//
//  DSHTurnDriver.swift
//  Minis
//
//  The agent loop, ported from DeepSeek Harness
//  (packages/core/agent-loop/src/agent.ts, tool-calls.ts).
//
//  This replaces OpenMinis' `runAgentLoop()`. What it keeps is the iOS
//  presentation contract: the same provider seam, the same stream events, the
//  same delegate callbacks the UI already renders. What it replaces is the
//  decision core:
//
//  - Requests are derived from the session surface, not from a mutable array
//    indexed by a counter. A compaction landing mid-turn cannot desynchronize
//    the request from the conversation, because the surface is recomputed from
//    the log each step.
//  - Tool calls are scheduled by declared concurrency mode — exclusive calls
//    form a barrier, parallel calls run in a bounded pool — and results commit
//    in model order regardless of which call finished first.
//  - Loop guards run before a call fires, so a repeated no-progress call is
//    blocked with a concrete reason instead of burning several rounds first.
//  - Compaction is selected by DSH's rule (system head excluded, recent tail
//    retained, cut walked to a tool-pairing balanced position) rather than by
//    walking user turns backwards and hoping the boundary is safe.
//
//  The driver holds no UIKit types and no `ChatStore` references. Persistence
//  and rendering stay in the presentation layer, which observes the delegate.
//

import Foundation

// MARK: - Turn End Reason

/// Why a turn ended.
public enum DSHTurnEndReason: Sendable {
    /// The model produced no further tool calls.
    case completed
    /// The driver was cancelled.
    case cancelled
    /// The step ceiling was reached.
    case maxSteps
    /// A tool result concluded the turn early.
    case concluded
    /// The model's own output ceiling cut a response short.
    ///
    /// A reason of its own, not the step ceiling it used to be mapped onto. DSH
    /// lists `max-tokens` separately from every other outcome
    /// (`packages/core/session/src/types.ts`, `TurnEndReason`) because the two
    /// facts are different: the step ceiling means the loop chose to stop, this
    /// means the MODEL was truncated mid-answer and the text is incomplete. The
    /// two also point at different fixes (Resume continues a truncated answer; a
    /// step-ceiling hit means the turn fanned out for too long), so an end reason
    /// cannot stand in for the other.
    ///
    /// Sticky for the turn: see `sawTruncatedStep`.
    case maxTokens
}

// MARK: - Delegate

/// The driver's view of the outside world.
///
/// Isolated to the main actor: every callback drives UI or persistence, both of
/// which are main-actor state in this app.
@MainActor
public protocol DSHTurnDriverDelegate: AnyObject {
    /// A step started.
    func driver(_ driver: DSHTurnDriver, didStartStep turn: Int, step: Int)
    /// A text delta arrived.
    func driver(_ driver: DSHTurnDriver, didEmitText text: String)
    /// A reasoning delta arrived.
    func driver(_ driver: DSHTurnDriver, didEmitReasoning text: String)
    /// A tool call started.
    func driver(_ driver: DSHTurnDriver, willRunTool name: String, callId: String, arguments: [String: Any])
    /// A tool call settled.
    func driver(_ driver: DSHTurnDriver, didFinishTool name: String, callId: String, result: DSHToolExecutionResult)
    /// Token usage was reported.
    func driver(_ driver: DSHTurnDriver, didReportUsage usage: DSHTokenUsage)
    /// The surface was compacted.
    func driver(_ driver: DSHTurnDriver, didCompact outcome: DSHCompactionOutcome)
    /// The turn ended.
    func driver(_ driver: DSHTurnDriver, didEndTurn reason: DSHTurnEndReason)
    /// The turn failed.
    func driver(_ driver: DSHTurnDriver, didFail failure: DSHFailure)
    /// Opening the stream failed with a retryable error and will be retried.
    func driver(_ driver: DSHTurnDriver, willRetryStreamAfter error: Error, attempt: Int, seconds: Int)
    /// Countdown tick for a pending stream retry. `0` means the stream opened.
    func driver(_ driver: DSHTurnDriver, streamRetryCountdown seconds: Int)
}

// MARK: - Configuration

/// Driver configuration. Deployment-varying values are fields, not constants.
public struct DSHTurnDriverConfig: Sendable {
    /// Bound on the parallel tool pool.
    public var maxParallelToolCalls: Int
    /// Maximum steps in one turn before the driver stops and reports, or nil for
    /// no step ceiling at all.
    ///
    /// nil is the shipped default and it is upstream's own shape. DSH's turn loop
    /// is a `while (true)` whose only exits are an empty next step, a cancel, and
    /// the pressure/overflow machinery
    /// (`packages/core/agent-loop/src/agent.ts`); it names no step budget, because
    /// a turn's real bound is the context window it has to fit in. Porting the
    /// ceiling in as 200 steps made a heavy turn report "Reached the step limit
    /// for this turn" as if it had failed, while the two facts it was standing in
    /// for — context pressure and a repeated no-progress call — were already
    /// checked directly. `DSHTurnEndReason.maxSteps` therefore still exists and is
    /// still reported, but only when a caller sets a ceiling on purpose.
    ///
    /// A ceiling of nil does NOT remove the loop's exits: `cancelled` is checked
    /// at the top of every step, `compactForPressure` runs before every request,
    /// the loop guard blocks repeated identical calls, and `restlessStepLimit`
    /// bounds a turn that never converges or terminates.
    public var maxStepsPerTurn: Int?
    /// Output tokens ONE request of this turn is allowed to emit — the number that
    /// reaches the provider as `max_tokens` / `max_completion_tokens` /
    /// `max_output_tokens`, and the number the compaction gate reserves inside the
    /// context window.
    ///
    /// [T-output-limit-three-hops] Resolved ONCE by
    /// `AIChatViewModel.dynamicMaxTokens` (user override → endpoint/catalog cap →
    /// `provider.defaultMaxTokens`, then clamped to the global ceiling and to the
    /// window actually left) and frozen here for the whole turn, so no step of a
    /// turn can send something the gate did not reserve for.
    ///
    /// THE ONE NUMBER, TWO NAMES — deliberately. This field used to be
    /// `maxTokens`, and one name for two jobs reads as one fact when it is two:
    /// the request's cap and the output budget the pressure threshold withholds
    /// (`min(W × thresholdRatio, W − O − headroom)`). The device log from
    /// 2026-10-19 is what makes that confusion expensive — `reserved=8192` beside
    /// `threshold=188416` reads as a policy knowingly withholding 8k, while the
    /// request was in fact capped at 8192 by a catalog default nobody chose (see
    /// `ModelsDevAPI.applyDevData`). Both names are computed views on the SAME
    /// stored property, which is what makes "they can never disagree" a property
    /// of the type rather than a convention:
    ///
    ///   * `requestMaxOutputTokens` — read it where the value becomes wire data
    ///     (`streamAgentMessageClamped(maxTokens:)`).
    ///   * `reservedOutputTokens` — read it where the value becomes a budget
    ///     (`PricedRequest.reservedCompletionTokens` → `resolveSpec`).
    public let maxTokens: Int
    /// The request's output cap, under the name that says so. See `maxTokens`.
    public var requestMaxOutputTokens: Int { maxTokens }
    /// The output tokens the compaction gate reserves. See `maxTokens`.
    public var reservedOutputTokens: Int { maxTokens }
    /// Extended-thinking level for this conversation.
    ///
    /// Resolved by the caller from the session's inference config and clamped to
    /// what the serving model accepts. It is a field rather than a constant
    /// because hardcoding `.off` here turned thinking off for every DSH turn —
    /// silently, and for models whose whole point is reasoning.
    public var thinkingLevel: ThinkingLevel
    /// Whether loop guards run before each tool call.
    public var enableLoopGuard: Bool
    /// Loop-guard warning threshold (repeated identical calls).
    public var loopWarningThreshold: Int
    /// Loop-guard critical threshold.
    public var loopCriticalThreshold: Int
    /// Hard stop for a turn that is neither converging nor ending.
    ///
    /// NOT a turn budget and not a user-facing setting: it exists so "no step
    /// ceiling" cannot become an unbounded loop when the model keeps producing
    /// tool calls that all do something (so the loop guard, which keys on
    /// REPEATED calls, never fires) and none of them concludes the turn. It is
    /// set far above any real turn — a 262k-window conversation at 1k tokens per
    /// step is under 300 steps before context pressure ends it — so it reports a
    /// genuine runaway rather than a long task.
    public var restlessStepLimit: Int
    /// Trigger policy: the pressure threshold and the retained-tail budget this
    /// conversation resolves against the serving model's capacity.
    ///
    /// DSH splits the trigger into a policy (`compaction-basic`'s resolved
    /// config) and a capacity (`resolveCompactSpec`'s `contextWindow` argument).
    /// These two fields are that pair.
    public var compactionPolicy: DSHCompactionPolicy
    /// Adapter-resolved capacity of the routed model, or nil when none is known.
    ///
    /// nil leaves proactive pressure compaction off rather than compacting on a
    /// guess — DSH reports the same case as a target configuration error and
    /// warns once per route. Provider-confirmed overflow recovery stays
    /// available either way, because that trigger needs no capacity at all: the
    /// provider has already told us the request did not fit.
    public var contextWindow: Int?
    /// Absolute pressure threshold, replacing the policy's derived one.
    ///
    /// An override moves *when* a compaction fires, never what it keeps. It
    /// exists so the pressure path can be exercised on a device whose window is
    /// too large to fill by hand; a released build leaves it nil.
    public var compactionPressureTokensOverride: Int?
    /// Absolute retained-tail budget, replacing the policy's derived one.
    public var compactionRetainTokensOverride: Int?
    /// Whether automatic compaction is enabled.
    public var autoCompactionEnabled: Bool
    /// Ordered tool names, with the rest marker exactly once. nil means
    /// lexicographic order.
    public var toolOrder: [String]?

    /// The shipped runaway bound. See `restlessStepLimit`.
    public static let shippedRestlessStepLimit = 1_000

    /// The conversation this turn belongs to, or nil for a draft with no id yet.
    ///
    /// The context readout stores (`DSHContextBreakdownStore`,
    /// `DSHContextUsageStore`) are process-global and the app switches
    /// conversations inside one process, so every figure they hold has to carry
    /// its owner. Without this a new chat opened on the previous chat's measured
    /// occupancy, and the sheet's rows could be paired with another session's
    /// provider receipt. A field rather than a read of some ambient "current
    /// session", because the driver is built per turn and must not observe a
    /// switch that happened after it was constructed.
    public var sessionKey: String?

    /// Backoff before retrying a retryable stream failure. Empty disables retry.
    ///
    /// The driver owns the loop and the host owns transport policy, but the
    /// policy is passed as data plus delegate callbacks rather than a closure:
    /// this config is `Sendable`, and a `@Sendable` closure reaching back into a
    /// main-actor view model would have to be re-isolated on every call.
    ///
    /// Retry exists because the legacy loop had it: `streamWithAutoRetry` waits
    /// these same five delays out on `LLMError.isRetryable` (network, 5xx) and
    /// shows a countdown. Without it a two-second network blip ended the turn
    /// with an error banner where the app previously recovered invisibly.
    /// Whether the memory feature is on for this session. The volatile tail
    /// block is assembled on the app side and needs the same answer.
    public var memoryEnabled: Bool = true
    public var streamRetryDelays: [Int]

    public init(
        maxParallelToolCalls: Int = 4,
        maxStepsPerTurn: Int? = nil,
        maxTokens: Int = 16_384,
        thinkingLevel: ThinkingLevel = .off,
        enableLoopGuard: Bool = true,
        loopWarningThreshold: Int = 10,
        loopCriticalThreshold: Int = 20,
        restlessStepLimit: Int = DSHTurnDriverConfig.shippedRestlessStepLimit,
        compactionPolicy: DSHCompactionPolicy = DSHCompactionPolicy(),
        contextWindow: Int? = nil,
        compactionPressureTokensOverride: Int? = nil,
        compactionRetainTokensOverride: Int? = nil,
        autoCompactionEnabled: Bool = true,
        toolOrder: [String]? = nil,
        sessionKey: String? = nil,
        memoryEnabled: Bool = true,
        streamRetryDelays: [Int] = [3, 5, 10, 15, 30]
    ) {
        self.maxParallelToolCalls = max(1, maxParallelToolCalls)
        // A ceiling that is not a ceiling: 0 and negative values are the "no
        // limit" request spelled wrong, and clamping them to 1 would stop the turn
        // on its first step. Only a positive value is a ceiling.
        self.maxStepsPerTurn = maxStepsPerTurn.flatMap { $0 > 0 ? $0 : nil }
        // [T-output-limit-three-hops] The default is `provider.defaultMaxTokens`
        // for an OpenAI-compatible chat-completions endpoint
        // (`OpenAIAgentProvider`) — the same fallback the request path resolves to
        // when neither the user nor the endpoint states a cap. It is NOT a
        // model-capability claim: the caller always passes the resolved
        // `dynamicMaxTokens`, and this default only has to be the honest value for
        // the case where nothing resolved at all. It was 32_000, which is a number
        // no shipped provider declares; a default that no provider would ever
        // produce is how "reserved 16–32k, capped at 8k" could go unnoticed.
        self.maxTokens = maxTokens
        self.thinkingLevel = thinkingLevel
        self.enableLoopGuard = enableLoopGuard
        self.loopWarningThreshold = max(1, loopWarningThreshold)
        self.loopCriticalThreshold = max(self.loopWarningThreshold + 1, loopCriticalThreshold)
        self.restlessStepLimit = max(199, restlessStepLimit)
        self.compactionPolicy = compactionPolicy
        if let contextWindow, contextWindow > 0 {
            self.contextWindow = contextWindow
        } else {
            self.contextWindow = nil
        }
        self.compactionPressureTokensOverride = compactionPressureTokensOverride.flatMap {
            $0 > 0 ? $0 : nil
        }
        self.compactionRetainTokensOverride = compactionRetainTokensOverride.flatMap {
            $0 >= 0 ? $0 : nil
        }
        self.autoCompactionEnabled = autoCompactionEnabled
        self.toolOrder = toolOrder
        self.sessionKey = sessionKey
        self.memoryEnabled = memoryEnabled
        self.streamRetryDelays = streamRetryDelays.filter { $0 > 0 }
    }
}

// MARK: - Driver

/// Drives one session through turn and step boundaries.
///
/// Main-actor isolated rather than an actor: the providers it drives are
/// main-actor types, and every delegate callback touches main-actor state.
/// Keeping one isolation domain avoids `Sendable` annotations on provider state
/// that is not `Sendable`.
@MainActor
public final class DSHTurnDriver {

    private let provider: any AgentProvider
    private let registry: DSHToolRegistry
    private let prompt: DSHSystemPrompt
    private let session: DSHSession
    private var config: DSHTurnDriverConfig

    /// Loop-guard state, one instance per driver so counters accumulate across a
    /// turn's steps.
    private let gate: DSHToolGate

    private var currentTurn = 0
    private var isRunning = false
    private var cancelled = false

