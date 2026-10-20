//
//  DSHTurnDriverAdapter.swift
//  Minis
//
//  AIChatViewModel's conformance to DSHTurnDriverDelegate.
//
//  WHAT THE DRIVER OWNS
//  --------------------
//  Request derivation, tool scheduling, result commit order, loop guard, and
//  compaction selection. These decide how well the agent works, and they were
//  the source of the index-drift defects.
//
//  WHAT THE VIEWMODEL KEEPS
//  ------------------------
//  Streaming presentation, persistence, image budgeting, group fallback, queued
//  prompts, cancel cleanup, TTS, and every UIKit interaction. The driver's
//  callbacks are coarser than the provider's stream events, so the ViewModel
//  maps them onto the rendering path it already has.
//
//  IDENTITY
//  --------
//  The driver addresses entries by DSHSeq; the UI by array index. Bridging the
//  two by index is exactly the defect this port removes, so the driver's state
//  lives on the ViewModel and the streaming target is resolved by seq.
//

import Foundation

// MARK: - Delegate Conformance

extension AIChatViewModel: DSHTurnDriverDelegate {

    public func driver(_ driver: DSHTurnDriver, didStartStep turn: Int, step: Int) {
        // One heartbeat line per step, so a wedged loop is attributable to a
        // step without correlating timestamps across subsystems.
        AppLogger(category: "DSHLoop").info(
            "[DSH] step=\(step) turn=\(turn) session=\(sessionId?.prefix(8) ?? "nil")"
        )
    }

    public func driver(_ driver: DSHTurnDriver, didEmitText text: String) {
        guard dshStreamingMsgIdx >= 0, dshStreamingMsgIdx < messages.count else { return }
        let idx = dshStreamingMsgIdx
        guard messages[idx].role == .assistant else { return }

        // Text ends the current reasoning segment, so the next thinking delta
        // opens a new block rather than appending behind the answer.
        //
        // [T-thinking-count-matches-text] FLUSH before letting go of the segment.
        // The adaptive throttle holds the newest second of reasoning in a buffer
        // that the body does not render, so resetting the index here dropped that
        // tail: the device showed a count of "1" beside a single "i" until the
        // block was expanded by hand (expanding forces the flush) and the real
        // sentence appeared. The legacy stream flushes at the same two boundaries
        // (`AIChatViewModel+SSEStream`: `.text` and `.toolUse` block starts).
        dshFlushThinkingSegment()
        dshThinkingBlockIdx = -1

        // The presenter is told which row it writes into before anything else: the
        // row is re-derived per step, and a presenter still pointing at the last
        // turn's row would write text nobody sees.
        guard let presenter = dshTextPresenter else { return }
        presenter.msgIdx = idx

        // Text before and after a tool call are two different transcript blocks, so
        // the presenter is re-pointed whenever the block it was filling is no longer
        // the row's trailing text block.
        //
        // A new block starts a new accumulation: the flush REPLACES the block's
        // content with what it is given, so it must be handed the whole text of
        // *this* block — handing it the pending chunk left the transcript showing
        // only the last fragment of every answer.
        let startedBlock = presenter.blockIdx < 0 || presenter.blockIdx >= messages[idx].blocks.count
            || messages[idx].blocks[presenter.blockIdx].kind != .text
        if startedBlock {
            _ = presenter.beginBlock()
        }
        presenter.accumulate(text)
        dshTurnTextTotal += text.count

        // A brand-new block is flushed at once, ignoring the throttle.
        //
        // The list's height invalidator runs off the empty → filled signal, and it
        // gives up silently if the block it names is not yet in the data source
        // snapshot — leaving the cell at its ~0pt empty-content height, which is
        // the reported overlap with the row above. Flushing the block and its first
        // text in one publish makes the snapshot the signal is handled against
        // already contain it.
        if let plan = presenter.takeFlushPayload(force: startedBlock) {
            if !commitStreamText(presenter, plan: plan, finalFlush: false) {
                presenter.requeue(plan.text)
            }
        } else {
            // [T-ios-stream-tail-flush] Nothing was due, so the throttle is holding
            // this text. Arm the one-shot tail flush: if the stream goes quiet, the
            // text is committed on its own instead of waiting for the next delta, the
            // tool boundary, or the end of the turn — which is how a paragraph's tail
            // ended up in the same frame as a batch of tool blocks.
            dshScheduleTrailingTextFlush()
        }

        // Streaming read-aloud: the shared presenter path, so the sentence
        // splitting, the once-per-turn queue clear and the dynamic window are the
        // same code the legacy loop runs. `speakEnabled` is read live, so turning
        // read-replies on mid-reply takes effect on this turn.
        if speakEnabled {
            Task { await presenter.speakStreamedText() }
        }
    }

