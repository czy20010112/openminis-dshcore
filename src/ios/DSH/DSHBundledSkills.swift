//
//  DSHBundledSkills.swift
//  Minis
//
//  SKILL.md bodies and bundled files for the DSH workflow skills that ship
//  inside the app binary. SkillStore.installBundledSkills() imports each body
//  through importSkill(_:source: .bundled) on launch, which registers it in
//  skills.db and writes <AppGroup>/skills/<id>/SKILL.md — the directory iSH
//  bind-mounts at /var/minis/skills, which is how the skill reaches
//  Settings > Skills, the agent's file reads, and the relative links between
//  a skill's own files.
//
//  Each body is the verbatim upstream deepseek-harness
//  .agents/skills/<id>/SKILL.md, and each entry of docFiles is a verbatim
//  upstream .agents/skills/dsh-doc/<path>. Backslashes are escaped because a
//  bare one starts a Swift escape sequence and would fold away the shell line
//  continuations in dsh-pre-push-checks; nothing else is rewritten. The bodies
//  sit at column 0 inside their literals so the stored bytes match the source
//  file exactly. Regenerate with _tools/gen-dsh-bundled-skills.cjs rather than
//  editing the text below by hand; re-check it with
//  _tools/verify-dsh-bundled-files.cjs.
//
//  The app has no bundled-skills resource directory, so these inlined literals
//  are the only channel a shipped skill can use.
//

/// Skill bodies and bundled files shipped in the binary, installed on launch by SkillStore.
enum DSHBundledSkills {

    /// Bundled revision of the three DSH bodies. The installed rows record the
    /// version from their frontmatter (1.0.0 — these sources carry no
    /// `version:`), so raising this makes installBundledSkill re-import all three.
    /// 1.1.0 is the revision that first shipped dsh-doc's 12 bundled files:
    /// without the bump a device already holding the 1.0.0 row would keep the
    /// dead references/ + templates/ links forever, because installBundledSkill
    /// leaves an up-to-date row alone.
    static let setVersion = "1.1.0"

    /// Upstream `.agents/skills/dsh-code-review/SKILL.md` — 9410 bytes, sha256 8A91213A7D97503A…
    static let codeReview = """
---
name: dsh-code-review
description: Use when reviewing a pull request in the deepseek-harness repo — orients the reviewer to this codebase's standards (AGENTS.md conventions, defensive patterns, ADRs, quality gates) and the review-specific checks that code alone can't show
---

# Reviewing a DeepSeek-Harness PR

**This skill is guidance, not a complete checklist.** Verify and fetch the PR's live base and exact head, then run `pnpm --silent run change-scope --base <verified-base-ref> --head <verified-head-ref>` before reading the diff and enough surrounding code to understand the design. The report identifies paths and dirty layers but does not replace semantic review. Re-establish the base and rerun it after a retarget or merge. Prioritize correctness, lifecycle, security, and broken required behavior over style; a short review with one substantiated blocker is better than a list of nits.

## Sources of truth

- [AGENTS.md](../../../AGENTS.md) and [packages/AGENTS.md](../../../packages/AGENTS.md): standing repository and package authoring rules.
- [docs/defensive-patterns.md](../../../docs/defensive-patterns.md): subprocess, callback, async-state, and disposal bug classes.
- [docs/AGENTS.md](../../../docs/AGENTS.md): documentation placement and prose discipline.
- [dsh-prose-standard](../dsh-prose-standard/SKILL.md): required coverage and editorial judgment for comments, docs, prompts, and visible strings.
- [dsh-ci-test-reliability](../dsh-ci-test-reliability/SKILL.md): isolation and regression-proof rules for resource-owning, asynchronous, or flaky tests and fixtures.
- [dsh-client-ui-ux](../dsh-client-ui-ux/SKILL.md): feedback-surface choice, overlay safety, platform window adaptation, and visual token discipline for product-user-visible GUI changes.
- [docs/testing.md](../../../docs/testing.md) and the [quality-gates Agent Note](../../notes/implemented/process/2026-06-11-quality-gates.md): required test tiers and gates.
- [Agent Notes](../../notes/README.md): design rationale. Treat disagreement with an Agent Note as a design discussion, not an automatic veto.
- For bilingual changes, read [translation-rules.md](../../../docs/i18n/translation-rules.md) and [terminology.md](../../../docs/i18n/terminology.md); the extended translation skill is outside automatic review and runs only on explicit user invocation.

## Blocking requirements

1. **New prose receives semantic review.** Use [dsh-prose-standard](../dsh-prose-standard/SKILL.md) to critically review every added or changed Markdown passage, JSDoc, comment, prompt, description, diagnostic, and visible string. Verify required coverage, accuracy, placement, and editorial quality against the owning code or behavior; automated checks do not establish those properties.
2. **Docs match the code.** Config, defaults, errors, wire fields, events, and public behavior update the package README and JSDoc in the same diff. Comments state non-obvious contracts; flag implementation narration, test walkthroughs, review history, and duplicated rationale for deletion or a link to their one home.
3. **Core type docs match.** Changes to spine or seam vocabulary update the appropriate [subsystems](../../../docs/subsystems/README.md) page and any `type-equiv` entry. Internal types need no catalog entry.
4. **Registrations clean up.** Verify each new registry contribution passes the disposal tests required by [packages/AGENTS.md](../../../packages/AGENTS.md).
5. **Invariant companions are semantic.** For every touched `./invariant`, require an owner event-stream or mutable-data relationship with independent observations at the point where that package can observe it; service or method presence, plugin metadata or effects, fixed pure examples, and probes that call the same operation they claim to verify belong in load, behavior, or unit tests. When no plausible relationship exists, require the package to omit the companion and publication wiring and record its package-specific reason in the README. Reject empty installers and invented checks ([repository rule](../../../AGENTS.md#conventions); [package invariant rules](../../../packages/AGENTS.md)).
6. **Required evidence exists.** Verify the author ran the [relevant local checks](../../../AGENTS.md#run-relevant-checks-locally) for the diff and that CI covers the exhaustive matrix; review the semantic gaps neither can detect.
7. **Client UI copy is locale-owned.** Reject product text embedded in JSX, templates, helper returns, accessibility attributes, or primitive defaults. Require typed dictionary keys, the standard `t` seat or explicit localized props, `verify-client-ui-i18n`, and behavior evidence in each affected locale; preserve user/model/wire data and code tokens verbatim.

## Manual checks

- **Intent and interface contracts:** trace both sides of every changed interface. Confirm the implementation matches the PR and any Agent Note, including errors, cancellation, ownership, and disposal.
- **Lifecycle and concurrency:** for async setup, callbacks, processes, or teardown, apply [defensive-patterns.md](../../../docs/defensive-patterns.md). Check races before publication, cancellation during awaits, independent error reporting, callback containment, ownership before reentry, complete detach cleanup, and quiescent disposal.
- **Capability and consumer fit:** trace every current consumer, then flag consumer-specific behavior leaking into the interface under [the package rules](../../../packages/AGENTS.md). Flag the inverse too: a new public method on a generic service (registry, session, agent) whose only caller is one internal consumer is an unnecessary API expansion — require a private capability closure handed to that consumer at construction instead.
- **Scope, ownership, and necessity:** map each abstraction, state machine, option, defensive copy, and compatibility path to its current contract, production consumer, and owning plugin or service. Challenge unrelated features and speculative generality, then test the PR against [the root rules](../../../AGENTS.md#conventions).
- **Configuration and public choices:** ask what current-consumer evidence or prior art supports each default, public operation set, format, or imported external concept. Require an explicit choice or deferral when that evidence is absent.
- **Model perspective:** inspect the exact prompts, tool schemas, results, and diagnostics the model receives across affected modes. Flag concepts outside the model's task, then verify stable text verbatim and dynamic behavior through snapshots or end-to-end coverage.
- **Enforcement:** follow every denial path to the operation that executes it; exercise direct and alternate callers that can bypass schemas, prompts, facades, wrappers, or listener ordering.
- **Borrowed and derived state:** determine whether each retained value is borrowed or owned under the package contract, then trace notifications and every cache, prompt, UI echo, replay, and query view to the documented success point and authoritative source.
- **Bounds cover the final operation:** locate the owner of the complete emitted or retained result, including wrappers and metadata. Probe tiny and exact limits, oversized single chunks, and multibyte text for byte limits.
- **Real entry path:** tests exercise the shipped Loader, bin, worker, ACP bridge, or subprocess where relevant. A hand-mounted plugin does not catch invalid Loader exports; a function plugin must named-export its namespace and have no default export.
- **Test strength:** assertions fail on the intended regression and verify external state, logs, events, or disposal rather than restating the implementation or trusting an agent's report. Coverage is necessary but not evidence that the scenario is correct.
- **Test reliability:** for a resource-owning, asynchronous, platform-sensitive, or flaky test, apply [dsh-ci-test-reliability](../dsh-ci-test-reliability/SKILL.md) to the real worker/job topology, resource allocation, global-state restoration, synchronization, timeout budget, and quiescent teardown.
- **Invariant lifecycle and negative controls:** verify candidate observations are rejected before publication where possible, session-backed checks reconstruct durable history after late loading or HMR, and a deliberately invalid case fails through the real runner for the intended rule.
- **Implemented Agent Notes match shipped reality:** when a PR implements a proposed Agent Note, move and rewrite it as present-tense shipped state in the same diff, then verify paths, names, and mechanisms against the implementation.
- **Transcript changes:** editor-visible or model-visible changes update snapshots or explain why no snapshot applies. Review expected-output diffs as behavior changes, not formatting noise.
- **Bilingual changes:** compare meaning and terminology on both sides; a green pairing hash does not prove translation quality.

## Reporting findings

State the defect, location, impact, and evidence. Place a localized defect inline on the tightest relevant diff range; use a PR-level comment for cross-cutting architecture, scope, or review-wide synthesis. Separate blockers from suggestions and omit issues already enforced by a green gate. Use the existing GitHub review thread for replies. When receiving review, verify each claim and fix or rebut it on technical grounds without performative agreement.

"""

