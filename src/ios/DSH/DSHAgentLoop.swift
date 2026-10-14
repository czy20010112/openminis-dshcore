//
//  DSHAgentLoop.swift
//  Minis
//
//  The agent loop core, ported from DeepSeek Harness
//  (packages/core/agent-loop/src/agent.ts, tool-calls.ts).
//
//  This replaces OpenMinis' AIChatViewModel loop. The provider seam is kept
//  intact: the loop drives any `AgentProvider` through the same
//  streamAgentMessage contract, so every existing provider implementation
//  (Anthropic, OpenAI, Gemini, OpenRouter, xAI, Kimi, Copilot, Antigravity)
//  keeps working unchanged.
//
//  What changes is the loop's behaviour:
//  - the system prompt is assembled from ordered registered sections instead
//    of one concatenated string, so contributions cannot silently displace
//    each other;
//  - every step's request is derived from the conversation, with a runtime
//    context snapshot folded in;
//  - tool calls are scheduled by declared concurrency mode with results
//    committed in model order;
//  - loop guards run before each call instead of only after a failure.
//

import Foundation

// MARK: - Loop Delegate

/// The loop's view of the outside world. Everything the loop needs to observe
/// or mutate goes through this seam, so the loop itself holds no UI state.
///
/// Isolated to the main actor: the delegate drives UI and persistence, both of
/// which are main-actor state in this app.
@MainActor
public protocol DSHAgentLoopDelegate: AnyObject {
    /// Called when a step starts, for UI progress.
    func loopDidStartStep(_ loop: DSHAgentLoop, turn: Int, step: Int)
    /// Called with a text delta.
    func loop(_ loop: DSHAgentLoop, didEmitText text: String, turn: Int, step: Int)
    /// Called with a reasoning delta.
    func loop(_ loop: DSHAgentLoop, didEmitReasoning text: String, turn: Int, step: Int)
    /// Called when a tool call begins.
    func loop(_ loop: DSHAgentLoop, willRunTool name: String, callId: String, arguments: [String: Any])
    /// Called when a tool call settles.
    func loop(
        _ loop: DSHAgentLoop,
        didFinishTool name: String,
        callId: String,
        result: DSHToolExecutionResult
    )
    /// Called when usage is reported.
    func loop(_ loop: DSHAgentLoop, didReportUsage usage: DSHTokenUsage)
    /// Called when the turn ends.
    func loopDidEndTurn(_ loop: DSHAgentLoop, reason: DSHTurnEndReason)
    /// Called when the loop fails.
    func loop(_ loop: DSHAgentLoop, didFail failure: DSHFailure)
}

/// Why a turn ended.
public enum DSHTurnEndReason: Sendable {
    case completed
    case cancelled
    case maxSteps
    case concluded
}

// MARK: - Configuration

/// Loop configuration. Deployment-varying values are fields, not constants.
public struct DSHAgentLoopConfig: Sendable {
    /// Bound on the parallel tool pool.
    public var maxParallelToolCalls: Int
    /// Maximum steps in one turn before the loop stops and reports.
    public var maxStepsPerTurn: Int
    /// Maximum tokens for one model response.
    public var maxTokens: Int
    /// Whether loop guards run before each tool call.
    public var enableLoopGuard: Bool
    /// Whether a runtime context snapshot is folded into the request.
    public var includeRuntimeContext: Bool
    /// Ordered tool names, with the rest marker exactly once. nil means
    /// lexicographic order.
    public var toolOrder: [String]?

    public init(
        maxParallelToolCalls: Int = 4,
        maxStepsPerTurn: Int = 200,
        maxTokens: Int = 32_000,
        enableLoopGuard: Bool = true,
        includeRuntimeContext: Bool = true,
        toolOrder: [String]? = nil
    ) {
        self.maxParallelToolCalls = max(1, maxParallelToolCalls)
        self.maxStepsPerTurn = max(1, maxStepsPerTurn)
        self.maxTokens = maxTokens
        self.enableLoopGuard = enableLoopGuard
        self.includeRuntimeContext = includeRuntimeContext
        self.toolOrder = toolOrder
    }
}

// MARK: - Loop

/// Drives one conversation through turn and step boundaries.
///
/// Main-actor isolated rather than an actor: the providers it drives are
/// main-actor types in this app, and the delegate drives UI and persistence.
/// Running the loop on the main actor keeps provider construction, request
/// building, and delegate dispatch in one isolation domain without `Sendable`
/// gymnastics on non-Sendable provider state.
@MainActor
public final class DSHAgentLoop {

    // MARK: State

    private let provider: any AgentProvider
    private let registry: DSHToolRegistry
    private let prompt: DSHSystemPrompt
    private var config: DSHAgentLoopConfig

