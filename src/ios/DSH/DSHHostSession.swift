import Foundation

// MARK: - Harness session list (GET /mobile/v1/dsh/sessions)

/// One harness Session, i.e. one row of the web sidebar — not a ds-bot Bot.
struct DSHHostSession: Codable, Identifiable, Equatable, Sendable {
    var sessionId: String
    var updatedAt: Double
    var cwd: String?
    /// Display name of the owning workspace (harness workspace.json title).
    var workspaceTitle: String?
    var workspaceOrder: Int?
    var lastPromptAt: Double?
    var running: Bool?
    var blank: Bool?
    var origin: String?
    var title: String?
    var asOfSeq: Double?
    var contextPressure: DSHContextPressure?

    var id: String { sessionId }

    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return "Untitled"
    }

    /// Grouping key: the harness groups Sessions by their working directory.
    var workspace: String { cwd?.isEmpty == false ? cwd! : "" }

    var workspaceName: String {
        let path = workspace
        guard !path.isEmpty else { return "Other" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Sub-agents are hidden from the sidebar, same as the web UI.
    var isSubagent: Bool { origin == "subagent" }
}

struct DSHContextPressure: Codable, Equatable, Sendable {
    /// The harness reports pressureTokens / projectedTokens; the older
    /// surfaceTokens pair is kept as a fallback for other builds.
    var pressureTokens: Double?
    var projectedTokens: Double?
    var surfaceTokens: Double?
    var sampledSurfaceTokens: Double?
    var contextWindow: Double?

    /// Tokens currently occupying the window.
    var usedTokens: Double? {
        projectedTokens ?? surfaceTokens ?? sampledSurfaceTokens ?? pressureTokens
    }

    /// 0…1 fill of the context window, for the ring indicator.
    var fraction: Double? {
        guard let used = usedTokens, let window = contextWindow, window > 0 else { return nil }
        return min(max(used / window, 0), 1)
    }
}

// MARK: - Session history (GET /mobile/v1/dsh/messages + GET /mobile/v1/dsh/events)

struct DSHHistoryRecord: Codable, Sendable {
    var seq: Double?
    var event: DSHHistoryEvent?

    init(seq: Double?, event: DSHHistoryEvent?) {
        self.seq = seq
        self.event = event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = container.lenientDouble(.seq)
        // An ABSENT `event` is legitimate (marker records); an `event` that is
        // present but undecodable is a schema gap, so it throws and the lossy
        // array counts it instead of silently keeping an empty row.
        if container.contains(.event) {
            event = try container.decodeIfPresent(DSHHistoryEvent.self, forKey: .event)
        } else {
            event = nil
        }
    }
}

struct DSHHistoryEvent: Codable, Sendable {
    var type: String
    var seq: Double?
    var time: Double?
    /// `"append"` / `"replace"` — the harness surface operation. A
    /// `compact-checkpoint` is always a REPLACEMENT: it stands in for (and
    /// shadows) everything before it, which is what the dimming means.
    var surfaceOp: String?
    var data: DSHHistoryData?

    init(type: String, seq: Double?, time: Double?, surfaceOp: String? = nil, data: DSHHistoryData?) {
        self.type = type
        self.seq = seq
        self.time = time
        self.surfaceOp = surfaceOp
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `type` is the one field every event has; default it rather than losing
        // the whole record over a missing key.
        type = container.lenientString(.type) ?? "unknown"
        seq = container.lenientDouble(.seq)
        time = container.lenientDouble(.time)
        surfaceOp = container.lenientString(.surfaceOp)
        data = container.lenient(DSHHistoryData.self, .data)
    }
}

struct DSHHistoryData: Codable, Sendable {
    var role: String?
    var id: String?
    var turn: Int?
    var step: Int?
    var content: [DSHHistoryContent]?
    /// Present on `user/message` (`data.source`), where the CLASSIFICATION lives:
    /// `kind == "user"` is a real user message, everything else is an injection.
    var source: DSHHistorySource?
    var message: DSHHistoryMessage?
    var usage: DSHHistoryUsage?
    var callId: String?
    var name: String?
    var arguments: String?
    var toolCallId: String?
    var reason: DSHHistoryTurnReason?
    /// `tool/result` failure (object) or `compaction/end` failure (JSON string).
    var error: DSHHistoryFailure?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = container.lenientString(.role)
        id = container.lenientString(.id)
        turn = container.lenientInt(.turn)
        step = container.lenientInt(.step)
        content = container.lenientArray(DSHHistoryContent.self, .content)
        source = container.lenient(DSHHistorySource.self, .source)
        message = container.lenient(DSHHistoryMessage.self, .message)
        usage = container.lenient(DSHHistoryUsage.self, .usage)
        callId = container.lenientString(.callId)
        name = container.lenientString(.name)
        // A tool's arguments are a JSON *string* in every log seen so far, but an
        // object here must not cost the record: it re-serialises to valid JSON,
        // which is exactly what the tool parser expects.
        arguments = container.lenientText(.arguments)
        toolCallId = container.lenientString(.toolCallId)
        reason = container.lenient(DSHHistoryTurnReason.self, .reason)
        error = container.lenient(DSHHistoryFailure.self, .error)
    }
}