    /// Upstream `.agents/skills/dsh-pre-push-checks/SKILL.md` — 10967 bytes, sha256 7091F3061DE122D2…
    static let prePushChecks = """
---
name: dsh-pre-push-checks
description: Use before pushing, force-pushing, marking ready for review, or claiming checks pass on a deepseek-harness branch, and immediately after gh stack sync publishes rewritten branches, to select the smallest tests and checks that cover the outgoing or just-published diff without reflexively running the full repository suite.
---

# DSH Pre-Push Checks

Use this skill to run relevant local evidence once before a `deepseek-harness` push. The sole ordering exception is `gh stack sync`, which may publish a cascading rebase before the rewritten layers can be validated; validate them immediately afterward and do not merge until the evidence passes. Git hooks are intentionally narrow: pre-commit fixes staged lint, checks staged whitespace, and guards vendored-source metadata; pre-push runs only the incremental repository typecheck. CI owns exhaustive coverage and the platform matrix.

## Inspect the outgoing change

1. Confirm the checkout and branch.

```sh
git status --short --branch
git rev-parse --show-toplevel
```

2. Verify the live PR base or stack parent, fetch that ref, and inspect the complete scope against it.

```sh
pnpm --silent run change-scope --base <verified-base-ref>
```

The command never guesses or fetches a base. Supply the ref verified from current remote or stack state; use `--head <ref>` when inspecting a commit other than `HEAD`. Its versioned JSON records committed paths relative to the resolved merge base, while staged, unstaged, and untracked paths describe the current worktree. After merging a changed base, rerun the report, reassess which behavior the combined scope can affect, and rerun only checks invalidated by the merge.

## Select relevant evidence

There is no universal local baseline beyond the hooks. Every behavior change needs the narrowest available test or purpose-built check that would fail for its regression; add broader checks only for surfaces the diff actually reaches.

When the outgoing change adds or changes a resource-owning or asynchronous test, fixture, helper, or CI execution path, use [dsh-ci-test-reliability](../dsh-ci-test-reliability/SKILL.md) first to decide whether restoration, negative-control, quiescent-teardown, or concurrent-process evidence applies. This skill still selects the commands and avoids repeating evidence that already passed.

- **Package or script behavior:** run the owning Vitest file or focused test name. Add adjacent package tests when a shared contract changes; leave repository-wide coverage to CI unless the change is genuinely cross-cutting or the user requests it.
- **Remote mock typing:** unbuilt `any` is an explicit local fallback, not strict evidence. Run `pnpm run typecheck` before handing off Remote/mock changes; rebuild missing, stale, or partial generated declarations before diagnosing remaining errors. Keep the exception in the [test proxy](../../../packages/test-support/remote-mock/README.md#remote-proxy), never in production Remote types, ambient flags, or copied signatures.
- **Documentation, Agent Notes, catalogs, or doc-linked comments:** run `pnpm run doc-sync`; run full lint when the documentation workflow requires it.
- **Model-, editor-, CLI-, or terminal-visible output:** run the focused keyless snapshot or real runnable-example scenario that owns the output.
- **Expected-output placement:** a test whose selected recorded Session generation is replay input and expected persisted output belongs under top-level `snapshots/`, with `snapshot.yml` naming its shipped `dsh` profile and composition/header pin. Canonical parent files are `session[.vN].jsonl`, children are `session.<ordinal>[.vN].jsonl`, and the harness selects the highest generation per role. ARIA, geometry, generator, CLI, and unit expectations without that Session round trip stay beside their owning test under `tests/expected/`; do not place them in `snapshots/` or give them a `*.snapshot.ts` owner. Use the owning `test:expected`, `test:web`, or `test` lane.
- **Profile and configuration placement:** cross-package behavior of a shipped `dsh` profile belongs under `apps/cli/tests/profiles/`; a package-specific Loader composition belongs under that package's `tests/fixtures/`. User-facing optional overlays live under `apps/cli/config/examples/` and pair with a guide under `docs/user/`.
- **Package manifests, public exports, build configuration, worker/bin entries, or built runtime paths:** run `pnpm run build`, the relevant hygiene checks, and the owning built-artifact smoke.
- **Real provider or agent behavior:** run the relevant `pnpm run test:e2e` target when credentials are available; never print secrets.

Do not manually repeat a passing check merely because commit or push follows. In particular, do not run typecheck immediately before pushing solely to duplicate the pre-push hook.

Pass Vitest file and name filters directly after the script name with `pnpm run`; do not insert a standalone `--`, which reaches Vitest and can disable `-t` filtering. For example, this command runs one headless snapshot scenario:

```sh
pnpm run test:snapshot snapshots/session/headless.snapshot.ts -t 'cordis-inspect-jsdoc'
```

This applies to these pnpm scripts; npm and other launchers retain their own argument-forwarding syntax. Check the reported selected test count before treating a filtered run as focused evidence.

### Focus unit coverage on the affected source

Test selection and coverage selection are separate. A Vitest file filter chooses which tests run, while the repository configuration otherwise measures every `packages/*/*/src/**/*.ts` file. When unit coverage is relevant, name both the owning tests and the source files or package whose coverage those tests must prove:

```sh
pnpm exec vitest run packages/<group>/<package>/tests/<behavior>.spec.ts \\
  --coverage \\
  --coverage.include='packages/<group>/<package>/src/**/*.ts'
```

Use an exact source file when the behavior is truly confined to one module. Repeat `--coverage.include` for multiple affected files or packages, and pass every owning test file needed to exercise that scope. The configured per-file 100% thresholds still apply inside the selected source scope.

When the owning tests are unclear, use Vitest's dependency graph to discover a candidate set, then inspect the selected tests before treating the run as evidence:

```sh
pnpm exec vitest related packages/<group>/<package>/src/<changed>.ts \\
  --run \\
  --coverage \\
  --coverage.include='packages/<group>/<package>/src/<changed>.ts'
```

`vitest related` cannot discover behavior reached only through configuration, dynamic loading, subprocesses, workers, built artifacts, or external providers; select those owning tests explicitly. Do not use `--passWithNoTests`, lower coverage thresholds, or narrow `--coverage.include` merely to hide an uncovered affected file. If a selected package scope fails because one focused test does not cover it, add its other relevant owning tests or narrow the source scope only when the excluded modules cannot be affected by the change.

## Full local rehearsal

Run the complete local approximation only when the user explicitly requests it, while diagnosing a CI failure, or when the change spans the repository so broadly that no narrower set is credible. Use the current workflow and package scripts as the inventory; do not recreate the removed `check:pre-push` aggregate.

## Protect history-rewriting pushes

Rebase is allowed for standalone and stacked PR branches, including after review. Before a standalone history rewrite, fetch the current remote branch and record its exact OID; publish with `--force-with-lease=<branch>:<observed-oid>` so a concurrent update aborts the push. `gh stack push` and `gh stack sync` supply lease protection for their managed branches. Raw `--force` is never allowed.

After any rewritten push, fetch the live heads again and re-audit unresolved review threads, approvals, mergeability, and checks. Commit hashes and inline-comment anchors from before the rewrite are not current evidence.

### Post-sync validation

`gh stack sync` fetches, cascade-rebases, and pushes as one operation, so it cannot place local validation between rewrite and publication. Before running it, require a clean worktree and record the official stack order and exact remote heads. After it returns:

1. Re-query every branch head and the official GitHub stack order.
2. Inspect the changed scope of every rewritten layer against its live PR base.
3. Run the relevant evidence selected by this skill for each affected layer.
4. Keep every PR unmerged and report validation as pending until all selected checks pass.

If post-sync evidence fails, leave the lease-protected published heads in place, repair the failure, validate the repair, and publish the correction. Do not claim the sync made the stack ready merely because the command succeeded.

## Handle failures

If a relevant check fails before an ordinary push, stop and fix or explain the blocker. Do not push and hope CI differs. For the post-sync exception, block the merge and follow the repair procedure above.

If a failure looks environment-specific, prove it:

- Record the exact command, failing test, and platform-specific mismatch.
- Confirm the relevant non-platform evidence.
- Prefer fixing cross-platform nondeterminism when the check is required.
- Bypass a local hook only when the user explicitly asks or agrees, and report exactly what failed and why CI is expected to differ.

## Push procedure

For ordinary and standalone rebase pushes:

1. Run the selected relevant checks once.
2. Commit normally and inspect any files changed by the pre-commit fixer before continuing.
3. Push normally, or use the exact lease for an authorized rewritten branch, so the incremental typecheck hook runs.
4. Verify the remote ref matches local `HEAD`.

```sh
git rev-parse HEAD origin/$(git branch --show-current)
```

For GitHub PRs, inspect remote CI after the push:

```sh
gh pr checks
```

Report pending checks as pending. Inspect failures before attributing them to the branch or the environment.

When `gh pr checks` reports "no checks reported" and `/actions/runs?head_sha=<sha>` returns `total_count: 0`, read mergeability before suspecting the push or a dropped GitHub event:

```sh
gh pr view <number> --json mergeable,mergeStateStatus
```

GitHub creates no `pull_request` workflow runs while a PR is `CONFLICTING`/`DIRTY`, so the absent signal is the conflict, not infrastructure. Resolving the conflict is the only fix; empty commits, `--allow-empty` pushes, draft/ready toggles, and revert-and-restore bounces all leave `total_count` at zero and add junk history. Confirm the conflicting paths with `git merge-tree --write-tree HEAD origin/<base>` when the branch cannot be merged locally yet.

For `gh stack sync`, use the post-sync validation sequence instead of pretending the ordinary order was possible.

"""

