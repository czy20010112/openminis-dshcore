//
//  DSHPlanApproval.swift
//  Minis
//
//  The plan-review channel: `exit_plan_mode` suspends until the user answers.
//
//  Ported from DSH's `plan-mode` package
//  (`packages/plan/plan-mode/src/index.ts`, the `EXIT_PLAN_MODE` tool). DSH asks
//  through its user-questions channel and only leaves plan mode when the user
//  picks Approve; every other answer comes back to the model as an ERROR and the
//  mode stays on. The previous port had no channel wired to tools, so the call
//  left the mode and reported success by itself — the operator's report was
//  "nothing happened and it was approved". This file is that channel.
//
//  Shape of the interaction, matching DSH one-for-one:
//
//    * header  "Plan review";
//    * question "Approve this plan and leave plan mode?";
//    * the plan itself as the detail, rendered as markdown;
//    * two options — Approve ("Leave plan mode; the plan is carried out from the
//      next step.") and Keep planning ("Stay in plan mode; feedback goes back to
//      the model.");
//    * dismissing without answering is the user taking the turn back to speak:
//      the mode stays on and the model is told to stop and wait.
//
//  Why a continuation rather than a polled flag: `exit_plan_mode` is dispatched
//  from an async tool call (`AIChatViewModel+ConcurrentTools.swift`), so it can
//  simply not return until the user has decided. The alternative — returning
//  "pending" and hoping the model calls again — would let a model that never
//  calls again strand the mode, and it would report success for a decision no
//  one made.
//
//  Timeout. DSH has none, because its channel is an interactive session UI that
//  assumes the user is there. Here the awaiting side is a turn that is holding
//  the composer's turn state and a suspended tool call, so it needs a deadline:
//
//    * 5 minutes, measured on the wall clock (a `Task.sleep`, i.e. the
//      continuous clock). A backgrounded app freezes the sleep but not the
//      clock it is measured against, so a review left open while the app was in
//      the background resolves the moment it resumes rather than hanging the
//      turn until the process is killed;
//    * on expiry the turn continues as "review not answered": stay in plan mode,
//      tell the model the review was not completed, and let it present the plan
//      again. Approving on the user's behalf would be the one outcome DSH
//      explicitly refuses to produce;
//    * a cancelled turn (Stop, a new message, session teardown) resolves the
//      same way through the continuation's cancellation handler, so the
//      continuation can never outlive the turn that owns it.
//

import Foundation
import SwiftUI
import UIKit

// MARK: - Coordinator

@MainActor
public final class DSHPlanApproval: ObservableObject {

    public static let shared = DSHPlanApproval()

    /// A plan waiting for the user's decision.
    public struct Request: Identifiable, Equatable, Sendable {
        public let id: UUID
        /// The plan markdown, verbatim as the model submitted it.
        public let plan: String
        /// First `#` heading, for the sheet's title. DSH titles its review card
        /// the same way (`firstHeading(plan) ?? 'Plan'`).
        public let title: String
        public let requestedAt: Date

        public init(id: UUID, plan: String, title: String, requestedAt: Date) {
            self.id = id
            self.plan = plan
            self.title = title
            self.requestedAt = requestedAt
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Leave plan mode and carry the plan out.
        case approve
        /// Stay in plan mode; the feedback (possibly empty) goes back to the
        /// model as the reason.
        case keepPlanning(feedback: String)
        /// The review was dismissed rather than answered — the user took the
        /// turn back to say something the two options do not cover.
        case dismissed
        /// The turn was cancelled while the review was open.
        case cancelled
        /// Nobody answered within `reviewTimeout`.
        case timedOut
        /// An `exit_plan_mode` call arrived while a review was already open.
        /// Stated rather than queued: two reviews stacked on one screen would
        /// answer whichever the user saw first.
        case busy
    }

    /// See the file header for why this is a wall-clock deadline.
    public static let reviewTimeout: TimeInterval = 5 * 60

    /// The open review, if any. Published so the chat view can present (and
    /// dismiss) its sheet from it.
    @Published public private(set) var pending: Request?

    private var box: ContinuationBox?
    private var timeoutTask: Task<Void, Never>?

    private init() {}