/// `turn/end` reason. `.cancelled` matters: the row must not be shown as
/// running after the user hit Stop.
///
/// Two shapes exist: `{"kind":"cancelled"}` and — measured in
/// `session-e902df26` — a bare `"cancelled"`. The bare form used to fail the
/// decode of the whole snapshot (506 KB → empty page), so both are accepted.
struct DSHHistoryTurnReason: Codable, Sendable {
    var kind: String?

    init(kind: String? = nil) { self.kind = kind }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let plain = try? single.decode(String.self) {
            kind = plain
            return
        }
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        kind = container?.lenientString(.kind)
    }
}

struct DSHHistoryMessage: Codable, Sendable {
    var role: String?
    var id: String?
    var content: [DSHHistoryContent]?
    var source: DSHHistorySource?
    var toolCallId: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = container.lenientString(.role)
        id = container.lenientString(.id)
        content = container.lenientArray(DSHHistoryContent.self, .content)
        source = container.lenient(DSHHistorySource.self, .source)
        toolCallId = container.lenientString(.toolCallId)
    }
}

/// One content block of an assistant message — or of a tool result, where the
/// shape nests (`tool-result.content[].text`).
struct DSHHistoryContent: Codable, Sendable {
    var type: String
    var text: String?
    var id: String?
    var name: String?
    var arguments: String?
    var toolCallId: String?
    /// Only on `type == "tool-result"`: the actual output blocks. A harness
    /// `tool/result` therefore carries its text one level down, and reading only
    /// the outer array came back empty for every single tool result.
    var content: [DSHHistoryContent]?

    init(type: String, text: String?, id: String? = nil, name: String? = nil,
         arguments: String? = nil, toolCallId: String? = nil, content: [DSHHistoryContent]? = nil) {
        self.type = type
        self.text = text
        self.id = id
        self.name = name
        self.arguments = arguments
        self.toolCallId = toolCallId
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = container.lenientString(.type) ?? "unknown"
        text = container.lenientText(.text)
        id = container.lenientString(.id)
        name = container.lenientString(.name)
        arguments = container.lenientText(.arguments)
        toolCallId = container.lenientString(.toolCallId)
        // Nested output blocks are decoded lossily: one unreadable block must not
        // take the tool call (and with it the whole record) down.
        content = container.lenientArray(DSHHistoryContent.self, .content)
    }
}

struct DSHHistorySource: Codable, Sendable {
    var kind: String?
    /// `"notice"` marks a status line rather than a conversation message
    /// (model switch, background job, subagent landing…). Only some kinds are
    /// worth showing — see `DSHTranscript.classify`.
    var form: String?
    /// One-line description of a notice; preferred over the body when present.
    var summary: String?
    var callId: String?
    var rpcId: String?
    var compactionId: String?
    var sourceCommandId: String?

    init(from decoder: Decoder) throws {
        // Two shapes, both live in the same log (survey: object ×2845 /
        // string ×302). `approval/policy` and `sandbox/mode` write a bare
        // `"delegation"`; `user/message` and friends write the object. A strict
        // object-only decode silently cost 302 records per full sweep.
        if let single = try? decoder.singleValueContainer(),
           let plain = try? single.decode(String.self) {
            kind = plain
            callId = nil
            rpcId = nil
            compactionId = nil
            sourceCommandId = nil
            form = nil
            summary = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.lenientString(.kind)
        form = container.lenientString(.form)
        summary = container.lenientText(.summary)
        callId = container.lenientString(.callId)
        rpcId = container.lenientString(.rpcId)
        compactionId = container.lenientString(.compactionId)
        sourceCommandId = container.lenientString(.sourceCommandId)
    }
}

/// An `error` field: an object on `tool/result` (×369), a whole JSON string on
/// `compaction/end` (×263, e.g. `400: {"message":"Invalid option: …"}`).
///
/// Not rendered on its own, but it is the ONLY place a failed tool explains
/// itself, so it must survive decoding instead of being dropped.
struct DSHHistoryFailure: Codable, Sendable {
    /// The one-line (or whole) diagnostic, whatever shape it arrived in.
    var text: String?

    init(text: String?) { self.text = text }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let plain = try? single.decode(String.self) {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            text = trimmed.isEmpty ? nil : trimmed
            return
        }
        guard let wrapper = (try? decoder.singleValueContainer()) else { text = nil; return }
        guard let raw = try? wrapper.decode(DSHJSONValue.self) else { text = nil; return }
        var found = raw.summaryText
        if case .object(let dictionary) = raw {
            for key in ["message", "detail", "error", "code", "reason", "kind"] {
                if let value = dictionary[key], case .string(let inner) = value, !inner.isEmpty {
                    found = inner
                    break
                }
            }
        }
        text = found.isEmpty ? nil : found
    }
}

struct DSHHistoryUsage: Codable, Sendable {
    var inputTokens: Double?
    var outputTokens: Double?
    var totalTokens: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = container.lenientDouble(.inputTokens)
        outputTokens = container.lenientDouble(.outputTokens)
        totalTokens = container.lenientDouble(.totalTokens)
    }
}