    /// Upstream `.agents/skills/dsh-doc/SKILL.md` — 18039 bytes, sha256 5704DCF1D81DCDA3…
    static let doc = """
---
name: dsh-doc
description: Create, restructure, review, audit, or migrate DeepSeek Harness Markdown documentation, package READMEs, and the documentation website using audience-first hierarchy, kind-mapped YAML metadata, bilingual line alignment, summary/contents navigation, progressive user-to-developer detail, executed-operation fact-checking, and repository validation. Use for new or revised DSH docs, docs-tree organization, documentation-quality audits and budgets, website page publishing, and bilingual documentation structure changes.
---

# DeepSeek Harness documentation

## Summary

The DeepSeek Harness documentation standard: make every page searchable, newcomer-readable, and exact enough for agents and maintainers, and keep the documentation website a tested projection of repository Markdown. Apply repository `AGENTS.md` files and executed gates first, then this workflow for kind-mapped metadata, progressive detail, line-aligned bilingual pages, corpus audits, and website publication. Preserve one owner per fact: source, tests, generated catalogs, package READMEs, guides, Agent Notes, and scratch each keep their own kind of truth. The `session-persistence-jsonl` README pair is the reference example of the format.

## Table of Contents

- [Workflow](#workflow)
- [Fact-check procedure: test, do not assume](#fact-check-procedure-test-do-not-assume)
- [Kind system and templates](#kind-system-and-templates)
- [Voice rules](#voice-rules)
- [Quality criteria](#quality-criteria)
- [Audit the corpus](#audit-the-corpus)
- [Wordcount budgets](#wordcount-budgets)
- [Website publication](#website-publication)
- [Detailed references](#detailed-references)
- [Validation](#validation)
- [Dev Note](#dev-note)

## Workflow

Follow this sequence for each requested scope. Keep the common reader path brief, but do not delete failures, ownership, limitations, or other required contracts merely to reduce words.

1. Read root and more-specific `AGENTS.md`, [the documentation standard](../../../docs/AGENTS.md), the target page, its source/tests, navigation owner, and bilingual record.
2. Classify the page by one primary job and reader: product quick start, user task guide, contributor tutorial, architecture overview, package/subsystem reference, generated reference, agent instruction, decision record, or scratch.
3. Place the page at its nearest owner. Keep package contracts beside package code; use `docs/` for cross-package learning, user, developer, architecture, discussion, and expiring scratch material.
4. Define the reader's starting state, observable outcome, likely failure, recovery path, and next useful depth before writing details.
5. Add or revise YAML metadata — assign the `kind` that maps to the template for this document's job — then write `Summary`, `Table of Contents`, user-facing content, developer-facing content, optional `Further Exploration`, and final `Dev Note` in that order where the document type permits.
6. Update the bilingual counterpart in the same pass. Keep headings, lists, tables, code, links, frontmatter layout, and physical line count aligned.
7. Verify every claim against code, tests, generators, package metadata, or a current decision owner — and run the operations the page instructs, per the fact-check procedure below. Update the owner before any derivative artifact.
8. Run focused checks, then `pnpm run test:docs`, `pnpm run doc-sync`, `pnpm run lint`, and `git diff --check`; re-read the complete diff for correctness and then for brevity and repository fit.

## Fact-check procedure: test, do not assume

Documentation states how the product behaves today, and the only admissible evidence for an operation claim is having run it. This procedure is mandatory for every new document and every new paragraph that claims an operation, command, default, error, or platform difference.

1. **Classify the subject before writing install guidance.** Read the facts, never the folder name: `package.json` for a `dsh.bundle.patch` declaration, and the entry file for the plugin shape (`apply` export or a default service export is a plugin; a plain module API is a library). A bundle installs with `dsh plugin --profile <name> add <package>` and is the only package shape for which that command activates a profile layer; a plugin mounts as a `cordis.yml` row; a library is a dependency with no install path of its own. Packages with special status (libraries, bundles) get their own README template — never a plugin README with install guidance that does not apply.
2. **Run every claimed operation against the current checkout.** Execute each CLI command, config snippet, and profile or patch example exactly as the document will show it; write down only what you observed, including the exact output, warnings, and failure modes. If a claim depends on a key or a network you do not have, say so and name the verification owner instead of asserting the behavior.
3. **Delete what you could not reproduce.** Never carry a command, field, default value, or behavior from memory, analogy, or a neighboring package's README. When a claim fails to reproduce, fix the claim — not the test.
4. **Check old docs against latest master.** Before revising pre-existing pages, `git fetch origin` and compare the section against `origin/master`; the pairing sidecar recovers the last-confirmed text of either side. A stale statement on master is still wrong: correct it against the code, not against the old prose.
5. **Re-record the pair after every edit.** Each paired edit re-runs `pnpm run verify-translation-pairing --write <pair>` so the sidecar tracks the confirmed pair.

## Kind system and templates

The `kind` frontmatter field selects exactly one README template. Every kind in [the metadata reference](references/metadata-links-i18n.md#the-kind-system) maps to one template file in [`templates/`](templates/), and every template backs exactly one kind; the documentation check derives the expected kind from the same mechanical facts.

- `package-group` → [templates/package-group.md](templates/package-group.md): group maps (`packages/README.md`, `packages/<group>/README.md`) — orient the family, map its direct packages, link package-owned details.
- `package-reference` → [templates/package-reference.md](templates/package-reference.md): a Cordis plugin or service package — mount configuration, the config table, folded implementation, Model Experience and Known Limitations in the gate-owned forms.
- `package-library` → [templates/package-library.md](templates/package-library.md): a package with no plugin surface — consumer entry points, no profile-install path, no mount configuration.
- `package-bundle` → [templates/package-bundle.md](templates/package-bundle.md): a package declaring `dsh.bundle.patch` — the verified `dsh plugin` install path, layer semantics, patch document.
- `persistence-change` → [templates/persistence-change.md](templates/persistence-change.md): a dated record in `docs/persistence-changes/` — acknowledge a detected type transition with per-root predecessors and generated after schemas.
- `persistence-release` → [templates/persistence-release.md](templates/persistence-release.md): a pinned tag in `docs/persistence-changes/releases/` — compare reconstructed historical types without claiming compatibility acknowledgement.
- `persistence-format` → [templates/persistence-format.md](templates/persistence-format.md): a historical Session format checkpoint in `docs/persistence-changes/historical-formats/`, with complete schemas; the current writer uses the existing catalog.

Open the template before writing and follow its skeleton and rules; it states what the kind is, how the page is structured, and the fact checks each section owes. Add a new kind only together with a distinct template file, a documented repository position or declared owner, and a focused check that maps documents to it.

## Voice rules

These rules decide what a section may say. They apply to every authored human-facing page, and to package READMEs with particular force.

- **Summary says what the subject does.** The opening `Summary` and the user-facing sections describe what a user or agent can DO with the subject — outcomes, benefits, when to choose it, main cost — never its role, type, or internal identity. In a package Summary, “what it is” means only its reader-visible capability, not its Cordis role, registrations, or internal components. Omit source identifiers unless the reader directly uses them in configuration, a command, or a public API. "The seam registers `ctx.x` and appends `x/event` records" is identity narration; "you can save a note per message and it survives restarts" is what it does.
- **Developer sections explain, never enumerate.** Folded implementation content covers the overall design concept, architecture, and hand-waving dataflow — enough to understand how the package works — and links code for exact detail. No full API catalogs, exhaustive column lists, event-payload enumerations, or JSDoc restatement inside the folds.
- **Dev Note is the only slop zone.** Partial ideas, scratches, undecided directions, measured artifacts, and working hypotheses live only in the final Dev Note, marked explicitly non-authoritative. Every other section is polished, current-state prose.
- **Current state only.** Ordinary documentation describes the current codebase. Dedicated `persistence-change`, `persistence-release`, and `persistence-format` records retain historical type evidence; release comparisons and format checkpoints describe observed history without asserting compatibility. Agent Notes and postmortems retain their own historical scope.
- **Use controlled technical English.** Give each sentence an explicit actor and one main action when ambiguity can change behavior. Reuse one term per concept, prefer direct verbs, split stacked instructions and conditions, and preserve modality and exceptions. Apply the non-certified, ASD-STE100-inspired discipline in [the page-style reference](references/style.md#controlled-technical-english). Do not force a shorter sentence when precision would fall.

## Quality criteria

Use these definitions in review. Each section opens with a short orienting paragraph before subsections or exhaustive detail.

- **Brief:** the common path contains only facts needed for its outcome; exhaustive truth remains one direct link or detail layer away.
- **Intuitive:** prerequisites precede dependent concepts, one next action is obvious, and headings use terms readers search for.
- **Friendly:** readers can recognize success, understand risk before acting, recover from likely failure, and choose whether to continue deeper.
- **Accurate:** each durable claim has one owner and a verification path proportionate to its risk.
- **Agent-readable:** metadata, stable headings, anchors, terminology, ownership, and current/proposed status support targeted retrieval without loading the corpus.
- **Newcomer-complete:** a professional engineer with no repository context can reconstruct the relevant architecture or feature through three to five linked pages.

Do not apply a universal word limit to exhaustive references. Measure entry-path length, unrelated material scanned for one lookup, largest section, heading count, and page size; split by an existing domain owner when retrieval cost is high.

## Audit the corpus

Read, do not re-summarize, the owning contracts: [docs/AGENTS.md](../../../docs/AGENTS.md) for hierarchy, tutorial/reference forms, taxonomy, budgets, and the slop checklist; [.agents/notes/README.md](../../notes/README.md) for Agent Note lifecycle; [docs/i18n/README.md](../../../docs/i18n/README.md) for the bilingual pairing rules; and [root AGENTS.md](../../../AGENTS.md) for standing orders. Exclude `.agents/notes/archived/` from audits and edits — archived notes are frozen history.

Apply the standard's authoring order to every human-facing document in scope (not to Agent Notes): locate the document and state its own subject; set the permitted detail level and move deeper explanations to owning descendants with links; classify tutorial or reference from intended use, not path; for a tutorial, order concepts by prerequisite and difficulty; split substantial mixed forms. Then check placement constraints: paired docs cost a counterpart update and a `--write` re-record on every edit; generated catalogs are never hand-edited; a move is atomic with every inbound link repaired in the same change.

After the structural pass, hunt the slop checklist with the cheapest probes first. Use [dsh-trim-cot-leakage](../dsh-trim-cot-leakage/SKILL.md) for reasoning-transcript leakage, grep distinctive phrases to find duplicated rules, replace hand-written catalogs and status inventories with their authoritative owners, and remove migration plans and future-tense spec language from implemented Agent Notes. Measure outliers with `pnpm run verify-doc-budgets --list` and a word-count scan; if removing prose changes a promised behavior rather than its explanation, propose the behavior change first (follow [dsh-find-simplifications](../dsh-find-simplifications/SKILL.md)). Keep every load-bearing rule, preferably as one to three lines plus a link to its rationale; do not create a new explanation merely to relocate disposable reasoning.

## Wordcount budgets

`pnpm run verify-doc-budgets` compares standing documents against ceilings in [scripts/doc-budgets.manifest.json](../../../scripts/doc-budgets.manifest.json); a red gate follows the ordered relocate-condense-raise policy in [docs/AGENTS.md](../../../docs/AGENTS.md#wordcount-budgets). Ceilings are guardrails, not reduction targets: at or below target, retain at least 5% headroom; raise a ceiling only when the words need the space, and justify the manifest diff in the PR.

## Website publication

The website is a tested projection, never a second copy: [website/docs.ts](../../../website/docs.ts) is the explicit public allowlist mapping canonical `docs/` sources into route trees, [scripts/project-doc-site.ts](../../../scripts/project-doc-site.ts) rewrites them into the disposable `website/.generated/` tree, and VitePress builds that tree. Repository Markdown stays the only editable content source; translations stay sibling pairs (`foo.md`, `foo.zh.md`, `foo.i18n.yaml`), never locale directories. Edit an already published page in its canonical source only; add one manifest entry for a new page; update source, manifest entry, and inbound links atomically for a move or removal; never edit `website/.generated/`, `website/.cache/`, or `website/.dist/`. Set every `DocsPage` field deliberately and honor the projector's link rules; see [references/website-sync.md](references/website-sync.md) for the fields, sidebar collections, and preview commands. Synchronizing content into the build does not publish it: deployment stays a separate, explicitly requested step.

## Detailed references

Load only the reference needed for the task. Each reference links directly from this file so the skill has no deep reference chain.

- [Metadata, links, and bilingual pairs](references/metadata-links-i18n.md): README frontmatter, the kind system and its derivation, description semantics, repository paths, line alignment, and the sidecar record.
- [Page structure and hierarchy](references/structure-hierarchy.md): mandatory section order, section summaries, user-to-developer progression, docs tree placement, small rule files, Further Exploration, and Dev Note ownership.
- [Page style](references/style.md): short Summary, `-----` section separators, foldable content sections, and emphasis discipline.
- [Review criteria](references/review.md): newcomer test, evidence checks, package README review, the reference example, and verification commands.
- [Website publication](references/website-sync.md): manifest fields, projector link rules, preview and validation, and deployment separation.

The templates in [`templates/`](templates/) provide one working skeleton per `kind`; open the one your document's kind names before writing.

Use [dsh-prose-standard](../dsh-prose-standard/SKILL.md) for sentence-level contract coverage and editorial judgment. The `session-persistence-jsonl` README pair ([English](../../../packages/session/session-persistence-jsonl/README.md), [Chinese](../../../packages/session/session-persistence-jsonl/README.zh.md)) is the reference example: searchable YAML, Summary and Table of Contents, user-to-developer progression with a folded developer section, Further Exploration, canonical Model Experience and Known Limitations sections, and a final Dev Note.

## Validation

Validate the affected format, not merely Markdown syntax. A strong promise needs a focused valid fixture and an invalid fixture that proves the top-level gate can fail.

- README metadata: parse YAML, map `kind` to its template and document standard, reject `name`, `audience`, ungoverned `tags`, and README-local `i18n` metadata, and reject missing or advertisement-style descriptions.
- Bilingual pages: verify structure, exact line count, terminology, link parity, and the sidecar record.
- Tutorials: exercise the documented entry path or name an explicit manual verification owner.
- Generated references: run the deterministic freshness check and report retrieval-size measures.
- Package READMEs: run the Summary gate, which limits each English Summary to 100 `wc -w`-style words and directs failures back to this skill and the kind template; run model-experience and limitation checks, then package-focused tests when behavior claims changed; re-run every command the README instructs before merging a claim about it.
- Skills: run the repository's skill-invocation metadata check.

Run `pnpm run test:docs` for the quick comprehensive documentation checks (pairing, wrap, links, README gates, budgets, skill metadata, Agent Note gates) before the full `pnpm run doc-sync`.

## Dev Note

None.

"""