    /// The last request envelope the provider priced, and the surface it was
    /// priced against.
    ///
    /// DSH's pressure check prices the latest *durable routed request* — the
    /// request header in its session log — together with the current surface.
    /// This app has no request log, so the driver keeps the two facts that stand
    /// in for one: the prompt tokens the provider itself counted for the last
    /// request (or the character-based envelope estimate when the adapter
    /// reported no usage), and the surface total at that moment, which is added
    /// to so growth since the request still counts.
    ///
    /// Seeded from the envelope the turn is about to send, then replaced by what
    /// each request actually reported. DSH reads the equivalent figure out of the
    /// previous turn's durable request header; a driver constructed per turn has
    /// no such header, so it measures instead — which also lets the first step of
    /// a turn compact, where DSH has nothing to price yet.
    private var lastPricedRequest: PricedRequest?

    /// One routed request's priced envelope.
    /// Why a provider-counted seed was refused.
    ///
    /// `Result` needs an `Error`, and the reasons here are sentences meant for the log line
    /// rather than typed failures anything switches on.
    private struct DSHSeedRefusal: Error, CustomStringConvertible {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var description: String { reason }
    }

    private struct PricedRequest {
        /// Prompt tokens the provider counted, or the estimated envelope total.
        let promptTokens: Int
        /// Output tokens the request reserved inside the window.
        let reservedCompletionTokens: Int
        /// Surface tokens the envelope was measured with.
        let surfaceTokens: Int
        /// The WHOLE envelope this request was priced at — system prompt, tool
        /// roster and surface — in the same units as `DSHContextBreakdown
        /// .estimatedTotal`.
        ///
        /// [T-ctx-usage-one-denominator] Zero means "not stated", and the only
        /// constructions that leave it zero are the compaction seed's, which never
        /// reach the usage store.
        ///
        /// It exists because two consumers price the same request: the compaction
        /// gate wants the SURFACE (it is the only part a compaction can shrink),
        /// while `DSHContextUsageStore`'s growth projection needs the whole
        /// envelope (it compares `envelopeNow` against the envelope the provider's
        /// count was taken at). Handing the surface to the second consumer made
        /// every projection overstate by system + tools — the device's own numbers
        /// put that head at 17,006 tokens, 6.2pp of a 262,144 window. The two
        /// denominators are now two fields instead of one field used twice.
        ///
        /// `var` only so the memberwise initializer keeps a default (a `let` with
        /// an initial value is dropped from it); nothing mutates it after
        /// construction.
        var envelopeTokens: Int = 0
        /// Whether `promptTokens` is the provider's own count.
        ///
        /// A diagnostic fact, not a decision input: the threshold is compared
        /// against the same number either way, because an unpriced envelope is
        /// the only thing a first step has and refusing to gate on it would let
        /// that step overflow. What it changes is what the log may CLAIM. The
        /// 2026-10-18 log printed `measured=192122` for a number this app had
        /// computed, in a message set whose every other figure it had also
        /// invented — which is how a 2.44×-low estimate came to be read as the
        /// engine's own measurement.
        let isProviderCount: Bool
    }

    /// Provider-confirmed overflow recoveries spent in this turn.
    private var overflowRetries = 0
    /// Whether a step of this turn was cut off by the model's output ceiling.
    ///
    /// [P1-2] DSH's `max-tokens` is STICKY for the whole turn — "max-tokens is
    /// sticky: once any step hits the ceiling, later steps that complete normally
    /// must not downgrade the turn outcome" (`packages/core/agent-loop/src/agent.ts`).
    /// A per-step variable cannot carry that: this driver resets `stopReason` for
    /// every attempt, which is exactly where the fact used to be lost — a turn
    /// whose seventh step was truncated and whose eighth step completed normally
    /// reported `.completed`, and the truncation vanished from both the UI and the
    /// session log. One flag per turn, reset with the other per-turn counters.
    private var sawTruncatedStep = false
    /// Routes whose pressure configuration has already been reported.
    private var warnedPressureTargets = Set<String>()
    /// Skip reasons already reported this turn, so a surface that repeats the same
    /// refusal on every step logs it once instead of once per step.
    private var reportedSkips = Set<String>()

    public weak var delegate: (any DSHTurnDriverDelegate)?

    /// Post-execute overflow handler applied to every settled tool result
    /// ([T-dsh-spill]).
    ///
    /// The seam DSH hangs `spill-policy` on. Installed once per turn by the
    /// presentation layer, which is the only side that knows the session's
    /// storage bucket; nil — the default — leaves the tool path exactly as it
    /// was, with no branch taken.
    public var spillHook: DSHResultOverflowHook?

    /// `AgentProvider` is internal to the Minis target, so this initializer is
    /// internal too — the driver is not a public API surface.
    init(
        provider: any AgentProvider,
        registry: DSHToolRegistry,
        prompt: DSHSystemPrompt,
        session: DSHSession,
        config: DSHTurnDriverConfig = DSHTurnDriverConfig()
    ) {
        self.provider = provider
        self.registry = registry
        self.prompt = prompt
        self.session = session
        self.config = config
        self.gate = DSHToolGate(
            enabled: config.enableLoopGuard,
            warningThreshold: config.loopWarningThreshold,
            criticalThreshold: config.loopCriticalThreshold
        )
    }

    // MARK: - Configuration

    public func updateConfig(_ config: DSHTurnDriverConfig) {
        self.config = config
    }

    /// The trigger budget this driver will apply to its next request.
    ///
    /// Exposed so a host can display the threshold that is actually in force
    /// rather than restating the policy and hoping the two agree. nil means no
    /// capacity is known, which is the same condition under which the driver
    /// leaves proactive pressure compaction off.
    ///
    /// - Parameter reservedCompletionTokens: output tokens the request reserves.
    /// - Returns: the resolved pressure and retention budgets, or nil.
    public func resolvedCompactionSpec(reservedCompletionTokens: Int) -> DSHCompactionSpec? {
        try? resolveSpec(reservedCompletionTokens: reservedCompletionTokens)
    }

    // MARK: - Turn

    /// Cancel the running turn at the next step boundary.
    public func cancel() {
        cancelled = true
    }

    /// Seed the conversation with a user turn.
    public func submitUserMessage(_ text: String) {
        session.append(DSHMessage(role: .user, blocks: [DSHTextBlock(text: text)]), turn: nil)
    }

    /// Run one turn to completion.
    @discardableResult
    public func run() async -> DSHTurnEndReason {
        guard !isRunning else { return .cancelled }
        isRunning = true
        cancelled = false
        currentTurn += 1
        defer { isRunning = false }

        let turn = currentTurn
        var step = 0

        // The context readouts are process-global and the app switches
        // conversations inside one process, so the binding moves at the start of
        // every turn — the earliest point at which this driver knows which
        // conversation it is about to spend. A value that outlived its session is
        // worse than no value: without this, a chat that has sent nothing yet
        // renders its predecessor's measured occupancy as its own, which is the
        // reported "a brand-new chat already shows a used figure". The binding is
        // idempotent, so a turn that did not move conversations costs nothing.
        DSHContextBreakdownStore.shared.bind(sessionKey: config.sessionKey)

        // Counters are per turn, so a call repeated across turns is not a loop.
        gate.reset()
        // A new turn starts a fresh overflow-recovery sequence: DSH clears the
        // same counter when the agent goes idle.
        overflowRetries = 0
        // The truncation fact belongs to a turn for the same reason its end
        // reason does: it is what this turn reports about itself.
        sawTruncatedStep = false
        reportedSkips.removeAll()
        // Prime the priced envelope before the first step, so a turn that opens
        // on an already-over-threshold conversation compacts before its first
        // request instead of spending that request to discover the overflow.
        // DSH reads this from the previous turn's durable request header; the
        // driver is constructed per turn here, so it measures the envelope it is
        // about to send.
        //
        // [P1-b] …but a turn is where the two meters are furthest apart, and it
        // used to be where the calibration was skipped. DSH prices the durable
        // request header — the provider's OWN count of the last routed request.
        // This driver, seeded from `measureRequestEnvelope()`, opened every turn
        // on an estimate and therefore on `isProviderCount == false`, which
        // `calibratedRetainBudget` refuses to convert (its guard below: one
        // currency or nothing). So the ONE compaction that fires at `step=1` kept
        // the policy's 40,632-token tail in ESTIMATOR units while every later
        // compaction of the same content kept 40,632/ratio. Device
        // 2026-10-19 09:17:18: `retain=(est)40632 == retainProvider=40632` for
        // that turn's first compaction, against `16,561`/`40,632` (= ratio 2.45)
        // for the two later ones, and a post-compaction prompt of 115,258 where
        // the same content cost 55,869…60,139 elsewhere — ~57k tokens of tail
        // that the policy never asked to keep.
        //
        // The provider's count for this session is already persisted (written
        // from every response's own accounting by `recordProviderPricing`), so
        // it — not a re-measurement — is the seed whenever it covers this route
        // and session. The estimate remains the fallback, and the line below
        // says which one is in force.
        if config.autoCompactionEnabled {
            switch providerCountedEnvelope() {
            case .success(let counted):
                lastPricedRequest = counted
                AppLogger(category: "CompactDiag").warning(Self.seedLine(
                    turn: turn,
                    source: "providerCount",
                    price: counted,
                    detail: "route=\(provider.name)/\(provider.model.id)"
                ))
            case .failure(let reason):
                lastPricedRequest = measureRequestEnvelope()
                if let estimated = lastPricedRequest {
                    AppLogger(category: "CompactDiag").warning(Self.seedLine(
                        turn: turn,
                        source: "estimate",
                        price: estimated,
                        detail: reason.description
                    ))
                }
            }
        }

        // No step ceiling unless a caller set one. `stepWouldExceedBudget` is the
        // whole condition: with `maxStepsPerTurn == nil` it never returns true, so
        // the loop leaves on the same exits upstream's `while (true)` has.
        while !stepWouldExceedBudget(step) {
            if cancelled {
                delegate?.driver(self, didEndTurn: .cancelled)
                return .cancelled
            }

            // Runaway bound, checked here rather than in the loop condition: it is
            // not a turn budget and must not read as one. A turn this long has
            // neither converged nor terminated — every step produced a new tool
            // call, so the loop guard (which keys on REPEATED calls) had nothing
            // to block, and context pressure never crossed. Cancelling is the
            // honest outcome: nothing here says the model's work was wrong, only
            // that this turn is not going to end by itself.
            if step >= config.restlessStepLimit {
                let budget = config.maxStepsPerTurn.map(String.init) ?? "nil"
                AppLogger(category: "DSHLoop").warning(
                    "[DSH] turn=\(turn) still running at step=\(step) "
                        + "(restlessStepLimit=\(config.restlessStepLimit) "
                        + "stepsPerTurnLimit=\(budget)) - stopping"
                )
                delegate?.driver(self, didEndTurn: .cancelled)
                return .cancelled
            }

            step += 1
            delegate?.driver(self, didStartStep: turn, step: step)

            // DSH's `agent/pre-step` pressure trigger. It runs before the request
            // for this step is derived, so the surface the model is given is the
            // surface this check just measured, and it runs once per proposed
            // step — which is what makes a turn that fans out into dozens of
            // tool calls compact mid-turn instead of only at send time.
            if config.autoCompactionEnabled {
                await compactForPressure(turn: turn, step: step)
            }

            var request = buildRequest()

            var assistantParts: [DSHContentBlock] = []
            var toolCalls: [DSHToolCallBlock] = []
            var stopReason: AgentStopReason = .endTurn
            var usage = DSHTokenUsage()

            // One step may issue more than one request: a provider-confirmed
            // context overflow is answered with a compaction and a retry of the
            // same step, exactly as DSH's `agent/request-error` recovery
            // re-derives and re-issues the request it just lost.
            attemptLoop: while true {
                // A retried attempt starts from a clean local frame. The driver
                // commits only after a stream completes, so nothing durable came
                // from the failed attempt and reusing its partial parts would
                // append a duplicated answer.
                assistantParts = []
                toolCalls = []
                stopReason = .endTurn
                usage = DSHTokenUsage()

                let stream: AsyncThrowingStream<AgentStreamEvent, Error>
                //
                // Retryable transport failures are retried with the host's backoff
                // before the turn is allowed to fail. `LLMError.isRetryable` is the
                // same predicate the legacy loop retried on, so a network blip or a
                // 5xx recovers here instead of ending the turn with an error banner.
                var retryAttempt = 0
                while true {
                    do {
                        stream = try await provider.streamAgentMessageClamped(
                            messages: request.messages,
                            systemPrompt: request.systemPrompt,
                            tools: request.tools,
                            maxTokens: config.requestMaxOutputTokens,
                            thinkingLevel: request.thinkingLevel
                        )
                        // Tell the host the stream is open, so it can clear the
                        // countdown and the error it showed on the row.
                        delegate?.driver(self, streamRetryCountdown: 0)
                        break
                    } catch let error as LLMError
                        where error.isRetryable && retryAttempt < config.streamRetryDelays.count {
                        retryAttempt += 1
                        let seconds = config.streamRetryDelays[retryAttempt - 1]
                        delegate?.driver(
                            self,
                            willRetryStreamAfter: error,
                            attempt: retryAttempt,
                            seconds: seconds
                        )
                        do {
                            for remaining in stride(from: seconds, through: 1, by: -1) {
                                delegate?.driver(self, streamRetryCountdown: remaining)
                                try await Task.sleep(nanoseconds: 1_000_000_000)
                            }
                        } catch {
                            // Cancelled during the backoff — Stop, or session teardown.
                            delegate?.driver(self, streamRetryCountdown: 0)
                            // Nothing can have streamed yet on this attempt, so this
                            // settles nothing; it is here because every terminal exit
                            // of an attempt settles its visible prefix in one place.
                            settleInterruptedAttempt(assistantParts, turn: turn)
                            delegate?.driver(self, didEndTurn: .cancelled)
                            return .cancelled
                        }
                        continue
                    } catch {
                        // [T-dsh-stop-is-not-a-failure] Stop is not a provider
                        // failure. A cancelled URLSession task throws
                        // NSURLErrorCancelled (-999) and a cancelled Task throws
                        // `CancellationError`; the old code mapped both to
                        // `PROVIDER_ERROR` and reported a broken backend for a
                        // deliberate stop (device 2026-10-19 21:22:36:
                        // "failure code=PROVIDER_ERROR Code=-999 已取消", and that
                        // turn recorded no turn end at all). The retry-backoff
                        // exit below already answers a cancellation this way —
                        // settle the visible prefix, end the turn as cancelled —
                        // so a stop is one outcome regardless of where it landed.
                        if cancelled || Self.isCancellation(error) {
                            settleInterruptedAttempt(assistantParts, turn: turn)
                            delegate?.driver(self, didEndTurn: .cancelled)
                            return .cancelled
                        }
                        let failure = error as? DSHFailure
                            ?? DSHFailure(message: String(describing: error), code: "PROVIDER_ERROR")
                        if await recoverFromContextOverflow(failure, turn: turn, step: step) {
                            request = buildRequest()
                            continue attemptLoop
                        }
                        // A request that never opened streamed nothing, so this is
                        // normally a no-op. See the mid-stream catch below for why
                        // every terminal attempt exit settles its visible prefix.
                        settleInterruptedAttempt(assistantParts, turn: turn)
                        delegate?.driver(self, didFail: failure)
                        return .cancelled
                    }
                }

                do {
                    for try await event in stream {
                        switch event {
                        case .textDelta(let text):
                            delegate?.driver(self, didEmitText: text)
                            if let last = assistantParts.last, let existing = last as? DSHTextBlock {
                                assistantParts[assistantParts.count - 1] = DSHTextBlock(text: existing.text + text)
                            } else {
                                assistantParts.append(DSHTextBlock(text: text))
                            }

                        case .thinkingDelta(let text):
                            delegate?.driver(self, didEmitReasoning: text)

                        case .reasoningContent, .reasoningEcho, .contentBlockStart, .toolInputDelta:
                            // Provider-private payloads and previews. The driver
                            // commits on toolCallComplete, so these are not
                            // model-visible state the driver owns.
                            break

                        case .toolCallComplete(let id, let name, let args, _):
                            let block = DSHToolCallBlock(
                                id: id, name: name, arguments: encodeArguments(args)
                            )
                            toolCalls.append(block)
                            assistantParts.append(block)
                            // [T-ios-tool-announce-in-stream] Announce now, not after
                            // the stream ends.
                            //
                            // The batch announce below used to be the only one, so
                            // every tool block of a step appeared in one frame at the
                            // end of the provider stream — and the text tail the
                            // throttle was holding landed in that same frame, which is
                            // the reported "a few characters, then the rest together
                            // with all the tool calls". Here the block lands as soon as
                            // its own call finished streaming, so several parallel calls
                            // appear in the order they completed, as the legacy loop's
                            // per-`contentBlockStart` append did.
                            //
                            // A call the loop guard later refuses needs no special
                            // case: it is announced like any other, and `recordBlocked`
                            // renders its refusal through `didFinishTool`, which the
                            // adapter resolves by call id into the block that already
                            // exists.
                            announcedCallIds.insert(id)
                            delegate?.driver(
                                self,
                                willRunTool: name,
                                callId: id,
                                arguments: args
                            )

                        case .usage(let reported):
                            usage.inputTokens += reported.inputTokens
                            usage.outputTokens += reported.outputTokens
                            if let v = reported.cacheCreationInputTokens {
                                usage.cacheWriteTokens = (usage.cacheWriteTokens ?? 0) + v
                            }
                            if let v = reported.cacheReadInputTokens {
                                usage.cacheReadTokens = (usage.cacheReadTokens ?? 0) + v
                            }
                            // Deliberately NOT reported here. The accumulator below
                            // carries this step's running total, and every chunk
                            // repeats the same total, so reporting per chunk made the
                            // delegate add it twice (three times with two chunks) and
                            // the session figures read about 2x until a relaunch
                            // recomputed them from the database. DSH keys usage by
                            // (turn, step) and replaces rather than adds, so the one
                            // report at the end of the step is the equivalent. The
                            // live figure while streaming comes from the estimate.

                        case .done(let reason):
                            stopReason = reason
                        }
                    }
                } catch {
                    let failure = error as? DSHFailure
                        ?? DSHFailure(message: String(describing: error), code: "STREAM_ERROR")
                    // A provider that reports the request exceeded its context
                    // window is answered with one compaction and a retry of this
                    // same step. Anything else ends the turn as before.
                    if await recoverFromContextOverflow(failure, turn: turn, step: step) {
                        request = buildRequest()
                        continue attemptLoop
                    }
                    // [P1-1] Whatever this attempt already streamed is on screen, so
                    // it is also a fact of the conversation: the user can read it, and
                    // a model that cannot see its own half-sentence repeats it or
                    // answers "the part above" as if it had said something else. DSH
                    // commits the same prefix when a stream dies mid-answer — a
                    // cancelled attempt's `live.interruptedBlocks()` is appended as an
                    // `assistant/message` with `interrupted: true`
                    // (`packages/core/agent-loop/src/agent.ts`), and a non-cancelled
                    // provider error ends the turn with that prefix still in the log.
                    //
                    // Until this line existed the driver committed only a COMPLETED
                    // stream, so this text lived exclusively in the UI's `ChatMessage`:
                    // `dshReconcileFromSession` rebuilt `agentHistory` from the surface
                    // at the end of the turn and the text was not in it, and
                    // `dshPersistSurface` had nothing to write — the answer vanished on
                    // the next launch. Appending here is what puts it in the log before
                    // either of those runs.
                    settleInterruptedAttempt(assistantParts, turn: turn)
                    delegate?.driver(self, didFail: failure)
                    return .cancelled
                }
                break attemptLoop
            }

            // [P1-2] Truncation is sticky for the turn (see `sawTruncatedStep`).
            // Recorded here, after the attempt finished streaming its terminal
            // event and before the turn-level reason is chosen below.
            if stopReason == .maxTokens { sawTruncatedStep = true }

            // Refine the priced envelope with what the provider itself counted.
            // DSH's meter reuses provider-reported usage when the request carried
            // it and falls back to character counting otherwise, because the
            // provider's number is the only one that knows how that adapter
            // tokenized the request. This is the figure the next step's pressure
            // check compares against the threshold.
            recordProviderPricing(usage)

            // Commit the assistant turn before any tool results, so the
            // conversation stays provider-valid (tool_use then tool_result).
            if !assistantParts.isEmpty {
                session.append(
                    DSHMessage(role: .assistant, blocks: assistantParts),
                    turn: turn
                )
                // A completed response starts a fresh overflow-recovery sequence,
                // even when tool calls continue the same turn into another
                // request (DSH clears the same counter on `assistant/message`).
                overflowRetries = 0
            }

            delegate?.driver(self, didReportUsage: usage)

            if toolCalls.isEmpty {
                let reason: DSHTurnEndReason
                switch stopReason {
                case .endTurn, .refusal, .toolUse:
                    // [P1-2] A truncation earlier in this turn outranks a step that
                    // completed normally — that is what sticky means upstream. The
                    // reply the user is looking at is short either way.
                    reason = sawTruncatedStep ? .maxTokens : .completed
                case .maxTokens:
                    reason = .maxTokens
                }
                delegate?.driver(self, didEndTurn: reason)
                return reason
            }

            // Pre-dispatch loop guard.
            //
            // The guard keys on the tool name AND the arguments, so it has to be
            // given the real arguments: with an empty dictionary every call to
            // the same tool hashes identically, and the twentieth `file_read` of
            // a turn is treated as a repeat of the first.
            //
            // It also has to run before dispatch. Checking after the call
            // returned cannot prevent the duplicate execution, and treating a
            // settled result as "blocked" means discarding real output and
            // handing the model a refusal in its place.
            var blocked: [String: DSHToolGate.Verdict] = [:]
            var admissible: [DSHToolCallBlock] = []
            for call in toolCalls {
                let verdict = gate.check(
                    toolName: call.name,
                    arguments: decodeArguments(call.arguments),
                    warningThreshold: config.loopWarningThreshold,
                    criticalThreshold: config.loopCriticalThreshold
                )
                if config.enableLoopGuard, verdict.level == DSHToolGate.Verdict.Level.critical {
                    blocked[call.id] = verdict
                } else {
                    admissible.append(call)
                }
            }

            // Announce every call before anything runs.
            //
            // The executor streams a tool's output into a transcript block and
            // addresses that block by position, so the block has to exist before
            // the call starts. Announcing here — rather than inside the
            // scheduler — also gives a refused call a block carrying its own
            // header, instead of the anonymous note it would otherwise get.
            // Anything the loop above already announced is skipped: its block
            // exists, and announcing it twice would append a second one.
            for call in toolCalls where !announcedCallIds.contains(call.id) {
                delegate?.driver(
                    self,
                    willRunTool: call.name,
                    callId: call.id,
                    arguments: decodeArguments(call.arguments)
                )
            }

            // Schedule the calls by their declared concurrency mode.
            let token = DSHCancellationToken()
            let outcome = await DSHToolScheduler.execute(
                registry: registry,
                turn: turn,
                step: step,
                toolCalls: admissible,
                signal: token,
                maxParallel: config.maxParallelToolCalls,
                applyOverflow: spillHook
            )

            if cancelled || outcome.aborted {
                // Unstarted calls already received a synthetic result, so the
                // surface stays replayable.
                delegate?.driver(self, didEndTurn: .cancelled)
                return .cancelled
            }

            // Commit in the model's own order, interleaving the blocked calls
            // with the executed ones so the result sequence still mirrors the
            // call sequence.
            var commitsById: [String: DSHToolCommit] = [:]
            for commit in outcome.commits { commitsById[commit.block.id] = commit }

            for call in toolCalls {
                if let verdict = blocked[call.id] {
                    recordBlocked(callId: call.id, name: call.name, verdict: verdict, turn: turn)
                } else if let commit = commitsById[call.id] {
                    commitResult(commit, turn: turn)
                }
            }

            if outcome.concluded {
                delegate?.driver(self, didEndTurn: .concluded)
                return .concluded
            }

            await Task.yield()
        }

        // The step ceiling reports itself, even when a step of this turn was also
        // truncated: this ceiling is the loop's OWN decision to stop (`maxSteps` has
        // no upstream counterpart — DSH's turn loop is a `while (true)` whose only
        // exit is an empty next step), and it is the more actionable of the two facts
        // for the user. Stickiness exists to keep a truncation from being reported as
        // a clean completion, not to erase a budget stop.
        //
        // Unreachable on the default path: `maxStepsPerTurn` is nil there, so
        // `stepWouldExceedBudget` never returns true and this code is only reached
        // when a caller set a ceiling on purpose. "Reached the step limit for this
        // turn" therefore names a limit the user asked for, not one the app
        // imposed on a long task.
        delegate?.driver(self, didEndTurn: .maxSteps)
        return .maxSteps
    }

