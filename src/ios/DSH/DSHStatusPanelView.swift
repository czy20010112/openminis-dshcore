//
//  DSHStatusPanelView.swift
//  Minis
//
//  The session's goal and task list as ONE bar docked above the composer:
//  the goal on top, the tasks under it, sharing a single card.
//
//  WHY ONE CARD
//  ---------------------------------------------------------------------------
//  `DSHGoalPanelView` and `DSHTodoPanelView` drew the same chrome twice, in two
//  stacked cards, whenever a goal and a list were up together. Operator report
//  (2026-10-18), verbatim: two bars at once "does not look good" — the ask is one
//  bar holding both, goal above, tasks below. So the two bodies are composed
//  here instead of mounted side by side. What each section RENDERS is kept
//  as-is: same header rows, same glyphs, same type scale, same taps. Only the
//  container changed.
//
//  The rules that decide what is drawn are the ones the two panels shipped with
//  and they are NOT re-decided here:
//
//    * a goal draws only while its phase is live — a completed or cleared goal
//      has nothing left to say (`DSHGoalStore.DSHGoal.Phase.isLive`, and DSH's
//      `ui-goal/README.md` behind it);
//    * the task section draws when plan mode is on or a list exists, and with no
//      list it is a pill that hugs its content, because a one-chip row stretched
//      across the composer is what the operator called "too long".
//
//  A section that draws nothing contributes NOTHING: no empty row, no spacer, no
//  second card. One live section = one card with one section in it, and that is
//  also the only case in which there is no hairline between them.
//
//  WHY IT LOOKS LIKE THE COMPOSER
//  ---------------------------------------------------------------------------
//  Same operator report: the bar should share the composer bubble's theme so the
//  bar and the input box read as one object. The values come from the composer's
//  own style sheet, quoted rather than re-derived:
//
//    * fill   `ChatColors.inputBg`  — `Views/Chat/AIChatView.swift:76`, the
//             composer surface's own fill (`ComposerSurface`, same file :4888).
//             Used to be `.ultraThinMaterial` here, which is a *material*, not
//             the composer's colour: over the chat background it reads as a grey
//             smudge rather than as the bubble next to it.
//    * radius 20      — `ComposerSurface`'s `RoundedRectangle(cornerRadius: 20,
//             style: .continuous)`, quoted as a literal for the same reason: a
//             `Shape` handed to `.fill`/`.stroke` has to be built inline, and a
//             non-erasable shape wrapper is not available to both lines.
//    * edge   `ChatColors.inputBorder` — the composer's own border colour
//             (`AIChatView.swift:77`). One hairline thickness (0.5), same as the
//             panels used, and the same `stroke`-not-`strokeBorder` choice: the
//             line is centred on the path, 0.25pt outside where `strokeBorder`
//             would put it, which is not findable by eye on 0.5pt.
//
//  Width is NOT set here. The caller already frames the bar to the composer's
//  `maxContentWidth` and gives it the composer's 12pt horizontal inset (the same
//  two modifiers the composer itself gets), so the bar's edges line up with the
//  input box's edges by construction rather than by a second opinion about the
//  width living in this file.
//
//  HEIGHT AND THE BOTTOM INSET
//  ---------------------------------------------------------------------------
//  Two sections expand and collapse independently — the task list keeps the
//  chevron it shipped with, the goal is one summary line plus its objective — and
//  both write into the SAME card, so the card's height is the sum of what is
//  actually there. That leaves exactly ONE number for the message list to
//  reserve, and the caller must register THIS view's measured height once
//  instead of registering the two old panels and adding them (see the handoff
//  note in the round's report; the mount point is `AIChatView`'s composer stack).
//
//  iOS 15 LINE
//  ---------------------------------------------------------------------------
//  Nothing here is newer than the two panels it replaces: `RoundedRectangle`,
//  `Capsule`, `.fill`/`.stroke`, `.ultraThinMaterial`-free colour fills,
//  `.foregroundStyle`, `AppFont`. `@ViewBuilder` branches rather than a
//  type-erasing shape wrapper (iOS 16) — the same reason `DSHTodoPanelView` had
//  two chrome branches.
//

import SwiftUI

struct DSHStatusPanelView: View {

    @ObservedObject private var goalStore = DSHGoalStore.shared
    @ObservedObject private var todoStore = DSHTodoStore.shared

    /// Collapsed/expanded state of the task section, exactly as the todo bar
    /// carried it: `false` = header only, `true` = header plus the list.
    @State private var expanded = false

    /// Rows drawn when expanded. The model still sees the whole list; this is
    /// only what is drawn before the composer is pushed off the screen.
    private let maxVisibleRows = 6

    /// The composer's corner radius, quoted from `ComposerSurface`
    /// (`Views/Chat/AIChatView.swift:4890`).
    private static let cornerRadius: CGFloat = 20

    /// The card's edge line, from the composer's own border colour.
    private static let edge = ChatColors.inputBorder
    private static let edgeWidth: CGFloat = 0.5

    /// The line between the two sections. Quieter than the card's edge: it
    /// separates two parts of one surface, it is not a second boundary.
    private static let separator = Color.primary.opacity(0.08)

    /// The live goal, or nil. `isLive` is the panel's own rule: a completed
    /// goal draws nothing.
    private var liveGoal: DSHGoal? {
        guard let goal = goalStore.goal, goal.phase.isLive else { return nil }
        return goal
    }

    /// Whether the task section draws at all.
    private var todoVisible: Bool {
        todoStore.planModeActive || !todoStore.todos.isEmpty
    }

    /// Whether the task section is in the pill shape: the mode chip alone.
    ///
    /// True implies the section is drawing — see `todoVisible`.
    private var todoPillOnly: Bool {
        todoStore.todos.isEmpty
    }