    /// Upstream `.agents/skills/dsh-doc/references/metadata-links-i18n.md` — 8934 bytes, sha256 7BC08F3C8270CE1C…
    private static let docFile_references_metadata_links_i18n = """
# Metadata, links, and bilingual pairs

## Summary

README metadata is a retrieval and template-selection interface, not a miniature report or advertisement. The `kind` field selects exactly one README template that exists in this skill and maps to the document standard; the frontmatter carries no field that a filename convention or an executed gate already owns. Bilingual pages keep equal authority, one-to-one structure, and exact physical line alignment. The `*.i18n.yaml` sidecar records the last-confirmed pair and supports automatic merges. Link syntax must render correctly on GitHub and the documentation site, so repository links stay renderer-valid relative URLs.

## Table of Contents

- [README metadata](#readme-metadata)
- [The kind system](#the-kind-system)
- [Description quality](#description-quality)
- [Repository links and path mentions](#repository-links-and-path-mentions)
- [Bilingual line alignment](#bilingual-line-alignment)
- [Bilingual consistency records](#bilingual-consistency-records)
- [Dev Note](#dev-note)

## README metadata

Start every authored README with YAML frontmatter. Permit custom fields, but keep common fields stable enough for search and indexing.

```yaml
---
description: "Example capability for users and maintainers choosing, configuring, or debugging the package."
kind: "package-reference"
---
```

`description` and `kind` are required for package README pairs. The page title and package manifest already own the name, while the document job and its reader path express the audience; duplicating either in frontmatter adds no retrieval value. The counterpart path comes from the sibling filename (`README.zh.md`), and the sidecar owns pair state, so README-local `i18n` metadata is redundant. Do not add `tags` until a repository-owned taxonomy and search consumer justify them beyond description and full-text search. Keep keys lowercase and hyphenated unless an existing owner defines another spelling, and do not copy volatile code inventories into frontmatter.

## The kind system

`kind` selects the document template directly; every kind maps to exactly one template that exists in this skill, and no template exists without a kind. Files named `docs/persistence-changes/YYYY-MM-DD-slug.md` use `persistence-change`; files named `docs/persistence-changes/releases/dsh-v*.md` use `persistence-release`. Files named `docs/persistence-changes/historical-formats/vN.md` use `persistence-format`. Their Chinese siblings use the same kind. Folder READMEs are indexes, not records. Derive package README kinds mechanically, in this order:

1. The README is `packages/README.md` or `packages/<group>/README.md` → `package-group`.
2. The package manifest declares `dsh.bundle.patch` → `package-bundle`.
3. The package is in the audited library registry of `scripts/doc-standard.spec.ts` → `package-library`.
4. Everything else — a service default export or an `apply` plugin — is `package-reference`.

| `kind` | Repository position | Template | Standard |
|---|---|---|---|
| `package-group` | `packages/README.md`, `packages/<group>/README.md` | [package-group.md](../templates/package-group.md) | Group map: orient the capability family, map its direct packages, explain composition relationships, and link package-owned details. |
| `package-reference` | `packages/<group>/<package>/README.md` with a plugin entry | [package-reference.md](../templates/package-reference.md) | Package contract: follow the [package README review standard](review.md#package-readme-review) and the canonical [package documentation requirements](../../../../docs/cookbook/adding-a-package.md#4-write-the-package-readme). |
| `package-library` | `packages/<group>/<package>/README.md` with a plain module entry | [package-library.md](../templates/package-library.md) | Library contract: consumer entry points and boundaries; no profile-install path and no mount configuration. |
| `package-bundle` | `packages/<group>/<package>/README.md` declaring `dsh.bundle.patch` | [package-bundle.md](../templates/package-bundle.md) | Installable layer: the verified `dsh plugin` install path, layer semantics, and patch document. |
| `persistence-change` | `docs/persistence-changes/YYYY-MM-DD-slug.md` and its Chinese sibling | [persistence-change.md](../templates/persistence-change.md) | Historical acknowledgement: mechanically detected type changes, per-root predecessor references, compatibility decision, and generated after schemas. |
| `persistence-release` | `docs/persistence-changes/releases/dsh-v*.md` and its Chinese sibling | [persistence-release.md](../templates/persistence-release.md) | Retrospective observation: pinned tag, adjacent before/after digests, actual version constants, and changed after schemas; no compatibility acknowledgement. |
| `persistence-format` | `docs/persistence-changes/historical-formats/vN.md` and its Chinese sibling | [persistence-format.md](../templates/persistence-format.md) | Selected historical format: source evidence, complete root schemas and reachable types; the current writer uses the generated catalog. |

Before assigning `package-library` or `package-bundle`, inspect the facts: read `package.json` for `dsh.bundle.patch` and `src/index.ts` for the entry shape (`apply` export or a default service export is a plugin; a plain module API is a library). `dsh plugin --profile <name> add <package>` installs any npm dependency, but the profile reconcile activates a layer only for a package that declares `dsh.bundle`; never present that command as an install path for a library or a plain plugin. The documentation check derives the expected kind from these same facts, rejects another value, and rejects `name`, `audience`, `tags`, and README-local `i18n` metadata. Add a new kind only with a distinct template, an unambiguous repository position or declared owner, and a focused check that maps documents to it.

## Description quality

Agents search frontmatter `description` values to shortlist pages before loading full documents. Write each value like a Skill description: state what the page covers and when a reader should open it. Use one or two concrete sentences, include searchable domain terms, and distinguish the page from nearby owners. Do not summarize every section, claim superiority, repeat the title, advertise vaguely, preserve change history, or write a technical status report.

Good: `The shipped JSONL session-persistence backend for deployments and maintainers choosing, configuring, or debugging per-session durable logs with optional Zstandard compression.`

Weak: `The best and most advanced session storage implementation with lots of optimizations.`

## Repository links and path mentions

Keep link destinations machine-checkable and mentions context-relative. Use fragment-only links for the current page's menu. Use full URLs for external resources.

The desired internal-link model names a target from the repository root, but a leading `/docs/...` Markdown URL resolves outside the repository on GitHub, remains untouched by the website projector, and is skipped by `verify-md-links`. Until a repository-owned resolver supports root paths in every renderer, use the current renderer-valid relative URL in Markdown links and write logical path mentions such as `docs/` or `packages/session/` relative to the discussion. Never adopt an unchecked leading-slash link merely to resemble an absolute path.

## Bilingual line alignment

Keep English and Simplified Chinese equally authoritative. Match frontmatter key order, headings, blank lines, paragraphs, list items, tables, code fences, link targets, and total physical line count one to one. The English side points every relative link at the `.md` target; the Chinese side points it at the `.zh.md` sibling when that counterpart exists and falls back to the `.md` target otherwise — the pairing gate compares `.md` and `.zh.md` targets as the same document. Translate prose naturally within its corresponding line; do not hard-wrap either language. Keep code blocks byte-identical and reposition first-use terminology annotations without changing line structure.

Line equality is a structural check, not proof of faithful meaning. Review still owns completeness, terminology, natural language, and whether each line expresses the same proposition.

## Bilingual consistency records

Keep the `*.i18n.yaml` sidecar for every bilingual pair. `verify-translation-pairing` consumes its Git blob hashes for last-confirmed-text recovery, verifies structure and exact line alignment, supports automatic merging, records generated regions, and seals archives. Re-record it with `pnpm run verify-translation-pairing --write <pair>` after either language changes. Do not copy content hashes into README frontmatter: independent edits would change the same header line and turn otherwise mergeable prose into an owner-file conflict.

## Dev Note

None.

"""

