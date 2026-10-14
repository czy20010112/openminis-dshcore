//
//  DSHToolHandlers.swift
//  Minis
//
//  Builds the DSH tool registry from Minis' existing tool handlers.
//
//  The handlers themselves are unchanged — `executeCommand`, the file tools, the
//  image reader, the memory store. What this adds is the declared concurrency
//  mode the DSH scheduler needs, and the streaming-output path the UI already
//  renders.
//
//  Concurrency policy:
//
//  - Exclusive: anything that mutates shared sandbox state or a shared file.
//    Overlapping two of these is a correctness bug, not a performance loss.
//  - Parallel: pure reads and lookups.
//  - Unknown tools default to exclusive, so a new tool must opt into
//    parallelism rather than inheriting it by omission.
//

import Foundation

extension AIChatViewModel {

    /// The DSH tool registry for this conversation.
    ///
    /// Rebuilt per turn so a Settings change to a tool switch takes effect on
    /// the next request rather than being cached from the previous one.
    func dshAgentRegistry() -> [DSHTool] {
        var tools: [DSHTool] = []

        // MARK: shell_execute

        tools.append(DSHMinisTools.make(
            name: "shell_execute",
            description: "Execute a command in an isolated Linux process (iSH/Alpine Linux). The command runs via /bin/sh -c with stdout and stderr captured separately via pipes. Each invocation spawns a fresh process — there is no shared terminal session. Default timeout is 15 minutes.",
            parameters: DSHMinisTools.shellExecuteSchema(),
            executionMode: .exclusive,
            handler: { [weak self] args, _ in
                guard let self else { return DSHToolExecutionResult.error("view model released") }
                let command = DSHToolArguments.string(args, "command", or: "")
                let timeout = TimeInterval(DSHToolArguments.int(args, "timeout", or: 900))
                let output = await self.dshRunShell(command: command, timeout: timeout)
                return DSHToolExecutionResult(content: output, isError: false)
            }
        ))

        // MARK: file_read

        tools.append(DSHMinisTools.make(
            name: "file_read",
            description: "Read a file from the Linux filesystem. Faster than shell_execute for reading files — no shell overhead. Returns file content with metadata. Rejects binary files.",
            parameters: DSHMinisTools.fileReadSchema(),
            executionMode: .parallel,
            handler: { [weak self] args, _ in
                guard let self else { return DSHToolExecutionResult.error("view model released") }
                let path = DSHToolArguments.string(args, "path", or: "")
                let content = await self.dshReadFile(path: path)
                return DSHToolExecutionResult(content: content, isError: false)
            }
        ))

        // MARK: file_write

        tools.append(DSHMinisTools.make(
            name: "file_write",
            description: "Write content to a file on the Linux filesystem. Faster than shell_execute for writing files. Creates the file if it doesn't exist. Use append mode to add to existing files.\n\nIMPORTANT for large files (roughly >8KB): do NOT emit it as one call. Every byte of `content` is generated and streamed as tool arguments, so one huge call is slow and frequently dies mid-request. Instead either (a) write the first chunk, then extend it with further calls using append: true, or (b) when the content is repetitive or computable, write a short script and run it with shell_execute.",
            parameters: DSHMinisTools.fileWriteSchema(),
            executionMode: .exclusive,
            handler: { [weak self] args, _ in
                guard let self else { return DSHToolExecutionResult.error("view model released") }
                let path = DSHToolArguments.string(args, "path", or: "")
                let content = DSHToolArguments.string(args, "content", or: "")
                let append = DSHToolArguments.bool(args, "append", or: false)
                let result = await self.dshWriteFile(path: path, content: content, append: append)
                return DSHToolExecutionResult(content: result, isError: false)
            }
        ))

        // MARK: file_edit

        tools.append(DSHMinisTools.make(
            name: "file_edit",
            description: "Make targeted edits to an existing file using exact string replacement. ALWAYS use file_read first to see the current file contents before editing. Prefer file_edit over file_write when modifying existing files — only the changed part needs to be specified. The old_string must match exactly one location in the file (including whitespace/indentation), unless replace_all is true.",
            parameters: DSHMinisTools.fileEditSchema(),
            executionMode: .exclusive,
            handler: { [weak self] args, _ in
                guard let self else { return DSHToolExecutionResult.error("view model released") }
                let path = DSHToolArguments.string(args, "path", or: "")
                let old = DSHToolArguments.string(args, "old_string", or: "")
                let new = DSHToolArguments.string(args, "new_string", or: "")
                let replaceAll = DSHToolArguments.bool(args, "replace_all", or: false)
                let result = await self.dshEditFile(path: path, oldString: old, newString: new, replaceAll: replaceAll)
                return DSHToolExecutionResult(content: result, isError: false)
            }
        ))

        // MARK: read_image

        if activeModelHasNativeVision {
            tools.append(DSHMinisTools.make(
                name: "read_image",
                description: "Read an image file from the Linux filesystem and return it for visual analysis. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, or any visual output. The image is returned directly for your analysis along with metadata (dimensions, file size).",
                parameters: DSHJSONSchema.object(
                    properties: [
                        DSHMinisTools.toolTitleParam(),
                        ("path", DSHJSONSchema.string(description: "Linux path (e.g. /var/minis/attachments/chart.png) or minis:// URL (e.g. minis://attachments/chart.png)")),
                        ("prompt", DSHJSONSchema.string(description: "Optional. A note about what you are looking for in the image.")),
                    ],
                    required: ["tool_title", "path"]
                ),
                executionMode: .parallel,
                handler: { [weak self] args, _ in
                    guard let self else { return DSHToolExecutionResult.error("view model released") }
                    let path = DSHToolArguments.string(args, "path", or: "")
                    let result = await self.dshReadImage(path: path)
                    return DSHToolExecutionResult(content: result, isError: false)
                }
            ))
        }

        // MARK: memory tools

        if memoryEnabled {
            tools.append(DSHMinisTools.make(
                name: "memory_write",
                description: "Write a memory entry to today's daily log (YYYY-MM-DD.md). Memories persist across all sessions. Each entry is prepended with a timestamp. Save: user preferences, recurring patterns, key facts, project conventions, reusable knowledge. Avoid saving passwords, API keys, tokens, or secrets unless the user explicitly confirms after being warned. Keep entries concise and general-purpose.",
                parameters: DSHJSONSchema.object(
                    properties: [
                        DSHMinisTools.toolTitleParam(),
                        ("content", DSHJSONSchema.string(description: "The memory content to write. Use concise Markdown with a short heading (## Topic) and context about what was done or learned.")),
                    ],
                    required: ["tool_title", "content"]
                ),
                executionMode: .exclusive,
                handler: { [weak self] args, _ in
                    guard let self else { return DSHToolExecutionResult.error("view model released") }
                    let content = DSHToolArguments.string(args, "content", or: "")
                    let result = await self.dshWriteMemory(content: content)
                    return DSHToolExecutionResult(content: result, isError: false)
                }
            ))
            tools.append(DSHMinisTools.make(
                name: "memory_get",
                description: "Retrieve memories from persistent storage. Supports keyword-based fuzzy search across memory files. Returns matching lines with surrounding context. Use this to recall previous knowledge, user preferences, or past notes.",
                parameters: DSHJSONSchema.object(
                    properties: [
                        DSHMinisTools.toolTitleParam(),
                        ("scope", DSHJSONSchema.string(description: "Memory scope to search: 'daily' for daily logs only, 'all' for daily logs + GLOBAL.md.", enumValues: ["daily", "all"])),
                        ("keywords", DSHJSONSchema.string(description: "Space-separated keywords for fuzzy matching. All keywords must appear in a line or its surrounding context for a match. Leave empty to return full memory files.")),
                    ],
                    required: ["tool_title"]
                ),
                executionMode: .parallel,
                handler: { [weak self] args, _ in
                    guard let self else { return DSHToolExecutionResult.error("view model released") }
                    let keywords = DSHToolArguments.string(args, "keywords", or: "")
                    let scope = DSHToolArguments.string(args, "scope", or: "all")
                    let result = await self.dshGetMemory(keywords: keywords, scope: scope)
                    return DSHToolExecutionResult(content: result, isError: false)
                }
            ))
        }

        return tools
    }
}