    /// Whether another step would exceed a ceiling the caller set.
    ///
    /// The loop's whole budget condition, kept in one place so "no ceiling" is a
    /// property of the value rather than of the comparison: nil means the loop has
    /// no step budget at all, and `>=` (not `>`) is what makes a ceiling of N mean
    /// N steps rather than N+1.
    private func stepWouldExceedBudget(_ step: Int) -> Bool {
        guard let limit = config.maxStepsPerTurn else { return false }
        return step >= limit
    }

    // MARK: - Attempt Settlement

    /// The prefix of an attempt the session can keep when its stream dies.
    ///
    /// DSH's `BlockAssembler.interruptedBlocks()` is the authority, and it is
    /// deliberately narrow: text/reasoning blocks with non-whitespace content, in
    /// stream order — "Tool calls are omitted because interruption precedes
    /// dispatch; retaining one would require a fabricated result."
    /// (`packages/llm/llm/src/assembler.ts`.)
    ///
    /// The tool-call half is not cosmetic. An assistant message carrying a
    /// `tool_use` block with no `tool_result` after it is a request the provider
    /// REJECTS, and an interrupted attempt's calls were never dispatched, so they
    /// cannot have a result to go with them. This driver announces its tool blocks
    /// as soon as their arguments finish streaming, so a stream that dies after a
    /// call completed leaves a `DSHToolCallBlock` in `parts` — exactly the block
    /// that must not be committed.
    ///
    /// - Parameter parts: the attempt's accumulated blocks.
    /// - Returns: the subset that may be appended, possibly empty.
    private func interruptedContent(_ parts: [DSHContentBlock]) -> [DSHContentBlock] {
        parts.compactMap { block -> DSHContentBlock? in
            switch block {
            case let text as DSHTextBlock:
                return text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : text
            case let reasoning as DSHReasoningBlock:
                return reasoning.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : reasoning
            default:
                return nil
            }
        }
    }

    /// Append an interrupted attempt's visible prefix to the session.
    ///
    /// [P1-1] Called from every terminal exit of an attempt that is not a completed
    /// stream — the mid-stream failure, the failure to open one, and cancellation —
    /// and BEFORE `didFail`, so the log holds the text before the UI is told the
    /// turn failed. What the user already read is then also what the model reads on
    /// the next turn, and what `dshPersistSurface` writes to the database.
    ///
    /// DSH records the equivalent entry with `interrupted: true` on the
    /// `assistant/message` event (`packages/core/agent-loop/src/agent.ts`).
    /// `DSHMessage` carries no such flag and this driver does not invent one: the
    /// same fact is expressed by the entry's shape and position — it is the last
    /// entry of a turn whose end reason is `.cancelled`, it never carries a
    /// `tool_use` block, and it is the only assistant entry this driver appends
    /// without a terminal stream event behind it. Adding the flag would require a
    /// field on the shared message type, whose persistence and projection both
    /// ignore unknown fields, so the flag would be dropped on the way to the
    /// database and read back as a false negative.
    ///
    /// - Parameter parts: the attempt's accumulated blocks.
    /// - Parameter turn: enclosing turn, recorded on the entry.
    private func settleInterruptedAttempt(_ parts: [DSHContentBlock], turn: Int) {
        let content = interruptedContent(parts)
        guard !content.isEmpty else { return }
        session.append(DSHMessage(role: .assistant, blocks: content), turn: turn)
        AppLogger(category: "DSHLoop").warning(
            "[DSH] settled interrupted attempt: kept \(content.count) block(s) "
            + "of \(parts.count) in turn=\(turn)"
        )
    }

    // MARK: - Compaction