    public func driver(_ driver: DSHTurnDriver, didEmitReasoning text: String) {
        guard dshStreamingMsgIdx >= 0, dshStreamingMsgIdx < messages.count else { return }
        let idx = dshStreamingMsgIdx
        guard messages[idx].role == .assistant else { return }

        // Each contiguous reasoning segment becomes its own block, appended in
        // arrival order so thinking interleaves naturally with text and tool
        // blocks — the same shape a reload from the store produces.
        //
        // The block position is remembered rather than re-derived: a tool call
        // can append to this row mid-segment, and searching for "the last
        // thinking block" would then find a different one, or none.
        if dshThinkingBlockIdx < 0 || dshThinkingBlockIdx >= messages[idx].blocks.count
            || messages[idx].blocks[dshThinkingBlockIdx].kind != .thinking {
            messages[idx].blocks.append(AssistantBlock(kind: .thinking, content: ""))
            dshThinkingBlockIdx = messages[idx].blocks.count - 1
            dshPendingReasoning = ""
        }
        let blockIdx = dshThinkingBlockIdx

        dshPendingReasoning += text
        messages[idx].blocks[blockIdx].appendThinkingDelta(text)

        // Throttled flush to the published `content`, with the interval widening
        // as the thinking grows: dense reasoning streams would otherwise trigger
        // a view rebuild and a scroll per delta.
        let now = Date()
        let interval = AssistantBlock.thinkingFlushInterval(forLength: dshPendingReasoning.count)
        if now.timeIntervalSince(dshLastThinkingFlush) >= interval {
            dshLastThinkingFlush = now
            messages[idx].blocks[blockIdx].flushThinkingBuffer()
            publishUnlessTransitioning()
            if isNearBottom { scrollToBottomSignal.send() }
        }
    }

    /// Push one reasoning segment's unpublished tail into its block.
    ///
    /// [T-thinking-count-matches-text] The throttle above deliberately keeps the
    /// newest second of reasoning in a buffer that the body does not render, and
    /// every boundary that ENDS a segment has to force it out: the text starting,
    /// a tool call starting, and the turn sealing. Only the last of those did, so
    /// a reasoning segment that ended in a tool call or an answer left its tail
    /// behind — the device showed a count of "1" and a single "i" until the block
    /// was expanded by hand, which forces the same flush.
    ///
    /// The whole block is the unit here, not one delta: `flushThinkingBuffer`
    /// copies the buffer the block has been accumulating, so calling it once per
    /// boundary is enough.
    private func dshFlushThinkingSegment() {
        guard dshThinkingBlockIdx >= 0,
              dshStreamingMsgIdx >= 0, dshStreamingMsgIdx < messages.count,
              dshThinkingBlockIdx < messages[dshStreamingMsgIdx].blocks.count else { return }
        messages[dshStreamingMsgIdx].blocks[dshThinkingBlockIdx].flushThinkingBuffer()
    }

    public func driver(
        _ driver: DSHTurnDriver,
        willRunTool name: String,
        callId: String,
        arguments: [String: Any]
    ) {
        AppLogger(category: "DSHLoop").info("[DSH] tool start \(name) id=\(callId.prefix(20))")

        // Keep the turn's tool calls for the session-title summary. The legacy
        // loop handed them to `generateSessionTitleIfNeeded` for exactly this
        // reason — an early turn can be tool-only, and a tool-only first
        // response otherwise summarises as the empty string.
        dshTurnToolEntries.append((name: name, args: arguments))

        // A tool call ends the current reasoning segment and the current text
        // block: text that follows a tool result is its own block, as it is after
        // a reload.
        //
        // The flush comes first and is forced: this is the last chance to push the
        // text belonging to the block being left behind, and the legacy loop makes
        // the same flush before it appends a tool block (its "Step 1"). Without it
        // the tail of that block sat in the throttle and only appeared later — the
        // "swallowed text" report.
        dshCommitTextForToolBoundary()
        // [T-thinking-count-matches-text] Same rule as the text block above, and
        // for the same reason: a tool call ends the reasoning segment and the
        // throttle still holds its tail. Resetting the index without flushing left
        // the block one flush short — a tool-first reply showed "1" and "i" until
        // the user expanded it.
        dshFlushThinkingSegment()
        dshThinkingBlockIdx = -1
        dshTextPresenter?.endBlock()

        // Create the block now so the user sees the call while it runs, and so
        // the executor has a row to stream into. The status is `.running` until
        // the result lands.
        guard dshStreamingMsgIdx >= 0, dshStreamingMsgIdx < messages.count else { return }
        let idx = dshStreamingMsgIdx
        guard messages[idx].role == .assistant else { return }

        // A re-emitted start for the same call id must not duplicate the block.
        if let existing = messages[idx].blocks.firstIndex(where: { $0.toolUseId == callId }) {
            dshToolBlockIndex[callId] = existing
            return
        }

        let kind = DSHToolBlockKind.kind(for: name, arguments: arguments)
        var block = AssistantBlock(kind: kind, content: "Executing...")
        block.toolUseId = callId
        block.toolStatus = .running
        block.toolStartTime = Date()
        messages[idx].blocks.append(block)
        // The executor addresses the block by position, and the position of a
        // block can change while a turn runs, so record it against the call id
        // the executor is given.
        dshToolBlockIndex[callId] = messages[idx].blocks.count - 1
        publishUnlessTransitioning()
        scrollToBottomSignal.send()
    }