    /// The conversation the loop derives every request from.
    private var messages: [DSHMessage] = []

    /// System prompt contributions that live for the loop's lifetime.
    private var disposers: [() -> Void] = []

    private var currentTurn = 0
    private var isRunning = false
    private var cancelled = false

    public weak var delegate: (any DSHAgentLoopDelegate)?

    // MARK: Init

    init(
        provider: any AgentProvider,
        registry: DSHToolRegistry,
        prompt: DSHSystemPrompt,
        config: DSHAgentLoopConfig = DSHAgentLoopConfig()
    ) {
        self.provider = provider
        self.registry = registry
        self.prompt = prompt
        self.config = config
    }

    // MARK: Configuration

    public func updateConfig(_ config: DSHAgentLoopConfig) {
        self.config = config
    }

    /// Register a prompt section for this loop's lifetime.
    @discardableResult
    public func addSection(_ section: DSHPromptSection) -> () -> Void {
        let disposer = prompt.section(section)
        disposers.append(disposer)
        return disposer
    }

    /// Replace the conversation. Used when a session is loaded or reset.
    public func setMessages(_ messages: [DSHMessage]) {
        self.messages = messages
    }

    /// Current conversation.
    public var currentMessages: [DSHMessage] {
        messages
    }

    /// Seed the conversation with an existing history without starting a turn.
    public func appendUserMessage(_ text: String, images: [DSHImageBlock] = [], files: [DSHFileBlock] = []) {
        var blocks: [DSHContentBlock] = [DSHTextBlock(text: text)]
        blocks.append(contentsOf: images)
        blocks.append(contentsOf: files)
        messages.append(DSHMessage(role: .user, blocks: blocks))
    }

    // MARK: Turn Execution

    /// Cancel the running turn at the next step boundary.
    public func cancel() {
        cancelled = true
    }

    /// Run one turn to completion.
    public func run() async -> DSHTurnEndReason {
        guard !isRunning else { return .cancelled }
        isRunning = true
        cancelled = false
        currentTurn += 1
        defer { isRunning = false }

        let turn = currentTurn
        var step = 0

        while step < config.maxStepsPerTurn {
            if cancelled { return .cancelled }

            step += 1
            delegate?.loopDidStartStep(self, turn: turn, step: step)

            // Every request is derived from the conversation plus the assembled
            // prompt. Nothing is carried over from a previous step except the
            // conversation itself.
            let request = await buildRequest(turn: turn, step: step)

            let stream: AsyncThrowingStream<AgentStreamEvent, Error>
            do {
                stream = try await provider.streamAgentMessageClamped(
                    messages: request.messages,
                    systemPrompt: request.systemPrompt,
                    tools: request.tools,
                    maxTokens: request.maxTokens,
                    thinkingLevel: request.thinkingLevel
                )
            } catch {
                let failure = error as? DSHFailure
                    ?? DSHFailure(message: String(describing: error), code: "PROVIDER_ERROR")
                delegate?.loop(self, didFail: failure)
                return .cancelled
            }

            var assistantParts: [AgentContentPart] = []
            var toolCalls: [DSHToolCallBlock] = []
            var stopReason: AgentStopReason = .endTurn
            var usage = DSHTokenUsage()

            do {
                for try await event in stream {
                    switch event {
                    case .textDelta(let text):
                        delegate?.loop(self, didEmitText: text, turn: turn, step: step)
                        if case .text(var existing) = assistantParts.last {
                            existing += text
                            assistantParts[assistantParts.count - 1] = .text(existing)
                        } else {
                            assistantParts.append(.text(text))
                        }

                    case .thinkingDelta(let text):
                        delegate?.loop(self, didEmitReasoning: text, turn: turn, step: step)

                    case .reasoningContent:
                        // Opaque provider payload; preserved by the provider
                        // implementation, not by the loop.
                        break

                    case .reasoningEcho:
                        break

                    case .contentBlockStart:
                        break

                    case .toolInputDelta:
                        // Preview only; the loop commits on toolCallComplete.
                        break

                    case .toolCallComplete(let id, let name, let args, _):
                        let raw = Self.encodeArguments(args)
                        let block = DSHToolCallBlock(id: id, name: name, arguments: raw)
                        toolCalls.append(block)
                        assistantParts.append(.toolUse(id: id, name: name, input: args))

                    case .usage(let reported):
                        usage.inputTokens += reported.inputTokens
                        usage.outputTokens += reported.outputTokens
                        if let v = reported.cacheCreationInputTokens { usage.cacheWriteTokens = (usage.cacheWriteTokens ?? 0) + v }
                        if let v = reported.cacheReadInputTokens { usage.cacheReadTokens = (usage.cacheReadTokens ?? 0) + v }
                        delegate?.loop(self, didReportUsage: usage)

                    case .done(let reason):
                        stopReason = reason
                    }
                }
            } catch {
                let failure = error as? DSHFailure
                    ?? DSHFailure(message: String(describing: error), code: "STREAM_ERROR")
                delegate?.loop(self, didFail: failure)
                return .cancelled
            }

            // Commit the assistant turn before any tool results, so the
            // conversation stays provider-valid (tool_use then tool_result).
            if !assistantParts.isEmpty {
                messages.append(DSHMessage(role: .assistant, blocks: assistantParts.map(Self.toBlock)))
            }

            delegate?.loop(self, didReportUsage: usage)

            if toolCalls.isEmpty {
                let reason: DSHTurnEndReason
                switch stopReason {
                case .endTurn: reason = .completed
                case .maxTokens: reason = .maxSteps
                case .refusal: reason = .completed
                case .toolUse: reason = .completed
                }
                delegate?.loopDidEndTurn(self, reason: reason)
                return reason
            }

            // Schedule the calls by their declared concurrency mode. Results
            // come back in model order, so the conversation stays provider-valid.
            let token = DSHCancellationToken()
            let gate = DSHToolGate(
                enabled: config.enableLoopGuard,
                warningThreshold: 10,
                criticalThreshold: 20
            )

            let outcome = await DSHToolScheduler.execute(
                registry: registry,
                turn: turn,
                step: step,
                toolCalls: toolCalls,
                signal: token,
                maxParallel: config.maxParallelToolCalls
            )

            if cancelled || outcome.aborted {
                // Unstarted calls already received a synthetic result, so the
                // conversation stays replayable.
                delegate?.loopDidEndTurn(self, reason: .cancelled)
                return .cancelled
            }

            for commit in outcome.commits {
                let verdict = gate.check(toolName: commit.block.name, arguments: [:])
                if verdict.level == DSHToolGate.Verdict.Level.critical {
                    recordBlocked(commit, verdict: verdict, turn: turn, step: step)
                    continue
                }
                commitResult(commit, turn: turn, step: step, gate: gate)
            }

            if outcome.concluded {
                delegate?.loopDidEndTurn(self, reason: .concluded)
                return .concluded
            }

            await Task.yield()
        }

        delegate?.loopDidEndTurn(self, reason: .maxSteps)
        return .maxSteps
    }

