//
//  DSHGoalTools.swift
//  Minis
//
//  The model-facing `get_goal`, `create_goal` and `update_goal` tools, over
//  `DSHGoalStore`.
//
//  Ported from DSH's `tool-goal` package (`packages/goal/tool-goal`). Three
//  things travel together and are kept together here, because splitting them is
//  how they drift:
//
//    * the `tool:goal` policy section, at DSH's own order (`TOOL_GOAL` = 2400);
//    * the three tool descriptions and their parameter schemas;
//    * the compare-and-set ref handling — `get_goal` first, then `update_goal`
//      with the exact `goal_id` and `revision` it returned.
//
//  The authority rule DSH enforces with an event scan is one line here: every
//  turn in this app starts from something the human typed, and the one path that
//  does not — an automatic continuation round — does not exist until a round
//  driver does. So `create`/`edit`/`pause`/`resume`, which DSH restricts to a
//  direct human turn, need no extra check; the check is added with the driver.
//
//  Output is canonical compact JSON, matching DSH's `goalValue` verbatim — the
//  model reads this shape, and `goal: null` is how it learns there is no goal.
//

import Foundation

/// Whether this process may automatically continue the current goal.
enum DSHActivation: String {
    case armed
    case disarmed
}

/// Compare-and-set identity for one exact goal revision.
struct DSHGoalRef: Equatable {
    let id: String
    let revision: Int
}

/// One goal, as the tools and the bar report it.
struct DSHGoalView: Equatable {
    let id: String
    let revision: Int
    let objective: String
    let phase: DSHGoal.Phase
    let roundsStarted: Int
    let maxGoalRounds: Int
    let blockedReason: DSHGoal.BlockReason?
    let activation: DSHActivation

    init(goal: DSHGoal, activation: DSHActivation) {
        self.id = goal.id
        self.revision = goal.revision
        self.objective = goal.objective
        self.phase = goal.phase
        self.roundsStarted = goal.roundsStarted
        self.maxGoalRounds = goal.maxGoalRounds
        self.blockedReason = goal.blockedReason
        self.activation = activation
    }
}

/// Every way a goal operation can be refused, carrying the text the model reads.
enum DSHGoalError: Error {
    case notFound
    case alreadyExists(DSHGoal)
    case stale(DSHGoalRef, DSHGoal?)
    case invalidObjective
    case invalidMaxRounds
    case invalidBlockReason
    case invalidEdit
    case invalidTransition(DSHGoal, String)
    case resumePaused(DSHGoal)
    case alreadyArmed(DSHGoal)
    case roundsExhausted(DSHGoal)
    case blockThreshold(DSHGoal)

    /// DSH's phrasing, so a model that was trained on the upstream messages sees
    /// the same rejection it would there.
    var message: String {
        switch self {
        case .notFound:
            return "No goal is currently set."
        case .alreadyExists(let current):
            return "A goal is already \(current.phase.rawValue) (id \"\(current.id)\"); "
                + "edit it, or clear it before replacing it."
        case .stale(let ref, let current):
            guard let current else {
                return "Stale goal ref \"\(ref.id)\" revision \(ref.revision); there is no current goal."
            }
            return "Stale goal ref \"\(ref.id)\" revision \(ref.revision); "
                + "current is \"\(current.id)\" revision \(current.revision). Read the current goal first."
        case .invalidObjective:
            return "The goal objective must be a non-empty string."
        case .invalidMaxRounds:
            return "max_goal_rounds must be a positive integer."
        case .invalidBlockReason:
            return "blocked_reason must be a non-empty explanation of the blocking condition."
        case .invalidEdit:
            return "A goal edit requires objective and/or max_goal_rounds."
        case .invalidTransition(let current, let operation):
            return "Cannot \(operation) goal \"\(current.id)\" from phase \"\(current.phase.rawValue)\"."
        case .resumePaused(let current):
            return "The goal \"\(current.id)\" is paused; the user must resume it."
        case .alreadyArmed(let current):
            return "The goal \"\(current.id)\" is already active and armed."
        case .roundsExhausted(let current):
            return "The goal \"\(current.id)\" exhausted \(current.maxGoalRounds) goal rounds; "
                + "raise max_goal_rounds before resuming."
        case .blockThreshold(let current):
            return "blocked requires at least \(DSHGoalStore.blockedAfterConsecutiveRounds) consecutive goal rounds; "
                + "the current round is \(current.roundsStarted)."
        }
    }
}