    public func driver(
        _ driver: DSHTurnDriver,
        didFinishTool name: String,
        callId: String,
        result: DSHToolExecutionResult
    ) {
        AppLogger(category: "DSHLoop").info(
            "[DSH] tool done \(name) id=\(callId.prefix(20)) isError=\(result.isError) len=\(result.content.count)"
        )
        dshPendingToolResults[callId] = result
        dshRenderToolResult(callId: callId)
    }

    /// Render a settled tool result onto its UI block.
    ///
    /// The driver settles results in model order but reports them one at a time,
    /// so each is applied to the block carrying its call id. Matching by call id
    /// rather than by position means a block appended by another path cannot
    /// steal the result.
    func dshRenderToolResult(callId: String) {
        guard let result = dshPendingToolResults[callId] else { return }
        guard dshStreamingMsgIdx >= 0, dshStreamingMsgIdx < messages.count else { return }
        let idx = dshStreamingMsgIdx
        guard messages[idx].role == .assistant else { return }

        // Find the block this call created. The driver emits `willRunTool` before
        // the call and `didFinishTool` after, so the block exists by now; if it
        // does not, append one rather than dropping the result on the floor.
        if let blockIdx = messages[idx].blocks.firstIndex(where: { $0.toolUseId == callId }) {
            messages[idx].blocks[blockIdx].content = result.content
            messages[idx].blocks[blockIdx].toolStatus = result.isError
                ? .failed(message: "Tool failed")
                : .success
            // A tool result is not always text. read_image produces pixels and
            // browser_use produces a page screenshot plus the URL it landed on;
            // both are rendered from the block, so carry them across here rather
            // than leaving the transcript with a bare caption.
            if let imagePath = result.imageLinuxPath, result.imageData != nil {
                messages[idx].blocks[blockIdx].imageFilePath = imagePath
            }
            if let pageURL = result.pageURL {
                messages[idx].blocks[blockIdx].browserURL = pageURL
            }
        } else {
            var block = AssistantBlock(kind: .info, content: result.content)
            block.toolUseId = callId
            block.toolStatus = result.isError
                ? .failed(message: "Tool failed")
                : .success
            messages[idx].blocks.append(block)
        }
        publishUnlessTransitioning()
        scrollToBottomSignal.send()
    }

    public func driver(_ driver: DSHTurnDriver, didReportUsage usage: DSHTokenUsage) {
        dshTurnUsage = usage

        // Session token totals, which the legacy loop accumulated once per
        // iteration. Without this the Session Token Usage sheet read 0 for the
        // whole of every live DSH session — the numbers only appeared after a
        // reload rebuilt them from the database rows — and "Context Used" read 0
        // because the row's own `usage` was never stamped either.
        sessionInputTokens += usage.inputTokens
        sessionOutputTokens += usage.outputTokens
        sessionCacheReadTokens += usage.cacheReadTokens ?? 0
        sessionCacheWriteTokens += usage.cacheWriteTokens ?? 0

        // Output speed is derived from streaming time, and the driver reports at
        // the end of each step rather than reporting a duration, so the gap
        // between reports is the closest available measurement. The first gap
        // starts at the turn, which `runDSHTurn` records.
        if usage.outputTokens > 0 {
            let now = Date()
            if let last = dshLastUsageAt {
                sessionStreamDuration += now.timeIntervalSince(last)
                sessionStreamOutputTokens += usage.outputTokens
            }
            dshLastUsageAt = now
        }

        // Publish this response's usage on the running row NOW.
        //
        // The row used to be stamped once, in `dshSealStreamingTurn`, so for the
        // whole of a multi-step turn the composer's context ring and the panel
        // behind it described the PREVIOUS turn: the driver reports once per model
        // call, and every one of those reports is a real report from the provider.
        // Stamping here is what makes "each response updates the reading" true, and
        // the store takes the same value so the panel's cache row moves with it.
        dshPublishLiveUsage()
    }

