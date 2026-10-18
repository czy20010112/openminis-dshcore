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

        // Plan mode's policy section, like the DSH turn registers it.
        //
        // This path did not have it: `runDSHTurn` registers it
        // (`DSHTurnDriverRun.swift`), and this assembly — which the legacy loop
        // reaches through `baseSystemPrompt`/`dshSystemPrompt` — did not, so with
        // `minis.useDSHAgentLoop` off the mode flipped its switch and changed
        // nothing about the request. The section renders empty while the mode is
        // off, so registering it on both paths costs nothing and removes the one
        // way for plan mode to be silently inert.
        disposers.append(prompt.section(DSHPlanMode.policySection()))

        // P1-2: the runtime context and the memory fragments are NOT registered
        // here. They are per-turn state, and everything registered into this
        // prompt is rendered into the system prompt — the prefix the engine's KV
        // cache matches on. A memory written in one turn therefore rewrote bytes
        // at the head of the next request and the engine re-prefilled the whole
        // conversation (`cache` 99.5% → 0.0% on the next request, measured).
        //
        // They travel in `dshVolatileTurnContext` instead, which the request
        // builders admit as a message before the turn's own user message — the
        // position upstream DSH gives its runtime-context snapshot
        // (`packages/core/agent-loop/src/runtime-context.ts`).

        // The assembly is unchanged; only the boundary between prompt and message
        // moves. Volatile sections are named with
        // `DSHSystemPrompt.volatileSectionPrefix`, so the render call below is
        // what drops them and the same assembly still reports every section that
        // took part.
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

        var text = DSHSystemPrompt.renderPrompt(excludingVolatileSectionsOf: assembly)

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
            // The status line is authoritative and says the memory files are in
            // this request. It stays in the system prompt: it moves only when the
            // user flips the per-session memory toggle, and it must precede the
            // block it describes.
            //
            // The files themselves used to sit right above it, also in the
            // system prompt — see `dshVolatileTurnContext`. `minis:memory-status`
            // still says "injected", which is now true of the block the request
            // carries ahead of the user's own message.
            disposers.append(prompt.section(DSHPromptSection(
                name: "minis:memory-status",
                order: DSHSectionOrder.memory.rawValue + 20,
                text: memoryStatus
            )))
        }
        return disposers
    }

    /// Sandbox root the DSH runtime context reports.
    static var dshSandboxRoot: String { "/var/minis" }

    // MARK: - Volatile Turn Context (P1-2)

    /// The per-turn block that must NOT go into the system prompt.
    ///
    /// Two kinds of state live here, and both were previously request-head bytes:
    ///
    /// - the memory fragments (`GLOBAL.md` + the recent daily logs), which change
    ///   the moment the agent calls `memory_write`;
    /// - the runtime facts (model, sandbox root, session, which tools are
    ///   registered this turn), which change when a tool is toggled.
    ///
    /// Everything here is rebuilt per request and admitted as its own `user`
    /// message immediately before the turn's own user message — upstream DSH's
    /// position for its runtime-context snapshot
    /// (`packages/core/agent-loop/src/runtime-context.ts`,
    /// `RuntimeContextProjection.project`; admitted in `agent.ts` as
    /// `{ kind: 'enter', messages: [...claimed, context] }`). Semantically it is
    /// the same text in front of the same user message; byte-wise the system
    /// prompt stops changing, so the engine's cached prefix survives.
    ///
    /// - Returns: the block, or nil when there is nothing volatile to report.
    func dshVolatileTurnContext(toolNames: [String]) -> String? {
        Self.volatileTurnContextSuffix(
            runtimeFacts: DSHMinisPrompt.runtimeContextText(
                model: selectedModel.id,
                cwd: nil,
                sandboxRoot: Self.dshSandboxRoot,
                sessionId: sessionId,
                memoryEnabled: memoryEnabled,
                toolNames: toolNames
            ),
            memoryEnabled: memoryEnabled
        )
    }
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