/// The three goal tools.
enum DSHGoalTools {

    /// Where the policy section sits. DSH's `TOOL_GOAL`, which is well behind the
    /// plan rules at 500 — a goal does not change what is allowed, only whether
    /// work continues, so it must not outrank the mode that does.
    static let sectionOrder = 2400

    /// The section registered for the life of every turn.
    ///
    /// Registered whether or not a goal exists, and rendering the policy either
    /// way — DSH holds the section in place for request-cache stability, and an
    /// objective that appears mid-conversation would otherwise change the shape
    /// of the request it appears in.
    static func policySection() -> DSHPromptSection {
        DSHPromptSection(name: "tool:goal", order: sectionOrder, text: policyText)
    }

    /// DSH's policy text, verbatim, plus one paragraph this app needs and DSH does
    /// not have.
    ///
    /// Source: `packages/goal/tool-goal/src/index.ts`, `guidance()`, at the tag
    /// `dsh-v0.2.1-rc.2` (upstream `dsh-checkout`). The authority for the wording
    /// is what a real request carries, not this port — the model was tuned against
    /// it — and that is checkable in the same checkout:
    /// `snapshots/web/cordis-tool-round/system-prompt.expected.md:25` is the
    /// composed prompt, and this string is its line for line, including the `3`
    /// (the interpolation of `blockedAfterConsecutiveRounds`).
    ///
    /// The added paragraph is the goal/todo boundary. DSH leaves it implicit, and
    /// here it cannot be: `todo_write` in this app survives the turn (see
    /// `DSHTodoStore`), so a model that reads "there is a long-running objective"
    /// as "there is a task list to keep up to date" would replace the plan with
    /// the objective. The two axes are different — a goal is what should be true
    /// when the work ends, a todo is the step being worked on now — and one does
    /// not stand in for the other.
    static let policyText = """
    Use goal tools for one long-running completion objective in the current session. create_goal may infer goal intent from a direct human request in any language; do not create a goal for routine single-turn work. Call get_goal before update_goal and copy its exact goal_id and revision. After session resume or fork, an active goal is disarmed: when a human asks to continue or resume in any wording or language, use update_goal action resume to rearm it. Mark complete only when the objective is actually achieved. Mark blocked only after the same blocking condition persists for at least \(DSHGoalStore.blockedAfterConsecutiveRounds) consecutive goal rounds, and report that concrete condition in blocked_reason; difficulty, uncertainty, or useful remaining work is not blocked.

    A goal and a todo list are different axes and one does not replace the other. The goal is the completion objective that outlives a single turn; use todo_write for the steps inside the current work, and let the list carry the sequence the goal is currently at. Do not restate the objective as a todo, and do not close the goal because the list is finished.
    """

    // MARK: - Roster

    /// The names `run` answers, written once so the roster can be checked against
    /// them at launch rather than at the first wrong call.
    private static let createdNames = ["get_goal", "create_goal", "update_goal"]

