//
//  DSHCompaction.swift
//  Minis
//
//  Context compaction, ported from DeepSeek Harness
//  (packages/compaction/compaction-basic/src/region.ts,
//   packages/compaction/compaction/src/tool-pairing.ts).
//
//  The selection rule matches DSH exactly:
//
//  1. Never compact the system head. A `system` message at surface node 0 stays
//     outside every range.
//  2. Walk the surface backwards accumulating token cost, stopping once the
//     retained tail reaches `retainTokens`.
//  3. Walk the candidate cut further back until it is tool-pairing balanced, so
//     a compaction never strands a tool call without its result.
//  4. Shadow the resulting positional range with one summary entry.
//
//  The transaction is a bracket: `start` is committed before the summary call
//  yields, `end` after it lands. An unmatched `start` is the compaction lock, so
//  two compactions cannot interleave — the condition OpenMinis guarded with a
//  separate `compactionsThisLoop` counter plus a queued-drain deferral.
//

import Foundation

// MARK: - Token Estimation

/// Token estimator for the compaction decision.
///
/// DSH routes this through a per-model token meter. On iOS the app already
/// carries a heuristic estimator (`estimateContextTokens`); the compaction only
/// needs relative cost, so a character-proportional estimate is sufficient and
/// keeps the decision independent of any provider's tokenizer.
public enum DSHTokenEstimate {
    /// Rough tokens per character for mixed prose and code.
    private static let charsPerToken = 3.6

    public static func tokens(for message: DSHMessage) -> Int {
        let chars = message.blocks.reduce(0) { partial, block in
            switch block {
            case let text as DSHTextBlock: return partial + text.text.count
            case let reasoning as DSHReasoningBlock: return partial + reasoning.text.count
            case let call as DSHToolCallBlock: return partial + call.name.count + call.arguments.count
            case let result as DSHToolResultBlock: return partial + result.content.count
            case let image as DSHImageBlock: return partial + 1200   // image tokens dominate
            case let file as DSHFileBlock: return partial + file.name.count + 64
            default: return partial
            }
        }
        return Int((Double(chars) / charsPerToken).rounded())
    }

    public static func tokens(for entry: DSHLogEntry) -> Int {
        tokens(for: entry.message)
    }

    public static func total(_ surface: [DSHLogEntry]) -> Int {
        surface.reduce(0) { $0 + tokens(for: $1) }
    }

    /// Estimated tokens for a rendered string — the assembled system prompt, or
    /// one tool's schema text.
    ///
    /// Same ratio as the per-message path above, so a component measured from
    /// text stays comparable with one measured from blocks. `[T-ctx-breakdown]`
    /// the composer's context panel is the caller: it reports the three
    /// components of one request, and the conversation row comes from
    /// `total(_:)` so the panel and the compaction decision can never disagree
    /// about the conversation's size.
    public static func tokens(forText text: String) -> Int {
        Int((Double(text.count) / charsPerToken).rounded())
    }

    /// Estimated tokens for a tool roster, measured from what the model is
    /// actually sent.
    ///
    /// The JSON Schema object is serialized rather than walked: the serialized
    /// form is the thing that goes on the wire, and it needs no agreement with
    /// the providers about which keys of a schema carry text. A schema that
    /// cannot be serialized contributes its name and description only.
    public static func tokens(forToolSchemas schemas: [DSHToolSchema]) -> Int {
        schemas.reduce(0) { partial, schema in
            var total = partial + tokens(forText: schema.name) + tokens(forText: schema.description)
            if let data = try? JSONSerialization.data(withJSONObject: schema.parameters),
               let json = String(data: data, encoding: .utf8) {
                total += tokens(forText: json)
            }
            return total
        }
    }
}

// MARK: - Trigger Policy