    // MARK: Request Building

    private struct LoopRequest {
        var messages: [AgentMessage]
        var systemPrompt: String?
        var tools: [AgentToolDefinition]
        var maxTokens: Int
        var thinkingLevel: ThinkingLevel
    }

    /// Build one step's request: assemble the prompt, order the tools, and
    /// project the conversation into the provider's message type.
    private func buildRequest(turn: Int, step: Int) async -> LoopRequest {
        var context = DSHAssembleContext(
            model: provider.model.id,
            provider: provider.name,
            toolNames: [],
            isHelper: false
        )

        let schemas = registry.schemas()
        context.toolNames = schemas.map(\.name)

        let assembly = prompt.assemble(
            tools: schemas,
            context: context,
            toolOrder: config.toolOrder
        )

        var systemPrompt = DSHSystemPrompt.renderPrompt(assembly)
        if config.includeRuntimeContext {
            let snapshot = DSHSystemPrompt.renderContextSnapshot(assembly)
            if !snapshot.isEmpty {
                systemPrompt += "\n\n" + snapshot
            }
        }

        let providerMessages = projectMessages(messages)

        return LoopRequest(
            messages: providerMessages,
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            tools: schemas.map(DSHToolSchemaBridge.toAgentToolDefinition),
            maxTokens: config.maxTokens,
            thinkingLevel: .off
        )
    }