    /// DSH's `agent/pre-step` pressure trigger.
    ///
    /// Prices the latest routed request against the routed model's threshold and
    /// compacts when it crosses. Runs once per proposed step, before this step's
    /// request is derived, so the surface the model is given is the surface this
    /// check just measured — and so a single turn that fans out into dozens of
    /// tool iterations compacts in the middle of itself rather than only when the
    /// user next presses send.
    ///
    /// Threshold and retention both come from `compactionPolicy` scaled to the
    /// resolved window, never from a fixed token count: a fixed count either
    /// fires on every step of a small-window model or never fires on a large one.
    ///
    /// - Parameters:
    ///   - turn: enclosing turn, recorded on the compaction bracket.
    ///   - step: step the compaction precedes, for the diagnostic line.
    private func compactForPressure(turn: Int, step: Int) async {
        guard config.autoCompactionEnabled else { return }
        guard let price = lastPricedRequest else { return }

        let surfaceNow = DSHTokenEstimate.total(session.surface())
        let measured = price.promptTokens + max(0, surfaceNow - price.surfaceTokens)
        // Which kind of number `measured` is, captured before the retry loop can
        // re-price it: every line of this decision reports the same provenance.
        let measuredSource: DSHContextUsageSource =
            price.isProviderCount ? .providerMeasured : .requestEnvelopeEstimate

        var spec: DSHCompactionSpec
        do {
            spec = try resolveSpec(reservedCompletionTokens: price.reservedCompletionTokens)
        } catch let error as DSHCompactionConfigError {
            // Misconfiguration is a property of the route, so it is reported once
            // per route rather than once per step. DSH warns once for the same
            // reason and skips proactive compaction until the config is fixed.
            if warnedPressureTargets.insert(error.targetKey).inserted {
                AppLogger(category: "CompactDiag").warning(
                    "[CompactDiag] mid-turn compaction unavailable for \(error.targetKey): "
                    + "\(error.message); provider-confirmed overflow recovery stays active"
                )
            }
            return
        } catch {
            return
        }

        guard measured >= spec.thresholdTokens else { return }

        // DSH runs the model-free tool-result prune pass HERE — after the
        // threshold has qualified and before anything is chosen to summarize
        // (`packages/compaction/compaction-basic/src/index.ts:319-327`):
        //
        //     if (measurement.totalTokens < spec.thresholdTokens) return null
        //     if (prune !== undefined) {
        //       prune.pruneSession(agent.session)
        //       measurement = meter.measure(agent.session)
        //     }
        //     if (measurement.totalTokens < spec.thresholdTokens) return null
        //
        // The second gate is the whole point of the pass and the reason it is
        // free: when replacing the middle of oversized tool results puts the
        // request back under pressure, no summary is generated at all. The device
        // log is why that matters on this corpus — a ~810 KB request
        // (2026-10-19 09:32, ~189k provider tokens) was dominated by ~60
        // `file_read` results of 15,235 characters, each of which the pruner
        // rewrites to 5,140 (head 4,096 + marker + tail 1,024). That is
        // ~605,700 characters ≈ 139k provider tokens of relief for zero model
        // calls, against a summary request the engine prices as a 132–141k-token
        // COLD prefill at a 43–47 s TTFT (`cache=13`, because the summary request
        // shares no prefix with the conversation it replaces).
        //
        // Order matters twice over. It runs after the gate so a conversation that
        // is not under pressure is never rewritten at all ("Below pressure nothing
        // is trimmed", pruner README) — the operator's history is not touched for
        // free. And it runs before the retained-tail calibration below, so the
        // budget is converted against the surface the summarizer would actually be
        // given.
        var measuredAfter = measured
        if config.autoCompactionEnabled, surfaceNow > 0, spec.thresholdTokens > 0 {
            let prune = DSHToolResultPruner.run(session)
            if !prune.isEmpty {
                // Re-price through the same composition the gate used: the system
                // prompt and the tool roster are not part of the surface and
                // cannot be pruned, so the envelope head is carried across. This
                // is upstream's `measurement = meter.measure(agent.session)`
                // read through this app's meter.
                let surfacePruned = DSHTokenEstimate.total(session.surface())
                measuredAfter = price.promptTokens + max(0, surfacePruned - price.surfaceTokens)
                let skipsSummary = measuredAfter < spec.thresholdTokens
                if let line = DSHToolResultPruner.diagnosticLine(
                    for: prune, skippedSummary: skipsSummary
                ) {
                    AppLogger(category: "CompactDiag").warning(line)
                }
                // The freed tokens are what the next step's gate must price, so the
                // envelope is re-seeded from the pruned surface. This is a NEW
                // envelope, not the provider's count of an older one, so it is
                // reported as an estimate until the next response re-prices it —
                // the same provenance the log line above names.
                lastPricedRequest = measureRequestEnvelope()
                // Upstream's second gate: the pass was enough, so this step sends
                // no summary request and pays nothing for one.
                if skipsSummary { return }
            }
        }

        // [P1-3] The gate above and the selection below must count with the SAME
        // meter, and they did not.
        //
        // `measured` is the provider's own count of the request envelope once a
        // response has reported usage, and `thresholdTokens` is derived from the
        // model's window — so both are provider tokens. `retainTokens` comes from
        // the same resolved window and is therefore provider tokens too, but the
        // selection that SPENDS it counts with `DSHTokenEstimate.tokens(for:)`
        // (`DSHCompaction.swift`, `select`), a character-proportional estimator
        // that understated this corpus's real count by a factor of ~2.5 (device
        // log 2026-10-18: `measured=191820` against a 76,551-token estimate of the
        // same surface, and the very next request charged `prompt=115980` for a
        // ~42.6k-estimate surface). A budget expressed in provider tokens, spent by
        // an accumulator reading estimates, buys ~2.5x the tail it names — so every
        // compaction shadowed less than the policy asked for, and the request that
        // followed each of the turn's five compactions was still charged 115,980 …
        // 118,210 provider tokens against a 40,632-token tail budget.
        //
        // Upstream has no such split: `compaction-basic` compares the threshold and
        // accumulates the retained tail from the SAME meter —
        // `const pricedNodes = measurement.nodes` in both
        // (`packages/compaction/compaction-basic/src/region.ts`). One meter, one
        // currency. This app has two, so the budget is converted into the units the
        // selection actually reads; the threshold formula and the retained-tail
        // POLICY are untouched.
        //
        // The conversion divides by `measured / surfaceEstimate`, which is the
        // ratio between the two meters over the same content. It is only applied
        // when `measured` really is a provider count: with an estimated envelope
        // both sides come from the estimator and converting would move the budget
        // by the ratio between two estimates of different scopes.
        //
        // The policy's own figure is kept for the diagnostic line: after the
        // conversion below, `spec.retainTokens` is in the estimator's units.
        let retainProviderTokens = spec.retainTokens
        spec = spec.replacingRetainTokens(Self.calibratedRetainBudget(
            retainTokens: retainProviderTokens,
            measuredTokens: measured,
            surfaceEstimate: surfaceNow,
            isProviderCount: price.isProviderCount
        ))

        // One rendering of the budget facts, shared by every line this decision
        // can produce: the same figures have to appear whichever outcome the
        // retry loop reaches, and a per-site call is what let two of the three
        // lines drift in the past.
        let facts = specFacts(
            spec, measured: measured, source: measuredSource,
            retainProviderTokens: retainProviderTokens
        )

        // The system prompt and tool roster are part of the request the provider
        // prices but cannot be shadowed by a compaction, so they are carried
        // across the re-measure below instead of being recomputed from the
        // surface.
        let envelopeHead = max(0, measured - surfaceNow)

        for attempt in 0...spec.compactionRetries {
            let result = await DSHCompaction.compact(
                session: session,
                turn: turn,
                retainTokens: spec.retainTokens,
                pressureThreshold: spec.thresholdTokens,
                measuredTokens: measured,
                model: provider.model.id,
                provider: provider.name,
                summaryTools: summaryToolRoster()
            ) { [weak self] input in
                guard let self else { throw DSHCompactionError.summaryFailed("driver deallocated") }
                return try await self.summarize(input)
            }

            switch result {
            case .success(let outcome):
                let position = "turn=\(turn) step=\(step)"
                // `before`/`after` are this app's own surface estimates — the
                // compaction's own outcome, measured by `DSHTokenEstimate` on both
                // sides of the shadow — so they are labelled as estimates rather
                // than printed beside `measured=` as if they were the same kind of
                // number. They were read as the engine's counts for a round: a
                // 262k-window session logged `before=77655 after=43779` while the
                // provider was charging 189,546 for the same request.
                let tokens = "beforeEst=\(outcome.beforeTokens) afterEst=\(outcome.afterTokens)"
                let shadowed = outcome.range.shadowedSeqs.count
                AppLogger(category: "CompactDiag").warning(
                    "[CompactDiag] mid-turn compaction at \(position): \(tokens) "
                    + "shadowed=\(shadowed) reason=pressure "
                    + facts
                    + " attempt=\(attempt) reserved=\(spec.reservedCompletionTokens)"
                )
                delegate?.driver(self, didCompact: outcome)
                // Re-price through the same composition the gate used: the freed
                // tokens are what decides whether another attempt is needed.
                let after = DSHTokenEstimate.total(session.surface()) + envelopeHead
                if after < spec.thresholdTokens { return }
                lastPricedRequest = PricedRequest(
                    promptTokens: after,
                    reservedCompletionTokens: spec.reservedCompletionTokens,
                    surfaceTokens: DSHTokenEstimate.total(session.surface()),
                    isProviderCount: false
                )
            case .failure(let error):
                // Reported once per reason per turn: a surface that is over
                // threshold with nothing safely compactable refuses identically
                // on every step, and one line per step buries the reason it is
                // refusing. `.noShrink` covers both "nothing safe to select" and
                // "the summary would not be smaller than what it replaces".
                let key = "\(error)"
                if reportedSkips.insert(key).inserted {
                    let position = "turn=\(turn) step=\(step)"
                    let reason = error.message
                    let entries = session.surfaceCount
                    AppLogger(category: "CompactDiag").warning(
                        "[CompactDiag] mid-turn compaction skipped at \(position): "
                        + "reason=\(reason) \(facts) "
                        + "surfaceEntries=\(entries)"
                    )
                }
                return
            }
        }

        let attempts = spec.compactionRetries + 1
        AppLogger(category: "CompactDiag").warning(
            "[CompactDiag] mid-turn compaction still above threshold at turn=\(turn) step=\(step) "
            + "after \(attempts) attempt(s): \(facts)"
        )
    }

    /// Translate a retained-tail budget into the units the selection reads.
    ///
    /// [P1-3] `retainTokens` and `thresholdTokens` are provider tokens — both are
    /// derived from the model's declared window, and the threshold is compared
    /// against the provider's own count of the request. `DSHCompactionSelection`
    /// spends the budget with `DSHTokenEstimate`, which counts characters, and on
    /// this app's corpus that estimate is ~2.5x low (device log 2026-10-18:
    /// `measured=191820` for a surface the estimator called 76,551 tokens; the next
    /// request after that compaction was charged `prompt=115980` for a surface the
    /// estimator called 42,599). Spending a provider budget through the estimator
    /// therefore retains ~2.5x the tail the policy names.
    ///
    /// The correction is a ratio and not a constant: which way, and by how much,
    /// the estimator is off depends on the content (CJK prose, tool JSON and
    /// base64 are all mispriced differently), so it is measured per compaction from
    /// the two numbers the decision already has.
    ///
    /// Deliberately conservative in three ways: nothing changes when the priced
    /// envelope is itself an estimate (one currency, nothing to convert), nothing
    /// changes when the provider's count is not above the estimate (ratio ≤ 1 —
    /// there is no split to correct, and a ratio below 1 would GROW the tail), and
    /// the result is clamped to `[1, retainTokens]`, so a wild ratio can only make
    /// the retained tail smaller than the policy asked, never larger.
    ///
    /// - Parameters:
    ///   - retainTokens: the resolved retained-tail budget, in provider tokens.
    ///   - measuredTokens: the priced envelope the threshold was compared against.
    ///   - surfaceEstimate: `DSHTokenEstimate.total(surface)` — the selection's own
    ///     units for the same content.
    ///   - isProviderCount: whether `measuredTokens` is the provider's own count.
    /// - Returns: the budget expressed in the estimator's units.
    static func calibratedRetainBudget(
        retainTokens: Int,
        measuredTokens: Int,
        surfaceEstimate: Int,
        isProviderCount: Bool
    ) -> Int {
        guard isProviderCount, retainTokens > 0 else { return retainTokens }
        let estimate = max(1, surfaceEstimate)
        guard measuredTokens > estimate else { return retainTokens }
        let ratio = Double(measuredTokens) / Double(estimate)
        let converted = Int((Double(retainTokens) / ratio).rounded(.down))
        return max(1, min(retainTokens, converted))
    }

