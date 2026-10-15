//
//  DSHToolHandlerImpl.swift
//  Minis
//
//  Runs one DSH tool call through Minis' own tool executor.
//
//  This file used to reimplement each tool: read the fields it knew about out of
//  the argument dictionary, call a lower-level helper, return the text. That is
//  how `file_read` lost `offset`/`lines`/`direction`/`max_length`, `file_write`
//  lost `create_dirs`, `shell_execute` lost `delay`, and `read_image` returned a
//  file-size string instead of an image — the schema kept advertising all of it
//  while the adapter quietly dropped it. It also lost everything that lives
//  *around* a call: output truncation and offload, the per-turn image budget,
//  the loop detector, argument preflight, and the tool snapshot that media
//  persistence reads.
//
//  None of that is reimplemented now. `executeSingleToolUse` is Minis' complete
//  per-call implementation, and this adapter supplies the three things it needs
//  from the DSH side and cannot know: the row it is working in, the block that
//  call created, and the turn's shared image budget.
//

import Foundation

extension AIChatViewModel {

    /// Execute one DSH tool call through Minis' tool executor.
    ///
    /// - Parameters:
    ///   - name: the tool being called.
    ///   - callId: the provider-side call id, which is also how the UI block is
    ///     found.
    ///   - arguments: the parsed arguments, forwarded verbatim.
    ///   - definitions: this turn's roster, which `executeSingleToolUse` uses
    ///     for argument preflight.
    ///   - batchBudget: the turn's shared image-slot budget.
    func dshExecuteMinisTool(
        name: String,
        callId: String,
        arguments: [String: Any],
        definitions: [AgentToolDefinition],
        batchBudget: BatchImageBudget
    ) async -> DSHToolExecutionResult {
        guard dshStreamingMsgIdx >= 0, dshStreamingMsgIdx < messages.count else {
            return DSHToolExecutionResult.error("no streaming assistant row to attach the result to")
        }
        let msgIdx = dshStreamingMsgIdx

        // The block for this call was created when the driver announced the
        // call, so that the user sees it while it runs. Find it by call id —
        // position is a hint, the id is the identity — and fall back to the
        // recorded position.
        let blockIdx = messages[msgIdx].blocks.firstIndex(where: { $0.toolUseId == callId })
            ?? dshToolBlockIndex[callId]
        guard let blockIdx else {
            return DSHToolExecutionResult.error("no transcript block for call \(callId)")
        }

        // `inputChunkRing` is empty: it carries the streamed argument fragments
        // for the preflight validator's failure dump, and the DSH driver hands
        // the tool layer a fully parsed dictionary rather than deltas.
        let entry = StreamResult.ToolEntry(
            id: callId,
            name: name,
            args: arguments,
            blockIdx: blockIdx,
            metadata: nil,
            inputChunkRing: []
        )

        let outcome = await executeSingleToolUse(
            tu: entry,
            msgIdx: msgIdx,
            tools: definitions,
            batchBudget: batchBudget
        )

        // Media the tool produced has to survive into persistence, which reads
        // it from these two collections.
        if let snapshotEntry = outcome.snapshotEntry {
            dshPendingSnapshots[outcome.toolId] = snapshotEntry
        }
        if let snapshotItem = outcome.snapshotItem {
            toolSnapshots.append(snapshotItem)
        }

        if let result = DSHSessionProjection.toolExecutionResult(from: outcome.resultPart) {
            return result
        }
        return DSHToolExecutionResult.error("tool produced no result part")
    }
}
