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

    /// Seed the session from what the model is supposed to see, and make
    /// `agentHistory` agree with it.
    ///
    /// Two things have to happen together, and the earlier version did neither:
    ///
    /// 1. **Each seeded row is stamped with the seq it landed on.** Without that
    ///    the sync that follows sees every row as "not in the session" and
    ///    appends all of them again — the whole conversation arrives twice, on
    ///    the first turn after every launch. The probe row showed it plainly: 33
    ///    loaded rows and a 66-entry surface.
    /// 2. **`agentHistory` becomes exactly what was seeded.** The seed is taken
    ///    from `effectiveAgentHistory()`, which applies the compaction marker, so
    ///    the rows it left out are the compacted prefix. Leaving them in
    ///    `agentHistory` invites the same sync to append them back and undo the
    ///    compaction. Assigning also preserves `dbMessageId`, which is what the
    ///    next compaction's anchor is resolved from.
    ///
    /// `effectiveAgentHistory()` rather than `agentHistory` for the content,
    /// because it is the one that applies a persisted marker — seeding from the
    /// raw history is why a compaction used to die with the process.
    private func dshSeedSession() {
        let session = DSHSession()
        var seeded: [AgentMessage] = []
        for message in effectiveAgentHistory() {
            let seq = session.append(DSHSessionProjection.toDSHMessage(message), turn: nil)
            var stamped = message
            stamped.dshSeq = seq.value
            seeded.append(stamped)
        }
        dshSession = session
        agentHistory = seeded
    }

    /// Re-drive the current turn through the DSH core, for a retry or a resume.
    ///
    /// The session *is* the conversation, so a redrive first removes what the
    /// previous attempt appended: the assistant entry it was streaming, and any
    /// tool calls or results that followed it. Without that the retry answers a
    /// question that already has an answer, and the transcript shows both.
    ///
    /// - Parameter afterSeq: keep everything up to and including this session
    ///   entry, then drop the rest plus any trailing non-user entries. `nil`
    ///   keeps the newest user turn and drops everything after it — which is what
    ///   a plain "retry" or "resume" means.
    func runDSHRedrive(afterSeq: Int?) async {
        if let session = dshSession {
            var cut = session.lastUserSeq()
            if let afterSeq, afterSeq > 0 {
                // A row the session knows about is a stronger bound than "the last
                // user turn", for a retry aimed at an older message. `DSHSeq`'s
                // initialiser traps on non-positive input, hence the guard.
                let requested = DSHSeq(afterSeq)
                if session.entry(at: requested) != nil { cut = requested }
            }
            let dropped = session.truncate(after: cut)
            dshDropUITail(keepingThrough: cut)
            AppLogger(category: "DSHLoop").warning(
                "[DSH] redrive dropped \(dropped) entr\(dropped == 1 ? "y" : "ies") "
                + "after \(cut?.description ?? "nil")"
            )
        }
        await runDSHTurn()
    }

    /// Remove the transcript rows the session truncation removed.
    ///
    /// `messages` mirrors the session for display. A row whose seq is gone has
    /// nothing behind it any more, so leaving it would show a retried turn twice.
    /// A row with no seq was never in the session: only a *trailing* assistant
    /// row can be the failed attempt's own placeholder or an error carrier.
    private func dshDropUITail(keepingThrough cut: DSHSeq?) {
        let cutoff = cut?.value ?? 0
        let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) ?? -1
        var doomed: [Int] = []
        for (idx, message) in messages.enumerated() {
            if let seq = message.dshSeq {
                if seq > cutoff { doomed.append(idx) }
            } else if message.role == .assistant, idx > lastUserIdx {
                doomed.append(idx)
            }
        }
        guard !doomed.isEmpty else { return }
        for idx in doomed.reversed() { messages.remove(at: idx) }
    }

    /// Resolve a DSH compaction into a marker that still has to be written.
    ///
    /// Called from the driver's `didCompact`, which is synchronous and runs while
    /// the shadowed rows are still in `agentHistory`. The write itself is async
    /// (the store is an actor) and happens at the end of the turn.
    func dshResolveCompactionMarker(_ outcome: DSHCompactionOutcome) {
        guard let summaryEntry = dshSession?.entry(at: outcome.summarySeq) else { return }
        guard let lastShadowed = outcome.range.shadowedSeqs.last,
              let anchorId = agentHistory.last(where: { $0.dshSeq == lastShadowed.value })?.dbMessageId else {
            AppLogger(category: "DSHLoop").warning(
                "[DSH] compaction has no persisted anchor row — the conversation "
                + "will come back whole on the next launch"
            )
            return
        }
        dshPendingMarker = (
            anchorId: anchorId,
            summary: summaryEntry.message.text,
            count: outcome.range.shadowedSeqs.count
        )
    }

    /// Write a resolved compaction marker, replacing any earlier one.
    ///
    /// Minis already has the right shape for this: a `CompactMarker` says
    /// "everything up to and including `lastCompactedMessageId` is compacted,
    /// and here is its summary", and `effectiveAgentHistory()` re-materializes
    /// that summary into the next request. Writing one is what lets a DSH
    /// compaction outlive the process.
    ///
    /// DSH summaries are cumulative by construction — the previous summary sits
    /// inside the range the next one shadows and is rendered into the summarizer's
    /// input — which is exactly the "covers everything up to the anchor"
    /// semantics a v2 marker assumes. Hence one marker at a time, replacing any
    /// earlier one rather than accumulating.
    func dshWriteCompactionMarker(_ pending: (anchorId: String, summary: String, count: Int)) async {
        guard let sid = sessionId else { return }

        await ChatStore.shared.deleteCompactMarkers(sessionId: sid)
        await ChatStore.shared.insertCompactMarker(CompactMarker(
            id: UUID().uuidString,
            sessionId: sid,
            summary: pending.summary,
            firstKeptSortOrder: 0,
            compactedCount: pending.count,
            createdAt: Date(),
            uiBoundarySortOrder: nil,
            boundaryMessageId: nil,
            firstKeptMessageId: nil,
            lastCompactedMessageId: pending.anchorId,
            version: 2
        ))
        cachedLatestMarker = await ChatStore.shared.latestCompactMarker(sessionId: sid)
        AppLogger(category: "DSHLoop").warning(
            "[DSH] compaction marker written anchor=\(pending.anchorId.prefix(8)) "
            + "shadowed=\(pending.count)"
        )
    }

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

        // Seed the session once per conversation, and rebuild it when the
        // conversation changes. The previous version created it once per
        // ViewModel and then reused it for whatever session happened to be open,
        // so switching chats inherited the other chat's history.
        if dshSession == nil || dshSessionOwner != sessionId {
            dshSeedSession()
            dshSessionOwner = sessionId
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
        // One presenter for the whole turn: the block index and the text
        // accumulated for it live in the same object, so a tool call cannot pull
        // them apart. See `StreamTextPresenter`.
        dshTextPresenter = StreamTextPresenter(vm: self)
        dshTurnToolEntries.removeAll()
        dshLastUsageAt = Date()
        dshTurnTextTotal = 0
        dshPendingReasoning = ""

        // The one-hour prompt-cache patch.
        //
        // The legacy loop sets this at the top of every run, so on a DSH-only
        // session the flag stayed false and the user's "enhanced cache" setting
        // silently did nothing. It is a global switch on the HTTP client, so it
        // has to be set before the first request of the turn.
        RequestBodyPatcher.setExtendedCacheTTL(enhancedCacheEnabled)

        let registry = DSHToolRegistry()
        for tool in dshAgentRegistry(definitions: definitions, batchBudget: batchBudget) {
            _ = registry.register(tool)
        }

        let prompt = DSHSystemPrompt()
        var disposers: [() -> Void] = []
        disposers.append(contentsOf: DSHMinisPrompt.registerBase(into: prompt))

        // [T-tools-todo-plan] Plan mode's policy section. Registered for every
        // turn and empty while the mode is off, so entering or leaving the mode
        // does not change which sections a request carries — DSH holds its tool
        // catalog constant across modes for the same reason.
        disposers.append(prompt.section(DSHPlanMode.policySection()))

        // [T-tools-goal] The goal-tool policy. Registered unconditionally, like
        // the plan section above and for the same reason: DSH holds its sections
        // and its tool catalog constant across states so that a request is not
        // reshaped by a state change, and so the prompt cache keeps hitting.
        disposers.append(prompt.section(DSHGoalTools.policySection()))

        // The app's own system prompt, verbatim.
        //
        // The port started by re-authoring this as a short DSH-flavoured base and
        // dropping the rest — roughly 180 lines of Minis-specific guidance the
        // model had always been given: the tool-usage rules, the memory and skill
        // rules, the permission notes, and the Settings deep-link list.
        //
        // The operator found the hole by asking the assistant how to change its
        // own provider: it had no idea. That answer is one paragraph of exactly
        // this text (`minis://settings/providers`, `model-groups`, `usage`, …).
        //
        // Registered as-is rather than paraphrased: it is the app describing its
        // own features, in its own words, and the harness sections above and below
        // add framing around it rather than replacing it.
        let appPrompt = baseSystemPrompt
        if !appPrompt.isEmpty {
            disposers.append(prompt.section(DSHPromptSection(
                name: "minis:app-system-prompt",
                order: DSHSectionOrder.personaPrefix.rawValue,
                text: appPrompt
            )))
        }
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
            // Resolved the way every legacy request resolves it: the user's
            // per-model override wins, then the provider default, then the global
            // ceiling — and the result is clamped to the window that is actually
            // left, so a near-full context cannot ask for more output than fits.
            //
            // Passing `provider.defaultMaxTokens` straight through ignored the
            // override entirely and dropped the clamp.
            maxTokens: dynamicMaxTokens(
                provider: provider,
                model: entry.model,
                lastContextTokens: dshTurnUsage.inputTokens
                    + (dshTurnUsage.cacheReadTokens ?? 0)
                    + (dshTurnUsage.cacheWriteTokens ?? 0)
            ),
            // Resolved per conversation and clamped to the serving model — the
            // same resolution the original loop uses. Hardcoding `.off` in the
            // driver turned thinking off for every DSH turn, silently.
            thinkingLevel: dshThinkingLevel(for: entry),
            enableLoopGuard: true,
            compactionPolicy: DSHCompactionPolicy(),
            // Capacity is resolved the way every other capacity decision in this
            // app resolves it — the bound group's limit when it has one, then the
            // model's own declared window — rather than from `model.contextWindow`
            // alone, which is nil for a model the catalog has no entry for and
            // for one whose limit the user only ever set on the group.
            //
            // A window of 0 is "unknown" and is passed as nil: DSH cannot derive
            // a threshold without declared capacity either, and compacting on a
            // guess is worse than running long — compacting away the user's live
            // request makes the model answer from nothing.
            contextWindow: effectiveContextWindow(for: entry.model),
            // Absolute overrides so the trigger can be exercised on a device
            // without filling a 262k window. `minis.dshCompactOverride` moves the
            // threshold, `minis.dshCompactRetainOverride` the retained tail;
            // unset, both derive from the window and the policy above, which is
            // the shipped configuration.
            compactionPressureTokensOverride: Self.dshCompactionPressureOverride,
            compactionRetainTokensOverride: Self.dshCompactionRetainOverride,
            autoCompactionEnabled: true,
            // The same backoff the legacy loop waits out on a retryable stream
            // failure, so the two paths recover from a network blip alike.
            streamRetryDelays: Self.retryDelays
        )

        let driver = DSHTurnDriver(
            provider: provider,
            registry: registry,
            prompt: prompt,
            session: session,
            config: config
        )
        driver.delegate = self
        // [T-dsh-spill] Overflow handling for oversized tool results, installed
        // where the session is known. It is nil while the feature is
        // unconfigured, and nil takes no branch in the tool path.
        dshInstallSpillHook(on: driver)

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
            + "window=\(effectiveContextWindow(for: entry.model)) "
            + "ratio=\(config.compactionPolicy.thresholdRatio) "
            + "headroom=\(config.compactionPolicy.headroomTokens) "
            + "retainRatio=\(config.compactionPolicy.retainRatio) "
            + "pressureOverride=\(Self.dshCompactionPressureOverride.map(String.init) ?? "nil") "
            + "retainOverride=\(Self.dshCompactionRetainOverride.map(String.init) ?? "nil")"
        )
        if Self.dshCompactionProbeEnabled {
            let info = ChatMessage(role: .systemInfo, content: "")
            info.systemIcon = "info.circle"
            // Whether a persisted compaction was actually applied to the seed is
            // otherwise invisible: the store-side marker can be perfect and
            // `effectiveAgentHistory()` can still degrade to the whole history,
            // and the only symptom is that the driver compacts the same
            // conversation again on every launch. So report the anchor lookup
            // itself rather than its result.
            let seed: String
            if let marker = cachedLatestMarker {
                let anchor = marker.lastCompactedMessageId
                let anchorResolves = anchor.map { id in
                    agentHistory.contains { $0.dbMessageId == id }
                } ?? false
                seed = "sess=\(sessionId?.prefix(8) ?? "nil") marker v\(marker.version) "
                    + "anchor=\(anchor?.prefix(8) ?? "nil") anchorResolves=\(anchorResolves) "
                    + "history=\(agentHistory.count)(withDbId=\(agentHistory.filter { $0.dbMessageId != nil }.count)) "
                    + "effective=\(effectiveAgentHistory().count)"
            } else {
                seed = "sess=\(sessionId?.prefix(8) ?? "nil") marker=none history=\(agentHistory.count) "
                    + "effective=\(effectiveAgentHistory().count)"
            }
            // The threshold shown is the one the driver will actually apply, read
            // back from the resolved trace instead of restated from the policy:
            // a readout that recomputes the number it is describing can disagree
            // with the number in force, and then the probe is measuring itself.
            let spec = driver.resolvedCompactionSpec(
                reservedCompletionTokens: config.maxTokens
            )
            let threshold = spec.map { "\($0.thresholdTokens)" } ?? "none (no declared window)"
            let retain = spec.map { "\($0.retainTokens)" } ?? "-"
            info.content = "DSH surface: \(surfaceBefore.count) entries, ~\(tokensBefore) tokens "
                + "(compact at \(threshold), retain \(retain)) | seed: \(seed)"
            messages.append(info)
        }

        let logCountBeforeTurn = session.logCount
        _ = await driver.run()

        // Write any compaction marker now, while `agentHistory` still holds the
        // shadowed rows — the anchor is one of their database ids, and the
        // reconcile below replaces that array with the session surface.
        if let pending = dshPendingMarker {
            await dshWriteCompactionMarker(pending)
            dshPendingMarker = nil
        }

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

        // Session title.
        //
        // The legacy loop calls this right after each stream completes, with the
        // turn's tool calls; the DSH turn did not, so every conversation kept the
        // "New Chat" placeholder forever — visible on the session list, where all
        // of them read the same. It self-limits (three attempts, skips while one
        // is in flight), so calling it per turn is what it was written for.
        generateSessionTitleIfNeeded(toolEntries: dshTurnToolEntries)
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

    /// Extended-thinking level for this conversation, clamped to the model.
    ///
    /// The session's persisted level may exceed what the resolved model accepts,
    /// so the clamp happens before the request is built — the protocol-extension
    /// clamp only knows the catalog maximum, not the entry-level override.
    private func dshThinkingLevel(for entry: ModelEntry) -> ThinkingLevel {
        var level = sessionId.flatMap {
            ProviderConfigStore.shared.inferenceConfig(for: $0)?.thinkingLevel
        } ?? .off
        level = min(level, entry.effectiveMaxThinkingLevel)
        return level
    }

    /// Map the driver's usage accounting onto the row type the store reads.
    ///
    /// Internal rather than private: the turn-sealing code that stamps a row's
    /// usage lives in the adapter, and both need the same mapping.
    func minisTokenUsage(_ usage: DSHTokenUsage) -> TokenUsage {
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
        // The driver's type keeps the cache buckets optional, and that is exactly
        // the distinction the panel needs: present means the provider accounted for
        // the cache (a 0% hit rate is then a fact), absent means it said nothing
        // about it (and the panel shows no rate at all). See `TokenUsage.cacheReported`.
        out.cacheReported = usage.cacheReadTokens != nil || usage.cacheWriteTokens != nil
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
    ///
    /// A compilation condition rather than a runtime flag, because runtime flags
    /// do not survive this app: it registers its own defaults dictionary at
    /// launch and rewrites the whole plist, so a key written from outside is
    /// discarded. The workflow exposes it as a `compaction_probe` input, which is
    /// how a compaction can be exercised without filling a 262k window — and
    /// because it is off by default, a released build cannot carry it.
    static var dshCompactionProbeEnabled: Bool {
        #if DSH_COMPACTION_PROBE
        return true
        #else
        return false
        #endif
    }

    /// Absolute retained-tail budget, replacing the policy's derived one.
    ///
    /// nil — the shipped value — lets `DSHCompactionPolicy.retainRatio` derive it
    /// as 16% of the message budget, which is what DSH does. The key exists so a
    /// device experiment can hold the tail fixed while the threshold moves.
    static var dshCompactionRetainOverride: Int? {
        if dshCompactionProbeEnabled { return 400 }
        if let override = UserDefaults.standard.object(forKey: "minis.dshCompactRetainOverride") as? Int,
           override > 0 {
            return override
        }
        return nil
    }

    /// Absolute pressure threshold, replacing the policy's derived one.
    ///
    /// nil — the shipped value — derives the threshold from the serving model's
    /// window as `min(W × 0.8, W − O − 65536)`, which is DSH's own rule. The same
    /// 80%-of-window figure stated without the output reservation and headroom is
    /// not the same trigger: on a 128k model it fires ~70k tokens later, by which
    /// point the request has already been rejected — the reason a long turn could
    /// blow the window with no compaction having run.
    static var dshCompactionPressureOverride: Int? {
        if dshCompactionProbeEnabled { return 2_000 }
        if let override = UserDefaults.standard.object(forKey: "minis.dshCompactOverride") as? Int,
           override > 0 {
            return override
        }
        return nil
    }

    // MARK: - Session Sync

    /// Append any agentHistory entries the session does not yet have.
    ///
    /// Matching is by seq where available and by content otherwise, so a
    /// re-seeded session does not duplicate entries the UI already committed.
    /// Rebuild agentHistory from the session surface, keeping database ids.
    ///
    /// The session is the single source of truth for *content*, so the surface is
    /// projected wholesale. What the session does not carry is the database id of
    /// each row, and two things downstream need it:
    ///
    ///   * the compaction anchor is a database id, so a marker cannot be written
    ///     without one;
    ///   * `effectiveAgentHistory()` resolves a persisted marker's anchor by
    ///     looking it up in `agentHistory`.
    ///
    /// So ids are carried across the rebuild by seq. Only rows that already had
    /// one keep it; a row appended this turn picks its id up when it is persisted.
    ///
    /// The earlier version walked `agentHistory` and aligned by seq instead of
    /// projecting the surface, which silently kept every row that had no seq —
    /// most of them, because the original loop's append paths never stamp one.
    /// Those stale rows were then re-appended on the next turn, so the
    /// conversation the driver saw was a fraction of the conversation the UI
    /// showed: a 4.8k-char message measured as 313 surface tokens, and compaction
    /// never fired.
    private func dshReconcileFromSession(_ session: DSHSession) {
        var knownDbIds: [Int: String] = [:]
        for message in agentHistory {
            guard let seq = message.dshSeq, let id = message.dbMessageId else { continue }
            knownDbIds[seq] = id
        }
        agentHistory = session.surface().map { entry in
            var message = DSHSessionProjection.toAgentMessage(entry)
            if let id = knownDbIds[entry.seq.value] { message.dbMessageId = id }
            return message
        }
    }

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

    // MARK: - Text Commit

    /// Commit the presenter's streamed text through the app's own streaming flush.
    ///
    /// [T-ios-streamtext-one-owner] This replaced the DSH loop's private copy of
    /// "throttled flush onto the streaming block": its own tiered throttle (which
    /// had lost the legacy newline gate's `unflushed >= 50` clause, so a
    /// box-drawing stream committed on every two-character line), its own markdown
    /// parse, and its own clearing of the pending buffer *before* it had proved the
    /// target block still existed — on the miss the text was dropped, not kept.
    ///
    /// - Parameter force: skip the throttle. A brand-new block commits at once, so
    ///   the row the empty → filled signal names is already in the data-source
    ///   snapshot the signal is handled against.
    /// - Parameter finalFlush: the turn's last commit. It must be marked as such:
    ///   the flush defers while the list suspends live updates, and only the final
    ///   flush's deferred record carries `cacheAttributedString`, which is what
    ///   gets applied when the suspension clears.
    func dshCommitText(force: Bool = false, finalFlush: Bool = false) {
        // Committing supersedes any scheduled tail: a late timer would re-commit
        // text that is already on the block.
        dshCancelTrailingTextFlush()
        guard let presenter = dshTextPresenter else { return }
        presenter.msgIdx = dshStreamingMsgIdx
        guard let plan = presenter.takeFlushPayload(force: force) else { return }
        if !commitStreamText(presenter, plan: plan, finalFlush: finalFlush) {
            presenter.requeue(plan.text)
        }
    }

    // MARK: - Trailing text flush

    /// How long the stream may stay quiet before the text tail is committed
    /// anyway.
    ///
    /// Short enough that a paragraph ending before a batch of tool calls lands on
    /// its own, long enough not to add a commit per delta: the throttle's own
    /// first tier is 0.20s.
    static let dshTrailingFlushDelay: TimeInterval = 0.25

    /// Commit the text tail once the stream goes quiet.
    ///
    /// [T-ios-stream-tail-flush] The throttle is consulted only when a delta
    /// arrives, so text that lands and then waits stays in the buffer until the
    /// next delta, the tool boundary, or the end of the turn — and there is no
    /// timer anywhere in that chain. The operator's report is exactly this shape:
    /// a paragraph ends, the model streams a batch of tool calls (their input
    /// deltas can run for seconds, and the driver announces nothing until the
    /// stream ends), and the tail therefore lands in the same frame as every tool
    /// block — "it prints a few characters, then the rest arrives together with all
    /// the other tool calls".
    ///
    /// A one-shot timer closes the gap: if nothing commits within the window, the
    /// tail is committed on its own. Generation-counted rather than merely
    /// cancelled, so a timer that already woke up cannot commit into a block the
    /// presenter has since left.
    func dshScheduleTrailingTextFlush() {
        dshTrailingFlushGeneration &+= 1
        let generation = dshTrailingFlushGeneration
        dshTrailingFlushTask?.cancel()
        dshTrailingFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.dshTrailingFlushDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.dshTrailingFlushGeneration == generation else { return }
            self.dshCommitText()
        }
    }

    /// Cancel a scheduled tail flush. Called wherever the caller is about to
    /// commit, switch blocks, or end the turn.
    func dshCancelTrailingTextFlush() {
        dshTrailingFlushGeneration &+= 1
        dshTrailingFlushTask?.cancel()
        dshTrailingFlushTask = nil
    }

    /// Commit everything streamed so far, ignoring the throttle AND the
    /// suspend gate — the legacy loop's "Step 1" flush at a tool boundary.
    ///
    /// It is the FINAL flush for the block being left behind, and deferring it is
    /// how "swallowed text" happened when the user was scrolling while the reply
    /// streamed. `bypassSuspend` skips only the scroll/background gate, never the
    /// hosting-transition gate (`transitionSuspended`), which exists to keep
    /// publishes out of a subgraph teardown.
    func dshCommitTextForToolBoundary() {
        dshCancelTrailingTextFlush()
        guard let presenter = dshTextPresenter else { return }
        presenter.msgIdx = dshStreamingMsgIdx
        guard let plan = presenter.forcePayload() else { return }
        if !commitStreamText(presenter, plan: plan, finalFlush: true, bypassSuspend: true) {
            presenter.requeue(plan.text)
        }
    }
}
