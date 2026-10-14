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
        // Reasoning is rendered by the existing thinking-block path; the driver
        // reports it, it does not own its presentation.
        dshPendingReasoning += text
    }

    public func driver(
        _ driver: DSHTurnDriver,
        willRunTool name: String,
        callId: String,
        arguments: [String: Any]
    ) {
        AppLogger(category: "DSHLoop").info("[DSH] tool start \(name) id=\(callId.prefix(20))")
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