    /// Upstream `.agents/skills/dsh-doc/references/review.md` — 6060 bytes, sha256 81F5BB876AD13BD2…
    private static let docFile_references_review = """
# Review criteria

## Summary

Review documentation by whether a reader completes an outcome, not by whether every template heading exists. Verify prose against code and tests, preserve exact contracts, and keep package READMEs useful to consumers while exposing enough implementation detail for maintainers. Run current repository gates; the `session-persistence-jsonl` README pair is the reference example of the format.

## Table of Contents

- [Newcomer test](#newcomer-test)
- [Evidence review](#evidence-review)
- [Package README review](#package-readme-review)
- [Reference example](#reference-example)
- [Verification](#verification)
- [Dev Note](#dev-note)

## Newcomer test

A professional engineer with no repository context should answer the following after three to five linked pages: what the product or feature does, how to run or use it safely, where its state lives, which component owns it, how it fails, and where to change it. If the reader must inspect source merely to discover the public flow, restore the missing explanation. If the reader must absorb unrelated internals, move those details deeper.

## Evidence review

Check each material statement against its strongest owner. Use package metadata for names and entry points, public types and JSDoc for API contracts, runtime code for behavior, tests for exercised failure paths, generated catalogs for exhaustive inventories, and active Agent Notes for rationale. Never treat a prior README, discussion, or report as stronger than current code and tests.

For every operational claim — a CLI command, a config snippet, a default value, an error message, a platform difference — the evidence is running it, not reading it. Execute the exact command or mount the exact configuration against the current checkout before the page may state its behavior; quote only observed output, warnings, and failures. Claims that depend on unavailable keys or networks name their verification owner instead of asserting behavior. For pre-existing pages, compare against latest `origin/master` and re-verify stale statements against code.

Classify the package before reviewing its install guidance: `dsh.bundle.patch` in `package.json` makes it a bundle (installable via `dsh plugin --profile <name> add <package>`, the only shape that command activates as a layer); an `apply` export or default service export makes it a plugin (mounted as a `cordis.yml` row); a plain module API makes it a library (a dependency with no install path). Reject install guidance written for another shape.

Retain a statement only when it helps the target reader act, reason, or avoid misuse. Move rationale, history, test walkthroughs, duplicate catalogs, and unrelated package detail to their owners.

## Package README review

Require the following without forcing one universal internal heading set:

- searchable YAML metadata with a precise `description` and the mechanically derived `kind` (`package-group`, `package-reference`, `package-library`, or `package-bundle`);
- a three-to-five-sentence English Summary of at most 100 `wc -w`-style words that says what the subject DOES for its user or agent reader, with a linked Table of Contents;
- controlled English with explicit actors, stable terms, direct verbs, separated instructions and conditions, and unchanged modality;
- when to choose or avoid the package;
- a smallest safe configuration or usage path when one exists — for a bundle, the verified `dsh plugin` install path; for a library, the consumer entry point; never profile-install guidance for a shape that does not take it;
- observable behavior, failures, durability, security, and performance limits relevant to consumers;
- developer-facing ownership and data/lifecycle design at concept level — overall design, architecture, hand-waving dataflow — that cannot be recovered cheaply from public types, with code links for exact detail;
- canonical Model Experience and Known Limitations sections required by package policy;
- newcomer-facing Further Exploration where adjacent docs materially help;
- a final non-authoritative Dev Note as the only home for partial ideas, scratches, and undecided directions.

Do not restate JSDoc or generated catalogs. Link the owner and explain only the decision or relationship needed locally. A package Summary describes reader-visible capability rather than Cordis roles, registrations, or internal components, and it omits source identifiers unless readers directly use them in configuration, commands, or a public API. Reject any user-facing section that narrates internals (function subjects, event streams, data flow) and any fold that enumerates APIs instead of explaining the concept.

## Reference example

The `session-persistence-jsonl` README pair ([English](../../../../packages/session/session-persistence-jsonl/README.md), [Chinese](../../../../packages/session/session-persistence-jsonl/README.zh.md)) demonstrates the format in production: searchable YAML whose `kind` selects this package-reference standard, a four-sentence Summary, a linked Table of Contents, a user-facing use section covering selection, configuration, layout, durability, and reading, a GitHub-native `<details>` fold for developer-facing design and storage details, Further Exploration, canonical Model Experience and Known Limitations sections, and a final Dev Note. Use its structure, evidence standards, and bilingual alignment as the model for package READMEs and cross-package pages; ground every claim in its owning source and evidence.

## Verification

Run the smallest focused checks while iterating, then the standing documentation checks:

```sh
pnpm run test:docs
pnpm run verify-translation-pairing --write <pair>
pnpm run doc-sync
pnpm run lint
git diff --check
```

Also run the repository's skill-invocation metadata check for skill changes and compare English/Chinese physical line counts for a line-aligned pair. Re-read the final diff once for factual completeness and once for brevity, navigation, and ownership.

## Dev Note

None.

"""

    /// Upstream `.agents/skills/dsh-doc/references/structure-hierarchy.md` — 6276 bytes, sha256 869AE393BE457951…
    private static let docFile_references_structure_hierarchy = """
# Page structure and hierarchy

## Summary

Each page gives a newcomer a short front door before it exposes operational or implementation depth. Cross-package learning and engineering material lives under a deliberate `docs/` hierarchy, while package contracts stay beside code. Small rule files own one independently searchable requirement, but arbitrary fragmentation is not a goal. The final Dev Note isolates active working context from the stable explanation above it.

## Table of Contents

- [Page order](#page-order)
- [Section progression](#section-progression)
- [Documentation hierarchy](#documentation-hierarchy)
- [Small rule files](#small-rule-files)
- [Further Exploration](#further-exploration)
- [Dev Note ownership](#dev-note-ownership)
- [Dev Note](#dev-note)

## Page order

Use this order for authored human-facing pages when the format owner permits it. Generated artifacts may generate the same entry sections, while Agent Notes and postmortems retain their repository-defined skeletons.

1. YAML metadata.
2. H1 title.
3. Language switcher for a bilingual page.
4. `## Summary`: three to five explanatory sentences stating what the reader can do or observe, why a reader would care, the main operating model, and the most important boundary. English package README Summaries stay within the gate-owned 100-word limit.
5. `## Table of Contents`: links to the page's H2 sections; keep it navigational rather than descriptive.
6. Stable content, ordered from user-facing use to developer-facing design and operational detail.
7. Optional `## Further Exploration` for newcomer-oriented links to adjacent subjects.
8. Final `## Dev Note` for non-authoritative active working context.

Do not force a Summary/Table of Contents wrapper around tiny machine-owned files, generated fragments, or formats whose executed parser defines another header. State the exception in the format owner rather than creating invalid output. The package README gate requires `Model Experience` and `Known Limitations and Deferred Work` as the final two H2 sections: place `Further Exploration` before them and end with a final `### Dev Note` inside the limitations H2.

## Section progression

Open every substantive H2 with a short orienting paragraph before tables, code, or H3 subsections. Explain the section's subject and decision-relevant point; do not repeat its complete contents.

Within a page, order content by reader depth:

1. Basic use: when to choose the feature, required inputs, shortest safe example, observable success, and likely recovery.
2. Advanced use: configuration choices, limits, operations, and integration behavior.
3. Developer detail: ownership, lifecycle, data model, failures, performance, security, and extension points worth maintaining.

Fold heavy developer detail and the final Dev Note behind `<details>` blocks with the section titles visible (mechanics in [style.md](style.md)).

Folded developer detail is concept-level by requirement: the overall design concept, the architecture of the main components, and hand-waving dataflow — enough to understand how the package works — plus source-map tables and links to code for exact detail. It never becomes an exhaustive catalog: no full API inventories, column lists, event-payload enumerations, or JSDoc restatement. The Dev Note is the only place allowed to hold partial ideas, scratches, and undecided directions; everything else, folds included, is polished current-state prose.

Keep exhaustive generated types, schemas, or catalogs behind a compact entry paragraph and stable index. Split them by an existing domain owner when one lookup requires scanning unrelated groups.

## Documentation hierarchy

Use package-local READMEs for package contracts and keep them next to source. Organize cross-package Markdown under audience and learning intent instead of leaving unrelated pages flat at `docs/`.

```text
docs/
  learn/
    overview/
    cordis/
    practices/
  user/
  developer/
    discussion/
  scratch/
  subsystems/
```

Treat this as a target map, not permission for an opportunistic mass move. Move one coherent topic at a time, repair every inbound link and website mapping atomically, preserve public routes or aliases, and keep `subsystems/` flat because its pages are logically parallel.

`docs/scratch/` contains tracked, expiring discussion that must survive a handoff. Each scratch page names its owner, creation date, expiry, and promotion target. Local disposable notes remain ignored and uncommitted.

## Small rule files

Give an independently searchable rule, practice, example family, or decision one small file when it has its own owner, change cadence, inbound links, or validation. Group related files under a descriptive hierarchy such as `docs/developer/code-quality/`. Keep tightly coupled rules together when splitting would force readers to open several files to understand one obligation.

An index page explains the folder in three to five sentences and links its direct children by purpose. It does not restate each child's rule.

## Further Exploration

Use this optional section for a newcomer who finished the page and wants adjacent understanding. Link three to seven directly related pages, order them from closest prerequisite to deeper exploration, and say in a short phrase what each adds. Do not turn it into a complete site index.

## Dev Note ownership

End authored pages with Dev Note, but keep it explicitly non-authoritative. Active hypotheses, compatibility concerns, rough alternatives, progress pointers, and unresolved questions may live there; stable behavior, required limitations, and accepted rationale belong in their ordinary owners.

Dev Note may mirror or link task progress but must not become a second writable queue. When work closes, promote durable conclusions, move reusable rationale to an Agent Note, keep incident chronology in a postmortem, and delete resolved chatter. Git history preserves old iterations.

## Dev Note

The mandatory final section is intentionally the least polished part of an authored page, but it still has lifecycle discipline. A blank Dev Note should say `None.` rather than accumulate placeholder prose; generated and parser-owned formats may omit it through a named exception.

"""

