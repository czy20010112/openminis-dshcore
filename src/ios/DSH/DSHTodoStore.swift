//
//  DSHTodoStore.swift
//  Minis
//
//  The session's task list, and the state behind the todo panel above the
//  composer.
//
//  Ported from DSH's `tool-todo` package (`packages/todo/tool-todo`). The
//  contract is deliberately the same shape, because the model was tuned against
//  it:
//
//    * `todo_write` takes the ENTIRE list and REPLACES the previous one. There
//      are no partial updates and no per-item edits, which is why an item needs
//      no identity of its own — see `DSHTodoItem.id`.
//    * Statuses are exactly three: `pending`, `in_progress`, `completed`.
//    * Several items may be `in_progress` at once. DSH ships
//      `allowParallelInProgress: true`, so the "exactly one active task" rule is
//      NOT enforced; parallel subagents and background commands make it wrong.
//    * The list never reaches the system prompt. DSH does not inject it either —
//      the tool description carries the whole contract.
//
//  Two deliberate departures from DSH:
//
//    * DSH's `todos` projection resets to null on `turn/start`, so its panel is
//      per-turn. Here the list survives the turn and is replaced only by the
//      next `todo_write`, which is what a multi-turn task actually wants.
//    * DSH requires an untrimmed `content` to be rejected by an invariant. This
//      trims instead: a leading space is not worth a failed call.
//

import Foundation

/// The model-facing outcome of a tool call that only changes session state.
///
/// Not `Result<String, String>`: `Result`'s failure must conform to `Error`, and
/// `String` does not. The two fields are exactly what the tool dispatcher wants
/// to write anyway (`toolOutput` / `toolSuccess`).
///
/// `public` because `DSHPlanMode.exit` is public and returns it — a public method
/// cannot expose an internal type. The members stay internal; nothing outside
/// this module reads them.
public struct DSHToolOutcome {
    let output: String
    let success: Bool

    static func ok(_ output: String) -> DSHToolOutcome {
        DSHToolOutcome(output: output, success: true)
    }

    /// The dispatcher prefixes failures with `Error: `, and the model is told
    /// plainly what was wrong with its call.
    static func failed(_ reason: String) -> DSHToolOutcome {
        DSHToolOutcome(output: reason, success: false)
    }
}

/// One entry of the session's task list.
struct DSHTodoItem: Equatable, Identifiable {

    enum Status: String, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case completed

        /// What the panel's state dot and the tool result call it.
        var label: String {
            switch self {
            case .pending: return "pending"
            case .inProgress: return "in progress"
            case .completed: return "completed"
            }
        }
    }

    let content: String
    var status: Status

    /// The whole list is replaced on every write and `content` is unique within
    /// it, so the content IS the identity. DSH does the same and says why:
    /// stable per-item ids would only be needed if items could be edited in
    /// place, and they cannot.
    var id: String { content }
}

/// The session's task list.
///
/// Not `@MainActor`, deliberately. It is read from three places whose isolation
/// a type annotation would fight: a SwiftUI view's property initialiser, the
/// plan-mode prompt section's closure, and the tool dispatcher. Every caller in
/// this app runs on the main actor (the view model, the DSH turn, the tool
/// dispatch switch), so the invariant holds by construction — and it is stated
/// here rather than enforced by an annotation that would only push the
/// gymnastics into those three call sites.
final class DSHTodoStore: ObservableObject {

    static let shared = DSHTodoStore()

    @Published private(set) var todos: [DSHTodoItem] = []

    /// Whether the turn is running under plan mode — see `DSHPlanMode`.
    @Published private(set) var planModeActive = false

    private init() {}

    // MARK: - Reading

    var isActive: Bool { !todos.isEmpty || planModeActive }

    var counts: (pending: Int, inProgress: Int, completed: Int) {
        var pending = 0
        var inProgress = 0
        var completed = 0
        for todo in todos {
            switch todo.status {
            case .pending: pending += 1
            case .inProgress: inProgress += 1
            case .completed: completed += 1
            }
        }
        return (pending, inProgress, completed)
    }