    /// Stamp the streaming row — and the panel's cache reading — with the newest
    /// provider report. No-op before the row exists, and while nothing has been
    /// reported yet (`dshTurnUsage` is the driver's zero value until then).
    private func dshPublishLiveUsage() {
        guard dshStreamingMsgIdx >= 0, dshStreamingMsgIdx < messages.count else { return }
        guard dshTurnUsage.inputTokens > 0
            || dshTurnUsage.outputTokens > 0
            || (dshTurnUsage.cacheReadTokens ?? 0) > 0
            || (dshTurnUsage.cacheWriteTokens ?? 0) > 0 else { return }
        let idx = dshStreamingMsgIdx
        let stamped = minisTokenUsage(dshTurnUsage)
        if messages[idx].usage != stamped {
            messages[idx].usage = stamped
        }
        DSHContextBreakdownStore.shared.recordUsage(stamped, sessionKey: sessionId)
        // One line per model response, and the only place the panel's inputs are
        // visible on a device: `cache_reported=false` is the proof that this
        // backend names no cache bucket at all (so the panel's cache row is
        // correctly absent rather than reading 0%), and `prompt` is the same
        // denominator the panel's rate uses.
        AppLogger(category: "DSHLoop").info(
            "[DSH] usage report: prompt=\(stamped.latestContextTokens) "
            + "cache_read=\(stamped.cacheReadTokens) cache_write=\(stamped.cacheCreationTokens) "
            + "cache_reported=\(stamped.cacheReported) out=\(stamped.outputTokens)"
        )
        publishUnlessTransitioning()
    }