    /// Upstream `.agents/skills/dsh-doc/references/style.md` — 4117 bytes, sha256 62600401BC7D771E…
    private static let docFile_references_style = """
# Page style

## Summary

Page-level style preferences that make DSH pages scannable and difficult to misread: a short Summary, controlled technical English, `-----` separators between major parts, `<details>` folds that keep section titles visible, and disciplined emphasis. The template is the `session-persistence-jsonl` README pair.

## Table of Contents

- [Short summary](#short-summary)
- [Controlled technical English](#controlled-technical-english)
- [Section separators](#section-separators)
- [Foldable content sections](#foldable-content-sections)
- [Emphasis discipline](#emphasis-discipline)
- [Dev Note](#dev-note)

## Short summary

Open every authored page with a short `Summary`: three to five sentences in one paragraph stating what the reader can do or observe, why the reader cares, the operating model, and the most important boundary. The Table of Contents and the sections carry the detail; placement and section order live in [structure-hierarchy.md](structure-hierarchy.md). An English package README Summary is additionally limited to 100 `wc -w`-style words by `verify-package-readme-summaries`.

## Controlled technical English

Use an [ASD-STE100](https://www.asd-ste100.org/)-inspired review pass for English prose that an agent, translator, or non-native reader must parse. This is a clarity discipline, not certified ASD-STE100 compliance. The repository does not reproduce or validate the standard's controlled dictionary.

- Name the actor and action. Prefer active voice when the actor matters.
- Use one stable term for each concept. Do not rotate synonyms for variety.
- Prefer direct verbs. Replace nominalizations and ambiguous phrasal verbs when a precise verb exists.
- Put one instruction in each sentence. Use a list for three or more steps or conditions.
- Split semicolons and long clause chains. Keep each paragraph on one topic.
- Remove unsupported quality adjectives and stacked hedges. Preserve every fact and degree of uncertainty from the source.

Treat 20 words for an instruction and 25 words for a description as review prompts, not mechanical gates. Keep a longer sentence when a split would hide a condition or relationship. Never remove or strengthen `must`, `may`, `never`, timing, exceptions, numbers, or other contract terms to meet a length target. The [prose standard](../../dsh-prose-standard/SKILL.md) owns the complete-proposition rule.

## Section separators

Separate the major parts of a page with a `-----` horizontal rule on its own line, with a blank line before and after it. A rule directly after a paragraph would parse as a Setext heading, and a rule inside the final two H2 sections of a package README would break the Model Experience gate. The template separates: front matter → use section → folded developer section → Further Exploration → Model Experience.

## Foldable content sections

Fold developer-facing detail and the final Dev Note behind GitHub-native `<details>`/`<summary>` blocks. Keep the section title (H2 or H3) and its `<a id>` anchor visible; fold only the content under the title. Inside the block, put a blank line after `<summary>`, keep every Markdown line at column 0 (indented content becomes a code block), and close with `</details>` after a blank line. Headings, lists, tables, and links inside the fold parse normally and keep their anchors. The `session-persistence-jsonl` README pair demonstrates both folds: the implementation section and the Dev Note.

In a package README, keep `## Model Experience` and `## Known Limitations and Deferred Work` as the final two H2 headings. Put the limitations anchor immediately after its H2 so it does not become part of the preceding Model Experience body. Place the final Dev Note under the limitations section as an anchored H3. A package that is explicitly exempt from the limitations section can use an H2 Dev Note.

## Emphasis discipline

Reserve bold for the clause that changes behavior or for the comparison that matters. In benchmark tables, bold the column headers and the best value in each row, as in the reference example.

## Dev Note

None.

"""

    /// Upstream `.agents/skills/dsh-doc/references/website-sync.md` — 6850 bytes, sha256 6AB2DC43AA43C964…
    private static let docFile_references_website_sync = """
# Website publication

## Summary

The documentation website is a tested projection of repository Markdown, never a second copy. [website/docs.ts](../../../../website/docs.ts) is the explicit public allowlist, [scripts/project-doc-site.ts](../../../../scripts/project-doc-site.ts) rewrites mapped sources into the disposable `website/.generated/` tree, and VitePress builds that tree. The build also emits a raw-Markdown twin of every route and a root `llms.txt` index from the same manifest. This reference owns the manifest fields, the projector's link rules, preview and validation commands, and the deployment boundary.

## Table of Contents

- [Manifest ownership](#manifest-ownership)
- [Classify the change](#classify-the-change)
- [DocsPage fields](#docspage-fields)
- [Preserve link behavior](#preserve-link-behavior)
- [Preview and validate](#preview-and-validate)
- [Keep deployment separate](#keep-deployment-separate)
- [Dev Note](#dev-note)

## Manifest ownership

Read [docs/AGENTS.md](../../../../docs/AGENTS.md) and the current `DocsPage` type and entries in [website/docs.ts](../../../../website/docs.ts) before changing the manifest; do not rely on a remembered field set. Read [website/.vitepress/config.ts](../../../../website/.vitepress/config.ts) before adding a new section, sidebar collection, locale, or top-level navigation item. For an edited bilingual source, follow the lightweight routine path in [docs/AGENTS.md](../../../../docs/AGENTS.md#writing-rules) and the [pairing contract](../../../../docs/i18n/README.md); never invoke the extended translation skill automatically.

Never edit or commit `website/.generated/`, `website/.cache/`, or `website/.dist/`. Except for `website/AGENTS.md`, never add Markdown under `website/`; locale and route directories such as `website/zh-CN/`, `website/en/`, and `website/api/` are invalid source layouts. Keep generated catalogs under `docs/`, freshness-gate them there, and publish them through the manifest.

## Classify the change

- **Edit an already published page:** change only its canonical Markdown source. Do not touch the manifest unless its route or navigation metadata changes.
- **Publish a new page:** create it in its owning `docs/` tier, then add one manifest entry.
- **Rename, move, or remove a page:** update the canonical file, manifest entry, and inbound repository links atomically. Remove stale manifest entries; `docs:check` rejects missing sources.
- **Publish a generated catalog:** map the generated `docs/` file, but change its generator or source metadata rather than editing the catalog by hand.
- **Change site structure:** update the manifest for ordinary pages; update VitePress configuration only when the existing sidebar, section, or locale model cannot express the change.

Keep the manifest an explicit public allowlist. Do not publish RFCs, postmortems, testing guides, `AGENTS.md`, or maintainer workflows merely because they exist under `docs/`; add internal material only when the user explicitly expands what the site publishes.

## DocsPage fields

Set every `DocsPage` field deliberately. The canonical field set and the `DocsSidebar` union live in [website/docs.ts](../../../../website/docs.ts) — read them there rather than copying values into prose; sections are owned by the `sections` record in that file, with no separate order list in the VitePress config.

- `source`: repository-relative canonical Markdown path. For a complete bilingual pair, add the English `.md` path through `pairedPages()`; it derives the sibling `.zh.md`, the content locales, and counterpart aliases.
- `route`: public VitePress path including the `.md` suffix.
- `label`: sidebar label, not necessarily the document H1.
- `sidebar`: reuse an existing `DocsSidebar` collection unless the information architecture genuinely needs another one.
- `section`: reuse an existing section when possible. If adding one, also define it in the `sections` record.
- `order`: stable order within the section.
- `sourceAliases`: optional additional repository paths that should resolve to this page when links are projected. It does not create another public route.

Use `mirroredPages()` only for a source that intentionally falls back to the same available language in both route trees. Convert that entry to `pairedPages()` when its counterpart is added. The site route trees are independent of the source layout: `foo.zh.md` projects to the root route and `foo.md` projects to the matching `/en/` route.

## Preserve link behavior

Write normal repository-relative Markdown links in canonical docs. The projector applies these rules:

- A target present in the manifest becomes a site-relative route.
- An existing target outside the manifest becomes a GitHub source link, including supported line suffixes.
- An image is the exception: its file is copied into the generated tree and referenced from there, so the site serves it regardless of repository visibility. It must be a regular file inside the repository.
- External URLs, site-absolute URLs, email links, and fragment-only links remain unchanged.
- A missing repository-relative target fails projection instead of silently producing a broken link.
- Cross-page fragments use the English GitHub heading id as their canonical id. If an authored heading emits a different VitePress id, place an explicit `<a id="..."></a>` immediately before it; add generated aliases in the owning generator.

Do not write website-specific routes into canonical Markdown just to satisfy VitePress. Use `sourceAliases` for directory-style repository links that should resolve to a mapped index page.

## Preview and validate

Run local preview while editing:

```sh
pnpm docs:dev
```

The dev server watches mapped source files and reprojects them. Restart it after changing the manifest if the new source is not picked up automatically.

Run the focused website gate before treating the mapping as valid:

```sh
pnpm docs:check
```

If Markdown link checks pass but the site build reports a missing fragment, follow the `verify-doc-site-fragments` source and target paths. Preserve the English GitHub id with an explicit alias in authored Markdown or in the owning generator.

Before committing a documentation-site change, run:

```sh
pnpm run test:docs
pnpm run doc-sync
pnpm run lint
git diff --check
```

Use [dsh-pre-push-checks](../../dsh-pre-push-checks/SKILL.md) before pushing. Report the canonical files changed, manifest entries added or removed, public routes affected, and the exact checks run.

## Keep deployment separate

Synchronizing content into the VitePress build does not publish it to the internet. Do not add GitHub Pages permissions, deployment workflows, custom domains, or public hosting unless the user explicitly requests deployment and confirms the hosting policy.

## Dev Note

None.

"""