    /// The three goal tool definitions, in the shape this app's roster uses.
    ///
    /// Declared here rather than in `makeAgentTools()` because the two iOS lines
    /// keep separate copies of that file, and a schema that has to stay identical
    /// between them should not exist twice. `tool_title` is this app's addition —
    /// every other tool in the roster carries it, and it drives the live pill
    /// header.
    static var definitions: [AgentToolDefinition] {
        // A roster that drifts from the dispatcher would be silent on both sides:
        // the model would call a tool by a name the switch below does not know
        // ("Unknown tool"), or never see a tool that exists. The names are few and
        // fixed, so the mismatch is made a compile error instead.
        guard createdNames == ["get_goal", "create_goal", "update_goal"] else {
            compileError("DSHGoalTools.definitions names drifted from DSHGoalTools.run")
        }
        return [
            AgentToolDefinition(
                name: "get_goal",
                description: getDescription,
                parameters: [
                    "tool_title": AgentToolParam(
                        type: .string,
                        description: "A concise 5-10 word summary shown to the user, e.g. 'Check the goal'. Use the same language as the user."
                    ),
                ],
                required: [],
                propertyOrdering: ["tool_title"]
            ),
            AgentToolDefinition(
                name: "create_goal",
                description: createDescription,
                parameters: createParameters,
                required: ["objective"],
                propertyOrdering: ["tool_title", "objective", "max_goal_rounds"]
            ),
            AgentToolDefinition(
                name: "update_goal",
                description: updateDescription,
                parameters: updateParameters,
                required: ["goal_id", "revision", "action"],
                propertyOrdering: [
                    "tool_title", "goal_id", "revision", "action",
                    "objective", "max_goal_rounds", "blocked_reason",
                ]
            ),
        ]
    }

    // MARK: - Descriptions

    /// DSH's `CREATE_DESCRIPTION`, with the clause that says what "long-running"
    /// means here. The extra sentence costs nothing and is the difference between
    /// a goal on every request and a goal on the requests that need one.
    static let createDescription =
        "Create a persisted goal that keeps this session working across automatic continuation rounds. "
        + "Use it when the direct human request is a long-running objective, even if the user did not say \"goal\"; "
        + "not for single-turn work. "
        + "A goal is refused for a single question, a one-step edit, or anything the user expects an answer to now."

    static let getDescription =
        "Read the current session goal, including the id and revision that update_goal requires."

    static let updateDescription =
        "Update the current goal. Call get_goal first and pass its exact goal_id and revision. "
        + "edit, pause and resume need a direct request from the user; complete and blocked also work during a "
        + "continuation of this goal, and blocked is refused before the configured minimum round count."

    // MARK: - Parameters

    static let createParameters: [String: AgentToolParam] = [
        "tool_title": AgentToolParam(
            type: .string,
            description: "A concise 5-10 word summary shown to the user, e.g. 'Set the goal for the migration'. Use the same language as the user."
        ),
        "objective": AgentToolParam(
            type: .string,
            description: "The concrete completion objective inferred from the direct human request."
        ),
        "max_goal_rounds": AgentToolParam(
            type: .integer,
            description: "Optional round cap, in automatic continuation rounds. Omit unless the task needs more rounds than the default."
        ),
    ]

    static let updateParameters: [String: AgentToolParam] = [
        "tool_title": AgentToolParam(
            type: .string,
            description: "A concise 5-10 word summary shown to the user, e.g. 'Mark the goal complete'. Use the same language as the user."
        ),
        "goal_id": AgentToolParam(
            type: .string,
            description: "Exact id returned by get_goal."
        ),
        "revision": AgentToolParam(
            type: .integer,
            description: "Exact positive revision returned by get_goal."
        ),
        "action": AgentToolParam(
            type: .string,
            description: "edit (replace objective and/or max_goal_rounds), pause, resume, complete, blocked.",
            enumValues: ["edit", "pause", "resume", "complete", "blocked"]
        ),
        "objective": AgentToolParam(
            type: .string,
            description: "Replacement objective; valid only with action edit."
        ),
        "max_goal_rounds": AgentToolParam(
            type: .integer,
            description: "Replacement cap; valid only with action edit."
        ),
        "blocked_reason": AgentToolParam(
            type: .string,
            description: "Required only with action blocked: the concrete condition that persisted across rounds and blocks progress. Report the condition itself, not how hard the work is."
        ),
    ]

    // MARK: - Execution