    public func driver(_ driver: DSHTurnDriver, didCompact outcome: DSHCompactionOutcome) {
        AppLogger(category: "DSHLoop").warning(
            "[DSH] compacted \(outcome.range.shadowedSeqs.count) entries, "
            + "\(outcome.beforeTokens) -> \(outcome.afterTokens) tokens "
            + "(shrink \(Int(outcome.shrinkRatio * 100))%)"
        )
        dshLastCompaction = outcome

        // [T-ctx-usage-after-dsh-compact] Re-price the composer's usage NOW.
        //
        // The legacy in-loop compaction ends by calling this
        // (`AIChatViewModel+Compaction.swift`'s `announceContextUsageAfterCompaction`),
        // but the DSH path installs its marker here and re-priced nothing. After a
        // mid-turn compaction the composer kept the PRE-compaction figure, so a
        // 560k-window session that had just dropped to tens of thousands kept
        // glowing red — and re-entering the conversation changed nothing, because a
        // cached view model publishes no usage on its own. The device showed exactly
        // that (2026-10-20 00:26:46 "compacted 60 entries, 59886 -> 20845"): the glow
        // cleared only when the operator stopped the turn.
        //
        // Measured, not reported-forward: `publishMeasuredContextUsage` prices what
        // the next request will send, which is the only figure that describes the
        // compacted surface before any response arrives.
        //
        // [T-ctx-usage-after-dsh-compact] `surfaceEstimate` is what makes that
        // literally true: a mid-turn compaction shrinks the SESSION surface, while
        // the app's model-facing history is only reconciled at turn end, so
        // measuring the history here priced the conversation that was just replaced
        // (the device announced 136% · 761.9k / 560k right after compacting to ~46k
        // estimator tokens). The outcome carries the compacted size.
        announceContextUsageAfterCompaction(surfaceEstimate: outcome.afterTokens)

        // Capture the durable anchor now, while the shadowed rows are still in
        // `agentHistory` — the anchor is a database id that only lives there, and
        // the reconcile that runs at the end of the turn replaces that array with
        // the session surface. The write itself happens after the persistence pass
        // at the end of the turn, because a mid-turn range ends inside this turn's
        // own rows.
        dshResolveCompactionMarker(outcome)

        // Surface the compaction in the transcript, AT THE BOUNDARY it created.
        //
        // [T-dsh-compact-divider-position] The divider used to be appended to the
        // end of `messages`. That is the newest position in the array, so on a
        // turn that compacts repeatedly the transcript showed the summary being
        // pushed further down each time, below the replies it summarizes, and the
        // rows it had just replaced were not greyed at all — the exact symptom the
        // operator reported ("the compacted message always sits at the newest
        // position instead of being wrapped by the messages after it").
        //
        // The replaced rows sit above the boundary, so the divider is inserted
        // immediately after the newest shadowed row — the same placement the
        // in-loop compactor uses (`compactBefore`'s `dividerInsertIdx`) and the same
        // one the reload path reconstructs from the persisted marker
        // (`AIChatViewModel+Persistence` Phase 2.5). Everything above it is
        // flagged `isCompactedHistory`, which is what greys it, and the streaming
        // bubble below it keeps writing into the active region.
        //
        // Old dividers are dropped first: one session shows one compaction, the
        // latest — the same rule the in-loop path applies.
        messages.removeAll { $0.role == .compactDivider }
        let insertIdx = Self.dshDividerInsertIndex(
            messages: messages,
            lastShadowedSeq: outcome.range.shadowedSeqs.last?.value,
            liveStreamingRowId: dshLiveStreamingRowId
        )

        // `content` is the divider's visible label and `compactSummary` sits
        // behind its info button — ChatMessageViews reads those two fields in
        // that order, so a summary written only to `compactSummary` renders as a
        // blank row.
        let label = "Compacted \(outcome.range.shadowedSeqs.count) entries (\(Int(outcome.shrinkRatio * 100))% smaller)"
        let row = ChatMessage(role: .compactDivider, content: label)
        row.compactSummary = """
        DSH compaction

        Shadowed \(outcome.range.shadowedSeqs.count) earlier entries into one summary.
        Context: \(outcome.beforeTokens) → \(outcome.afterTokens) tokens (\(Int(outcome.shrinkRatio * 100))% smaller)
        Retained tail: \(outcome.range.retainedTokenCount) tokens
        Summary writer: \(outcome.model) via \(outcome.provider)
        """
        row.systemIcon = "arrow.down.right.and.arrow.up.left"

        // [F4-compaction-visibility] Place the bar where the compaction actually
        // cut the transcript, which for a DSH mid-turn compaction is usually
        // INSIDE the assistant bubble the turn is still writing into.
        //
        // Why the old placement was invisible, from the device log
        // (F:\smb\log\minis-2026-10-19.log, 09:17:18 / 09:28:31 / 09:33:11):
        //
        //   [DSH] compaction divider at 2/4 lastShadowedSeq=111 liveRow=3
        //   [DSH] compaction divider at 4/6 lastShadowedSeq=102 liveRow=5
        //
        // `insertIdx` equals the live row's own index in every one of them. That
        // is structural, not coincidence: `dshDividerInsertIndex` resolves the
        // boundary by `dshSeq`, and NO UI row carries one (the only stamp is
        // `dshSealStreamingTurn`, i.e. after the turn; the reload path never stamps
        // one), so the seq search always misses and `dshDividerPosition` clamps to
        // the live row. One DSH turn is ONE assistant bubble — 199 blocks / 9,114pt
        // in the recorded session — so "immediately above the live row" is
        // thousands of points above a viewport pinned to the bottom, and the
        // greying loop exempts that row wholesale. The user watches the reply
        // continue and sees neither the bar nor any dim: 「压缩的时候没有任何显示
        // 了，就像正常对话一样直接继续」.
        //
        // The boundary is knowable exactly, without a seq on the UI row: the
        // shadowed session entries record their tool-call ids, and the live row's
        // blocks carry the id of the call each rendered — so a block whose call is
        // inside the shadowed range IS compacted. No inference, and no over-claim,
        // which is the rule the reload path's `deferredBlocks` accounting exists to
        // enforce.
        //
        // The message-level greying below is unchanged and still dims the rows
        // above the bar; what it cannot reach is the shadowed prefix INSIDE the
        // live row, and that is the region the user is actually looking at.
        let liveIdxBefore = dshStreamingMsgIdx
        let shadowedCallIds = Self.dshShadowedCallIds(
            session: dshSession,
            shadowedSeqs: outcome.range.shadowedSeqs
        )
        let compactedBlocks = (liveIdxBefore >= 0 && liveIdxBefore < messages.count
                               && messages[liveIdxBefore].role == .assistant)
            ? Self.dshCompactedBlockPrefixCount(
                liveBlocks: messages[liveIdxBefore].blocks,
                shadowedCallIds: shadowedCallIds)
            : 0
        let anchoredDivider = compactedBlocks > 0 && insertIdx == liveIdxBefore
        if anchoredDivider {
            let live = messages[liveIdxBefore]
            for blockIdx in 0..<compactedBlocks {
                live.blocks[blockIdx].isCompactedHistory = true
            }
            row.compactionAnchorBlockId = live.blocks[compactedBlocks - 1].id
            row.compactionRevealPending = true
            // BELOW the live row, on purpose: the row the turn is streaming into
            // keeps its index (so no re-anchor can be got wrong), the list emits
            // this divider's cell after its anchor block's cell, and every block
            // the turn writes next lands under the bar — which is also the fix for
            // "new messages appear above the compaction line".
            messages.insert(row, at: min(liveIdxBefore + 1, messages.count))
        } else {
            messages.insert(row, at: insertIdx)
            row.compactionRevealPending = true
        }

        // [T-dsh-compact-divider-index-drift] The insert moved every row below
        // the divider down by one — including the assistant row this turn is
        // streaming into. Re-anchor it before anything else reads it, or the loop
        // keeps writing at the pre-insert offset, which is now this divider: text,
        // thinking and tool blocks are then rejected by their
        // `role == .assistant` guards, the reply row stays empty forever, and the
        // divider ends up as the newest row on screen — the operator's "all new
        // messages appear above the compaction line, as if nothing new arrived".
        //
        // One healing site, and this is it: the target is re-derived from the
        // row's own identity, so it is correct however far the insert moved it.
        // (A no-op in the anchored case above: nothing was inserted above it.)
        dshReanchorStreamingRow()

        // The streaming row is BY CONSTRUCTION the newest row of this turn, so it
        // is never part of the shadowed prefix. Skipping it explicitly keeps the
        // greying loop from ever marking live output as compacted history, even
        // if a future insert index lands below it.
        let liveIdx = dshStreamingMsgIdx
        for above in 0..<insertIdx
        where above != liveIdx
            && messages[above].role != .compactDivider
            && messages[above].role != .systemInfo {
            messages[above].isCompactedHistory = true
        }
        AppLogger(category: "DSHLoop").warning(
            "[DSH] compaction divider at \(insertIdx)/\(messages.count) "
            + "lastShadowedSeq=\(outcome.range.shadowedSeqs.last.map { String($0.value) } ?? "nil") "
            + "liveRow=\(liveIdx) shadowedCalls=\(shadowedCallIds.count) "
            + "dimmedBlocks=\(compactedBlocks) "
            + "anchored=\(anchoredDivider ? "afterBlock\(compactedBlocks - 1)" : "none(barAboveLiveRow)")"
        )
        publishUnlessTransitioning()
        scrollToBottomSignal.send()
    }

