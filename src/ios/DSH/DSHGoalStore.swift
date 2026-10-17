//
//  DSHGoalStore.swift
//  Minis
//
//  The session's one long-running completion objective, and the state behind the
//  goal bar above the composer.
//
//  Ported from DSH's `goal` package (`packages/goal/goal`). The contract is the
//  same shape, because the model was tuned against it:
//
//    * AN OBJECTIVE IS STATE, NOT SCHEDULING. DSH's README says it outright —
//      "the package stores goal state but does not schedule work". Nothing here
//      runs a turn; the model advances the goal (and, once a round driver
//      exists, that driver admits rounds against this state).
//    * Phase is exactly four values: `active`, `paused`, `blocked`, `complete`.
//      One goal per session. A non-complete goal must be edited, paused,
//      resumed, blocked or cleared before it can be replaced; a complete one may
//      be replaced outright.
//    * Every mutation bumps `revision`, and every mutation that names a goal
//      must carry the exact `{id, revision}` it read — a stale pair is refused
//      (DSH's compare-and-set, `GOAL_STALE_REVISION`).
//    * `blocked` is the only phase carrying a machine-routable `code` plus a
//      human-readable `message`, so a provider limit, an exhausted budget and a
//      genuine request for human input share one phase instead of growing four.
//    * Activation (`armed`/`disarmed`) is PROCESS-LOCAL and never persisted.
//      It answers "may automatic continuation run right now", which is why
//      pause / complete / block / clear all disarm and resume arms.
//
//  One deliberate departure from DSH: DSH stores the goal in the session log and
//  replays it (event sourcing, `goal/change` events, a projection). This app's
//  `DSHTodoStore` is plain memory and has no session-log format to append to, so
//  the state lives in memory too. The consequence is the honest one: a relaunch
//  loses the goal, which DSH's own behaviour already implied — an active goal is
//  disarmed after any session-start edge, so automatic continuation never
//  survived a restart there either. What is lost here is the display.
//
//  The other departure is the round cap. DSH's deployment default is 256; this
//  store's is 5. A phone can be left alone in a pocket, and 256 unattended turns
//  is a bill, not a feature. DSH's own rule is that the cap belongs to the
//  deployment rather than to the code, so it is a named constant here.
//

import Foundation

/// The session's goal: one objective, its phase, and its round budget.
struct DSHGoal: Equatable, Identifiable {

    /// Durable lifecycle phase. `armed` (below) is a separate, process-local fact.
    enum Phase: String, CaseIterable {
        case active
        case paused
        case blocked
        case complete

        /// Whether a goal in this phase is still being worked toward. The panel
        /// draws only these, which is DSH's rule too: a completed or cleared goal
        /// has nothing left to say above the composer.
        var isLive: Bool {
            switch self {
            case .active, .paused, .blocked: return true
            case .complete: return false
            }
        }
    }

    /// A stable classification plus the explanation a human reads.
    struct BlockReason: Equatable {
        /// Lower-kebab-case, chosen by whichever policy blocked the goal.
        let code: String
        let message: String
    }

    let id: String
    /// Positive; every mutation increments it. This is the compare-and-set half
    /// of `{id, revision}` that `update_goal` has to echo back.
    var revision: Int
    var objective: String
    var phase: Phase
    /// Present exactly while `phase` is `blocked`.
    var blockedReason: BlockReason?
    /// Total admitted continuation rounds this goal may spend. Replaced only by
    /// an `edit`, which is why it is not `let`.
    var maxGoalRounds: Int
    /// Rounds admitted so far. Human turns are free; only a goal round counts.
    var roundsStarted: Int
}

/// The session's goal.
///
/// Not `@MainActor`, for the same reason `DSHTodoStore` is not: it is read from
/// a SwiftUI view, from the goal prompt section's closure, and from the tool
/// dispatcher. Every one of those callers runs on the main actor in this app, so
/// the invariant holds by construction rather than by an annotation that would
/// only push the gymnastics into the three call sites.
final class DSHGoalStore: ObservableObject {

    static let shared = DSHGoalStore()