/// Failure resolving a trigger budget from model capacity and the routed request.
///
/// The iOS counterpart of DSH's `TargetPressureConfigError`. It carries the
/// exact route as a stable key so a caller can warn once per target instead of
/// once per step: the misconfiguration is a property of the deployment, and a
/// model that declares no capacity would otherwise produce one warning per
/// model request for the life of the conversation.
public struct DSHCompactionConfigError: Error, Sendable, Equatable {
    /// Exact `provider/model` route the failure belongs to.
    public let targetKey: String
    /// Actionable configuration detail.
    public let detail: String

    public init(targetKey: String, detail: String) {
        self.targetKey = targetKey
        self.detail = detail
    }

    public var message: String { detail }
}

/// Concrete token budgets for one routed request, scaled to its model capacity.
///
/// DSH's `ResolvedCompactSpec`. `thresholdTokens` is compared against the priced
/// request envelope (system prompt, tool roster, and surface), never against the
/// surface alone — the envelope is what the provider counts.
public struct DSHCompactionSpec: Sendable, Equatable {
    /// Capacity of the routed model.
    public let contextWindow: Int
    /// Output tokens the routed request reserves inside that capacity.
    public let reservedCompletionTokens: Int
    /// Window fraction used in the threshold.
    public let thresholdRatio: Double
    /// Pressure headroom beyond the output reservation.
    public let headroomTokens: Int
    /// Priced-envelope tokens at or above which pressure compaction runs.
    public let thresholdTokens: Int
    /// Recent-tail budget retained verbatim.
    public let retainTokens: Int
    /// Extra condensation attempts after the first while pressure remains.
    ///
    /// Carried on the resolved spec rather than read from the policy at the call
    /// site, so one resolved value drives the whole retry sequence.
    public let compactionRetries: Int
    /// Maximum retries after a provider-confirmed context overflow.
    public let maxOverflowRetries: Int

    public init(
        contextWindow: Int,
        reservedCompletionTokens: Int,
        thresholdRatio: Double,
        headroomTokens: Int,
        thresholdTokens: Int,
        retainTokens: Int,
        compactionRetries: Int,
        maxOverflowRetries: Int
    ) {
        self.contextWindow = contextWindow
        self.reservedCompletionTokens = reservedCompletionTokens
        self.thresholdRatio = thresholdRatio
        self.headroomTokens = headroomTokens
        self.thresholdTokens = thresholdTokens
        self.retainTokens = retainTokens
        self.compactionRetries = compactionRetries
        self.maxOverflowRetries = maxOverflowRetries
    }

    /// Replace the derived threshold with an absolute one.
    ///
    /// An override moves *when* a compaction fires, never what it keeps: the
    /// retained-tail budget, the capacity checks, and the retry budgets stay as
    /// derived. It exists for deployments whose window is too large to fill by
    /// hand (a probe build, a device experiment), so the pressure path is
    /// reachable without manufacturing a 262k-token conversation.
    public func overridingThreshold(_ tokens: Int) -> DSHCompactionSpec {
        DSHCompactionSpec(
            contextWindow: contextWindow,
            reservedCompletionTokens: reservedCompletionTokens,
            thresholdRatio: thresholdRatio,
            headroomTokens: headroomTokens,
            thresholdTokens: tokens,
            retainTokens: retainTokens,
            compactionRetries: compactionRetries,
            maxOverflowRetries: maxOverflowRetries
        )
    }
}

/// Pressure and retention policy resolved against one routed model.
///
/// Port of DSH `compaction-basic`'s `resolveConfig` defaults plus
/// `resolveCompactSpec`. The defaults are DSH's own published values
/// (`thresholdRatio` 0.8, `headroomTokens` 65536, `retainRatio` 0.16,
/// `compactionRetries` 1, `maxOverflowRetries` 1) so a compaction fires at the
/// same point this app's upstream does.
public struct DSHCompactionPolicy: Sendable {

