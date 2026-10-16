//
//  DSHTodoPanelView.swift
//  Minis
//
//  The session's task list, as a band docked inside the composer.
//
//  Ported from DSH's `TodoPanel` (`packages/client/ui-conversation/src/client/
//  skeleton/TodoPanel.tsx`), which docks it at `conversation.input.dock` — above
//  the input, not in the transcript. The transcript is where finished work is
//  read; the dock is where work in progress is watched.
//
//  Three placement decisions, each of which was wrong in the first version:
//
//    * The band lives INSIDE the composer's own box, as its first child. The
//      composer clips itself (`ComposerSurface` → `clipShape(RoundedRectangle(
//      cornerRadius: 20))`), so the band's top corners ARE the composer's rounded
//      corners and the bottom edge is a hairline the composer provides — that is
//      the "attached, top-rounded, closed at the bottom" shape the operator asked
//      for. Rendered as a sibling card above the composer it floated: its own
//      four rounded corners read as a second box, and the composer's vertical
//      padding left a visible gap.
//    * It renders nothing when there is no list. An expandable chevron with
//      nothing under it reads as a broken control, which is exactly how plan mode
//      looked before a list existed. Plan mode is shown by `DSHPlanModeChip` in
//      the composer's own row instead.
//    * It starts COLLAPSED, showing one line: how many tasks and which one is
//      running. A long list that opens itself every time the model adds a step
//      pushes the composer off the screen.
//

import SwiftUI

struct DSHTodoPanelView: View {

    @ObservedObject private var store = DSHTodoStore.shared
    @State private var expanded = false

    /// Rows shown when expanded. A longer list keeps the composer taller than the
    /// screen, so the tail collapses into a count — the model still sees the whole
    /// list, this is only what is drawn.
    private let maxVisibleRows = 6

    var body: some View {
        Group {
            if !store.todos.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if expanded {
                        taskList
                    }
                    // The separator between the band and the input field. Inset so
                    // it stops short of the composer's edges — a full-bleed line
                    // makes the band read as a separate box rather than part of the
                    // same surface.
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)
                        .padding(.horizontal, 12)
                        .padding(.top, expanded ? 8 : 7)
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.todos)
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    // MARK: - Header

    private var header: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(store.progressLabel)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if !expanded, let active = store.activeContent {
                    Text(active)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tasks, \(store.progressLabel)")
    }

    // MARK: - List

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(store.todos.prefix(maxVisibleRows)) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    stateDot(todo.status)
                        .frame(width: 10)
                    Text(todo.content)
                        .font(.system(size: 12))
                        .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                        // No strikethrough on purpose: `strikethrough(_:)` and
                        // `strikethrough(_:pattern:color:)` are both applicable to
                        // a single-argument call (the newer one's extra parameters
                        // have defaults), so the compiler picks the iOS 16 overload
                        // and the iOS 15 line fails to build on it. The green check
                        // and the dimmed line already say "done".
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            if store.todos.count > maxVisibleRows {
                Text("+\(store.todos.count - maxVisibleRows) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func stateDot(_ status: DSHTodoItem.Status) -> some View {
        // Symbols chosen for the iOS 15 line: `circle.dotted` and friends are
        // SF Symbols 4 and render as blank on 15.3 rather than failing, which
        // would have looked like a missing status rather than a missing glyph.
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
}

/// The plan-mode indicator, for the composer's control row.
///
/// Plan mode has no task list until the model writes one, so it cannot be shown
/// by the task band; and it must be visible from the moment it is switched on, or
/// the only sign the mode is active is the system line the command posted. This
/// is the chip that carries it, and it doubles as the way out by tap.
struct DSHPlanModeChip: View {

    @ObservedObject private var store = DSHTodoStore.shared

    var body: some View {
        Group {
            if store.planModeActive {
                Button {
                    _ = DSHPlanMode.leave()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Plan")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.15))
                    )
                    .overlay(
                        Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Plan mode on — tap to leave")
                .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.planModeActive)
    }
}
