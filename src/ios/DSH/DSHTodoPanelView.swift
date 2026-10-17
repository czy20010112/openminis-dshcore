//
//  DSHTodoPanelView.swift
//  Minis
//
//  The session's task list and plan state, as a bar docked OUTSIDE the composer,
//  above it in the composer's stack.
//
//  Three placements have been tried and the operator rejected the first two. The
//  first was a sibling card floating above the composer: two rounded boxes with a
//  gap between them. The second put it INSIDE the composer so the composer's own
//  clip gave it the rounded top corners — but that put a plan chip and a task list
//  in the same box as the input field, and the operator's verdict was "the
//  composer should not contain extra plan content, it gets crowded".
//
//  So: outside, above. Two shapes, because the operator's next report separated
//  them — "the plan-mode strip is still too long, and its bottom edge now goes
//  past the composer's rounded top edge":
//
//    * plan mode on, no list yet — a PILL that hugs its content. Nothing here
//      needs the composer's width, and stretching a one-chip row across the
//      screen is what "too long" described. DSH ships the mode indicator as
//      exactly this (`ui-plan`'s `PlanChip`: 28pt tall, radius half that, so a
//      capsule) and keeps its full-width surface for the list alone.
//    * a list — the bar: counts, the running task on one line, and a chevron to
//      open it. A list is what wants the composer's width.
//
//  Both sit clear of the composer rather than overlapping it. The bar used to be
//  pulled 8pt down onto the composer's surface to close the gap, which put its
//  straight bottom edge — and the 0.5pt line along it — exactly at the composer's
//  top edge, where the composer's corners have already curved inward: the strip
//  was wider there than the surface under it, so its bottom edge hung over the
//  corners. DSH's own dock keeps 4pt under the panel instead
//  (`conversation.input.dock: padding: 0 … 4px`), and a panel that does not
//  overlap cannot have that defect.
//

import SwiftUI

struct DSHTodoPanelView: View {

    @ObservedObject private var store = DSHTodoStore.shared
    @State private var expanded = false

    /// Rows drawn when expanded. The model still sees the whole list; this is only
    /// what is drawn before the composer is pushed off the screen.
    private let maxVisibleRows = 6

    /// The composer's corner radius, from `ComposerSurface`, so the two surfaces
    /// share a radius when they are the same width.
    private static let cornerRadius: CGFloat = 20

    /// Whether there is no list to show, which leaves only the mode to show.
    ///
    /// True implies the mode is on: `body` renders nothing when both are empty.
    private var pillOnly: Bool { store.todos.isEmpty }

    var body: some View {
        Group {
            if store.planModeActive || !store.todos.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if expanded, !store.todos.isEmpty {
                        taskList
                    }
                }
                .padding(.top, 7)
                .padding(.bottom, 6)
                .background(chromeBackground)
                .overlay(chromeStroke)
                // The pill is sized by its content; the list takes the width the
                // caller offers, because its rows need it. Belt and braces with
                // the missing spacer in `header`: this holds even if a flexible
                // child is added to the pill's row later.
                .fixedSize(horizontal: pillOnly, vertical: false)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.todos)
        .animation(.easeInOut(duration: 0.18), value: store.planModeActive)
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    // MARK: - Chrome

    /// The bar's fill. A capsule for the pill — the radius is half its height,
    /// which is the same compact-chip geometry DSH's `PlanChip` uses — and the
    /// composer's own radius for the list.
    ///
    /// Two `@ViewBuilder` branches rather than one shape value: the type-erasing
    /// shape wrapper is iOS 16, and both lines this app builds are 15.0 and 16.0.
    /// `Capsule` and `RoundedRectangle` are both `Shape`s, so `fill` on either is
    /// the same call.
    @ViewBuilder
    private var chromeBackground: some View {
        if pillOnly {
            Capsule().fill(.ultraThinMaterial)
        } else {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }

    /// The 0.5pt hairline along the bar's edge.
    ///
    /// `stroke` and not `strokeBorder`: `strokeBorder` is declared on
    /// `InsettableShape`, and neither shape below is used as one — `stroke`
    /// centres the line on the path, so the visible edge sits 0.25pt outside
    /// where `strokeBorder` would have put it, which is not something the eye can
    /// find on a 0.5pt hairline.
    @ViewBuilder
    private var chromeStroke: some View {
        if pillOnly {
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        } else {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if store.planModeActive {
                // The mode, and the way out of it. Plan mode has no list until the
                // model writes one, so this is the only affordance it has — which is
                // why it lives on the bar rather than inside the composer.
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

            if !store.todos.isEmpty {
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
                .accessibilityLabel("Tasks, \(store.progressLabel)")
            }
            // No spacer on the other branch: with no list there is only the mode
            // chip, and the row is meant to be exactly as wide as that chip. A
            // flexible child here is what stretched the strip across the composer
            // when there was nothing to put in it.
        }
        .padding(.horizontal, 12)
    }

    // MARK: - List

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(store.todos.prefix(maxVisibleRows)) { todo in
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
            if store.todos.count > maxVisibleRows {
                Text("+\(store.todos.count - maxVisibleRows) more")
                    .font(Font(AppFont.ui(11, category: .ui)))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 12)
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
}
