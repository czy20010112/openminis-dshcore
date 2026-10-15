//
//  DSHTurnDriverRun.swift
//  Minis
//
//  Runs one turn through the DSH driver, and the flush helpers its delegate
//  callbacks use.
//
//  The five core segments of runAgentLoop() are replaced here:
//
//  1. Request derivation  — the driver rebuilds it from the session surface
//     each step, so a mid-turn compaction needs no index bookkeeping.
//  2. Stream consumption  — the driver folds provider events; the ViewModel
//     renders them through the path it already has.
//  3. Tool dispatch       — the DSH scheduler with declared concurrency.
//  4. Result commit       — model order by construction.
//  5. Compaction          — DSH selection rule, applied before the request.
//
//  Everything outside those five — queued prompts, cancel cleanup, group
//  fallback, persistence, image budgeting, TTS, UI — stays in the ViewModel.
//

import Foundation

// MARK: - Turn Entry Point

extension AIChatViewModel {

    /// Run one turn through the DSH driver.
    ///
    /// Callers replace the body of `runAgentLoop()` with this. The ViewModel
    /// keeps its own state; the driver keeps the conversation.
    func runDSHTurn() async {
        guard let entry = resolveCurrentEntry() else {
            reportTurnFailure("No model configured. Add a provider in Settings.")
            return
        }

        let provider = await makeAgentProvider(for: entry)

        // Seed the session once per session id. A later turn reuses it, so the
        // surface accumulates across turns instead of restarting from scratch.
        if dshSession == nil {
            let session = DSHSession()
            for message in agentHistory {
                session.append(DSHSessionProjection.toDSHMessage(message), turn: nil)
            }
            dshSession = session
        }
        guard let session = dshSession else { return }

        // Build the tool registry from the same schema source the loop uses, so
        // the model sees one set of definitions.
        let registry = DSHToolRegistry()
        for tool in dshAgentRegistry() {
            _ = registry.register(tool)
        }

        let prompt = DSHSystemPrompt()
        var disposers: [() -> Void] = []
        disposers.append(contentsOf: DSHMinisPrompt.registerBase(into: prompt))
        disposers.append(prompt.section(DSHMinisPrompt.runtimeContextSection(
            sandboxRoot: Self.dshSandboxRoot,
            sessionId: sessionId,
            memoryEnabled: memoryEnabled
        )))
        defer { for d in disposers { d() } }

        // A fresh assistant row for this turn, and its seq once the driver
        // commits it.
        let assistantMsg = ChatMessage(role: .assistant, content: "", blocks: [])
        messages.append(assistantMsg)
        dshStreamingMsgIdx = messages.count - 1
        scrollToBottomSignal.send()

        let config = DSHTurnDriverConfig(
            maxParallelToolCalls: 4,
            maxStepsPerTurn: Self.maxAgentTurns,
            maxTokens: provider.defaultMaxTokens,
            enableLoopGuard: true,
            compactionRetainTokens: Self.dshCompactionRetainTokens,
            // Pressure is judged against the serving model's real window. A
            // fixed 120k threshold fires on every step of a small-context model
            // and compacts away the user's own request, so the model answers
            // from nothing. Derive it from the window and skip compaction
            // entirely when the window is unknown.
            //
            // An explicit override exists so the behaviour can be exercised on a
            // device without filling a 262k window: set `minis.dshCompactOverride`
            // to a token count and compaction fires there instead. Leave it unset
            // in normal use.
            compactionPressureTokens: Self.dshCompactionPressureTokens(for: entry.model),
            autoCompactionEnabled: true
        )

        let driver = DSHTurnDriver(
            provider: provider,
            registry: registry,
            prompt: prompt,
            session: session,
            config: config
        )
        driver.delegate = self

        // The user's message is already in agentHistory; mirror it into the
        // session so the surface the driver builds includes it.
        syncAgentHistoryIntoSession(session)

        _ = await driver.run()

        // Reconcile the UI array against the session surface, so agentHistory
        // reflects any compaction the driver applied.
        dshReconcileFromSession(session)

        dshStreamingMsgIdx = -1
        dshPendingToolResults.removeAll()
    }

    /// Compaction budgets. Deployment-varying values, so they are fields rather
    /// than constants in the driver.
    static var dshCompactionRetainTokens: Int {
        if let override = UserDefaults.standard.object(forKey: "minis.dshCompactRetainOverride") as? Int,
           override > 0 {
            return override
        }
        return 20_000
    }

