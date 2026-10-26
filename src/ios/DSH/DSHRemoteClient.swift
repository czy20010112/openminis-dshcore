import Foundation
import Security

// MARK: - Keychain

/// Small Keychain wrapper for the device session. The access/refresh tokens never
/// touch UserDefaults; only the host URL/name/serverId do.
enum DSHRemoteKeychain {
    private static let service = "app.minis.dshremote"

    static func save(_ session: DSHRemoteSession, account: String) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> DSHRemoteSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(DSHRemoteSession.self, from: data)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Client

/// One row of `GET /mobile/v1/dsh/sessions`.
///
/// The row is `DSHHostSession` plus two list-only extras the sidebar shows as its
/// subtitle: `preview` (the newest turn's text, bridge-truncated to 120 code points)
/// and `turns` (the completed-turn count). They are decoded *around* `DSHHostSession`
/// instead of inside it because that type is shared with the rest of the DSH layer
/// (and owned by another change), while a preview is a sidebar-row concern only.
///
/// Both extras are optional, and nil is a normal answer: a Session that never ran has
/// no turn to quote, and a bridge build that predates the field sends neither (a
/// plugin change only reaches this device after the host restarts).
struct DSHHostSessionRow: Decodable, Identifiable, Equatable, Sendable {
    var session: DSHHostSession
    var preview: String?
    var turns: Int?

    var id: String { session.sessionId }

    private enum Keys: String, CodingKey {
        case preview
        case turns
    }

    init(session: DSHHostSession, preview: String?, turns: Int?) {
        self.session = session
        self.preview = preview
        self.turns = turns
    }

    init(from decoder: Decoder) throws {
        // Both key sets live in the same JSON object: `DSHHostSession` reads the keys
        // it knows, this reads the two it does not.
        session = try DSHHostSession(from: decoder)
        let container = try decoder.container(keyedBy: Keys.self)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        turns = try container.decodeIfPresent(Int.self, forKey: .turns)
    }
}

/// HTTP client for the DSH mobile bridge (`/mobile/v1`).
///
/// The protocol mirrors `packages/mobile-sdk/index.js` in the DS-Bot-App repo:
/// anonymous `/info`, pairing code exchange, Bearer-authenticated reads and a
/// WebSocket at `/mobile/v1/events`.
final class DSHRemoteClient: @unchecked Sendable {
    private let base: URL
    /// Sessions go through the system proxy on macOS, and on the Simulator that
    /// proxy is whatever the host machine runs — a TLS-terminating proxy makes
    /// every request fail with NSURLErrorDomain -1200 / -9816 ("secure
    /// connection failed"). Real devices do not sit behind the host's proxy, so
    /// only the Simulator opts out. `connectionProxyDictionary = [:]` means
    /// "no proxy", which is what an empty dictionary is documented to do.
    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        #if targetEnvironment(simulator)
        config.connectionProxyDictionary = [:]
        #endif
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private let urlSession: URLSession
    private let lock = NSLock()
    private var session: DSHRemoteSession
    private var refreshing = false

    init(session: DSHRemoteSession, urlSession: URLSession = DSHRemoteClient.defaultSession) {
        self.session = session
        self.base = DSHRemoteClient.origin(from: session.baseURL)
        self.urlSession = urlSession
    }

    // MARK: URL helpers

    static func origin(from raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme) ?? URL(string: "https://localhost")!
    }

    private func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("mobile/v1" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    var eventsURL: URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = "/mobile/v1/events"
        return components.url!
    }

    // MARK: Session access