    /// Window fraction used in `min(W × thresholdRatio, W − O − headroomTokens)`.
    public var thresholdRatio: Double
    /// Additional pressure headroom beyond the routed output reservation.
    public var headroomTokens: Int
    /// Recent tail kept verbatim as a fraction of `W − O`.
    public var retainRatio: Double
    /// Absolute recent-tail budget; nil derives `floor((W − O) × retainRatio)`.
    public var retainTokens: Int?
    /// Extra condensation attempts after the first while pressure remains.
    public var compactionRetries: Int
    /// Maximum retries after a provider-confirmed context overflow.
    public var maxOverflowRetries: Int

    public init(
        thresholdRatio: Double = 0.8,
        headroomTokens: Int = 65_536,
        retainRatio: Double = 0.16,
        retainTokens: Int? = nil,
        compactionRetries: Int = 1,
        maxOverflowRetries: Int = 1
    ) {
        self.thresholdRatio = thresholdRatio
        self.headroomTokens = headroomTokens
        self.retainRatio = retainRatio
        self.retainTokens = retainTokens
        self.compactionRetries = compactionRetries
        self.maxOverflowRetries = maxOverflowRetries
    }

    /// Scale this policy into concrete budgets for one model's capacity.
    ///
    /// Pressure is capped by both the window fraction and the capacity left
    /// after the routed output reservation plus headroom. Retention scales the
    /// message budget before headroom is deducted. Every rejection is a load- or
    /// first-use-time misconfiguration rather than a silent skip: a policy that
    /// cannot resolve must not silently disable compaction, or the failure looks
    /// exactly like "the conversation was never under pressure".
    ///
    /// - Parameters:
    ///   - contextWindow: adapter-declared capacity for the routed model.
    ///   - reservedCompletionTokens: output tokens one routed request reserves.
    /// - Returns: pressure and retention budgets for that route.
    /// - Throws: `DSHCompactionConfigError` naming the route and the cause.
    public func resolveSpec(
        targetKey: String,
        contextWindow: Int,
        reservedCompletionTokens: Int
    ) throws -> DSHCompactionSpec {
        guard contextWindow > 0 else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "contextWindow (\(contextWindow)) must be a positive integer"
            )
        }
        guard reservedCompletionTokens >= 0 else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "reservedCompletionTokens (\(reservedCompletionTokens)) "
                    + "must be a non-negative integer"
            )
        }
        guard thresholdRatio > 0, thresholdRatio <= 1 else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "thresholdRatio (\(thresholdRatio)) must be a number in (0, 1]"
            )
        }
        guard headroomTokens >= 0 else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "headroomTokens (\(headroomTokens)) must be non-negative"
            )
        }
        // A window that has to be fully spent on the output reservation plus
        // headroom leaves nothing to measure pressure against.
        let messageBudgetTokens = contextWindow - reservedCompletionTokens
        guard messageBudgetTokens > 0 else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "\(targetKey) reserves \(reservedCompletionTokens) completion tokens "
                    + "of its \(contextWindow)-token context window, leaving no message budget"
            )
        }
        let pressureBudgetTokens = messageBudgetTokens - headroomTokens
        guard pressureBudgetTokens > 0 else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "\(targetKey) reserves \(reservedCompletionTokens) completion tokens "
                    + "and \(headroomTokens) headroom tokens of its \(contextWindow)-token "
                    + "context window, leaving no pressure budget"
            )
        }
        let windowFraction = Int((Double(contextWindow) * thresholdRatio).rounded(.down))
        let thresholdTokens = min(windowFraction, pressureBudgetTokens)
        let derivedRetain = Int((Double(messageBudgetTokens) * retainRatio).rounded(.down))
        let retainTokens = self.retainTokens ?? derivedRetain
        guard retainTokens < thresholdTokens else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "retainTokens (\(retainTokens)) must be less than threshold tokens "
                    + "(\(thresholdTokens))"
            )
        }
        return DSHCompactionSpec(
            contextWindow: contextWindow,
            reservedCompletionTokens: reservedCompletionTokens,
            thresholdRatio: thresholdRatio,
            headroomTokens: headroomTokens,
            thresholdTokens: thresholdTokens,
            retainTokens: retainTokens,
            compactionRetries: compactionRetries,
            maxOverflowRetries: maxOverflowRetries
        )
    }

    /// The route key used to report one misconfiguration once.
    public static func targetKey(provider: String, model: String) -> String {
        "\(provider)/\(model)"
    }
}