    /// Pressure threshold for one model's context window.
    ///
    /// DSH compacts at roughly 80% of the window. An unknown window returns
    /// `Int.max`, which disables automatic compaction rather than compacting on
    /// a guess — compacting away the live request is worse than running long.
    ///
    /// `UserDefaults["minis.dshCompactOverride"]` replaces the derived value when
    /// set, so the behaviour can be exercised on a device without filling the
    /// model's whole window. Intended for testing only.
    static func dshCompactionPressureTokens(for model: LLMModel) -> Int {
        if let override = UserDefaults.standard.object(forKey: "minis.dshCompactOverride") as? Int,
           override > 0 {
            return override
        }
        guard let window = model.contextWindow, window > 0 else { return Int.max }
        return (window * 80) / 100
    }

    // MARK: - Session Sync

    /// Append any agentHistory entries the session does not yet have.
    ///
    /// Matching is by seq where available and by content otherwise, so a
    /// re-seeded session does not duplicate entries the UI already committed.
    private func syncAgentHistoryIntoSession(_ session: DSHSession) {
        let surfaceSeqs = Set(session.surface().map { $0.seq.value })
        for message in agentHistory {
            if let seq = message.dshSeq, surfaceSeqs.contains(seq) { continue }
            session.append(DSHSessionProjection.toDSHMessage(message), turn: nil)
        }
    }

    /// Rebuild agentHistory from the session surface, preserving UI-only rows.
    ///
    /// UI rows — dividers, status rows, queued placeholders — are not session
    /// entries and must survive. Everything else is re-projected from the
    /// surface, so a compaction's shadow is reflected without touching the
    /// streaming target, which is found by seq.
    private func dshReconcileFromSession(_ session: DSHSession) {
        let surface = session.surface()
        var rebuilt: [AgentMessage] = []

        // Keep leading UI-only rows (dividers, info) that precede the first
        // session-backed message.
        var surfaceIndex = 0
        for message in agentHistory {
            if let seq = message.dshSeq {
                // Consume surface entries up to and including this seq.
                while surfaceIndex < surface.count, surface[surfaceIndex].seq.value != seq {
                    surfaceIndex += 1
                }
                if surfaceIndex < surface.count {
                    rebuilt.append(DSHSessionProjection.toAgentMessage(surface[surfaceIndex]))
                    surfaceIndex += 1
                }
                continue
            }
            // UI-only row: preserve in place.
            rebuilt.append(message)
        }

        // Append any surface entries the UI has not projected yet (a compaction
        // summary, or entries committed after the last UI row).
        while surfaceIndex < surface.count {
            rebuilt.append(DSHSessionProjection.toAgentMessage(surface[surfaceIndex]))
            surfaceIndex += 1
        }

        agentHistory = rebuilt
    }

    // MARK: - Text Flush

    /// Flush buffered text onto the streaming block, throttled.
    ///
    /// The tiered throttle is the existing one: markdown re-parsing on every
    /// delta is O(n²) on dense streams and tripped the main-thread watchdog.
    /// Dense streams (≥5000 chars) drop the newline fast path because box-drawing
    /// output emits one every couple of characters.
    func dshMaybeFlushText(force: Bool = false) {
        guard !dshPendingText.isEmpty else { return }
        let len = dshPendingText.count
        let throttle: TimeInterval = len < 500 ? 0.20
                                    : len < 2000 ? 0.30
                                    : len < 32_000 ? 0.50
                                    : len < 64_000 ? 1.00
                                    : len < 128_000 ? 1.50
                                    : 2.00
        let elapsed = Date().timeIntervalSince(dshLastTextFlush)
        let newlineFlush = len < 5000 && dshPendingText.contains("\n")
        guard force || elapsed >= throttle || newlineFlush else { return }

        dshLastTextFlush = Date()
        let snapshot = dshPendingText
        dshPendingText = ""
        dshFlushPendingText(snapshot)
    }

    /// Commit buffered text onto the streaming assistant block.
    func dshFlushPendingText(_ snapshot: String? = nil) {
        let text = snapshot ?? dshPendingText
        guard !text.isEmpty else { return }
        dshPendingText = ""
        guard dshStreamingMsgIdx >= 0, dshStreamingMsgIdx < messages.count else { return }
        let idx = dshStreamingMsgIdx
        guard messages[idx].role == .assistant else { return }

        // Resolve the trailing text block rather than assuming the last index:
        // a tool block may have been appended after it.
        guard let blockIdx = messages[idx].blocks.indices.last(where: { messages[idx].blocks[$0].kind == .text }) else {
            return
        }

        let prepared = prepareMarkdownForRender(text)
        let parsed = MarkdownContent(prepared)
        setStreamingTextBlockContent(
            msgIdx: idx,
            blockIdx: blockIdx,
            text: text,
            parsedMarkdown: parsed,
            cacheAttributedString: false,
            requestScroll: true
        )
    }
}
