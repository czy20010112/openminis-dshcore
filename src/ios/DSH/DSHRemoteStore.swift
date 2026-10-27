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

    /// Connection health, in the only terms the UI can act on.
    ///
    /// `status` says whether the pair is usable; this says whether the LIVE side is
    /// still alive. They differ in exactly the case that cost the user a session:
    /// the socket dies, `status` stays `.connected`, the frozen page looks fine and
    /// nothing streams until the page is re-entered.
    enum ConnectionState: Equatable {
        /// No host at all: the connection page should offer pairing.
        case unpaired
        /// A host is saved but nothing can talk to it (Keychain empty, refresh
        /// rejected). Carries the sentence to show — never a silent failure.
        case unavailable(String)
        case connected
        /// Frames stopped arriving (`since` = the last one). The banner belongs here.
        case stale(since: Date)
        case reconnecting(attempt: Int)

        var isHealthy: Bool { self == .connected }
    }

    /// No frame (not even a heartbeat) for this long means the socket is dead.
    ///
    /// The host heartbeats every 15 s, so two missed beats is unambiguous, and it
    /// keeps "stale" well inside the 30 s the user is willing to wait.
    static let staleTimeout: TimeInterval = 30
    /// Banner grace: one missed heartbeat is when the UI should start saying something.
    static let staleHint: TimeInterval = 15

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
    /// Live-socket health for the banner (see `ConnectionState`).
    @Published private(set) var connectionState: ConnectionState = .unpaired
    /// When the last frame OR heartbeat arrived. `nil` until something does.
    @Published private(set) var lastFrameAt: Date?
    /// Why the pair is not usable, in the user's words. Set on every failure path
    /// that used to be silent.
    @Published private(set) var disconnectReason: String?

    /// STICKY: the pairing itself is dead (revoked, expired past repair) and only a
    /// re-pair can fix it.
    ///
    /// This is the flag the UI must read. The store sets `.unavailable(reason)` when
    /// it sees `pair_again`, but a state alone was not enough: the next successful
    /// frame (a heartbeat, a list, a lucky refresh) set `.connected` again, the
    /// banner disappeared, and the screen was left with a stale status line and a
    /// red "Reconnect" button that could never work.
    ///
    /// Cleared ONLY by a successful re-pair (`connect()`/`pairAgain()` obtaining a
    /// working token). A successful request never clears it — that is the whole
    /// point of "sticky".
    @Published private(set) var needsRepair: Bool = false
    /// The sentence to show while `needsRepair` is true (same string as
    /// `disconnectReason`; separate field so the UI has one thing to read).
    @Published private(set) var repairReason: String?

    /// A success has arrived: healthy again, unless the pairing is dead.
    private func markHealthy() {
        guard !needsRepair else {
            // Do not let a heartbeat or a lucky request paper over a dead pairing.
            return
        }
        if connectionState != .connected { connectionState = .connected }
        errorText = nil
        disconnectReason = nil
    }

    /// The pairing is dead: make it stick, and make the UI able to say why.
    private func markNeedsRepair(_ reason: String) {
        needsRepair = true
        repairReason = reason
        disconnectReason = reason
        errorText = reason
        status = .failed(reason)
        connectionState = .unavailable(reason)
        NSLog("[DSH] needsRepair=TRUE reason=\(reason)")
    }

    /// A working token exists again (a fresh pair, or a refresh that succeeded).
    private func clearNeedsRepair() {
        guard needsRepair else { return }
        needsRepair = false
        repairReason = nil
        NSLog("[DSH] needsRepair cleared (pairing is alive again)")
    }
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
    /// Ticks while any Session is open and restarts a socket that went quiet.
    private var watchdog: Task<Void, Never>?
    /// How often the watchdog looks. Cheap: it only compares dates.
    private static let watchdogInterval: TimeInterval = 3

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
            // The host URL and server id identify the user's own computer. They are
            // useful while debugging a pairing and worth nothing in a shipped log,
            // which is the one place a user may paste into a bug report.
            #if DEBUG
            NSLog("[DSH] init: injected session host=\(injected.baseURL) server=\(injected.serverId.prefix(12))")
            #endif
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
            connectionState = .unavailable(AppLocalized("Pair this device again."))
            if let session = DSHRemoteKeychain.load(account: saved.serverId) {
                client = DSHRemoteClient(session: session)
            } else {
                // The host survived the relaunch but its session did not (iOS can
                // drop a Keychain item after an update/before first unlock). This
                // used to be silent: the page said "not paired" with an empty URL
                // and the user had no idea they only needed to pair again.
                let reason = AppLocalized("The pairing expired. Pair this device again.")
                status = .failed(reason)
                connectionState = .unavailable(reason)
                disconnectReason = reason
                NSLog("[DSH] init: host restored but no local session (Keychain empty) — pair again, host kept")
            }
        }
        // A restored pairing must reconnect on its own: nothing else runs at
        // launch, so without this the sidebar stays empty until the user taps
        // Refresh, while the connection page already shows the paired host.
        if host != nil, mode == .dsh {
            Task { await connect() }
        }
        // The dispatch tools (`remote_team_*`) live in the LOCAL agent's catalog,
        // and `makeAgentTools()` reads `availability` synchronously — so a phone
        // that launches straight into Minis mode would spend its first message
        // without the tools while the throttled probe caught up. Probing here costs
        // one GET and makes the tools exist on the user's first message.
        if client != nil, mode != .dsh {
            Task { await DSHRemoteTeamTools.refreshAvailability() }
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
        // `load()`/`onAppear` funnel into here. With a revoked pairing every attempt
        // is another guaranteed 401, so the state is kept and the UI is left with
        // the banner. `finishPairing` clears the flag before calling this.
        guard !needsRepair else {
            NSLog("[DSH] connect skipped — needsRepair")
            return
        }
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
            // A working token means any earlier "pair again" is stale: this is one
            // of the two places allowed to clear the sticky flag.
            needsRepair = false
            repairReason = nil
            markHealthy()
            status = .connected
            // Team tools are gated on a value `makeAgentTools()` reads
            // SYNCHRONOUSLY every turn, so it cannot await there. A successful
            // connect is the one authoritative moment to refresh it: after the
            // list is on screen, never throwing, never blocking it.
            await DSHRemoteTeamTools.refreshAvailability()
            NSLog("[DSH] team availability=\(DSHRemoteTeamTools.availability.tag) members=\(DSHRemoteTeamTools.lastMemberCount)")
        } catch let error as DSHRemoteError {
            NSLog("[DSH] connect failed (remote): \(error.message)")
            if error.needsRepair || error.code == "pair_again" {
                // Sticky: a revoked pairing must survive every later success.
                markNeedsRepair(error.message)
            } else {
                status = .failed(error.message)
                errorText = error.message
                disconnectReason = error.message
                connectionState = .unavailable(error.message)
            }
        } catch {
            NSLog("[DSH] connect failed: \(error)")
            status = .failed(error.localizedDescription)
            errorText = error.localizedDescription
            disconnectReason = error.localizedDescription
            connectionState = .unavailable(error.localizedDescription)
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
        // A brand-new pairing is the one thing that definitely repairs a dead one.
        clearNeedsRepair()
        errorText = nil
        disconnectReason = nil
        self.pairingPhase = .approved
        self.setMode(.dsh)
        Task { await connect() }
    }

    // MARK: - Idle liveness probe

    /// Whether the DSH UI is on screen. The probe only runs while it is: a hidden
    /// page must not spend the user's battery confirming a session that nobody is
    /// looking at.
    private var uiVisible = false
    private var idleProbe: Task<Void, Never>?
    /// How often a visible, idle page asks "is this pairing still alive?".
    ///
    /// A revoked device that is sitting in Settings has no socket and no requests,
    /// so nothing else would ever notice. 60 s is the compromise in the doc: the
    /// banner appears within a minute instead of never.
    static let idleProbeInterval: TimeInterval = 60

    /// The page tells the store when it is visible; the probe follows.
    func setUIVisible(_ visible: Bool) {
        guard uiVisible != visible else { return }
        uiVisible = visible
        NSLog("[DSH] ui visible=\(visible)")
        if visible {
            startIdleProbe()
        } else {
            stopIdleProbe()
        }
    }

    private func startIdleProbe() {
        guard idleProbe == nil else { return }
        idleProbe = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(DSHRemoteStore.idleProbeInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                // A live socket answers this question on its own; a dead pairing
                // must never be re-probed into "connected" again.
                guard self.uiVisible, self.streamSlots.isEmpty, !self.needsRepair else { continue }
                guard let client = self.client else { continue }
                do {
                    let list = try await client.hostSessions()
                    NSLog("[DSH] idle probe ok rows=\(list.count)")
                    self.markHealthy()
                } catch let error as DSHRemoteError where error.needsRepair || error.code == "pair_again" {
                    NSLog("[DSH] idle probe found a dead pairing code=\(error.code)")
                    self.markNeedsRepair(error.message)
                } catch {
                    // A network blip while idle says nothing about the pairing.
                    NSLog("[DSH] idle probe failed (ignored): \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopIdleProbe() {
        idleProbe?.cancel()
        idleProbe = nil
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
        cancelCacheSaves()
        if let host { DSHRemoteKeychain.delete(account: host.serverId) }
        // Unpairing means the cache describes a host we no longer trust.
        DSHRemoteTranscriptCache.removeAll()
        recordMirror = [:]
        UserDefaults.standard.removeObject(forKey: Keys.host)
        host = nil
        client = nil
        conversations = []
        messages = [:]
        cursors = [:]
        streamCursors = [:]
        status = .disconnected
        connectionState = .unpaired
        disconnectReason = nil
        lastFrameAt = nil
        watchdog?.cancel()
        watchdog = nil
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
        // A dead pairing cannot stream: opening one would produce another 401 and
        // re-enter the loop the watchdog used to drive. The page keeps whatever it
        // has and the banner explains why; a re-pair brings the stream back.
        if needsRepair {
            NSLog("[DSH] openStream refused — needsRepair sid=\(sessionId.prefix(12))")
            let dead = DSHRemoteStreamSlot(id: UUID(), sessionId: sessionId, onFrame: onFrame)
            dead.closed = true
            return dead.id
        }
        let slot = DSHRemoteStreamSlot(id: UUID(), sessionId: sessionId, onFrame: onFrame)
        streamSlots[slot.id] = slot
        ensureWatchdog()
        // A dead pair must be repaired BEFORE opening a socket, otherwise the
        // page sits on a stream that can never deliver (the host rejects the
        // token, the user sees a frozen snapshot and blames the app).
        if status != .connected, host != nil, client == nil || isFailureStatus {
            NSLog("[DSH] openStream: status not connected → connect() first sid=\(sessionId.prefix(12))")
            Task { @MainActor [weak self] in
                await self?.connect()
                guard let self, let live = self.streamSlots[slot.id], !live.closed else { return }
                self.start(live)
            }
            return slot.id
        }
        // 1) Cache FIRST: paint what we already have, before any network. This is
        //    the whole point — the page is readable while the socket opens.
        primeFromCache(slot)
        // 2) Then the socket, resuming from the cached cursor when we have one.
        start(slot)
        return slot.id
    }

    /// Show the cached page (if any) and seed the cursor the stream will ask from.
    ///
    /// The cached records are delivered as a SNAPSHOT frame on purpose: that runs
    /// the same rebuild path a live page uses, so the on-disk data and a network
    /// page cannot render differently.
    private func primeFromCache(_ slot: DSHRemoteStreamSlot) {
        guard let serverId = host?.serverId,
              let cached = DSHRemoteTranscriptCache.load(serverId: serverId, sessionId: slot.sessionId) else {
            return
        }
        let age = Int(Date().timeIntervalSince(cached.savedAt))
        NSLog("[DSH] cache hit sid=\(slot.sessionId.prefix(12)) records=\(cached.records.count) age=\(age)s cursor=\(cached.cursor)")
        streamCursors[slot.sessionId] = max(streamCursors[slot.sessionId] ?? 0, cached.cursor)
        recordMirror[slot.sessionId] = cached.records
        slot.onFrame(.snapshot(cursor: cached.cursor, records: cached.records, hasMore: false,
                               running: false, title: nil, contextPressure: nil, tokenUsage: nil))
    }

    private var isFailureStatus: Bool {
        if case .failed = status { return true }
        return status == .disconnected
    }

    /// One ticker for every open Session. Started on the first `openStream`,
    /// stopped when the last one closes.
    private func ensureWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(DSHRemoteStore.watchdogInterval * 1_000_000_000))
                guard let self else { return }
                if self.streamSlots.isEmpty {
                    self.watchdog = nil
                    return
                }
                self.checkStreamHealth()
            }
        }
    }

    /// Declare a socket dead when it has been silent for `staleTimeout`.
    ///
    /// Silence is measured against the last FRAME **or heartbeat**: when nothing
    /// is happening the host still sends `{type:"heartbeat"}` every 15 s (the
    /// device log shows `sse line len=40` for exactly those), so two missed beats
    /// mean the socket is gone even though TCP has not noticed.
    /// How a socket looks given its last sign of life. Pure, so the thresholds can
    /// be asserted (`dsh-remote-projection-selftest.cjs` mirrors them).
    enum StreamHealth: Equatable {
        /// Nothing has ever arrived on this socket.
        case unknown
        case ok
        /// Quiet for a while: show the banner, do not tear anything down yet.
        case quiet(seconds: Int)
        /// Silent past the timeout: the socket is dead, reconnect.
        case stale(seconds: Int)
    }

    static func health(lastActivity: Date?, now: Date) -> StreamHealth {
        guard let lastActivity else { return .unknown }
        let age = now.timeIntervalSince(lastActivity)
        if age > staleTimeout { return .stale(seconds: Int(age)) }
        if age > staleHint { return .quiet(seconds: Int(age)) }
        return .ok
    }

    private func checkStreamHealth() {
        // A dead pairing has no socket to keep alive. Without this the watchdog was
        // the SECOND way into the reconnect loop: the 401 path marked `needsRepair`
        // and stopped the stream, but `lastActivityAt` kept its old value, so three
        // seconds later the slot looked "stale", `restartStale` re-opened it, the
        // host answered 401 again… every ~32 s for ever. Measured on device (v21).
        guard !needsRepair else {
            closeDefunctSlots()
            return
        }
        let now = Date()
        for slot in streamSlots.values where !slot.closed {
            switch DSHRemoteStore.health(lastActivity: slot.lastActivityAt, now: now) {
            case .unknown, .ok:
                continue
            case .quiet(let age):
                // Halfway: a banner is honest here, a teardown is not (a 20 s
                // thought pause on the host looks exactly the same).
                guard connectionState.isHealthy else { continue }
                NSLog("[DSH] stream quiet (lastFrame=\(age)s) sid=\(slot.sessionId.prefix(12))")
                connectionState = .stale(since: slot.lastActivityAt ?? now)
            case .stale(let age):
                // Belt and braces: the loop guard above already returned.
                guard !needsRepair else { continue }
                NSLog("[DSH] stream stale (lastFrame=\(age)s) → reconnect attempt=\(slot.attempt + 1) sid=\(slot.sessionId.prefix(12))")
                if let last = slot.lastActivityAt { connectionState = .stale(since: last) }
                restartStale(slot)
            }
        }
    }

    /// Tear down every socket of a dead pairing and forget them.
    ///
    /// `closed` FIRST, so a callback that is already in flight cannot resurrect a
    /// writer, and the removal is what makes the watchdog blind to them.
    private func closeDefunctSlots() {
        guard !streamSlots.isEmpty else { return }
        NSLog("[DSH] closing \(streamSlots.count) stream(s) — pairing needs repair")
        for slot in streamSlots.values {
            slot.closed = true
            slot.reconnectTask?.cancel()
            slot.reconnectTask = nil
            slot.stream?.close()
            slot.stream = nil
        }
        streamSlots.removeAll()
        watchdog?.cancel()
        watchdog = nil
    }

    /// Tear down a silent socket and open a fresh one.
    ///
    /// No `after`: the snapshot is a REBUILD, and a page trimmed to `after` would
    /// truncate the transcript to the events that followed the last one we saw.
    /// Re-opening without it re-reads the newest page, which is what "catch up"
    /// means here — and it is the same path a first open takes, so nothing is
    /// special-cased.
    private func restartStale(_ slot: DSHRemoteStreamSlot) {
        // The single choke point every reconnect goes through. A dead pairing must
        // never reopen a socket, whatever asked for it.
        guard !needsRepair else {
            NSLog("[DSH] restart refused — needsRepair sid=\(slot.sessionId.prefix(12))")
            closeDefunctSlots()
            return
        }
        slot.stream?.close()
        slot.stream = nil
        slot.reconnectTask?.cancel()
        slot.reconnectTask = nil
        slot.attempt += 1
        connectionState = .reconnecting(attempt: slot.attempt)
        start(slot)
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
        // Nothing is showing this Session any more: its mirror is the only thing
        // keeping hundreds of KB of decoded records alive.
        if !streamSlots.values.contains(where: { $0.sessionId == slot.sessionId && !$0.closed }) {
            dropMirror(sessionId: slot.sessionId)
        }
        if streamSlots.isEmpty {
            watchdog?.cancel()
            watchdog = nil
        }
        NSLog("[DSH] stream closed sid=\(slot.sessionId.prefix(12))")
    }

    private func closeAllLiveStreams() {
        for token in Array(streamSlots.keys) { closeStream(token) }
    }

    /// Has this device already applied events for the Session?
    func streamCursor(sessionId: String) -> Int? { streamCursors[sessionId] }

    private func start(_ slot: DSHRemoteStreamSlot) {
        guard let client else {
            // Not a log-only failure: the UI has to say why nothing streams.
            let reason = host == nil
                ? AppLocalized("Pair this device again.")
                : AppLocalized("The pairing expired. Pair this device again.")
            errorText = reason
            disconnectReason = reason
            status = .failed(reason)
            connectionState = .unavailable(reason)
            NSLog("[DSH] stream cannot start: no client (host=\(host != nil)) reason=\(reason)")
            return
        }
        slot.lastActivityAt = Date()
        // Resume from the newest seq this device has applied: the cached cursor on
        // a cached open, and the last live seq on a reconnect. The host answers
        // `resumed` (append) or `reset` (full page), so a wrong cursor is
        // recoverable now — that is what makes `after` safe where it used to
        // truncate the transcript.
        let after = streamCursors[slot.sessionId].flatMap { $0 > 0 ? $0 : nil }
        NSLog("[DSH] stream open sid=\(slot.sessionId.prefix(12)) after=\(after.map(String.init) ?? "nil") attempt=\(slot.attempt)")
        let token = slot.id
        slot.stream = client.stream(
            sessionId: slot.sessionId,
            after: after,
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
        let now = Date()
        slot.lastActivityAt = now
        lastFrameAt = now
        markHealthy()
        if case .snapshot(let cursor, _, _, _, _, let pressure, let usage) = frame {
            // Live context data goes straight into the panel's published slot: the
            // ring must not need a second request, and a summary fetched earlier
            // keeps its goal/todos while these two are refreshed.
            if let pressure { cachePressure(pressure, sessionId: slot.sessionId) }
            if pressure != nil || usage != nil {
                mergeLiveContext(sessionId: slot.sessionId, pressure: pressure, usage: usage)
            }
            if cursor > 0 {
                // A snapshot is the Session's CURRENT state, so its cursor REPLACES
                // the stored one. Taking `max` made a host that renumbered after a
                // reset unrecoverable: the client kept asking `after=<old, larger
                // seq>`, the host could never satisfy it, and every reconnect
                // re-sent the whole page.
                streamCursors[slot.sessionId] = cursor
            }
            errorText = nil
        }
        // Keep the on-disk copy in step with what the writer has been given: a
        // snapshot REPLACES the mirror, every event APPENDS to it.
        mirrorFrame(frame, sessionId: slot.sessionId)
        slot.onFrame(frame)
    }

    /// One short line per frame. `String(describing:)` on a snapshot frame would
    /// print all 40 records — tens of kilobytes into the device log.
    static func frameTag(_ frame: DSHRemoteStreamFrame) -> String {
        switch frame {
        case .snapshot(let cursor, let records, _, let running, _, _, _):
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
        guard let slot = streamSlots[token], !slot.closed else { return }
        // Heartbeats arrive here and nowhere else, so this is the liveness signal
        // that keeps an idle Session from being declared stale.
        let now = Date()
        slot.lastActivityAt = now
        lastFrameAt = now
        markHealthy()
        guard cursor > 0 else { return }
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
            // Permanent: the user has to act. A dead pairing keeps its state until a
            // re-pair, and a plain permanent failure is still a reason to show.
            let reason = message ?? AppLocalized("The connection was closed by the computer.")
            if needsRepair || reason.localizedCaseInsensitiveContains("pair") {
                markNeedsRepair(reason)
            } else {
                status = .failed(reason)
                connectionState = .unavailable(reason)
                disconnectReason = reason
                errorText = reason
            }
            // Take the slot OUT of the store. `return` alone left it in
            // `streamSlots`, so the watchdog kept seeing a silent socket and
            // reopened it every ~32 s, each time collecting another 401.
            slot.closed = true
            slot.reconnectTask?.cancel()
            slot.reconnectTask = nil
            slot.stream?.close()
            slot.stream = nil
            streamSlots.removeValue(forKey: token)
            if streamSlots.isEmpty {
                watchdog?.cancel()
                watchdog = nil
            }
            return
        }
        // A dead pairing must not re-enter the reconnect loop even if some caller
        // hands us a retryable finish.
        guard !needsRepair else {
            NSLog("[DSH] stream reconnect suppressed — needsRepair sid=\(slot.sessionId.prefix(12))")
            slot.closed = true
            slot.stream?.close()
            slot.stream = nil
            streamSlots.removeValue(forKey: token)
            return
        }
        let delay = DSHRemoteStore.backoffDelay(attempt: slot.attempt)
        slot.attempt += 1
        connectionState = .reconnecting(attempt: slot.attempt)
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

    // MARK: - Session summary (context panel)

    /// Context / goal / todos / usage per Session, for the context panel.
    ///
    /// Populated by BOTH paths: `refreshSessionSummary` (the full GET) and every
    /// snapshot frame (live context + usage), so the ring is current without a
    /// second request. The panel decides when to refresh; the store never polls.
    @Published private(set) var summaries: [String: DSHRemoteSessionSummary] = [:]

    /// Fetch the whole summary and publish it.
    func sessionSummary(sessionId: String) async throws -> DSHRemoteSessionSummary {
        guard let client else {
            throw DSHRemoteError(code: "dsh/unavailable", message: "This device is not paired.", status: nil)
        }
        let summary = try await client.sessionSummary(sessionId: sessionId)
        var merged = summaries[sessionId] ?? DSHRemoteSessionSummary.empty(sessionId: sessionId)
        merged.sessionId = summary.sessionId ?? sessionId
        merged.asOfSeq = summary.asOfSeq
        // A block the host did not send keeps what the panel already had: a partial
        // answer must not erase the goal the user is reading.
        if let context = summary.context { merged.context = context }
        if let goal = summary.goal { merged.goal = goal }
        if let todos = summary.todos { merged.todos = todos }
        if let usage = summary.tokenUsage { merged.tokenUsage = usage }
        summaries[sessionId] = merged
        return merged
    }

    /// Fold a snapshot frame's live context/usage into the panel's slot.
    private func mergeLiveContext(sessionId: String, pressure: DSHContextPressure?,
                                  usage: DSHRemoteSessionSummary.TokenUsage?) {
        let current = summaries[sessionId] ?? DSHRemoteSessionSummary.empty(sessionId: sessionId)
        summaries[sessionId] = current.withLiveContext(pressure, usage: usage)
    }

    private func cachePressure(_ pressure: DSHContextPressure, sessionId: String) {
        guard let index = rows.firstIndex(where: { $0.session.sessionId == sessionId }) else { return }
        var row = rows[index]
        row.session.contextPressure = pressure
        rows[index] = row
    }

    // MARK: - Transcript cache (open fast, then catch up)

    /// In-memory mirror of the cached records per Session: what the disk copy will
    /// hold once the throttle fires. Kept as records, not as rendered rows, so a
    /// save never depends on the writer.
    ///
    /// Dropped when the Session's last slot closes — this used to survive until
    /// unpair, so every Session opened in a run stayed in memory for the rest of it
    /// (a 400-record page is hundreds of KB of decoded events, per Session).
    private var recordMirror: [String: [DSHHistoryRecord]] = [:]
    /// Sequence numbers already in `recordMirror[sessionId]`.
    ///
    /// Dedupe was a linear scan of the whole mirror per event, so a long Session
    /// cost O(n²) on the MAIN ACTOR — the input field stutters exactly when the
    /// transcript is longest. A set makes it O(1).
    private var recordMirrorSeqs: [String: Set<Double>] = [:]
    /// Session → pending save task (2 s throttle, one per Session).
    private var cacheSaveTasks: [String: Task<Void, Never>] = [:]
    /// Records are cheap to hold but pointless to write on every frame.
    private static let cacheSaveDelay: TimeInterval = 2

    private func mirrorFrame(_ frame: DSHRemoteStreamFrame, sessionId: String) {
        switch frame {
        case .snapshot(_, let records, _, _, _, _, _):
            // A snapshot is a REPLACE: the mirror must not keep a single record the
            // page no longer shows, or the next open resurrects them.
            recordMirror[sessionId] = records
            recordMirrorSeqs[sessionId] = Set(records.compactMap { $0.seq })
            scheduleCacheSave(sessionId: sessionId)
        case .event(let seq, let event):
            // Dedupe by seq: a resumed stream and a live event can carry the same
            // record, and a duplicated record would be applied twice on the next
            // open.
            var seqs = recordMirrorSeqs[sessionId] ?? []
            guard !seqs.contains(Double(seq)) else { return }
            seqs.insert(Double(seq))
            recordMirrorSeqs[sessionId] = seqs
            recordMirror[sessionId, default: []].append(DSHHistoryRecord(seq: Double(seq), event: event))
            scheduleCacheSave(sessionId: sessionId)
        case .delta, .deltaEnd:
            break
        }
    }

    /// Throttled write. One pending task per Session; the newest mirror wins.
    ///
    /// The encoding and the atomic write happen OFF the main actor: a 400-record
    /// page is hundreds of KB, and doing the JSON encode + fsync there stalled the
    /// UI right when a stream finished.
    private func scheduleCacheSave(sessionId: String) {
        guard let serverId = host?.serverId else { return }
        cacheSaveTasks[sessionId]?.cancel()
        cacheSaveTasks[sessionId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DSHRemoteStore.cacheSaveDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.cacheSaveTasks[sessionId] = nil
            guard let records = self.recordMirror[sessionId] else { return }
            // Only the CONTIGUOUS tail is safe to cache: `after=cursor` promises
            // "everything after this point", so a page with a hole in the middle
            // would come back as a transcript with a piece missing for ever.
            let tail = DSHRemoteTranscriptCache.contiguousTail(records)
            guard let last = tail.last?.seq.map(Int.init) ?? self.streamCursors[sessionId], last > 0 else { return }
            // `records`/`tail` are values, so handing them to a detached task is
            // safe; nothing but the return value comes back.
            let total = records.count
            Task.detached(priority: .utility) {
                let written = DSHRemoteTranscriptCache.save(serverId: serverId, sessionId: sessionId,
                                                            cursor: last, records: tail)
                NSLog("[DSH] cache save sid=\(sessionId.prefix(12)) records=\(written)/\(total) cursor=\(last)")
            }
        }
    }

    /// Forget a Session's mirror when nothing is looking at it any more.
    private func dropMirror(sessionId: String) {
        recordMirror[sessionId] = nil
        recordMirrorSeqs[sessionId] = nil
        cacheSaveTasks[sessionId]?.cancel()
        cacheSaveTasks[sessionId] = nil
    }


    private func cancelCacheSaves() {
        for task in cacheSaveTasks.values { task.cancel() }
        cacheSaveTasks = [:]
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

    // MARK: Harness team (tools run here, not in the UI)

    /// Whether this device can reach a client at all. The team tools gate on it.
    var isPaired: Bool { client != nil && host != nil }

    func listTeamMembers() async throws -> DSHRemoteTeamRoster {
        guard let client else {
            throw DSHRemoteError(code: "dsh/unavailable", message: "This device is not paired.", status: nil)
        }
        let roster = try await client.listTeamMembers()
        NSLog("[DSH] team members=\(roster.members.count) lead=\(roster.lead?.sessionId?.prefix(12) ?? "nil")")
        return roster
    }

    func spawnTeammate(name: String, description: String?, task: String,
                       context: String? = nil) async throws -> DSHRemoteTeamMember {
        guard let client else {
            throw DSHRemoteError(code: "dsh/unavailable", message: "This device is not paired.", status: nil)
        }
        let member = try await client.spawnTeammate(name: name, description: description,
                                                   task: task, context: context)
        NSLog("[DSH] team spawn name=\(member.name) sid=\(member.sessionId?.prefix(12) ?? "nil")")
        return member
    }

    func sendTeamMessage(target: String, text: String) async throws -> DSHRemoteTeamDelivery {
        guard let client else {
            throw DSHRemoteError(code: "dsh/unavailable", message: "This device is not paired.", status: nil)
        }
        let delivery = try await client.sendTeamMessage(target: target, text: text)
        NSLog("[DSH] team message target=\(target) delivered=\(delivery.delivered.map(String.init) ?? "nil")")
        return delivery
    }

    func interruptTeammate(target: String) async throws -> DSHRemoteTeamInterrupt {
        guard let client else {
            throw DSHRemoteError(code: "dsh/unavailable", message: "This device is not paired.", status: nil)
        }
        let result = try await client.interruptTeammate(target: target)
        NSLog("[DSH] team interrupt target=\(target) ok=\(result.interrupted.map(String.init) ?? "nil")")
        return result
    }

    /// What a teammate has said so far, read from its own Session transcript.
    func teamTranscript(sessionId: String, limit: Int = 20) async throws -> DSHRemoteTeamAnswer {
        guard let client else {
            throw DSHRemoteError(code: "dsh/unavailable", message: "This device is not paired.", status: nil)
        }
        return try await client.teamTranscript(sessionId: sessionId, limit: limit)
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
    /// When the last frame OR heartbeat arrived on this socket. `nil` until the
    /// first byte; refreshed on every `start` so a new socket gets a full grace
    /// period instead of inheriting the dead one's silence.
    var lastActivityAt: Date?

    init(id: UUID, sessionId: String, onFrame: @escaping (DSHRemoteStreamFrame) -> Void) {
        self.id = id
        self.sessionId = sessionId
        self.onFrame = onFrame
    }
}
