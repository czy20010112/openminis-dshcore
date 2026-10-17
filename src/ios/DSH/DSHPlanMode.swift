//
//  DSHPlanMode.swift
//  Minis
//
//  Plan mode: explore and produce a plan, then leave the mode and implement.
//
//  Ported from DSH's `plan-mode` package (`packages/plan/plan-mode`). The
//  behaviour that matters is the same:
//
//    * entering is a user action — `/plan` in the composer, or the `/` menu;
//    * while active, a policy section is added to the system prompt telling the
//      model to explore with non-mutating reads and to plan rather than execute;
//    * the mode ends through the `exit_plan_mode` tool, which is the model's only
//      way out;
//    * `todo_write` is explicitly NOT for the planning phase — it tracks the
//      implementation after the plan is accepted. DSH states this in the policy
//      text and this port keeps it.
//
//  The one section of DSH's behaviour that was missing in the first port is now
//  implemented. DSH routes `exit_plan_mode` through a user-questions approval
//  channel and stays in plan mode unless the user picks "Approve". The first
//  port had no channel wired to tools, so the call approved itself and left the
//  mode — the operator's report was "nothing happened and it got approved".
//  `exit` now suspends on `DSHPlanApproval` (the review channel: sheet, two
//  options, optional feedback) and no longer decides anything by itself.
//
//  Every non-approving answer — keep planning (with or without feedback), a
//  dismissed review, a cancelled turn, a review that outlived its deadline —
//  returns to the model as an ERROR and leaves the mode on, exactly as DSH does.
//
//  Also unlike DSH, nothing here hard-blocks mutating tools in plan mode. DSH
//  does not either — its policy text says sandbox mode and approval policy are
//  enforced independently and never read plan state — so a hard block would be a
//  new behaviour rather than a port, and it would break the one legitimate use of
//  a read-only phase that still needs a shell command to inspect something.
//
//  The operator reported that plan mode did nothing: the model "made no plan at
//  all and just started". The section WAS reaching the request — measured, not
//  inferred: `[DSH] prompt sections=[…] chars=… planMode=true` reports 29292
//  characters against 27243 with the mode off, a 2049-character delta that is
//  exactly this section (2047) plus `renderPrompt`'s two-character join. What was
//  weak was the text, which the first port had shortened; `policyText` below now
//  carries the upstream section verbatim. The other half of that report — "it
//  only planned after I told it in prose" — is what a section that forbids
//  *mutation* but never says "do not carry out the request at all" produces on a
//  read-only task: `yes … | head -3` edits nothing, so the policy as trimmed did
//  not cover it, while upstream's "Stay in plan mode until exit_plan_mode
//  succeeds" and "do not proceed with implementation" do.
//

import Foundation

public enum DSHPlanMode {

    /// Where the policy section sits. DSH's `PLAN_POLICY` is 500, ahead of its
    /// tool guidance at 1000, because the plan rules have to win over any later
    /// tool description that suggests mutating something. The same ordering is
    /// kept here.
    public static let sectionOrder = 500

    /// The section registered while plan mode is active.
    ///
    /// Registered for the life of the turn either way: when the mode is off the
    /// section renders as the empty string, which `DSHSystemPrompt` drops. DSH
    /// adds and removes the section instead, and notes the tool catalog is held
    /// constant across modes for request-cache stability — keeping the section
    /// position fixed is the same idea applied to the prompt.
    public static func policySection() -> DSHPromptSection {
        DSHPromptSection(
            name: "plan:policy",
            order: sectionOrder,
            dynamic: { _ in
                guard DSHTodoStore.shared.planModeActive else { return "" }
                return policyText
            }
        )
    }