    /// Upstream `.agents/skills/dsh-doc/templates/package-bundle.md` — 3409 bytes, sha256 9F6751700F4886B8…
    private static let docFile_templates_package_bundle = """
# Template: package-bundle

Use this template for a package whose manifest declares `dsh.bundle.patch` — an installable profile layer: `packages/bundle/*`, `dsh-subagent-codex`, `dsh-subagent-claude-code`. The `bundle/base` README pair is the worked example.

A bundle README leads with the profile-install path and the layer semantics; the implementation fold explains the patch document. It never presents the package as a library to import or as a single plugin to mount.

## Frontmatter

```yaml
---
description: "What the bundle layer adds to a dsh --profile surface, for users composing or customizing a profile."
kind: "package-bundle"
---
```

## Skeleton

```markdown
# @deepseek-ai/dsh-<name>

English | [中文](README.zh.md)

## Summary

Three to five sentences and at most 100 `wc -w`-style words: what a profile gains from this layer, which profiles already include it, how a user adds or removes it, and the main boundary. Apply the [Summary voice rules](../SKILL.md#voice-rules).

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Further Exploration](#further-exploration)
- [Model Experience](#model-experience)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

### Install into a profile

The verified install path — run it against the current checkout before writing:

```text
dsh plugin --profile <name> add @deepseek-ai/dsh-<name>
dsh plugin --profile <name> remove @deepseek-ai/dsh-<name>
```

State where in-box bundles resolve from, what the reconcile step activates, and what fails when the patch declaration is missing.

### What you get

The observable surface this layer adds: tools, providers, or UI rows, and which package owns each row's behavior.

-----

<a id="understand-the-implementation"></a>
## Understand the implementation

<details>
<summary>Implementation internals — click to expand</summary>

The patch document: insert list, row ids, platform gating, override semantics. Source-map table links `cordis.patch.yml` and `src/`. No API catalogs.

</details>

-----

<a id="further-exploration"></a>
## Further Exploration

Adjacent pages: the group map, the profile contract, the composition graph.

-----

<a id="model-experience"></a>
## Model Experience

The form the verify-package-readme-model-experience gate assigns (bundle carriers are `indirect` or `none`: each inserted row's package owns its model-facing behavior).

## Known Limitations and Deferred Work

<a id="known-limitations-and-deferred-work"></a>

Current constraints: override semantics, platform gates, and conflict rules a user must respect.

<a id="dev-note"></a>
### Dev Note

<details>
<summary>Working context for maintainers — click to expand</summary>

None.

</details>
```

## Rules

- **Only `dsh.bundle.patch` packages use this template.** Verify the declaration in `package.json` before classifying; the `dsh plugin` reconcile activates a layer for exactly these packages.
- **Test the install path.** Run `dsh plugin --profile <name> add <this-package>` in a scratch profile and reproduce the documented warning, layer activation, and failure modes before writing them.
- Re-run `pnpm run verify-translation-pairing --write packages/<group>/<pkg>/README.md` after editing the pair.

"""

    /// Upstream `.agents/skills/dsh-doc/templates/package-group.md` — 1867 bytes, sha256 53CB8A73B3D465E8…
    private static let docFile_templates_package_group = """
# Template: package-group

Use this template for `packages/README.md` and every `packages/<group>/README.md`. The page is a map: it orients the capability family, lists its direct packages with one-line roles, and links package-owned details. It never restates a package's contract.

## Frontmatter

```yaml
---
description: "The <group> package group: what the packages under packages/<group>/ own, for readers choosing or navigating the family."
kind: "package-group"
---
```

## Skeleton

```markdown
# <group>/ — <one-line subject>

English | [中文](README.zh.md)

## Summary

Three to five sentences and at most 100 `wc -w`-style words: what the family provides, what a reader can DO with it, which package owns which half, and the main boundary. Apply the [Summary voice rules](../SKILL.md#voice-rules).

## Table of Contents

- [Packages](#packages)
- [Related documentation](#related-documentation)
- [Dev Note](#dev-note)

-----

<a id="packages"></a>
## Packages

One short orienting sentence, then the package map:

| Package | Role |
|---|---|
| [`<pkg>`](<pkg>/README.md) | One-line role: what it contributes |

<a id="related-documentation"></a>
## Related documentation

- [Adjacent owner](../../<path>.md) — what it adds to this family.

<a id="dev-note"></a>
## Dev Note

None.
```

## Rules

- One row per direct package; role text states the package's contribution, never its internals.
- Add a `ctx key`, package shape, or npm-name column only when that distinction helps readers choose among the direct packages.
- Related documentation links adjacent owners (group maps, subsystem pages, Agent Notes) with a short phrase per link.
- Do not add a Model Experience or Known Limitations section; the group map owns no runtime behavior.
- Re-run `pnpm run verify-translation-pairing --write packages/<group>/README.md` after editing the pair.

"""

    /// Upstream `.agents/skills/dsh-doc/templates/package-library.md` — 3546 bytes, sha256 E65883A53950806E…
    private static let docFile_templates_package_library = """
# Template: package-library

Use this template for a package with no plugin surface: its entry exports a plain module API and it registers nothing into a composition. Examples: `boot/app-boot`, `util/*`, `sdk/protocol`, `typert/generator`. The `boot/app-boot` README pair is the worked example.

A library README differs from a package reference in three ways: no "install into a profile" guidance (a library is a dependency, not a layer), no mount configuration (there is no `cordis.yml` row), and a Model Experience section only in the audited form the gate assigns (most libraries are `none` or `indirect`).

## Frontmatter

```yaml
---
description: "What the library lets a caller build, in one or two concrete sentences with the consuming packages or searchable domain terms."
kind: "package-library"
---
```

## Skeleton

```markdown
# @deepseek-ai/dsh-<name>

English | [中文](README.zh.md)

## Summary

Three to five sentences and at most 100 `wc -w`-style words: what a caller can DO with the library, who consumes it, the smallest entry point, and the main boundary. Apply the [Summary voice rules](../SKILL.md#voice-rules).

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Further Exploration](#further-exploration)
- [Model Experience](#model-experience)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

### When to use it

Name the consuming call sites (which bins, packages, or runtimes import it) and when a caller should reach for it instead of a plugin.

### Entry point

The smallest import-plus-call that works, in a `text` or `ts` fence, followed by what success and failure look like. Link the owning contracts in `src/index.ts` for exact detail instead of restating them.

-----

<a id="understand-the-implementation"></a>
## Understand the implementation

<details>
<summary>Implementation internals — click to expand</summary>

Design notes and a source-map table. No API catalogs.

</details>

-----

<a id="further-exploration"></a>
## Further Exploration

Adjacent pages, closest prerequisite first.

-----

<a id="model-experience"></a>
## Model Experience

Only the form the verify-package-readme-model-experience gate assigns this package (`none`, `indirect`, or the canonical blocks). A library never invents model effects it does not have.

## Known Limitations and Deferred Work

<a id="known-limitations-and-deferred-work"></a>

Current package constraints as top-level bullets; allowlist the package in scripts/verify-package-readme-limitations.ts when none exist.

<a id="dev-note"></a>
### Dev Note

<details>
<summary>Working context for maintainers — click to expand</summary>

None.

</details>
```

## Rules

- **Classify by the entry, not the folder.** Read `src/index.ts` before choosing this template: `export default` a service class or an `apply` export makes the package a `package-reference`, and `dsh.bundle.patch` in `package.json` makes it a `package-bundle`. A plain module API without those is a library.
- **Never write profile-install guidance.** `dsh plugin --profile <name> add <package>` installs any npm dependency but activates a profile layer only for `dsh.bundle`-declaring packages; for a library it is at best a no-op dependency and must not appear as an install path.
- Re-run `pnpm run verify-translation-pairing --write packages/<group>/<pkg>/README.md` after editing the pair.

"""

    /// Upstream `.agents/skills/dsh-doc/templates/package-reference.md` — 3860 bytes, sha256 B9E75748BD32B409…
    private static let docFile_templates_package_reference = """
# Template: package-reference

Use this template for a package whose entry is a Cordis plugin — a service default export or an `apply` function — mounted in a composition. This is the default for `packages/<group>/<pkg>/README.md`. The `session-persistence-jsonl` README pair is the worked example of this template.

## Frontmatter

```yaml
---
description: "What the package lets a reader choose, configure, or debug, in one or two concrete sentences with searchable domain terms."
kind: "package-reference"
---
```

## Skeleton

```markdown
# @deepseek-ai/dsh-<name>

English | [中文](README.zh.md)

## Summary

Three to five sentences and at most 100 `wc -w`-style words on what a user or agent can DO with the package: outcomes, when to choose it, main cost, most important boundary. Apply the [Summary voice rules](../SKILL.md#voice-rules); never describe its role, type, or internal identity.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Further Exploration](#further-exploration)
- [Model Experience](#model-experience)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

One orienting sentence: the common path.

### When to choose it

Choose or avoid the package: one paragraph naming the deciding conditions and the fallback package.

### Minimal configuration

The smallest mount that works, as a `cordis.yml` snippet, plus the config table:

| Field | Default | Meaning |
|---|---|---|
| `<field>` | `<default>` or `required` | One-line meaning |

The generated [configuration catalog](../../../docs/config-catalog.md#deepseek-aidsh-<name>) is the exhaustive source for every accepted field.

-----

<a id="understand-the-implementation"></a>
## Understand the implementation

<details>
<summary>Implementation internals — click to expand</summary>

Design concept, component architecture, and hand-waving dataflow — enough to understand the package. A source-map table links files for exact detail. No API catalogs or JSDoc restatement.

</details>

-----

<a id="further-exploration"></a>
## Further Exploration

Three to seven adjacent pages, closest prerequisite first, one short phrase each.

-----

<a id="model-experience"></a>
## Model Experience

<per the Model Experience contract in docs/cookbook/adding-a-package.md#4-write-the-package-readme; the verify-package-readme-model-experience gate owns the required form>

## Known Limitations and Deferred Work

<a id="known-limitations-and-deferred-work"></a>

One orienting sentence, then top-level bullets naming current package constraints. Packages with none use the allowlist in scripts/verify-package-readme-limitations.ts.

<a id="dev-note"></a>
### Dev Note

<details>
<summary>Working context for maintainers — click to expand</summary>

None.

</details>
```

## Rules

- **Fact-check before writing.** Mount the package in a test composition and run every command, config field, default, and behavior claim this README makes. Delete anything you did not reproduce; link the generated config catalog instead of restating fields.
- **Installation guidance.** A plugin package mounts through `cordis.yml` rows. Only a package declaring `dsh.bundle.patch` installs as a profile layer via `dsh plugin --profile <name> add <package>` — if this package lacks that declaration, say how it mounts in a composition, never `dsh plugin add`.
- **Model Experience and Known Limitations are gate-owned.** Match the exact headings and per-package forms the two gates enforce; update the gates' audited lists in the same change when behavior moves a package between forms.
- Re-run `pnpm run verify-translation-pairing --write packages/<group>/<pkg>/README.md` after editing the pair.

"""