struct DSHMessagesPage: Codable, Sendable {
    var sessionId: String?
    /// Real log cursor from the follow() snapshot frame (NOT projections.asOfSeq,
    /// which is the lowest watermark and truncates history when used for paging).
    var cursor: Double?
    var asOfSeq: Double?
    var hasMore: Bool?
    var records: [DSHHistoryRecord]?
    /// How many records the page carried but could not be decoded (`records` is
    /// already the survivors). Logged, never fatal.
    var droppedRecords: Int = 0

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = container.lenientString(.sessionId)
        cursor = container.lenientDouble(.cursor)
        asOfSeq = container.lenientDouble(.asOfSeq)
        hasMore = container.lenient(DSHHistoryPageHasMore.self, .hasMore)?.value
        let lossy = container.lenient(DSHLossyArray<DSHHistoryRecord>.self, .records)
        records = lossy?.values
        droppedRecords = lossy?.failures.count ?? 0
    }
}

/// `hasMore` is a Bool in the follow frame and `0`/`1` in some pages.
struct DSHHistoryPageHasMore: Decodable {
    var value: Bool
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) { value = flag; return }
        if let number = try? container.decode(Double.self) { value = number != 0; return }
        value = false
    }
}

// MARK: - Lenient field readers

extension KeyedDecodingContainer {
    /// Absent/garbled → nil, never a throw.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    func lenientString(_ key: Key) -> String? {
        guard let wrapper = (try? decodeIfPresent(DSHFlexibleString.self, forKey: key)) ?? nil else {
            return nil
        }
        return wrapper.value
    }

    func lenientText(_ key: Key) -> String? {
        guard let wrapper = (try? decodeIfPresent(DSHFlexibleText.self, forKey: key)) ?? nil else {
            return nil
        }
        return wrapper.text.isEmpty ? nil : wrapper.text
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let value = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return value }
        guard let text = lenientString(key) else { return nil }
        return Double(text)
    }

    func lenientInt(_ key: Key) -> Int? {
        if let value = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil { return value }
        guard let number = lenientDouble(key), number.isFinite else { return nil }
        return Int(number)
    }

    /// A lossy array flattened to its survivors. `nil` only when the key is
    /// absent or not an array at all.
    func lenientArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T]? {
        guard let lossy = (try? decodeIfPresent(DSHLossyArray<T>.self, forKey: key)) ?? nil else {
            return nil
        }
        return lossy.values
    }

    /// Same as `lenientArray`, but keeps the failure descriptions for logging.
    func lenientLossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> DSHLossyArray<T>? {
        (try? decodeIfPresent(DSHLossyArray<T>.self, forKey: key)) ?? nil
    }
}

// MARK: - Event classification (issue 1)

/// What one harness event contributes to the transcript.
enum DSHEventClass: Equatable {
    /// A real user message (`source.kind == "user"` / `"user-question-reply"`).
    case user(id: String, text: String)
    /// A status line: `source.form == "notice"` on a kind worth showing.
    case notice(text: String)
    /// A compaction checkpoint (`source.kind == "compact-checkpoint"`).
    case checkpoint(summary: String)
    /// Nothing — injected context, system prompt, lifecycle events.
    case drop
}

/// Rebuilds the Minis message model from harness session events.
///
/// The harness stores an append-only event log; the web UI's transcript is a
/// projection of it. Two facts drive every rule in here:
///
///  * a `user/message` is NOT necessarily a user message — the harness also
///    records context injections (agent instructions, runtime context, skill
///    catalogs, tool-job notices, subagent settlements…) through the same event
///    type, and `data.source.kind` is what tells them apart;
///  * one assistant TURN is several `assistant/message` events (one per step),
///    each with its own `content[]` in arrival order, so a turn folds into ONE
///    Minis message whose `.reasoning` / `.text` / tool parts keep that order.
enum DSHTranscript {

    // MARK: Classification

    /// Kind → rendered as a user bubble. Everything else is an injection.
    private static let userKinds: Set<String> = ["user", "user-question-reply"]

    /// Injected kinds that must never render, even when they carry
    /// `form == "notice"`.
    ///
    /// The harness writes `notice` for background-job and subagent lifecycle
    /// lines too, and those are BYSTANDER events: one pwsh job produces several
    /// of them, each quoting the whole command line. Rendering them would put a
    /// wall of shell commands between two messages. `model-selection` is the one
    /// notice the user needs to see ("the model changed under me"), and it is
    /// NOT in this list by design.
    private static let silentKinds: Set<String> = [
        "agent-instructions", "runtime-context", "skill-catalog", "skill-invocation",
        "plugin", "goal", "tool-jobs", "subagent-settled", "subagent-report",
        "agent-message", "agent-report", "bot", "team-message", "compact-candidate",
        "user-approval", "model-suggestion",
    ]