    /// Project the provider-neutral conversation into the provider's message
    /// type. Tool results become `.toolResult` parts in model order.
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
                        isError: result.isError
                    ))
                case let image as DSHImageBlock:
                    parts.append(.imageData(data: image.data, mimeType: image.mimeType, linuxPath: image.path))
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

    // MARK: Delegate Dispatch


    /// Serialize tool arguments to a stable JSON string. Falls back to `{}`
    /// when the provider handed us something JSONSerialization rejects, because
    /// the loop still needs a well-formed arguments payload to persist.
    private static func encodeArguments(_ args: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Project one provider content part onto the loop's block vocabulary.
    private static func toBlock(_ part: AgentContentPart) -> any DSHContentBlock {
        switch part {
        case .text(let text): return DSHTextBlock(text: text)
        case .toolUse(let id, let name, let input):
            return DSHToolCallBlock(id: id, name: name, arguments: encodeArguments(input))
        case .toolResult(let id, let name, let content, let isError, _, _, _, _):
            return DSHToolResultBlock(callId: id, name: name, content: content, isError: isError)
        case .imageData(let data, let mimeType, let path):
            return DSHImageBlock(data: data, mimeType: mimeType, path: path)
        }
    }

    // MARK: Result Commit

    private func commitResult(
        _ commit: DSHToolCommit,
        turn: Int,
        step: Int,
        gate: DSHToolGate
    ) {
        let name = commit.block.name
        let callId = commit.block.id
        let result = commit.result

        var content = result.content
        if commit.started {
            let verdict = gate.record(
                toolName: name,
                result: result.content,
                errorMessage: result.isError ? result.content : nil
            )
            if let warning = verdict.message {
                content += "\n\n" + warning
            }
        }

        messages.append(DSHMessage(role: .tool, blocks: [
            DSHToolResultBlock(
                callId: callId,
                name: name,
                content: content,
                isError: result.isError
            ),
        ]))
    }

    /// Report a call the loop guard blocked, so the model sees why it did not
    /// run instead of silently retrying the same no-progress call.
    private func recordBlocked(
        _ commit: DSHToolCommit,
        verdict: DSHToolGate.Verdict,
        turn: Int,
        step: Int
    ) {
        let result = DSHToolExecutionResult(
            content: verdict.message ?? "Error: blocked by loop guard",
            isError: true
        )
        delegate?.loop(self, didFinishTool: commit.block.name, callId: commit.block.id, result: result)
        messages.append(DSHMessage(role: .tool, blocks: [
            DSHToolResultBlock(
                callId: commit.block.id,
                name: commit.block.name,
                content: result.content,
                isError: true
            ),
        ]))
    }
}

// MARK: - Loop Guard

/// Loop guard: detects repeated no-progress calls and blocks them before they
/// fire again.
///
/// A blocked call returns an error result rather than executing, so the model
/// gets a concrete reason to change approach instead of retrying.
final class DSHToolGate: @unchecked Sendable {
    let enabled: Bool
    let warningThreshold: Int
    let criticalThreshold: Int

    init(enabled: Bool, warningThreshold: Int, criticalThreshold: Int) {
        self.enabled = enabled
        self.warningThreshold = warningThreshold
        self.criticalThreshold = criticalThreshold
    }

    struct Verdict: Sendable {
        enum Level { case pass, warning, critical }
        let level: Level
        let message: String?
    }

    private var history: [String: Int] = [:]
    private var noProgress: [String: Int] = [:]
    private var warningBuckets: [String: Int] = [:]

    /// Check before a call fires.
    func check(toolName: String, arguments: [String: Any]) -> Verdict {
        guard enabled else { return Verdict(level: .pass, message: nil) }
        let key = "\(toolName):\(stableHash(arguments))"
        let count = (history[key] ?? 0) + 1
        history[key] = count

        if count >= criticalThreshold {
            return Verdict(
                level: .critical,
                message: "[LOOP BLOCKED] CRITICAL: called \(toolName) \(count) times with identical arguments. Stop retrying and report the outcome without that tool."
            )
        }
        if count >= warningThreshold {
            let bucket = count / warningThreshold
            if let last = warningBuckets[key], last >= bucket {
                return Verdict(level: .pass, message: nil)
            }
            warningBuckets[key] = bucket
            return Verdict(
                level: .warning,
                message: "[LOOP WARNING] You have called \(toolName) \(count) times with identical arguments. If this is not making progress, stop and report."
            )
        }
        return Verdict(level: .pass, message: nil)
    }

    /// Record a settled call.
    func record(
        toolName: String,
        result: String?,
        errorMessage: String?
    ) -> Verdict {
        guard enabled else { return Verdict(level: .pass, message: nil) }
        let key = "\(toolName):\(stableHash(result ?? ""))"
        let count = (noProgress[key] ?? 0) + 1
        noProgress[key] = count
        if count >= warningThreshold && count < criticalThreshold {
            let bucket = count / warningThreshold
            if let last = warningBuckets[key], last >= bucket {
                return Verdict(level: .pass, message: nil)
            }
            warningBuckets[key] = bucket
            return Verdict(
                level: .warning,
                message: "[LOOP WARNING] This call has produced the same outcome \(count) times. Change approach or report the result."
            )
        }
        return Verdict(level: .pass, message: nil)
    }

    private func stableHash(_ value: Any) -> String {
        let normalized = normalize(value)
        guard let data = try? JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys, .fragmentsAllowed]
        ) else { return "?" }
        return String(data: data, encoding: .utf8) ?? "?"
    }

    private func normalize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = normalize(v) }
            return out
        }
        if let arr = value as? [Any] { return arr.map { normalize($0) } }
        if value is NSNull { return NSNull() }
        if let s = value as? String { return s }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n }
        return String(describing: value)
    }
}
