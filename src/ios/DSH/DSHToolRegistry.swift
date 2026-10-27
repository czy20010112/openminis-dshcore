//
//  DSHToolRegistry.swift
//  Minis
//
//  Tool registry and execution pipeline, ported from DeepSeek Harness
//  (packages/core/tools/src/index.ts, tool-calls.ts).
//
//  Two things here are load-bearing for loop quality:
//  - a declared execution mode per tool, so an exclusive tool forms a barrier
//    and parallel tools run in a bounded pool;
//  - results committed in model order, so the conversation the model sees
//    matches the order it asked in.
//

import Foundation

// MARK: - Execution Mode

/// How one tool call participates in a step's concurrency.
public enum DSHToolExecutionMode: Sendable {
    /// Runs alone; later calls in the same step wait for it.
    case exclusive
    /// Runs in a bounded rolling pool with other parallel calls.
    case parallel
}

// MARK: - Tool

/// One registered tool.
public final class DSHTool: @unchecked Sendable {
    public let name: String
    public let description: String
    /// JSON Schema object for the arguments.
    public let parameters: [String: Any]
    public let executionMode: DSHToolExecutionMode
    /// Result context this tool contributes back into the conversation.
    public let resultRole: DSHMessage.Role
    /// The order this tool's parameters are presented in, when it declares one.
    public let propertyOrdering: [String]?
    private let body: @Sendable ([String: Any], DSHToolRunContext) async throws -> DSHToolExecutionResult

    public init(
        name: String,
        description: String,
        parameters: [String: Any],
        executionMode: DSHToolExecutionMode = .exclusive,
        propertyOrdering: [String]? = nil,
        body: @escaping @Sendable ([String: Any], DSHToolRunContext) async throws -> DSHToolExecutionResult
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.executionMode = executionMode
        self.resultRole = .tool
        self.propertyOrdering = propertyOrdering
        self.body = body
    }

    /// Execute the tool with parsed arguments.
    public func run(
        _ arguments: [String: Any],
        context: DSHToolRunContext
    ) async throws -> DSHToolExecutionResult {
        try await body(arguments, context)
    }

    /// The schema sent to the model.
    public func schema(deferLoading: Bool = false) -> DSHToolSchema {
        DSHToolSchema(
            name: name,
            description: description,
            parameters: parameters,
            deferLoading: deferLoading,
            propertyOrdering: propertyOrdering
        )
    }
}

/// Context handed to a tool body.
public struct DSHToolRunContext: Sendable {
    /// The tool call id this body is serving.
    public let callId: String
    /// Cancellation shared by the whole step.
    public let signal: DSHCancellationToken
    /// Turn and step numbers, for logging and correlation.
    public let turn: Int
    public let step: Int

    public init(callId: String, signal: DSHCancellationToken, turn: Int, step: Int) {
        self.callId = callId
        self.signal = signal
        self.turn = turn
        self.step = step
    }
}

/// One settled tool execution.
public struct DSHToolExecutionResult: Sendable {
    public var content: String
    public var isError: Bool
    /// Whether this result ends the turn regardless of further calls.
    public var concludesTurn: Bool
    /// Extra messages folded into model context after the result.
    public var additionalContexts: [DSHMessage]
    /// Pixels a tool produced, carried onto its tool_result part.
    ///
    /// Not every tool is text-only: `read_image` hands the model an image, and
    /// `browser_use` hands it a page screenshot. Those bytes belong to the
    /// result, not to a separate message.
    public var imageData: Data?
    public var imageMimeType: String?
    /// The URL a browser action landed on.
    public var pageURL: String?
    /// Durable sandbox path of `imageData`, so the model can re-fetch it.
    public var imageLinuxPath: String?

    public init(
        content: String,
        isError: Bool = false,
        concludesTurn: Bool = false,
        additionalContexts: [DSHMessage] = [],
        imageData: Data? = nil,
        imageMimeType: String? = nil,
        pageURL: String? = nil,
        imageLinuxPath: String? = nil
    ) {
        self.content = content
        self.isError = isError
        self.concludesTurn = concludesTurn
        self.additionalContexts = additionalContexts
        self.imageData = imageData
        self.imageMimeType = imageMimeType
        self.pageURL = pageURL
        self.imageLinuxPath = imageLinuxPath
    }

    public static func error(_ message: String) -> DSHToolExecutionResult {
        DSHToolExecutionResult(content: "Error: \(message)", isError: true)
    }
}

