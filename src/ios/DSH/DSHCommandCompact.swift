//
//  DSHCommandCompact.swift
//  Minis
//
//  `/compact`: the human-facing on-demand compaction, ported from DeepSeek
//  Harness `packages/compaction/command-compact/src/index.ts` — command name
//  (`:103`), argument rejection (`:63-65`), the call into the compaction seam
//  (`:67`) and the exact wording of every outcome (`:14`, `:29-52`, `:68-72`).
//
//  WHY THIS FILE EXISTS AT ALL, given `/compact` already shipped. The row was
//  there (`AIChatViewModel+SlashCommands`, `availableSlashCommands`) and it called
//  `compactAll()`, which runs the app's own compaction: a `CompactMarker` row in
//  the store, the store's own summary prompt, the store's own anchor rules
//  (`compactKeepRecentUserTurns`, the write-back protocol, the segment-splitting
//  ladder). None of that is the engine's. `DSHCompactionPolicy` — the one object
//  that decides when the DSH turn driver compacts and how much recent tail it
//  keeps (`DSHTurnDriver.compactForPressure`, `recoverFromContextOverflow`) — was
//  never consulted, so a user pressing `/compact` and the engine compacting by
//  itself were two different products with two different retention policies
//  operating on the same conversation. The operator's requirement is the opposite:
//  one policy. So `/compact` now runs `DSHCompaction.compact`, the SAME entry point
//  the automatic paths call, with the SAME policy, from the SAME settings accessor.
//
//  What upstream's `compactNow` does, and what this port therefore does
//  (`packages/compaction/compaction-basic/src/index.ts:383-435`):
//
//   1. It is EXPLICITLY below the pressure threshold, and it keeps NO retained
//      tail. Upstream's manual call is `selectCompactableRange(agent.session,
//      this.ctx.tokenMeter.measure(agent.session), 0)` (`index.ts:394-398`), and
//      that third argument is `retainTokens` (`region.ts:117-121`) — not a
//      threshold: `selectCompactableRange` has no threshold parameter at all, and
//      this port's earlier note calling it a "0 threshold gate" was wrong. `0`
//      there spends nothing on the tail, so the backward walk (`region.ts:133-141`)
//      stops on the LAST surface node and the cut then moves further back only
//      until the tool-call/result pairing is balanced (`:143-147`).
//      The manual reduction is therefore the maximal balanced one — the same range
//      `compactIfNeeded('context-overflow')` selects (`index.ts:299`) — and NOT the
//      policy's 16% tail: that figure is spent by the AUTOMATIC PRESSURE path only,
//      as `spec.retainTokens` (`index.ts:331`, derived at `config.ts:195-197` from
//      `DEFAULT_RETAIN_RATIO` at `:23`).
//      What the manual command does NOT bypass is the selection RULES: same
//      `selectCompactableRange`, same system-head exclusion, same balanced cut,
//      same shrink requirement, and the same `DSHCompactionPolicy` object for
//      everything else. It bypasses *when*, never *what*.
//   2. It takes NO arguments (`:63-65`, `USAGE` at `:14`).
//   3. It refuses while the agent is busy rather than queueing (`:29-31`, the
//      `busy` arm), and while another compaction is open.
//   4. It reports what it did in tokens and history-item counts — never the
//      summary text itself (`:71`).
//   5. Between the "nothing to compact" answer and the "did it" answer there is
//      no third shape: no-op is `null` from the engine, not an error (`:68`).
//
//  DEVIATIONS, stated rather than hidden:
//
//   * Upstream's busiest message names its own composition
//     ("this process has an active compaction"); this app's says the same thing in
//     the app's own words. The substance — busy is reported, not queued — is
//     upstream's.
//   * `compactNow` requires an idle agent and holds a durable lock across the
//     summary call (`ManualCompactAgentContext.runMaintenance`). This port cannot:
//     the DSH session here is owned by the view model, and there is no maintenance
//     lane. It uses the same `isCompacting` re-entrancy guard the app's other
//     compaction paths use, which is the equivalent lock for this app.
//   * The summary text is produced by the same summarizer prompt the engine's own
//     compactions use, so a manual and an automatic compaction of the same span
//     produce the same kind of summary.
//
//  [T-command-compact-port]
//

import Foundation

private let logger = AppLogger(category: "DSHCompact")

extension AIChatViewModel {

    /// Upstream's `USAGE` string, verbatim (`command-compact/src/index.ts:14`).
    static let dshCompactUsage = "Usage: /compact (no arguments)"

