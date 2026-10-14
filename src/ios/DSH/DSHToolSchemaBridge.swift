//
//  DSHToolSchemaBridge.swift
//  Minis
//
//  Converts a DSH JSON-Schema tool definition into the provider-facing
//  `AgentToolDefinition` OpenMinis providers already consume.
//
//  This is the seam that lets the DSH loop drive the existing provider
//  implementations unchanged: the loop reasons about JSON Schema, providers
//  reason about `AgentToolDefinition`.
//

import Foundation

/// Bridges DSH tool schemas onto OpenMinis' provider-facing tool definitions.
///
/// `AgentToolDefinition` is internal to the Minis target, so these converters
/// are internal too — they exist for the loop inside this target, not as public
/// API.
enum DSHToolSchemaBridge {

    /// Convert one schema.
    static func toAgentToolDefinition(_ schema: DSHToolSchema) -> AgentToolDefinition {
        let properties = schema.parameters["properties"] as? [String: Any] ?? [:]
        let required = schema.parameters["required"] as? [String] ?? []

        var params: [String: AgentToolParam] = [:]
        // Preserve the declared property order where the schema exposes it.
        for (name, raw) in properties {
            guard let object = raw as? [String: Any] else { continue }
            params[name] = AgentToolParam(
                type: paramType(object["type"]),
                description: object["description"] as? String ?? "",
                enumValues: object["enum"] as? [String]
            )
        }

        return AgentToolDefinition(
            name: schema.name,
            description: schema.description,
            parameters: params,
            required: required,
            propertyOrdering: nil
        )
    }

    /// Convert a list of schemas.
    static func toAgentToolDefinitions(_ schemas: [DSHToolSchema]) -> [AgentToolDefinition] {
        schemas.map(toAgentToolDefinition)
    }

    private static func paramType(_ raw: Any?) -> AgentParamType {
        switch raw as? String {
        case "integer", "number": return .integer
        case "boolean": return .boolean
        default: return .string
        }
    }
}
