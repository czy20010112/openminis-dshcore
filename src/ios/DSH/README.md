//
//  README.md
//  Minis
//

# DSH Agent Framework (iOS port)

A Swift port of the DeepSeek Harness agent framework core, wired into Minis.

## What is replaced

| Layer | Status | Mechanism |
|---|---|---|
| System prompt | replaced | `dshSystemPrompt` — ordered section assembly |
| Tool schemas | replaced | `dshAgentTools()` — DSH registry + typed JSON Schema |
| Tool scheduling | replaced | `DSHToolScheduler` — declared concurrency, model-order commit |
| Loop guard | replaced | `DSHToolGate` — runs before dispatch |
| Conversation identity | replaced | `DSHSession` — append-only log, branded seq, derived surface |
| Compaction | replaced | `DSHCompaction` — DSH selection rule + shadow replacement |
| Turn driving | available | `DSHTurnDriver` — full replacement loop, not yet wired into the UI |

Retained from OpenMinis: streaming presentation, persistence, image budgeting,
group fallback, TTS, and the UI. These are deeply coupled to UIKit and to the
existing `ChatStore`, and the DSH port has no equivalent to replace them with.

## Files

| File | Ported from |
|---|---|
| `DSHTypes.swift` | `packages/llm/llm/src/types.ts` |
| `DSHSystemPrompt.swift` | `packages/core/system-prompt/src/index.ts` |
| `DSHToolRegistry.swift` | `packages/core/tools/src/index.ts` |
| `DSHToolScheduler.swift` | `packages/core/agent-loop/src/tool-calls.ts` |
| `DSHToolGate.swift` | repeat-tool reminder + scheduler guards |
| `DSHSession.swift` | `packages/session` — surface nodes, replace semantics |
| `DSHCompaction.swift` | `packages/compaction/compaction-basic/src/region.ts` |
| `DSHTurnDriver.swift` | `packages/core/agent-loop/src/agent.ts` |
| `DSHJSONSchema.swift` | `packages/core/tools/src/json-schema.ts` |
| `DSHToolSchemaBridge.swift` | — DSH schema → `AgentToolDefinition` |
| `DSHToolDispatchBridge.swift` | — Minis concurrency policy |
| `DSHMinisPrompt.swift` | — Minis prompt sections |
| `DSHMinisTools.swift` | — Minis tool schemas |
| `DSHPromptAdapter.swift` | — supplies the prompt and tool set to the loop |

## Why the session model changed

OpenMinis addressed conversation entries by bare `Int` index into a mutable
array. Every mid-turn mutation — compaction's divider insert, an iCloud sync's
wholesale rebuild, a user delete — invalidated every index a running loop held.
The failure was quiet: the loop kept streaming into a detached `ChatMessage`, so
the UI froze while the database advanced.

The accumulated fix was a resync at every subscript site. Each is individually
correct; collectively they mean a new array mutation needs a new resync
everywhere it could be observed.

`DSHSession` removes the class of bug instead:

- The log is append-only; entries are never moved, replaced, or removed.
- Every entry carries a monotonic `DSHSeq`, a dedicated type so it cannot be
  passed where an array offset is expected.
- Compaction appends a summary that SHADOWS a positional range. The surface is
  the log read through the current shadow set, so a running loop holding seqs
  still sees the same entries.
- Cut positions are validated for tool-pairing balance, so a compaction cannot
  strand a tool call without its result — the provider-level 400 that OpenMinis
  patched with a separate pre-send orphan scan.

## Concurrency is declared, not assumed

OpenMinis' dispatch treated every tool as parallel-eligible with an in-flight
cap, then stitched results back by dispatch index. An index that never harvested
left its slot empty, and every read needed a `guard let ... else { continue }`
that silently dropped the result.

`DSHToolScheduler` states the property as data: each tool declares `.exclusive`
or `.parallel`. Exclusive calls form a barrier; parallel calls run in a bounded
pool. The committer advances only across contiguous settled slots, so results
land in model order by construction and there is no index to lose.

The guard runs before dispatch, so a repeated no-progress call never executes
and the model receives the reason as the tool result.

## Compaction rule

Matches DSH's `selectCompactableRange`:

1. A `system` message at surface node 0 is never inside the range.
2. Walk the surface backwards accumulating token cost until the retained tail
   reaches `retainTokens`.
3. Walk the cut back to a tool-pairing balanced position.
4. Shadow the resulting range with one summary entry, and only when the summary
   actually costs less than what it replaces.

## Wiring

`DSHTurnDriver` is the full replacement loop. It is complete and compiles, but
the UI still drives `AIChatViewModel.runAgentLoop()`. Connecting the driver means
adapting its delegate onto the streaming presentation layer, which is the
remaining work.

`AIChatViewModel.useDSHAgentLoop` (default true) toggles the DSH-assembled
prompt and tool set against the originals for A/B comparison.

## Not ported

Cordis service/plugin infrastructure, the durable session log format, session
projections, subagent spawning, and the workflow tool are Node-side facilities
with no iOS equivalent here. The loop, prompt assembly, tool registry, scheduler,
session surface, and compaction are the parts that change agent behaviour.
