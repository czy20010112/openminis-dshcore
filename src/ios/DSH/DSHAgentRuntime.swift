//
//  DSHAgentRuntime.swift
//  Minis
//
//  Composes the DSH agent runtime: tool registry, prompt registry, and loop.
//
//  This is the single construction point the chat layer uses. It replaces the
//  AIChatViewModel loop; the ViewModel keeps its UI, persistence, and streaming
//  presentation, and delegates the agent decision-making to this runtime.
//

import Foundation

/// The composed DSH agent runtime for one conversation.
///
/// Main-actor isolated: it builds a `DSHAgentLoop`, which is main-actor
/// isolated because the providers it drives are main-actor types.
@MainActor
public final class DSHAgentRuntime {

    /// Tools available to the loop.
    public let registry: DSHToolRegistry
    /// The prompt registry the loop assembles from.
    public let prompt: DSHSystemPrompt
    /// Loop configuration.
    public var config: DSHAgentLoopConfig

    private var promptDisposers: [() -> Void] = []
    private var toolDisposers: [() -> Void] = []
    private let lock = NSLock()

    public init(config: DSHAgentLoopConfig = DSHAgentLoopConfig()) {
        self.registry = DSHToolRegistry()
        self.prompt = DSHSystemPrompt()
        self.config = config
    }

    // MARK: - Composition

    /// Install the base prompt and the Minis tool set.
    public func installDefaults(sandboxRoot: String, sessionId: String?, memoryEnabled: Bool) {
        lock.lock()
        defer { lock.unlock() }

        promptDisposers.append(contentsOf: DSHMinisPrompt.registerBase(into: prompt))
        promptDisposers.append(prompt.section(
            DSHMinisPrompt.runtimeContextSection(
                sandboxRoot: sandboxRoot,
                sessionId: sessionId,
                memoryEnabled: memoryEnabled
            )
        ))
    }

    /// Register a tool for the runtime's lifetime.
    @discardableResult
    public func addTool(_ tool: DSHTool) -> () -> Void {
        let disposer = registry.register(tool)
        lock.lock()
        toolDisposers.append(disposer)
        lock.unlock()
        return disposer
    }

    /// Register a prompt section for the runtime's lifetime.
    @discardableResult
    public func addSection(_ section: DSHPromptSection) -> () -> Void {
        let disposer = prompt.section(section)
        lock.lock()
        promptDisposers.append(disposer)
        lock.unlock()
        return disposer
    }

    // MARK: - Loop

    /// Start a loop over the given provider and delegate.
    public func makeLoop(
        provider: any AgentProvider,
        delegate: (any DSHAgentLoopDelegate)?
    ) -> DSHAgentLoop {
        let loop = DSHAgentLoop(
            provider: provider,
            registry: registry,
            prompt: prompt,
            config: config
        )
        loop.delegate = delegate
        return loop
    }

    // MARK: - Teardown

    /// Dispose every registration this runtime installed.
    public func dispose() {
        lock.lock()
        defer { lock.unlock() }
        for disposer in promptDisposers { disposer() }
        for disposer in toolDisposers { disposer() }
        promptDisposers.removeAll()
        toolDisposers.removeAll()
    }

    deinit {
        dispose()
    }
}
