//
//  DSHJSONSchema.swift
//  Minis
//
//  JSON Schema builder for tool parameters, ported from DeepSeek Harness
//  (packages/core/tools/src/json-schema.ts, schema.ts).
//
//  Providers disagree on what they accept, so schemas are built through one
//  typed builder rather than hand-written dictionaries.
//

import Foundation

/// Builds a JSON Schema object for tool arguments.
public enum DSHJSONSchema {

    /// An object schema from ordered properties.
    public static func object(
        properties: [(name: String, schema: [String: Any])],
        required: [String] = [],
        additionalProperties: Bool = false
    ) -> [String: Any] {
        var props: [String: Any] = [:]
        // Preserve declaration order: providers that support property ordering
        // (e.g. Gemini) instruct the model to emit parameters in this order.
        for entry in properties { props[entry.name] = entry.schema }
        var schema: [String: Any] = [
            "type": "object",
            "properties": props,
        ]
        if !required.isEmpty { schema["required"] = required }
        schema["additionalProperties"] = additionalProperties
        return schema
    }

    public static func string(
        description: String,
        enumValues: [String]? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "string", "description": description]
        if let enumValues, !enumValues.isEmpty { schema["enum"] = enumValues }
        if let minLength { schema["minLength"] = minLength }
        if let maxLength { schema["maxLength"] = maxLength }
        return schema
    }

    public static func integer(
        description: String,
        minimum: Int? = nil,
        maximum: Int? = nil,
        default defaultValue: Int? = nil
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "integer", "description": description]
        if let minimum { schema["minimum"] = minimum }
        if let maximum { schema["maximum"] = maximum }
        if let defaultValue { schema["default"] = defaultValue }
        return schema
    }

    public static func boolean(
        description: String,
        default defaultValue: Bool? = nil
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "boolean", "description": description]
        if let defaultValue { schema["default"] = defaultValue }
        return schema
    }

    public static func array(
        description: String,
        items: [String: Any],
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "array",
            "description": description,
            "items": items,
        ]
        if let minItems { schema["minItems"] = minItems }
        if let maxItems { schema["maxItems"] = maxItems }
        return schema
    }

    /// A number schema, used for coordinates and ratios.
    public static func number(
        description: String,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "number", "description": description]
        if let minimum { schema["minimum"] = minimum }
        if let maximum { schema["maximum"] = maximum }
        return schema
    }
}