// MARK: - Unified Trigger

/// Which of the two terms of `min()` is holding the trigger down.
///
/// The formula is a `min` of two bounds and the user only ever set one of them,
/// so "why is it firing here and not there" is otherwise unanswerable from the
/// settings screen. Named terms rather than two raw numbers for that reason.
public enum DSHCompactionThresholdBinding: String, Sendable, Equatable {
    /// `W × thresholdRatio` is the smaller term: the window fraction decides.
    case windowRatio = "window-ratio"
    /// `(W − O) − headroomTokens` is the smaller term: headroom decides.
    case headroom = "headroom"
}

/// The trigger, with the two terms it was chosen from.
///
/// ONE resolution of one formula, shared by every path that decides whether a
/// conversation is under pressure — the engine's mid-turn check
/// (`DSHTurnDriver.compactForPressure`) and the pre-send capacity check on the
/// view-model side. Log 2026-10-19 showed the same conversation carrying two
/// rulers: `[CtxMeter] … threshold=242144` (legacy `W − 20000`) against
/// `[CompactDiag] … threshold=188416` (this policy). Two numbers for one
/// decision is a bug even when both are individually defensible, so the
/// arithmetic moved here and the legacy site is meant to read it too.
public struct DSHCompactionThresholdBreakdown: Sendable, Equatable {
    /// Capacity of the routed model.
    public let window: Int
    /// Output tokens the routed request reserves.
    public let reserved: Int
    /// Pressure headroom beyond the output reservation.
    public let headroom: Int
    /// `floor(W × ratio)`.
    public let windowFraction: Int
    /// `(W − O) − headroom`.
    public let headroomBound: Int
    /// `min(windowFraction, headroomBound)` — the trigger actually in force.
    public let threshold: Int
    /// Which term produced `threshold`.
    public let binding: DSHCompactionThresholdBinding

    /// `windowFraction` as a percentage of the window, for the settings readout.
    public var windowPercentLabel: String {
        guard window > 0 else { return "0%" }
        return "\(Int((Double(windowFraction) / Double(window) * 100).rounded()))%"
    }

    /// Thousands-separated token count, for the settings readout.
    public static func format(_ tokens: Int) -> String {
        let digits = Array(String(tokens))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }
}

extension DSHCompactionPolicy {

    /// Resolve the trigger from one policy and one model capacity, keeping both
    /// terms.
    ///
    /// The formula is upstream's, unchanged and unabridged:
    /// `Math.floor(Math.min(contextWindow * thresholdRatio, pressureBudgetTokens))`
    /// (`packages/compaction/compaction-basic/src/config.ts:191-194`, with
    /// `pressureBudgetTokens = contextWindow - reservedCompletionTokens -
    /// headroomTokens` at `:181` and `:172`). The defaults are upstream's own
    /// published values (`DEFAULT_THRESHOLD_RATIO = 0.8` at `:20`,
    /// `headroomTokens ?? 65_536` at `:75`, `DEFAULT_RETAIN_RATIO = 0.16` at
    /// `:23`) and are NOT changed by the settings screen: the screen writes a
    /// stored override, and `resolveSpec` keeps applying this formula to it. The
    /// same clamps `resolveSpec` enforces apply here, so a caller can show the
    /// resolved number without first being able to throw.
    ///
    /// - Parameters:
    ///   - contextWindow: adapter-declared capacity for the routed model.
    ///   - reservedCompletionTokens: output tokens one routed request reserves.
    /// - Returns: the trigger with both of its terms, or nil when the pair cannot
    ///   yield one (non-positive window, or nothing left after output and
    ///   headroom) — the cases `resolveSpec` reports as misconfiguration.
    public func thresholdBreakdown(
        contextWindow: Int,
        reservedCompletionTokens: Int
    ) -> DSHCompactionThresholdBreakdown? {
        guard contextWindow > 0, reservedCompletionTokens >= 0 else { return nil }
        let messageBudget = contextWindow - reservedCompletionTokens
        guard messageBudget > 0 else { return nil }
        let pressureBudget = messageBudget - headroomTokens
        guard pressureBudget > 0 else { return nil }
        let windowFraction = Int((Double(contextWindow) * thresholdRatio).rounded(.down))
        let threshold = min(windowFraction, pressureBudget)
        return DSHCompactionThresholdBreakdown(
            window: contextWindow,
            reserved: reservedCompletionTokens,
            headroom: headroomTokens,
            windowFraction: windowFraction,
            headroomBound: pressureBudget,
            threshold: threshold,
            binding: windowFraction <= pressureBudget ? .windowRatio : .headroom
        )
    }
}