    private func currentSession() -> DSHRemoteSession {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    /// The token the NEXT request will carry.
    ///
    /// Streams must take it from here and never from the Keychain: a
    /// DEBUG-injected session (`MINIS_DSH_SESSION`) is not written to the
    /// Keychain at all, and a refresh only updates this client's copy — reading
    /// the Keychain gave an empty/stale token and a guaranteed 401.
    var accessToken: String { currentSession().accessToken }

    /// Same token, refreshed first when it is within a minute of expiry.
    ///
    /// Everything here is bounded: `makeStreamRequest` calls it BEFORE the socket
    /// opens, so an unbounded wait would show up as "the stream never starts"
    /// rather than as a transport failure — hence the two log lines.
    func freshAccessToken() async throws -> String {
        let current = currentSession()
        let remaining = current.expiresAt - Date().timeIntervalSince1970 * 1000
        NSLog("[DSH] token check remaining=\(Int(remaining / 1000))s server=\(current.serverId.prefix(12))")
        guard remaining < 60_000 else {
            return current.accessToken
        }
        NSLog("[DSH] token expired/expiring — refreshing")
        let fresh = try await refreshed(current)
        NSLog("[DSH] token refreshed ok")
        return fresh.accessToken
    }

    private func store(_ value: DSHRemoteSession) {
        lock.lock(); session = value; lock.unlock()
        // A refreshed session is persisted for the paired host; an injected
        // DEBUG session is not, so this stays best-effort.
        DSHRemoteKeychain.save(value, account: value.serverId)
    }

    // MARK: Anonymous endpoints

    /// `GET /mobile/v1/info` — handshake, no credentials.
    static func info(url: String, urlSession: URLSession = DSHRemoteClient.defaultSession) async throws -> DSHRemoteInfo {
        let origin = DSHRemoteClient.origin(from: url)
        let target = origin.appendingPathComponent("mobile/v1/info")
        var request = URLRequest(url: target)
        request.timeoutInterval = 12
        let (data, response) = try await urlSession.data(for: request)
        try DSHRemoteClient.check(response: response, data: data)
        return try JSONDecoder().decode(DSHRemoteInfo.self, from: data)
    }

    /// `POST /mobile/v1/pairings` — trade the 120-second code for a claim token.
    static func beginPairing(url: String, code: String, deviceName: String, urlSession: URLSession = DSHRemoteClient.defaultSession) async throws -> DSHRemotePairingClaim {
        let origin = DSHRemoteClient.origin(from: url)
        var request = URLRequest(url: origin.appendingPathComponent("mobile/v1/pairings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "deviceName": deviceName])
        let (data, response) = try await urlSession.data(for: request)
        try DSHRemoteClient.check(response: response, data: data)
        return try JSONDecoder().decode(DSHRemotePairingClaim.self, from: data)
    }

    /// `POST /mobile/v1/pairings/complete` — poll until the host approves.
    /// Returns the issued session, or nil while the request is still pending.
    static func completePairing(url: String, claimToken: String, hostName: String?, urlSession: URLSession = DSHRemoteClient.defaultSession) async throws -> DSHRemoteSession? {
        let origin = DSHRemoteClient.origin(from: url)
        var request = URLRequest(url: origin.appendingPathComponent("mobile/v1/pairings/complete"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: ["claimToken": claimToken])
        let (data, response) = try await urlSession.data(for: request)
        try DSHRemoteClient.check(response: response, data: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let status = object["status"] as? String
        if status == "pending" { return nil }
        var session = try JSONDecoder().decode(DSHRemoteSession.self, from: data)
        session.baseURL = origin.absoluteString
        if session.hostName == nil { session.hostName = hostName }
        return session
    }

    /// `POST /mobile/v1/auth/refresh`
    static func refresh(session: DSHRemoteSession, urlSession: URLSession = DSHRemoteClient.defaultSession) async throws -> DSHRemoteSession {
        let origin = DSHRemoteClient.origin(from: session.baseURL)
        var request = URLRequest(url: origin.appendingPathComponent("mobile/v1/auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": session.refreshToken])
        let (data, response) = try await urlSession.data(for: request)
        try DSHRemoteClient.check(response: response, data: data)
        var next = try JSONDecoder().decode(DSHRemoteSession.self, from: data)
        next.baseURL = origin.absoluteString
        next.hostName = session.hostName
        return next
    }

    // MARK: Authenticated endpoints

    /// Refreshes once when the access token is rejected, then retries.
    func authorizedData(path: String, method: String = "GET", json: Any? = nil, query: [URLQueryItem] = [], retry: Bool = true) async throws -> Data {
        var session = currentSession()
        if session.expiresAt - Date().timeIntervalSince1970 * 1000 < 30_000, retry {
            session = try await refreshed(session)
        }
        var request = URLRequest(url: endpoint(path, query: query))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await urlSession.data(for: request)
        do {
            try DSHRemoteClient.check(response: response, data: data)
            return data
        } catch let error as DSHRemoteError where error.needsRepair && retry {
            _ = try await refreshed(session)
            return try await authorizedData(path: path, method: method, json: json, query: query, retry: false)
        }
    }

    private func refreshed(_ stale: DSHRemoteSession) async throws -> DSHRemoteSession {
        let next = try await DSHRemoteClient.refresh(session: stale, urlSession: urlSession)
        store(next)
        return next
    }

    func conversations() async throws -> [DSHRemoteConversation] {
        let data = try await authorizedData(path: "/conversations")
        struct Envelope: Decodable { var items: [DSHRemoteConversation]?; var conversations: [DSHRemoteConversation]? }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.items ?? envelope.conversations ?? []
    }

    /// `GET /mobile/v1/dsh/sessions` — the harness' own Session list (web sidebar),
    /// not the Bot roster.
    func hostSessions() async throws -> [DSHHostSessionRow] {
        let data = try await authorizedData(path: "/dsh/sessions")
        struct Envelope: Decodable { var items: [DSHHostSessionRow]? }
        return (try JSONDecoder().decode(Envelope.self, from: data)).items ?? []
    }

    /// `GET /mobile/v1/dsh/messages` — one page of a Session's raw event log.
    func hostMessages(sessionId: String, beforeSeq: Double? = nil, limit: Int = 40) async throws -> DSHMessagesPage {
        var query = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let beforeSeq, beforeSeq > 0 {
            query.append(URLQueryItem(name: "beforeSeq", value: String(Int(beforeSeq))))
        }
        let data = try await authorizedData(path: "/dsh/messages", query: query)
        return try JSONDecoder().decode(DSHMessagesPage.self, from: data)
    }

    func messages(conversationId: String, cursor: String? = nil, limit: Int = 40) async throws -> DSHRemotePage {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let path = "/conversations/\(conversationId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? conversationId)/messages"
        let data = try await authorizedData(path: path, query: query)
        return try JSONDecoder().decode(DSHRemotePage.self, from: data)
    }

    func action(_ endpoint: String, payload: [String: Any] = [:]) async throws -> Data {
        try await authorizedData(path: "/actions", method: "POST", json: ["endpoint": endpoint, "payload": payload])
    }

    func submit(conversationId: String, sessionId: String, text: String, requestId: String) async throws -> Data {
        try await authorizedData(path: "/submissions", method: "POST", json: [
            "conversationId": conversationId,
            "sessionId": sessionId,
            "requestId": requestId,
            "text": text,
        ])
    }

    // MARK: Harness write path (protocol §1.1 / §1.2)

    /// `POST /mobile/v1/dsh/submissions` — deliver a prompt into a harness Session.
    ///
    /// `requestId` is the idempotency key: the host answers `accepted:true` for a
    /// duplicate instead of queueing a second prompt, so a retry after a flaky
    /// response cannot double-send.
    func submit(sessionId: String, text: String, requestId: String) async throws {
        _ = try await authorizedData(path: "/dsh/submissions", method: "POST", json: [
            "sessionId": sessionId,
            "text": text,
            "requestId": requestId,
            "clientTimeZone": TimeZone.current.identifier,
        ])
    }

    /// `POST /mobile/v1/dsh/cancel` — stop the Session's running turn.
    func cancel(sessionId: String) async throws {
        _ = try await authorizedData(path: "/dsh/cancel", method: "POST", json: [
            "sessionId": sessionId,
        ])
    }

    // MARK: Live stream (protocol §1.3)

    /// Open the SSE stream for one Session.
    ///
    /// Returns immediately; frames are delivered on the main queue. `close()`
    /// cancels the underlying task, which is what makes the host see the
    /// connection drop and abort its `follow()` iterator.
    func stream(sessionId: String,
                after: Int?,
                onFrame: @escaping (DSHRemoteStreamFrame) -> Void,
                onCursor: @escaping (Int) -> Void = { _ in },
                onFinish: @escaping (String?, Bool) -> Void = { _, _ in }) -> DSHRemoteStream {
        let stream = DSHRemoteStream(
            client: self, sessionId: sessionId, after: after,
            onFrame: onFrame, onCursor: onCursor, onFinish: onFinish
        )
        stream.start()
        return stream
    }

    /// Build the SSE request for `DSHRemoteStream`. Re-reads the token every
    /// time, so a reconnect after a refresh carries the new one.
    func makeStreamRequest(sessionId: String, after: Int?, maxMessages: Int) async throws -> URLRequest {
        let token = try await freshAccessToken()
        var query = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "maxMessages", value: String(maxMessages)),
        ]
        if let after, after > 0 { query.append(URLQueryItem(name: "after", value: String(after))) }
        var request = URLRequest(url: endpoint("/dsh/events", query: query))
        request.httpMethod = "GET"
        // Idle timeout, not a total budget: the host sends a `: hb` comment every
        // 15 s, so anything near a minute of silence means the connection is dead.
        request.timeoutInterval = 90
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    func openByteStream(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await urlSession.bytes(for: request)
    }

    /// Turn a non-2xx stream response into the same `DSHRemoteError` the JSON
    /// endpoints produce, reading the body off the byte stream we already have.
    static func streamError(status: Int, bytes: URLSession.AsyncBytes) async -> DSHRemoteError {
        var raw = Data()
        do {
            for try await byte in bytes {
                raw.append(byte)
                if raw.count >= 4096 { break }
            }
        } catch {
            // The body is best-effort: a broken stream still has a status code.
        }
        return error(from: raw, status: status)
    }

    // MARK: Errors

    static func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw error(from: data, status: http.statusCode)
        }
    }

    /// Decode the bridge's `{ "error": { "code", "message" } }` envelope, falling
    /// back to a status-derived code so every failure path reports something.
    static func error(from data: Data, status: Int) -> DSHRemoteError {
        var code = "http_\(status)"
        var message = "The host refused this request."
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            code = error["code"] as? String ?? code
            message = error["message"] as? String ?? message
        }
        return DSHRemoteError(code: code, message: message, status: status)
    }
}

// MARK: - Live harness stream (SSE)

/// One `GET /mobile/v1/dsh/events` connection.
///
/// Wiring, in the order it happens:
///   1. `start()` spawns a task that opens the byte stream and iterates LINES,
///      which is all SSE needs (`data: {json}` … blank line … repeat);
///   2. `: hb` comments are ignored here — they exist to keep the connection and
///      the idle timeout alive, and the cursor they carry arrives separately as
///      a `heartbeat` frame;
///   3. frames are decoded into `DSHRemoteStreamFrame` and delivered on the main
///      queue, so both the store and the writer are main-actor safe;
///   4. `close()` cancels the task. That drops the TCP connection, which is the
///      only thing that makes the host abort its `follow()` iterator — letting
///      the socket linger leaves a stream slot occupied (the host allows 2).
final class DSHRemoteStream: @unchecked Sendable {
    private let client: DSHRemoteClient
    private let sessionId: String
    private let initialAfter: Int?
    private let maxMessages: Int
    private let onFrame: (DSHRemoteStreamFrame) -> Void
    private let onCursor: (Int) -> Void
    /// `(message, retryable)` — plain values on purpose: this crosses back into
    /// the main actor through a task, and an `Error` payload is not `Sendable`.
    private let onFinish: (String?, Bool) -> Void

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var closed = false
    private var receivedFrame = false
    private var lastCursor: Int?