    /// Ask the user about one plan, and suspend until they answer.
    ///
    /// - Returns: the decision, never throwing: "the user did not approve" is a
    ///   normal outcome of this tool, and the tool's caller turns each case into
    ///   the model-facing text.
    public func review(plan: String, title: String) async -> Decision {
        guard box == nil else { return .busy }

        let request = Request(id: UUID(), plan: plan, title: title, requestedAt: Date())
        let box = ContinuationBox()
        self.box = box
        pending = request

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.reviewTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timeOut(request.id)
        }

        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Decision, Never>) in
                // Only the box is touched here: this closure is not isolated to
                // the main actor, so it must not reach for `pending` or the
                // timeout task. `install` hands back a decision the box already
                // received (an already-cancelled task gets its handler invoked
                // before this runs) and resumes the continuation itself.
                box.install(continuation)
            }
        } onCancel: {
            // The turn was cancelled: answer the review so the awaiting tool
            // call can finish and the loop can unwind. This is a thread-safe
            // call on the box; `pending` is cleared on the main actor below,
            // when the suspension returns.
            box.resolve(.cancelled)
        }

        timeoutTask?.cancel()
        timeoutTask = nil
        if self.box === box { self.box = nil }
        if pending?.id == request.id { pending = nil }
        return decision
    }

    /// Answer the open review.
    ///
    /// No-op when there is none, and no-op for a second answer to the same
    /// review — an approving tap followed by the sheet's own dismissal is the
    /// normal double-answer, and the second must not overwrite the first.
    public func resolve(_ decision: Decision) {
        box?.resolve(decision)
    }

    /// Answer only while a review is still open. Used by the dismissal path,
    /// which must not overwrite an answer the user already gave.
    public func resolveIfPending(_ decision: Decision) {
        guard pending != nil else { return }
        resolve(decision)
    }

    private func timeOut(_ id: UUID) {
        guard pending?.id == id else { return }
        resolve(.timedOut)
    }
}

// MARK: - Continuation box

/// Holds the suspended side of one review.
///
/// Exists so the two halves of the handoff can happen in either order without a
/// lost wakeup: the decision can arrive before the continuation is installed (an
/// already-cancelled task invokes its cancellation handler immediately, and a
/// very fast tap can land before `withCheckedContinuation`'s body runs). Both
/// orders are just "store what you have", so the second half never blocks and
/// nothing has to poll.
private final class ContinuationBox: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<DSHPlanApproval.Decision, Never>?
    private var earlyDecision: DSHPlanApproval.Decision?
    private var settled = false

    /// Store the awaiting side, or resume it immediately with a decision that
    /// arrived first.
    func install(_ continuation: CheckedContinuation<DSHPlanApproval.Decision, Never>) {
        lock.lock()
        if let decision = earlyDecision {
            earlyDecision = nil
            lock.unlock()
            continuation.resume(returning: decision)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ decision: DSHPlanApproval.Decision) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: decision)
            return
        }
        earlyDecision = decision
        lock.unlock()
    }
}

// MARK: - Review sheet

/// The plan review, presented from the chat view while `exit_plan_mode` waits.
struct DSHPlanReviewSheet: View {

    let request: DSHPlanApproval.Request

    @Environment(\.dismiss) private var dismiss
    @State private var feedback: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                SelectableMarkdownView(markdown: request.plan)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
            Divider()
            footer
        }
        .onDisappear {
            // A swipe-down, or "Speak instead", both mean what DSH's channel
            // means by a cancelled question: the user took the turn back to say
            // something the two options do not cover. The model is told that and
            // the mode stays on. Idempotent: after an explicit answer this is a
            // no-op, because the review is no longer pending.
            DSHPlanApproval.shared.resolveIfPending(.dismissed)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Plan review")
                    .font(Font(AppFont.ui(13, weight: .medium, category: .body)))
                    .foregroundStyle(.secondary)
                Text(request.title)
                    .font(Font(AppFont.ui(17, weight: .semibold, category: .body)))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Speak instead") {
                DSHPlanApproval.shared.resolve(.dismissed)
                dismiss()
            }
            .font(Font(AppFont.ui(14, category: .body)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approve this plan and leave plan mode?")
                .font(Font(AppFont.ui(15, weight: .medium, category: .body)))

            feedbackField

            HStack(alignment: .top, spacing: 12) {
                optionButton(
                    title: "Keep planning",
                    caption: "Stay in plan mode; feedback goes back to the model.",
                    prominent: false
                ) {
                    let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
                    DSHPlanApproval.shared.resolve(.keepPlanning(feedback: text))
                    dismiss()
                }
                optionButton(
                    title: "Approve",
                    caption: "Leave plan mode; the plan is carried out from the next step.",
                    prominent: true
                ) {
                    DSHPlanApproval.shared.resolve(.approve)
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }

    private var feedbackField: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $feedback)
                .font(Font(AppFont.ui(14, category: .body)))
                .frame(minHeight: 64, maxHeight: 96)
                .padding(4)
                .background(ChatColors.secondaryBg)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(UIColor.separator), lineWidth: 0.5)
                )
            if feedback.isEmpty {
                Text("Optional: what to change if you keep planning…")
                    .font(Font(AppFont.ui(14, category: .body)))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private func optionButton(
        title: LocalizedStringKey,
        caption: LocalizedStringKey,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if prominent {
                    Button(action: action) {
                        Text(title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(action: action) {
                        Text(title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            Text(caption)
                .font(Font(AppFont.ui(11, category: .ui)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