    /// Tool-call ids the compaction's shadowed range contains.
    ///
    /// [F4-compaction-visibility] This is the exact handle on "which rendered
    /// blocks did the compaction replace". A session entry carries its tool calls
    /// (`DSHToolCallBlock.id`), the live row's blocks carry the id of the call each
    /// one rendered (`AssistantBlock.toolUseId`), and the compaction reports the
    /// seqs it shadowed — so the intersection is a fact rather than an estimate.
    /// Nothing on the UI row has to be trusted for it, which matters because a UI
    /// row carries no seq while its turn is running.
    static func dshShadowedCallIds(
        session: DSHSession?,
        shadowedSeqs: [DSHSeq]
    ) -> Set<String> {
        guard let session else { return [] }
        var ids: Set<String> = []
        for seq in shadowedSeqs {
            guard let entry = session.entry(at: seq) else { continue }
            for block in entry.message.blocks {
                if let call = block as? DSHToolCallBlock {
                    ids.insert(call.id)
                }
            }
        }
        return ids
    }

    /// How many of a live row's LEADING blocks the compaction covers.
    ///
    /// The shadowed range is a prefix of the session log, so if a block belonging
    /// to it is at index i, every block before i belongs to it too: the count is
    /// `lastShadowedToolBlockIndex + 1`, and no block after it is claimed (those
    /// may belong to the retained tail the model still sees verbatim).
    ///
    /// Blocks the shadowed range produced but that carry no tool call — the text
    /// and thinking around them — are covered by the same prefix rule whenever they
    /// precede a shadowed call, and left alone when they do not. That is the
    /// under-claim direction `DSHCompactBoundary` insists on: dimming a block the
    /// model can still read is the failure this refuses to make.
    static func dshCompactedBlockPrefixCount(
        liveBlocks: [AssistantBlock],
        shadowedCallIds: Set<String>
    ) -> Int {
        guard !shadowedCallIds.isEmpty else { return 0 }
        var last = -1
        for (idx, block) in liveBlocks.enumerated() {
            guard let callId = block.toolUseId, shadowedCallIds.contains(callId) else { continue }
            last = idx
        }
        return last + 1
    }

    /// Where the transcript divider goes for a compaction that shadowed
    /// everything up to `lastShadowedSeq`.
    ///
    /// The boundary is the first row whose session seq is NEWER than the newest
    /// shadowed one — i.e. the first row the compaction kept. Position is read from
    /// the seq and never from an index: `messages` is rebuilt by reload, retry and
    /// reconcile, so an index captured when the compaction landed would name a
    /// different row by the time it is used. This is the same reason every other
    /// DSH-side lookup goes through `dshSeq`.
    ///
    /// A row without a seq (a status row, a queued prompt) is not part of the
    /// session, so it can never be the boundary; it stays where it is.
    ///
    /// Falls back to the end of the list only when no seq at all names the
    /// boundary — an unresolvable position must not hide rows the model can still
    /// see.
    static func dshDividerInsertIndex(
        messages: [ChatMessage],
        lastShadowedSeq: Int?,
        liveStreamingRowId: UUID? = nil
    ) -> Int {
        guard let lastShadowedSeq else {
            return Self.dshDividerPosition(
                messages: messages, boundary: messages.count,
                liveStreamingRowId: liveStreamingRowId)
        }
        if let idx = messages.firstIndex(where: { ($0.dshSeq ?? Int.min) > lastShadowedSeq }) {
            return Self.dshDividerPosition(
                messages: messages, boundary: idx,
                liveStreamingRowId: liveStreamingRowId)
        }
        return Self.dshDividerPosition(
            messages: messages, boundary: messages.count,
            liveStreamingRowId: liveStreamingRowId)
    }

