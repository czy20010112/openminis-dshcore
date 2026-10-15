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

        // Append to the trailing text block, mirroring how the provider stream
        // was folded before. Markdown parsing stays off the main thread and the
        // flush stays throttled — that machinery is unchanged.
        var blocks = messages[idx].blocks
        if let last = blocks.indices.last, blocks[last].kind == .text {
            blocks[last].content += text
        } else {
            blocks.append(AssistantBlock(kind: .text, content: text))
        }
        messages[idx].blocks = blocks
        dshPendingText += text
        dshMaybeFlushText()
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

        // A tool call ends the current reasoning segment.
        dshThinkingBlockIdx = -1

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
    }

    public func driver(_ driver: DSHTurnDriver, didCompact outcome: DSHCompactionOutcome) {
        AppLogger(category: "DSHLoop").warning(
            "[DSH] compacted \(outcome.range.shadowedSeqs.count) entries, "
            + "\(outcome.beforeTokens) -> \(outcome.afterTokens) tokens "
            + "(shrink \(Int(outcome.shrinkRatio * 100))%)"
        )
        dshLastCompaction = outcome

        // Surface the compaction in the transcript. A silent context rewrite is
        // indistinguishable from the model forgetting, so the row says what was
        // replaced and what it cost.
        //
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
        messages.append(row)
        publishUnlessTransitioning()
        scrollToBottomSignal.send()
    }

    public func driver(_ driver: DSHTurnDriver, didEndTurn reason: DSHTurnEndReason) {
        AppLogger(category: "DSHLoop").info("[DSH] turn end reason=\(String(describing: reason))")
        dshFlushPendingText()
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
        dshFlushPendingText()
        dshSealStreamingTurn()
        reportTurnFailure(AIChatViewModel.friendlyErrorMessage(failure.message))
    }

    // MARK: - Turn Sealing

    /// Close out the streaming assistant row: clear the awaiting flag, stamp
    /// usage, and force any tool block still in a non-terminal status into one.
    ///
    /// The force-close matters because a stream interruption can leave a block
    /// in `.streaming`, which renders as a permanently running tool.
    func dshSealStreamingTurn() {
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
        publishUnlessTransitioning()
    }
}