    /// Classify one event. Pure — this is the whole of issue 1.
    static func classify(_ event: DSHHistoryEvent) -> DSHEventClass {
        guard event.type == "user/message" else { return .drop }
        let data = event.data
        let source = data?.source ?? data?.message?.source
        let kind = source?.kind ?? ""
        let body = text(of: data?.content ?? data?.message?.content)

        // No `source` at all: older / partial logs. The only `user/message` a
        // human typed is the one the schema marks `role: "user"`, and every
        // injected kind has to identify itself (that is how the web UI labels
        // it), so an UNSOURCED row with that role is far more likely to be a
        // human message than an injection. Dropping it would blank the whole
        // transcript on such a log.
        if source == nil, data?.role == "user" {
            guard !body.isEmpty else { return .drop }
            return .user(id: data?.id ?? "user-\(Int(event.seq ?? 0))", text: body)
        }

        if userKinds.contains(kind) {
            // An empty body is a real possibility (an attachment-only steer);
            // there is nothing to show, and an empty bubble is worse than none.
            guard !body.isEmpty else { return .drop }
            return .user(id: data?.id ?? "user-\(Int(event.seq ?? 0))", text: body)
        }

        if kind == "compact-checkpoint" {
            // The checkpoint's own body IS the summary of what it replaced.
            return .checkpoint(summary: body)
        }

        if silentKinds.contains(kind) { return .drop }

        // Anything else that declares itself a notice is a status line. Keep the
        // one-line summary when the harness supplies one: the body of a notice
        // can be the injected prompt itself (see `plugin` notices), and that
        // must never reach the transcript.
        if source?.form == "notice" {
            let line = firstLine(source?.summary) ?? firstLine(body)
            guard let line, !line.isEmpty else { return .drop }
            return .notice(text: line)
        }

        return .drop
    }

    /// Icon for a notice row. `ChatMessageRole.systemInfo` renders as a hairline
    /// divider with an SF Symbol; these are the same two symbols the local DSH
    /// rows use, so a remote notice and a local one are indistinguishable.
    static func noticeIcon(for event: DSHHistoryEvent) -> String {
        let kind = (event.data?.source ?? event.data?.message?.source)?.kind ?? ""
        switch kind {
        case "model-selection": return "arrow.triangle.2.circlepath"
        default: return "info.circle"
        }
    }

    // MARK: Reload projection (snapshot / page load)

    /// Project a page of records into Minis messages.
    ///
    /// This is the RELOAD path, and it must produce the same rows and the same
    /// block order as the live streaming path — a turn that streamed as
    /// `thinking → text → tool → thinking → text` has to reload that way.
    static func rawMessages(sessionId: String, records: [DSHHistoryRecord]) -> [RawMessage] {
        var projection = DSHTranscriptProjection()
        projection.beginPage()
        for record in records.sorted(by: { ($0.seq ?? 0) < ($1.seq ?? 0) }) {
            guard let event = record.event else { continue }
            projection.apply(event)
        }
        return projection.rawMessages(sessionId: sessionId)
    }

    // MARK: Helpers

    /// Concatenate the text blocks of a content array, one level deep.
    ///
    /// A user message carries its text directly (`[{type:"text",text:…}]`); a
    /// tool result nests it (`[{type:"tool-result",content:[{type:"text",…}]}]`).
    /// Both shapes exist in the log, so both are handled here.
    static func text(of content: [DSHHistoryContent]?) -> String {
        guard let content else { return "" }
        var out = ""
        for item in content {
            switch item.type {
            case "text":
                if let text = item.text { out += text }
            case "tool-result":
                out += text(of: item.content)
            default:
                continue
            }
        }
        return out
    }

    /// Whether a tool result reports failure. The harness encodes errors as an
    /// `is_error`-shaped block on some providers and as leading error text on
    /// others; `tool/result` events carry no explicit flag here, so the bridge
    /// leaves it `success`.
    static func toolSucceeded(_ content: [DSHHistoryContent]?) -> Bool {
        guard let content else { return true }
        return !content.contains { $0.type == "error" }
    }

    private static func firstLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let collapsed, !collapsed.isEmpty else { return nil }
        return collapsed
    }

    static func date(from millis: Double?) -> Date {
        guard let millis, millis > 0 else { return Date() }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}

// MARK: - Projection

/// One transcript row of the projection.
///
/// Rows carry a stable `key` so the live writer can keep the SAME
/// `ChatMessage` object for a row across events — the list's diffable snapshot
/// and its height caches are identity based, so re-creating the object per event
/// would make every delta look like a brand-new message.
struct DSHTranscriptRow {
    /// Row key for the "this page starts mid-conversation" marker. One per page,
    /// so a plain constant is enough.
    static let pageStartKey = "page:start"

    enum Kind: Equatable {
        case user
        case notice
        case checkpoint
        case assistant(turn: Int)
        /// A tool result whose call never appeared in an assistant message
        /// (host-injected tools). Rendered as a plain info block.
        case orphanTool(callId: String)
    }

    var key: String
    var kind: Kind
    var time: Date
    /// Assistant rows: reasoning / text / toolUse / toolResult in arrival order.
    /// User rows: a single `.text`.
    var parts: [ContentPart]
    var usage: DSHHistoryUsage?
    /// Set by `compact-checkpoint` on the rows it shadows.
    var compacted = false
    /// [T-dsh-remote-brand] Who produced this row. `"DSH"` for a harness turn;
    /// nil on everything local, so the app's own identity resolution stands.
    var assistantName: String?
    /// SF Symbol for a `.notice` row — the same primitive `systemInfo` rows use
    /// (hairline divider + icon + one line), so a remote notice looks exactly
    /// like a local one.
    var noticeIcon: String?
}

