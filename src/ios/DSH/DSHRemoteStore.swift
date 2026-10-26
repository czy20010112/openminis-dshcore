import Foundation
import Combine

/// Sidebar data source. `.dsh` swaps the conversation list for the paired host's
/// conversations; everything else in the app stays exactly as it is.
enum DSHRemoteMode: String {
    case minis
    case dsh

    var next: DSHRemoteMode { self == .minis ? .dsh : .minis }
}

/// Connection + conversation state for the remote DSH host.
///
/// Nothing here touches `ChatStore`: the DSH conversations are a separate,
/// read-through cache that the sidebar and the DSH chat view render directly.
///
/// [T-dsh-remote-v2] Since protocol v2 this type also owns the LIVE side: one SSE
/// connection per open Session, its cursor, and the reconnect policy. The chat
/// page never opens a socket; it subscribes (`openStream`) and forwards the
/// frames it receives to `DSHRemoteTranscriptWriter`.
@MainActor
final class DSHRemoteStore: ObservableObject {
    static let shared = DSHRemoteStore()

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    enum PairingPhase: Equatable {
        case idle
        case probing
        case waiting
        case approved
        case failed(String)
    }

    // MARK: Persisted

    private enum Keys {
        static let host = "minis.dshRemote.host"
        static let mode = "minis.dshRemote.mode"
    }