    /// One line of the command's own vocabulary, kept next to the code that emits
    /// it so a change to one is visibly a change to the other.
    enum DSHCompactMessage {
        /// `:68` — the engine reported no safe useful range.
        static let noHistory = "No compactable history yet."
        /// `:32`.
        static let cancelled = "Compaction cancelled."
        /// `:27-30`. Upstream's own words name "this process"; the app's name the
        /// app's two blockers, which are the same two.
        static let busy = "Compaction is unavailable because a compaction is already running, or the assistant is not idle."
        /// `:35-37`.
        static let changed = "The history selected for compaction changed before it could be replaced. The attempt is recorded in the session log."
        /// `:39-42`.
        static let summary = "Compaction could not produce a useful summary. The attempt is recorded in the session log."
    }

    /// Upstream's success line (`command-compact/src/index.ts:71`):
    /// `Compacted %lld history items (~%@ tokens).`
    ///
    /// Both figures are this app's own estimates, labelled as such — upstream's
    /// `shadowedSeqs.length` / `shadowedTokenCount` come from its token meter, and
    /// the nearest equivalent here is `DSHTokenEstimate`, which is
    /// character-proportional. Quoting them without the label is how "the model
    /// charged 189 546 for a 77 655-token surface" became a report twice.
    static func dshCompactSuccessMessage(shadowedCount: Int, shadowedTokens: Int) -> String {
        "Compacted \(shadowedCount) history items (~\(shadowedTokens) tokens, estimated)."
    }

