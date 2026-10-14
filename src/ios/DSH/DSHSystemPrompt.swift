//
//  DSHSystemPrompt.swift
//  Minis
//
//  Ordered system-prompt assembly, ported from DeepSeek Harness
//  (packages/core/system-prompt/src/index.ts).
//
//  The ordered-section registry is the part that makes the agent behave
//  consistently: every contribution declares a placement instead of appending
//  text, so a new capability cannot silently push guidance out of the prompt.
//

import Foundation

// MARK: - Section Placement

/// Centrally allocated prompt-section positions. Every first-party section
/// takes its order from here rather than picking a number, so two subsystems
/// cannot claim the same slot.
public enum DSHSectionOrder: Int, CaseIterable {
    /// Fixed harness identity, ahead of every deployment contribution.
    case harnessIdentity = -1000
    case personaPrefix = 0
    case environment = 100
    case toolGuidance = 1000
    case toolReference = 1100
    case skills = 1500
    case memory = 1600
    case runtimeContext = 9000
    case deliverableReference = 9010
    case personaSuffix = 10200
}

/// One contributed section of the system prompt.
public struct DSHPromptSection: Sendable {
    /// Unique name — a duplicate registration throws.
    public let name: String
    /// Sections are concatenated in ascending order. Equal orders use name order.
    public let order: Int
    /// Static text, or a provider evaluated at each assembly.
    public let text: DSHSectionText
    /// Whether to interpolate `{{variable}}` references. Defaults to true.
    public let interpolate: Bool
    /// Treat this contribution as the complete system prompt.
    public let complete: Bool

    public enum DSHSectionText: Sendable {
        case static(String)
        case dynamic(@Sendable (DSHAssembleContext) -> String)
    }

    public init(
        name: String,
        order: Int,
        text: String,
        interpolate: Bool = true,
        complete: Bool = false
    ) {
        self.name = name
        self.order = order
        self.text = .static(text)
        self.interpolate = interpolate
        self.complete = complete
    }

    public init(
        name: String,
        order: Int,
        dynamic: @escaping @Sendable (DSHAssembleContext) -> String,
        interpolate: Bool = true,
        complete: Bool = false
    ) {
        self.name = name
        self.order = order
        self.text = .dynamic(dynamic)
        self.interpolate = interpolate
        self.complete = complete
    }
}

/// Dynamic model context materialized into the request.
public struct DSHPromptContext: Sendable {
    public let name: String
    public let order: Int
    public let text: DSHPromptContext.ContextText

    public enum ContextText: Sendable {
        case static(String)
        case dynamic(@Sendable (DSHAssembleContext) -> String)
    }

    public init(name: String, order: Int, text: String) {
        self.name = name
        self.order = order
        self.text = .static(text)
    }

    public init(name: String, order: Int, dynamic: @escaping @Sendable (DSHAssembleContext) -> String) {
        self.name = name
        self.order = order
        self.text = .dynamic(dynamic)
    }
}

/// Merge-extensible context for one prompt assembly.
public struct DSHAssembleContext: Sendable {
    /// The model that will receive this turn.
    public var model: String?
    /// The provider route serving this turn.
    public var provider: String?
    /// Working directory the tools operate in.
    public var cwd: String?
    /// Names of tools visible in this assembly, in canonical order.
    public var toolNames: [String]
    /// Whether this assembly belongs to a delegated sub agent.
    public var isHelper: Bool

    public init(
        model: String? = nil,
        provider: String? = nil,
        cwd: String? = nil,
        toolNames: [String] = [],
        isHelper: Bool = false
    ) {
        self.model = model
        self.provider = provider
        self.cwd = cwd
        self.toolNames = toolNames
        self.isHelper = isHelper
    }
}

/// One resolved section of an assembly.
public struct DSHAssembledSection: Sendable {
    public let name: String
    public let text: String
    public let interpolate: Bool
}

/// One resolved dynamic context contribution.
public struct DSHAssembledContext: Sendable {
    public let name: String
    public let text: String
}

/// Merge-extensible assembled model input.
public struct DSHPromptAssembly: Sendable {
    public var sections: [DSHAssembledSection]
    public var contexts: [DSHAssembledContext]
    public var tools: [DSHToolSchema]
    public var variables: [String: String]

    public init(
        sections: [DSHAssembledSection],
        contexts: [DSHAssembledContext],
        tools: [DSHToolSchema],
        variables: [String: String]
    ) {
        self.sections = sections
        self.contexts = contexts
        self.tools = tools
        self.variables = variables
    }
}

// MARK: - Registry