    /// Upstream `.agents/skills/dsh-doc/templates/persistence-change.md` — 3940 bytes, sha256 984451269BE8F0D5…
    private static let docFile_templates_persistence_change = """
# Template: persistence-change

Use this template for `docs/persistence-changes/YYYY-MM-DD-slug.md` and its Chinese sibling. The folder README is an index, not a record. A record acknowledges only mechanically detected persistence-type changes. Its generated JSON sibling retains complete after schemas so verification needs no Git baseline.

## Frontmatter

```yaml
---
description: "The persisted types changed and the compatibility decision this record explains."
kind: persistence-change
---
```

## Skeleton

The generator fills the machine declaration, schema companion, and consistency records, inferring the minimum version decision from the fixed rules. Supply `--prose` JSON with `en` and `zh` objects, each containing authored `summary`, `compatibility`, and `verification` strings; the [cookbook](../../../../docs/cookbook/reviewing-persistence-type-changes.md) shows the complete operation. The following values illustrate the document fields; use the actual generated root names, record ids, and digests.

````markdown
# Persistence change: <specific persisted change>

English | [中文](YYYY-MM-DD-slug.zh.md)

## Summary

Describe the mechanically detected change and its version decision.

## Table of Contents

- [Declaration](#declaration)
- [Compatibility](#compatibility)
- [Verification](#verification)
- [Dev Note](#dev-note)

<a id="declaration"></a>
## Declaration

```yaml persistence-change
schemaVersion: 1
id: YYYY-MM-DD-slug
baseline: false
changes:
  - root: event:example/message
    previous: YYYY-MM-DD-predecessor
    after: <generated-64-character-sha256-hex>
    decision: same-version
```

<a id="compatibility"></a>
## Compatibility

Explain the declared decision for the detected paths. For an optional addition, explain why existing records can omit it and older readers can ignore it without changing replay. For required-to-optional changes, explain how readers handle absence. For a version bump, link the adjacent migration and its verification owner.

<a id="verification"></a>
## Verification

Record the commands actually run and their outcomes. Link focused tests or preserved evidence that support the compatibility explanation.

<a id="dev-note"></a>
## Dev Note

None.
````

## Rules

- Keep exactly one `yaml persistence-change` block. The English and Chinese blocks are byte-identical; the verifier parses the English record once and checks its counterpart.
- The filename stem and `id` agree. A root's `previous` identifies its predecessor record; `null` introduces a root. Its `after` matches the generated companion schema digest; `null` records deletion.
- One initial `baseline: true` record covers the complete inventory. Routine changes use `baseline: false` and preserve accepted predecessors. A version-bump record carries its own increasing `SessionHeader.version` transition.
- Omit `--decision` in the ordinary authoring flow. An explicit value asserts the decision and cannot bypass classification or the required header increase. The command supplies no source changes or validation claims.
- Explain only the detected persistence-type changes. This kind permits the before/after facts and historical evidence needed for that transition; behavior-only changes remain out of scope.
- Record creation and terminal-record update generate the catalog pair and consistency sidecars. Review both languages and retain the generated companions. Direct prose edits still require re-recording pairing; do not hand-maintain schema nodes or digests.
- Use explicit `--update` only for an unaccepted terminal record. It rejects baselines and depended-on records; `--prose` replaces its authored explanations, while omission preserves them. Accepted records receive successors.
- The [folder reference](../../../../docs/persistence-changes/README.md) owns compatibility rules; the [cookbook](../../../../docs/cookbook/reviewing-persistence-type-changes.md) owns commands and recovery.

"""

    /// Upstream `.agents/skills/dsh-doc/templates/persistence-format.md` — 2412 bytes, sha256 8E2CFD248807A49F…
    private static let docFile_templates_persistence_format = """
# Template: persistence-format

Use this kind for `docs/persistence-changes/historical-formats/vN.md` and its Chinese sibling. Each record describes one explicitly selected historical Session format checkpoint with complete declared types. It is a format reference, not a release record or compatibility acknowledgement. The checkout writer uses the existing current catalog.

## Frontmatter

```yaml
---
description: "The historical Session format, source checkpoint, and persistence types documented here."
kind: persistence-format
---
```

## Sections

1. **Summary:** identify the format and its distinguishing persisted fields.
2. **Table of Contents:** link subsequent sections with shared bilingual anchors.
3. **Source evidence:** name the tag or PR and enough context to select the source tree. A PR's intermediate tree must not be presented as its final merge or as a product release. Historical sources use file paths without line numbers and remain text unless linked to the exact source.
4. **Format characteristics:** explain header, event, and physical encoding distinctions; link codec owners for behavior beyond the declared-type inventory.
5. **Declaration:** include one identical `yaml persistence-format` block per language with `schemaVersion: 1`, numeric `sessionFormatVersion`, `source` containing exactly one `tag` or numeric `pullRequest`, and a `roots` mapping from every root key to its captured SHA-256 digest. Link the sibling `vN.schema.json`.
6. **Complete schemas:** keep one `persistence-format-schema:start` / `persistence-format-schema:end` comment region. The format verifier renders root digests and all reachable definitions here.
7. **Verification and limitations:** state actual extraction evidence, coverage limits, and the offline verifier. Preserve historical optional fields and opaque declarations without claiming codec admission or migration safety.
8. **Dev Note:** reserve non-authoritative working context, or write `None.`.

The [format index](../../../../docs/persistence-changes/historical-formats/README.md) owns coverage and maintenance. `pnpm run verify-persistence-formats --write` validates schemas before refreshing generated regions and pairing records. It cannot create historical evidence or repair machine data. Keep every older integer documented when the current writer advances; do not duplicate the current catalog under a historical filename.

"""

    /// Upstream `.agents/skills/dsh-doc/templates/persistence-release.md` — 3123 bytes, sha256 641B2C8A78DA2D88…
    private static let docFile_templates_persistence_release = """
# Template: persistence-release

Use this kind for `docs/persistence-changes/releases/dsh-v<version>.md` and its Chinese sibling. These records reconstruct tagged persistence types for human comparison and format validation. They are observations, not compatibility acknowledgements, and do not participate in the current-source history.

## Frontmatter

```yaml
---
description: "The tagged persistence types and adjacent-release differences recorded here."
kind: persistence-release
---
```

## Sections

1. **Summary:** explain the concrete type differences or lack of differences from the preceding available tag and state the Session writer version when relevant.
2. **Table of Contents:** link the following sections with shared bilingual anchors.
3. **Release evidence:** name the source tag and tagged source paths, then link the preceding record and schema companion with relative paths. Identify reconstruction limits.
4. **Declaration:** include exactly one `yaml persistence-release` block with `schemaVersion: 1`, `tag`, `previous`, `sessionFormatVersion`, and `changes`. Each change names `root`, `before`, and `after`; null represents absence. Both languages contain identical machine blocks.
5. **Structural changes:** list mechanically detected paths and kinds. Current-rule classifications are informational; they do not establish historical release safety or imply that the observed writer version increased.
6. **Verification:** state executed reconstruction and validation evidence. `pnpm run verify-persistence-releases` validates the committed archive without source checkouts, Git, or network access.
7. **Dev Note:** reserve this section for non-authoritative working context, or write `None.`.

## Snapshot and history rules

The [archive reference](../../../../docs/persistence-changes/releases/README.md) owns the pinned release manifest and extraction limits. The first record contains every extracted root; later schema companions contain only changed roots that remain present, with all their reachable type definitions. Empty changes and snapshots preserve releases with unchanged types. Each record references the immediately preceding manifest entry.

The index table, inventory cell, and structural-change facts use `persistence-release-index`, `persistence-release-inventory`, and `persistence-release-changes` start/end comment markers. Keep human explanations outside these generated regions. `pnpm run verify-persistence-releases --write` validates all machine data before refreshing factual regions and pairing records; it preserves authored prose, machine declarations, and schema files. Default verification rejects stale generated facts and missing fixed index files.

Keep source `number` declarations and historical optional fields intact. Report actual writer version constants separately. Historical parsing permits optional `surfaceOp` for surface events; the live persistence parser and acknowledgement rules remain strict. Never insert these retrospective records into the current-source acknowledgement chain or rewrite the committed baseline to accommodate old releases.

"""


    // MARK: - dsh-doc bundled files

    /// One same-directory file that ships beside an installed SKILL.md.
    struct DSHBundledFile {
        /// Path relative to the installed skill directory (POSIX separators).
        let path: String
        /// iSH `file(1)` reads the suffix; "markdown" renders a text preview
        /// in the rootfs file browser instead of a hex dump.
        let kind: String
        /// UTF-8 byte count of `content`, carried so a hand-edit of a literal
        /// is rejected at compile time instead of shipping silently. The
        /// sha256 of each source file is checked off-device by
        /// _tools/verify-dsh-bundled-files.cjs.
        let bytes: Int
        let content: String
    }

    /// Files `dsh-doc/SKILL.md` links to relatively (5 references + 7 templates).
    /// SkillStore.installBundledSkill(dsh-doc) writes each one into the skill
    /// directory, which the iSH bind mount exposes at
    /// /var/minis/skills/dsh-doc/<path> — the only way those links resolve.
    static let docFiles: [DSHBundledFile] = [
        DSHBundledFile(path: "references/metadata-links-i18n.md", kind: "markdown", bytes: 8934, content: docFile_references_metadata_links_i18n),
        DSHBundledFile(path: "references/review.md", kind: "markdown", bytes: 6060, content: docFile_references_review),
        DSHBundledFile(path: "references/structure-hierarchy.md", kind: "markdown", bytes: 6276, content: docFile_references_structure_hierarchy),
        DSHBundledFile(path: "references/style.md", kind: "markdown", bytes: 4117, content: docFile_references_style),
        DSHBundledFile(path: "references/website-sync.md", kind: "markdown", bytes: 6850, content: docFile_references_website_sync),
        DSHBundledFile(path: "templates/package-bundle.md", kind: "markdown", bytes: 3409, content: docFile_templates_package_bundle),
        DSHBundledFile(path: "templates/package-group.md", kind: "markdown", bytes: 1867, content: docFile_templates_package_group),
        DSHBundledFile(path: "templates/package-library.md", kind: "markdown", bytes: 3546, content: docFile_templates_package_library),
        DSHBundledFile(path: "templates/package-reference.md", kind: "markdown", bytes: 3860, content: docFile_templates_package_reference),
        DSHBundledFile(path: "templates/persistence-change.md", kind: "markdown", bytes: 3940, content: docFile_templates_persistence_change),
        DSHBundledFile(path: "templates/persistence-format.md", kind: "markdown", bytes: 2412, content: docFile_templates_persistence_format),
        DSHBundledFile(path: "templates/persistence-release.md", kind: "markdown", bytes: 3123, content: docFile_templates_persistence_release),
    ]
}