    /// Rounds an objective may spend when its `create_goal` call names none.
    ///
    /// DSH's deployment default is 256. This is the one number that decides how
    /// much unattended work a single objective can authorise, and on a phone the
    /// answer is "not much": a small cap makes a runaway goal visible while it is
    /// still cheap, and the user can raise it per objective with
    /// `create_goal max_goal_rounds`.
    static let defaultMaxGoalRounds = 5

    /// Below this many rounds, `blocked` is refused: difficulty, uncertainty and
    /// "work remains" are not blockers, and a goal that reports one after a single
    /// round is a goal that quit early. DSH's configuration default is the same 3.
    static let blockedAfterConsecutiveRounds = 3

    /// The current goal, or nil before the first create and after a clear.
    @Published private(set) var goal: DSHGoal?

    /// Whether this process may automatically continue the current goal. Never
    /// persisted, and meaningless without a round driver — but it is part of the
    /// canonical tool output and of what the user needs to see, so it is real
    /// state here rather than a value invented at render time.
    @Published private(set) var activation: DSHActivation = .disarmed

    /// Whether a goal is present and still live, which is what the bar draws.
    var hasLiveGoal: Bool { goal?.phase.isLive ?? false }

    private init() {}

    // MARK: - Reading

    /// The current goal as the tool surface reports it.
    var view: DSHGoalView? {
        guard let goal else { return nil }
        return DSHGoalView(goal: goal, activation: activation)
    }

    /// The exact `{id, revision}` a mutation must echo back.
    var ref: DSHGoalRef? {
        guard let goal else { return nil }
        return DSHGoalRef(id: goal.id, revision: goal.revision)
    }

    /// `Rounds: 2/5`, the same shape DSH's `/goal` prints.
    var roundsLabel: String { "\(goal?.roundsStarted ?? 0)/\(goal?.maxGoalRounds ?? Self.defaultMaxGoalRounds)" }

    // MARK: - Writing

    /// Create and arm a goal, replacing a completed one.
    ///
    /// - Throws: `alreadyExists` when the current goal is not `complete` — DSH
    ///   requires the caller to edit, pause, resume, block or clear it first, so a
    ///   long-running objective cannot be silently overwritten by a passing
    ///   remark.
    @discardableResult
    func create(objective: String, maxGoalRounds: Int? = nil) throws -> DSHGoalView {
        if let current = goal, current.phase != .complete {
            throw DSHGoalError.alreadyExists(current)
        }
        let text = try Self.validatedObjective(objective)
        let cap = try Self.validatedCap(maxGoalRounds ?? Self.defaultMaxGoalRounds)
        let created = DSHGoal(
            id: "goal-\(UUID().uuidString)",
            revision: 1,
            objective: text,
            phase: .active,
            blockedReason: nil,
            maxGoalRounds: cap,
            roundsStarted: 0
        )
        goal = created
        activation = .armed
        return DSHGoalView(goal: created, activation: activation)
    }

    /// Edit the objective and/or the round cap. Phase is untouched.
    ///
    /// - Throws: `invalidEdit` when neither field is present.
    @discardableResult
    func edit(ref: DSHGoalRef, objective: String? = nil, maxGoalRounds: Int? = nil) throws -> DSHGoalView {
        guard objective != nil || maxGoalRounds != nil else { throw DSHGoalError.invalidEdit }
        return try mutate(ref: ref) { current in
            var next = current
            if let objective { next.objective = try Self.validatedObjective(objective) }
            if let maxGoalRounds { next.maxGoalRounds = try Self.validatedCap(maxGoalRounds) }
            return next
        }
    }

    /// Pause an active goal and disarm continuation.
    @discardableResult
    func pause(ref: DSHGoalRef) throws -> DSHGoalView {
        try transition(ref: ref, from: [.active], to: .paused, activation: .disarmed)
    }