/// Incremental, order-preserving projection of harness events into rows.
///
/// Both the reload path (`DSHTranscript.rawMessages`) and the live streaming
/// writer drive THIS type, which is what makes "reloaded block sequence ==
/// streamed block sequence" true by construction rather than by coincidence.
struct DSHTranscriptProjection {

    /// One step of one assistant turn — the unit the durable/live merge works on.
    ///
    /// A durable `assistant/message` REPLACES the step's blocks wholesale
    /// (Lead's overlap rule): the live deltas ran ahead of it and only carried
    /// text/reasoning, while the durable event carries the authoritative
    /// `content[]` (tool calls included) and the usage. Rewriting — never
    /// appending — is what keeps the streamed transcript and the reloaded one
    /// identical.
    private struct StepSegment {
        var step: Int
        var parts: [ContentPart]
        /// Attempt id when this segment is still live (no durable message yet).
        var attempt: String?
        /// index → (channel, text) for live deltas, ordered by index on render.
        var live: [Int: (channel: DSHStreamChannel, text: String)] = [:]
        var liveOrder: [Int] = []
    }

    private struct TurnState {
        var segments: [StepSegment] = []
        var usage: DSHHistoryUsage?
        var createdAt: Date = Date()
        /// `false` once `turn/end` (or a failure) arrives.
        var running = false
    }

    private(set) var rows: [DSHTranscriptRow] = []
    /// turn number → index into `rows`.
    private var rowIndexByTurn: [Int: Int] = [:]
    /// row key → index into `rows`.
    private var rowIndexByKey: [String: Int] = [:]
    /// Set once the page's first record has been classified (see `notePageStart`).
    private var didNotePageStart = false
    /// `true` between `beginPage()` and the page's first record. Only PAGED input
    /// (a snapshot / a messages page) can start mid-conversation; a live stream's
    /// first delta is a resume, not a missing history.
    private var awaitingPageStart = false
    private var turns: [Int: TurnState] = [:]
    /// callId → settled result. Kept OUTSIDE the segments: a result can arrive
    /// before a later step of the same turn, and every rebuild of the row's parts
    /// (a durable message, another step's arrival) has to re-emit it right behind
    /// its call — otherwise the tool card would revert to "Executing…".
    private var toolResults: [String: ToolResult] = [:]
    /// callId → the turn that called it, so a result knows which row to rebuild.
    private var turnByCall: [String: Int] = [:]
    /// Turns that were live-rendered, so a durable message must REWRITE.
    private(set) var lastSeq: Int = 0

    // MARK: Events

    // MARK: - Page start

    /// A paged snapshot can begin in the MIDDLE of a turn.
    ///
    /// `maxMessages` on the wire counts RECORDS, not turns (measured: the last 30
    /// records of `session-e902df26` cover turn 14's steps 2…7 only), so the first
    /// record of a page is often an `assistant/message` / `tool/*` whose
    /// `turn/start` and user prompt sit outside the window. The transcript then
    /// legitimately starts with an assistant row that answers nothing visible.
    ///
    /// Rather than dropping those records (the old behaviour risked an empty page)
    /// or inventing content, say so ONCE with a notice row — the same
    /// `systemInfo` primitive the other status lines use. `false` when the page
    /// starts at a boundary, so an ordinary load shows nothing extra.
    /// Arm the mid-conversation check for the records that follow. Call this
    /// before replaying a page (snapshot / `/dsh/messages`), never for a live
    /// stream.
    mutating func beginPage() {
        awaitingPageStart = true
        didNotePageStart = false
    }

    private mutating func notePageStart(_ event: DSHHistoryEvent) {
        guard awaitingPageStart, !didNotePageStart else { return }
        // Idempotent by key, not just by flag: replaying the same snapshot twice
        // (or re-arming without a reset) must never stack two markers.
        guard rowIndexByKey[DSHTranscriptRow.pageStartKey] == nil else { return }
        didNotePageStart = true
        awaitingPageStart = false
        switch event.type {
        case "assistant/message", "tool/call", "tool/result":
            break
        default:
            // `turn/start` / `user/message` / session metadata: the page begins at
            // a real boundary, nothing is missing.
            return
        }
        guard let turn = event.data?.turn else { return }
        rows.append(DSHTranscriptRow(
            key: DSHTranscriptRow.pageStartKey,
            kind: .notice,
            time: DSHTranscript.date(from: event.time),
            parts: [.text(AppLocalized("Earlier messages are not in this window."))],
            usage: nil,
            compacted: false,
            assistantName: nil,
            noticeIcon: "info.circle"
        ))
        rowIndexByKey[DSHTranscriptRow.pageStartKey] = rows.count - 1
        NSLog("[DSH] page starts mid-turn t=\(turn) → marker row")
    }

    // MARK: - Events

    mutating func apply(_ event: DSHHistoryEvent) {
        if let seq = event.seq, seq > 0 { lastSeq = max(lastSeq, Int(seq)) }
        notePageStart(event)
        switch event.type {
        case "user/message":
            applyUserMessage(event)
        case "assistant/message":
            applyAssistantMessage(event)
        case "tool/result":
            applyToolResult(event)
        case "tool/call":
            applyToolCall(event)
        case "turn/start":
            // Running state only. The row is created by the first thing that
            // needs it: `turn/start` is logged BEFORE the user message that
            // triggered it (seq 6 vs seq 10 in a real log), so creating the row
            // here would put the assistant bubble above the user's message.
            if let turn = event.data?.turn { markRunning(turn) }
        case "turn/end":
            guard let turn = event.data?.turn else { return }
            seal(turn: turn)
        default:
            // `system/message` carries the whole system prompt (tens of
            // thousands of characters), `assistant/attempt` is often an empty
            // stream, `step/start` / `step/end` / `assistant/chunk` are
            // internal: nothing here belongs in a transcript.
            return
        }
    }

