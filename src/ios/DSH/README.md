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
TTS, and the UI. These are deeply coupled to UIKit and to the
existing `ChatStore`, and the DSH port has no equivalent to replace them with.

NOT retained, despite what this file said until an audit caught it: **group
fallback**. The legacy loop catches a fallbackable provider error inside itself,
advances to the next member of the model group, rebuilds the prompt and inserts a
"switched to X" row. The driver talks only to the provider it was constructed
with, so a rate-limited or broken primary fails the turn instead of silently
advancing. See the known-gaps section of `docs/DSH-ARCHITECTURE.md`.

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
| `DSHSpill.swift` | `packages/spill/spill-policy/src/{index,retention,notice}.ts` |
| `DSHSpillStore.swift` | `packages/spill/spill-local/src/{index,store,cleanup}.ts` |
| `DSHSpillHook.swift` | — the `tools/post-execute` seam, wired to the tool scheduler |

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

## Tool-result spill

A tool result too large to be worth its tokens is written to a file in full, the
conversation keeps only its head and tail, and a notice says how many bytes went
overlooked and where the whole thing now lives:

```
line 1: …
line 271: the quick brown fox …

[...]

line 1120: …
line 3121: the quick brown fox …

(Omitted 55279 bytes. Full formatted result stored at:
/var/minis/offloads/dsh-spill/session-1a2b3c4d5e6f/9f3c1a2b-shell_execute.txt.
Use file_read with offset/limit, or a shell_execute grep on this path to search
within it.)
```

Ported semantics, unchanged from DSH: read results are never spilled (the
notice tells the model to read the file back, so spilling that read would make
recovery lossy); only text and image content is handled; the unit is TOKENS, not
characters; the budget splits evenly between head and tail; an image is
indivisible and is dropped whole when it does not fit; `\n\n[...]\n\n` marks the
elision; and the notice wording is fixed.

**Where the file goes.** The session's existing offload bucket:
`/var/minis/offloads/dsh-spill/session-<sha256(sessionId)[0:12]>/<random>-<tool>.txt`.
That path is what makes the notice's "use file_read with offset/limit, or a
shell_execute grep on this path" true — `/var/minis/offloads` is bind-mounted onto
the session's persistent `offloads` directory, it is documented to the model in
the app's own system prompt, `file_read` and `read_image` resolve it, and a
`shell_execute` grep sees the same bytes. Nothing new is mounted and no new tool
is added.

**The tool names in that sentence are this app's.** DSH spells them `read` and
`grep`; this app has neither — its read tool is `file_read` and it has no grep
tool at all. Both the notice and `exemptTools` therefore name `file_read`, because
a notice that instructs the model to use a tool that does not exist is worse than
one that says nothing, and an exemption keyed on a name no tool carries silently
does nothing. Measured on a device 2026-10-17: with DSH's `read` in `exemptTools`,
a spilled result was read back with `file_read`, that read was spilled in turn,
and the model burned a turn reading spill files instead of answering.

