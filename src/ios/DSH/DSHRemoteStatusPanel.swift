import SwiftUI

/// The goal + task card above the remote composer.
///
/// Same place and same shape as the local one (`DSHStatusPanelView`): one rounded
/// surface, the goal section above the task section, 7pt above and 6pt below so
/// the height it reports is exactly the inset the list must reserve.
///
/// WHY NOT INSTANTIATE `DSHStatusPanelView` ITSELF: that view reads
/// `DSHGoalStore.shared` / `DSHTodoStore.shared`, which hold the LOCAL session's
/// state. A remote Session's goal and tasks live on the computer, and on iPad the
/// local chat can be alive at the same time — pointing a singleton at the remote
/// document would corrupt the other page. So this view is the same DESIGN driven
/// by `DSHRemoteSessionSummary`, and the two constants below are quoted from the
/// local card so they cannot drift visually.
struct DSHRemoteStatusPanel: View {

    var summary: DSHRemoteSessionSummary?
    /// Measured height, reported the way the composer reports its own: the list
    /// is the only view that knows how much of the bottom it must keep clear.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// Collapsed/expanded state of the task section, `false` = header only.
    /// Deliberately local `@State`: which section the user opened is a view
    /// preference, not something the host reports.
    @State private var expanded = false

    /// Rows drawn when expanded. The host keeps the whole list; this is only
    /// what fits before the composer is pushed off the screen.
    private let maxVisibleRows = 6

    /// Quoted from `DSHStatusPanelView` (`DSHStatusPanelView.swift:95`), which
    /// quotes the composer's own corner radius.
    private static let cornerRadius: CGFloat = 20
    private static let edgeWidth: CGFloat = 0.5

    /// The goal the card draws. `done`/`complete`/`cleared` have nothing left to
    /// say above the composer — the local bar applies the same rule.
    private var liveGoal: DSHRemoteSessionSummary.Goal? {
        guard let goal = summary?.goal else { return nil }
        let state = (goal.status ?? goal.phase ?? "").lowercased()
        guard state != "done", state != "complete", state != "completed", state != "cleared" else { return nil }
        return goal
    }

    private var todos: [DSHRemoteSessionSummary.Todo] { summary?.todos ?? [] }

    private func statusText(_ goal: DSHRemoteSessionSummary.Goal) -> String {
        (goal.status ?? goal.phase ?? "").capitalized
    }

    private func isBlocked(_ goal: DSHRemoteSessionSummary.Goal) -> Bool {
        [goal.status, goal.phase].compactMap { $0?.lowercased() }.contains("blocked")
    }

    private func isInProgress(_ todo: DSHRemoteSessionSummary.Todo) -> Bool {
        (todo.status ?? "").lowercased() == "in_progress"
    }

    private func isCompleted(_ todo: DSHRemoteSessionSummary.Todo) -> Bool {
        (todo.status ?? "").lowercased() == "completed"
    }