// MARK: - Overflow Classification

/// Recognizes the provider wording that means "this request exceeded the model's
/// context window".
///
/// Port of DSH's `isContextWindowExceededError`. Overflow recovery hangs off this
/// classifier, so a miss is not cosmetic: an unclassified over-length refusal
/// ends the turn as a provider error instead of being answered with a compaction
/// and a retry. The patterns are the same ones DSH ships — the structured
/// `context_length_exceeded`/`context window exceeded` family, the
/// "maximum context length" family, and the three phrasings that tie "too
/// large"/"exceeds" to the model's context specifically.
///
/// DSH's adapters normalize recognized failures to a `CONTEXT_WINDOW_EXCEEDED`
/// code. This app's providers surface the provider's own message text, so the
/// classifier is the only route to the same decision; callers must therefore
/// pass every piece of text a failure carries (code, status, message), not just
/// the message.
public enum DSHContextOverflow {

    /// Structured codes and plain phrases that explicitly name a context bound
    /// being exceeded.
    private static let structured = #"(?:^|[^a-z0-9])context[\s_-](?:length|window)[\s_-](?:exceed(?:ed|s)?|overflow(?:ed)?|limit[\s_-]exceeded)(?:$|[^a-z0-9])"#

    /// Request-size wording that ties "too large" directly to model capacity.
    private static let tooLargeForContext = #"\b(?:request|prompt|input|messages?)\s+(?:is\s+|are\s+)?too\s+(?:large|long)\s+for\s+(?:(?:this|the)\s+)?(?:model(?:'s)?\s+)?context(?:\s+window)?\b"#

    /// "Exceeds" wording is safe only when its object is explicitly the model
    /// context.
    private static let exceedsModelContext = #"\b(?:input|prompt|request|messages?)\b.{0,40}\b(?:exceed(?:s|ed)?|overflows?|is\s+larger\s+than)\b.{0,40}\b(?:the\s+)?(?:model(?:'s)?\s+)?context(?:\s+(?:length|window))?\b"#

    /// The declared maximum context, named as such.
    private static let maximumContext = #"\b(?:maximum|max)(?:\s+(?:allowed|supported))?\s+context\s+(?:length|window)\b"#

    /// "too long for this model", without naming the context explicitly.
    private static let tooLongForModel = #"\b(?:input|prompt|request)\s+(?:is\s+)?too\s+(?:long|large)\s+for\s+(?:this|the)\s+model\b"#

    /// The canonical provider-neutral code DSH normalizes this failure to.
    public static let code = "CONTEXT_WINDOW_EXCEEDED"

    /// Whether a failure's text identifies a request exceeding the model window.
    ///
    /// - Parameter detail: provider code, status, and message text joined into
    ///   one string, so in-band and thrown delivery styles share one classifier.
    /// - Returns: true when the detail names a context bound being exceeded.
    public static func isContextWindowExceeded(_ detail: String) -> Bool {
        if detail.contains(code) { return true }
        return matches(structured, detail)
            || matches(maximumContext, detail)
            || matches(tooLargeForContext, detail)
            || matches(tooLongForModel, detail)
            || matches(exceedsModelContext, detail)
    }