**Off by default.** The budget is `maxInlineTokens`, its absence is the off
switch (DSH's own rule for this plugin), and the shipped DSH value is 12 500.
The value is read from `UserDefaults` key `minis.dshSpillMaxInlineTokens`; unset,
non-numeric, zero or negative all leave the feature inert, and the hook is then
never installed, so the tool path takes no branch. Note the caveat above about
injecting defaults from outside the app.

**Two ways to turn it on.** `DSHSpillSettingsView` — Settings → Agent Runtime →
"Tool Result Spill" — is the switch a person can reach: on/off, the budget in
tokens, the cleanup window, and a readout of the budget actually in force. It
writes through `DSHSpillConfig.setEnabled`, so the "absent or non-positive means
off" rule stays in one place. The settings screen exists because the other way in
is unreachable: an external write to the plist is discarded at launch, so before
it there was no switch at all.

The second way is the compile-time probe, `#if DSH_SPILL_PROBE`, in the same
spirit as `dshCompactionProbeEnabled`. A probe build forces a 600-token budget,
ignores whatever is stored, logs the fact when the hook is installed, and is
renamed `-probe` and never published. CI exposes it as the `spill_probe`
workflow_dispatch input. It is a compilation condition rather than a runtime key
for the same reason the compaction probe is: the app rewrites its own plist.

**The retention decision is pure** and lives in `DSHSpill.swift` free of UIKit
and file I/O, so it can be exercised without a device:
`_tools/dsh-spill-selftest.swift` is generated from the shipped file by
`_tools/sync-dsh-spill-selftest.ps1` and run on a real Swift toolchain by
`_tools/run-dsh-spill-selftest.ps1`.

## Compaction rule

Matches DSH's `selectCompactableRange`:

1. A `system` message at surface node 0 is never inside the range.
2. Walk the surface backwards accumulating token cost until the retained tail
   reaches `retainTokens`.
3. Walk the cut back to a tool-pairing balanced position.
4. Shadow the resulting range with one summary entry, and only when the summary
   actually costs less than what it replaces.

The threshold is 80% of the serving model's context window. An unknown window
disables automatic compaction rather than compacting on a guess — compacting
away the live request is worse than running long.

## Compaction verified on device

The probe (`dshCompactionProbeEnabled`) lowers the thresholds so a realistic
conversation trips compaction without filling a 262k window. With it on, one
turn on the iPhone 13 produced:

| | Before | After |
|---|---|---|
| Surface entries | 18 | **9** |
| Estimated tokens | 2026 | **1330** |

Nine earlier entries were shadowed into one summary — a 34% reduction — and the
`shell_execute` call in that same turn still completed, with the model answering
correctly from the summary afterwards. The probe ships `false`.

Selection was also probed independently over synthetic surfaces (Python port of
the same rule, `_testdata/compaction_probe.py`):

| Surface | Result |
|---|---|
| Long tool output (20 × 20k-char results) | 94% smaller, boundaries balanced |
| Image blocks | 73% smaller, boundaries balanced |
| Barely over pressure | 45% smaller, boundaries balanced |
| Retain budget larger than the surface | correctly declines |
| Session too small | correctly declines |
| No system head | correctly declines |

Every accepted cut was tool-pairing balanced, so a compaction cannot strand a
tool call from its result.

## Two device-only facts worth knowing

**External `UserDefaults` injection does not work.** The app registers its own
defaults dictionary at launch and rewrites the whole plist, so a key written
from outside is discarded. Test thresholds therefore have to be compile-time.

**The app's own logs are not reachable.** `get_syslog` does not carry its NSLog
output and the on-disk log keeps only the last 20 lines. Diagnostics that need
to be observed go into the transcript as rows.

## Wiring

`DSHTurnDriver` is wired in. `AIChatViewModel.runDSHTurn()` builds the registry,
prompt, and session, then drives the turn; `runAgentLoop()`'s call sites branch
on `AIChatViewModel.useDSHAgentLoop` (default true) so the original loop is
still reachable for A/B comparison.

The driver owns the five core segments. `AIChatViewModel` keeps streaming
presentation, persistence, image budgeting, queued prompts,
cancel cleanup, TTS, and the UI — but **not** group fallback: that one is a
genuine gap, not a retained part.

Identity: `ChatMessage.dshSeq` carries the session seq the row was projected
from, so the streaming target is resolved by seq rather than by array index.

Tool blocks are created on `willRunTool` and filled on `didFinishTool`, matched
by call id, so a block appended by another path cannot steal the result.
`DSHToolBlockKind` maps a tool name plus arguments onto the block kind that
renders it.

## Verified on device

iPhone 13 / iOS 15.3.1, installed via ios-mcp over AppSync Unified. A single
turn exercising all five tools produced real results:

| Tool | Observed |
|---|---|
| `shell_execute` | `DSH_TOOL_TEST_OK` |
| `file_write` | `Wrote to /root/dsh_verify.txt (5 bytes)` |
| `file_read` | `[/root/dsh_verify.txt \| 5 bytes \| 1 lines \| showing lines 1-1 of 1]` |
| `file_edit` | `Edited /root/dsh_verify.txt (1 replacement, 6 bytes)` |
| `file_read` | `[/root/dsh_verify.txt \| 6 bytes \| 1 lines ...]` + content `SECOND` |

The byte-count change (5 → 6) confirms the edit landed rather than being
narrated.

## Not ported

Cordis service/plugin infrastructure, the durable session log format, session
projections, subagent spawning, and the workflow tool are Node-side facilities
with no iOS equivalent here. The loop, prompt assembly, tool registry, scheduler,
session surface, and compaction are the parts that change agent behaviour.
