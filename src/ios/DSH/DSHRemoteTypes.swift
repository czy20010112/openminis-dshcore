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
                  title: String?, contextPressure: DSHContextPressure?,
                  tokenUsage: DSHRemoteSessionSummary.TokenUsage?)
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
    /// Lossily decoded: one malformed record is dropped and counted, the rest of
    /// the page still renders. A strict `[DSHHistoryRecord]` meant that a single
    /// unexpected field shape (measured: `event.data.reason` arriving as a bare
    /// string) turned a 506 KB snapshot into an empty Session.
    var records: DSHLossyArray<DSHHistoryRecord>?
    var running: Bool?
    var blank: Bool?
    var title: String?
    var contextPressure: DSHContextPressure?
    /// Live token usage on the snapshot frame (newer hosts). Feeds the context
    /// panel without a second request.
    var tokenUsage: DSHRemoteSessionSummary.TokenUsage?
    /// `GET /dsh/events?after=<cursor>` answered by CONTINUING the log: `records`
    /// only holds what came after the cursor, so they must be APPENDED.
    var resumed: Bool?
    /// The host could not continue from that cursor and re-sent a whole page:
    /// every cached record must be thrown away.
    var reset: Bool?
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

    // Declared explicitly: this type is Decodable-only, so the compiler does not
    // synthesise `CodingKeys` for it.
    private enum CodingKeys: String, CodingKey {
        case type, cursor, hasMore, records, running, blank, title, contextPressure
        case tokenUsage, resumed, reset
        case seq, event, turn, step, attempt, index, channel, text, code, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Every field is read leniently ON PURPOSE: a frame that carries one
        // unexpected shape (a string where an object was expected, a number where
        // a string was) must still deliver the rest of itself. Rejecting the whole
        // envelope is what turned a 506 KB snapshot into an empty Session.
        type = container.lenientString(.type) ?? "unknown"
        cursor = container.lenientInt(.cursor)
        hasMore = container.lenient(DSHHistoryPageHasMore.self, .hasMore)?.value
        records = container.lenientLossyArray(DSHHistoryRecord.self, .records)
        running = container.lenient(DSHHistoryPageHasMore.self, .running)?.value
        blank = container.lenient(DSHHistoryPageHasMore.self, .blank)?.value
        title = container.lenientText(.title)
        contextPressure = container.lenient(DSHContextPressure.self, .contextPressure)
        tokenUsage = container.lenient(DSHRemoteSessionSummary.TokenUsage.self, .tokenUsage)
        // nil when the host is old — the reader decides what "unknown" means, and
        // for `reset` that means "assume a full page".
        resumed = container.lenientBool(.resumed)
        reset = container.lenientBool(.reset)
        seq = container.lenientInt(.seq)
        event = container.lenient(DSHHistoryEvent.self, .event)
        turn = container.lenientInt(.turn)
        step = container.lenientInt(.step)
        attempt = container.lenientString(.attempt)
        index = container.lenientInt(.index)
        channel = container.lenientString(.channel)
        text = container.lenientText(.text)
        code = container.lenientString(.code)
        message = container.lenientText(.message)
    }
}


// MARK: - Harness team (protocol §1, `verify/DSH-REMOTE-TEAM-CONTRACT.md`)

/// One teammate the HOST is running. Unlike a sub-agent this is a durable agent
/// with its own Session: it can be messaged repeatedly and interrupted.
struct DSHRemoteTeamMember: Decodable, Sendable, Equatable {
    var id: String?
    var name: String
    var role: String?
    /// `running` / `inactive` / `provisioning` / `failed` — kept as a string so a
    /// new host state is displayable instead of failing the decode.
    var status: String?
    /// The teammate's own harness Session: `GET /dsh/events?sessionId=` on this id
    /// shows its live output.
    var sessionId: String?
    var lastMessageAt: Double?

    var displayStatus: String { status ?? "unknown" }
}

/// `GET /dsh/team/members`
struct DSHRemoteTeamRoster: Decodable, Sendable {
    struct Lead: Decodable, Sendable, Equatable {
        var sessionId: String?
        var title: String?
    }

    var lead: Lead?
    var members: [DSHRemoteTeamMember]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lead = container.lenient(Lead.self, .lead)
        // Lossy: one malformed member must not blank the whole roster.
        members = container.lenientLossyArray(DSHRemoteTeamMember.self, .members)?.values ?? []
    }

    private enum CodingKeys: String, CodingKey { case lead, members }
}

/// `POST /dsh/team/spawn`
struct DSHRemoteTeamSpawn: Decodable, Sendable {
    var member: DSHRemoteTeamMember
    var opened: Bool?
}

/// `POST /dsh/team/message`
struct DSHRemoteTeamDelivery: Decodable, Sendable {
    var delivered: Bool?
    /// The member's status right after the delivery, when the host reports one.
    var status: String?
}

/// `POST /dsh/team/interrupt`
struct DSHRemoteTeamInterrupt: Decodable, Sendable {
    var interrupted: Bool?
}

/// The last thing a teammate SAID — read out of its own Session transcript.
///
/// The team endpoints only carry the roster and delivery receipts; the answer a
/// teammate produced lives in its `assistant/message` events. `remote_team_output`
/// is what turns those into something the phone agent can read.
struct DSHRemoteTeamAnswer: Sendable, Equatable {
    /// Concatenated `text` blocks of the newest assistant message that had any.
    var text: String
    var turn: Int?
    var records: Int
    /// Identity of that message: `seq|chars`. A change means "it said something new".
    var fingerprint: String