    private static func matches(_ pattern: String, _ detail: String) -> Bool {
        detail.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

// MARK: - Selection

/// One validated inclusive span of surface positions to compact.
public struct DSHCompactableRange: Sendable, Equatable {
    /// First surface index in the range.
    public let startIndex: Int
    /// Last surface index in the range (inclusive).
    public let endIndex: Int
    /// Seqs of the entries the range covers.
    public let shadowedSeqs: [DSHSeq]
    /// Estimated token count of the shadowed content.
    public let shadowedTokenCount: Int
    /// Estimated token count of the retained tail.
    public let retainedTokenCount: Int

    public init(
        startIndex: Int,
        endIndex: Int,
        shadowedSeqs: [DSHSeq],
        shadowedTokenCount: Int,
        retainedTokenCount: Int
    ) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.shadowedSeqs = shadowedSeqs
        self.shadowedTokenCount = shadowedTokenCount
        self.retainedTokenCount = retainedTokenCount
    }

    public var isEmpty: Bool { startIndex > endIndex }
}

/// Selects the range a compaction shadows.
public enum DSHCompactionSelection {

    /// Select the compactable range for a surface.
    ///
    /// Mirrors DSH's `selectCompactableRange`: the system head is never inside
    /// the range, the recent tail is retained verbatim up to `retainTokens`, and
    /// the cut is walked back to a tool-pairing balanced position.
    ///
    /// - Parameters:
    ///   - surface: current surface, oldest first.
    ///   - retainTokens: minimum recent-tail budget retained verbatim.
    ///   - pressureThreshold: priced tokens above which compaction is worth doing.
    ///     When the measurement passed below is below this, selection returns
    ///     nil. Pass `0` to select the maximal balanced head reduction with no
    ///     pressure gate at all — the provider-confirmed overflow path, where the
    ///     request has already failed.
    ///   - measuredTokens: the priced request envelope the gate compares, i.e.
    ///     system prompt + tool roster + surface. DSH gates on the token meter's
    ///     envelope total, not on the surface total; measuring the surface alone
    ///     under-reports exactly the part of the request this app cannot shrink
    ///     and lets a request overflow while the surface still looks small.
    /// - Returns: the range to compact, or nil when nothing should be compacted.
    public static func select(
        surface: [DSHLogEntry],
        retainTokens: Int,
        pressureThreshold: Int,
        measuredTokens: Int
    ) -> DSHCompactableRange? {
        guard !surface.isEmpty else { return nil }

        guard measuredTokens >= pressureThreshold else { return nil }

        // A system head at node 0 is never inside the range.
        let firstIdx = isSystemHead(surface[0]) ? 1 : 0
        guard surface.count > firstIdx + 1 else { return nil }

        // Walk backwards accumulating the retained tail.
        var accumulated = 0
        var keepFromIdx = surface.count
        var index = surface.count - 1
        while index >= firstIdx {
            accumulated += DSHTokenEstimate.tokens(for: surface[index])
            keepFromIdx = index
            if accumulated >= retainTokens { break }
            index -= 1
        }
        if keepFromIdx <= firstIdx { return nil }

        // Walk the cut back to a tool-pairing balanced position.
        guard let balanced = DSHToolPairing.nearestBalancedBefore(
            surface: surface, index: keepFromIdx
        ) else { return nil }
        if balanced <= firstIdx { return nil }
        keepFromIdx = balanced

        let rangeSeqs = surface[firstIdx..<keepFromIdx].map(\.seq)
        let shadowedTokens = surface[firstIdx..<keepFromIdx]
            .reduce(0) { $0 + DSHTokenEstimate.tokens(for: $1) }
        let retainedTokens = surface[keepFromIdx...]
            .reduce(0) { $0 + DSHTokenEstimate.tokens(for: $1) }

        return DSHCompactableRange(
            startIndex: firstIdx,
            endIndex: keepFromIdx - 1,
            shadowedSeqs: rangeSeqs,
            shadowedTokenCount: shadowedTokens,
            retainedTokenCount: retainedTokens
        )
    }