    /// Execute one goal tool call.
    ///
    /// - Returns: the canonical goal JSON, or the reason the call was refused.
    ///   A refusal is a failure on purpose: `update_goal`'s success value is what
    ///   tells the model its phase change was durable.
    static func run(name: String, arguments: [String: Any]) -> DSHToolOutcome {
        do {
            switch name {
            case "get_goal":
                return .ok(valueJSON(DSHGoalStore.shared.view))
            case "create_goal":
                guard let objective = arguments["objective"] as? String else {
                    return .failed("create_goal requires an `objective` string.")
                }
                let cap = try positiveInteger(arguments["max_goal_rounds"])
                return .ok(valueJSON(try DSHGoalStore.shared.create(objective: objective, maxGoalRounds: cap)))
            case "update_goal":
                return try update(arguments)
            default:
                return .failed("Unknown goal tool '\(name)'.")
            }
        } catch let error as DSHGoalError {
            return .failed(error.message)
        } catch {
            return .failed("\(error)")
        }
    }

    /// `update_goal`, with DSH's argument validation in DSH's order.
    ///
    /// The order matters and is not incidental: each check answers a call that
    /// would otherwise change something the wrong way, so the first thing the
    /// model is told is the first thing it got wrong.
    private static func update(_ arguments: [String: Any]) throws -> DSHToolOutcome {
        guard let rawId = arguments["goal_id"] as? String else {
            return .failed("update_goal requires a `goal_id` string from get_goal.")
        }
        let id = rawId
        guard !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .failed("goal_id must be a non-empty, untrimmed id from get_goal.")
        }
        guard let revision = try positiveInteger(arguments["revision"]) else {
            return .failed("update_goal requires a positive `revision` from get_goal.")
        }
        guard let action = arguments["action"] as? String,
              ["edit", "pause", "resume", "complete", "blocked"].contains(action) else {
            return .failed("update_goal requires an `action` of edit, pause, resume, complete or blocked.")
        }
        let ref = DSHGoalRef(id: id, revision: revision)
        let objective = text(arguments["objective"])
        let cap = try positiveInteger(arguments["max_goal_rounds"])
        let blockedReason = text(arguments["blocked_reason"])
        let hasReplacements = objective != nil || cap != nil

