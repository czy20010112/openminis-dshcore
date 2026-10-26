import Foundation

// MARK: - Host / session

/// A paired DSH host. Persisted in UserDefaults (non-secret parts only).
struct DSHRemoteHost: Codable, Equatable, Sendable {
    var url: String
    var serverId: String
    var name: String?
    var tlsPin: String?
}

/// The device session issued by `POST /mobile/v1/pairings/complete`.
///
/// The host returns exactly five fields — `accessToken`, `refreshToken`,
/// `deviceId`, `serverId`, `expiresAt` (see `issueSession()` in the bridge's
/// `auth.js`). `baseURL`/`hostName` are filled in client-side afterwards, so they
/// must decode as optional; a plain synthesized `Codable` would demand them and
/// fail with `keyNotFound` ("The data couldn't be read because it is missing.")
/// the moment the user approves the pairing.
struct DSHRemoteSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var deviceId: String
    var serverId: String
    var expiresAt: Double
    var baseURL: String = ""
    var hostName: String?

    init(accessToken: String, refreshToken: String, deviceId: String, serverId: String,
         expiresAt: Double, baseURL: String = "", hostName: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.deviceId = deviceId
        self.serverId = serverId
        self.expiresAt = expiresAt
        self.baseURL = baseURL
        self.hostName = hostName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        serverId = try container.decode(String.self, forKey: .serverId)
        expiresAt = try container.decode(Double.self, forKey: .expiresAt)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName)
    }
}

// MARK: - Wire types (mirror packages/mobile-sdk)

struct DSHRemoteInfo: Codable, Sendable {
    var protocolVersion: Int?
    var serverId: String
    var name: String?
}

struct DSHRemoteConversation: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String?
    var kind: String?
    var sessionId: String?
    var updatedAt: Double?
    /// The bridge's conversation rows carry `createdAt` only (rooms/bots have no
    /// `updatedAt`), so sorting has to fall back to it or the list comes back flat.
    var createdAt: Double?
    var preview: String?
    var pinned: Bool?
    var hidden: Bool?
    var waiting: Bool?
    var role: String?

    var displayName: String { (name?.isEmpty == false ? name! : "Conversation") }
    var isBot: Bool { kind != "agent" }
    /// Newest-first ordering key.
    var sortStamp: Double { updatedAt ?? createdAt ?? 0 }
}

struct DSHRemoteMessage: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var sessionId: String?
    var seq: Double?
    var role: String
    var text: String?
    var reasoning: String?
    var createdAt: Double?
    var pending: Bool?
    var attemptId: String?
    var streamIndex: Int?

    var createdAtDate: Date? {
        guard let createdAt, createdAt > 0 else { return nil }
        return Date(timeIntervalSince1970: createdAt / 1000)
    }
}

struct DSHRemotePage: Codable, Sendable {
    var messages: [DSHRemoteMessage]
    var cursor: String?
    var sessionId: String?
}

struct DSHRemoteEvent: Codable, Sendable {
    var type: String
    var sessionId: String?
    var conversationId: String?
    var attemptId: String?
    var replaceAttemptId: String?
    var text: String?
    var reasoning: String?
    var index: Int?
    var eventSeq: Int?
    var message: DSHRemoteMessage?
    var messages: [DSHRemoteMessage]?
    var clearAttempt: Bool?
}

struct DSHRemotePairingClaim: Codable, Sendable {
    var claimToken: String
    var requestId: String
    var status: String
}

struct DSHRemoteError: Error, LocalizedError, Sendable {
    var code: String
    var message: String
    var status: Int?

    var errorDescription: String? { message }
    var needsRepair: Bool {
        status == 401 || status == 403 || ["unauthorized", "invalid_session", "server_changed"].contains(code)
    }
    /// Worth retrying with backoff: a transport failure, a busy agent, or a
    /// freshly restarted host. A 4xx that is not auth-related (`SESSION_NOT_FOUND`)
    /// is NOT retryable — retrying it just spins.
    var isRetryable: Bool {
        if needsRepair { return true }
        guard let status else { return true }
        if status == 409 || status == 429 { return true }
        if status >= 500 { return true }
        return false
    }
}

// MARK: - Live stream (protocol §2.4)

/// Which transcript block a delta belongs to.
///
/// The host only forwards two of the harness' chunk types
/// (`text-delta` / `reasoning-delta`); tool calls arrive as durable events.
enum DSHStreamChannel: String, Codable, Sendable {
    case reasoning
    case text
}

