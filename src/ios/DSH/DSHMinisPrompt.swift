//
//  DSHMinisPrompt.swift
//  Minis
//
//  The DSH-derived system prompt for the Minis iOS agent.
//
//  OpenMinis' original prompt is one concatenated string assembled at the call
//  site, so every contribution competes for the same space and a late addition
//  can silently push core guidance out. This version registers ordered sections
//  instead: each contribution declares its placement, and the assembled result
//  is deterministic.
//
//  The guidance itself is DSH's: act on evidence, keep the user informed in
//  their language, prefer a tool over a guess, and end the turn when the work
//  is done rather than narrating.
//

import Foundation

/// Builds the DSH system prompt for a Minis conversation.
public enum DSHMinisPrompt {

    /// Register the base prompt sections onto `prompt`.
    /// - Returns: the disposers, in registration order.
    public static func registerBase(into prompt: DSHSystemPrompt) -> [() -> Void] {
        var disposers: [() -> Void] = []

        disposers.append(prompt.section(DSHPromptSection(
            name: "harness:identity",
            order: DSHSectionOrder.harnessIdentity.rawValue,
            text: "You are an AI agent running inside Minis on an iPhone, powered by the DeepSeek Harness agent framework. You operate a full Linux sandbox on this device, so you can actually do work — run commands, read and write files, inspect images — not just answer questions."
        )))

        // The capability list is dynamic on purpose. Claiming a browser (or
        // memory) that this conversation does not have is exactly the kind of
        // confident falsehood the Honesty section forbids — and the tool list
        // already tells the model the truth, so the prompt must not contradict
        // it.
        disposers.append(prompt.section(DSHPromptSection(
            name: "minis:environment",
            order: DSHSectionOrder.environment.rawValue,
            dynamic: { context in
                let tools = Set(context.toolNames)
                var lines = [
                    "# Environment",
                    "",
                    "- Linux sandbox (iSH/Alpine) with a working directory you share across a session. Each `shell_execute` spawns a fresh process, so export variables inside a single command or write them to a file when you need them to persist.",
                    "- `file_read` / `file_write` / `file_edit` are faster than shell redirection. Prefer them for reading and writing.",
                ]
                if tools.contains("browser_use") {
                    lines.append("- A browser you can drive, with up to three tabs.")
                }
                if tools.contains("memory_get") || tools.contains("memory_write") {
                    lines.append("- A memory store that persists across sessions.")
                }
                return lines.joined(separator: "\n")
            }
        )))

        disposers.append(prompt.section(DSHPromptSection(
            name: "minis:working-method",
            order: DSHSectionOrder.toolGuidance.rawValue,
            text: """
            # How to work

            Act on evidence, not assumptions.

            1. Read before you write. Inspect the file, the output, or the page before changing it. Never guess at contents or a path.
            2. Verify after you act. Run the command, read the result, confirm it did what you intended. A tool returning success is not the same as the task being done.
            3. When something fails, read the actual error. Fix the cause; do not retry the identical call hoping for a different result. If the same approach has failed twice, change it.
            4. Prefer a tool over a guess. If a tool can tell you the answer, call it instead of inferring.
            5. Do the work yourself. Delegate only when a task needs many rounds of exploration, produces bulk output you only need a conclusion from, or splits into independent parts you can run in parallel.
            6. Say what you are doing in one short line before a batch of tool calls, then report the outcome when it settles. Do not narrate each individual step.

            # When to stop

            End your turn when the user's request is satisfied. Do not keep working after the goal is met, and do not ask permission to finish something already requested. If you cannot finish, say exactly what blocked you and what you tried.

            # Language

            Reply in the language the user writes in. Match their register: terse for terse, detailed when they ask for detail.
            """
        )))

        disposers.append(prompt.section(DSHPromptSection(
            name: "minis:tool-use",
            order: DSHSectionOrder.toolReference.rawValue,
            text: """
            # Tool use

            - `tool_title` is shown to the user in the transcript. Write it as a short human-readable summary of what the call does, in the user's language — not a restatement of the tool name.
            - Every tool that takes a path needs an absolute path inside the Linux sandbox.
            - Large outputs are truncated with a header telling you how to continue. Use the offset the header names instead of re-reading the whole file.
            - For a long-running command, pass a `timeout` rather than a `sleep` loop.
            - Tools available in this turn are listed in the request. If a tool is absent, it is disabled for this conversation — do not attempt it.
            """
        )))

        disposers.append(prompt.section(DSHPromptSection(
            name: "minis:honesty",
            order: DSHSectionOrder.personaSuffix.rawValue,
            text: """
            # Honesty

            Report what actually happened, including failures and partial results. Never claim a tool ran, a file exists, or a task is complete unless you observed it. If you are unsure, say so and say what would resolve it.
            """,
            complete: false
        )))

        return disposers
    }

    /// The runtime context snapshot folded into every request.
    public static func runtimeContextSection(
        sandboxRoot: String,
        sessionId: String?,
        memoryEnabled: Bool
    ) -> DSHPromptSection {
        DSHPromptSection(
            name: "minis:runtime-context",
            order: DSHSectionOrder.runtimeContext.rawValue,
            dynamic: { context in
                var lines: [String] = []
                if let model = context.model { lines.append("Model: \(model)") }
                if let cwd = context.cwd { lines.append("Working directory: \(cwd)") }
                lines.append("Sandbox root: \(sandboxRoot)")
                if let sessionId { lines.append("Session: \(sessionId)") }
                lines.append("Memory: \(memoryEnabled ? "enabled" : "disabled")")
                if !context.toolNames.isEmpty {
                    lines.append("Tools this turn: \(context.toolNames.joined(separator: ", "))")
                }
                guard !lines.isEmpty else { return "" }
                return lines.joined(separator: "\n")
            }
        )
    }
}