    init(client: DSHRemoteClient, sessionId: String, after: Int?, maxMessages: Int = 100,
         onFrame: @escaping (DSHRemoteStreamFrame) -> Void,
         onCursor: @escaping (Int) -> Void,
         onFinish: @escaping (String?, Bool) -> Void) {
        self.client = client
        self.sessionId = sessionId
        self.initialAfter = after
        self.maxMessages = maxMessages
        self.onFrame = onFrame
        self.onCursor = onCursor
        self.onFinish = onFinish
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// True once at least one frame arrived — the store uses it to decide
    /// whether a reconnect resets its backoff or keeps backing off.
    var didReceiveFrame: Bool {
        lock.lock(); defer { lock.unlock() }
        return receivedFrame
    }

    func start() {
        lock.lock()
        guard !closed, task == nil else { lock.unlock(); return }
        let after = lastCursor ?? initialAfter
        lock.unlock()
        // DETACHED, deliberately.
        //
        // A plain `Task {}` inherits the actor context it is created in, and this
        // one is created from a `@MainActor` caller (`DSHRemoteStore.start`). An
        // inherited task's body first hops back to the main actor to run — so if
        // the main thread is busy laying out 40 freshly-applied rows, the network
        // request simply does not start, and none of the stream's own log lines
        // ever appear. That is exactly the shape of the "spinner forever, zero
        // logs after `stream open`" report.
        //
        // Nothing in `run` needs the main actor: it touches only lock-guarded
        // state and hands every callback to the main queue through `deliver`.
        NSLog("[DSH] stream task spawn sid=\(sessionId.prefix(12))")
        task = Task.detached(priority: .utility) { [weak self] in
            NSLog("[DSH] stream task start main=\(Thread.isMainThread)")
            await self?.run(after: after)
            NSLog("[DSH] stream task end")
        }
    }

    /// Disconnect and do NOT reconnect. Idempotent.
    func close() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        let running = task
        task = nil
        lock.unlock()
        guard !alreadyClosed else { return }
        running?.cancel()
    }

