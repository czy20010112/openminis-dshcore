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
//  Tools whose block kind exists on only one of the two source lines are handled
//  by `lineSpecificKind(for:arguments:)`, defined in the branch-specific seam
//  file `DSHTurnDriverBridge.swift`. The iOS 26 line's v1.14 added
//  `AssistantBlockKind.delegateTool(title:)`; the iOS 15 line's enum has no such
//  case, so naming it here would not compile there.
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

        default:
            // A tool whose block kind only exists on one of the two lines. Split
            // out because the two lines do not have the same set of
            // `AssistantBlockKind` cases.
            if let kind = lineSpecificKind(for: name, arguments: arguments) {
                return kind
            }
            // An unknown tool still gets a block so its result is visible; the
            // generic `.info` kind is the only kind that carries no header.
            return .info
        }
    }
}