    /// Whether a thrown error means "the user stopped", not "the backend broke".
    ///
    /// [T-dsh-stop-is-not-a-failure] A cancelled `URLSession` stream surfaces as
    /// `NSURLErrorCancelled` (-999) and a cancelled `Task` as `CancellationError`;
    /// both reach the attempt loop's `catch`, which used to relabel them
    /// `PROVIDER_ERROR` and report a failure. Nothing about a stop is a provider
    /// fault, so the terminal outcome is `.cancelled`, exactly as it is on the
    /// retry-backoff exit.
    ///
    /// Deliberately narrow: only those two shapes. A transport error that merely
    /// mentions "cancelled" is still a transport error.
    ///
    /// - Parameter error: the error one attempt threw.
    /// - Returns: true when the attempt was cancelled rather than failed.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        // Some adapters wrap the URL error in their own type; unwrap one level
        // rather than pattern-matching message text.
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain,
           underlying.code == NSURLErrorCancelled {
            return true
        }
        return false
    }

    /// The budget facts one compaction line reports.
    ///
    /// `measured` is the priced request envelope the threshold was compared
    /// against, and it is exactly that: the provider's own count once a response
    /// has reported one this turn, and this app's estimate of the same envelope
    /// before that (`PricedRequest.isProviderCount`). The suffix says which, so a
    /// log reader never has to guess — that guess is what made a 2.44×-low
    /// estimate look like the engine's measurement.
    ///
    /// `retain` is the OTHER currency on the same line, and it says so. Since
    /// [P1-3] the retained-tail budget this compaction actually spent is in
    /// `DSHTokenEstimate` units — the same units as `beforeEst`/`afterEst` — while
    /// the policy's own figure is in provider tokens. Both are printed, labelled,
    /// because the two differ by the estimator's error (~2.5x on this corpus) and a
    /// single unlabelled number here is what let "it compacted but the prompt did
    /// not shrink" be diagnosed as a compaction failure instead of a currency one.
    ///
    /// A named piece rather than one long `+` chain: a single chain holding a
    /// dozen interpolations over mixed `Int`/`Double`/`String` operands makes the
    /// type checker search every overload combination, and the whole expression
    /// gets rejected as "unable to type-check in reasonable time" — a real build
    /// failure that a local syntax check cannot see.
    ///
    /// - Parameters:
    ///   - spec: the resolved trigger budget, retained-tail figure already
    ///     converted into estimator units.
    ///   - measured: the priced envelope the threshold was compared against.
    ///   - source: whether that envelope carries a provider count.
    ///   - retainProviderTokens: the policy's retained-tail budget, unconverted.
    /// - Returns: one line's worth of threshold, window, and retention facts.
    private func specFacts(
        _ spec: DSHCompactionSpec,
        measured: Int,
        source: DSHContextUsageSource = .requestEnvelopeEstimate,
        retainProviderTokens: Int
    ) -> String {
        let kind = source == .providerMeasured ? "provider" : "estimated"
        return "measured=\(measured)(\(kind)) threshold=\(spec.thresholdTokens)"
            + " window=\(spec.contextWindow) retain=\(spec.retainTokens)(est)"
            + " retainProvider=\(retainProviderTokens)"
    }

    /// DSH's `agent/request-error` context-overflow recovery.
    ///
    /// A provider that reports the request exceeded the model's window is
    /// answered with one maximal balanced head reduction and one retry of the
    /// same step. Both the pressure threshold and the retained-tail policy are
    /// deliberately bypassed here: the request has already failed, so any
    /// reduction that advances the surface is progress, and `retainTokens: 0`
    /// retains only the newest surface node — the largest reduction the selection
    /// rule can produce.
    ///
    /// A retry is authorized only after the surface actually shrank. Without that
    /// proof the retry re-sends the request that was just rejected, and the pair
    /// of them repeat until `maxOverflowRetries` runs out.
    ///
    /// [T-dsh-tool-result-prune] The proof is `surfaceReplacementGeneration`, and a
    /// tool-result prune advances it: upstream authorizes this retry on exactly
    /// that counter and treats a landed prune as sufficient
    /// (`compaction-basic/src/index.ts:202-233` — a failing second phase does not
    /// discard "durable surface progress" the model-free pass already made). So a
    /// turn whose overflow is answered by the prune pass alone retries with the
    /// pruned request instead of ending on the provider's error.
    ///
    /// - Parameters:
    ///   - failure: the provider's structured failure.
    ///   - turn: enclosing turn.
    ///   - step: step being retried.
    /// - Returns: true when the surface shrank and the caller should retry.
    private func recoverFromContextOverflow(
        _ failure: DSHFailure,
        turn: Int,
        step: Int
    ) async -> Bool {
        guard config.autoCompactionEnabled else { return false }

        // Every piece of text the failure carries is classified, because the
        // provider's code and message differ per adapter and only one of them may
        // name the context bound.
        let detail = "\(failure.code) \(failure.status.map(String.init) ?? "") \(failure.message)"
        guard DSHContextOverflow.isContextWindowExceeded(detail) else { return false }

        guard overflowRetries < config.compactionPolicy.maxOverflowRetries else {
            AppLogger(category: "CompactDiag").warning(
                "[CompactDiag] context-overflow recovery exhausted at turn=\(turn) step=\(step): "
                + "attempts=\(overflowRetries)/\(config.compactionPolicy.maxOverflowRetries) "
                + "failure=\(failure.code)"
            )
            return false
        }

        let generation = session.surfaceReplacementGeneration
        let surfaceBefore = DSHTokenEstimate.total(session.surface())

        // DSH prunes on the overflow path too, and unconditionally
        // (`packages/compaction/compaction-basic/src/index.ts:294-302`): "Overflow
        // always qualifies". The gate that makes the pressure path free does not
        // apply here — the request has already been rejected, so any reduction is
        // progress. Two things make it worth the pass. It is model-free, so it
        // cannot fail the way a summary can; and it shrinks the range the summary
        // then has to read, which is the input to the request that overflowed in
        // the first place (device 2026-10-19 09:17: a 1,783,917-byte summary
        // request against a 262,144-token window, refused by the engine).
        let overflowPrune = DSHToolResultPruner.run(session)
        if !overflowPrune.isEmpty {
            if let line = DSHToolResultPruner.diagnosticLine(
                for: overflowPrune, skippedSummary: false
            ) {
                AppLogger(category: "CompactDiag").warning(
                    line + " trigger=contextOverflow turn=\(turn) step=\(step)"
                )
            }
        }

        let result = await DSHCompaction.compact(
            session: session,
            turn: turn,
            retainTokens: 0,
            pressureThreshold: 0,
            measuredTokens: 0,
            model: provider.model.id,
            provider: provider.name,
            summaryTools: summaryToolRoster()
        ) { [weak self] input in
            guard let self else { throw DSHCompactionError.summaryFailed("driver deallocated") }
            return try await self.summarize(input)
        }

        switch result {
        case .success(let outcome):
            let position = "turn=\(turn) step=\(step)"
            let tokens = "beforeEst=\(outcome.beforeTokens) afterEst=\(outcome.afterTokens)"
            let shadowed = outcome.range.shadowedSeqs.count
            let attempt = overflowRetries + 1
            let limits = config.compactionPolicy.maxOverflowRetries
            AppLogger(category: "CompactDiag").warning(
                "[CompactDiag] mid-turn compaction at \(position): \(tokens) "
                + "shadowed=\(shadowed) reason=context-overflow "
                + "failure=\(failure.code) attempt=\(attempt)/\(limits)"
            )
            delegate?.driver(self, didCompact: outcome)
        case .failure(let error):
            let position = "turn=\(turn) step=\(step)"
            let reason = error.message
            let code = failure.code
            let tokens = surfaceBefore
            AppLogger(category: "CompactDiag").warning(
                "[CompactDiag] context-overflow recovery not possible at \(position): "
                + "reason=\(reason) surfaceTokensEst=\(tokens) failure=\(code)"
            )
        }

        guard session.surfaceReplacementGeneration > generation else { return false }
        overflowRetries += 1
        return true
    }

    /// The priced envelope for the request this driver would build right now.
    ///
    /// Prices the three things a request is made of — the rendered system prompt,
    /// the tool roster, and the surface — because that is what the provider
    /// counts against the window and what DSH's meter prices from the logged
    /// request. Measuring the surface alone is what lets a request overflow while
    /// the conversation still looks small: the prompt and the roster are the
    /// difference, and they are exactly the part a compaction cannot shrink.
    ///
    /// - Returns: the envelope price, with the reserved output tokens the next
    ///   request will carry.
    private func measureRequestEnvelope() -> PricedRequest {
        let schemas = registry.schemas()
        let context = DSHAssembleContext(
            model: provider.model.id,
            provider: provider.name,
            cwd: nil,
            toolNames: schemas.map(\.name),
            isHelper: false
        )
        let assembly = prompt.assemble(
            tools: schemas,
            context: context,
            toolOrder: config.toolOrder
        )
        let rendered = DSHSystemPrompt.renderPrompt(assembly)
        let snapshot = DSHSystemPrompt.renderContextSnapshot(assembly)
        let surfaceTokens = DSHTokenEstimate.total(session.surface())
        let promptTokens = DSHTokenEstimate.tokens(forText: rendered)
            + DSHTokenEstimate.tokens(forText: snapshot)
            + DSHTokenEstimate.tokens(forToolSchemas: schemas)
            + surfaceTokens
        return PricedRequest(
            promptTokens: promptTokens,
            reservedCompletionTokens: config.reservedOutputTokens,
            surfaceTokens: surfaceTokens,
            isProviderCount: false
        )
    }

    /// The provider's own count of this session's last routed request, priced
    /// against the surface this turn is about to send — or the reason there is
    /// none. [P1-b]
    ///
    /// This is this app's stand-in for DSH's `session.requestHeader()`: the
    /// measured figure the app already holds for the conversation, which is what
    /// makes the retained-tail calibration available to a turn's FIRST step
    /// instead of only to its second onwards. Four facts have to line up, and
    /// each failure falls back to the estimate rather than pricing the turn on a
    /// count that belongs to another route:
    ///
    ///   * a provider count exists for the session (`DSHContextUsageStore`, whose
    ///     binding moves with the conversation's own choke point) — a report for
    ///     a session the store is not bound to is refused there, so a value that
    ///     is present is this session's;
    ///   * an assembly is on record (`DSHContextBreakdownStore.latest`), which is
    ///     what carries the SURFACE estimate the count was taken against;
    ///   * that assembly was for the SAME provider and model. A count taken from
    ///     another route's tokenizer is not this route's currency, and DSH has no
    ///     such window because its header is per-route by construction;
    ///   * the count is positive.
    ///
    /// The returned envelope's `surfaceTokens` is the estimate the count was
    /// taken against, so the pressure check's existing growth term
    /// (`surfaceNow − price.surfaceTokens`) still measures what has been appended
    /// since — the same arithmetic `PricedRequest` documents for a measured
    /// envelope.
    ///
    /// - Returns: the seeded request, or the reason it could not be built.
    private func providerCountedEnvelope() -> Result<PricedRequest, DSHSeedRefusal> {
        guard let measured = DSHContextUsageStore.shared.measured, measured.promptTokens > 0 else {
            return .failure(DSHSeedRefusal("no provider count for this session"))
        }
        guard let breakdown = DSHContextBreakdownStore.shared.latest else {
            return .failure(DSHSeedRefusal("no assembled request to pair the count with"))
        }
        guard breakdown.model == provider.model.id, breakdown.provider == provider.name else {
            return .failure(DSHSeedRefusal(
                "count is from \(breakdown.provider)/\(breakdown.model), this turn routes "
                    + "\(provider.name)/\(provider.model.id)"
            ))
        }
        let surfaceNow = DSHTokenEstimate.total(session.surface())
        let baseline = breakdown.surfaceTokens > 0 ? breakdown.surfaceTokens : surfaceNow
        // The reservation this route prices with is taken from the estimate
        // itself rather than restated: the seed is a different PROMPT COUNT, not a
        // different reservation, and a second copy of `config.reservedOutputTokens`
        // is exactly how one of them drifts from the other later.
        let estimated = measureRequestEnvelope()
        return .success(PricedRequest(
            promptTokens: measured.promptTokens,
            reservedCompletionTokens: estimated.reservedCompletionTokens,
            surfaceTokens: baseline,
            isProviderCount: true
        ))
    }

    /// One line for the turn-start seed: the figure the first step's pressure
    /// check will price, and where it came from.
    ///
    /// A named piece rather than one long interpolation chain: a log line with a
    /// dozen mixed operands is what the type checker rejects as "unable to
    /// type-check in reasonable time" (see `specFacts`).
    ///
    /// - Parameters:
    ///   - turn: the turn this seed belongs to.
    ///   - source: `providerCount` or `estimate` — which of the two is in force.
    ///   - price: the seeded envelope.
    ///   - detail: the route, or why the counted seed was refused.
    /// - Returns: the line to log.
    private static func seedLine(
        turn: Int, source: String, price: PricedRequest, detail: String
    ) -> String {
        let figures = "promptTokens=\(price.promptTokens) surfaceEst=\(price.surfaceTokens) "
            + "reserved=\(price.reservedCompletionTokens)"
        return "[CompactDiag] pressure seed at turn=\(turn): source=\(source) "
            + "\(figures) providerCount=\(price.isProviderCount) — \(detail)"
    }

    /// Replace the estimated envelope with the prompt tokens the provider counted.
    ///
    /// The estimator is character-proportional, and it cannot know how an adapter
    /// tokenizes: CJK prose, tool JSON and base64 payloads are all underpriced by
    /// any characters-per-token ratio, and on the 2026-10-18 device log the
    /// understatement was a factor of 2.44 (`prompt=189546` against the app's own
    /// 77,655 for the same turn). The provider's own count has neither problem, so
    /// it supersedes the estimate whenever a request reports one — which is also
    /// what DSH's meter does.
    ///
    /// This is also the only writer of the app's MEASURED context figure
    /// (`DSHContextUsageStore`), on either loop: every readout of "how full is the
    /// context" reads what this records, and nothing derives the figure a second
    /// way. It is written here rather than in the delegate's usage callback
    /// because here the envelope the provider priced is still in hand
    /// (`built.surfaceTokens`), which is what the growth projection needs as its
    /// baseline.
    ///
    /// - Parameter usage: usage accumulated for the request that just finished.
    private func recordProviderPricing(_ usage: DSHTokenUsage) {
        guard let built = lastPricedRequest else { return }
        let reported = usage.inputTokens
            + (usage.cacheReadTokens ?? 0)
            + (usage.cacheWriteTokens ?? 0)
        guard reported > 0 else { return }
        lastPricedRequest = PricedRequest(
            promptTokens: reported,
            reservedCompletionTokens: built.reservedCompletionTokens,
            surfaceTokens: built.surfaceTokens,
            envelopeTokens: built.envelopeTokens,
            isProviderCount: true
        )
        // [T-ctx-usage-one-denominator] The projection's baseline is the WHOLE
        // envelope the provider priced, so `occupancy` adds only what grew since.
        // The surface is the fallback for a request that never stated one (a seed
        // construction), and it is the old behaviour rather than a new lie.
        DSHContextUsageStore.shared.record(
            promptTokens: reported,
            envelopeTokens: built.envelopeTokens > 0 ? built.envelopeTokens : built.surfaceTokens,
            sessionKey: config.sessionKey
        )
    }

    /// Resolve this driver's trigger budget for one routed request.
    ///
    /// The arithmetic and the override order live in
    /// `DSHCompactionPolicy.resolvedSpec` (`DSHCompaction.swift`) — the ONE place a
    /// policy meets a window, shared with `/compact`. What the driver owns is its
    /// own four inputs: the route key, `config.contextWindow`, and the two
    /// device-experiment overrides. Anything computed here a second time is drift:
    /// before this forwarding, `/compact` resolved the same three inputs through its
    /// own copy and the two were only equal by inspection.
    ///
    /// - Parameter reservedCompletionTokens: output tokens the request reserves.
    /// - Returns: the pressure and retention budgets for this route.
    /// - Throws: `DSHCompactionConfigError` when no capacity is known, or when the
    ///   policy cannot be scaled to the capacity that is known.
    private func resolveSpec(reservedCompletionTokens: Int) throws -> DSHCompactionSpec {
        let targetKey = DSHCompactionPolicy.targetKey(
            provider: provider.name,
            model: provider.model.id
        )
        return try config.compactionPolicy.resolvedSpec(
            targetKey: targetKey,
            contextWindow: config.contextWindow,
            reservedCompletionTokens: reservedCompletionTokens,
            retainOverride: config.compactionRetainTokensOverride,
            pressureThresholdOverride: config.compactionPressureTokensOverride
        )
    }

    // MARK: - Summary Request Budget

    /// Output ceiling one summary request reserves, at full size.
    ///
    /// 65,536 IS UPSTREAM'S FIGURE, not this app's own: `SummarizationConfig.maxTokens`
    /// defaults to `summarizeMaxTokens: 65_536`
    /// (`packages/compaction/compaction-basic/src/config.ts:76`) and
    /// `summarizeWithLlm` sends it as the request's `maxTokens`
    /// (`summarizer.ts:158`). It used to be 4,096 here, which is the value the
    /// driver happened to have grown for a different job — keeping a small route
    /// from reserving a quarter of its window — and that adaptation is now the
    /// SECOND clamp rather than the figure itself: `summarizeOutputCeiling`
    /// takes the smaller of this, the route's own output cap, and a quarter of
    /// the window. A route that can spend 65,536 does; one that cannot is asked
    /// for what it can.
    static let summarizeMaxOutputTokens = 65_536

    /// The least output a summary request may reserve.
    static let summarizeMinOutputTokens = 1024

    /// Headroom held under the window beyond the output ceiling, at full size.
    ///
    /// The engine counts the request it receives; this app cannot reproduce that
    /// count (its meter is a character ratio), so the last few thousand tokens of
    /// the window are never spent on excerpt text. This is also what pays for the
    /// instruction wrapper around the excerpt, which is not part of the text the
    /// budget is computed over.
    static let summarizeSafetyMarginTokens = 4096

    /// The least headroom held, on a window too small for the full-size figure.
    static let summarizeMinSafetyMarginTokens = 512

    /// Provider tokens per `DSHTokenEstimate` token, as a floor.
    ///
    /// `DSHTokenEstimate` divides `String.count` by 3.6 — a prose ratio. The
    /// engine's tokenizer is much denser on what a compaction actually shadows
    /// (file reads, tool JSON, CJK), and the device log brackets it from two
    /// independent directions:
    ///
    ///   * the summary requests themselves: 2026-10-19 09:28:47 was charged
    ///     140,371 provider tokens for the excerpt this app counted as
    ///     `beforeEst − afterEst = 79,899 − 19,177 = 60,722` (ratio 2.31);
    ///     09:33:11 the same way: 131,936 against `74,458 − 18,594 = 55,864`
    ///     (ratio 2.36);
    ///   * whole envelopes against their estimates: `189,581 / 77,655` = 2.44,
    ///     and five pairs on 2026-10-18 in 2.47…2.51.
    ///
    /// A budget computed in estimator units alone therefore prices the summary
    /// request 2.3–2.5x under what the engine charges. The floor is set above
    /// that band so ~20% of the window is still unspent after the conversion —
    /// which is the difference between a request the engine accepts and the
    /// 1,783,917-byte one it rejected at 2026-10-19 09:17:19
    /// (`context_length_exceeded` against a 262,144-token window; the same shape
    /// again at 2026-10-18 21:20:43, body 1,783,914 B).
    static let summarizeMeterRatioFloor = 3.0

    /// How many requests one compaction's summary may be split across.
    ///
    /// A bound rather than "as many as it takes": every segment is a full
    /// provider round-trip (43–47 s TTFT on the summary requests of 2026-10-19),
    /// so a compaction must not become an unbounded batch job while the turn
    /// waits. Four covers the observed corpus — the largest shadowed range on
    /// record needs three — and anything past the cap is folded into one
    /// head+tail excerpt with an explicit omission marker rather than dropped
    /// silently.
    static let summarizeMaxSegments = 4

    /// Separator between shadowed entries, and therefore between the paragraphs
    /// the excerpt is segmented on.
    ///
    /// The same `"\n\n"` `DSHCompaction.compact` joins its rendered entries with,
    /// so a segment boundary can only fall between two entries.
    static let summaryExcerptSeparator = "\n\n"

    /// The output ceiling for one route.
    ///
    /// Upstream sends `config.maxTokens` — 65,536 by default (`config.ts:76`,
    /// `summarizer.ts:158`) — and never adapts it. This app must, in two ways, and
    /// both are clamps on that figure rather than replacements for it:
    ///
    ///   * **the route's own output cap** (`routeOutputCap`). The summary request
    ///     goes through `streamAgentMessageClamped`, whose contract is that the
    ///     caller has already clamped `maxTokens` to the model's effective
    ///     maximum. Asking a route whose cap is 8,192 for 65,536 is a request the
    ///     provider rejects or silently truncates — and a truncated summary is
    ///     refused as a failure (`summarizeSegment`), so the compaction would
    ///     never succeed on such a route.
    ///   * **a quarter of the window**, kept from the previous rule so a small
    ///     route cannot spend its whole capacity on output: the summary request
    ///     also has to carry the replayed conversation plus the tool roster.
    ///
    /// The floor stays 1,024 — a small route must still be able to compact, and
    /// "no summary is possible on this model" is the outcome this exists to
    /// avoid. `routeOutputCap <= 0` is read as "no declared cap" and clamps
    /// nothing, which is the same convention `DSHTokenEstimate`'s callers use for
    /// an unknown capacity.
    ///
    /// - Parameters:
    ///   - contextWindow: capacity of the routed model.
    ///   - routeOutputCap: output tokens ONE routed request of this turn may emit
    ///     (`DSHTurnDriverConfig.maxTokens` in the driver, `dynamicMaxTokens(...)`
    ///     in `/compact`).
    /// - Returns: output tokens one summary request reserves.
    static func summarizeOutputCeiling(contextWindow: Int, routeOutputCap: Int) -> Int {
        var ceiling = min(summarizeMaxOutputTokens, max(summarizeMinOutputTokens, contextWindow / 4))
        if routeOutputCap > 0 { ceiling = min(ceiling, routeOutputCap) }
        return max(summarizeMinOutputTokens, ceiling)
    }

    /// The headroom held under one route's window.
    ///
    /// 4,096 on a full-size window, a 64th of the window below that, and never
    /// less than 512 — the floor is what keeps the wrapper's own cost covered on
    /// the smallest routes, and the min() is what keeps a window larger than
    /// 262,144 from holding back proportionally more than the full-size figure.
    ///
    /// - Parameter contextWindow: capacity of the routed model.
    /// - Returns: tokens held back from the excerpt budget.
    static func summarizeSafetyMargin(contextWindow: Int) -> Int {
        max(summarizeMinSafetyMarginTokens, min(summarizeSafetyMarginTokens, contextWindow / 64))
    }

    /// The largest region one summary request may carry, in estimator units.
    ///
    /// The assertion this exists to make, stated in the units the regioning works
    /// in: one request's estimated tokens — its messages, its tool roster, and
    /// the directive — must not exceed `window − maxOutput − margin` once the
    /// meter's error is priced in.
    ///
    /// - Parameters:
    ///   - contextWindow: capacity of the routed model.
    ///   - routeOutputCap: output tokens one routed request of this turn may emit.
    ///   - meterRatio: provider tokens per estimator token.
    /// - Returns: the per-request budget in `DSHTokenEstimate` units.
    static func summarizeInputBudgetTokens(
        contextWindow: Int,
        routeOutputCap: Int,
        meterRatio: Double
    ) -> Int {
        let requestable = contextWindow
            - summarizeOutputCeiling(contextWindow: contextWindow, routeOutputCap: routeOutputCap)
            - summarizeSafetyMargin(contextWindow: contextWindow)
        guard requestable > 0 else { return 0 }
        let ratio = max(1, meterRatio)
        return max(1, Int((Double(requestable) / ratio).rounded(.down)))
    }

    /// Provider tokens per estimator token for the request being summarized.
    ///
    /// A ratio and not a constant: how far the estimator is off depends on the
    /// content, so when the envelope being priced carries the provider's own
    /// count, that pair is the measurement. The floor keeps a pair that happens
    /// to agree from claiming the estimator is accurate on text this app has
    /// never been charged for.
    ///
    /// - Parameters:
    ///   - measuredTokens: the provider's count of the envelope, or 0.
    ///   - surfaceEstimate: `DSHTokenEstimate`'s count of the same content.
    /// - Returns: provider tokens per estimator token, at least the floor.
    static func summaryMeterRatio(measuredTokens: Int, surfaceEstimate: Int) -> Double {
        let estimate = max(1, surfaceEstimate)
        guard measuredTokens > estimate else { return summarizeMeterRatioFloor }
        let observed = Double(measuredTokens) / Double(estimate)
        return max(summarizeMeterRatioFloor, observed)
    }

    /// The same ratio for the envelope the pressure check just priced.
    ///
    /// The same composition as the gate's (`price.promptTokens` grown by the
    /// surface appended since it was priced), named in two steps rather than one:
    /// the gate's own line is asserted to be unique by
    /// `midturn-compaction-selftest.cjs`, and a second spelling of it would make
    /// "the measurement rule" two rules.
    private func summaryMeterRatioNow() -> Double {
        guard let price = lastPricedRequest, price.isProviderCount else {
            return Self.summarizeMeterRatioFloor
        }
        let surfaceNow = DSHTokenEstimate.total(session.surface())
        let growth = max(0, surfaceNow - price.surfaceTokens)
        let measured = price.promptTokens + growth
        return Self.summaryMeterRatio(measuredTokens: measured, surfaceEstimate: surfaceNow)
    }

    /// Split a shadowed excerpt into segments that each fit `budgetTokens`.
    ///
    /// Segmented rather than truncated: the range being compacted is the whole
    /// reason the compaction exists, and a head-only excerpt would summarize the
    /// beginning of a 111-entry range while the newest — and most load-bearing —
    /// part of it never reached the model. Splitting keeps every entry in exactly
    /// one segment, in surface order.
    ///
    /// Two shapes need care and both are handled here rather than at the call
    /// site: a single entry larger than the whole budget (one tool result can
    /// exceed a small route's per-segment budget on its own) is cut to fit, and a
    /// range that would need more than `maxSegments` requests has its remainder
    /// folded into one head+tail excerpt by `summaryHeadTailExcerpt`.
    ///
    /// - Parameters:
    ///   - text: the rendered shadowed excerpt.
    ///   - budgetTokens: per-segment budget, in `DSHTokenEstimate` units.
    ///   - maxSegments: upper bound on the number of segments returned.
    /// - Returns: the excerpt split into at most `maxSegments` pieces.
    static func chunkSummaryExcerpt(
        _ text: String,
        budgetTokens: Int,
        maxSegments: Int
    ) -> [String] {
        let budget = max(1, budgetTokens)
        let separator = summaryExcerptSeparator
        var segments: [String] = []
        var current = ""
        var currentTokens = 0
        func flush() {
            guard !current.isEmpty else { return }
            segments.append(current)
            current = ""
            currentTokens = 0
        }

        for paragraph in text.components(separatedBy: separator) {
            var piece = paragraph
            while !piece.isEmpty {
                let pieceTokens = DSHTokenEstimate.tokens(forText: piece)
                if currentTokens > 0, currentTokens + pieceTokens > budget { flush() }
                if currentTokens + pieceTokens <= budget {
                    current += current.isEmpty ? piece : separator + piece
                    currentTokens += pieceTokens
                    break
                }
                // One paragraph, or one entry, larger than a whole segment.
                // The cut is proportional to the token estimate rather than
                // converted through a characters-per-token constant, so it
                // cannot disagree with the meter this budget is stated in.
                let room = max(1, budget - currentTokens)
                let share = Double(room) / Double(max(1, pieceTokens))
                let chars = min(piece.count, max(1, Int((Double(piece.count) * share).rounded(.down))))
                let head = String(piece.prefix(chars))
                current += current.isEmpty ? head : separator + head
                flush()
                piece = String(piece.dropFirst(chars))
            }
        }
        flush()

        let cap = max(1, maxSegments)
        guard segments.count > cap else { return segments }
        let kept = Array(segments.prefix(cap - 1))
        let remainder = segments.dropFirst(cap - 1).joined(separator: separator)
        return kept + [summaryHeadTailExcerpt(remainder, budgetTokens: budget)]
    }

    /// A head+tail excerpt of `text` that fits `budgetTokens`.
    ///
    /// The last resort when a range needs more than `summarizeMaxSegments`
    /// requests. The middle is replaced by a marker that says so, inside the
    /// excerpt the model reads: an omission the summarizer can report is a fact
    /// about the summary, while a silent one is a summary that claims to cover a
    /// range it never saw.
    ///
    /// - Parameters:
    ///   - text: the excerpt remainder to compress into one segment.
    ///   - budgetTokens: per-segment budget, in `DSHTokenEstimate` units.
    /// - Returns: head + marker + tail, within the budget.
    static func summaryHeadTailExcerpt(_ text: String, budgetTokens: Int) -> String {
        let budget = max(1, budgetTokens)
        let total = max(1, DSHTokenEstimate.tokens(forText: text))
        let omitted = max(1, total - budget)
        let marker = summaryExcerptSeparator + "<omitted \(omitted) tokens> this range is too large "
            + "to summarize in one request; its middle is not in this excerpt"
            + summaryExcerptSeparator
        let markerTokens = DSHTokenEstimate.tokens(forText: marker)
        let usable = max(2, budget - markerTokens)
        let headTokens = usable / 2
        let tailTokens = usable - headTokens
        let chars = max(1, text.count)
        let headChars = min(chars, max(1, Int((Double(chars) * Double(headTokens) / Double(total)).rounded(.down))))
        let remaining = max(0, chars - headChars)
        let tailChars = min(remaining, max(1, Int((Double(chars) * Double(tailTokens) / Double(total)).rounded(.down))))
        return String(text.prefix(headChars)) + marker + String(text.suffix(tailChars))
    }

    // MARK: - Region Fitting

    /// One summary request's worth of a shadowed region.
    ///
    /// The message-level counterpart of the old text segment: what a request
    /// carries, measured, plus how much of the region had to be left out of it.
    struct DSHSummarySegment {
        /// The messages this request carries, in surface order.
        ///
        /// May begin with one explicit omission note and may contain one
        /// head+tail excerpt in place of a group that could not be replayed —
        /// both are ordinary `user` messages, so the request keeps upstream's
        /// shape (`summarizer.ts:145-151`) all the way down to the truncation.
        var messages: [AgentMessage]
        /// Estimated tokens this request spends on the region.
        var regionTokens: Int
        /// Surface entries that are NOT replayed whole in this request.
        var omittedEntries: Int
    }

    /// The estimator allowance one omission note is charged.
    ///
    /// The note is ~150 characters ≈ 42 estimator tokens; 64 leaves room for a
    /// six-digit token count and a two-digit entry count without re-measuring it
    /// inside the fitter's loop. Reserved from the budget BEFORE the kept entries
    /// are chosen, so a note can never push a request over.
    static let summaryOmissionNoteAllowanceTokens = 64

    /// The note a request carries when part of its region is not in it.
    ///
    /// Wording mirrors `summaryHeadTailExcerpt`'s marker on purpose: whichever
    /// shape the omission takes, the model reads the same sentence — "this much
    /// is missing, and here is why" — rather than one form that says so and one
    /// that silently drops text.
    ///
    /// - Parameters:
    ///   - omittedTokens: estimated tokens of the entries left out.
    ///   - omittedEntries: how many entries were left out.
    /// - Returns: the note, as one standalone paragraph.
    static func summaryOmissionNote(omittedTokens: Int, omittedEntries: Int) -> String {
        summaryExcerptSeparator
            + "<omitted \(max(1, omittedTokens)) tokens> \(max(1, omittedEntries)) earlier "
            + "entries of this range are too large to replay in one request; they are not "
            + "in this excerpt"
            + summaryExcerptSeparator
    }

    /// Split a replayed region into at most `maxSegments` request-sized segments.
    ///
    /// The unit is the SURFACE ENTRY, not rendered text: a request now carries
    /// messages (`DSHSummaryInput`), so a segment boundary has to fall between two
    /// entries — and at a tool-pairing balanced one, or the provider rejects the
    /// request for stranding a `tool_result`. `DSHToolPairing.cutBalances` gives
    /// every cut position, and the selection that produced the region already
    /// guarantees its first and last cuts are balanced, so a walk that only ever
    /// cuts on `true` stays valid end to end.
    ///
    /// THE CAP IS THE BRIEF'S GUARD. Upstream sends a region in one request
    /// (`summarizer.ts:145-151`) because its meter is exact. This app's is not,
    /// so the region is chunked while the chunks fit the budget; the moment the
    /// region needs more than `maxSegments` requests, everything past the cap is
    /// folded into ONE request by `fold` — drop the oldest entries from that
    /// remainder, keep the newest that fit, and put an explicit omission note in
    /// front. `maxSegments == 1` therefore produces exactly the one-request shape
    /// with the drop-oldest guard, which is the behaviour the plan called for;
    /// the shipped value keeps today's coverage on the corpus the device recorded
    /// (the 09:17 compaction's region needed three).
    ///
    /// - Parameters:
    ///   - input: the region to fit.
    ///   - budgetTokens: per-request budget, in `DSHTokenEstimate` units, for the
    ///     region. `summarizeExcerpt` has already taken the tool roster off.
    ///   - maxSegments: upper bound on the number of requests.
    /// - Returns: one segment per request, in region order.
    static func summarySegments(
        _ input: DSHSummaryInput,
        budgetTokens: Int,
        maxSegments: Int
    ) -> [DSHSummarySegment] {
        let budget = max(1, budgetTokens)
        // Degraded mode: a region with no entries to budget over. `DSHSummaryInput`
        // is assembled from surface entries, so this only fires for a caller that
        // built one from text — and there the text segmenter is still the rule.
        guard !input.entries.isEmpty, input.entries.count == input.messages.count else {
            return chunkSummaryExcerpt(
                input.renderedText,
                budgetTokens: budget,
                maxSegments: maxSegments
            ).map { piece in
                DSHSummarySegment(
                    messages: [AgentMessage(role: .user, parts: [.text(piece)])],
                    regionTokens: DSHTokenEstimate.tokens(forText: piece),
                    omittedEntries: 0
                )
            }
        }

        let estimates = input.entries.map { DSHTokenEstimate.tokens(for: $0) }
        let cuts = DSHToolPairing.cutBalances(input.entries)
        let texts = input.entryTexts
        let total = estimates.reduce(0, +)

        func whole(_ range: Range<Int>) -> DSHSummarySegment {
            DSHSummarySegment(
                messages: Array(input.messages[range]),
                regionTokens: estimates[range].reduce(0, +),
                omittedEntries: 0
            )
        }

        // Keep the newest entries of `range` that fit `room`, drop the rest, and
        // say so. The cut is walked forward to a balanced position: dropping MORE
        // than the budget requires is safe, keeping an unpaired tool result is not.
        func fold(_ range: Range<Int>) -> DSHSummarySegment {
            let rangeTotal = estimates[range].reduce(0, +)
            guard rangeTotal > budget else { return whole(range) }
            let room = max(1, budget - summaryOmissionNoteAllowanceTokens)
            var keepFrom = range.upperBound
            var kept = 0
            var index = range.upperBound
            while index > range.lowerBound {
                let cost = estimates[index - 1]
                if kept + cost > room { break }
                kept += cost
                index -= 1
                keepFrom = index
            }
            while keepFrom < range.upperBound, !cuts[keepFrom] { keepFrom += 1 }
            guard keepFrom < range.upperBound else {
                // Even the newest entry alone is over the budget. One entry that
                // cannot be replayed is the case `summaryHeadTailExcerpt` already
                // answers, so it becomes one excerpt message — explicit about its
                // own middle — instead of a request that cannot be sent.
                let excerpt = summaryHeadTailExcerpt(
                    texts[range.upperBound - 1],
                    budgetTokens: room
                )
                return DSHSummarySegment(
                    messages: [AgentMessage(role: .user, parts: [.text(excerpt)])],
                    regionTokens: DSHTokenEstimate.tokens(forText: excerpt),
                    omittedEntries: range.count - 1
                )
            }
            let dropped = range.lowerBound..<keepFrom
            let note = summaryOmissionNote(
                omittedTokens: estimates[dropped].reduce(0, +),
                omittedEntries: dropped.count
            )
            var messages = [AgentMessage(role: .user, parts: [.text(note)])]
            messages.append(contentsOf: input.messages[keepFrom..<range.upperBound])
            return DSHSummarySegment(
                messages: messages,
                regionTokens: kept + DSHTokenEstimate.tokens(forText: note),
                omittedEntries: dropped.count
            )
        }

        if total <= budget { return [whole(0..<estimates.count)] }

        // Walk forward, closing each group before the entry that would overflow
        // it, at the nearest balanced cut at or before that entry.
        var groups: [Range<Int>] = []
        var start = 0
        var index = 0
        var accumulated = 0
        while index < estimates.count {
            let cost = estimates[index]
            if accumulated > 0, accumulated + cost > budget {
                var cut = index
                while cut > start, !cuts[cut] { cut -= 1 }
                if cut > start {
                    groups.append(start..<cut)
                    start = cut
                    accumulated = 0
                    index = cut
                    continue
                }
            }
            accumulated += cost
            index += 1
        }
        groups.append(start..<estimates.count)

        // EVERY group goes through `fold`, not just the capped remainder: the walk
        // can only cut BETWEEN entries, so a group is over budget whenever one
        // entry alone is — a single 300 KB tool result, which no meter would fit
        // and no cut can shrink. `fold` is a no-op on a group that fits.
        let cap = max(1, maxSegments)
        guard groups.count > cap else { return groups.map(fold) }
        var segments = Array(groups.prefix(cap - 1)).map(fold)
        segments.append(fold(groups[cap - 1].lowerBound..<estimates.count))
        return segments
    }

    // MARK: - Summarization

    /// Ask the model to summarize the shadowed content.
    ///
    /// The plan, the segmentation, the requests and the truncation/emptiness
    /// refusals all live in `summarizeExcerpt` below, because `/compact` sends the
    /// same summary request and must not own a second copy of it. What stays here
    /// is the pair of facts THIS driver owns: which window its route has, and the
    /// meter ratio measured from its own priced envelope.
    ///
    /// [P0] Two things this call must not do, and both were observed on the
    /// device:
    ///
    ///   * send more excerpt than the window holds. 2026-10-19 09:17:19: a
    ///     1,783,917-byte summary request (~410k provider tokens) against a
    ///     262,144-token window, rejected by the engine with
    ///     `context_length_exceeded`; 2026-10-18 21:20:43 the same shape
    ///     (1,783,914 B). Springing from it: the engine never ran the request, so
    ///     it produced no text, and `compact()` has exactly one gate before it
    ///     commits — `summaryTokens < range.shadowedTokenCount` — which the fixed
    ///     `<context-summary>` boilerplate always passes (~120 estimator tokens
    ///     against a 41,693-token shadowed range). The compaction therefore
    ///     announced success, wrote a marker, and shadowed 111 entries with an
    ///     empty summary.
    ///   * accept "the model produced no text" as a summary. Upstream refuses it
    ///     outright (`compaction-basic/src/summarizer.ts:168-170`: an empty
    ///     summary throws), and this app did not: `summarize` collected the
    ///     deltas and returned whatever it had.
    ///
    /// Both are fixed in `summarizeExcerpt` rather than at the call site, so every
    /// path that summarizes — the pressure trigger, the provider-confirmed
    /// overflow recovery, and now the manual command — is bounded and every empty
    /// or truncated result is a failure. A failure leaves `DSHCompaction.compact`
    /// BEFORE `appendCompaction`: no summary entry, no surface change, no
    /// `didCompact`, and therefore no marker. The surface that was over threshold
    /// stays over threshold, which is what makes the next step's pressure check
    /// retry the compaction instead of losing the range.
    ///
    /// - Parameter input: the replayed region and its tool roster.
    /// - Returns: the summary, non-empty by construction.
    /// - Throws: `DSHCompactionError.summaryFailed` when there is no window to
    ///   budget against, or when a segment produced no text.
    private func summarize(_ input: DSHSummaryInput) async throws -> String {
        guard let window = config.contextWindow, window > 0 else {
            throw DSHCompactionError.summaryFailed("no context capacity to summarize against")
        }
        return try await Self.summarizeExcerpt(
            input,
            contextWindow: window,
            routeOutputCap: config.maxTokens,
            meterRatio: summaryMeterRatioNow(),
            provider: provider,
            logCategory: "CompactDiag"
        )
    }

    /// One replayed region in, one summary out — the ONE summary request this
    /// app sends, on either loop.
    ///
    /// WHY THIS IS SHARED RATHER THAN THE DRIVER'S OWN. `/compact` used to send
    /// the whole shadowed range as ONE request with a fixed `maxTokens: 4096`
    /// (`DSHCommandCompact.dshCompactSummarize`), while this driver had already
    /// learned what that shape gets wrong: the output ceiling has to scale with the
    /// route (`summarizeOutputCeiling`), a margin has to stay under the window
    /// (`summarizeSafetyMargin`), the region has to be fitted to what is left
    /// after converting for the meter's error (`summarizeInputBudgetTokens`), and
    /// what does not fit has to be omitted EXPLICITLY (`summaryOmissionNote`,
    /// `summaryHeadTailExcerpt`) rather than silently. Two implementations meant
    /// the same span produced two different requests, and the manual one was the
    /// unbounded one — the 1,783,917-byte request the engine rejected is exactly
    /// that shape, one path over. So there is one implementation and two callers;
    /// each caller supplies ONLY the facts it owns: which provider to route
    /// through, which window and output cap to budget against, and the tool
    /// roster its own registry declares.
    ///
    /// Upstream's analogue is `summarizeWithLlm` + the `SummarizationInput` it is
    /// given (`packages/compaction/compaction-basic/src/summarizer.ts:120-181`):
    /// one auxiliary call, the replayed conversation prefix as the messages, the
    /// compaction directive last (`:145-151`), the output ceiling as `maxTokens`
    /// (`:158`), the conversation's tool schemas alongside (`:152-162`), an empty
    /// summary thrown (`:169-171`) and a `max-tokens` finish thrown
    /// (`:203-206`). The region fitting below is this app's addition — the engine
    /// can send a region in one request because its meter is exact, and this
    /// app's estimator is not — but every refusal upstream makes is made here.
    ///
    /// DEVIATION WITH EVIDENCE — the durable envelope. Upstream frames the
    /// LANDED checkpoint as `CHECKPOINT_PREAMBLE + <compacted-summary> … </compacted-summary>`
    /// (`summarizer.ts:22-23` for the tags, `:26-30` for the preamble, `:70-71`
    /// and `:188-194` for `frameSummary`), and this app still frames it as
    /// `<context-summary>` via `DSHCompaction.summaryEnvelope` →
    /// `AIChatViewModel.compactSummaryWrappedText`. That is deliberate:
    /// **the reload path re-wraps a stored summary with the same function**
    /// (`AIChatViewModel+Persistence.swift`, both the marker write and the
    /// re-injection), so changing the live wording without changing that one would
    /// leave a conversation whose summary reads differently after a relaunch than
    /// it did in the reply that produced it. The envelope is therefore upstream's
    /// in shape (a framed background block) and this app's in literal, and it is
    /// the one place in this function where upstream's exact bytes are not copied.
    /// The INSTRUCTION (`DSHCompactionInstruction`) is copied byte for byte.
    ///
    /// - Parameters:
    ///   - input: the replayed region — its messages, its system head, its tool
    ///     roster, and the entries those messages were projected from.
    ///   - window: capacity of the routed model.
    ///   - routeOutputCap: output tokens one routed request of this turn may emit;
    ///     the summary request's `maxTokens` is clamped to it.
    ///   - ratio: provider tokens per `DSHTokenEstimate` token.
    ///   - provider: the route the request is sent on.
    ///   - logCategory: the `AppLogger` category the three diagnostic lines are
    ///     written under, and the bracketed tag in front of each — `CompactDiag` for
    ///     the driver's own compactions, `DSHCompact` for `/compact`, so a log
    ///     reader can tell the two callers apart while the sentences stay identical.
    /// - Returns: the assembled summary, non-empty by construction.
    /// - Throws: `DSHCompactionError.summaryFailed` when the window cannot hold a
    ///   request, when a segment produced no text or was truncated at the output
    ///   cap, or when the assembled summary is empty.
    static func summarizeExcerpt(
        _ input: DSHSummaryInput,
        contextWindow window: Int,
        routeOutputCap: Int,
        meterRatio ratio: Double,
        provider: any AgentProvider,
        logCategory: String
    ) async throws -> String {
        let diag = AppLogger(category: logCategory)
        let tag = "[\(logCategory)] "
        let ceiling = Self.summarizeOutputCeiling(
            contextWindow: window,
            routeOutputCap: routeOutputCap
        )
        let margin = Self.summarizeSafetyMargin(contextWindow: window)
        let budget = Self.summarizeInputBudgetTokens(
            contextWindow: window,
            routeOutputCap: routeOutputCap,
            meterRatio: ratio
        )
        guard budget > 0 else {
            let limits = "window=\(window) maxOutput=\(ceiling) margin=\(margin)"
            throw DSHCompactionError.summaryFailed("no summary input budget: \(limits)")
        }

        // The roster rides in the request and cannot be shrunk with the region,
        // so it comes off the budget before the region is measured. Leaving it out
        // prices every request low by the roster's whole cost — on this app's
        // roster that is ~14k tokens, i.e. exactly the overshoot that produced the
        // 2026-10-19 rejection the budget exists to prevent.
        let toolTokens = DSHTokenEstimate.tokens(forTools: input.tools)
        let regionBudget = budget - toolTokens

        let segments = Self.summarySegments(
            input,
            budgetTokens: max(1, regionBudget),
            maxSegments: Self.summarizeMaxSegments
        )
        guard !segments.isEmpty else {
            throw DSHCompactionError.summaryFailed(
                "nothing to summarize (excerptChars=\(input.renderedText.count))"
            )
        }
        // The assertion, in the numbers that will appear in the log: the largest
        // request's region, times the ratio, plus the roster, is what the engine
        // will charge for it, and it has to fit beside the output reservation and
        // the margin. `excerptTokens` is what the range costs the estimator; the
        // provider figure is that times the ratio.
        let excerptTokens = DSHTokenEstimate.tokens(forText: input.renderedText)
        let largest = segments.map { $0.regionTokens }.max() ?? 0
        let providerEquivalent = Int((Double(largest) * ratio).rounded())
        let requestable = window - ceiling - margin
        let omittedEntries = segments.reduce(0) { $0 + $1.omittedEntries }
        let plan = "excerptChars=\(input.renderedText.count) excerptTokensEst=\(excerptTokens) "
            + "segments=\(segments.count) budgetEst=\(budget) "
            + "regionBudgetEst=\(max(1, regionBudget)) toolEst=\(toolTokens) ratio=\(ratio) "
            + "largestSegmentEst=\(largest) largestSegmentProviderEst=\(providerEquivalent) "
            + "requestable=\(requestable) omittedEntries=\(omittedEntries) "
            + "messages=\(input.messages.count) tools=\(input.tools.count) "
            + "systemChars=\(input.systemPrompt?.count ?? 0) maxTokens=\(ceiling)"
        diag.warning(tag + "summary request planned: \(plan)")

        var parts: [String] = []
        for (index, segment) in segments.enumerated() {
            // A cancelled task stops between segments rather than after the last
            // one: `/compact` cancels its own task when the user leaves, and a
            // summary request is 40+ seconds of billed prefill. The driver's
            // `cancel()` is a flag on the turn, not a task cancellation, so this
            // costs it nothing.
            try Task.checkCancellation()
            let produced = try await Self.summarizeSegment(
                segment,
                systemPrompt: input.systemPrompt,
                tools: input.tools,
                index: index + 1,
                of: segments.count,
                outputCeiling: ceiling,
                provider: provider
            )
            let trimmed = produced.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                diag.warning(tag + "summary segment produced no text: summaryChars=0 "
                    + "segment=\(index + 1)/\(segments.count) "
                    + "excerptChars=\(segment.regionTokens) tokens "
                    + "— refusing the compaction rather than shadowing with an empty summary")
                throw DSHCompactionError.summaryFailed(
                    "empty summary (summaryChars=0, segment \(index + 1)/\(segments.count), "
                        + "excerptEst=\(segment.regionTokens) tokens, "
                        + "messages=\(segment.messages.count))"
                )
            }
            parts.append(trimmed)
        }

        let summary = parts.joined(separator: Self.summaryExcerptSeparator)
        let summaryChars = summary.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard summaryChars > 0 else {
            throw DSHCompactionError.summaryFailed("empty summary (summaryChars=0)")
        }
        diag.warning(tag + "summary generated: summaryChars=\(summaryChars) "
            + "segments=\(segments.count) excerptChars=\(input.renderedText.count)")
        return summary
    }

    /// One summary request: one segment of the shadowed region.
    ///
    /// THE REQUEST IS UPSTREAM'S SHAPE, not "one excerpt": the segment's messages
    /// are the conversation's own (the same parts the routed request replays), the
    /// derived system head is passed as a system prompt, the conversation's tool
    /// roster rides along, and the compaction directive is the FINAL user message
    /// (`packages/compaction/compaction-basic/src/summarizer.ts:145-151`). There
    /// is no summarizer system prompt and no `<excerpt>` wrapper: the directive
    /// says what to produce, and the replayed conversation above it is the thing
    /// to condense.
    ///
    /// The instruction is the same text for every request; a segment only adds a
    /// line that tells the model which part it is reading, so a compaction that
    /// needs one request sends exactly what a single-request compaction sends —
    /// and `/compact`, which calls this too, sends exactly what the driver sends
    /// for the same span.
    ///
    /// - Parameters:
    ///   - segment: the messages this request carries.
    ///   - systemPrompt: the derived system head, or nil.
    ///   - tools: the conversation's tool roster.
    ///   - index: 1-based position of this segment.
    ///   - count: how many segments the region was split into.
    ///   - outputCeiling: output tokens this route can reserve for the summary.
    ///   - provider: the route the request is sent on.
    /// - Returns: the text the model produced, which the caller requires to be
    ///   non-empty.
    /// - Throws: `DSHCompactionError.summaryFailed` when the stream's terminal
    ///   reason is the output cap.
    static func summarizeSegment(
        _ segment: DSHSummarySegment,
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        index: Int,
        of count: Int,
        outputCeiling: Int,
        provider: any AgentProvider
    ) async throws -> String {
        let body = DSHCompactionInstruction.text
        let instruction = count > 1
            ? "This is segment \(index) of \(count) of one long conversation range. Summarize "
                + "only this segment; the other segments are summarized separately.\n\n" + body
            : body

        var messages = segment.messages
        messages.append(AgentMessage(role: .user, parts: [.text(instruction)]))
        let stream = try await provider.streamAgentMessageClamped(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: outputCeiling,
            thinkingLevel: .off
        )

        var summary = ""
        var stopReason: AgentStopReason?
        for try await event in stream {
            if case .textDelta(let delta) = event { summary += delta }
            // The terminal reason is the fact the turn loop already reads for its
            // own truncation (`AgentStreamEvent.done`), so it is read here too.
            if case .done(let reason) = event { stopReason = reason }
        }
        // Upstream fails a summarization whose terminal reason is the token cap
        // rather than framing the truncated text as a complete checkpoint
        // (`packages/compaction/compaction-basic/src/summarizer.ts:203-206`,
        // `finishError`, error code `MAX_TOKENS`). A truncated "summary" is the
        // same defect class as an empty one: it shadows a whole range with half a
        // checkpoint, and the compaction's only gate
        // (`summaryTokens < range.shadowedTokenCount`) passes it.
        if let reason = stopReason, case .maxTokens = reason {
            throw DSHCompactionError.summaryFailed(
                "the summarizer was truncated at the token cap (incomplete checkpoint)"
            )
        }
        return summary
    }

    // MARK: - Request Building

    private struct LoopRequest {
        var messages: [AgentMessage]
        var systemPrompt: String?
        var tools: [AgentToolDefinition]
        var thinkingLevel: ThinkingLevel
    }

    /// The tool roster a summary request replays.
    ///
    /// The same conversion `buildRequest` performs on the same registry
    /// (`registry.schemas().map(DSHToolSchemaBridge.toAgentToolDefinition)`), named
    /// once because a compaction now sends it too
    /// (`DSHCompaction.compact(summaryTools:)` ← `region.ts:560`'s
    /// `header.tools`). Two spellings of this conversion would let the summary
    /// request advertise a different tool set than the conversation it is a
    /// prefix of, which is exactly what the prefix-cache alignment is for.
    ///
    /// - Returns: this turn's provider-facing tool definitions, in registry order.
    private func summaryToolRoster() -> [AgentToolDefinition] {
        registry.schemas().map(DSHToolSchemaBridge.toAgentToolDefinition)
    }

    /// Build one step's request from the current surface.
    ///
    /// The surface is recomputed every step, so a compaction that landed
    /// mid-turn is reflected here without any index bookkeeping.
    private func buildRequest() -> LoopRequest {
        let schemas = registry.schemas()
        let context = DSHAssembleContext(
            model: provider.model.id,
            provider: provider.name,
            cwd: nil,
            toolNames: schemas.map(\.name),
            isHelper: false
        )

        let assembly = prompt.assemble(
            tools: schemas,
            context: context,
            toolOrder: config.toolOrder
        )

        var systemPrompt = DSHSystemPrompt.renderPrompt(excludingVolatileSectionsOf: assembly)
        let snapshot = DSHSystemPrompt.renderContextSnapshot(assembly)
        if !snapshot.isEmpty {
            systemPrompt += "\n\n" + snapshot
        }

        // [P1-2] The volatile half of the assembly — memory fragments and the
        // runtime facts — must NOT reach the system prompt: it is the prefix the
        // engine's KV cache matches on, and a turn that wrote a memory used to
        // rewrite bytes at the head of the next request, dropping cache from
        // 99.5% to 0.0%. It rides as a message instead, admitted at the head of the
        // conversation (`historyWithVolatileTurnContext`) — an index the
        // conversation's own growth cannot move, which is the one property this
        // engine's cache actually needs: it reuses a prompt only while the request
        // extends one it still holds. Upstream DSH keeps the same invariant by
        // admitting its runtime-context snapshot once and never moving it
        // (`packages/core/agent-loop/src/runtime-context.ts`,
        // `RuntimeContextProjection.project`). Same text, different message — the
        // model's view is unchanged, the cached prefix is not.
        //
        // This is recomputed every step from the same assembly, so a mid-turn
        // `memory_write` shows up in the next step's request rather than being
        // frozen for the whole turn.
        let volatileSections = DSHSystemPrompt.renderVolatileSections(assembly)
        let tailContext = AIChatViewModel.volatileTurnContextSuffix(
            runtimeFacts: [],
            memoryEnabled: config.memoryEnabled,
            extraParts: volatileSections.isEmpty ? [] : [volatileSections]
        )

        // [T-tools-todo-plan] Which sections actually made it into this request.
        //
        // The operator turned plan mode on and the model carried on with the work
        // instead of planning, then only planned after being told in prose that the
        // mode was on — which is what a policy section that never reached the
        // request looks like from the outside. `assemble` evaluates a section's
        // `dynamic` provider per assembly and `renderPrompt` drops empty ones, so the
        // section CAN be absent for two different reasons (the mode is off, or the
        // registry never got it) and the two are indistinguishable from the reply.
        // One line makes them distinguishable, and names the section so a rename
        // cannot quietly break the check.
        //
        // `volatileChars` is the other half of the same question: it says how much
        // of the assembly moved out of the prompt and into the tail message.
        AppLogger(category: "DSHLoop").info(
            "[DSH] prompt sections=[\(assembly.sections.map(\.name).joined(separator: ","))] "
            + "chars=\(systemPrompt.count) volatileChars=\(tailContext?.count ?? 0) "
            + "tools=\(schemas.count) planMode=\(DSHTodoStore.shared.planModeActive)"
        )

        // [T-ctx-breakdown] Measure the request HERE, where all three inputs are
        // in hand at once: the rendered system prompt, the tool roster and the
        // surface the messages are projected from. The composer's context panel
        // shows these three as the request's components, and estimating them
        // anywhere else would describe a different request than the one about to
        // be sent — which is exactly what the old "estimate the surface from the
        // UI" reads were.
        //
        // `sectionNames` is filtered to the sections that carried text, so the
        // panel lists what actually reached the prompt: `plan:policy` is
        // registered on every turn but renders empty while plan mode is off, and
        // `renderPrompt` drops empty sections.
        //
        // The tail message is a fourth component and is counted into the surface
        // figure below, so the panel's total still prices the whole request rather
        // than the prompt alone.
        let projected = projectMessages(session.surfaceMessages())
        let requestMessages = AIChatViewModel.historyWithVolatileTurnContext(projected, suffix: tailContext)

        // Price the envelope here, where all three of its inputs are in hand at
        // once: the rendered system prompt, the tool roster, and the surface the
        // messages are projected from. DSH prices the latest durable routed
        // request; building one is the moment this driver knows what that request
        // holds, and the next step's pressure check reads exactly this figure.
        //
        // `tailContext` is added to the surface figure because it is a message and
        // not prompt text — leaving it out would under-price every request on the
        // one path that has to decide whether the next one still fits.
        let pricedSurface = DSHTokenEstimate.total(session.surface())
            + DSHTokenEstimate.tokens(forText: tailContext ?? "")
        // [T-ctx-usage-one-denominator] The breakdown just recorded IS this
        // request's whole envelope, priced from the same three inputs. Taking it
        // back instead of recomputing keeps the two consumers on one number: the
        // compaction gate wants `pricedSurface` (the only part a compaction can
        // shrink), the usage store's projection wants this total.
        let pricedBreakdown = DSHContextBreakdownStore.shared.record(
            systemPrompt: systemPrompt,
            tools: schemas,
            surface: session.surface(),
            sectionNames: assembly.sections.filter { !$0.text.isEmpty }.map(\.name),
            model: provider.model.id,
            provider: provider.name,
            sessionKey: config.sessionKey,
            // The capacity THIS STEP was assembled for, which is the settings
            // screen's "session model window" and the turn-start log's `window=`.
            //
            // `config.contextWindow` is `effectiveContextWindow(for: entry.model)`
            // (`DSHTurnDriverRun.swift:806`) — the SAME call, on the same model, that
            // the turn-start line captures into `resolvedWindow` and prints as
            // `window=` (`:862`, logged at `:874-889`). Both run before `driver.run()`,
            // so within a turn they are one value: `init` only clamps a non-positive
            // window to nil (`DSHTurnDriver.swift:270-274`), which is the one case
            // where this field is nil and the log would print 0 — "no capacity" either
            // way. Recording it here rather than re-resolving it in the settings screen
            // is what keeps that row from describing a different route than the turn.
            windowTokens: config.contextWindow
        )
        lastPricedRequest = PricedRequest(
            promptTokens: DSHTokenEstimate.tokens(forText: systemPrompt)
                + DSHTokenEstimate.tokens(forToolSchemas: schemas)
                + pricedSurface,
            reservedCompletionTokens: config.reservedOutputTokens,
            surfaceTokens: pricedSurface,
            envelopeTokens: pricedBreakdown.estimatedTotal,
            isProviderCount: false
        )

        return LoopRequest(
            messages: requestMessages,
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            tools: schemas.map(DSHToolSchemaBridge.toAgentToolDefinition),
            thinkingLevel: config.thinkingLevel
        )
    }

    /// Project the surface's messages into the provider's message type.
    private func projectMessages(_ messages: [DSHMessage]) -> [AgentMessage] {
        messages.compactMap { message -> AgentMessage? in
            var parts: [AgentContentPart] = []
            var toolArguments: [String: AgentToolArguments.Record] = [:]
            for block in message.blocks {
                switch block {
                case let text as DSHTextBlock:
                    parts.append(.text(text.text))
                case let reasoning as DSHReasoningBlock:
                    parts.append(.text(reasoning.text))
                case let call as DSHToolCallBlock:
                    // The block keeps the model's own `arguments` bytes; the
                    // dictionary is for execution only. Replaying the dictionary
                    // re-orders the keys and invalidates the engine's KV prefix
                    // on every turn — see AgentToolArguments.
                    let args = (try? JSONSerialization.jsonObject(
                        with: Data(call.arguments.utf8)
                    )) as? [String: Any] ?? [:]
                    parts.append(.toolUse(id: call.id, name: call.name, input: args))
                    if !args.isEmpty {
                        toolArguments[call.id] = AgentToolArguments.Record(text: call.arguments, input: args)
                    }
                case let result as DSHToolResultBlock:
                    parts.append(.toolResult(
                        id: result.callId,
                        name: result.name,
                        content: result.content,
                        isError: result.isError,
                        imageData: result.imageData,
                        imageMimeType: result.imageMimeType,
                        pageURL: result.pageURL,
                        imageLinuxPath: result.imageLinuxPath
                    ))
                case let image as DSHImageBlock:
                    parts.append(.imageData(
                        data: image.data, mimeType: image.mimeType, linuxPath: image.path
                    ))
                case let file as DSHFileBlock:
                    parts.append(.text("[file: \(file.name) (\(file.size) bytes)]"))
                default:
                    continue
                }
            }
            guard !parts.isEmpty else { return nil }
            var projected = AgentMessage(
                role: DSHSessionProjection.agentRole(for: message.role),
                parts: parts
            )
            projected.toolArguments = toolArguments
            return projected
        }
    }

    // MARK: - Result Commit

    private func commitResult(_ commit: DSHToolCommit, turn: Int) {
        delegate?.driver(
            self,
            didFinishTool: commit.block.name,
            callId: commit.block.id,
            result: commit.result
        )

        // [T-dsh-spill] The overflow hook has already bounded `commit.result`,
        // so what is appended here IS what the model will read: head, elision
        // marker, tail, and the notice naming the file holding the whole thing.
        // DSH reaches the same state from a `tools/post-execute` listener; the
        // invariant both forms keep is that nothing downstream of the hook can
        // observe the unbounded result.
        var content = commit.result.content
        if commit.started {
            let verdict = gate.record(
                toolName: commit.block.name,
                result: commit.result.content,
                errorMessage: commit.result.isError ? commit.result.content : nil,
                warningThreshold: config.loopWarningThreshold,
                criticalThreshold: config.loopCriticalThreshold
            )
            if let warning = verdict.message {
                content += "\n\n" + warning
            }
        }

        session.append(DSHMessage(role: .tool, blocks: [
            DSHToolResultBlock(
                callId: commit.block.id,
                name: commit.block.name,
                content: content,
                isError: commit.result.isError,
                imageData: commit.result.imageData,
                imageMimeType: commit.result.imageMimeType,
                pageURL: commit.result.pageURL,
                imageLinuxPath: commit.result.imageLinuxPath
            ),
        ]), turn: turn)
    }

    /// Record a call the loop guard refused to dispatch.
    ///
    /// The call never ran, so the model gets the reason as its result rather
    /// than a duplicate execution.
    /// Call ids whose transcript block has already been announced this turn.
    ///
    /// [T-ios-tool-announce-in-stream] Tool calls are announced as they complete
    /// streaming; this makes the pre-dispatch batch announce idempotent for the
    /// paths that reach it without having announced (and guards against a provider
    /// re-emitting a call id).
    private var announcedCallIds = Set<String>()

    private func recordBlocked(
        callId: String,
        name: String,
        verdict: DSHToolGate.Verdict,
        turn: Int
    ) {
        let result = DSHToolExecutionResult(
            content: verdict.message ?? "Error: blocked by loop guard",
            isError: true
        )
        delegate?.driver(
            self,
            didFinishTool: name,
            callId: callId,
            result: result
        )
        session.append(DSHMessage(role: .tool, blocks: [
            DSHToolResultBlock(
                callId: callId,
                name: name,
                content: result.content,
                isError: true
            ),
        ]), turn: turn)
    }

    // MARK: - Helpers

    private func encodeArguments(_ args: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Recover a committed call's arguments, for the loop guard's key.
    private func decodeArguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

// MARK: - Currency Conversion

extension DSHCompactionSpec {
    /// The same resolved budget with a different retained-tail figure.
    ///
    /// [P1-3] `DSHCompactionSpec` is a value type whose fields are all `let`, and
    /// the driver has to hand the selection a budget expressed in the units that
    /// selection counts with — see `DSHTurnDriver.calibratedRetainBudget`. Only
    /// `retainTokens` moves: the threshold, the capacity, the headroom, and both
    /// retry budgets are the policy's own and are not the driver's to reinterpret.
    ///
    /// Kept here rather than as a method on the type so that the one place which
    /// knows WHY the budget is converted is also the one place that builds the
    /// converted value, and so `DSHCompaction.swift` — shared byte-for-byte by both
    /// trees and owned by another change — keeps no driver-specific helper.
    ///
    /// - Parameter tokens: retained-tail budget in the caller's units.
    /// - Returns: the same spec with that budget.
    func replacingRetainTokens(_ tokens: Int) -> DSHCompactionSpec {
        DSHCompactionSpec(
            contextWindow: contextWindow,
            reservedCompletionTokens: reservedCompletionTokens,
            thresholdRatio: thresholdRatio,
            headroomTokens: headroomTokens,
            thresholdTokens: thresholdTokens,
            retainTokens: tokens,
            compactionRetries: compactionRetries,
            maxOverflowRetries: maxOverflowRetries
        )
    }
}
