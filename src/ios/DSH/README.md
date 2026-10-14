//
//  DSHModule.md
//  Minis
//

# DSH Agent Framework (iOS port)

A Swift port of the DeepSeek Harness agent framework core, wired into Minis'
existing chat loop.

## What this replaces

`AIChatViewModel.runAgentLoop()` keeps its streaming, persistence, image
budgeting, compaction, group fallback, and UI — all heavily patched and
load-bearing. What this module replaces is the two inputs that decide how well
the agent works:

| Input | Before | After |
|---|---|---|
| System prompt | one concatenated string built at the call site | ordered DSH section assembly |
| Tool set | hand-written `AgentToolDefinition` literals | DSH registry + typed schema builder |

Set `AIChatViewModel.useDSHAgentLoop = false` to fall back to the original
prompt and tool list for A/B comparison on the device.

## Files

| File | Ported from | Role |
|---|---|---|
| `DSHTypes.swift` | `packages/llm/llm/src/types.ts` | provider-neutral message, block, finish, usage vocabulary |
| `DSHSystemPrompt.swift` | `packages/core/system-prompt/src/index.ts` | ordered section registry, dynamic context, tool ordering, `{{variable}}` interpolation |
| `DSHToolRegistry.swift` | `packages/core/tools/src/index.ts` | tool registry, execution modes, argument parsing, cancellation |
| `DSHToolScheduler.swift` | `packages/core/agent-loop/src/tool-calls.ts` | barrier/pool scheduling, results committed in model order |
| `DSHAgentLoop.swift` | `packages/core/agent-loop/src/agent.ts` | the loop: per-step request derivation, streaming, tool dispatch, loop guard |
| `DSHJSONSchema.swift` | `packages/core/tools/src/json-schema.ts` | typed JSON Schema builder |
| `DSHMinisPrompt.swift` | — | Minis-specific prompt sections and runtime context |
| `DSHMinisTools.swift` | — | Minis tool schemas |
| `DSHToolSchemaBridge.swift` | — | DSH schema → `AgentToolDefinition` (the provider seam) |
| `DSHPromptAdapter.swift` | — | supplies `dshSystemPrompt` / `dshAgentTools()` to the loop |
| `DSHAgentRuntime.swift` | — | composition root |

## Behavioural differences from the original loop

1. **Ordered prompt assembly.** Every contribution declares a placement
   (`DSHSectionOrder`) instead of appending. A new capability cannot silently
   push core guidance out of the prompt, and the assembled result is identical
   on every run.

2. **Runtime context snapshot.** Model, provider, sandbox root, session, memory
   state, and the live tool list are folded into each request, so the model
   does not have to guess at its own environment.

3. **Declared concurrency.** Each tool declares `.exclusive` or `.parallel`.
   Exclusive calls form a barrier; parallel calls run in a bounded pool. Calls
   are reclassified at scheduling time, so a registry change creates a barrier
   for calls that have not started.

4. **Model-order results.** Results commit in the order the model asked for
   them, regardless of which call finished first. The conversation the model
   sees next always matches its own request order.

5. **Pre-execution loop guard.** Repeated identical calls are blocked *before*
   they fire, with a concrete reason returned as the tool result, instead of
   only being noticed after several wasted rounds.

6. **Derived requests.** Every step's request is rebuilt from the conversation
   plus the current assembly. Nothing is carried across steps except the
   conversation itself.

## Build

The DSH directory is an Xcode `PBXFileSystemSynchronizedRootGroup` on the
`Minis` target, so files added there compile without editing `project.pbxproj`.

## Not ported

Cordis service/plugin infrastructure, the durable session log, session
projections, subagent spawning, and the workflow tool are Node-side facilities
with no iOS equivalent in this app. The loop, prompt assembly, tool registry,
and scheduler are the parts that change agent behaviour.
