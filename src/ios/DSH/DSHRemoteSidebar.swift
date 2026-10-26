import Foundation

/// Bridges a remote DSH conversation into the sidebar's existing row model.
///
/// The sidebar, its grouping memo, drag/drop, badges and search all key off
/// `ChatSession`, so mapping the remote list into `ChatSession` values keeps every
/// one of those code paths untouched. The `dsh:` id prefix is mandatory: it keeps
/// remote ids out of the local id space (and out of `AIChatViewModel.activeSessionId`).
enum DSHRemoteSidebar {
    static let prefix = "dsh:"

    static func sessionId(for conversationId: String) -> String { prefix + conversationId }

    static func conversationId(from sessionId: String) -> String {
        sessionId.hasPrefix(prefix) ? String(sessionId.dropFirst(prefix.count)) : sessionId
    }

    static func isRemote(_ sessionId: String) -> Bool { sessionId.hasPrefix(prefix) }
}

extension DSHRemoteConversation {
    /// Sidebar row projection. Model id / timestamps are placeholders: the row view
    /// only reads id/title/updatedAt/lastMessage/pinned for remote entries.
    func asSidebarSession() -> ChatSession {
        let millis = sortStamp > 0 ? sortStamp : Date().timeIntervalSince1970 * 1000
        let stamp = Date(timeIntervalSince1970: millis / 1000)
        return ChatSession(
            id: DSHRemoteSidebar.sessionId(for: id),
            title: displayName,
            category: nil,
            modelId: "dsh-remote",
            createdAt: stamp,
            updatedAt: stamp,
            lastMessage: preview,
            source: "dsh-remote",
            lastSyncedAt: nil,
            remoteDeviceId: nil,
            remoteDeviceName: nil,
            pinnedAt: nil,
            folderId: nil
        )
    }
}

extension DSHHostSessionRow {
    /// Sidebar row for a harness Session. The folder is the workspace (`cwd`), which
    /// is exactly how the web sidebar groups; `DSHRemoteStore.derivedFolders()`
    /// produces the matching ChatFolder rows.
    func asSidebarSession() -> ChatSession {
        let stamp = Date(timeIntervalSince1970: session.updatedAt / 1000)
        let workspace = session.workspace
        let folder = workspace.isEmpty ? nil : "dshcwd:" + workspace
        return ChatSession(
            id: DSHRemoteSidebar.sessionId(for: session.sessionId),
            title: session.displayTitle,
            category: nil,
            modelId: "dsh-remote",
            createdAt: stamp,
            updatedAt: stamp,
            lastMessage: subtitle,
            source: "dsh-remote",
            lastSyncedAt: nil,
            remoteDeviceId: nil,
            remoteDeviceName: nil,
            pinnedAt: nil,
            folderId: folder
        )
    }

    /// The row's second line.
    ///
    /// `preview` is the newest thing said in the Session, which is what the row is
    /// for. It is nil for a Session with no turn yet and for a bridge that predates
    /// the field, so this never hands the row an empty string: the sidebar renders
    /// `lastMessage ?? "No messages yet"`, and that sentence — the English fallback
    /// that used to be every remote row's subtitle — must not come back for a
    /// Session that is merely quiet. The turn count is a real fact about the
    /// Session, so it wins over the workspace name, which the folder header already
    /// shows above the row.
    private var subtitle: String {
        if let preview, !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preview
        }
        if let turns, turns > 0 {
            return String(format: AppLocalized("%lld turns"), turns)
        }
        return session.workspaceName
    }
}

extension DSHHostSession {
    /// Row built from the Session alone, i.e. without the list extras. Kept for
    /// callers that only hold the Session model (it still never yields the
    /// "No messages yet" fallback — see `DSHHostSessionRow.subtitle`).
    func asSidebarSession() -> ChatSession {
        DSHHostSessionRow(session: self, preview: nil, turns: nil).asSidebarSession()
    }
}