    /// A live token delta from an `assistant-stream` frame.
    ///
    /// Identity is `(turn, step, attempt, index)`; `channel` decides which kind
    /// of block the index becomes, so a text delta can never extend a thinking
    /// block (that is the "thinking block grew behind the answer" defect).
    mutating func applyDelta(turn: Int, step: Int, attempt: String, index: Int,
                             channel: DSHStreamChannel, text: String) {
        guard !text.isEmpty else { return }
        ensureTurn(turn, at: Date(), running: true)
        var state = turns[turn] ?? TurnState()
        guard let rowIdx = rowIndexByTurn[turn] else { return }

        // Locate the segment for (step). A retry inside the same step starts a
        // NEW attempt: the abandoned attempt's text is dropped, because the
        // durable message for the step will only ever contain the final
        // attempt's content and the two must end up identical.
        var segmentIdx: Int
        if let idx = state.segments.firstIndex(where: { $0.step == step && $0.attempt == attempt }) {
            segmentIdx = idx
        } else if let idx = state.segments.firstIndex(where: { $0.step == step && $0.attempt != nil }) {
            segmentIdx = idx
            state.segments[idx].attempt = attempt
            state.segments[idx].live = [:]
            state.segments[idx].liveOrder = []
            state.segments[idx].parts = []
        } else if let idx = state.segments.firstIndex(where: { $0.step == step }) {
            // Durable message already landed for this step and deltas are still
            // arriving: append into the matching part rather than starting a
            // second copy of the same step.
            segmentIdx = idx
            appendLateDelta(&state.segments[idx], index: index, channel: channel, text: text)
            turns[turn] = state
            rebuildParts(turn: turn, rowIdx: rowIdx, state: state)
            return
        } else {
            state.segments.append(StepSegment(step: step, parts: [], attempt: attempt, live: [:], liveOrder: []))
            segmentIdx = state.segments.count - 1
        }

        var live = state.segments[segmentIdx].live
        if live[index] == nil {
            state.segments[segmentIdx].liveOrder.append(index)
            live[index] = (channel, text)
        } else {
            live[index]?.text += text
        }
        state.segments[segmentIdx].live = live
        turns[turn] = state
        rebuildParts(turn: turn, rowIdx: rowIdx, state: state)
    }

    /// `delta-end`: the attempt finished and the writer must flush its tail
    /// (thinking throttle, text throttle) at this boundary.
    ///
    /// Deliberately keeps `attempt` on the segment: a retry that reuses the same
    /// step has to be recognised as "same step, different attempt" so its deltas
    /// REPLACE the abandoned attempt's text instead of concatenating with it.
    /// The only thing that clears an attempt is the durable message.
    mutating func endDelta(turn: Int, attempt: String) {
        _ = turn
        _ = attempt
    }

    /// Close the turn: nothing is running any more.
    mutating func seal(turn: Int) {
        guard var state = turns[turn] else { return }
        state.running = false
        turns[turn] = state
    }

    /// Drop everything. Used when a Session is (re)opened.
    mutating func reset() {
        rows = []
        rowIndexByTurn = [:]
        rowIndexByKey = [:]
        didNotePageStart = false
        awaitingPageStart = false
        turns = [:]
        toolResults = [:]
        turnByCall = [:]
        lastSeq = 0
    }

    // MARK: Row access

    func index(ofRow key: String) -> Int? { rowIndexByKey[key] }

    func isRunning(_ turn: Int) -> Bool { turns[turn]?.running ?? false }

    var runningTurn: Int? {
        turns.filter { $0.value.running }.keys.max()
    }

    var anyRunning: Bool { turns.values.contains { $0.running } }
    // MARK: - Event application

    private mutating func applyUserMessage(_ event: DSHHistoryEvent) {
        switch DSHTranscript.classify(event) {
        case .drop:
            return
        case .user(let id, let text):
            let key = "user:\(id)"
            if let existing = rowIndexByKey[key] {
                rows[existing].parts = [.text(text)]
                return
            }
            append(DSHTranscriptRow(
                key: key, kind: .user, time: DSHTranscript.date(from: event.time),
                parts: [.text(text)]
            ))
        case .notice(let text):
            let key = "notice:\(Int(event.seq ?? 0))-\(text.hashValue)"
            guard rowIndexByKey[key] == nil else { return }
            var row = DSHTranscriptRow(
                key: key, kind: .notice, time: DSHTranscript.date(from: event.time),
                parts: [.text(text)]
            )
            row.noticeIcon = DSHTranscript.noticeIcon(for: event)
            append(row)
        case .checkpoint(let summary):
            let key = "checkpoint:\(event.data?.source?.compactionId ?? String(Int(event.seq ?? 0)))"
            guard rowIndexByKey[key] == nil else { return }
            let row = DSHTranscriptRow(
                key: key, kind: .checkpoint, time: DSHTranscript.date(from: event.time),
                parts: [.text(summary)]
            )
            append(row)
            markPrecedingCompacted(before: rowIndexByKey[key] ?? rows.count - 1)
        }
    }

