//
//  DSHPromptAdapter.swift
//  Minis
//
//  Supplies the DSH-assembled system prompt and tool set to AIChatViewModel's
//  existing agent loop.
//
//  This is the surgical seam. The ViewModel's loop keeps its streaming,
//  persistence, image budgeting, compaction, group fallback, and UI — all of
//  which are load-bearing and heavily patched. What changes is the two inputs
//  that decide how well the agent works:
//
//  - `baseSystemPrompt` becomes an ordered DSH assembly instead of one
//    concatenated string, so contributions cannot silently displace each other;
//  - the tool set is produced from the DSH registry, so tool descriptions and
//    parameter ordering come from one typed source.
//
//  Set `AIChatViewModel.useDSHAgentLoop = false` to fall back to the original
//  prompt and tool list for A/B comparison on the device.
//

import Foundation

// MARK: - Feature Flag

extension AIChatViewModel {
    /// Whether the DSH-assembled system prompt and tool set replace the
    /// built-in ones.
    ///
    /// Defaults on: the DSH assembly is the replacement core. Turn it off to
    /// compare behaviour against the original prompt and tool list on the
    /// device without rebuilding.
    static var useDSHAgentLoop: Bool {
        get { UserDefaults.standard.object(forKey: "minis.useDSHAgentLoop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "minis.useDSHAgentLoop") }
    }
}

// MARK: - Prompt Assembly

extension AIChatViewModel {

    /// The DSH-assembled system prompt.
    ///
    /// Assembled from registered sections in their declared order, so the
    /// result is identical on every run regardless of registration sequence.
    var dshSystemPrompt: String {
        let prompt = DSHSystemPrompt()
        var disposers: [() -> Void] = []
        defer { for d in disposers { d() } }

        disposers.append(contentsOf: DSHMinisPrompt.registerBase(into: prompt))

        // Dynamic runtime context: the facts the model would otherwise guess
        // at. Folded in as a snapshot of the state at request-build time.
        disposers.append(prompt.section(DSHMinisPrompt.runtimeContextSection(
            sandboxRoot: Self.dshSandboxRoot,
            sessionId: sessionId,
            memoryEnabled: memoryEnabled
        )))

        let assembly = prompt.assemble(
            tools: [],
            context: DSHAssembleContext(
                model: selectedModel.id,
                provider: selectedModel.provider,
                cwd: nil,
                toolNames: [],
                isHelper: false
            )
        )

        var text = DSHSystemPrompt.renderPrompt(assembly)

        // Preserve the model-specific fragments the original prompt injected:
        // they carry per-model capability and behaviour notes that are still
        // accurate, and dropping them would regress specific models.
        if let capFragment = selectedModel.capabilityPromptFragment {
            text += "\n\n" + capFragment
        }
        if let behaviorFragment = selectedModel.agentBehaviorPromptFragment {
            text += "\n\n" + behaviorFragment
        }

        // Skill and MCP metadata keep their own trailing position, as in the
        // original assembly.
        if let sid = sessionId, let skillFragment = SkillStore.shared.skillPromptFragment(for: sid) {
            text += "\n\n" + skillFragment
        }
        if let sid = sessionId, let mcpFragment = MCPStore.shared.systemPromptSnippet(for: sid) {
            text += "\n\n" + mcpFragment
        }

        return text
    }

    /// Sandbox root the DSH runtime context reports.
    static var dshSandboxRoot: String { "/var/minis" }
}

// MARK: - Tool Set

extension AIChatViewModel {

    /// The DSH-assembled tool set.
    ///
    /// Same tools, same handlers, same gating as `makeAgentTools()`; the
    /// definitions are declared through the DSH schema builder so descriptions,
    /// parameter ordering, and required fields stay consistent.
    func dshAgentTools() -> [AgentToolDefinition] {
        let registry = DSHToolRegistry()
        var disposers: [() -> Void] = []
        defer { for d in disposers { d() } }

        // shell_execute
        disposers.append(registry.register(DSHMinisTools.make(
            name: "shell_execute",
            description: "Execute a command in an isolated Linux process (iSH/Alpine Linux). The command runs via /bin/sh -c with stdout and stderr captured separately via pipes. Each invocation spawns a fresh process — there is no shared terminal session. Default timeout is 15 minutes.",
            parameters: DSHMinisTools.shellExecuteSchema(),
            executionMode: DSHToolDispatch.mode(for: "shell_execute"),
            handler: { _, _ in DSHToolExecutionResult.error("handler wired at call site") }
        )))

        // file_read / file_write / file_edit
        disposers.append(registry.register(DSHMinisTools.make(
            name: "file_read",
            description: "Read a file from the Linux filesystem. Faster than shell_execute for reading files — no shell overhead. Returns file content with metadata. Rejects binary files.",
            parameters: DSHMinisTools.fileReadSchema(),
            executionMode: DSHToolDispatch.mode(for: "file_read"),
            handler: { _, _ in DSHToolExecutionResult.error("handler wired at call site") }
        )))
        disposers.append(registry.register(DSHMinisTools.make(
            name: "file_write",
            description: "Write content to a file on the Linux filesystem. Faster than shell_execute for writing files. Creates the file if it doesn't exist. Use append mode to add to existing files.\n\nIMPORTANT for large files (roughly >8KB): do NOT emit it as one call. Every byte of `content` is generated and streamed as tool arguments, so one huge call is slow and frequently dies mid-request. Instead either (a) write the first chunk, then extend it with further calls using append: true, or (b) when the content is repetitive or computable, write a short script and run it with shell_execute.",
            parameters: DSHMinisTools.fileWriteSchema(),
            executionMode: DSHToolDispatch.mode(for: "file_write"),
            handler: { _, _ in DSHToolExecutionResult.error("handler wired at call site") }
        )))
        disposers.append(registry.register(DSHMinisTools.make(
            name: "file_edit",
            description: "Make targeted edits to an existing file using exact string replacement. ALWAYS use file_read first to see the current file contents before editing. Prefer file_edit over file_write when modifying existing files — only the changed part needs to be specified. The old_string must match exactly one location in the file (including whitespace/indentation), unless replace_all is true.",
            parameters: DSHMinisTools.fileEditSchema(),
            executionMode: DSHToolDispatch.mode(for: "file_edit"),
            handler: { _, _ in DSHToolExecutionResult.error("handler wired at call site") }
        )))

        // Memory tools are gated by the per-session toggle, matching the
        // original registration so the model never sees a tool that is off.
        if memoryEnabled {
            disposers.append(registry.register(DSHMinisTools.make(
                name: "memory_write",
                description: "Write a memory entry to today's daily log (YYYY-MM-DD.md). Memories persist across all sessions. Each entry is prepended with a timestamp. Save: user preferences, recurring patterns, key facts, project conventions, reusable knowledge. Avoid saving passwords, API keys, tokens, or secrets unless the user explicitly confirms after being warned. Keep entries concise and general-purpose.",
                parameters: DSHJSONSchema.object(
                    properties: [
                        DSHMinisTools.toolTitleParam(),
                        ("content", DSHJSONSchema.string(description: "The memory content to write. Use concise Markdown with a short heading (## Topic) and context about what was done or learned.")),
                    ],
                    required: ["tool_title", "content"]
                ),
                executionMode: DSHToolDispatch.mode(for: "memory_write"),
                handler: { _, _ in DSHToolExecutionResult.error("handler wired at call site") }
            )))
            disposers.append(registry.register(DSHMinisTools.make(
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
                executionMode: DSHToolDispatch.mode(for: "memory_get"),
                handler: { _, _ in DSHToolExecutionResult.error("handler wired at call site") }
            )))
        }

        // read_image, registered when the model that will actually receive the
        // turn can see images itself.
        if activeModelHasNativeVision {
            disposers.append(registry.register(DSHMinisTools.make(
                name: "read_image",
                description: "Read an image file from the Linux filesystem and return it for visual analysis. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, or any visual output. The image is returned directly for your analysis along with metadata (dimensions, file size).",
                parameters: DSHJSONSchema.object(
                    properties: [
                        DSHMinisTools.toolTitleParam(),
                        ("path", DSHJSONSchema.string(description: "Linux path (e.g. /var/minis/attachments/chart.png) or minis:// URL (e.g. minis://attachments/chart.png)")),
                        ("prompt", DSHJSONSchema.string(description: "Optional. A note about what you are looking for in the image. Recorded alongside the result; the image itself is returned to you in full either way.")),
                    ],
                    required: ["tool_title", "path"]
                ),
                executionMode: DSHToolDispatch.mode(for: "read_image"),
                handler: { _, _ in DSHToolExecutionResult.error("handler wired at call site") }
            )))
        }

        return DSHToolSchemaBridge.toAgentToolDefinitions(registry.schemas())
    }
}