    // MARK: Run loop

    private func run(after: Int?) async {
        var finishMessage: String?
        var retryable = true
        NSLog("[DSH] sse start sid=\(sessionId.prefix(12)) after=\(after.map(String.init) ?? "nil") main=\(Thread.isMainThread)")
        var lineCount = 0
        var frameCount = 0
        do {
            NSLog("[DSH] run stage=request sid=\(sessionId.prefix(12))")
            let request = try await client.makeStreamRequest(
                sessionId: sessionId, after: after, maxMessages: maxMessages
            )
            NSLog("[DSH] sse request ready sid=\(sessionId.prefix(12)) url=\(request.url?.absoluteString ?? "nil")")
            NSLog("[DSH] run stage=open")
            let (bytes, response) = try await client.openByteStream(request)
            let http = response as? HTTPURLResponse
            let encoding = http?.value(forHTTPHeaderField: "Transfer-Encoding") ?? "-"
            let bodyBytes = http?.value(forHTTPHeaderField: "Content-Length") ?? "-"
            NSLog("[DSH] sse status=\(http?.statusCode ?? -1) te=\(encoding) cl=\(bodyBytes) sid=\(sessionId.prefix(12))")
            if let http, !(200..<300).contains(http.statusCode) {
                let error = await DSHRemoteClient.streamError(status: http.statusCode, bytes: bytes)
                NSLog("[DSH] sse rejected status=\(http.statusCode) code=\(error.code) msg=\(error.message)")
                deliver { self.onFinish(error.message, error.isRetryable) }
                return
            }

            var payload = ""
            // Deliver one accumulated frame. Kept in a closure so the three call
            // sites below (a complete single line, a completed multi-line frame,
            // the end of the stream) cannot drift.
            func flushFrame(reason: String) {
                guard !payload.isEmpty else { return }
                let frame = payload
                payload = ""
                guard handle(frame) else {
                    payload = frame
                    return
                }
                frameCount += 1
                NSLog("[DSH] sse frame n=\(frameCount) bytes=\(frame.count) why=\(reason)")
            }
            NSLog("[DSH] run stage=loop")
            for try await line in bytes.lines {
                lineCount += 1
                if isClosed { NSLog("[DSH] sse break (closed) lines=\(lineCount)"); break }
                if line.isEmpty {
                    // The spec's frame boundary — but measured on device,
                    // `URLSession.AsyncBytes.lines` does NOT hand us the blank line
                    // between `data: …\n\n`. Nothing depends on it any more; it is
                    // logged so the next reader can see which shape this OS sends.
                    NSLog("[DSH] sse line n=\(lineCount) len=0 (blank line delivered)")
                    flushFrame(reason: "blank")
                    continue
                }
                // Lengths only: a 74 KB snapshot line would flood the log with its
                // own body, and the interesting fact is whether lines arrive at all.
                NSLog("[DSH] sse line n=\(lineCount) len=\(line.count) prefix=\(line.prefix(10))")
                if line.hasPrefix(":") { continue }              // `: hb`
                guard line.hasPrefix("data:") else { continue }   // `event:`/`id:`/`retry:`
                let chunk = String(line.dropFirst("data:".count))
                guard !payload.isEmpty else {
                    // The normal case: one whole JSON object on one `data:` line.
                    // Try it right now — this is the line that removes the 14 s
                    // wait for the next heartbeat.
                    if handle(chunk) {
                        frameCount += 1
                        NSLog("[DSH] sse frame n=\(frameCount) bytes=\(chunk.count) why=immediate")
                    } else {
                        payload = chunk
                    }
                    continue
                }
                // A previous `data:` line did not decode on its own: this is the
                // continuation of a multi-line frame (the spec joins them with \n).
                payload += "\n" + chunk
                flushFrame(reason: "joined")
            }
            NSLog("[DSH] run stage=left-loop lines=\(lineCount) frames=\(frameCount) sid=\(sessionId.prefix(12))")
            // A frame without a trailing newline (or a stream that ended right
            // after its last `data:` line) still has to reach the writer.
            flushFrame(reason: "eof")
        } catch {
            // A cancelled task surfaces as URLError.cancelled; that is a close,
            // not a failure.
            NSLog("[DSH] sse threw: \(error) closed=\(isClosed)")
            if !isClosed, !Self.isCancellation(error) {
                finishMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if let remote = error as? DSHRemoteError { retryable = remote.isRetryable }
            }
        }

        let closedByUs = isClosed
        clearTask()
        NSLog("[DSH] sse finish sid=\(sessionId.prefix(12)) lines=\(lineCount) frames=\(frameCount) closed=\(closedByUs) msg=\(finishMessage ?? "nil")")
        guard !closedByUs else { return }
        // A clean end (the host closed the stream) is still a reconnect: the
        // Session is still there and the page still wants its events.
        deliver { self.onFinish(finishMessage, retryable) }
    }

