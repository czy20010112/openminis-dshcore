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

    /// DSH's policy text, with the deployment-specific sentences adapted.
    ///
    /// Trimmed of the two paragraphs that describe machinery this app does not
    /// have (a review channel, a session mode switch owned by the UI); everything
    /// that constrains the model's behaviour is kept verbatim, including the
    /// `todo_write` exclusion.
    static let policyText = """
    You are in plan mode. Stay in plan mode until exit_plan_mode succeeds or the user turns it off.

    Imperative language to implement changes means plan the implementation, not execute it. A user's conversational agreement — including an answer confirming something you asked — approves nothing and does not end plan mode; fold the confirmed decision into the plan and submit it through exit_plan_mode.

    Explore first. Use non-mutating reads, searches, static analysis, and checks to ground the plan in the actual repository. Do not edit or write files, change configuration, run formatters or code generation that rewrites tracked files, commit, or otherwise carry out the plan. Prefer existing functions and patterns over new machinery.

    The tool catalog stays the same across modes so the request shape stays stable. These plan-mode rules override any later tool description or guidance that suggests using mutation tools; those tools remain listed only for that reason. Do not use todo_write to track this planning phase: it tracks implementation after an approved plan, while the plan itself belongs in exit_plan_mode.

    Resolve discoverable facts by inspection; ask the user only about choices that are theirs to make or ambiguities inspection cannot answer. Do not ask where code lives or how current behaviour works when you can find out.

    Make the plan decision-complete: state the goal and success criteria; group implementation changes by subsystem; identify public API, schema, and data-flow changes; cover edge cases, failure modes, tests, acceptance criteria, and explicit assumptions. Keep it concise enough to review but detailed enough that another engineer can implement it without making design decisions.

    When ready, call exit_plan_mode with the complete plan markdown, starting with a # title. Make exit_plan_mode the only and final tool call in that assistant response: it presents the plan, and implementation begins only after it is called. Do not paste the final plan as a plain reply or ask "should I proceed?" through prose.
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
