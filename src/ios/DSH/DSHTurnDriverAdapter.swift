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
            messages: messages, lastShadowedSeq: outcome.range.shadowedSeqs.last?.value
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
        messages.insert(row, at: insertIdx)
        for above in 0..<insertIdx
        where messages[above].role != .compactDivider && messages[above].role != .systemInfo {
            messages[above].isCompactedHistory = true
        }
        AppLogger(category: "DSHLoop").warning(
            "[DSH] compaction divider at \(insertIdx)/\(messages.count) "
            + "lastShadowedSeq=\(outcome.range.shadowedSeqs.last.map { String($0.value) } ?? "nil")"
        )
        publishUnlessTransitioning()
        scrollToBottomSignal.send()
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
    static func dshDividerInsertIndex(messages: [ChatMessage], lastShadowedSeq: Int?) -> Int {
        guard let lastShadowedSeq else { return messages.count }
        if let idx = messages.firstIndex(where: { ($0.dshSeq ?? Int.min) > lastShadowedSeq }) {
            return idx
        }
        return messages.count
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
        if dshThinkingBlockIdx >= 0, dshThinkingBlockIdx < messages[idx].blocks.count {
            messages[idx].blocks[dshThinkingBlockIdx].flushThinkingBuffer()
        }
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