    /// Drop the finished task handle. Kept out of the async body so the lock is
    /// never taken from an async context (Swift 6 makes that a hard error).
    private func clearTask() {
        lock.lock()
        task = nil
        lock.unlock()
    }

    /// Decode and deliver one candidate frame.
    ///
    /// - Returns: `true` when the text was a complete, decodable frame (so the
    ///   caller can drop it), `false` when it was not — which is how a `data:`
    ///   line that is only the FIRST line of a multi-line frame is recognised.
    ///
    /// The return value exists for latency, not for correctness: waiting for the
    /// next `data:` (or for a blank line the transport never sends) to decide that
    /// a frame is complete delayed the first snapshot by 14 s — one heartbeat.
    private func handle(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8) else {
            NSLog("[DSH] frame not utf8 bytes=\(json.count)")
            return false
        }
        let envelope: DSHRemoteStreamEnvelope
        do {
            envelope = try JSONDecoder().decode(DSHRemoteStreamEnvelope.self, from: data)
        } catch {
            // Logged, not swallowed: "the host sent a frame this build cannot
            // decode" and "the host never sent a frame" used to look identical
            // from the device log, which is exactly what made a stuck spinner
            // unattributable. A partial line (multi-line frame) lands here too,
            // which is why this is not fatal.
            NSLog("[DSH] frame decode failed bytes=\(data.count) head=\(String(json.prefix(80))) err=\(error)")
            return false
        }
        NSLog("[DSH] frame type=\(envelope.type) records=\(envelope.records?.count ?? -1) seq=\(envelope.seq.map(String.init) ?? "-")")
        apply(envelope)
        return true
    }