    /// DSH's policy text, verbatim.
    ///
    /// Source: the deployment that owns the section,
    /// `packages/bundle/base/cordis.patch.yml` — the `plan-mode` entry's
    /// `section` (upstream `dsh-checkout`, 0.1.7-rc.1, lines 321-335). That file
    /// is the authority for the wording, not this port: the model was tuned
    /// against it.
    ///
    /// The first port shortened it. Two of the dropped sentences are what made
    /// the mode bind, and both are back:
    ///
    ///   * "it presents the plan **for approval**, and implementation begins only
    ///     in a later step **after approval**" — the port had written "after it is
    ///     called", which told the model its own `exit_plan_mode` call was what
    ///     starts implementation. That was true while the call approved itself;
    ///     `exit` now waits on `DSHPlanApproval`, so the stale sentence was both
    ///     weaker and false.
    ///   * "If review rejects it, incorporate the feedback and present again. If
    ///     the review channel is unavailable or aborted, stay in plan mode and ask
    ///     the user to switch modes manually; **do not proceed with
    ///     implementation**." — the port dropped this because it then had no
    ///     review channel. It has one now, and every non-approving path in `exit`
    ///     returns one of these situations to the model, so the model needs to be
    ///     told what to do in them.
    ///
    /// Two clauses name `ask_user_question`, which is not a tool in this app
    /// (the roster is `makeAgentTools()`; the plan review is not a general
    /// question channel). Both are reworded, and those two rewrites are the only
    /// deviations from the upstream text:
    ///
    ///   * "Use ask_user_question only for user-owned choices…" becomes "Ask the
    ///     user only for user-owned choices…";
    ///   * "…through prose or ask_user_question." becomes "…through prose."
    ///
    /// Everything else — including the `todo_write` exclusion, which is how the
    /// implementation checklist stays separate from the plan — is upstream's
    /// exact sentence.
    /// The message plan mode hands back when the model reaches for a tool that
    /// would carry the plan out, or nil when the tool is allowed.
    ///
    /// DSH leaves the tool catalog identical across modes and relies on the policy
    /// text alone — its own README calls plan mode "guidance, not enforcement".
    /// Measured on this device that guidance does not hold: with the policy section
    /// demonstrably in the request (30 590 characters with plan mode on against
    /// 29 292 off) the model called `shell_execute` thirteen seconds in and ran the
    /// operator's command, which is exactly the complaint that started this.
    ///
    /// So the refusal is mechanical. `shell_execute` is refused even though DSH's
    /// text permits read-only commands: nothing here can tell a read-only command
    /// from a destructive one without running it, and "plan, do not act" is the
    /// whole point of the mode. Inspection that does not need a shell stays
    /// available — `file_read`, `memory_get`, `browser_use`, `read_image`.
    /// `todo_write` is refused because DSH's policy says the checklist tracks
    /// implementation after approval, not the planning phase.
    static func refusal(forTool name: String) -> String? {
        guard DSHTodoStore.shared.planModeActive else { return nil }
        switch name {
        case "file_write", "file_edit", "shell_execute", "memory_write", "todo_write":
            return """
            Refused: `\(name)` is not available while plan mode is on. Plan mode is \
            for producing a plan, not for carrying it out — including commands that \
            only look read-only, because nothing here can tell the two apart without \
            running them. Explore with `file_read`, `memory_get`, `browser_use` or \
            `read_image`, then submit the finished plan through `exit_plan_mode`. \
            Implementation begins only after that plan is approved.
            """
        default:
            return nil
        }
    }

    static let policyText = """
    You are in plan mode. Stay in plan mode until exit_plan_mode succeeds or the user switches the session mode. Imperative language to implement changes means plan the implementation, not execute it. A user's conversational agreement — including an answer confirming something you asked — approves nothing and does not end plan mode; fold the confirmed decision into the plan and submit it through exit_plan_mode.

    Explore first. Use non-mutating reads, searches, static analysis, and checks to ground the plan in the actual repository. Do not edit or write files, change configuration, run formatters or code generation that rewrites tracked files, commit, or otherwise carry out the plan. Prefer existing functions and patterns over new machinery.

    The tool catalog stays the same across modes for request-cache stability. These plan-mode rules override any later tool description or guidance that suggests using mutation tools; those tools remain listed only to keep the request shape stable. Do not use todo_write to track this planning phase: it tracks implementation after an approved plan, while the plan itself belongs in exit_plan_mode.

    Resolve discoverable facts by inspection. Ask the user only for user-owned choices or material ambiguity that inspection cannot answer. Do not ask the user where code lives or how current behavior works when you can find out.

    Make the plan decision-complete: state the goal and success criteria; group implementation changes by subsystem; identify public API, schema, and data-flow changes; cover edge cases, failure modes, tests, acceptance criteria, and explicit assumptions. Keep it concise enough to review but detailed enough that another engineer can implement it without making design decisions.

    When ready, call exit_plan_mode with the complete plan markdown, starting with a # title. Make exit_plan_mode the only and final tool call in that assistant response: it presents the plan for approval, and implementation begins only in a later step after approval. Do not paste the final plan as a plain reply or ask "should I proceed?" through prose. If review rejects it, incorporate the feedback and present again. If the review channel is unavailable or aborted, stay in plan mode and ask the user to switch modes manually; do not proceed with implementation.
    """