    /// Run `/compact` through the DSH compaction policy.
    ///
    /// Returns false when this conversation has no DSH session to compact (no turn
    /// has run yet in it), which is the caller's signal to fall back to the
    /// store-side path. Returns true once it has reported an outcome, including the
    /// failure outcomes — the caller must not also run the fallback in that case.
    @discardableResult
    @MainActor
    func compactThroughDSHPolicy() -> Bool {
        // The lock, first: upstream refuses while a compaction is open
        // (`ManualCompactionError.busy`) and this app has exactly one such flag.
        guard !isCompacting else {
            appendSystemInfo(DSHCompactMessage.busy, icon: "arrow.down.right.and.arrow.up.left")
            return true
        }
        guard !isProcessing else {
            appendSystemInfo(DSHCompactMessage.busy, icon: "arrow.down.right.and.arrow.up.left")
            return true
        }
        // No DSH session means no engine-owned conversation yet: a conversation
        // whose first turn has not run has nothing the policy can select a range
        // from, and the store-side path is the only one that knows about it.
        guard let session = dshSession, dshSessionOwner == sessionId else { return false }
        guard let entry = resolveCurrentEntry() else { return false }
        let window = effectiveContextWindow(for: entry.model)
        guard window > 0 else { return false }

        isCompacting = true
        let wasProcessingOnEntry = isProcessing
        isProcessing = true

        // The status row and its sweep are the app's existing compaction
        // affordance, matched so /compact and the long-press path look the same
        // while they run.
        messages.removeAll { $0.role == .systemInfo && $0.systemIcon == "arrow.down.right.and.arrow.up.left" }
        let statusMsg = ChatMessage(role: .systemInfo, content: "Compacting conversation...")
        statusMsg.systemIcon = "arrow.down.right.and.arrow.up.left"
        statusMsg.isCompactLoading = true
        messages.append(statusMsg)

        compactTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var statusRetired = false
            defer {
                self.isCompacting = false
                self.isProcessing = wasProcessingOnEntry
                self.compactTask = nil
                // The success path retires the row earlier (the divider carries the
                // outcome); this covers every failure exit and the early returns
                // above it.
                if !statusRetired { self.messages.removeAll { $0.id == statusMsg.id } }
            }

            // Resolved here rather than in the synchronous prologue: building the
            // provider is async, and the budget must come from the same resolver the
            // driver uses (`DSHCompactionPolicy.resolvedSpec`) so a route whose policy
            // cannot be scaled is refused here exactly as the driver refuses it.
            //
            // The RESOLVED values are not spent on the selection below — upstream's
            // manual call retains no tail — but the resolution itself is not optional:
            // it is what turns "this route has no budget" into a refusal with a reason
            // instead of a compaction that runs on numbers nobody validated, and it is
            // what keeps `dshCompactionSpec` a report of the same policy object the
            // automatic paths use. `dshCompactionRetainOverride`, the device probe, now
            // moves only the pressure path's tail — upstream has no manual-path
            // counterpart for it, and inventing one was the deviation D1 removes.
            let provider = await self.makeAgentProvider(for: entry)
            let reservedOutput = self.dynamicMaxTokens(
                provider: provider,
                model: entry.model,
                lastContextTokens: self.dshTurnUsage.inputTokens
                    + (self.dshTurnUsage.cacheReadTokens ?? 0)
                    + (self.dshTurnUsage.cacheWriteTokens ?? 0)
            )
            guard Self.dshCompactionSpec(
                policy: DSHCompactionSettings.policy(),
                contextWindow: window,
                reservedCompletionTokens: reservedOutput,
                retainOverride: Self.dshCompactionRetainOverride
            ) != nil else {
                // The route cannot resolve a budget — the same condition under which the
                // driver's `compactForPressure` warns once and lets provider-confirmed
                // overflow recovery handle it. Here there is no overflow to recover from,
                // so the command declines and says why rather than silently doing nothing.
                logger.warning(
                    "[DSHCompact] no resolvable compaction budget for \(entry.model)")
                self.appendSystemInfo(
                    "Cannot resolve a compaction budget for this route.",
                    icon: "arrow.down.right.and.arrow.up.left")
                return
            }

            // Upstream's manual selection (`compaction-basic/src/index.ts:394-398`):
            // `retainTokens: 0` — the tail is NOT retained — and a `0` pressure
            // threshold, so the command works below the automatic trigger.
            //
            // Both zeroes are upstream's own, and they are two different arguments.
            // The third argument of `selectCompactableRange` is `retainTokens`
            // (`region.ts:117-121`), so upstream's manual compaction keeps only the
            // last surface node and then walks the cut back until the tool pairing
            // is balanced (`:143-147`): the maximal balanced head reduction, the
            // same range the context-overflow path selects (`index.ts:299`). The
            // policy's 16% tail is spent by the automatic PRESSURE path alone
            // (`index.ts:331`), and `spec` is still resolved here — and still drives
            // the "cannot resolve a budget" outcome above — because the command must
            // refuse on a route whose policy cannot be scaled rather than compact
            // with no budget. What it no longer does is borrow the pressure path's
            // tail: that was this port's own deviation, not upstream's behaviour.
            //
            // `measuredTokens: 0` is inert: `select` compares it to
            // `pressureThreshold` and nothing else (`DSHCompaction.swift`, `select`),
            // and the threshold is 0.
            let result = await DSHCompaction.compact(
                session: session,
                turn: nil,
                retainTokens: 0,
                pressureThreshold: 0,
                measuredTokens: 0,
                model: entry.model.id,
                provider: provider.name,
                // The same roster the turn's own requests advertise
                // (`DSHPromptAdapter.dshAgentTools` → `makeAgentTools`, which is
                // what `runDSHTurn` hands the driver's registry). A summary request
                // replays the conversation's prefix, tools included, so a manual
                // compaction must send the same catalogue the automatic one does —
                // otherwise the two paths produce different requests for one span,
                // which is the split this port exists to remove.
                summaryTools: self.dshAgentTools()
            ) { [weak self] input in
                guard let self else { throw DSHCompactionError.summaryFailed("view model deallocated") }
                return try await self.dshCompactSummarize(
                    input,
                    contextWindow: window,
                    routeOutputCap: reservedOutput
                )
            }

            switch result {
            case .failure(let error):
                self.reportDSHCompactFailure(error, statusMsg: statusMsg)
            case .success(let outcome):
                // Upstream reports a manual compaction in ONE place
                // (`command-compact/src/index.ts:69-73`): the counts. The transcript's
                // divider is this app's equivalent, so the loading row is retired
                // first and the divider becomes the whole report — the same shape a
                // driver compaction leaves behind.
                self.messages.removeAll { $0.id == statusMsg.id }
                statusRetired = true
                logger.info(
                    "[DSHCompact] /compact shadowed=\(outcome.range.shadowedSeqs.count) "
                    + "beforeEst=\(outcome.beforeTokens) afterEst=\(outcome.afterTokens) "
                    + "retainedEst=\(outcome.range.retainedTokenCount) summarySeq=\(outcome.summarySeq.value)"
                )
                self.dshReportManualCompaction(outcome)
            }
        }
        return true
    }

    /// Turn a `DSHCompactionError` into upstream's message for the same class
    /// (`command-compact/src/index.ts:24-56`), so a user sees the same reason
    /// whether the compaction was asked for or automatic.
    @MainActor
    private func reportDSHCompactFailure(_ error: DSHCompactionError, statusMsg: ChatMessage) {
        let text: String
        switch error {
        case .busy:
            text = DSHCompactMessage.busy
        case .surfaceChanged:
            text = DSHCompactMessage.changed
        // `.noShrink` is upstream's `summary` class in effect — the summary could
        // not be made useful — while `.summaryFailed` is explicit about why. Both
        // end with "recorded in the session log", which is where the attempt is.
        case .noShrink, .summaryFailed:
            text = DSHCompactMessage.summary
        case .noOpenTurn:
            // Unreachable for a manual compaction (`turn: nil`); named rather than
            // defaulted so a future arm fails loudly instead of silently reporting
            // the wrong reason.
            text = DSHCompactMessage.busy
        }
        statusMsg.content = text
        statusMsg.isCompactLoading = false
        logger.warning("[DSHCompact] /compact failed: \(error.message)")
    }

    /// Surface a successful manual compaction in the transcript, with the same
    /// divider shape the driver's own compaction uses (`didCompact`) so the two are
    /// indistinguishable to a reader — they are the same operation.
    @MainActor
    private func dshReportManualCompaction(_ outcome: DSHCompactionOutcome) {
        messages.removeAll { $0.role == .compactDivider }
        let label = "Compacted \(outcome.range.shadowedSeqs.count) entries "
            + "(\(Int(outcome.shrinkRatio * 100))% smaller)"
        let row = ChatMessage(role: .compactDivider, content: label)
        row.compactSummary = """
        DSH compaction (/compact)

        Shadowed \(outcome.range.shadowedSeqs.count) earlier entries into one summary.
        Context: \(outcome.beforeTokens) → \(outcome.afterTokens) tokens (\(Int(outcome.shrinkRatio * 100))% smaller)
        Retained tail: \(outcome.range.retainedTokenCount) tokens
        Summary writer: \(outcome.model) via \(outcome.provider)
        """
        row.systemIcon = "arrow.down.right.and.arrow.up.left"

        // A manual compaction has no streaming turn to anchor against: the divider
        // goes at the newest shadowed row the transcript can name, or at the end
        // when none of them is on screen.
        let lastShadowedSeq = outcome.range.shadowedSeqs.last?.value
        let insertIdx: Int
        if let lastShadowedSeq,
           let idx = messages.lastIndex(where: { $0.dshSeq == lastShadowedSeq }) {
            insertIdx = idx + 1
        } else {
            insertIdx = messages.count
        }
        messages.insert(row, at: min(insertIdx, messages.count))

        for above in 0..<min(insertIdx, messages.count)
        where messages[above].role != .compactDivider && messages[above].role != .systemInfo {
            messages[above].isCompactedHistory = true
        }

        // The session half is now ahead of the store half, exactly as it is after a
        // driver compaction: the next turn's end-of-turn pass writes the marker from
        // the same pending record the driver uses. Queueing it here rather than
        // inventing a second write path is what keeps "one marker row per session"
        // true (`dshResolveCompactionMarker` / `dshWriteCompactionMarker`).
        dshResolveCompactionMarker(outcome)
        publishUnlessTransitioning()
        scrollToBottomSignal.send()
    }

    /// Summarize the shadowed region for a manual compaction.
    ///
    /// The request is the DRIVER'S request, not a second one: this forwards to
    /// `DSHTurnDriver.summarizeExcerpt`, which owns the output ceiling, the safety
    /// margin, the per-request region budget, the region fitting itself, the
    /// explicit omission past the segment cap, the replayed messages, the derived
    /// system head, the tool roster, the compaction directive and the
    /// empty/truncated refusals. What this function supplies is only the facts a
    /// manual compaction owns — the provider it resolved for the current entry, the
    /// window the same `effectiveContextWindow` reports for that entry (the figure
    /// `DSHTurnDriverRun` hands the driver as `config.contextWindow`), and the
    /// output cap `dynamicMaxTokens` resolved for the same entry (the figure
    /// `DSHTurnDriverRun` hands the driver as `config.maxTokens`).
    ///
    /// That delegation is the fix for a P0-shaped defect rather than tidying: the
    /// old body here sent the WHOLE shadowed excerpt as one request with a fixed
    /// `maxTokens: 4096` and no region fitting, so the manual path carried exactly
    /// the unbounded-request shape the driver's budget exists to prevent (a
    /// 1,783,917-byte summary request rejected with `context_length_exceeded`,
    /// device 2026-10-19 09:17:19) — it just had not been hit yet. The prompt is
    /// deliberately NOT the store-side one (`generateCompactSummary`): that one
    /// asks for its own structure and answers a different pipeline.
    ///
    /// - Parameters:
    ///   - input: the replayed region (messages, system head, tool roster).
    ///   - contextWindow: capacity of the routed model.
    ///   - routeOutputCap: output tokens one routed request may emit for this
    ///     entry, as `dynamicMaxTokens` resolved it.
    /// - Returns: the summary, non-empty by construction.
    private func dshCompactSummarize(
        _ input: DSHSummaryInput,
        contextWindow window: Int,
        routeOutputCap: Int
    ) async throws -> String {
        guard let entry = resolveCurrentEntry() else {
            throw DSHCompactionError.summaryFailed("No model configured. Add a provider in Settings.")
        }
        let provider = await makeAgentProvider(for: entry)
        guard window > 0 else {
            throw DSHCompactionError.summaryFailed(
                "no context capacity to summarize against (model=\(entry.model.id))")
        }
        // The same meter conversion `DSHTurnDriver.summaryMeterRatioNow()` applies,
        // over the same kind of pair: the provider's own count of the last routed
        // request (accumulated into `dshTurnUsage` from every response's usage) and
        // this surface's estimator total. A manual compaction has no driver-owned
        // envelope to grow, so the count is used as it stands; when there is none —
        // a `/compact` before the session's first response — the ratio falls to the
        // shipped floor, which is the conservative direction (a smaller per-request
        // budget, more segments, never an oversized request).
        let measured = dshTurnUsage.inputTokens
            + (dshTurnUsage.cacheReadTokens ?? 0)
            + (dshTurnUsage.cacheWriteTokens ?? 0)
        let surfaceEstimate = DSHTokenEstimate.total(dshSession?.surface() ?? [])
        let ratio = DSHTurnDriver.summaryMeterRatio(
            measuredTokens: measured,
            surfaceEstimate: surfaceEstimate
        )
        return try await DSHTurnDriver.summarizeExcerpt(
            input,
            contextWindow: window,
            routeOutputCap: routeOutputCap,
            meterRatio: ratio,
            provider: provider,
            logCategory: "DSHCompact"
        )
    }
}