    /// The frame bodies. Split out of `handle` so every early `return` below stays
    /// a plain `return` even though `handle` now reports a decode result.
    private func apply(_ envelope: DSHRemoteStreamEnvelope) {
        switch envelope.type {
        case "snapshot":
            noteCursor(envelope.cursor)
            let records = envelope.records ?? []
            let frame = DSHRemoteStreamFrame.snapshot(
                cursor: envelope.cursor ?? 0, records: records, hasMore: envelope.hasMore ?? false,
                running: envelope.running ?? false, title: envelope.title,
                contextPressure: envelope.contextPressure
            )
            deliver { self.onFrame(frame) }

        case "event":
            if let seq = envelope.seq ?? envelope.event?.seq.map({ Int($0) }) {
                noteCursor(seq)
                if let event = envelope.event {
                    deliver { self.onFrame(.event(seq: seq, event: event)) }
                }
            }

        case "delta":
            // `turn`/`step` are missing on a delta whose attempt STARTED before
            // this connection opened (the host learns them from the attempt's
            // `start` frame). Those are dropped on purpose: inventing turn 0 would
            // create a row the durable `assistant/message` never rewrites, so the
            // same text would show twice. The durable event carries the content.
            guard let turn = envelope.turn, let step = envelope.step, let index = envelope.index,
                  let text = envelope.text, !text.isEmpty,
                  let channel = envelope.channel.flatMap(DSHStreamChannel.init(rawValue:)) else { return }
            let attempt = envelope.attempt ?? "\(turn)-\(step)"
            deliver {
                self.onFrame(.delta(turn: turn, step: step, attempt: attempt,
                                    index: index, channel: channel, text: text))
            }

        case "delta-end":
            // Same "attempt predates this stream" case as above: without a turn
            // there is nothing to seal, and the next durable event (or the turn
            // end) is the boundary anyway.
            guard let turn = envelope.turn, let step = envelope.step else { return }
            let attempt = envelope.attempt ?? "\(turn)-\(step)"
            deliver { self.onFrame(.deltaEnd(turn: turn, step: step, attempt: attempt)) }

        case "heartbeat":
            noteCursor(envelope.cursor)

        case "error":
            // Terminal for this connection. `SESSION_NOT_FOUND` is permanent —
            // retrying it would just spin against a Session that is gone.
            let code = envelope.code ?? "stream/error"
            let message = envelope.message ?? "The host closed the stream."
            let retryable = !["SESSION_NOT_FOUND", "DSH_UNAVAILABLE", "session/not-found"].contains(code)
            // Delivered BEFORE `close()`, and through the forced dispatcher: the
            // close below would otherwise make `deliver` drop the one frame the
            // caller must not miss.
            dispatch { self.onFinish(message, retryable) }
            close()

        default:
            return
        }
    }

