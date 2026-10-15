//
//  DSHToolBlockKind.swift
//  Minis
//
//  Maps a DSH tool call onto the UI block kind that renders it.
//
//  Each Minis tool has a dedicated block kind carrying the argument the UI
//  shows in its header (the command, the path, the action). The DSH driver
//  reports a tool by name plus an argument dictionary, so the mapping lives
//  here rather than being re-derived at each render site.
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

        default:
            // An unknown tool still gets a block so its result is visible; the
            // generic `.info` kind is the only kind that carries no header.
            return .info
        }
    }
}
