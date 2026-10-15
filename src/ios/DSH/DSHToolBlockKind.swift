//
//  DSHToolBlockKind.swift
//  Minis
//
//  Maps a DSH tool call onto the UI block kind that renders it.
//
//  Each Minis tool has a dedicated block kind carrying the argument the UI shows
//  in its header (the command, the path, the action). The DSH driver reports a
//  tool by name plus an argument dictionary, so the mapping lives here rather
//  than being re-derived at each render site.
//
//  Keep this in step with the block the original loop builds while a tool call's
//  arguments stream in — `AIChatViewModel+SSEStream.swift`'s `case "browser_use":`
//  and `case SubAgentDefinition.toolName:` arms. A tool whose kind is missing
//  here still runs, but its block renders headerless.
//

import Foundation

enum DSHToolBlockKind {

    /// The block kind for one tool call.
    static func kind(for name: String, arguments: [String: Any]) -> AssistantBlockKind {
        switch name {
        case "shell_execute":
            let command = DSHToolArguments.string(arguments, "command", or: "")
            return .shellTool(command: String(command.prefix(200)))

        case "file_read":
            return .fileReadTool(path: DSHToolArguments.string(arguments, "path", or: ""))

        case "file_write":
            return .fileWriteTool(path: DSHToolArguments.string(arguments, "path", or: ""))

        case "file_edit":
            return .fileEditTool(path: DSHToolArguments.string(arguments, "path", or: ""))

        case "read_image":
            return .readImageTool(path: DSHToolArguments.string(arguments, "path", or: ""))

        case "memory_write", "memory_get":
            let action = name == "memory_write" ? "write" : "read"
            return .memoryTool(action: action)

        case "browser_use":
            return .browserTool(action: DSHToolArguments.string(arguments, "action", or: ""))

        case "subagent_task":
            // `SubAgentDefinition.toolName`, spelled out because that type only
            // exists on the iOS 26 line and this file is identical on both.
            return .delegateTool(title: DSHToolArguments.string(arguments, "tool_title", or: ""))

        default:
            // An unknown tool still gets a block so its result is visible; the
            // generic `.info` kind is the only kind that carries no header.
            return .info
        }
    }
}
