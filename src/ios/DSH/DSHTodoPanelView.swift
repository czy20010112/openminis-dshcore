//
//  DSHTodoPanelView.swift
//  Minis
//
//  The session's task list, docked above the composer.
//
//  Ported from DSH's `TodoPanel` (`packages/client/ui-conversation/src/client/
//  skeleton/TodoPanel.tsx`). The shape is the point, and it is the part that is
//  easy to get wrong:
//
//    * it is a dock above the input box, NOT a card in the transcript — the
//      transcript is where finished work is read, the dock is where work in
//      progress is watched;
//    * it renders nothing at all when there are no tasks, so a conversation with
//      no list loses no vertical space;
//    * it starts COLLAPSED, showing one line: how many tasks, and which one is
//      running. A long list that opens itself every time the model adds a step
//      would push the composer off the screen;
//    * the counts are joined the way DSH joins them, with empty segments left
//      out, so the header does not read as a row of zeros.
//

import SwiftUI

struct DSHTodoPanelView: View {

    @ObservedObject private var store = DSHTodoStore.shared
    @State private var expanded = false

    var body: some View {
        Group {
            if store.isActive {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if expanded {
                        taskList
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.todos)
        .animation(.easeInOut(duration: 0.18), value: expanded)
        .animation(.easeInOut(duration: 0.18), value: store.planModeActive)
    }

    // MARK: - Header

    private var header: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: store.planModeActive ? "list.bullet.rectangle" : "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.planModeActive ? Color.accentColor : Color.secondary)

                Text(store.planModeActive ? "Plan mode" : "Tasks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                if !store.todos.isEmpty {
                    Text(store.progressLabel)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if !expanded, let active = store.activeContent {
                    Text(active)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if !expanded, store.planModeActive, store.todos.isEmpty {
                    Text("planning before changing anything")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(store.planModeActive ? "Plan mode" : "Tasks"), \(store.progressLabel)")
    }

    // MARK: - List

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 6)
            ForEach(store.todos) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    stateDot(todo.status)
                        .frame(width: 10)
                    Text(todo.content)
                        .font(.system(size: 12))
                        .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                        // No strikethrough on purpose: `strikethrough(_:)` and
                        // `strikethrough(_:pattern:color:)` are both applicable to
                        // a single-argument call (the newer one's extra parameters
                        // have defaults), the compiler picks the iOS 16 overload,
                        // and the iOS 15 line then fails to build. The green check
                        // and the dimmed line already say "done".
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
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