    var body: some View {
        Group {
            if liveGoal != nil || !todos.isEmpty {
                card
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        // Zero height when there is nothing to draw: the caller's inset
        // registration then reserves nothing, which is the behaviour the remote
        // page had before the panels existed.
        .dshMeasurePanelHeight { height in
            guard height > 0 || (!todos.isEmpty || liveGoal != nil) else { return }
            onHeightChange(height)
        }
        .animation(.easeInOut(duration: 0.18), value: summary?.goal)
        .animation(.easeInOut(duration: 0.18), value: todos)
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let goal = liveGoal {
                goalSection(goal)
            }
            if let goal = liveGoal, !todos.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)
                    .padding(.horizontal, 12)
            }
            if !todos.isEmpty {
                taskSection
            }
        }
        .padding(.top, 7)
        .padding(.bottom, 6)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(ChatColors.inputBorder, lineWidth: Self.edgeWidth)
        )
        .padding(.horizontal, 12)
    }

    // MARK: - Goal

    private func goalSection(_ goal: DSHRemoteSessionSummary.Goal) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(isBlocked(goal) ? Color.orange : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(statusText(goal))
                    .font(AppFont.sw(11, weight: .medium, category: .ui))
                    // `blocked` is the one state the local bar colours, and it is
                    // the one that needs the user to act.
                    .foregroundStyle(isBlocked(goal) ? Color.orange : ChatColors.secondaryText)
                // Rounds, not steps: the host's goal projection carries a round
                // budget and NO per-step list (`steps` is always empty by
                // contract), so "0 steps" would be a fabricated number.
                if let rounds = goal.rounds, let max = rounds.max, max > 0 {
                    Text("· \(Int((rounds.started ?? 0).rounded()))/\(Int(max.rounded())) rounds")
                        .font(AppFont.sw(11, weight: .regular, category: .ui))
                        .foregroundStyle(ChatColors.secondaryText)
                }
                Spacer(minLength: 0)
            }
            Text(goal.title ?? "")
                .font(AppFont.sw(13, weight: .regular, category: .ui))
                .foregroundStyle(ChatColors.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    // MARK: - Tasks

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(progressLabel)
                        .font(AppFont.sw(11, weight: .medium, category: .ui))
                        .foregroundStyle(ChatColors.secondaryText)
                    if !expanded, let active = todos.first(where: { isInProgress($0) }) {
                        Text("· \(active.content ?? "")")
                            .font(AppFont.sw(11, weight: .regular, category: .ui))
                            .foregroundStyle(ChatColors.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ChatColors.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Tasks, \(progressLabel)"))
            .padding(.horizontal, 12)
            .padding(.vertical, 2)

            if expanded {
                // `Todo` is client-model's type and carries no `id`: `content` is
                // the identity, exactly as the local `DSHTodoItem` argues (the
                // list is replaced wholesale and cannot hold two identical lines).
                ForEach(Array(todos.prefix(maxVisibleRows)), id: \.content) { todo in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: isCompleted(todo)
                              ? "checkmark.circle.fill"
                              : (isInProgress(todo) ? "circle.lefthalf.filled" : "circle"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isCompleted(todo) ? Color.secondary
                                             : (isInProgress(todo) ? Color.accentColor : Color.secondary.opacity(0.6)))
                        Text(todo.content ?? "")
                            .font(AppFont.sw(11, weight: isInProgress(todo) ? .medium : .regular, category: .ui))
                            // `in_progress` is the row the user is waiting on.
                            .foregroundStyle(isInProgress(todo) ? ChatColors.primaryText : ChatColors.secondaryText)
                            // No `.strikethrough`: the only overload the iOS 15
                            // line can resolve here is the iOS 16 pattern form.
                            // A completed row is already marked by the filled
                            // checkmark and the dimmed text, which is the signal
                            // that actually reads at 11pt.
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                }
                if todos.count > maxVisibleRows {
                    Text("+\(todos.count - maxVisibleRows) more")
                        .font(AppFont.sw(10, weight: .regular, category: .ui))
                        .foregroundStyle(ChatColors.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.top, 1)
                }
            }
        }
    }

    private var progressLabel: String {
        let done = todos.filter { isCompleted($0) }.count
        return "\(done)/\(todos.count) tasks"
    }
}

// MARK: - Height reporting

/// Same mechanism as the composer's height report: a `GeometryReader` in
/// `.background` writes a preference, the layout never depends on it, and no
/// conditional compilation is involved (both trees share this file byte for
/// byte, so the iOS 26-only `onGeometryChange` cannot be used here).
private struct DSHPanelHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

private extension View {
    func dshMeasurePanelHeight(_ action: @escaping (CGFloat) -> Void) -> some View {
        self.background(
            GeometryReader { proxy in
                Color.clear.preference(key: DSHPanelHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(DSHPanelHeightPreferenceKey.self) { value in
            if let value { action(value) }
        }
    }
}