// MARK: - Compaction budget

extension AIChatViewModel {

    /// The budgets a DSH compaction runs with — the one policy, meeting the one
    /// window, through the ONE resolver.
    ///
    /// `DSHTurnDriver.resolveSpec` is private to the driver, and the driver is
    /// created per turn — a manual compaction has no driver to ask. The resolution
    /// therefore lives in `DSHCompaction.swift`
    /// (`DSHCompactionPolicy.resolvedSpec(targetKey:contextWindow:reservedCompletionTokens:retainOverride:pressureThresholdOverride:)`),
    /// which is also what the driver now forwards to, and this is its only other
    /// caller: the two assemblers that used to exist (one here, one in the driver,
    /// differing only in `targetKey`) are one function with `targetKey` as an
    /// argument. Every input is the same input the driver takes from `config`
    /// (`DSHTurnDriverRun`), read from the same accessors:
    /// `DSHCompactionSettings.policy()`, the group-aware `effectiveContextWindow`,
    /// and the probe/UserDefaults retain override.
    ///
    /// `targetKey` stays `manual/compact`: it is the key a misconfiguration is
    /// reported under, and a manual compaction's route is the model, not a
    /// provider/model pair the driver could have named.
    ///
    /// - Parameters:
    ///   - policy: the user's policy, as stored.
    ///   - contextWindow: adapter-declared capacity for the routed model.
    ///   - reservedCompletionTokens: output tokens a routed request reserves —
    ///     `dynamicMaxTokens`, resolved by the caller the same way the driver
    ///     resolves it.
    ///   - retainOverride: absolute retained-tail budget, or nil to derive.
    /// - Returns: the resolved spec, or nil when the policy cannot be scaled.
    static func dshCompactionSpec(
        policy: DSHCompactionPolicy,
        contextWindow: Int,
        reservedCompletionTokens: Int,
        retainOverride: Int?
    ) -> DSHCompactionSpec? {
        try? policy.resolvedSpec(
            targetKey: DSHCompactionPolicy.targetKey(provider: "manual", model: "compact"),
            contextWindow: contextWindow,
            reservedCompletionTokens: reservedCompletionTokens,
            retainOverride: retainOverride,
            pressureThresholdOverride: nil
        )
    }
}
