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
//   1. It is EXPLICITLY below the pressure threshold. Upstream calls
//      `selectCompactableRange(session, measurement, 0)` — a `0` THRESHOLD gate,
//      which is the argument that is not spent here — and its own
//      `compactIfNeeded('pressure')` is the only path that consults
//      `spec.thresholdTokens`. The RETAINED TAIL is the opposite: the manual call
//      passes the policy's own `spec.retainTokens`, resolved from the same
//      `resolveCompactSpec(policy, contextWindow, reservedCompletionTokens)`
//      (`compaction-basic/src/config.ts`) the automatic trigger uses, and
//      `compactNow` reaches that resolution through the same `selectCompactableRange`
//      whose `retainTokens` walk-back is at `compaction-basic/src/region.ts:133-141`.
//      So the manual command *bypasses when*, never *what*: same selection rule,
//      same balanced cut, same shrink requirement, same policy object. On a 0.16
//      retain ratio that means a manual `/compact` keeps the same 16% recent tail an
//      automatic compaction would — which is exactly the operator's requirement
//      ("must share the same `DSHCompactionPolicy`"), and the opposite of the
//      zero-tail maximal reduction `recoverFromContextOverflow` performs when a
//      request has ALREADY been rejected.
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
        let provider = await makeAgentProvider(for: entry)
        let window = effectiveContextWindow(for: entry.model)
        guard window > 0 else { return false }
        // The same output reservation the driver takes (`DSHTurnDriverRun`): the
        // resolved request cap, which is also the number the trigger's headroom
        // bound is computed from. Resolved through the same call so a manual
        // compaction cannot keep a different tail than an automatic one on the same
        // route.
        let reservedOutput = dynamicMaxTokens(
            provider: provider,
            model: entry.model,
            lastContextTokens: dshTurnUsage.inputTokens
                + (dshTurnUsage.cacheReadTokens ?? 0)
                + (dshTurnUsage.cacheWriteTokens ?? 0)
        )
        guard let spec = Self.dshCompactionSpec(
            policy: DSHCompactionSettings.policy(),
            contextWindow: window,
            reservedCompletionTokens: reservedOutput,
            retainOverride: Self.dshCompactionRetainOverride
        ) else {
            // The route cannot resolve a budget — the same condition under which the
            // driver's `compactForPressure` warns once and lets provider-confirmed
            // overflow recovery handle it. There is no overflow to recover from
            // here, so the store-side path answers the request.
            logger.warning("[DSHCompact] no resolvable compaction budget for \(entry.model); falling back to the store-side compaction")
            return false
        }

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

            // Upstream's manual selection (`compaction-basic/src/index.ts:394-398`):
            // the POLICY's retained tail, and a `0` threshold so the command works
            // below the automatic trigger.
            //
            // `retainTokens` is `spec.retainTokens` — the same number
            // `DSHTurnDriver.compactForPressure` hands the engine, derived from
            // `DSHCompactionSettings.policy()` and the same probe/UserDefaults
            // override through `dshCompactionSpec` — so editing the retain ratio in
            // Settings moves BOTH. Passing a literal (or a zero) here would be the
            // drift this port exists to remove.
            //
            // `measuredTokens: 0` is inert: `select` compares it to
            // `pressureThreshold` and nothing else (`DSHCompaction.swift`, `select`),
            // and the threshold is 0. The retention budget is the policy's; only the
            // gate is bypassed.
            let result = await DSHCompaction.compact(
                session: session,
                turn: nil,
                retainTokens: spec.retainTokens,
                pressureThreshold: 0,
                measuredTokens: 0,
                model: entry.model,
                provider: provider.name
            ) { [weak self] shadowedText in
                guard let self else { throw DSHCompactionError.summaryFailed("view model deallocated") }
                return try await self.dshCompactSummarize(shadowedText)
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

    /// Summarize one shadowed span for a manual compaction.
    ///
    /// Same instruction the engine's own compactions send (`DSHTurnDriver.summarize`)
    /// and the same clamped stream call, so a span compacted by hand and the same
    /// span compacted under pressure produce summaries of the same kind. The prompt
    /// is deliberately NOT the store-side one (`generateCompactSummary`): that one
    /// asks for its own structure and answers a different pipeline.
    private func dshCompactSummarize(_ text: String) async throws -> String {
        guard let entry = resolveCurrentEntry() else {
            throw DSHCompactionError.summaryFailed("No model configured. Add a provider in Settings.")
        }
        let provider = await makeAgentProvider(for: entry)

        let instruction = """
        Summarize the conversation excerpt below. Preserve: decisions made, facts \
        established, file paths and identifiers, current task state, and anything \
        the next turn must know to continue. Drop: repeated attempts that failed, \
        verbose tool output already superseded, and pleasantries.

        Be concrete and terse. Do not address the user. Do not invent facts not \
        present in the excerpt.

        <excerpt>
        \(text)
        </excerpt>
        """

        let stream = try await provider.streamAgentMessageClamped(
            messages: [AgentMessage(role: .user, parts: [.text(instruction)])],
            systemPrompt: "You are a precise conversation summarizer.",
            tools: [],
            maxTokens: 4096,
            thinkingLevel: .off
        )

        var summary = ""
        for try await event in stream {
            try Task.checkCancellation()
            if case .textDelta(let delta) = event { summary += delta }
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DSHCompactionError.summaryFailed("the summarizer returned nothing")
        }
        return trimmed
    }
}

// MARK: - Compaction budget

extension AIChatViewModel {

    /// The budgets a DSH compaction runs with, resolved from the one policy object
    /// both the automatic and the manual path use.
    ///
    /// `DSHTurnDriver.resolveSpec` is private to the driver, and the driver is
    /// created per turn — a manual compaction has no driver to ask. So the
    /// resolution lives here, once, as a value: the driver could not call it either
    /// without being changed, and the point of this whole file is that there must be
    /// exactly one place where the policy meets a window. Every input is the same
    /// input the driver takes from `config` (`DSHTurnDriverRun`), read from the same
    /// accessors: `DSHCompactionSettings.policy()`, the group-aware
    /// `effectiveContextWindow`, and the probe/UserDefaults retain override.
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
        var resolved = policy
        if let retainOverride { resolved.retainTokens = retainOverride }
        return try? resolved.resolveSpec(
            targetKey: DSHCompactionPolicy.targetKey(provider: "manual", model: "compact"),
            contextWindow: contextWindow,
            reservedCompletionTokens: reservedCompletionTokens
        )
    }
}
