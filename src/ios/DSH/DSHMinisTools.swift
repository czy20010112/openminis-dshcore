//
//  DSHMinisTools.swift
//  Minis
//
//  Bridges OpenMinis' existing tools into the DSH tool registry.
//
//  The tools themselves are untouched: this adapter only wraps each existing
//  handler as a DSH `DSHTool` with a declared execution mode. Interaction and
//  tool behaviour are preserved; only the scheduling semantics change.
//

import Foundation

/// Bridges OpenMinis' existing tool handlers into the DSH registry.
public enum DSHMinisTools {

    /// A handler that executes one tool call and returns a result.
    public typealias Handler = @Sendable ([String: Any], DSHToolRunContext) async throws -> DSHToolExecutionResult

    /// Build a DSH tool from a name, schema, and existing handler.
    public static func make(
        name: String,
        description: String,
        parameters: [String: Any],
        executionMode: DSHToolExecutionMode,
        handler: @escaping Handler
    ) -> DSHTool {
        DSHTool(
            name: name,
            description: description,
            parameters: parameters,
            executionMode: executionMode,
            body: handler
        )
    }

    // MARK: - Shared parameter Schemas

    /// The `tool_title` parameter every Minis tool accepts.
    public static func toolTitleParam() -> (name: String, schema: [String: Any]) {
        (
            "tool_title",
            DSHJSONSchema.string(
                description: "A concise 5-10 word summary of what this call does, shown to the user in the transcript. Use the user's language."
            )
        )
    }

    /// Object schema for a shell command.
    public static func shellExecuteSchema() -> [String: Any] {
        DSHJSONSchema.object(
            properties: [
                toolTitleParam(),
                (
                    "command",
                    DSHJSONSchema.string(
                        description: "The shell command to run, passed to /bin/sh -c. Multi-line commands are fine. For a long script, write it with file_write first and run the file.",
                        maxLength: 100_000
                    )
                ),
                (
                    "timeout",
                    DSHJSONSchema.integer(
                        description: "Timeout in seconds (default 900).",
                        minimum: 1,
                        maximum: 3600,
                        default: 900
                    )
                ),
                (
                    "delay",
                    DSHJSONSchema.integer(
                        description: "Seconds to wait before starting, without holding the shell.",
                        minimum: 0,
                        maximum: 600
                    )
                ),
            ],
            required: ["tool_title", "command"]
        )
    }

    /// Object schema for reading a file.
    public static func fileReadSchema() -> [String: Any] {
        DSHJSONSchema.object(
            properties: [
                toolTitleParam(),
                (
                    "path",
                    DSHJSONSchema.string(
                        description: "Absolute Linux path to read."
                    )
                ),
                (
                    "offset",
                    DSHJSONSchema.integer(
                        description: "1-based line to start from. Use the next_offset a truncated read reports.",
                        minimum: 1
                    )
                ),
                (
                    "lines",
                    DSHJSONSchema.integer(
                        description: "Maximum lines to return.",
                        minimum: 1
                    )
                ),
                (
                    "direction",
                    DSHJSONSchema.string(
                        description: "Read from the start or the end of the file.",
                        enumValues: ["head", "tail"]
                    )
                ),
                (
                    "max_length",
                    DSHJSONSchema.integer(
                        description: "Maximum characters of content to return.",
                        minimum: 100,
                        default: 15_000
                    )
                ),
            ],
            required: ["tool_title", "path"]
        )
    }

    /// Object schema for writing a file.
    public static func fileWriteSchema() -> [String: Any] {
        DSHJSONSchema.object(
            properties: [
                toolTitleParam(),
                ("path", DSHJSONSchema.string(description: "Absolute Linux path to write.")),
                ("content", DSHJSONSchema.string(description: "Text content to write.")),
                (
                    "append",
                    DSHJSONSchema.boolean(
                        description: "Append instead of overwrite.",
                        default: false
                    )
                ),
                (
                    "create_dirs",
                    DSHJSONSchema.boolean(
                        description: "Create parent directories.",
                        default: false
                    )
                ),
            ],
            required: ["tool_title", "path", "content"]
        )
    }

    /// Object schema for a targeted edit.
    public static func fileEditSchema() -> [String: Any] {
        DSHJSONSchema.object(
            properties: [
                toolTitleParam(),
                ("path", DSHJSONSchema.string(description: "Absolute Linux path to edit.")),
                (
                    "old_string",
                    DSHJSONSchema.string(
                        description: "Exact text to find, including whitespace. Must be unique unless replace_all is true."
                    )
                ),
                ("new_string", DSHJSONSchema.string(description: "Replacement text. Empty deletes.")),
                (
                    "replace_all",
                    DSHJSONSchema.boolean(description: "Replace every occurrence.", default: false)
                ),
            ],
            required: ["tool_title", "path", "old_string", "new_string"]
        )
    }
}
