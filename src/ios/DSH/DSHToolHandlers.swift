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
//  Registration gating mirrors `makeAgentTools()` exactly. A tool that Minis
//  would have offered must be offered here too, or switching the loop on would
//  silently take a capability away from the model.
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
                return await self.dshRunShell(args: args)
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
                return await self.dshReadFile(args: args)
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
                return await self.dshWriteFile(args: args)
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
                return await self.dshEditFile(args: args)
            }
        ))

        // MARK: read_image

        // [T-ios-vision-group #182] Expose read_image when the model can see
        // images ITSELF, or when a Vision Group is configured to see them on its
        // behalf — the same gate `makeAgentTools()` uses. Previously a text-only
        // model simply never got this tool, so an image on disk was invisible to
        // it with no recourse. The handler picks the matching branch: native
        // models get pixels, others get the Vision Group's description as text.
        //
        // `isConfigured` is evaluated FIRST and not inside the `||`: short-
        // circuiting on `nativeVision` would skip the call, and that read is what
        // keeps the cached mirror fresh for the off-main placeholder builder.
        let nativeVision = activeModelHasNativeVision
        let visionGroupConfigured = VisionGroupResolver.isConfigured
        if nativeVision || visionGroupConfigured {
            // Describe what this model will ACTUALLY receive. Promising "the image
            // is returned directly" to a text-only model sets up a false
            // expectation and invites it to re-call the tool when no pixels
            // arrive; that branch returns a written description instead.
            let readImageDescription = nativeVision
                ? "Read an image file from the Linux filesystem and return it for visual analysis. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, or any visual output. The image is returned directly for your analysis along with metadata (dimensions, file size)."
                : "Read an image file from the Linux filesystem and return a written description of it. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, user-attached photos, or any visual output. You cannot see images directly, so the image is analyzed by a separate vision model and you receive its detailed description plus a transcription of any visible text, along with metadata (dimensions, file size). Because you cannot look again yourself, use the optional 'prompt' argument to ask for exactly what you need from the image — that is your only way to follow up on specific details."
            let promptDescription = nativeVision
                ? "Optional. A note about what you are looking for in the image. Recorded alongside the result; the image itself is returned to you in full either way."
                : "Optional. A specific question or instruction about the image, e.g. 'transcribe the table', 'what error message is shown in this screenshot', 'describe the people and their expressions'. This is passed to the vision model that reads the image for you, so ask for exactly the detail you need. If omitted, a generic detailed description with full text transcription is returned."

            tools.append(DSHMinisTools.make(
                name: "read_image",
                description: readImageDescription,
                parameters: DSHJSONSchema.object(
                    properties: [
                        DSHMinisTools.toolTitleParam(),
                        ("path", DSHJSONSchema.string(description: "Linux path (e.g. /var/minis/attachments/chart.png) or minis:// URL (e.g. minis://attachments/chart.png)")),
                        ("prompt", DSHJSONSchema.string(description: promptDescription)),
                    ],
                    required: ["tool_title", "path"]
                ),
                executionMode: .parallel,
                handler: { [weak self] args, context in
                    guard let self else { return DSHToolExecutionResult.error("view model released") }
                    return await self.dshReadImage(args: args, callId: context.callId)
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
                    return await self.dshWriteMemory(args: args)
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
                    return await self.dshGetMemory(args: args)
                }
            ))
        }

        return tools
    }
}