    /// Resume and arm a stopped goal, or rearm an active goal after a
    /// session-start edge, while its round budget still has capacity.
    ///
    /// - Throws: `resumePaused` when the durable phase is `paused`. That transfer
    ///   belongs to the user — DSH refuses it for the model under
    ///   `GOAL_TOOL_RESUME_PAUSED`, and a model that could un-pause itself would
    ///   make "pause" advisory.
    @discardableResult
    func resume(ref: DSHGoalRef) throws -> DSHGoalView {
        guard let current = goal, matches(ref, current) else { throw DSHGoalError.stale(ref, goal) }
        if current.phase == .paused { throw DSHGoalError.resumePaused(current) }
        guard [.active, .blocked].contains(current.phase) else {
            throw DSHGoalError.invalidTransition(current, "resume")
        }
        if current.phase == .active, activation == .armed { throw DSHGoalError.alreadyArmed(current) }
        if current.roundsStarted >= current.maxGoalRounds { throw DSHGoalError.roundsExhausted(current) }
        var next = current
        next.phase = .active
        next.blockedReason = nil
        next.revision = current.revision + 1
        goal = next
        activation = .armed
        return DSHGoalView(goal: next, activation: activation)
    }

    /// Mark a current non-complete goal complete and disarm it.
    @discardableResult
    func complete(ref: DSHGoalRef) throws -> DSHGoalView {
        try transition(ref: ref, from: [.active, .paused, .blocked], to: .complete, activation: .disarmed)
    }

    /// Mark an active goal blocked, recording why, and disarm it.
    @discardableResult
    func block(ref: DSHGoalRef, reason: DSHGoal.BlockReason) throws -> DSHGoalView {
        let code = reason.code
        guard code.range(of: #"^[a-z][a-z0-9]*(-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            throw DSHGoalError.invalidBlockReason
        }
        let message = reason.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw DSHGoalError.invalidBlockReason }
        return try mutate(ref: ref) { current in
            guard current.phase == .active else { throw DSHGoalError.invalidTransition(current, "block") }
            var next = current
            next.phase = .blocked
            next.blockedReason = DSHGoal.BlockReason(code: code, message: message)
            return next
        }
    }

    /// Drop the goal. DSH keeps a tombstone so the history still shows it; there
    /// is no durable log here, so the goal is simply gone.
    func clear(ref: DSHGoalRef) throws {
        guard let current = goal, matches(ref, current) else { throw DSHGoalError.stale(ref, goal) }
        goal = nil
        activation = .disarmed
    }

    /// Drop the goal without a compare-and-set — a new conversation, or "clear".
    func clear() {
        goal = nil
        activation = .disarmed
    }

    // MARK: - Activation

    /// Set process-local continuation authority without touching durable state.
    func setActivation(_ activation: DSHActivation) {
        guard self.activation != activation else { return }
        self.activation = activation
    }

    // MARK: - Mutation plumbing

    /// Apply one mutation to the current goal, bumping its revision.
    ///
    /// The compare-and-set happens before the mutation body runs: `block` and
    /// `edit` re-check phase inside, and both must not have written anything by
    /// the time they do.
    private func mutate(ref: DSHGoalRef, _ body: (DSHGoal) throws -> DSHGoal) throws -> DSHGoalView {
        guard let current = goal, matches(ref, current) else { throw DSHGoalError.stale(ref, goal) }
        var next = try body(current)
        next.revision = current.revision + 1
        goal = next
        return DSHGoalView(goal: next, activation: activation)
    }

    /// Shared validated phase transition.
    private func transition(
        ref: DSHGoalRef,
        from allowed: [DSHGoal.Phase],
        to phase: DSHGoal.Phase,
        activation: DSHActivation
    ) throws -> DSHGoalView {
        guard let current = goal, matches(ref, current) else { throw DSHGoalError.stale(ref, goal) }
        guard allowed.contains(current.phase) else {
            throw DSHGoalError.invalidTransition(current, phase == .complete ? "complete" : "pause")
        }
        var next = current
        next.phase = phase
        next.blockedReason = nil
        next.revision = current.revision + 1
        goal = next
        self.activation = activation
        return DSHGoalView(goal: next, activation: self.activation)
    }

    private func matches(_ ref: DSHGoalRef, _ current: DSHGoal) -> Bool {
        ref.id == current.id && ref.revision == current.revision
    }

    private static func validatedObjective(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DSHGoalError.invalidObjective }
        return trimmed
    }

    private static func validatedCap(_ value: Int) throws -> Int {
        guard value >= 1 else { throw DSHGoalError.invalidMaxRounds }
        return value
    }
}