    private static func isSystemHead(_ entry: DSHLogEntry) -> Bool {
        entry.message.role == .system
    }
}

// MARK: - Transaction

/// Failure captured after `compaction/start` committed, so the bracket always
/// closes exactly once.
public enum DSHCompactionError: Error, Sendable, Equatable {
    /// A compaction is already open on this session.
    case busy
    /// No open turn to enclose an automatic compaction.
    case noOpenTurn
    /// The summary call failed.
    case summaryFailed(String)
    /// The surface changed under the summary, so the span is no longer valid.
    case surfaceChanged
    /// The summary would not shrink the surface enough to be worth it.
    case noShrink

    public var message: String {
        switch self {
        case .busy: return "a compaction is already open on this session"
        case .noOpenTurn: return "automatic compaction requires an open turn"
        case .summaryFailed(let reason): return "summarization failed: \(reason)"
        case .surfaceChanged: return "the surface changed while summarizing"
        case .noShrink: return "the summary would not shrink the surface"
        }
    }
}

/// Outcome of one compaction.
public struct DSHCompactionOutcome: Sendable {
    public let summarySeq: DSHSeq
    public let range: DSHCompactableRange
    /// Tokens the surface held before the compaction.
    public let beforeTokens: Int
    /// Tokens the surface holds after it.
    public let afterTokens: Int
    /// The model that wrote the summary, recorded so "which model wrote this"
    /// has a durable answer rather than being inferred from the provider route.
    public let model: String
    /// The provider route the summary came from.
    public let provider: String

    public var shrinkRatio: Double {
        guard beforeTokens > 0 else { return 0 }
        return Double(beforeTokens - afterTokens) / Double(beforeTokens)
    }
}

/// Runs the compaction transaction.
public enum DSHCompaction {

    /// Bracket state, tracked so two compactions cannot interleave.
    private final class Bracket: @unchecked Sendable {
        var open = false
        var turn: Int?
        let lock = NSLock()

        func begin(turn: Int?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !open else { return false }
            open = true
            self.turn = turn
            return true
        }

        func end() {
            lock.lock(); defer { lock.unlock() }
            open = false
            turn = nil
        }
    }