    private mutating func applyAssistantMessage(_ event: DSHHistoryEvent) {
        guard let data = event.data, let turn = data.turn, let message = data.message else { return }
        let step = data.step ?? 0
        ensureTurn(turn, at: DSHTranscript.date(from: event.time), running: true)
        guard let rowIdx = rowIndexByTurn[turn] else { return }

        var durable: [ContentPart] = []
        for item in message.content ?? [] {
            switch item.type {
            case "text":
                if let text = item.text, !text.isEmpty { durable.append(.text(text)) }
            case "reasoning":
                if let text = item.text, !text.isEmpty { durable.append(.reasoning(text)) }
            case "tool-call":
                guard let callId = item.id, let name = item.name else { continue }
                let normalized = DSHRemoteToolNameMap.normalize(
                    name: name, argumentsJSON: item.arguments ?? "{}"
                )
                durable.append(.toolUse(ToolUse(
                    toolUseId: callId,
                    name: normalized.name,
                    input: normalized.arguments,
                    description: nil,
                    thoughtSignature: nil
                )))
            default:
                continue
            }
        }

        var state = turns[turn] ?? TurnState()
        state.usage = data.usage
        state.running = true

        // REWRITE the step (never append): this event is authoritative for it,
        // and it arrives after the live deltas of the same step.
        if let idx = state.segments.firstIndex(where: { $0.step == step }) {
            state.segments[idx].parts = durable
            state.segments[idx].attempt = nil
            state.segments[idx].live = [:]
            state.segments[idx].liveOrder = []
        } else {
            // Cold load: insert the step in step order so a reload builds the
            // same sequence the stream built.
            var insertAt = state.segments.count
            for (i, segment) in state.segments.enumerated() where segment.step > step {
                insertAt = i
                break
            }
            state.segments.insert(StepSegment(step: step, parts: durable), at: insertAt)
        }
        turns[turn] = state
        rebuildParts(turn: turn, rowIdx: rowIdx, state: state)
    }

    private mutating func applyToolResult(_ event: DSHHistoryEvent) {
        guard let message = event.data?.message else { return }
        let callId = message.toolCallId ?? message.source?.callId ?? event.data?.toolCallId
        guard let callId, !callId.isEmpty else { return }
        // A failed tool explains itself in `data.error` (object on tool/result) and
        // often has an EMPTY content array — reading only `content` showed a
        // successful tool with no output.
        let failure = event.data?.error?.text
        var output = DSHTranscript.text(of: message.content)
        var success = DSHTranscript.toolSucceeded(message.content)
        if let failure, !failure.isEmpty {
            success = false
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output = failure }
        }
        let result = ToolResult(
            toolUseId: callId,
            output: output,
            success: success,
            mediaRef: nil,
            snapshot: nil,
            pageURL: nil,
            status: success ? "success" : "failed"
        )

        // The call already belongs to a turn: remember the result and rebuild
        // that row's parts, so the result is emitted immediately behind its call
        // (that pairing is what the renderer fills the tool card from).
        if let turn = turnByCall[callId], let rowIdx = rowIndexByTurn[turn] {
            toolResults[callId] = result
            let state = turns[turn] ?? TurnState()
            rebuildParts(turn: turn, rowIdx: rowIdx, state: state)
            return
        }