/// One frame of `GET /mobile/v1/dsh/events`.
///
/// Heartbeat and terminal-error frames are consumed by `DSHRemoteStore` (it owns
/// the cursor and the reconnect policy) and never reach this enum: the writer
/// only needs these four.
enum DSHRemoteStreamFrame: Sendable {
    case snapshot(cursor: Int, records: [DSHHistoryRecord], hasMore: Bool, running: Bool,
                  title: String?, contextPressure: DSHContextPressure?)
    case event(seq: Int, event: DSHHistoryEvent)
    case delta(turn: Int, step: Int, attempt: String, index: Int, channel: DSHStreamChannel, text: String)
    case deltaEnd(turn: Int, step: Int, attempt: String)
}

/// Wire shape of a stream frame (`data: {…}` line). One struct for every frame
/// type — the union is small and a single decoder keeps the SSE parser tiny.
struct DSHRemoteStreamEnvelope: Decodable, Sendable {
    var type: String
    // snapshot
    var cursor: Int?
    var hasMore: Bool?
    var records: [DSHHistoryRecord]?
    var running: Bool?
    var blank: Bool?
    var title: String?
    var contextPressure: DSHContextPressure?
    // event
    var seq: Int?
    var event: DSHHistoryEvent?
    // delta / delta-end
    var turn: Int?
    var step: Int?
    var attempt: String?
    var index: Int?
    var channel: String?
    var text: String?
    // error
    var code: String?
    var message: String?
}


// MARK: - Merge (same rules as mergeMessages/applyConversationEvent in the SDK)

enum DSHRemoteMerge {
    static func merge(_ existing: [DSHRemoteMessage], _ incoming: [DSHRemoteMessage]) -> [DSHRemoteMessage] {
        var byID: [String: DSHRemoteMessage] = [:]
        for message in existing + incoming {
            guard let previous = byID[message.id] else {
                byID[message.id] = message
                continue
            }
            let previousVersion = previous.seq ?? 0
            let incomingVersion = message.seq ?? 0
            let stale = incomingVersion < previousVersion
            var value = stale ? previous : message
            // Keep the first sequence number when both sides carry one.
            if let a = previous.seq, let b = message.seq {
                value.seq = min(a, b)
                if let earlier = (a <= b ? previous : message).createdAt { value.createdAt = earlier }
            }
            byID[message.id] = value
        }
        return byID.values.sorted { lhs, rhs in
            let lp = lhs.pending ?? false
            let rp = rhs.pending ?? false
            if lp != rp { return !lp }
            if lhs.sessionId == rhs.sessionId, let a = lhs.seq, let b = rhs.seq { return a < b }
            let la = lhs.createdAt ?? 0
            let ra = rhs.createdAt ?? 0
            return la < ra
        }
    }

    static func apply(_ messages: [DSHRemoteMessage], event: DSHRemoteEvent) -> [DSHRemoteMessage] {
        switch event.type {
        case "reset":
            let kept = messages.filter { !($0.pending ?? false) }
            return merge(kept, event.messages ?? [])
        case "delta":
            guard let attempt = event.attemptId, let text = event.text else { return messages }
            let id = "stream:\(event.sessionId ?? ""):\(attempt)"
            let previous = messages.first { $0.id == id }
            if let index = event.index, let previousIndex = previous?.streamIndex, index < previousIndex { return messages }
            let streamed = DSHRemoteMessage(
                id: id,
                sessionId: event.sessionId,
                seq: nil,
                role: "assistant",
                text: text,
                reasoning: event.reasoning ?? previous?.reasoning,
                createdAt: previous?.createdAt ?? Date().timeIntervalSince1970 * 1000,
                pending: true,
                attemptId: attempt,
                streamIndex: event.index
            )
            return merge(messages, [streamed])
        case "message":
            guard let message = event.message else { return messages }
            let remaining = messages.filter { message in
                guard message.pending ?? false else { return true }
                guard let replace = event.replaceAttemptId else { return true }
                return message.attemptId != replace
            }
            return merge(remaining, [message])
        case "status":
            guard event.clearAttempt == true, let attempt = event.attemptId else { return messages }
            return messages.filter { !(($0.pending ?? false) && $0.attemptId == attempt) }
        default:
            return messages
        }
    }
}