    /// Compact a session's surface.
    ///
    /// - Parameters:
    ///   - session: the session to compact.
    ///   - turn: the enclosing turn for an automatic compaction, or nil for a
    ///     standalone manual one.
    ///   - retainTokens: recent-tail budget retained verbatim. `0` retains only
    ///     the newest surface node, which is the maximal balanced head reduction.
    ///   - pressureThreshold: priced tokens above which compaction runs; `0`
    ///     removes the gate (the provider-confirmed overflow path).
    ///   - measuredTokens: the priced request envelope `pressureThreshold` is
    ///     compared against. Must be the same value the caller gated on.
    ///   - summarize: builds the summary for the shadowed content. Called with
    ///     the surface text of the range being compacted.
    ///   - model / provider: recorded on the summary so "which model wrote this"
    ///     has a durable answer.
    /// - Returns: the outcome, or an error.
    public static func compact(
        session: DSHSession,
        turn: Int?,
        retainTokens: Int,
        pressureThreshold: Int,
        measuredTokens: Int,
        model: String,
        provider: String,
        summarize: @escaping @Sendable (String) async throws -> String
    ) async -> Result<DSHCompactionOutcome, DSHCompactionError> {
        let surface = session.surface()
        let beforeTokens = DSHTokenEstimate.total(surface)

        guard let range = DSHCompactionSelection.select(
            surface: surface,
            retainTokens: retainTokens,
            pressureThreshold: pressureThreshold,
            measuredTokens: measuredTokens
        ) else {
            return .failure(.noShrink)
        }

        let shadowedText = surface[range.startIndex...range.endIndex]
            .map { entry in Self.renderForSummary(entry) }
            .joined(separator: "\n\n")

        let summaryText: String
        do {
            summaryText = try await summarize(shadowedText)
        } catch {
            return .failure(.summaryFailed(String(describing: error)))
        }

        // Re-read the surface: an append during the summary call is fine (the
        // range's seqs are still valid), but a compaction that landed in
        // between invalidates the span we built from.
        let currentSurface = session.surface()
        let currentSeqs = Set(currentSurface.map { $0.seq.value })
        if !range.shadowedSeqs.allSatisfy({ currentSeqs.contains($0.value) }) {
            return .failure(.surfaceChanged)
        }

        // The summary replaces the range, so it must cost less than what it
        // shadows. Otherwise compaction churns context for no gain.
        let summaryMessage = DSHMessage(role: .user, blocks: [
            DSHTextBlock(text: Self.summaryEnvelope(summaryText))
        ])
        let summaryTokens = DSHTokenEstimate.tokens(for: summaryMessage)
        guard summaryTokens < range.shadowedTokenCount else {
            return .failure(.noShrink)
        }

        // [T-nonmonotonic-seq-range] `shadowedSeqs` is in surface order, not seq order: a
        // range that ends inside the previously kept tail yields descending values, and
        // `first!...last!` would then trap in `ClosedRange.init` (a crash, not a throw).
        // The range only means "the span of seqs this summary shadows", so take the
        // extremes.
        guard let shadowedLow = range.shadowedSeqs.min(),
              let shadowedHigh = range.shadowedSeqs.max(),
              shadowedLow <= shadowedHigh else {
            return .failure(.noShrink)
        }
        let shadowedRange = shadowedLow...shadowedHigh
        let summarySeq = session.appendCompaction(
            summary: summaryMessage,
            shadows: shadowedRange,
            shadowedTokenCount: range.shadowedTokenCount,
            model: model,
            provider: provider,
            turn: turn
        )

        let afterTokens = DSHTokenEstimate.total(session.surface())
        return .success(DSHCompactionOutcome(
            summarySeq: summarySeq,
            range: range,
            beforeTokens: beforeTokens,
            afterTokens: afterTokens,
            model: model,
            provider: provider
        ))
    }

    // MARK: - Summary Envelope

    /// Wrap a summary so the model treats it as background rather than as the
    /// current instruction.
    ///
    /// The precedence clause matters: without it a stale summary can override a
    /// newer, shorter user instruction, which is the failure the envelope exists
    /// to prevent.
    static func summaryEnvelope(_ summary: String) -> String {
        """
        <context-summary>
        The following is a summary of earlier conversation that was compacted to save context space.

        Treat it as background context only. The user's most recent message takes precedence — if it changes the task, the goal, or any numbers or scope, follow the new instruction and do not resume the old plan from this summary. Do not re-run discovery (reading memory, scanning skills, re-reading files) unless the new instruction requires it.

        \(summary)
        </context-summary>
        """
    }

    /// Render one entry as text for the summarizer.
    static func renderForSummary(_ entry: DSHLogEntry) -> String {
        var lines: [String] = []
        let role = entry.message.role.rawValue
        for block in entry.message.blocks {
            switch block {
            case let text as DSHTextBlock:
                lines.append("[\(role)] \(text.text)")
            case let reasoning as DSHReasoningBlock:
                lines.append("[\(role) reasoning] \(reasoning.text)")
            case let call as DSHToolCallBlock:
                lines.append("[\(role) tool-call \(call.name)] \(call.arguments)")
            case let result as DSHToolResultBlock:
                let status = result.isError ? "error" : "ok"
                lines.append("[tool-result \(result.name) \(status)] \(result.content)")
            case let image as DSHImageBlock:
                lines.append("[\(role) image] \(image.mimeType) \(image.path ?? "(inline)")")
            case let file as DSHFileBlock:
                lines.append("[\(role) file] \(file.name) (\(file.size) bytes)")
            default:
                continue
            }
        }
        return lines.joined(separator: "\n")
    }
}
