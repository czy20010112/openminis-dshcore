//
//  DSHMinisTools.swift
//  Minis
//
//  Bridges OpenMinis' own tool definitions into the DSH registry.
//
//  The tool surface is Minis'. `makeAgentTools()` owns which tools exist, their
//  descriptions, their parameters and their gating — all of it shaped by
//  settings toggles, the configured Vision Group, and the sub-agent switch. The
//  DSH port replaces the *scheduling* of those tools, not their declaration, so
//  the registry is built from that same list rather than from a second,
//  hand-maintained copy of the schemas.
//
//  The copy is what this file used to be, and it drifted: `browser_use` and the
//  iOS 26 line's delegation tool were never re-declared, so the model simply
//  never saw them, and nothing reported that. Deriving the registry removes the
//  possibility rather than the instance — a tool Minis offers is offered here,
//  with the same description and the same parameters, by construction.
//
//  Declared concurrency is the one thing Minis does not have an opinion about,
//  and it stays here: `DSHToolDispatch.mode(for:)` says whether a tool may run
//  alongside another.
//

import Foundation

/// Bridges Minis' tool definitions into the DSH registry.
enum DSHMinisTools {

    /// A handler that executes one tool call and returns a result.
    typealias Handler = @Sendable ([String: Any], DSHToolRunContext) async throws -> DSHToolExecutionResult

    /// Build a DSH tool from a Minis tool definition.
    static func make(
        from definition: AgentToolDefinition,
        executionMode: DSHToolExecutionMode,
        handler: @escaping Handler
    ) -> DSHTool {
        DSHTool(
            name: definition.name,
            description: definition.description,
            parameters: jsonSchema(from: definition),
            executionMode: executionMode,
            propertyOrdering: definition.propertyOrdering,
            body: handler
        )
    }

    /// Render a Minis tool definition as the JSON Schema a DSHTool carries.
    static func jsonSchema(from definition: AgentToolDefinition) -> [String: Any] {
        let properties = parameterNames(of: definition).compactMap { name -> (name: String, schema: [String: Any])? in
            guard let param = definition.parameters[name] else { return nil }
            return (name, schema(for: param))
        }
        return DSHJSONSchema.object(properties: properties, required: definition.required)
    }

    /// Every parameter name, in the order it should be presented.
    ///
    /// `AgentToolDefinition.parameters` is a dictionary and therefore unordered,
    /// so the declared order comes from `propertyOrdering`. Anything it does not
    /// name is appended; the order of those is unspecified, but the ordering
    /// that providers act on is the declared one, which travels separately.
    private static func parameterNames(of definition: AgentToolDefinition) -> [String] {
        var names = definition.propertyOrdering ?? []
        for name in definition.parameters.keys where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private static func schema(for param: AgentToolParam) -> [String: Any] {
        var schema: [String: Any] = ["type": typeName(param.type)]
        if !param.description.isEmpty { schema["description"] = param.description }
        if let values = param.enumValues, !values.isEmpty { schema["enum"] = values }
        return schema
    }

    /// `AgentParamType` has no `number` case, so a numeric parameter is an
    /// integer on the wire. That mirrors what the original loop sent.
    private static func typeName(_ type: AgentParamType) -> String {
        switch type {
        case .string: return "string"
        case .integer: return "integer"
        case .boolean: return "boolean"
        }
    }
}
