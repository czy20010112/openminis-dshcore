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
    /// Maximum steps in one turn before the driver stops and reports.
    public var maxStepsPerTurn: Int
    /// Maximum tokens for one model response.
    public var maxTokens: Int
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
        maxStepsPerTurn: Int = 200,
        maxTokens: Int = 32_000,
        thinkingLevel: ThinkingLevel = .off,
        enableLoopGuard: Bool = true,
        loopWarningThreshold: Int = 10,
        loopCriticalThreshold: Int = 20,
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
        self.maxStepsPerTurn = max(1, maxStepsPerTurn)
        self.maxTokens = maxTokens
        self.thinkingLevel = thinkingLevel
        self.enableLoopGuard = enableLoopGuard
        self.loopWarningThreshold = max(1, loopWarningThreshold)
        self.loopCriticalThreshold = max(self.loopWarningThreshold + 1, loopCriticalThreshold)
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
    private struct PricedRequest {
        /// Prompt tokens the provider counted, or the estimated envelope total.
        let promptTokens: Int
        /// Output tokens the request reserved inside the window.
        let reservedCompletionTokens: Int
        /// Surface tokens the envelope was measured with.
        let surfaceTokens: Int
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
        reportedSkips.removeAll()
        // Prime the priced envelope before the first step, so a turn that opens
        // on an already-over-threshold conversation compacts before its first
        // request instead of spending that request to discover the overflow.
        // DSH reads this from the previous turn's durable request header; the
        // driver is constructed per turn here, so it measures the envelope it is
        // about to send.
        if config.autoCompactionEnabled {
            lastPricedRequest = measureRequestEnvelope()
        }

        while step < config.maxStepsPerTurn {
            if cancelled {
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
                            maxTokens: request.maxTokens,
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
                            delegate?.driver(self, didEndTurn: .cancelled)
                            return .cancelled
                        }
                        continue
                    } catch {
                        let failure = error as? DSHFailure
                            ?? DSHFailure(message: String(describing: error), code: "PROVIDER_ERROR")
                        if await recoverFromContextOverflow(failure, turn: turn, step: step) {
                            request = buildRequest()
                            continue attemptLoop
                        }
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
                    delegate?.driver(self, didFail: failure)
                    return .cancelled
                }
                break attemptLoop
            }

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
                case .endTurn, .refusal, .toolUse: reason = .completed
                case .maxTokens: reason = .maxSteps
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

        delegate?.driver(self, didEndTurn: .maxSteps)
        return .maxSteps
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

        let spec: DSHCompactionSpec
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
                provider: provider.name
            ) { [weak self] shadowedText in
                guard let self else { throw DSHCompactionError.summaryFailed("driver deallocated") }
                return try await self.summarize(shadowedText)
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
                    + specFacts(spec, measured: measured, source: measuredSource)
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
                        + "reason=\(reason) \(specFacts(spec, measured: measured, source: measuredSource)) "
                        + "surfaceEntries=\(entries)"
                    )
                }
                return
            }
        }

        let attempts = spec.compactionRetries + 1
        AppLogger(category: "CompactDiag").warning(
            "[CompactDiag] mid-turn compaction still above threshold at turn=\(turn) step=\(step) "
            + "after \(attempts) attempt(s): \(specFacts(spec, measured: measured, source: measuredSource))"
        )
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
    /// A named piece rather than one long `+` chain: a single chain holding a
    /// dozen interpolations over mixed `Int`/`Double`/`String` operands makes the
    /// type checker search every overload combination, and the whole expression
    /// gets rejected as "unable to type-check in reasonable time" — a real build
    /// failure that a local syntax check cannot see.
    ///
    /// - Parameters:
    ///   - spec: the resolved trigger budget.
    ///   - measured: the priced envelope the threshold was compared against.
    ///   - source: whether that envelope carries a provider count.
    /// - Returns: one line's worth of threshold, window, and retention facts.
    private func specFacts(
        _ spec: DSHCompactionSpec,
        measured: Int,
        source: DSHContextUsageSource = .requestEnvelopeEstimate
    ) -> String {
        let kind = source == .providerMeasured ? "provider" : "estimated"
        return "measured=\(measured)(\(kind)) threshold=\(spec.thresholdTokens)"
            + " window=\(spec.contextWindow) retain=\(spec.retainTokens)"
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

        let result = await DSHCompaction.compact(
            session: session,
            turn: turn,
            retainTokens: 0,
            pressureThreshold: 0,
            measuredTokens: 0,
            model: provider.model.id,
            provider: provider.name
        ) { [weak self] shadowedText in
            guard let self else { throw DSHCompactionError.summaryFailed("driver deallocated") }
            return try await self.summarize(shadowedText)
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
            reservedCompletionTokens: config.maxTokens,
            surfaceTokens: surfaceTokens,
            isProviderCount: false
        )
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
            isProviderCount: true
        )
        DSHContextUsageStore.shared.record(
            promptTokens: reported,
            envelopeTokens: built.surfaceTokens,
            sessionKey: config.sessionKey
        )
    }

    /// Resolve this driver's trigger budget for one routed request.
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
        guard let window = config.contextWindow else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "no context capacity for \(targetKey); the serving model "
                    + "declares no context window"
            )
        }
        var policy = config.compactionPolicy
        if let retain = config.compactionRetainTokensOverride {
            policy.retainTokens = retain
        }
        let spec = try policy.resolveSpec(
            targetKey: targetKey,
            contextWindow: window,
            reservedCompletionTokens: reservedCompletionTokens
        )
        guard let threshold = config.compactionPressureTokensOverride else { return spec }
        return spec.overridingThreshold(threshold)
    }

    /// Ask the model to summarize the shadowed content.
    private func summarize(_ text: String) async throws -> String {
        let instruction = """
        Summarize the conversation excerpt below. Preserve: decisions made, facts \
        established, file paths and identifiers, current task state, and anything \
        the next turn must know to continue. Drop: repeated attempts that failed, \
        verbose tool output already superseded, and pleasantries.

        Be concrete and terse. Do not address the user. Do not invent facts not \
        present in the excerpt.

        <excerpt>
        \(text)
        </excerpt>
        """

        let messages = [AgentMessage(role: .user, parts: [.text(instruction)])]
        let stream = try await provider.streamAgentMessageClamped(
            messages: messages,
            systemPrompt: "You are a precise conversation summarizer.",
            tools: [],
            maxTokens: 4096,
            thinkingLevel: .off
        )

        var summary = ""
        for try await event in stream {
            if case .textDelta(let delta) = event { summary += delta }
        }
        return summary
    }

    // MARK: - Request Building

    private struct LoopRequest {
        var messages: [AgentMessage]
        var systemPrompt: String?
        var tools: [AgentToolDefinition]
        var maxTokens: Int
        var thinkingLevel: ThinkingLevel
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
        DSHContextBreakdownStore.shared.record(
            systemPrompt: systemPrompt,
            tools: schemas,
            surface: session.surface(),
            sectionNames: assembly.sections.filter { !$0.text.isEmpty }.map(\.name),
            model: provider.model.id,
            provider: provider.name,
            sessionKey: config.sessionKey
        )

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
        lastPricedRequest = PricedRequest(
            promptTokens: DSHTokenEstimate.tokens(forText: systemPrompt)
                + DSHTokenEstimate.tokens(forToolSchemas: schemas)
                + pricedSurface,
            reservedCompletionTokens: config.maxTokens,
            surfaceTokens: pricedSurface,
            isProviderCount: false
        )
        // The measured context record's growth baseline moves to the envelope just
        // assembled. This is the only place that knows the envelope the NEXT
        // receipt will cover, so it is the only place that can stop the projection
        // from counting a step's appends twice: the response's own tokens land on
        // the surface before its report arrives, and that report's count already
        // includes them.
        DSHContextUsageStore.shared.rebase(envelopeTokens: pricedSurface)

        return LoopRequest(
            messages: requestMessages,
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            tools: schemas.map(DSHToolSchemaBridge.toAgentToolDefinition),
            maxTokens: config.maxTokens,
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