        // No matching call: a host-injected tool. Give it its own row so the
        // output is not lost, exactly like the local adapter's `.info` fallback.
        let key = "tool:\(callId)"
        guard rowIndexByKey[key] == nil else { return }
        append(DSHTranscriptRow(
            key: key, kind: .orphanTool(callId: callId),
            time: DSHTranscript.date(from: event.time),
            parts: [.toolResult(result)]
        ))
    }

    /// A `tool/call` event announces a call before its result exists.
    ///
    /// The call already appears inside the step's durable `assistant/message`
    /// `content[]`, so this arm is a FALLBACK: it exists for a step whose
    /// assistant message never landed (an aborted stream). It is idempotent —
    /// an existing block for the same call id is reused.
    private mutating func applyToolCall(_ event: DSHHistoryEvent) {
        guard let data = event.data, let callId = data.callId, let name = data.name else { return }
        guard turnByCall[callId] == nil else { return }
        guard let turn = data.turn else { return }
        ensureTurn(turn, at: DSHTranscript.date(from: event.time), running: true)
        guard let rowIdx = rowIndexByTurn[turn] else { return }
        var state = turns[turn] ?? TurnState()
        let step = data.step ?? 0
        let normalized = DSHRemoteToolNameMap.normalize(
            name: name, argumentsJSON: data.arguments ?? "{}"
        )
        let part: ContentPart = .toolUse(ToolUse(
            toolUseId: callId, name: normalized.name, input: normalized.arguments,
            description: nil, thoughtSignature: nil
        ))
        if let idx = state.segments.firstIndex(where: { $0.step == step }) {
            state.segments[idx].parts.append(part)
        } else {
            state.segments.append(StepSegment(step: step, parts: [part]))
        }
        turns[turn] = state
        rebuildParts(turn: turn, rowIdx: rowIdx, state: state)
    }

    // MARK: - Segment helpers

    private mutating func ensureTurn(_ turn: Int, at date: Date, running: Bool) {
        if turns[turn] == nil { turns[turn] = TurnState(createdAt: date, running: running) }
        guard rowIndexByTurn[turn] == nil else { return }
        var row = DSHTranscriptRow(
            key: "turn:\(turn)", kind: .assistant(turn: turn), time: date, parts: []
        )
        // [T-dsh-remote-brand] A remote assistant row names its own producer.
        row.assistantName = "DSH"
        let idx = append(row)
        rowIndexByTurn[turn] = idx
    }

    @discardableResult
    private mutating func append(_ row: DSHTranscriptRow) -> Int {
        rows.append(row)
        let idx = rows.count - 1
        rowIndexByKey[row.key] = idx
        return idx
    }

    /// Fold a live delta into a step that already has its durable message.
    ///
    /// Should not happen with a correct host (deltas precede the message), but a
    /// delta that lands afterwards must still be visible: it joins the same
    /// content index when the kinds match, otherwise it is appended behind.
    private mutating func appendLateDelta(_ segment: inout StepSegment,
                                          index: Int, channel: DSHStreamChannel, text: String) {
        let wanted: (ContentPart) -> Bool = { part in
            switch (channel, part) {
            case (.text, .text), (.reasoning, .reasoning): return true
            default: return false
            }
        }
        // Nth block of this channel, matching the delta's index when possible.
        var seen = 0
        for i in segment.parts.indices where wanted(segment.parts[i]) {
            if seen == index {
                switch segment.parts[i] {
                case .text(let old): segment.parts[i] = .text(old + text)
                case .reasoning(let old): segment.parts[i] = .reasoning(old + text)
                default: break
                }
                return
            }
            seen += 1
        }
        segment.parts.append(channel == .reasoning ? .reasoning(text) : .text(text))
    }

    /// Rebuild one row's `parts` from its ordered segments.
    ///
    /// A settled tool result is emitted immediately AFTER its call, because that
    /// is the pair the renderer fills a tool card from (`toChatMessage` matches a
    /// `.toolResult` to the block with the same `toolUseId`; an unresolvable
    /// result is appended to the message text instead). Results live in
    /// `toolResults` rather than in the segments, so a durable rewrite of a later
    /// step cannot lose them.
    private mutating func rebuildParts(turn: Int, rowIdx: Int, state: TurnState) {
        var parts: [ContentPart] = []
        for segment in state.segments.sorted(by: { $0.step < $1.step }) {
            if segment.liveOrder.isEmpty {
                appendWithResults(segment.parts, into: &parts, turn: turn)
            } else {
                for index in segment.liveOrder.sorted() {
                    guard let entry = segment.live[index] else { continue }
                    parts.append(entry.channel == .reasoning
                        ? .reasoning(entry.text)
                        : .text(entry.text))
                }
                appendWithResults(segment.parts, into: &parts, turn: turn)
            }
        }
        guard rowIdx < rows.count else { return }
        rows[rowIdx].parts = parts
        rows[rowIdx].usage = state.usage
    }

    private mutating func appendWithResults(_ source: [ContentPart], into parts: inout [ContentPart], turn: Int) {
        for part in source {
            if case .toolUse(let use) = part { turnByCall[use.toolUseId] = turn }
            parts.append(part)
            if case .toolUse(let use) = part, let result = toolResults[use.toolUseId] {
                parts.append(.toolResult(result))
            }
        }
    }

    private mutating func markRunning(_ turn: Int) {
        if turns[turn] == nil { turns[turn] = TurnState(running: true) }
        else { turns[turn]?.running = true }
    }

    private mutating func markPrecedingCompacted(before index: Int) {
        for i in 0..<min(index, rows.count) {
            if case .checkpoint = rows[i].kind { continue }
            rows[i].compacted = true
        }
    }

    // MARK: - Export

    /// Convert the projection to the Minis message model.
    ///
    /// One row → one `RawMessage`; parts are already in arrival order, so no
    /// reasoning is merged and `reasoningContent` stays nil on purpose (the
    /// per-part `.reasoning` order is what the renderer needs).
    func rawMessages(sessionId: String) -> [RawMessage] {
        var result: [RawMessage] = []
        var sortOrder = 0
        for row in rows {
            switch row.kind {
            case .notice, .checkpoint:
                // UI-only rows: they are not messages the model ever saw, and
                // they are built as `ChatMessage`s by the writer/reload adapter.
                continue
            case .user:
                result.append(RawMessage(
                    id: row.key, sessionId: sessionId, role: .user, parts: row.parts,
                    createdAt: row.time, sortOrder: sortOrder
                ))
            case .assistant, .orphanTool:
                var message = RawMessage(
                    id: row.key, sessionId: sessionId, role: .assistant, parts: row.parts,
                    createdAt: row.time, sortOrder: sortOrder
                )
                message.assistantName = row.assistantName
                result.append(message)
            }
            sortOrder += 1
        }
        return result
    }
}