    @Published private(set) var mode: DSHRemoteMode = .minis {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode) }
    }

    @Published private(set) var host: DSHRemoteHost?
    @Published private(set) var status: Status = .disconnected
    @Published private(set) var conversations: [DSHRemoteConversation] = []
    /// Harness Sessions (the web sidebar list). This is what the DSH sidebar shows.
    ///
    /// Stored as rows, not as `DSHHostSession`: the bridge also sends the two
    /// list-only extras the row's subtitle needs (`preview`, `turns`), and those do
    /// not belong on the Session model the rest of the DSH layer shares. `sessions`
    /// below is the plain view of the same data, so every existing reader is
    /// unchanged.
    @Published private(set) var rows: [DSHHostSessionRow] = []
    /// The Session models, in the same order as `rows`.
    var sessions: [DSHHostSession] { rows.map(\.session) }
    @Published private(set) var messages: [String: [DSHRemoteMessage]] = [:]
    @Published private(set) var cursors: [String: String] = [:]
    @Published private(set) var loadingConversations = false
    @Published var errorText: String?

    // MARK: Pairing

    @Published private(set) var pairingPhase: PairingPhase = .idle
    @Published private(set) var pairingURL: String = ""
    @Published private(set) var pairingCode: String = ""

    // MARK: Private

    private var client: DSHRemoteClient?
    private var stream: DSHRemoteEventStream?
    private var openConversationId: String?
    private var pairingTask: Task<Void, Never>?

    /// Live harness streams, keyed by the token handed to the caller.
    private var streamSlots: [UUID: DSHRemoteStreamSlot] = [:]
    /// Highest `seq` this device has applied per Session. Sent as `?after=` on
    /// open and on every reconnect, so a reconnect resumes instead of replaying
    /// (or, worse, re-projecting a turn the writer already sealed).
    private var streamCursors: [String: Int] = [:]

    private init() {
        #if DEBUG
        // Simulator/debug only: the simulator cannot be driven through the
        // pairing sheet, so a device session can be injected at launch. Two
        // channels because `SIMCTL_CHILD_*` environment variables do not survive
        // `simctl launch --console`; `-KEY VALUE` launch arguments (which iOS
        // parses into NSArgumentDomain) always do.
        let rawEnv = ProcessInfo.processInfo.environment["MINIS_DSH_SESSION"]
        let rawArg = UserDefaults.standard.string(forKey: "MINIS_DSH_SESSION_B64")
        NSLog("[DSH] init inject: envLen=\(rawEnv?.count ?? -1) b64Len=\(rawArg?.count ?? -1)")
        var injectedData: Data?
        if let rawEnv { injectedData = Data(rawEnv.utf8) }
        else if let rawArg { injectedData = Data(base64Encoded: rawArg) }
        if let data = injectedData,
           var injected = try? JSONDecoder().decode(DSHRemoteSession.self, from: data) {
            // `/auth/refresh` ROTATES the refresh token, so the injected payload
            // is only valid until the first rotation. A locally persisted session
            // with a later expiry therefore wins: replaying the stale injected
            // token would 401 forever and look like a dead pairing.
            if let persisted = DSHRemoteKeychain.load(account: injected.serverId),
               persisted.expiresAt > injected.expiresAt {
                NSLog("[DSH] init: using persisted rotated session (injected expiresIn=\(Int((injected.expiresAt - Date().timeIntervalSince1970 * 1000) / 1000))s)")
                injected = persisted
            }
            host = DSHRemoteHost(url: injected.baseURL, serverId: injected.serverId,
                                 name: injected.hostName ?? "DSH", tlsPin: nil)
            client = DSHRemoteClient(session: injected)
            mode = .dsh
            NSLog("[DSH] init: injected session host=\(injected.baseURL) server=\(injected.serverId.prefix(12))")
            Task { await connect() }
            return
        } else if injectedData != nil {
            NSLog("[DSH] init: injected payload did not decode")
        }
        #endif
        if let raw = UserDefaults.standard.string(forKey: Keys.mode), let value = DSHRemoteMode(rawValue: raw) {
            mode = value
        }
        if let data = UserDefaults.standard.data(forKey: Keys.host),
           let saved = try? JSONDecoder().decode(DSHRemoteHost.self, from: data) {
            host = saved
            if let session = DSHRemoteKeychain.load(account: saved.serverId) {
                client = DSHRemoteClient(session: session)
            }
        }
        // A restored pairing must reconnect on its own: nothing else runs at
        // launch, so without this the sidebar stays empty until the user taps
        // Refresh, while the connection page already shows the paired host.
        if host != nil, mode == .dsh {
            Task { await connect() }
        }
    }

    // MARK: Mode

    func setMode(_ value: DSHRemoteMode) {
        mode = value
        if value == .dsh {
            if status == .disconnected || isFailure(status) { Task { await connect() } }
        } else {
            stream?.close()
            stream = nil
            openConversationId = nil
            closeAllLiveStreams()
        }
    }

    func toggleMode() {
        setMode(mode.next)
    }

    private func isFailure(_ value: Status) -> Bool {
        if case .failed = value { return true }
        return false
    }

    // MARK: Connect

    /// Restores the saved pairing and loads the conversation list.
    func connect() async {
        guard host != nil else { status = .disconnected; NSLog("[DSH] connect: no host"); return }
        if client == nil, let saved = host,
           let session = DSHRemoteKeychain.load(account: saved.serverId) {
            client = DSHRemoteClient(session: session)
        }
        guard let client else { status = .failed("Pair this device again."); NSLog("[DSH] connect: no client"); return }
        status = .connecting
        do {
            let list = try await client.hostSessions()
            // Sub-agent Sessions stay out of the sidebar, same as the web UI.
            NSLog("[DSH] connect: got \(list.count) rows")
            apply(list)
            status = .connected
            errorText = nil
        } catch let error as DSHRemoteError {
            NSLog("[DSH] connect failed (remote): \(error.message)")
            if error.needsRepair {
                status = .failed(error.message)
            } else {
                status = .failed(error.message)
            }
            errorText = error.message
        } catch {
            NSLog("[DSH] connect failed: \(error)")
            status = .failed(error.localizedDescription)
            errorText = error.localizedDescription
        }
    }

    func refreshConversations() async {
        guard let client, !loadingConversations else { return }
        loadingConversations = true
        defer { loadingConversations = false }
        do {
            let list = try await client.hostSessions()
            apply(list)
            status = .connected
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// One publish point for the Session list: hides sub-agents, newest first.
    private func apply(_ list: [DSHHostSessionRow]) {
        rows = list.filter { !$0.session.isSubagent }.sorted { $0.session.updatedAt > $1.session.updatedAt }
        NSLog("[DSH] apply: \(list.count) raw -> \(rows.count) rows (first=\(rows.first?.session.sessionId ?? "nil"))")
    }

    // MARK: Pairing

    func beginPairing(url: String, code: String, deviceName: String) {
        pairingTask?.cancel()
        pairingURL = url
        pairingCode = code
        pairingPhase = .probing
        errorText = nil
        pairingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await DSHRemoteClient.info(url: url)
                if Task.isCancelled { return }
                let claim = try await DSHRemoteClient.beginPairing(url: url, code: code, deviceName: deviceName)
                await MainActor.run {
                    self.host = DSHRemoteHost(url: url, serverId: info.serverId, name: info.name, tlsPin: nil)
                    self.pairingPhase = .waiting
                }
                let deadline = Date().addingTimeInterval(180)
                while Date() < deadline, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                    if let session = try await DSHRemoteClient.completePairing(url: url, claimToken: claim.claimToken, hostName: info.name) {
                        await MainActor.run {
                            self.finishPairing(session: session, host: DSHRemoteHost(url: url, serverId: info.serverId, name: info.name, tlsPin: nil))
                        }
                        return
                    }
                }
                await MainActor.run { self.pairingPhase = .failed("The computer did not approve this device in time.") }
            } catch {
                await MainActor.run {
                    self.pairingPhase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }

    private func finishPairing(session: DSHRemoteSession, host: DSHRemoteHost) {
        self.host = host
        DSHRemoteKeychain.save(session, account: host.serverId)
        if let data = try? JSONEncoder().encode(host) {
            UserDefaults.standard.set(data, forKey: Keys.host)
        }
        self.client = DSHRemoteClient(session: session)
        self.pairingPhase = .approved
        self.setMode(.dsh)
        Task { await connect() }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairingPhase = .idle
    }

    func resetPairingState() {
        pairingTask?.cancel()
        pairingTask = nil
        pairingPhase = .idle
        pairingURL = ""
        pairingCode = ""
    }

    func disconnect() {
        stream?.close()
        stream = nil
        closeAllLiveStreams()
        if let host { DSHRemoteKeychain.delete(account: host.serverId) }
        UserDefaults.standard.removeObject(forKey: Keys.host)
        host = nil
        client = nil
        conversations = []
        messages = [:]
        cursors = [:]
        streamCursors = [:]
        status = .disconnected
        setMode(.minis)
    }

    // MARK: Conversations / messages

    /// One page of a Session's event log, projected into Minis' message model.
    ///
    /// Kept for callers that want a plain page (the live page does not use it:
    /// its first frame IS the newest page, and fetching both would race two
    /// writers into `vm.messages`).
    func transcript(sessionId: String, beforeSeq: Double? = nil, limit: Int = 40) async throws -> (messages: [RawMessage], hasMore: Bool, page: DSHMessagesPage) {
        guard let client else { throw DSHRemoteError(code: "dsh/unavailable", message: "This device is not paired.", status: nil) }
        let page = try await client.hostMessages(sessionId: sessionId, beforeSeq: beforeSeq, limit: limit)
        let raw = DSHTranscript.rawMessages(sessionId: sessionId, records: page.records ?? [])
        return (raw, page.hasMore == true, page)
    }

    /// Sidebar folders derived from the harness workspace (`cwd`) of each Session.
    /// The harness has no user-named folders, so the workspace IS the group.
    func derivedFolders() -> [ChatFolder] {
        var seen: [String: Int] = [:]
        var result: [ChatFolder] = []
        for session in sessions where !session.workspace.isEmpty {
            let key = "dshcwd:" + session.workspace
            guard seen[key] == nil else { continue }
            let index = result.count
            seen[key] = index
            let stamp = Date(timeIntervalSince1970: session.updatedAt / 1000)
            result.append(ChatFolder(
                id: key,
                name: (session.workspaceTitle?.isEmpty == false) ? session.workspaceTitle! : session.workspaceName,
                icon: "folder",
                color: nil,
                origin: "manual",
                sortIndex: index,
                pinnedAt: nil,
                desc: session.workspace,
                createdAt: stamp,
                updatedAt: stamp
            ))
        }
        return result
    }

    func conversation(_ id: String) -> DSHRemoteConversation? {
        conversations.first { $0.id == id }
    }

    /// Opens a bot conversation: paints whatever is cached, then refreshes the
    /// newest page and starts the WebSocket. Harness Sessions use `openStream`.
    func open(_ id: String) {
        if openConversationId == id, stream != nil { return }
        stream?.close()
        stream = nil
        openConversationId = id
        Task { await loadNewest(id) }
        startStream(id)
    }

    func closeOpenConversation() {
        stream?.close()
        stream = nil
        openConversationId = nil
    }

    private func loadNewest(_ id: String) async {
        guard let client else { return }
        do {
            let page = try await client.messages(conversationId: id, cursor: nil, limit: 40)
            messages[id] = DSHRemoteMerge.merge(messages[id] ?? [], page.messages)
            if let cursor = page.cursor { cursors[id] = cursor }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loadOlder(_ id: String) async {
        guard let client, let cursor = cursors[id] else { return }
        do {
            let page = try await client.messages(conversationId: id, cursor: cursor, limit: 40)
            messages[id] = DSHRemoteMerge.merge(messages[id] ?? [], page.messages)
            cursors[id] = page.cursor
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Bot-conversation socket. The token comes from the CLIENT, never from the
    /// Keychain: a DEBUG-injected session has no Keychain entry, and a refresh
    /// only updates the client's copy.
    private func startStream(_ id: String) {
        guard let client else { return }
        let url = client.eventsURL
        let after = messages[id]?.compactMap(\.seq).max().map(Int.init)
        let stream = DSHRemoteEventStream(
            url: url,
            token: client.accessToken,
            conversationId: id,
            after: after,
            onEvent: { [weak self] event in
                self?.apply(event, to: id)
            },
            onStatus: { value in
                _ = value
            },
            onError: { [weak self] error in
                self?.errorText = error.localizedDescription
            }
        )
        self.stream = stream
        stream.start()
    }

    private func apply(_ event: DSHRemoteEvent, to id: String) {
        let current = messages[id] ?? []
        messages[id] = DSHRemoteMerge.apply(current, event: event)
        if event.type == "message" || event.type == "reset" {
            // Keep list previews roughly fresh without a full reload.
            if let index = conversations.firstIndex(where: { $0.id == id }) {
                var item = conversations[index]
                item.updatedAt = Date().timeIntervalSince1970 * 1000
                if let text = event.message?.text, !text.isEmpty { item.preview = text }
                conversations[index] = item
            }
        }
    }

    // MARK: - Live harness streams (protocol §1.3 / §2.3)

    /// Subscribe to a Session's live stream, opening it when it is not open yet.
    ///
    /// Idempotent per Session: a second call for the same Session rebinds the
    /// callback and returns the SAME token, so a view reload cannot end up with
    /// two sockets (the host allows 2 per Session, and the extra one would just
    /// duplicate every frame).
    ///
    /// `onFrame` is invoked on the main actor and in arrival order.
    @discardableResult
    func openStream(sessionId: String, onFrame: @escaping (DSHRemoteStreamFrame) -> Void) -> UUID {
        if let existing = streamSlots.values.first(where: { $0.sessionId == sessionId && !$0.closed }) {
            existing.onFrame = onFrame
            return existing.id
        }
        let slot = DSHRemoteStreamSlot(id: UUID(), sessionId: sessionId, onFrame: onFrame)
        streamSlots[slot.id] = slot
        start(slot)
        return slot.id
    }

    /// Detach and disconnect. Safe to call twice, and safe for a token the store
    /// already dropped.
    func closeStream(_ token: UUID) {
        guard let slot = streamSlots.removeValue(forKey: token) else { return }
        slot.closed = true
        slot.reconnectTask?.cancel()
        slot.reconnectTask = nil
        slot.stream?.close()
        slot.stream = nil
        NSLog("[DSH] stream closed sid=\(slot.sessionId.prefix(12))")
    }

    private func closeAllLiveStreams() {
        for token in Array(streamSlots.keys) { closeStream(token) }
    }

    /// Has this device already applied events for the Session?
    func streamCursor(sessionId: String) -> Int? { streamCursors[sessionId] }

    private func start(_ slot: DSHRemoteStreamSlot) {
        guard let client else {
            errorText = "This device is not paired."
            return
        }
        // NO `after` on purpose, even on a reconnect.
        //
        // The host trims `snapshot.records` to everything after `after`, and the
        // writer treats a snapshot as a REBUILD (that is what makes a reloaded
        // turn identical to the streamed one). Handing it a trimmed page would
        // therefore truncate the transcript to the last few events. Without
        // `after` the snapshot is the newest page, which is exactly what a fresh
        // open gets — so a reconnect reproduces the page instead of continuing it.
        //
        // The cursor is still tracked: it is the diagnostic that tells us whether
        // a reconnect resumed or restarted.
        let knownCursor = streamCursors[slot.sessionId]
        NSLog("[DSH] stream open sid=\(slot.sessionId.prefix(12)) knownCursor=\(knownCursor.map(String.init) ?? "nil") attempt=\(slot.attempt)")
        let token = slot.id
        slot.stream = client.stream(
            sessionId: slot.sessionId,
            after: nil,
            onFrame: { [weak self] frame in
                // Called from DSHRemoteStream on the main queue; hop through a
                // task so this closure stays free of main-actor calls.
                Task { @MainActor in self?.route(frame, token: token) }
            },
            onCursor: { [weak self] cursor in
                Task { @MainActor in self?.noteCursor(cursor, token: token) }
            },
            onFinish: { [weak self] message, retryable in
                Task { @MainActor in self?.handleFinish(token: token, message: message, retryable: retryable) }
            }
        )
    }

    private func route(_ frame: DSHRemoteStreamFrame, token: UUID) {
        guard let slot = streamSlots[token], !slot.closed else {
            NSLog("[DSH] route dropped token=\(token) exists=\(streamSlots[token] != nil) slots=\(streamSlots.count)")
            return
        }
        // Any frame proves the connection works: the backoff starts over.
        slot.attempt = 0
        NSLog("[DSH] route \(DSHRemoteStore.frameTag(frame)) slots=\(streamSlots.count)")
        if case .snapshot(let cursor, _, _, _, _, let pressure) = frame {
            if let pressure { cachePressure(pressure, sessionId: slot.sessionId) }
            if cursor > 0 {
                streamCursors[slot.sessionId] = max(streamCursors[slot.sessionId] ?? 0, cursor)
            }
            errorText = nil
        }
        slot.onFrame(frame)
    }

    /// One short line per frame. `String(describing:)` on a snapshot frame would
    /// print all 40 records — tens of kilobytes into the device log.
    static func frameTag(_ frame: DSHRemoteStreamFrame) -> String {
        switch frame {
        case .snapshot(let cursor, let records, _, let running, _, _):
            return "snapshot cursor=\(cursor) records=\(records.count) running=\(running)"
        case .event(let seq, let event):
            return "event seq=\(seq) type=\(event.type)"
        case .delta(let turn, let step, _, let index, let channel, let text):
            return "delta t=\(turn) s=\(step) i=\(index) \(channel.rawValue) len=\(text.count)"
        case .deltaEnd(let turn, let step, _):
            return "deltaEnd t=\(turn) s=\(step)"
        }
    }

    private func noteCursor(_ cursor: Int, token: UUID) {
        guard let slot = streamSlots[token], !slot.closed, cursor > 0 else { return }
        streamCursors[slot.sessionId] = max(streamCursors[slot.sessionId] ?? 0, cursor)
    }

    /// A stream ended. Reconnect with exponential backoff (0.5 s → 5 s) unless
    /// the caller closed it or the failure is permanent (a Session that no
    /// longer exists, a rejected pairing).
    private func handleFinish(token: UUID, message: String?, retryable: Bool) {
        guard let slot = streamSlots[token], !slot.closed else { return }
        slot.stream = nil
        if let message, !message.isEmpty {
            errorText = message
            NSLog("[DSH] stream error sid=\(slot.sessionId.prefix(12)): \(message) retryable=\(retryable)")
        } else {
            NSLog("[DSH] stream ended sid=\(slot.sessionId.prefix(12))")
        }
        guard retryable else {
            NSLog("[DSH] stream not retryable — giving up sid=\(slot.sessionId.prefix(12))")
            return
        }
        let delay = DSHRemoteStore.backoffDelay(attempt: slot.attempt)
        slot.attempt += 1
        NSLog("[DSH] stream reconnect sid=\(slot.sessionId.prefix(12)) in \(String(format: "%.1f", delay))s attempt=\(slot.attempt)")
        slot.reconnectTask?.cancel()
        slot.reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard let slot = self.streamSlots[token], !slot.closed, slot.stream == nil else { return }
            self.start(slot)
        }
    }

    /// 0.5 s, 1 s, 2 s, 4 s, 5 s, 5 s… — capped at 5 s, which keeps a restored
    /// Wi-Fi connection from waiting half a minute for the next try.
    static func backoffDelay(attempt: Int) -> TimeInterval {
        let base = 0.5 * pow(2, Double(max(0, attempt)))
        return min(base, 5)
    }

    private func cachePressure(_ pressure: DSHContextPressure, sessionId: String) {
        guard let index = rows.firstIndex(where: { $0.session.sessionId == sessionId }) else { return }
        var row = rows[index]
        row.session.contextPressure = pressure
        rows[index] = row
    }

    // MARK: - Harness write path (protocol §1.1 / §1.2)

    /// Send one prompt into a harness Session.
    ///
    /// Throws the host's own error (`SESSION_NOT_FOUND`, `AGENT_BUSY`, …) so the
    /// page can say what happened instead of "something failed".
    func submit(sessionId: String, text: String, requestId: String) async throws {
        guard let client else {
            throw DSHRemoteError(code: "dsh/unavailable", message: "This device is not paired.", status: nil)
        }
        try await client.submit(sessionId: sessionId, text: text, requestId: requestId)
        NSLog("[DSH] submit ok sid=\(sessionId.prefix(12)) len=\(text.count)")
    }

    /// Stop the Session's running turn.
    func cancel(sessionId: String) async throws {
        guard let client else {
            throw DSHRemoteError(code: "dsh/unavailable", message: "This device is not paired.", status: nil)
        }
        try await client.cancel(sessionId: sessionId)
        NSLog("[DSH] cancel ok sid=\(sessionId.prefix(12))")
    }

    // MARK: Send (bot conversations)

    /// Sends a message through `/submissions`. Returns false when the host rejects it.
    @discardableResult
    func send(_ text: String, to id: String) async -> Bool {
        guard let client else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let sessionId = conversation(id)?.sessionId ?? id
        let requestId = UUID().uuidString
        do {
            _ = try await client.submit(conversationId: id, sessionId: sessionId, text: trimmed, requestId: requestId)
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }
}

// MARK: - Stream slot

/// One live SSE subscription: the socket, the callback, and the retry state.
///
/// A class so the store can mutate it from `openStream`/`route`/`handleFinish`
/// without re-finding it by value, and so a stale task can check `closed`.
@MainActor
final class DSHRemoteStreamSlot {
    let id: UUID
    let sessionId: String
    var onFrame: (DSHRemoteStreamFrame) -> Void
    var stream: DSHRemoteStream?
    var reconnectTask: Task<Void, Never>?
    /// Consecutive failed/open attempts since the last received frame.
    var attempt = 0
    /// Set by `closeStream`/`disconnect`. Every callback checks it, so a frame
    /// that races the teardown cannot reach a writer the UI already reset.
    var closed = false

    init(id: UUID, sessionId: String, onFrame: @escaping (DSHRemoteStreamFrame) -> Void) {
        self.id = id
        self.sessionId = sessionId
        self.onFrame = onFrame
    }
}
