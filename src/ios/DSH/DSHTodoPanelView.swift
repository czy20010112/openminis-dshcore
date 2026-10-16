//
//  DSHTodoPanelView.swift
//  Minis
//
//  The session's task list and plan state, as a bar docked OUTSIDE the composer,
//  attached to its top edge.
//
//  This is the second placement, and the operator's correction is the reason for
//  it. The first version was a sibling card floating above the composer: two
//  rounded boxes with a gap between them. The second put it INSIDE the composer so
//  the composer's own clip gave it the rounded top corners — but that put a plan
//  chip and a task list in the same box as the input field, and the operator's
//  verdict was "the composer should not contain extra plan content, it gets
//  crowded".
//
//  So: outside, and attached. Same width as the composer (it inherits the
//  composer's `maxContentWidth` and its horizontal inset from the caller, less 2pt
//  so it reads as slightly narrower), top two corners rounded, bottom edge square
//  and pulled down onto the composer's surface with a negative bottom padding so
//  there is no gap to see.
//
//  One bar, two states, because they occupy the same slot:
//
//    * plan mode on, no list yet — "Plan mode", no chevron (there is nothing to
//      expand, and an expandable chevron with nothing under it reads as broken);
//    * a list — counts, the running task on one line, and a chevron to open it.
//

import SwiftUI

struct DSHTodoPanelView: View {

    @ObservedObject private var store = DSHTodoStore.shared
    @State private var expanded = false

    /// Rows drawn when expanded. The model still sees the whole list; this is only
    /// what is drawn before the composer is pushed off the screen.
    private let maxVisibleRows = 6

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
                .background(TopRoundedRectangle(radius: 20).fill(.ultraThinMaterial))
                // `stroke` and not `strokeBorder`: `strokeBorder` is declared on
                // `InsettableShape`, and `TopRoundedRectangle` is a plain `Shape`
                // (see its own note below on why it is hand-rolled). `stroke`
                // centres the 0.5pt line on the path, so the visible edge sits
                // 0.25pt outside where `strokeBorder` would have put it — not
                // something the eye can find on a 0.5pt hairline.
                .overlay(TopRoundedRectangle(radius: 20).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                // The bar's top corners match the composer's own radius (20, see
                // `ComposerSurface`), so the two surfaces line up when stacked.
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.todos)
        .animation(.easeInOut(duration: 0.18), value: store.planModeActive)
        .animation(.easeInOut(duration: 0.18), value: expanded)
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
            } else {
                Spacer(minLength: 0)
            }
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

/// A rectangle with its top two corners rounded and its bottom two square.
///
/// Hand-rolled because the obvious spelling, `UnevenRoundedRectangle`, is iOS 17 —
/// and the two lines this app builds for are 15.0 and 16.0, where it compiles on
/// neither. `RoundedRectangle` rounds all four, which is what made the bar look
/// like a separate card instead of one attached to the composer.
struct TopRoundedRectangle: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + r),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