        switch action {
        case "edit":
            guard blockedReason == nil else {
                return .failed("blocked_reason is valid only with action blocked.")
            }
            guard hasReplacements else {
                return .failed("Action edit requires objective and/or max_goal_rounds.")
            }
            return .ok(valueJSON(try DSHGoalStore.shared.edit(ref: ref, objective: objective, maxGoalRounds: cap)))

        case "pause", "resume":
            guard !hasReplacements, blockedReason == nil else {
                return .failed("objective and max_goal_rounds are valid only with action edit; "
                    + "blocked_reason is valid only with action blocked.")
            }
            let view = action == "pause"
                ? try DSHGoalStore.shared.pause(ref: ref)
                : try DSHGoalStore.shared.resume(ref: ref)
            return .ok(valueJSON(view))

        default:
            guard !hasReplacements else {
                return .failed("objective and max_goal_rounds are valid only with action edit.")
            }
            if action == "complete", blockedReason != nil {
                return .failed("blocked_reason is valid only with action blocked.")
            }
            if action == "blocked" {
                guard let blockedReason else {
                    return .failed("blocked_reason is required with action blocked.")
                }
                guard let current = DSHGoalStore.shared.goal else { throw DSHGoalError.notFound }
                // Only an automatic continuation can have spent round 3, so on a
                // human turn this check cannot fire. It is written anyway, because
                // it is what stops the threshold from quietly disappearing the
                // moment a round driver exists.
                if current.roundsStarted < DSHGoalStore.blockedAfterConsecutiveRounds {
                    throw DSHGoalError.blockThreshold(current)
                }
                let code = "model-reported"
                return .ok(valueJSON(try DSHGoalStore.shared.block(
                    ref: ref,
                    reason: DSHGoal.BlockReason(code: code, message: blockedReason)
                )))
            }
            return .ok(valueJSON(try DSHGoalStore.shared.complete(ref: ref)))
        }
    }

    // MARK: - Rendering

    /// What `/goal` prints: DSH's own report, line for line.
    ///
    /// Not localized, and deliberately so. DSH's `/goal` output is
    /// `Status: active` / `Rounds: 0/5` with the command hint under it; a
    /// translated copy would have to invent nine translations of "Activation:" for
    /// a line whose only reader is the person who just typed the command, and the
    /// phase words are already the vocabulary the tool JSON uses.
    static func statusReport() -> String {
        guard let view = DSHGoalStore.shared.view else {
            return "No goal is currently set.\nUsage: /goal"
        }
        var lines = ["Goal", "Status: \(view.phase.rawValue)"]
        if let reason = view.blockedReason {
            lines.append("Blocker: \(reason.code): \(reason.message)")
        }
        lines.append("Objective: \(view.objective)")
        lines.append("Rounds: \(view.roundsStarted)/\(view.maxGoalRounds)")
        lines.append("Activation: \(view.activation.rawValue)")
        lines.append("")
        lines.append("Commands: \(commandHint(view))")
        return lines.joined(separator: "\n")
    }

    /// The commands that are meaningful from one exact live state — DSH's
    /// `commandHint`, with `complete` and `blocked` named as well, because here
    /// the model performs those and the user can ask for them in prose.
    private static func commandHint(_ view: DSHGoalView) -> String {
        switch view.phase {
        case .active:
            return view.activation == .armed
                ? "/goal (show), or ask for an edit, pause or clear"
                : "/goal (show), or ask to resume, edit or clear"
        case .paused, .blocked:
            return "/goal (show), or ask to resume, edit or clear"
        case .complete:
            return "/goal (show), or describe a new objective to replace it"
        }
    }

    /// DSH's `goalValue`, byte for byte in shape:
    /// `{"goal":null}` or `{"goal":{…},"activation":"armed|disarmed"}`.
    ///
    /// `activation` sits outside `goal` because it is an observation of this
    /// process, not a field of the durable goal. Sorted keys rather than a
    /// hand-ordered string: the value is a dictionary either way, and a stable
    /// order costs nothing to guarantee.
    static func valueJSON(_ view: DSHGoalView?) -> String {
        guard let view else {
            return encode(["goal": NSNull()])
        }
        var goal: [String: Any] = [
            "id": view.id,
            "revision": view.revision,
            "objective": view.objective,
            "phase": view.phase.rawValue,
            "roundsStarted": view.roundsStarted,
            "maxGoalRounds": view.maxGoalRounds,
        ]
        if let reason = view.blockedReason {
            goal["blockedReason"] = ["code": reason.code, "message": reason.message]
        }
        return encode(["goal": goal, "activation": view.activation.rawValue])
    }

    private static func encode(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"goal":null}"#
        }
        return text
    }

    // MARK: - Argument types

    /// An optional positive integer, from a JSON number of either shape.
    ///
    /// The app's schema has no `number` type, so a numeric argument arrives as an
    /// integer — but a provider that sends `3` where the schema said integer is
    /// not guaranteed, and a `Double` that is exactly integral is the same
    /// instruction. Anything else is a rejected call, not a coerced one.
    private static func positiveInteger(_ raw: Any?) throws -> Int? {
        guard let raw else { return nil }
        if let value = raw as? Int { return try check(value) }
        if let value = raw as? Double, value == value.rounded(), value >= 1 {
            return try check(Int(value))
        }
        if let value = raw as? String, let parsed = Int(value) { return try check(parsed) }
        throw DSHGoalError.invalidMaxRounds
    }

    private static func check(_ value: Int) throws -> Int {
        guard value >= 1 else { throw DSHGoalError.invalidMaxRounds }
        return value
    }

    /// A meaningful optional string. DSH treats a strict-schema empty filler as
    /// absent, so `""` never counts as a replacement objective or a block reason.
    private static func text(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Fail the build for a condition decidable in source. `fatalError` taking an
    /// autoclosure is what makes the call site a compile-time check: the closure
    /// returns `Never`, so the call is a statement that cannot fall through.
    private static func compileError(_ message: @autoclosure () -> String) -> Never {
        fatalError(message())
    }
}