    /// Keep the divider ABOVE the row this turn is streaming into.
    ///
    /// [T-dsh-compact-divider-above-live-row] The seq boundary and the live row
    /// are different coordinate systems, and the live row has no seq at all:
    /// `sealStreamingTurn` is what stamps it, and that runs at the END of the
    /// turn. So `dshSeq` for the live row is nil (read as `Int.min`), the
    /// boundary search walks straight past it, and the divider lands BELOW it.
    ///
    /// The divider's whole job is to say "everything above me was replaced";
    /// leaving it below live output puts the newest content above the line,
    /// which is exactly what the operator reported ("所有新消息继续出现在压缩的
    /// 那条提示的线上方，看起来就像刚压缩完一点新消息没有"). The older
    /// append-to-`messages.count` shape had the same effect, which is what round
    /// 8 was fixing; this keeps the fix true for the row the turn is still
    /// writing into.
    ///
    /// Nothing is greyed by the move: the live row is never in the replacement
    /// region, because the compaction selected its range from a surface the live
    /// row had not been appended to yet.
    static func dshDividerPosition(
        messages: [ChatMessage],
        boundary: Int,
        liveStreamingRowId: UUID? = nil
    ) -> Int {
        guard let liveId = liveStreamingRowId else { return boundary }
        guard let liveIdx = messages.firstIndex(where: { $0.id == liveId }) else { return boundary }
        return min(boundary, liveIdx)
    }

    public func driver(_ driver: DSHTurnDriver, didEndTurn reason: DSHTurnEndReason) {
        AppLogger(category: "DSHLoop").info("[DSH] turn end reason=\(String(describing: reason))")
        // Final flush before sealing: this is the last chance to push the reply's
        // text, and it has to be marked as such so the list applies it even if it
        // was suspended while the text was arriving.
        dshCommitText(force: true, finalFlush: true)
        dshSealStreamingTurn()
        switch reason {
        case .completed, .concluded:
            break
        case .cancelled:
            handleUserCancelledCleanup()
        case .maxSteps:
            reportTurnFailure("Reached the step limit for this turn.")
        case .maxTokens:
            // Not a budget stop: the model's answer ran into the output limit.
            //
            // [P1-2] This reason used to be reported as `.maxSteps` — "Reached the
            // step limit for this turn" — which is the opposite of what happened:
            // the model did not fan out for too long, its answer was cut off mid
            // sentence. The two also need different words and different arms, and
            // the reply stays CONTINUABLE, so Resume is armed here, which is what
            // the legacy loop does for the same stop reason (`AIChatViewModel.swift`:
            // `stopReason == .maxTokens` → warn + `canResume = true`).
            //
            // [T-max-tokens-neutral-wording] The words changed, the semantics did
            // not. The old copy was "Response truncated (max tokens reached). Tap
            // Resume to continue." and the operator's report on it was 「对话的 agent
            // 总说什么被截断…感觉有点影响使用」 — a warning banner that reads as
            // damage, on a turn whose text is complete-to-the-point-it-stopped and
            // is already in the session (`session.append` above runs before the end
            // reason is chosen, so the half answer is durable and the next request
            // carries it). "Truncated" also names the wrong layer: since
            // [T-output-limit-three-hops] the cap is a number the app resolved and
            // the user can change, not a transport failure.
            //
            // The replacement states what happened, that nothing was lost, and the
            // one action that continues — and it is the SAME string the legacy loop
            // now uses, so the two loops cannot describe one event two ways.
            reportTurnFailure(AppLocalized("The reply reached this model's output limit. The text so far is kept — send a message to continue."))
            canResume = true
        }
    }

    public func driver(_ driver: DSHTurnDriver, didFail failure: DSHFailure) {
        AppLogger(category: "DSHLoop").error("[DSH] failure code=\(failure.code) \(failure.message)")
        dshCommitText(force: true)
        dshSealStreamingTurn()

        // Stop is a cancellation, not a failure.
        //
        // Cancelling the turn tears the provider stream down, and how that
        // surfaces is up to the provider — it can arrive here as a stream error.
        // The legacy loop's catch checks this same flag and runs the cancel
        // cleanup instead of showing an error; without the check a user pressing
        // Stop got an error banner for their own action.
        if userDidCancel {
            handleUserCancelledCleanup()
            return
        }
        reportTurnFailure(AIChatViewModel.friendlyErrorMessage(failure.message))
    }

