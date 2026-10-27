# mini-dsh

**OpenMinis with its agent core replaced by [DeepSeek Harness](https://github.com/deepseek-ai) (DSH)** — the app, its tools and its UI stay; the loop that decides what to do next is DSH's.

> **This is a modified version of OpenMinis** (GPL-3.0 §5(a)). Last modified: **2026-10-28**.
> Upstream: [OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis). This repository is not
> affiliated with the upstream project and does not speak for it; the upstream name and icon are
> not covered by the code licence and remain with their authors.

The original loop is one large file: request assembly, tool scheduling, retries, compaction and
persistence all in one place. This fork moves the **decision core** to DSH's layered packages
(agent / agent-loop / system-prompt / tools / llm / compaction / session) and leaves **every tool
handler untouched** — each tool still calls OpenMinis' own implementation. The original loop is one
flag away: `AIChatViewModel.useDSHAgentLoop` (`minis.useDSHAgentLoop`, default `true`).

## Two lines, one pipeline

| | iOS 26 line (default) | iOS 15 line |
|---|---|---|
| Branch | **`main`** | **`ios15`** |
| Baseline | [OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis) v1.14, deployment target 16.2 | [zhaoxiufei/OpenMinis](https://github.com/zhaoxiufei/OpenMinis), deployment target 15.0 |
| CI runner | `macos-26` / Xcode 26 | `macos-14` / Xcode 16 |
| Extensions | all kept, each signed individually | AgentWidget / MinisShare dropped |

`src/ios/DSH/**` is **byte-identical on both branches**, with exactly two exceptions —
`DSHTurnDriver.swift` (adapts the `.responseModel` enum) and `DSHTurnDriverBridge.swift` (tool-block
tuple arity). Change the core once and both lines get it.

## What it does

### A conversation on the phone

- **Full agent loop** — tools, skills, memory, sub-agents, MCP servers, browser use, a Linux shell on
  the device, group fallback, TTS, voice input: all of OpenMinis' tooling, unchanged.
- **Compaction that survives a relaunch** — the boundary is persisted, so a restarted app still knows
  where the conversation was cut and why the history above it is dimmed.
- **Thinking blocks keep their place** — reasoning is rendered where it arrived, so
  `thinking → tool → thinking → text` interleaves as it happened instead of collapsing to the top.
- **A context panel that says what it measured** — system prompt / tool definitions / conversation /
  total, with the provider's own cache-hit rate when the provider reports cache buckets, and an
  explicit "not reported" instead of a zero when it does not.

### A conversation on a paired computer

Pair the phone with a computer running the DS Bot bridge and DSH sessions on that machine become
readable and writable from the phone.

- **The transcript is the same transcript** — user words stay bubbles, model switches and injected
  context become thin status rows, and rows measure themselves before the list lays them out.
- **It keeps up** — a 15 s silence raises a thin banner, 30 s closes and reopens the stream. An idle
  page probes once a minute. A revoked pairing says so and stops, instead of reconnecting forever.
- **It opens fast** — the transcript is mirrored locally (records only, never goals or todos) and
  painted before the network answers; the host is then asked only for what came after the cached
  cursor, and says whether it resumed or resent the whole page.
- **The composer behaves like the local one** — send, stop, `/` commands with `→ PC` / `Local`
  badges, arrow-key navigation on a hardware keyboard, the same context panel, and goal/todo panels
  above the composer.
- **Work can be dispatched** — `remote_team_spawn` / `_message` / `_list` / `_output` / `_interrupt`
  drive the computer's real Agent Team: named, messageable, interruptible teammates that keep their
  context, not one-shot subagents.

### Wide screens

iPad and landscape cap the conversation column at 900 pt and centre it, exactly like the local page —
the transcript, the status rows, the goal/todo panels and the composer all sit in that column.

## Downloads

Each build publishes its own release; the tag is the build number.

```bash
gh release list --repo czy20010112/openminis-dshcore --limit 5
gh release download <tag> --repo czy20010112/openminis-dshcore
```

The IPA names carry the line: `MinisDSH-ios15-*` (iOS 15.0+) and `MinisDSH-ios26-*` (iOS 16.2+, the
extension needs 16.2). They are **ad-hoc signed**, deepest first. Install with
`ios-mcp` (`POST /upload_file`, then `install_app`) on a jailbroken device with AppSync Unified, or
with TrollStore / Sideloadly. **Do not re-sign the bundle yourself**: the App Group entitlement is
easy to lose, and a missing one crashes the app on launch.

Identity: bundle id `com.openminis.minidsh`, App Group `group.com.openminis.minidsh` — deliberately
distinct from official OpenMinis so the two can coexist.

## Privacy

- **No telemetry.** Nothing is sent anywhere except the model providers you configure and the
  computer you pair.
- Pairing is one phone to one computer. Access and refresh tokens live in the Keychain and refresh
  rotates them; unpairing deletes them and the local transcript mirror.
- Provider keys and web-search keys live in the Keychain, not in `UserDefaults` or an iCloud backup.
- The transcript mirror is excluded from backup, and shipped logs do not print the paired host or its
  server id.

## Architecture notes

**[docs/DSH-ARCHITECTURE.md](docs/DSH-ARCHITECTURE.md)** — ten diagrams plus a before/after per
change: what the original loop did, what the DSH turn does instead, and the root cause of each
difference. Its §8 keeps the running "fixed / not fixed" tables, including the defect pattern that
recurred most often: *the original loop did something the DSH turn forgot to do*.

## Building

Pushing to `main` or `ios15` triggers `.github/workflows/build-ipa.yml`: each line checks out its own
branch, builds, signs ad-hoc (framework → appex → app), packages, and a publish job merges the two
into one release.

A one-off probe build (compaction threshold lowered so compaction is easy to trigger on a device):

```bash
gh workflow run build-ipa.yml \
  -f compaction_probe=true -f build_ios26=false -f create_release=false
```

Probe artefacts carry a `-probe` suffix and the publish job refuses them.

## Known gaps

- **Group fallback is not wired into the DSH turn** — a rate-limited primary member fails loudly
  instead of silently switching, because that needs a second provider to test.
- **A second turn can start while the previous one settles** (queue versus interrupt is a product
  decision, not implemented).
- `waitForAny` drains a tool batch rather than waking on the first completion; the latency is real and
  documented in the code.
- **An occasional overlap in local conversations is unverified, not fixed.** Two overlap defects were
  closed by measurement (a bubble painting over the body after a send, and misalignment after
  collapsing a thinking block). The third — reported as occasional, in ordinary local chats — is a
  static-state defect, and a probe that samples after a transition cannot see one: a cell's height
  comes from the layout attribute it was handed, so the two numbers agree exactly when both are
  wrong. A resting-state instrument exists and, across four trigger edges (scroll,
  background/foreground, session switch, idle) found no clipping and no unresolved mismatch. To
  reproduce it you need a long conversation containing single-line truncated tool rows, scrolled
  until one is visible; a screen of wrapped rows held still produces nothing.
- **Switching a model from the phone also changes the paired computer's default model**, and can
  drop that profile's thinking effort. That is the host's own semantics — it exposes no
  session-only entry point — so the app states the consequence rather than pretending otherwise.
- **"Five minutes with no stream activity after a pairing is revoked" is not yet verified.** Device
  logs cannot settle it: the panel sleeps, iOS suspends the app, and a suspended app logs exactly
  like a correctly dead client. The observation belongs on the host, which sees every request and
  whose clock ignores a sleeping phone; that check is written but needs a host restart to run.
- **Keyboard navigation on iOS 15/16 is verified only in parts.** The wiring is covered by tests
  (both arrows registered, both taking priority, both falling back to cursor movement, both
  declining when no menu is open), and `↓` / `Return` / dismiss were confirmed on a device. Whether
  iOS 15/16 actually delivers the up-arrow key event cannot be tested without a matching simulator
  runtime.

## Upstream and licence

This project is a derivative of [OpenMinis](https://github.com/OpenMinis/OpenMinis), under the
upstream **GPL-3.0** licence (see [LICENSE](LICENSE)).

Under GPL-3.0: the source ships with the binaries (this repository is that source), the original
authors' copyright notices are kept, and the modification is declared above with its date. GPL-3.0
does **not** grant trademark rights — the upstream project name and icon stay with their authors and
are not licensed with the code. Removing or replacing those brand elements is a modification the
licence allows; claiming to be the official project is not.

The upstream README no longer applies. Its text and copyright belong to the upstream authors. This
repository changes the agent core, the remote-session capability and the build pipeline; it does not
change any tool implementation.
