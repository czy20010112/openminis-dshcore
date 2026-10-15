//
//  DSHPromptAdapter.swift
//  Minis
//
//  Supplies the DSH-assembled system prompt and the tool roster to the agent
//  loop.
//
//  This is the surgical seam. The ViewModel keeps its streaming, persistence,
//  image budgeting, group fallback, TTS and UI — all of which are load-bearing
//  and heavily patched. What changes is the two inputs that decide how well the
//  agent works:
//
//  - `baseSystemPrompt` becomes an ordered DSH assembly instead of one
//    concatenated string, so contributions cannot silently displace each other;
//  - the tool roster comes from `makeAgentTools()`, and the DSH registry adds
//    the declared concurrency Minis has no opinion about.
//
//  Set `AIChatViewModel.useDSHAgentLoop = false` to fall back to the original
//  loop for A/B comparison on the device.
//

import Foundation

// MARK: - Feature Flag

extension AIChatViewModel {
    /// Whether the DSH agent core replaces the original loop.
    ///
    /// Defaults on: the DSH core is the replacement. Turn it off to compare
    /// behaviour against the original loop on the device without rebuilding.
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

    /// The context fragments the original assembly appended at the call site.
    ///
    /// These are registered as sections so they land at their declared order
    /// inside the assembly, and so the DSH turn — which builds its own prompt
    /// instead of calling `dshSystemPrompt` — gets them too. It did not, at
    /// first: a turn driven by the DSH core was missing the model's own
    /// capability and behaviour notes, the skill index, the MCP server list and
    /// the authoritative memory state, all of which the legacy path kept.
    ///
    /// - Returns: the disposers, in registration order.
    func dshRegisterContextSections(into prompt: DSHSystemPrompt) -> [() -> Void] {
        var disposers: [() -> Void] = []
        let model = selectedModel

        if let fragment = model.capabilityPromptFragment, !fragment.isEmpty {
            disposers.append(prompt.section(DSHPromptSection(
                name: "minis:model-capability",
                order: DSHSectionOrder.personaPrefix.rawValue + 10,
                text: fragment
            )))
        }
        if let fragment = model.agentBehaviorPromptFragment, !fragment.isEmpty {
            disposers.append(prompt.section(DSHPromptSection(
                name: "minis:model-behaviour",
                order: DSHSectionOrder.personaPrefix.rawValue + 20,
                text: fragment
            )))
        }
        if let sid = sessionId,
           let fragment = SkillStore.shared.skillPromptFragment(for: sid), !fragment.isEmpty {
            disposers.append(prompt.section(DSHPromptSection(
                name: "minis:skills",
                order: DSHSectionOrder.skills.rawValue,
                text: fragment
            )))
        }
        if let sid = sessionId,
           let fragment = MCPStore.shared.systemPromptSnippet(for: sid), !fragment.isEmpty {
            disposers.append(prompt.section(DSHPromptSection(
                name: "minis:mcp",
                order: DSHSectionOrder.skills.rawValue + 10,
                text: fragment
            )))
        }
        let memoryStatus = memoryStatusFragment
        if !memoryStatus.isEmpty {
            disposers.append(prompt.section(DSHPromptSection(
                name: "minis:memory-status",
                order: DSHSectionOrder.memory.rawValue,
                text: memoryStatus
            )))
        }
        return disposers
    }

    /// Sandbox root the DSH runtime context reports.
    static var dshSandboxRoot: String { "/var/minis" }
}

// MARK: - Tool Roster

extension AIChatViewModel {

    /// The tool roster for a turn, when the DSH core is driving.
    ///
    /// This deliberately delegates. An earlier version re-declared the whole
    /// tool set here through the DSH schema builder, which meant two hand-written
    /// copies of every schema — this one and the registry's — and they disagreed
    /// with `makeAgentTools()` in the same way: `browser_use` and the iOS 26
    /// line's delegation tool were missing from both, so the model never saw
    /// them and nothing reported it.
    ///
    /// `makeAgentTools()` is the authoritative roster. It is the only place that
    /// knows the gating (the memory toggle, the settings switches, the Vision
    /// Group, the sub-agent switch), and the DSH layer has no business forming a
    /// second opinion about it.
    func dshAgentTools() -> [AgentToolDefinition] {
        makeAgentTools()
    }
}