    public func driver(_ driver: DSHTurnDriver, willRetryStreamAfter error: Error, attempt: Int, seconds: Int) {
        // Same feedback the legacy loop gives during its retry countdown: the
        // attempt number drives the "retrying in Ns" banner and the row shows
        // why the request did not go through.
        autoRetryAttempt = attempt
        if dshStreamingMsgIdx >= 0, dshStreamingMsgIdx < messages.count {
            let desc = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            messages[dshStreamingMsgIdx].error = desc
            publishUnlessTransitioning()
        }
        AppLogger(category: "DSHLoop").warning(
            "[DSH] retryable stream failure (\(error)) — attempt \(attempt) in \(seconds)s"
        )
    }

    public func driver(_ driver: DSHTurnDriver, streamRetryCountdown seconds: Int) {
        autoRetryCountdown = seconds
        guard seconds == 0 else { return }
        // The stream opened: clear the countdown and whatever the retry wrote
        // onto the row.
        autoRetryAttempt = 0
        if dshStreamingMsgIdx >= 0, dshStreamingMsgIdx < messages.count {
            messages[dshStreamingMsgIdx].error = nil
        }
    }

    // MARK: - Turn Sealing

    /// Close out the streaming assistant row: clear the awaiting flag, stamp
    /// usage, and force any tool block still in a non-terminal status into one.
    ///
    /// The force-close matters because a stream interruption can leave a block
    /// in `.streaming`, which renders as a permanently running tool.
    func dshSealStreamingTurn() {
        // Nothing may commit after this: the turn is over and the row is final.
        dshCancelTrailingTextFlush()
        guard dshStreamingMsgIdx >= 0, dshStreamingMsgIdx < messages.count else { return }
        let idx = dshStreamingMsgIdx
        messages[idx].isAwaitingModelResponse = false

        // The throttle holds the tail of the reasoning in an unpublished buffer,
        // so seal it here or the last second of thinking never appears.
        dshFlushThinkingSegment()
        dshThinkingBlockIdx = -1
        dshPendingReasoning = ""

        // Same for speech: the dynamic window holds a tail, and a turn that ends
        // on one short sentence would otherwise never speak it. Speech crosses to
        // the main actor, so it is handed off rather than awaited here.
        //
        // Then drop the text presenter's streaming state: the turn is over, and a
        // stale accumulator must not be able to write into this row again.
        if let presenter = dshTextPresenter {
            Task { await presenter.sealSpeech() }
            presenter.reset()
        }

        for i in messages[idx].blocks.indices {
            switch messages[idx].blocks[i].toolStatus {
            case .streaming, .running:
                messages[idx].blocks[i].toolStatus = .cancelled
            case .success, .failed, .cancelled, .none:
                break
            }
        }
        // Resolve the driver's committed seq for this row, so a later array
        // rebuild can find it.
        let surface = dshSession?.surface() ?? []
        if let seq = surface.last(where: { $0.message.role == .assistant })?.seq.value {
            messages[idx].dshSeq = seq
        }

        // Stamp the turn's usage on the row.
        //
        // The legacy loop does this at the end of every turn, and
        // `sessionTokenStats.context` reads it back out of the rows — so without
        // it the sheet's "Context Used" was 0 for a live session and every
        // per-row readout stayed blank until a reload merged usage from the
        // database. `dshTurnUsage` is a value type with a zero default, so this
        // only stamps when the driver actually reported something.
        if dshTurnUsage.inputTokens > 0 || dshTurnUsage.outputTokens > 0 {
            messages[idx].usage = minisTokenUsage(dshTurnUsage)
        }
        dshLastUsageAt = nil

        // Text accounting.
        //
        // The operator reports words missing from the rendered reply — sentences
        // arriving as only their tail. Nothing in the app compares the text the
        // model actually produced against the text the row ended up holding, so
        // there is no way to tell "the model said that" from "that got lost".
        // These two numbers do: `model` is every character the driver emitted this
        // turn, `row` is every character the row's text blocks hold. A gap is text
        // the user cannot see, and its size says whether a chunk or a whole block
        // went missing.
        let textBlockCount = messages[idx].blocks.filter { $0.kind == .text }.count
        let rowTextLength = messages[idx].blocks
            .filter { $0.kind == .text }
            .reduce(0) { $0 + $1.content.count }
        AppLogger(category: "DSHLoop").warning(
            "[DSH] text accounting: model=\(dshTurnTextTotal) row=\(rowTextLength) "
            + "gap=\(dshTurnTextTotal - rowTextLength) textBlocks=\(textBlockCount) "
            + "allBlocks=\(messages[idx].blocks.count)"
        )

        publishUnlessTransitioning()
    }
}