    private func noteCursor(_ cursor: Int?) {
        guard let cursor, cursor > 0 else { return }
        lock.lock()
        let previous = lastCursor ?? 0
        if cursor > previous { lastCursor = cursor }
        let value = max(cursor, previous)
        lock.unlock()
        deliver { self.onCursor(value) }
    }

    /// Deliver on the main queue, and drop anything that arrives after close so
    /// a late frame cannot resurrect a writer the UI already tore down.
    private func deliver(_ body: @escaping () -> Void) {
        if isClosed { return }
        lock.lock(); receivedFrame = true; lock.unlock()
        DispatchQueue.main.async {
            guard !self.isClosed else {
                NSLog("[DSH] deliver dropped (closed)")
                return
            }
            body()
        }
    }

    /// Deliver regardless of the closed flag. Only for the terminal finish
    /// signal, which by definition arrives as the connection closes.
    private func dispatch(_ body: @escaping () -> Void) {
        DispatchQueue.main.async { body() }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}

// MARK: - Bot conversation event stream (WebSocket, legacy `/mobile/v1/events`)

/// One WebSocket connection to `/mobile/v1/events`.
/// Sends the auth frame on open, then forwards decoded events on the main queue.
///
/// The DSH-as-harness path (sessions, messages, live transcript) does NOT use
/// this: harness Sessions stream over SSE (`DSHRemoteStream`). This stays for the
/// bot-conversation transport the bridge still exposes.
final class DSHRemoteEventStream: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let token: String
    private let conversationId: String
    private let after: Int?
    private let onEvent: (DSHRemoteEvent) -> Void
    private let onStatus: (String) -> Void
    private let onError: (Error) -> Void
    private var closed = false

    init(url: URL, token: String, conversationId: String, after: Int?,
         onEvent: @escaping (DSHRemoteEvent) -> Void,
         onStatus: @escaping (String) -> Void,
         onError: @escaping (Error) -> Void) {
        self.task = DSHRemoteClient.defaultSession.webSocketTask(with: url)
        self.token = token
        self.conversationId = conversationId
        self.after = after
        self.onEvent = onEvent
        self.onStatus = onStatus
        self.onError = onError
    }

    func start() {
        task.resume()
        onStatus("connecting")
        var payload: [String: Any] = ["type": "auth", "token": token, "conversationId": conversationId]
        if let after { payload["after"] = after }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        task.send(.data(data)) { [weak self] error in
            if let error { self?.fail(error) }
        }
        receive()
    }

    func close() {
        closed = true
        task.cancel(with: .goingAway, reason: nil)
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error):
                self.fail(error)
            case .success(let message):
                let data: Data?
                switch message {
                case .data(let value): data = value
                case .string(let text): data = text.data(using: .utf8)
                @unknown default: data = nil
                }
                if let data, let event = try? JSONDecoder().decode(DSHRemoteEvent.self, from: data) {
                    DispatchQueue.main.async {
                        if event.type == "ready" { self.onStatus("connected") }
                        if event.type == "error" { self.onStatus("error") }
                        self.onEvent(event)
                    }
                }
                self.receive()
            }
        }
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
        DispatchQueue.main.async { self.onError(error); self.onStatus("closed") }
    }
}