    var isEmpty: Bool { text.isEmpty }

    static let none = DSHRemoteTeamAnswer(text: "", turn: nil, records: 0, fingerprint: "-")
}

// MARK: - Session summary (GET /dsh/summary)

/// Everything the context panel needs, in ONE GET.
///
/// The snapshot frame already carries `contextPressure` + `tokenUsage` (live), so
/// this endpoint is for the parts a frame cannot show: the goal, the todo list and
/// the last compaction. Every block can be `null` and any block can fail to decode
/// without taking the others down — a panel is not allowed to blank the page.
struct DSHRemoteSessionSummary: Decodable, Sendable, Equatable {
    var sessionId: String?
    var asOfSeq: Double?
    var context: Context?
    var goal: Goal?
    var todos: [Todo]?
    var tokenUsage: TokenUsage?

    struct LastCompaction: Decodable, Sendable, Equatable {
        var at: Double?
        var before: Double?
        /// HOST FACT: always `null` — the projection does not record the size after
        /// the compaction. Show `before` and the time; never print "after N".
        var after: Double?
        var compactionId: String?
        var error: String?
    }

    struct Context: Decodable, Sendable, Equatable {
        /// Tokens in the window, and where that number came from.
        var used: Double?
        var window: Double?
        var remaining: Double?
        var ratio: Double?
        var projectedTokens: Double?
        /// `pressure` (measured) / `projected` (estimated). Absent on older hosts.
        var source: String?
        var lastCompaction: LastCompaction?

        var usageSource: DSHRemoteContextUsageSource {
            if let source, let parsed = DSHRemoteContextUsageSource(rawValue: source) { return parsed }
            return .projected
        }

        /// The same shape the live snapshot uses, so the panel renders both paths
        /// identically.
        var asPressure: DSHContextPressure {
            DSHContextPressure(
                pressureTokens: usageSource == .pressure ? used : nil,
                projectedTokens: projectedTokens ?? (usageSource == .projected ? used : nil),
                surfaceTokens: nil,
                sampledSurfaceTokens: nil,
                contextWindow: window,
                source: usageSource.rawValue
            )
        }
    }

    struct Goal: Decodable, Sendable, Equatable {
        var id: String?
        var revision: Double?
        var title: String?
        /// `active` / `done` / `blocked`
        var status: String?
        var phase: String?
        var rounds: Rounds?
        var blockedReason: String?
        /// HOST FACT: always `[]`. The harness' goal projection has no per-step
        /// list (only `rounds`), so a UI must NOT render "0 steps" from this.
        var steps: [String]?
        var updatedAt: Double?

        struct Rounds: Decodable, Sendable, Equatable {
            var started: Double?
            var max: Double?
        }
    }

    struct Todo: Decodable, Sendable, Equatable {
        var content: String?
        var status: String?
    }

    struct TokenUsage: Decodable, Sendable, Equatable {
        var uncachedInputTokens: Double?
        var outputTokens: Double?
        var cacheReadTokens: Double?
        var cacheWriteTokens: Double?
        var totalTokens: Double?
    }

    /// Explicit because `init(from:)` removes the synthesised member-wise one.
    init(sessionId: String?, asOfSeq: Double?, context: Context?, goal: Goal?,
         todos: [Todo]?, tokenUsage: TokenUsage?) {
        self.sessionId = sessionId
        self.asOfSeq = asOfSeq
        self.context = context
        self.goal = goal
        self.todos = todos
        self.tokenUsage = tokenUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = container.lenientString(.sessionId)
        asOfSeq = container.lenientDouble(.asOfSeq)
        context = container.lenient(Context.self, .context)
        goal = container.lenient(Goal.self, .goal)
        // Lossy: one malformed todo must not hide the rest of the list.
        todos = container.lenientLossyArray(Todo.self, .todos)?.values
        tokenUsage = container.lenient(TokenUsage.self, .tokenUsage)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, asOfSeq, context, goal, todos, tokenUsage
    }

    static func empty(sessionId: String) -> DSHRemoteSessionSummary {
        DSHRemoteSessionSummary(
            sessionId: sessionId, asOfSeq: nil, context: nil, goal: nil, todos: nil, tokenUsage: nil
        )
    }

    /// A summary carrying only what a live snapshot knows, for merging into the
    /// panel's published slot without clearing its goal/todos.
    func withLiveContext(_ pressure: DSHContextPressure?, usage: TokenUsage?) -> DSHRemoteSessionSummary {
        var copy = self
        if let pressure { copy.context = Context(from: pressure) }
        if let usage { copy.tokenUsage = usage }
        return copy
    }
}

extension DSHRemoteSessionSummary.Context {
    /// Live snapshot → panel shape. `usedTokens` keeps the host's precedence, and
    /// the source travels with it so "≈" stays honest.
    init(from pressure: DSHContextPressure) {
        self.used = pressure.usedTokens
        self.window = pressure.contextWindow
        self.remaining = {
            guard let used = pressure.usedTokens, let window = pressure.contextWindow else { return nil }
            return max(window - used, 0)
        }()
        self.ratio = pressure.fraction
        self.projectedTokens = pressure.projectedTokens
        self.source = pressure.usedSource.rawValue
        self.lastCompaction = nil
    }
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
