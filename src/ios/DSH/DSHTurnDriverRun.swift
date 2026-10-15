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

        // The tool roster is Minis' — `makeAgentTools()` is the only place that
        // knows the gating. The DSH registry adds the declared concurrency, and
        // one image budget per turn, matching the original loop's per-turn
        // allocation so concurrent image reads cannot collectively exceed the
        // context image cap.
        let definitions = dshAgentTools()
        let batchBudget = BatchImageBudget(initial: Self.kImageContextKeepCount)
        dshToolBlockIndex.removeAll()
        dshPendingSnapshots.removeAll()
        dshThinkingBlockIdx = -1
        dshPendingReasoning = ""

        let registry = DSHToolRegistry()
        for tool in dshAgentRegistry(definitions: definitions, batchBudget: batchBudget) {
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
        // The fragments the legacy assembly appended at its own call site: the
        // model's capability and behaviour notes, the skill index, the MCP server
        // list, and the authoritative memory state. Without them a DSH turn
        // silently lost every one of those inputs.
        disposers.append(contentsOf: dshRegisterContextSections(into: prompt))
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

        // Append the pending user turn to the session rather than syncing it from
        // agentHistory. The row `send()` appended carries no seq, so a sync would
        // skip it and the driver would run a turn over a conversation that does
        // not contain the user's own request.
        //
        // A row appended here is the newest surface entry, so it is the last
        // assistant turn's context and the compaction target's recent tail.
        if let lastIndex = agentHistory.indices.last,
           agentHistory[lastIndex].role == .user,
           agentHistory[lastIndex].dshSeq == nil {
            let row = agentHistory[lastIndex]
            let seq = session.append(DSHSessionProjection.toDSHMessage(row), turn: nil)
            agentHistory[lastIndex].dshSeq = seq.value
        }

        // Surface state before the turn runs, so a compaction that fires can be
        // judged against the surface it actually saw rather than a guess.
        //
        // The transcript row is written only under the probe: a per-turn context
        // readout is useful while verifying and noise in normal use, and the
        // app's own logs are not reachable from the device, so without the row a
        // silent no-compaction is indistinguishable from a broken threshold.
        let surfaceBefore = session.surface()
        let tokensBefore = DSHTokenEstimate.total(surfaceBefore)
        AppLogger(category: "DSHLoop").warning(
            "[DSH] turn start surface=\(surfaceBefore.count) entries tokens=\(tokensBefore) "
            + "pressure=\(config.compactionPressureTokens) retain=\(config.compactionRetainTokens)"
        )
        if Self.dshCompactionProbeEnabled {
            let info = ChatMessage(role: .systemInfo, content: "")
            info.systemIcon = "info.circle"
            info.content = "DSH surface: \(surfaceBefore.count) entries, ~\(tokensBefore) tokens (compact at \(config.compactionPressureTokens))"
            messages.append(info)
        }

        let logCountBeforeTurn = session.logCount
        _ = await driver.run()

        // Persist what this turn added, then rebuild the UI array from the
        // surface. The driver owns conversation identity but not storage:
        // nothing under src/ios/DSH/ writes to ChatStore, so without this the
        // turn renders on screen and is gone at the next launch — the transcript
        // is rebuilt from the database.
        let persisted = await dshPersistSurface(
            session,
            fromIndex: logCountBeforeTurn,
            modelEntryId: entry.id
        )

        // Reconcile the UI array against the session surface, so agentHistory
        // reflects any compaction the driver applied.
        dshReconcileFromSession(session)

        // Record the database ids the reconcile just made addressable. The row a
        // later edit or delete targets is found by these.
        for i in agentHistory.indices {
            guard let seq = agentHistory[i].dshSeq, let dbId = persisted[seq] else { continue }
            agentHistory[i].dbMessageId = dbId
        }

        dshStreamingMsgIdx = -1
        dshPendingToolResults.removeAll()
        dshToolBlockIndex.removeAll()
        dshPendingSnapshots.removeAll()
    }

    /// Persist the session entries this turn appended.
    ///
    /// Only entries from `fromIndex` on are written: the head of the session is
    /// rows restored from the database, which already have rows of their own, and
    /// re-appending them would duplicate the conversation. The user's own message
    /// is excluded too — `send()` persisted it before the turn began.
    ///
    /// - Returns: seq → database id, for rows the caller still has to stamp.
    private func dshPersistSurface(
        _ session: DSHSession,
        fromIndex: Int,
        modelEntryId: String?
    ) async -> [Int: String] {
        let entries = session.allEntries()
        guard fromIndex >= 0, fromIndex < entries.count else { return [:] }

        let usage = minisTokenUsage(dshTurnUsage)
        var persisted: [Int: String] = [:]

        for entry in entries[fromIndex...] {
            // A system or developer entry is context, not a conversation row.
            switch entry.message.role {
            case .system, .developer:
                continue
            case .user, .assistant, .tool:
                break
            }

            // A compaction summary is NOT persisted.
            //
            // It exists to shadow a range of earlier entries, and that shadowing
            // lives only in the session. Writing the summary to the store would
            // put it in the transcript beside the messages it replaces — the next
            // launch seeds a fresh session from every row, so the model would see
            // both. Losing the compaction is the honest failure: the conversation
            // comes back whole, and the driver compacts again once the surface is
            // under pressure.
            if entry.shadows != nil { continue }

            let message = DSHSessionProjection.toAgentMessage(entry)
            // A reasoning-only or empty assistant turn has nothing to store, and
            // writing it would put a blank bubble in the transcript on reload.
            guard message.parts.contains(where: { part in
                if case .text(let text) = part { return !text.isEmpty }
                return true
            }) else { continue }

            if let dbId = await persistAgentMessage(
                message,
                tokenUsage: entry.message.role == .assistant ? usage : nil,
                snapshots: dshPendingSnapshots,
                modelEntryId: modelEntryId
            ) {
                persisted[entry.seq.value] = dbId
            } else {
                AppLogger(category: "DSHLoop").warning(
                    "[DSH] persist FAILED for seq=\(entry.seq.value) role=\(entry.message.role.rawValue)"
                )
            }
        }
        return persisted
    }

    /// Map the driver's usage accounting onto the row type the store reads.
    private func minisTokenUsage(_ usage: DSHTokenUsage) -> TokenUsage {
        var out = TokenUsage()
        out.inputTokens = usage.inputTokens
        out.outputTokens = usage.outputTokens
        out.cacheCreationTokens = usage.cacheWriteTokens ?? 0
        out.cacheReadTokens = usage.cacheReadTokens ?? 0
        // "Context size of the latest API call", which is the input plus
        // whatever was served from or written to cache.
        out.latestContextTokens = usage.inputTokens
            + out.cacheCreationTokens
            + out.cacheReadTokens
        return out
    }

    /// Compaction budgets. Deployment-varying values, so they are fields rather
    /// than constants in the driver.
    ///
    /// `dshCompactionProbeEnabled` lowers the thresholds enough that a real
    /// device session trips compaction without filling a 262k window. It exists
    /// so the behaviour can be exercised on-device; ship it false, because the
    /// probe values compact far more eagerly than the model needs.
    ///
    /// Verified on-device with the probe on: a 18-entry / 2026-token surface
    /// compacted to 9 entries / 1330 tokens (34% smaller) in one turn, with the
    /// tool call in that turn still completing and the model still answering
    /// correctly from the summary.
    static var dshCompactionProbeEnabled: Bool { false }

    static var dshCompactionRetainTokens: Int {
        if dshCompactionProbeEnabled { return 400 }
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
    static func dshCompactionPressureTokens(for model: LLMModel) -> Int {
        if dshCompactionProbeEnabled { return 2000 }
        guard let window = model.contextWindow, window > 0 else { return Int.max }
        return (window * 80) / 100
    }

    // MARK: - Session Sync

    /// Append any agentHistory entries the session does not yet have.
    ///
    /// Matching is by seq where available and by content otherwise, so a
    /// re-seeded session does not duplicate entries the UI already committed.
    /// Rebuild agentHistory from the session surface.
    ///
    /// The session is the single source of truth, so the surface is projected
    /// wholesale. The earlier version walked `agentHistory` and aligned by seq,
    /// which silently kept every row that had no seq — most of them, because the
    /// original loop's append paths never stamp one. Those stale rows then got
    /// re-appended to the session on the next turn, so the conversation the
    /// driver saw was a fraction of the conversation the UI showed: a 4.8k-char
    /// message measured as 313 surface tokens, and compaction never fired.
    ///
    /// Only genuinely UI-only rows survive — dividers and info rows, which are
    /// not conversation entries and are identified by role rather than by absence
    /// of a seq.
    private func dshReconcileFromSession(_ session: DSHSession) {
        agentHistory = session.surface().map { DSHSessionProjection.toAgentMessage($0) }
    }

    /// Append any agentHistory entries the session does not yet have.
    ///
    /// Only rows that carry a seq are considered; a row without one cannot be
    /// deduplicated and would be re-appended on every turn.
    /// Absorb every `agentHistory` row the session does not already hold, and
    /// stamp each absorbed row with the seq it landed on.
    ///
    /// Rows *without* a seq are absorbed too, and that is the point. The legacy
    /// loop is still reachable — `retry()`, `resume()` and the message-level
    /// reruns drive it — and nothing on that path stamps a seq. Skipping those
    /// rows meant the reconcile that follows, which rebuilds `agentHistory` from
    /// the surface, dropped them: the conversation on screen kept them, the
    /// conversation the model was given did not.
    ///
    /// Stamping the seq back onto the row is what makes this idempotent. Membership
    /// is tested against the whole log rather than the surface, because a
    /// compacted entry is still in the log even though the surface no longer
    /// shows it, and re-appending it would duplicate the conversation.
    private func syncAgentHistoryIntoSession(_ session: DSHSession) {
        var knownSeqs = Set(session.allEntries().map { $0.seq.value })
        for index in agentHistory.indices {
            if let seq = agentHistory[index].dshSeq, knownSeqs.contains(seq) { continue }
            let seq = session.append(DSHSessionProjection.toDSHMessage(agentHistory[index]), turn: nil)
            agentHistory[index].dshSeq = seq.value
            knownSeqs.insert(seq.value)
        }
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