    // MARK: - Transition

    public static func enter(reason: String? = nil) -> String {
        DSHTodoStore.shared.setPlanMode(true)
        if let reason, !reason.isEmpty {
            return "Plan mode on. Work out the plan for: \(reason)"
        }
        return "Plan mode on. Use /plan off to leave."
    }

    public static func leave() -> String {
        DSHTodoStore.shared.setPlanMode(false)
        return "Plan mode off."
    }

    /// Handle an `exit_plan_mode` call.
    ///
    /// Suspends on the user's decision. The plan is presented through
    /// `DSHPlanApproval` and this call does not return until the user approves,
    /// asks to keep planning, dismisses the review to speak, cancels the turn,
    /// or the review hits its deadline.
    ///
    /// - Returns: the model-facing result, or the reason the call was rejected.
    ///   Every non-approving path is a failure on purpose: "the plan was not
    ///   approved" has to read as a rejection to the model, because a success
    ///   result is what tells it to start implementing.
    public static func exit(plan rawPlan: Any?) async -> DSHToolOutcome {
        guard DSHTodoStore.shared.planModeActive else {
            return .failed("exit_plan_mode is only available in plan mode.")
        }
        guard let plan = rawPlan as? String else {
            return .failed("exit_plan_mode requires a `plan` string.")
        }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        // DSH rejects a plan that does not open with a level-1 heading: the
        // heading is what the transcript card and the review sheet title
        // themselves from, and a plan without one reads as a stray paragraph.
        guard trimmed.hasPrefix("# "),
              trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .failed(
                "exit_plan_mode requires a non-empty markdown plan starting with a # heading that names it."
            )
        }

        let decision = await DSHPlanApproval.shared.review(
            plan: trimmed,
            title: firstHeading(trimmed) ?? "Plan"
        )

        switch decision {
        case .approve:
            DSHTodoStore.shared.setPlanMode(false)
            // DSH's own success text, verbatim (`plan-mode/src/index.ts`, the
            // tool's output render). Deliberately unchanged: the model is told
            // to carry on from its next step, and that phrasing is what its plan
            // policy referred to.
            return .ok("Plan approved — plan mode exited; carry out the plan starting with your next step.")

        case .keepPlanning(let feedback):
            // DSH's two texts, verbatim: unlike a rejection from prose, "keep
            // planning" is an instruction to revise and resubmit, and the
            // feedback is the revision brief.
            return .failed(feedback.isEmpty
                ? "The user chose to keep planning; revise the plan and present it again."
                : "The user chose to keep planning; their feedback: \(feedback)")

        case .dismissed:
            return .failed(
                "The user dismissed the plan review to speak instead; "
                + "stay in plan mode, stop here, and wait for their message."
            )

        case .cancelled:
            return .failed(
                "The plan review was cancelled before the user answered; "
                + "stay in plan mode and present the plan again when they ask."
            )

        case .timedOut:
            // Our own text: DSH has no deadline, because its channel assumes an
            // interactive session. The model must not treat "no answer" as an
            // approval, so it is told plainly and sent back to the mode.
            return .failed(
                "The plan review was not answered within \(Int(DSHPlanApproval.reviewTimeout / 60)) minutes; "
                + "stay in plan mode and present the plan again when the user is ready."
            )

        case .busy:
            return .failed(
                "A plan review is already open and waiting for the user; "
                + "do not call exit_plan_mode again until it is answered."
            )
        }
    }

    /// The plan's first level-1 heading, for the review sheet's title.
    ///
    /// Ported from DSH's `firstHeading(args.plan) ?? 'Plan'`: the first
    /// non-empty line, with `# ` stripped. Returns nil for anything that is not
    /// a level-1 heading, and the caller falls back to "Plan".
    static func firstHeading(_ markdown: String) -> String? {
        let firstNonEmpty = markdown
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line = firstNonEmpty?.trimmingCharacters(in: .whitespaces) else { return nil }
        guard line.hasPrefix("# ") else { return nil }
        let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}
