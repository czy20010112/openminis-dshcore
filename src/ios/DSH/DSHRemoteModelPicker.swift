import SwiftUI

/// The models the paired computer offers for this Session.
///
/// Contract: `GET /mobile/v1/dsh/models?sessionId=` →
/// ```jsonc
/// { "sessionId": "…", "current": "deepseek/deepseek-chat",
///   "items": [ { "ref": "…", "label": "DeepSeek Chat", "provider": "deepseek",
///                "providerLabel": "DeepSeek", "model": "deepseek-chat",
///                "contextWindow": 131072, "available": true, "reason": null } ] }
/// ```
/// `available: false` is a first-class state, not an error: the host lists the model
/// AND the reason it cannot be used, because "why is this greyed out" is the question
/// the user asks. Tapping such a row shows `reason` and sends nothing.
struct DSHRemoteModelList: Decodable, Sendable, Equatable {
    var sessionId: String?
    var current: String?
    var items: [Item]?

    struct Item: Decodable, Sendable, Equatable, Identifiable {
        var ref: String
        var label: String?
        var provider: String?
        var providerLabel: String?
        var model: String?
        var contextWindow: Double?
        /// Absent means "the host did not say" — treated as available, because a
        /// bridge that predates the flag should not turn every row grey.
        var available: Bool?
        var reason: String?

        var id: String { ref }
        var isAvailable: Bool { available ?? true }
        var title: String { label ?? model ?? ref }
        var group: String { providerLabel ?? provider ?? "" }
    }
}

/// `POST /mobile/v1/dsh/model` → the Session's new model.
struct DSHRemoteModelSelection: Decodable, Sendable, Equatable {
    var sessionId: String?
    var current: String?
    var provider: String?
    var model: String?
    var contextWindow: Double?
    /// `next-request` — the running turn is NOT interrupted.
    var appliesTo: String?
}

/// The picker.
///
/// Grouped by `providerLabel` because that is the axis a user thinks in ("use the
/// Anthropic one"), sorted within a group by the host's own order. The current row
/// carries a checkmark; unavailable rows stay tappable so their `reason` can be read.
struct DSHRemoteModelPicker: View {

    var sessionId: String
    /// Called with the host's answer after a successful switch, so the page can
    /// update its ring denominator (`contextWindow`) and any title that names the model.
    var onSwitched: (DSHRemoteModelSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var list: DSHRemoteModelList?
    @State private var errorText: String?
    @State private var busyRef: String?
    @State private var notice: String?

    private var groups: [(String, [DSHRemoteModelList.Item])] {
        let items = list?.items ?? []
        var order: [String] = []
        var bucket: [String: [DSHRemoteModelList.Item]] = [:]
        for item in items {
            if bucket[item.group] == nil { order.append(item.group) }
            bucket[item.group, default: []].append(item)
        }
        return order.map { ($0, bucket[$0] ?? []) }
    }

    var body: some View {
        NavigationView {
            List {
                if let errorText {
                    Section {
                        Text(errorText)
                            .font(AppFont.sw(13, weight: .regular, category: .ui))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(groups, id: \.0) { group, items in
                    Section {
                        ForEach(items) { item in
                            row(item)
                        }
                    } header: {
                        Text(group.isEmpty ? AppLocalized("This computer") : group)
                            .font(AppFont.sw(11, weight: .semibold, category: .ui))
                    }
                }
                if let notice {
                    Section {
                        Text(notice)
                            .font(AppFont.sw(12, weight: .regular, category: .ui))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(AppLocalized("Model"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Done")) { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func row(_ item: DSHRemoteModelList.Item) -> some View {
        let isCurrent = item.ref == list?.current
        Button {
            Task { await select(item) }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(AppFont.sw(14, weight: isCurrent ? .semibold : .regular, category: .ui))
                        .foregroundStyle(item.isAvailable ? ChatColors.primaryText : ChatColors.secondaryText)
                    if let window = item.contextWindow, window > 0 {
                        Text(String(format: AppLocalized("%@ context"), DSHContextFormat.magnitude(Int(window))))
                            .font(AppFont.sw(11, weight: .regular, category: .ui))
                            .foregroundStyle(ChatColors.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                if busyRef == item.ref {
                    ProgressView().controlSize(.small)
                } else if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatColors.primaryText)
                }
            }
            .contentShape(Rectangle())
            .opacity(item.isAvailable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(busyRef != nil)
    }

    private func load() async {
        do {
            list = try await DSHRemoteStore.shared.models(sessionId: sessionId)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func select(_ item: DSHRemoteModelList.Item) async {
        // Unavailable: say WHY, send nothing. This is the whole point of the row
        // still being tappable.
        guard item.isAvailable else {
            notice = item.reason ?? AppLocalized("This model can't be used for this session.")
            return
        }
        guard item.ref != list?.current else { dismiss(); return }
        busyRef = item.ref
        defer { busyRef = nil }
        do {
            let answer = try await DSHRemoteStore.shared.setModel(sessionId: sessionId, ref: item.ref)
            onSwitched(answer)
            // The host applies the change to the NEXT request, so say it instead of
            // letting the user think a running turn was restarted.
            notice = AppLocalized("Takes effect on the next request.")
            var updated = list
            updated?.current = answer.current ?? item.ref
            list = updated
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