    /// `12 · 3 done · 2 active · 7 pending`, with zero counts left out.
    ///
    /// DSH's `progressLabel` omits empty segments and joins the rest with an
    /// en-space, a middle dot and an en-space, which is what keeps the header
    /// from reading as a wall of zeros before the first task is done.
    ///
    /// Each segment is a catalog key (`"%lld done"`, `"%lld active"`,
    /// `"%lld pending"`) applied through `String(format:)`, not a literal
    /// interpolated into one sentence: this is a `String` that a view renders,
    /// so `Text` would take the finished sentence verbatim and the bar would read
    /// English on every device. The leading total is a bare number and needs no
    /// key. A key that is not in the catalog yet falls back to the English
    /// source, which is why the call sites are safe to land before the table is
    /// filled in.
    var progressLabel: String {
        let c = counts
        var parts: [String] = ["\(todos.count)"]
        if c.completed > 0 { parts.append(String(format: AppLocalized("%lld done"), c.completed)) }
        if c.inProgress > 0 { parts.append(String(format: AppLocalized("%lld active"), c.inProgress)) }
        if c.pending > 0 { parts.append(String(format: AppLocalized("%lld pending"), c.pending)) }
        return parts.joined(separator: "\u{2002}\u{00B7}\u{2002}")
    }

    /// The active task's line, for the collapsed header when there is one.
    var activeContent: String? {
        todos.first { $0.status == .inProgress }?.content
    }

    // MARK: - Writing

    func setPlanMode(_ active: Bool) {
        guard planModeActive != active else { return }
        planModeActive = active
    }

    /// Drop the list and plan state — a new conversation, or "clear".
    func clear() {
        if !todos.isEmpty { todos = [] }
        planModeActive = false
    }

    /// Replace the list from a `todo_write` call.
    ///
    /// - Parameter raw: the `todos` argument as it arrived. The app's tool schema
    ///   has no array parameter type, so the model is asked for a JSON-encoded
    ///   array and sends a string — but a provider that hands over a real array
    ///   is accepted too, since that costs three lines and removes a way for a
    ///   correct call to fail.
    /// - Returns: the model-facing result text, or the reason the call was
    ///   rejected.
    func replace(raw: Any?) -> DSHToolOutcome {
        guard let parsed = Self.parseItems(raw) else {
            return .failed(
                "todo_write: `todos` must be a JSON array of objects like "
                + #"[{"content": "...", "status": "pending"}]"#
            )
        }

        var items: [DSHTodoItem] = []
        var seen = Set<String>()
        for (index, entry) in parsed.enumerated() {
            // DSH rejects a key beyond `content`/`status` instead of dropping
            // it ("model-visible must equal logged", upstream `2d95a60ac9`).
            // The `todos` argument here is a JSON string, so the schema cannot
            // reject the extra key for us, so the check lives in this loop; a
            // rejection happens before the list is assigned.
            let unknown = entry.keys
                .filter { $0 != "content" && $0 != "status" }
                .sorted()
            if !unknown.isEmpty {
                return .failed(
                    "todo_write: item \(index) has unknown key(s) "
                    + unknown.map { "`\($0)`" }.joined(separator: ", ")
                    + " — each item is exactly `content` and `status`."
                )
            }
            guard let rawContent = entry["content"] as? String else {
                return .failed("todo_write: item \(index) has no `content`.")
            }
            let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                return .failed("todo_write: item \(index) has empty `content`.")
            }
            // Uniqueness is what lets the content double as the identity, and it
            // is what DSH validates — a duplicated line makes "mark it done"
            // ambiguous.
            guard seen.insert(content).inserted else {
                return .failed("todo_write: duplicate content \"\(content)\" — each todo must be a distinct line.")
            }
            guard let rawStatus = entry["status"] as? String,
                  let status = DSHTodoItem.Status(rawValue: rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return .failed(
                    "todo_write: item \(index) needs a `status` of pending, in_progress or completed "
                    + "(got \(entry["status"].map { "\($0)" } ?? "nothing"))."
                )
            }
            items.append(DSHTodoItem(content: content, status: status))
        }

        todos = items
        let c = counts
        return .ok(
            "Updated todo list: \(c.pending) pending, \(c.inProgress) in progress, \(c.completed) completed."
        )
    }

    /// Accept either a JSON string or an already-decoded array of dictionaries.
    private static func parseItems(_ raw: Any?) -> [[String: Any]]? {
        if let array = raw as? [[String: Any]] { return array }
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        // A single object is a common near-miss: one todo, no array wrapper.
        if let one = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return [one]
        }
        return nil
    }
}