/// Registry for ordered system sections, dynamic context, tool schemas, and
/// prompt variables.
///
/// Registrations are effects: every contribution goes through `register`, which
/// returns the disposer. That keeps a subsystem's prompt contribution tied to
/// its own lifecycle instead of living for the process.
public final class DSHSystemPrompt: @unchecked Sendable {

    private let lock = NSLock()
    private var sections: [DSHPromptSection] = []
    private var contexts: [DSHPromptContext] = []
    private var variables: [String: @Sendable (DSHAssembleContext) -> String?] = [:]
    private var suppressRuntimeContext = false

    public init() {}

    // MARK: Registration

    /// Register an ordered prompt section.
    /// - Returns: the disposer that removes exactly this contribution.
    @discardableResult
    public func section(_ section: DSHPromptSection) -> () -> Void {
        lock.lock()
        if sections.contains(where: { $0.name == section.name }) {
            lock.unlock()
            preconditionFailure("prompt section \"\(section.name)\" is already registered")
        }
        guard section.order.isFinite else {
            lock.unlock()
            preconditionFailure("prompt section \"\(section.name)\" order must be finite")
        }
        sections.append(section)
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.sections.removeAll { $0.name == section.name }
            self.lock.unlock()
        }
    }

    /// Register ordered dynamic context.
    @discardableResult
    public func context(_ context: DSHPromptContext) -> () -> Void {
        lock.lock()
        if contexts.contains(where: { $0.name == context.name }) {
            lock.unlock()
            preconditionFailure("prompt context \"\(context.name)\" is already registered")
        }
        guard context.order.isFinite else {
            lock.unlock()
            preconditionFailure("prompt context \"\(context.name)\" order must be finite")
        }
        contexts.append(context)
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.contexts.removeAll { $0.name == context.name }
            self.lock.unlock()
        }
    }

    /// Register a prompt variable. Names match `[a-z][a-z0-9_]*`.
    @discardableResult
    public func variable(
        _ name: String,
        provider: @escaping @Sendable (DSHAssembleContext) -> String?
    ) -> () -> Void {
        let valid = name.range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil
        precondition(valid, "invalid prompt variable name \"\(name)\"")
        lock.lock()
        precondition(variables[name] == nil, "prompt variable \"\(name)\" is already registered")
        variables[name] = provider
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.variables[name] = nil
            self.lock.unlock()
        }
    }

    /// Suppress every dynamic runtime-context contribution.
    @discardableResult
    public func suppressRuntimeContext() -> () -> Void {
        lock.lock()
        suppressRuntimeContext = true
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.suppressRuntimeContext = false
            self.lock.unlock()
        }
    }

    // MARK: Assembly

    /// Assemble the registered sections, contexts, tools, and variables.
    public func assemble(
        tools: [DSHToolSchema],
        context: DSHAssembleContext = DSHAssembleContext(),
        toolOrder: [String]? = nil
    ) -> DSHPromptAssembly {
        lock.lock()
        let sectionDefs = sections.sorted { a, b in
            a.order != b.order ? a.order < b.order : a.name < b.name
        }
        let contextDefs = contexts.sorted { a, b in
            a.order != b.order ? a.order < b.order : a.name < b.name
        }
        let variableProviders = variables
        let runtimeSuppressed = suppressRuntimeContext
        lock.unlock()

        var resolvedVariables: [String: String] = [:]
        for (name, provider) in variableProviders {
            if let value = provider(context) { resolvedVariables[name] = value }
        }

        // Reject an ambiguous assembly before resolving any section text, so a
        // misconfigured composition fails at the composition rather than after
        // every provider has already run.
        let completes = sectionDefs.filter { $0.complete }
        precondition(completes.count <= 1,
                     "multiple complete prompt sections are active: \(completes.map(\.name).joined(separator: ", "))")

        var completeSection: DSHAssembledSection?
        var resolvedSections: [DSHAssembledSection] = []
        resolvedSections.reserveCapacity(sectionDefs.count)

        for def in sectionDefs {
            let raw: String
            switch def.text {
            case .static(let text): raw = text
            case .dynamic(let provider): raw = provider(context)
            }
            let assembled = DSHAssembledSection(
                name: def.name,
                text: raw,
                interpolate: def.interpolate
            )
            if def.complete { completeSection = assembled }
            resolvedSections.append(assembled)
        }

        let resolvedContexts: [DSHAssembledContext] = runtimeSuppressed ? [] : contextDefs.map { def in
            let raw: String
            switch def.text {
            case .static(let text): raw = text
            case .dynamic(let provider): raw = provider(context)
            }
            return DSHAssembledContext(name: def.name, text: raw)
        }

        return DSHPromptAssembly(
            sections: completeSection.map { [$0] } ?? resolvedSections,
            contexts: resolvedContexts,
            tools: DSHSystemPrompt.orderTools(tools, toolOrder: toolOrder),
            variables: resolvedVariables
        )
    }

    /// Interpolate strict `{{variable}}` references, drop empty sections, and
    /// join the rest with blank lines.
    ///
    /// Malformed or unknown references throw rather than rendering literal
    /// braces: a silent typo would ship a broken instruction to the model.
    public static func renderPrompt(_ assembly: DSHPromptAssembly) -> String {
        assembly.sections
            .map { section in
                section.interpolate
                    ? interpolate(section.text, variables: assembly.variables, sectionName: section.name)
                    : section.text
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Render the complete dynamic context snapshot.
    public static func renderContextSnapshot(_ assembly: DSHPromptAssembly) -> String {
        let body = assembly.contexts.map { context in
            interpolate(context.text, variables: assembly.variables, sectionName: context.name)
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")

        guard !body.isEmpty else { return "" }
        return "Current runtime context. This snapshot supersedes earlier runtime-context snapshots.\n\n\(body)"
    }

    /// Apply configured tool order, inserting unlisted tools lexicographically
    /// at the rest marker.
    public static func orderTools(_ tools: [DSHToolSchema], toolOrder: [String]?) -> [DSHToolSchema] {
        let restMarker = DSHSystemPrompt.toolOrderRest
        guard let toolOrder else {
            return tools.sorted { $0.name < $1.name }
        }
        precondition(!tools.contains { $0.name == restMarker },
                     "tool provider returned reserved tool name \"\(restMarker)\"")
        let listed = Set(toolOrder)
        let rest = tools.filter { !listed.contains($0.name) }.sorted { $0.name < $1.name }
        return toolOrder.flatMap { name -> [DSHToolSchema] in
            name == restMarker ? rest : tools.filter { $0.name == name }
        }
    }

    /// Reserved marker for unlisted tools in a configured order.
    public static let toolOrderRest = "<unlisted-tools>"

    private static func interpolate(
        _ text: String,
        variables: [String: String],
        sectionName: String
    ) -> String {
        // Work in UTF-16 view space: offsets are plain Ints, so slice bookkeeping
        // cannot drift the way String.Index arithmetic does across a rebuild.
        let units = Array(text.utf16)
        var result = ""
        var last = 0
        var cursor = 0

        while cursor < units.count {
            guard units[cursor] == 0x7B, cursor + 1 < units.count, units[cursor + 1] == 0x7B else {
                cursor += 1
                continue
            }
            // Locate the closing `}}`; a lone `{{` with none is literal prose.
            guard let closeOffset = nextCloseBrace(units, from: cursor + 2) else {
                result += String(decoding: units[last..<(cursor + 2)], as: UTF16.self)
                last = cursor + 2
                cursor += 2
                continue
            }

            let name = String(decoding: units[(cursor + 2)..<closeOffset], as: UTF16.self)

            // A well-formed group that names no registered variable is a bug in
            // the section, and shipping the literal braces would hand the model
            // a broken instruction — fail loudly.
            //
            // A group whose name is not a valid variable name is treated as
            // prose instead: prompt text legitimately contains `{{` in code
            // samples and JSON, and crashing the app over a literal brace in a
            // description would be worse than passing it through.
            let validName = name.range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil
            if !validName {
                result += String(decoding: units[last..<(cursor + 2)], as: UTF16.self)
                last = cursor + 2
                cursor += 2
                continue
            }

            guard let value = variables[name] else {
                preconditionFailure("unknown prompt variable \"{{\(name)}}\" in section \"\(sectionName)\"; registered variables: \(variables.keys.sorted().joined(separator: ", "))")
            }

            result += String(decoding: units[last..<cursor], as: UTF16.self) + value
            last = closeOffset + 2
            cursor = closeOffset + 2
        }

        result += String(decoding: units[last...], as: UTF16.self)
        return result
    }

    /// Find the next `}}` at or after `from`, or nil when the text never closes.
    private static func nextCloseBrace(_ units: [UInt16], from: Int) -> Int? {
        var i = from
        while i < units.count {
            if units[i] == 0x7D, i + 1 < units.count, units[i + 1] == 0x7D { return i }
            if units[i] == 0x7B, i + 1 < units.count, units[i + 1] == 0x7B { return nil }
            i += 1
        }
        return nil
    }
}
