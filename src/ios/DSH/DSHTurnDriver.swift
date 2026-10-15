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
    /// Recent-tail budget retained verbatim by a compaction.
    public var compactionRetainTokens: Int
    /// Total surface tokens above which a compaction is worth doing.
    public var compactionPressureTokens: Int
    /// Whether automatic compaction is enabled.
    public var autoCompactionEnabled: Bool
    /// Ordered tool names, with the rest marker exactly once. nil means
    /// lexicographic order.
    public var toolOrder: [String]?

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
    public var streamRetryDelays: [Int]

    public init(
        maxParallelToolCalls: Int = 4,
        maxStepsPerTurn: Int = 200,
        maxTokens: Int = 32_000,
        thinkingLevel: ThinkingLevel = .off,
        enableLoopGuard: Bool = true,
        loopWarningThreshold: Int = 10,
        loopCriticalThreshold: Int = 20,
        compactionRetainTokens: Int = 20_000,
        compactionPressureTokens: Int = 120_000,
        autoCompactionEnabled: Bool = true,
        toolOrder: [String]? = nil,
        streamRetryDelays: [Int] = [3, 5, 10, 15, 30]
    ) {
        self.maxParallelToolCalls = max(1, maxParallelToolCalls)
        self.maxStepsPerTurn = max(1, maxStepsPerTurn)
        self.maxTokens = maxTokens
        self.thinkingLevel = thinkingLevel
        self.enableLoopGuard = enableLoopGuard
        self.loopWarningThreshold = max(1, loopWarningThreshold)
        self.loopCriticalThreshold = max(self.loopWarningThreshold + 1, loopCriticalThreshold)
        self.compactionRetainTokens = max(0, compactionRetainTokens)
        self.compactionPressureTokens = max(1, compactionPressureTokens)
        self.autoCompactionEnabled = autoCompactionEnabled
        self.toolOrder = toolOrder
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

    public weak var delegate: (any DSHTurnDriverDelegate)?

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

        // Counters are per turn, so a call repeated across turns is not a loop.
        gate.reset()

        while step < config.maxStepsPerTurn {
            if cancelled {
                delegate?.driver(self, didEndTurn: .cancelled)
                return .cancelled
            }

            step += 1
            delegate?.driver(self, didStartStep: turn, step: step)

            // Automatic compaction, before the request is built. Running it here
            // rather than inside the request builder keeps the surface the model
            // sees consistent with the surface the driver just measured.
            if config.autoCompactionEnabled {
                await maybeCompact(turn: turn)
            }

            let request = buildRequest()

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
                    delegate?.driver(self, didFail: failure)
                    return .cancelled
                }
            }

            var assistantParts: [DSHContentBlock] = []
            var toolCalls: [DSHToolCallBlock] = []
            var stopReason: AgentStopReason = .endTurn
            var usage = DSHTokenUsage()

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

                    case .responseModel:
                        // [T-agent-model-identity] The model the API reported
                        // serving. Identity reporting is the ViewModel's
                        // concern; the driver addresses the model it was
                        // configured with, so this carries no loop state.
                        break

                    case .toolCallComplete(let id, let name, let args, _):
                        let block = DSHToolCallBlock(
                            id: id, name: name, arguments: encodeArguments(args)
                        )
                        toolCalls.append(block)
                        assistantParts.append(block)

                    case .usage(let reported):
                        usage.inputTokens += reported.inputTokens
                        usage.outputTokens += reported.outputTokens
                        if let v = reported.cacheCreationInputTokens {
                            usage.cacheWriteTokens = (usage.cacheWriteTokens ?? 0) + v
                        }
                        if let v = reported.cacheReadInputTokens {
                            usage.cacheReadTokens = (usage.cacheReadTokens ?? 0) + v
                        }
                        delegate?.driver(self, didReportUsage: usage)

                    case .done(let reason):
                        stopReason = reason
                    }
                }
            } catch {
                let failure = error as? DSHFailure
                    ?? DSHFailure(message: String(describing: error), code: "STREAM_ERROR")
                delegate?.driver(self, didFail: failure)
                return .cancelled
            }

            // Commit the assistant turn before any tool results, so the
            // conversation stays provider-valid (tool_use then tool_result).
            if !assistantParts.isEmpty {
                session.append(
                    DSHMessage(role: .assistant, blocks: assistantParts),
                    turn: turn
                )
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
            for call in toolCalls {
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
                maxParallel: config.maxParallelToolCalls
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

    /// Compact the surface when it is under pressure.
    private func maybeCompact(turn: Int) async {
        guard config.autoCompactionEnabled else { return }

        let surface = session.surface()
        let total = DSHTokenEstimate.total(surface)
        guard total >= config.compactionPressureTokens else { return }

        let result = await DSHCompaction.compact(
            session: session,
            turn: turn,
            retainTokens: config.compactionRetainTokens,
            pressureThreshold: config.compactionPressureTokens,
            model: provider.model.id,
            provider: provider.name
        ) { [weak self] shadowedText in
            guard let self else { throw DSHCompactionError.summaryFailed("driver deallocated") }
            return try await self.summarize(shadowedText)
        }

        if case .success(let outcome) = result {
            delegate?.driver(self, didCompact: outcome)
        }
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

        var systemPrompt = DSHSystemPrompt.renderPrompt(assembly)
        let snapshot = DSHSystemPrompt.renderContextSnapshot(assembly)
        if !snapshot.isEmpty {
            systemPrompt += "\n\n" + snapshot
        }

        return LoopRequest(
            messages: projectMessages(session.surfaceMessages()),
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
            for block in message.blocks {
                switch block {
                case let text as DSHTextBlock:
                    parts.append(.text(text.text))
                case let reasoning as DSHReasoningBlock:
                    parts.append(.text(reasoning.text))
                case let call as DSHToolCallBlock:
                    let args = (try? JSONSerialization.jsonObject(
                        with: Data(call.arguments.utf8)
                    )) as? [String: Any] ?? [:]
                    parts.append(.toolUse(id: call.id, name: call.name, input: args))
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
            return AgentMessage(role: message.role == .user ? .user : .assistant, parts: parts)
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
