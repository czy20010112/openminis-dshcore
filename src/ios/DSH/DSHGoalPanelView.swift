//
//  DSHGoalPanelView.swift
//  Minis
//
//  The session's goal, as a bar docked OUTSIDE the composer, in the same stack
//  slot as the todo/plan bar.
//
//  Ported from DSH's `client/ui-goal`: the goal is the SECOND card in that stack
//  (todo, then goal, then the queue) and uses the same panel elevation, so this
//  draws the same chrome as `DSHTodoPanelView` — same height, same radius, same
//  4pt of clearance under it — rather than inventing a second visual language for
//  a strip that sits directly beneath the first one.
//
//  Two rules come from that package and are the reason the bar is as quiet as it
//  is:
//
//    * a completed or cleared goal draws NOTHING (`ui-goal/README.md`). There is
//      no "done" state to look at; the objective either still needs work or is
//      gone.
//    * the round counter is part of the bar, because "how many rounds has this
//      spent" is the one number that decides whether it is still a good idea.
//
//  A rejected goal command is not drawn here at all: it comes back in the tool
//  result the model reads, which is where the model can act on it.
//
//  SUPERSEDED BY `DSHStatusPanelView` (2026-10-18). Two bars stacked above the
//  composer was the operator's report; the goal is now the top section of
//  `DSHStatusPanelView`'s single card, so this view must NOT be mounted
//  alongside it — that would draw the goal twice. It is kept in the tree only
//  as the source of the goal's rows, which moved across unchanged.
//

import SwiftUI

struct DSHGoalPanelView: View {

    @ObservedObject private var store = DSHGoalStore.shared

    /// The composer's corner radius, from `ComposerSurface` — kept equal to
    /// `DSHTodoPanelView`'s so the two bars are the same shape when both show.
    private static let cornerRadius: CGFloat = 20

    var body: some View {
        Group {
            if let goal = store.goal, goal.phase.isLive {
                VStack(alignment: .leading, spacing: 0) {
                    header(goal)
                    objectiveLine(goal)
                }
                .padding(.top, 7)
                .padding(.bottom, 7)
                .background(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.goal)
    }

    // MARK: - Header

    private func header(_ goal: DSHGoal) -> some View {
        HStack(spacing: 8) {
            // `checklist`, not `target`: this repo already draws `checklist` in
            // the todo bar on the iOS 15.3 device, so its glyph is proven
            // present, and the bar below a goal is the bar that carries the
            // steps. A symbol that only exists from SF Symbols 2 onward would
            // render blank on 15.3 rather than failing to build, which looks
            // like a missing icon and is only findable by eye.
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            phaseDot(goal.phase)
            Text(LocalizedStringKey(phaseLabel(goal.phase)))
                .font(AppFont.sw(12, weight: .medium, category: .ui))
                .foregroundStyle(.secondary)
            Text(store.roundsLabel)
                .font(AppFont.sw(12, weight: .medium, category: .ui))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button {
                DSHGoalStore.shared.clear()
            } label: {
                Text("clear")
                    .font(Font(AppFont.ui(11, category: .ui)))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear the goal")
        }
        .padding(.horizontal, 12)
    }

    private func objectiveLine(_ goal: DSHGoal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if goal.phase == .blocked, let reason = goal.blockedReason {
                Text("Blocker: \(reason.code): \(reason.message)")
                    .font(Font(AppFont.ui(11, category: .ui)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("Objective: \(goal.objective)")
                .font(Font(AppFont.ui(12, category: .ui)))
                .foregroundStyle(.primary)
                .lineLimit(2)
                // No strikethrough and no completion styling: a live goal is never
                // finished, and `strikethrough(_:)` is an iOS 16 overload trap.
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 3)
        .accessibilityLabel("Goal: \(goal.objective)")
    }

    // MARK: - Phase

    /// Symbols chosen for the iOS 15 line: anything from SF Symbols 4 or later
    /// renders blank on 15.3 instead of failing, which would look like a missing
    /// phase rather than a missing glyph.
    @ViewBuilder
    private func phaseDot(_ phase: DSHGoal.Phase) -> some View {
        switch phase {
        case .active:
            Image(systemName: "largecircle.fill.circle")
                .font(.system(size: 9))
                .foregroundStyle(Color.accentColor)
        case .paused:
            Image(systemName: "pause.circle")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        case .blocked:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 9))
                .foregroundStyle(Color.orange)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.green)
        }
    }

    /// The English source for each phase, which is also the catalog key.
    private func phaseLabel(_ phase: DSHGoal.Phase) -> String {
        switch phase {
        case .active: return "active"
        case .paused: return "paused"
        case .blocked: return "blocked"
        case .complete: return "complete"
        }
    }
}
