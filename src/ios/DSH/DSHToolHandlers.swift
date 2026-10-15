//
//  DSHToolHandlers.swift
//  Minis
//
//  Builds the DSH tool registry for one turn.
//
//  The roster is Minis'. `makeAgentTools()` decides which tools exist — its
//  gating reads the memory toggle, the settings switches, the configured Vision
//  Group and the sub-agent switch — and this file turns that list into DSH
//  tools, adding the one thing Minis has no opinion about: each tool's declared
//  concurrency class.
//
//  Execution is not reimplemented either. Every tool routes through Minis'
//  own `executeSingleToolUse`, which is the complete implementation: streaming
//  output into the block, image budgets, output truncation and offload, the loop
//  detector, argument preflight, tool snapshots. The DSH layer decides *when* a
//  call runs and *in what order* its result is committed; it does not decide
//  what the call does.
//

import Foundation

extension AIChatViewModel {

    /// The DSH tool registry for one turn.
    ///
    /// - Parameters:
    ///   - definitions: the roster for this turn, from `makeAgentTools()`.
    ///   - batchBudget: shared image-slot budget for the turn. One budget per
    ///     turn, as the original loop has it, so concurrent `read_image` calls
    ///     cannot collectively exceed the context image cap.
    func dshAgentRegistry(
        definitions: [AgentToolDefinition],
        batchBudget: BatchImageBudget
    ) -> [DSHTool] {
        definitions.map { definition in
            DSHMinisTools.make(
                from: definition,
                executionMode: DSHToolDispatch.mode(for: definition.name)
            ) { [weak self] arguments, context in
                guard let self else {
                    return DSHToolExecutionResult.error("view model released")
                }
                return await self.dshExecuteMinisTool(
                    name: definition.name,
                    callId: context.callId,
                    arguments: arguments,
                    definitions: definitions,
                    batchBudget: batchBudget
                )
            }
        }
    }
}