// MARK: - Registry

/// Tool registry and execution pipeline.
///
/// Registrations are effects: `register` returns the disposer.
public final class DSHToolRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var tools: [String: DSHTool] = [:]
    private var order: [String] = []

    public init() {}

    /// Register a tool.
    ///
    /// A duplicate name is REFUSED, not fatal. This used to be a `precondition`,
    /// which trapped the whole app in release builds: registering a second tool
    /// with the same name (an MCP tool that shadows a built-in, a re-registration
    /// after a reload) killed the process instead of telling anyone. The caller now
    /// gets the error back and can surface it; the existing tool keeps working.
    ///
    /// - Returns: `nil` on success, or the conflict to report.
    @discardableResult
    public func register(_ tool: DSHTool) -> DSHFailure? {
        lock.lock()
        if tools[tool.name] != nil {
            lock.unlock()
            NSLog("[DSH] tool registry refused duplicate name \"\(tool.name)\"")
            return DSHFailure(message: "tool \"\(tool.name)\" is already registered", code: "DUPLICATE_TOOL")
        }
        tools[tool.name] = tool
        order.append(tool.name)
        lock.unlock()
        return nil
    }

    /// Register, and hand back the unregister closure on success.
    ///
    /// Kept as a separate name so the many call sites that ignore the outcome stay
    /// source-compatible and a re-registration is a no-op instead of a crash.
    @discardableResult
    public func registerReturningHandle(_ tool: DSHTool) -> (() -> Void)? {
        guard register(tool) == nil else { return nil }
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.tools[tool.name] = nil
            self.order.removeAll { $0 == tool.name }
            self.lock.unlock()
        }
    }

    /// The registered tool, or nil.
    public func tool(named name: String) -> DSHTool? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]
    }

    /// Whether a tool is registered.
    public func has(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tools[name] != nil
    }

    /// Registered tool names in registration order.
    public var registeredNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    /// Schemas for the registered tools, in registration order.
    public func schemas() -> [DSHToolSchema] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { tools[$0]?.schema() }
    }

    /// The live execution mode of one call. Read at scheduling time so a
    /// registry change can reclassify a call that has not started yet.
    public func executionMode(name: String) -> DSHToolExecutionMode {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]?.executionMode ?? .exclusive
    }
}

// MARK: - Cancellation

/// Cooperative cancellation shared by one step.
public final class DSHCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var handlers: [() -> Void] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    public func cancel() {
        lock.lock()
        guard !_cancelled else { lock.unlock(); return }
        _cancelled = true
        let pending = handlers
        handlers = []
        lock.unlock()
        for handler in pending { handler() }
    }

    /// Register a handler invoked once on cancellation.
    public func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if _cancelled {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }
}

// MARK: - JSON Argument Parsing

/// Parse model arguments, preserving invalid JSON as an error rather than
/// silently passing an empty object to a tool.
public enum DSHToolArguments {
    /// Parse a raw JSON string into a dictionary. Empty input yields `{}`.
    public static func parse(_ raw: String) throws -> [String: Any] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let data = trimmed.data(using: .utf8) else {
            throw DSHFailure(message: "arguments are not valid UTF-8", code: "INVALID_ARGUMENTS")
        }
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let object = parsed as? [String: Any] else {
            throw DSHFailure(message: "arguments must be a JSON object", code: "INVALID_ARGUMENTS")
        }
        return object
    }

    /// Read a string argument.
    public static func string(_ args: [String: Any], _ key: String) -> String? {
        (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read a string argument, falling back to a default.
    public static func string(_ args: [String: Any], _ key: String, or fallback: String) -> String {
        string(args, key) ?? fallback
    }

    /// Read an integer argument.
    public static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let n = args[key] as? Int { return n }
        if let n = args[key] as? NSNumber { return n.intValue }
        if let s = args[key] as? String, let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return n }
        return nil
    }

    /// Read an integer argument, falling back to a default.
    public static func int(_ args: [String: Any], _ key: String, or fallback: Int) -> Int {
        int(args, key) ?? fallback
    }

    /// Read a boolean argument.
    public static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        if let b = args[key] as? Bool { return b }
        if let n = args[key] as? NSNumber { return n.boolValue }
        if let s = args[key] as? String {
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// Read a boolean argument, falling back to a default.
    public static func bool(_ args: [String: Any], _ key: String, or fallback: Bool) -> Bool {
        bool(args, key) ?? fallback
    }
}