    var body: some View {
        Group {
            if liveGoal != nil || todoVisible {
                card
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: goalStore.goal)
        .animation(.easeInOut(duration: 0.18), value: todoStore.todos)
        .animation(.easeInOut(duration: 0.18), value: todoStore.planModeActive)
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    // MARK: - The card

    /// One surface, the goal's section above the task section.
    ///
    /// The vertical padding belongs to the CARD, not to the sections, because
    /// the top edge of the surface is the top of whichever section is first and
    /// the bottom edge is the bottom of whichever is last. That also means the
    /// body's height is exactly what the caller's bottom-inset registration
    /// measures: 7pt above and 6pt below, whatever is in between.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let goal = liveGoal {
                goalSection(goal)
            }
            // Only when both are up: with one section there is nothing to
            // divide, and a line under the last row would be that empty row the
            // brief rules out.
            if liveGoal != nil, todoVisible {
                Rectangle()
                    .fill(Self.separator)
                    .frame(height: 0.5)
                    .padding(.top, 5)
            }
            if todoVisible {
                todoSection
            }
        }
        .padding(.top, 7)
        .padding(.bottom, 6)
        .background(cardBackground)
        .overlay(cardStroke)
        // The pill is sized by its content; the list takes the width the caller
        // offers, because its rows need it. Belt and braces with the missing
        // spacer in `todoHeader`: this holds even if a flexible child is added
        // to the pill's row later.
        .fixedSize(horizontal: todoVisible && todoPillOnly, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session status")
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(ChatColors.inputBg)
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .stroke(Self.edge, lineWidth: Self.edgeWidth)
    }

    // MARK: - Goal section

    @ViewBuilder
    private func goalSection(_ goal: DSHGoal) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            goalHeader(goal)
            goalObjective(goal)
        }
    }

    private func goalHeader(_ goal: DSHGoal) -> some View {
        HStack(spacing: 8) {
            // `checklist`, not `target`: this repo already draws `checklist` in
            // the task bar on the iOS 15.3 device, so its glyph is proven
            // present, and the section below a goal is the section that carries
            // the steps. A symbol that only exists from SF Symbols 2 onward would
            // render blank on 15.3 rather than failing to build, which looks
            // like a missing icon and is only findable by eye.
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            phaseDot(goal.phase)
            Text(LocalizedStringKey(phaseLabel(goal.phase)))
                .font(AppFont.sw(12, weight: .medium, category: .ui))
                .foregroundStyle(.secondary)
            Text(goalStore.roundsLabel)
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

    private func goalObjective(_ goal: DSHGoal) -> some View {
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

    // MARK: - Task section

    @ViewBuilder
    private var todoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            todoHeader
            if expanded, !todoStore.todos.isEmpty {
                taskList
            }
        }
    }

    private var todoHeader: some View {
        HStack(spacing: 8) {
            if todoStore.planModeActive {
                // The mode, and the way out of it. Plan mode has no list until the
                // model writes one, so this is the only affordance it has — which
                // is why it lives on the bar rather than inside the composer.
                Button {
                    _ = DSHPlanMode.leave()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Plan mode")
                            .font(Font(AppFont.ui(12, weight: .medium, category: .ui)))
                        Text("exit")
                            .font(Font(AppFont.ui(11, category: .ui)))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Plan mode on — tap to leave")
            }

            if !todoStore.todos.isEmpty {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checklist")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        // A category font, not `.system(size: 12, weight: .medium)`:
                        // the system face here is what used to leave this one run
                        // of text on the stock font while the rest of the bar
                        // followed the font settings. `.monospacedDigit()` stays,
                        // because the counts change while a task runs and tabular
                        // digits keep the row from jittering.
                        Text(todoStore.progressLabel)
                            .font(AppFont.sw(12, weight: .medium, category: .ui))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if !expanded, let active = todoStore.activeContent {
                            Text(active)
                                .font(Font(AppFont.ui(12, category: .ui)))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        // Only when there is something to open.
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tasks, \(todoStore.progressLabel)")
            }
            // No spacer on the other branch: with no list there is only the mode
            // chip, and the row is meant to be exactly as wide as that chip. A
            // flexible child here is what stretched the strip across the composer
            // when there was nothing to put in it.
        }
        .padding(.horizontal, 12)
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(todoStore.todos.prefix(maxVisibleRows)) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    stateDot(todo.status)
                        .frame(width: 10)
                    Text(todo.content)
                        .font(Font(AppFont.ui(12, category: .ui)))
                        .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                        // No strikethrough: `strikethrough(_:)` and
                        // `strikethrough(_:pattern:color:)` are both applicable to a
                        // single-argument call (the newer one's extra parameters have
                        // defaults), the compiler picks the iOS 16 overload, and the
                        // iOS 15 line fails to build. The green check and the dimmed
                        // line already say "done".
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            if todoStore.todos.count > maxVisibleRows {
                Text("+\(todoStore.todos.count - maxVisibleRows) more")
                    .font(Font(AppFont.ui(11, category: .ui)))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 12)
        // 7pt under the header, which is the same gap the old todo bar had
        // between its header and its list.
        .padding(.top, 7)
    }

    @ViewBuilder
    private func stateDot(_ status: DSHTodoItem.Status) -> some View {
        // Symbols chosen for the iOS 15 line: `circle.dotted` and friends are SF
        // Symbols 4 and render blank on 15.3 rather than failing, which would look
        // like a missing status rather than a missing glyph.
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        case .inProgress:
            Image(systemName: "largecircle.fill.circle")
                .font(.system(size: 9))
                .foregroundStyle(Color.accentColor)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.green)
        }
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
