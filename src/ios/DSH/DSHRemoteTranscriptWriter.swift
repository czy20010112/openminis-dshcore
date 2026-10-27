import Foundation
import Combine

// MARK: - DSHRemoteTranscriptWriter
//
// The single place remote harness events become Minis blocks.
//
// WHY THIS TYPE EXISTS
// --------------------
// A remote Session has two event sources for the same turn: live
// `assistant-stream` deltas (text/reasoning only, arriving first) and the durable
// event log (`assistant/message` per step, `tool/call`, `tool/result`, arriving
// after). Rendering them independently produced two classes of defect: the turn
// showed up twice, or a reloaded turn did not look like the turn that streamed.
//
// So there is ONE projection (`DSHTranscriptProjection`) and ONE renderer (this
// type). The projection decides WHAT the transcript contains; the renderer turns
// that into `AssistantBlock`s while preserving block identity, because the list
// is identity-anchored and caches measured heights per block.
//
// THE THREE INVARIANTS (contract §3.2, copied from `DSHTurnDriverAdapter`)
// ----------------------------------------------------------------------
// 1. Block identity is `(turn, step, attempt, index)` — a channel change or an
//    index change starts a NEW block; a delta only ever extends the block it
//    belongs to.
// 2. Empty → filled must signal. A new block that appears with its first content
//    is committed immediately (`force`), because the list's height invalidator
//    runs off `blockContentFilledSignal` and gives up silently if the block is
//    not in its snapshot yet — that is the "text overlaps the row below" defect.
// 3. Three boundaries force the thinking tail out: text starting, a tool
//    starting, and the turn sealing. The thinking buffer is throttled, so a
//    segment that ends without a flush shows a truncated block.
//
// OPTIMISTIC USER ROWS
// --------------------
// Sending inserts the user bubble before the host has it. This type owns that
// row too, and reconciles it with the authoritative `user/message` echo, so the
// de-duplication exists exactly once (see `promoteOptimisticUser`).

@MainActor
final class DSHRemoteTranscriptWriter: ObservableObject {

    // MARK: Public state

    /// A turn is running on the host. The composer reads this to turn its send
    /// key into STOP. Published so a view can bind to it directly.
    @Published private(set) var isRunning = false
    /// The turn number currently running, when the host told us (`turn/start`).
    @Published private(set) var streamingTurn: Int?
    /// The Session this writer is projecting.
    private(set) var sessionId: String = ""
    /// Highest event seq applied. Exposed for diagnostics / reconnect parity.
    private(set) var cursor = 0

    // MARK: Private

    private let vm: AIChatViewModel
    private var projection = DSHTranscriptProjection()

    /// Rendered `ChatMessage` per row key. Reused across renders so the list's
    /// identity-anchored rows and their cached heights survive an update.
    private var rowChat: [String: ChatMessage] = [:]
    /// Per-row incremental render state (block pointers + throttles).
    private var rowState: [String: RenderedRow] = [:]
    /// The order `vm.messages` currently has. An assignment only happens when
    /// this changes — a delta must not re-publish `$messages`.
    private var renderedOrder: [String] = []

    /// Optimistic user rows that the host has not echoed yet, oldest first.
    private var pendingOptimistic: [OptimisticUser] = []

    /// `turn|step|attempt|index` keys whose block has already been announced by
    /// `writer delta-open`. Trace only — it drives no behaviour.
    private var deltaOpened: Set<String> = []
    /// `turn|step` → the attempt id its last delta belonged to. Trace only: the
    /// durable `assistant/message` has no attempt field, so this is the only real
    /// source for the `a=` in `writer apply`.
    private var attemptByStep: [String: String] = [:]
    /// The newest `seq` this writer has applied. Drives the dedupe in
    /// `applyIncremental`: a resumed stream may repeat what the page already has.
    private var lastAppliedSeq: Double?

    private static let mediaResolver: (MediaRef) -> URL = { _ in URL(fileURLWithPath: "/dev/null") }

    // MARK: - Init / reset

    init(vm: AIChatViewModel) {
        self.vm = vm
    }

    /// Drop everything and start projecting another Session.
    ///
    /// Does NOT seal the outgoing turn: the turn keeps running on the computer,
    /// and the incoming Session's snapshot is the authority for its own rows.
    func reset(sessionId: String) {
        NSLog("[DSH] writer reset in msgs=\(vm.messages.count) sid=\(sessionId.prefix(12))")
        self.sessionId = sessionId
        projection.reset()
        rowChat = [:]
        rowState = [:]
        renderedOrder = []
        pendingOptimistic = []
        deltaOpened = []
        attemptByStep = [:]
        liveDeltas = []
        cursor = 0
        lastAppliedSeq = nil
        // Only publish when something actually changes: `@Published` fires on
        // every assignment, and each one makes the list run a full diffable
        // snapshot apply. Opening a page on a fresh view model would otherwise
        // spend a main-thread layout pass deleting rows that were never there.
        if !vm.messages.isEmpty { vm.messages = [] }
        vm.isProcessing = false
        isRunning = false
        streamingTurn = nil
        NSLog("[DSH] writer reset out msgs=\(vm.messages.count)")
    }

    // MARK: - Frames

    /// One frame from `DSHRemoteStore`. The only entry point a view needs.
    func apply(_ frame: DSHRemoteStreamFrame) {
        switch frame {
        case .snapshot(let cursor, let records, _, let running, _, _, _):
            applySnapshot(cursor: cursor, records: records, running: running)
        case .event(let seq, let event):
            // One implementation for "a record arrived", not two: a resumed stream
            // arrives as a run of `.event` frames, and a live frame is a run of one.
            applyIncremental(records: [DSHHistoryRecord(seq: Double(seq), event: event)])
        case .delta(let turn, let step, let attempt, let index, let channel, let text):
            applyDelta(turn: turn, step: step, attempt: attempt, index: index, channel: channel, text: text)
        case .deltaEnd(let turn, _, let attempt):
            endDelta(turn: turn, attempt: attempt)
        }
    }

    /// Append records that continue the transcript (`resumed: true` from the host,
    /// or a cached tail being caught up).
    ///
    /// Deliberately NOT `applySnapshot`: this must not rebuild the list, because
    /// the point of an incremental fetch is that the page is already on screen.
    /// Records are de-duplicated by `seq`, so a resumed stream that overlaps the
    /// page cannot double-apply a turn.
    ///
    /// - Returns: how many records were actually applied (0 = nothing new).
    @discardableResult
    func applyIncremental(records: [DSHHistoryRecord]) -> Int {
        var applied = 0
        for record in records.sorted(by: { ($0.seq ?? 0) < ($1.seq ?? 0) }) {
            guard let event = record.event else { continue }
            if let seq = record.seq {
                if let last = lastAppliedSeq, seq <= last {
                    NSLog("[DSH] incremental skipped seq=\(Int(seq)) last=\(Int(last))")
                    continue
                }
                lastAppliedSeq = seq
            }
            apply(event: event)
            applied += 1
        }
        if applied > 0 {
            NSLog("[DSH] incremental applied=\(applied) lastSeq=\(Int(lastAppliedSeq ?? 0)) rows=\(vm.messages.count)")
        }
        return applied
    }

    /// Replace the transcript with a page of records.
    ///
    /// The stream's first frame is the newest page, so this is the reload path:
    /// the same projection the deltas use, replayed from the log. Whatever was
    /// running locally is sealed first — the snapshot's `running` is the truth.
    func applySnapshot(cursor: Int, records: [DSHHistoryRecord], running: Bool) {
        NSLog("[DSH] snapshot in records=\(records.count) cursor=\(cursor) running=\(running)")
        sealActiveTurnInternal(publish: false)
        projection.reset()
        // This is a PAGE (it can start mid-conversation) — arm the marker so a
        // window whose first record is mid-turn says so instead of looking empty.
        projection.beginPage()
        rowChat = [:]
        rowState = [:]
        renderedOrder = []
        // A rebuild re-announces every block: the trace must describe the page as
        // it is after the rebuild, not as it was before.
        deltaOpened = []
        attemptByStep = [:]
        // This is a REBUILD, so the rows that are about to be dropped must go
        // too: an empty Session reopened after a non-empty one would otherwise
        // keep the previous transcript (the order `[] == []` check below cannot
        // tell "nothing to draw" from "nothing changed").
        if !vm.messages.isEmpty { vm.messages = [] }
        // Optimistic rows survive a snapshot: the user may have sent a message a
        // moment ago and the snapshot was cut before its echo landed.
        var echoedUserMessages: [DSHHistoryEvent] = []
        for record in records.sorted(by: { ($0.seq ?? 0) < ($1.seq ?? 0) }) {
            guard let event = record.event else { continue }
            projection.apply(event)
            if event.type == "user/message" { echoedUserMessages.append(event) }
        }
        // An echo that is already IN the page still has to consume its optimistic
        // row, exactly like a live one — otherwise the snapshot duplicates it.
        for event in echoedUserMessages { promoteOptimisticUser(echo: event) }
        self.cursor = max(cursor, projection.lastSeq)
        // A rebuild re-establishes the watermark: anything at or below this seq is
        // already on screen.
        lastAppliedSeq = records.compactMap { $0.seq }.max() ?? lastAppliedSeq
        renderAll()
        // What the snapshot cannot contain: the in-flight step's streamed text.
        // Re-applied here, after the rebuild, so a reconnect continues the answer
        // instead of deleting the half that had already arrived.
        let durableSteps = Set(records.compactMap { record -> String? in
            guard let event = record.event, event.type == "assistant/message",
                  let turn = event.data?.turn, let step = event.data?.step else { return nil }
            return "\(turn)|\(step)"
        })
        let survivors = DSHRemoteTranscriptWriter.liveDeltasToReplay(liveDeltas, durableSteps: durableSteps)
        if !survivors.isEmpty {
            NSLog("[DSH] snapshot replay live deltas=\(survivors.count) (in-flight text kept) durableSteps=\(durableSteps.count)")
            for delta in survivors {
                attemptByStep[delta.stepKey] = delta.attempt
                projection.applyDelta(turn: delta.turn, step: delta.step, attempt: delta.attempt,
                                      index: delta.index, channel: delta.channel, text: delta.text)
            }
            renderAll()
        }
        // `running` comes from the harness' own Session row and is authoritative:
        // a turn that died without a `turn/end` (host killed mid-turn) leaves the
        // log "running" forever, and a STOP key that never goes away is worse than
        // one that appears on the next delta.
        setRunning(running, turn: running ? (projection.runningTurn ?? streamingTurn) : nil)
    }

    /// One durable event, in log order.
    func apply(event: DSHHistoryEvent) {
        projection.apply(event)
        cursor = max(cursor, projection.lastSeq)
        switch event.type {
        case "turn/start":
            if let turn = event.data?.turn { setRunning(true, turn: turn) }
        case "turn/end":
            // Turn sealed: force the thinking tail and the text tail out before
            // the durable message replaces the step (boundary 3).
            flushThinkingTails()
            commitTexts(finalFlush: true)
            if let turn = event.data?.turn { dropLiveDeltas(upTo: turn) }
            setRunning(projection.anyRunning, turn: projection.runningTurn)
        case "user/message":
            promoteOptimisticUser(echo: event)
        default:
            break
        }
        renderAll()
        // A durable event that opens a turn (`assistant/message`, `tool/call`)
        // proves the Session is busy even if its `turn/start` was missed — for
        // example when a reconnect resumed past it. The composer must show STOP
        // for that turn, not a send key.
        if projection.anyRunning, !isRunning { setRunning(true, turn: projection.runningTurn) }
        // [T-dsh-writer-trace] Machine-checkable proof that the step's blocks
        // were REPLACED, not appended: after a reload the same step must produce
        // the same `blocks=`/`kinds=` line it produced live.
        if event.type == "assistant/message", let turn = event.data?.turn {
            logDurableStep(turn: turn, step: event.data?.step)
        }
    }

    /// A live token delta.
    func applyDelta(turn: Int, step: Int, attempt: String, index: Int,
                    channel: DSHStreamChannel, text: String) {
        guard !text.isEmpty else { return }
        // [T-dsh-writer-trace] Once per (turn, step, attempt, index): the moment a
        // block is BORN. A streamed turn must open exactly as many blocks as its
        // durable message ends up with, and this line is what makes that provable
        // from a device log instead of from a screenshot.
        let deltaKey = "\(turn)|\(step)|\(attempt)|\(index)"
        attemptByStep["\(turn)|\(step)"] = attempt
        if deltaOpened.insert(deltaKey).inserted {
            NSLog("[DSH] writer delta-open t=\(turn) s=\(step) a=\(attempt) i=\(index) channel=\(channel.rawValue)")
        }
        // Recorded BEFORE the projection: this is the only copy of the text until
        // the step's durable `assistant/message` lands, and a snapshot that arrives
        // in between must not be able to erase it.
        rememberLiveDelta(turn: turn, step: step, attempt: attempt,
                          index: index, channel: channel, text: text)
        setRunning(true, turn: turn)
        projection.applyDelta(turn: turn, step: step, attempt: attempt,
                              index: index, channel: channel, text: text)
        renderAll()
    }

    // MARK: - In-flight text that a snapshot must not erase

    /// One streamed block, accumulated from its deltas, kept until a durable
    /// `assistant/message` for the same (turn, step) replaces it.
    struct LiveDelta: Equatable {
        var turn: Int
        var step: Int
        var attempt: String
        var index: Int
        var channel: DSHStreamChannel
        var text: String

        var stepKey: String { "\(turn)|\(step)" }
    }

    /// Deltas of the turn that is streaming right now, merged per block.
    private(set) var liveDeltas: [LiveDelta] = []
    /// Bound: a runaway stream must not grow this without limit.
    private static let maxLiveDeltas = 400

    private func rememberLiveDelta(turn: Int, step: Int, attempt: String, index: Int,
                                   channel: DSHStreamChannel, text: String) {
        // Only the newest turn can still be live; anything older is durable by
        // definition and keeping it would only make the rebuild slower.
        liveDeltas.removeAll { $0.turn < turn }
        if let existing = liveDeltas.firstIndex(where: {
            $0.turn == turn && $0.step == step && $0.attempt == attempt
                && $0.index == index && $0.channel == channel
        }) {
            liveDeltas[existing].text += text
            return
        }
        guard liveDeltas.count < Self.maxLiveDeltas else { return }
        liveDeltas.append(LiveDelta(turn: turn, step: step, attempt: attempt,
                                    index: index, channel: channel, text: text))
    }

    /// Which buffered deltas a rebuild has to re-apply.
    ///
    /// A snapshot only contains DURABLE messages, so every step it does not have an
    /// `assistant/message` for is still in flight: its streamed text exists nowhere
    /// else. Re-applying those is what stops a reconnect (the 30 s watchdog, a
    /// background/foreground cycle, a proxy dropping the socket) from making half an
    /// answer vanish and then restart mid-sentence.
    ///
    /// Pure, so the policy can be asserted without a view model.
    static func liveDeltasToReplay(_ deltas: [LiveDelta], durableSteps: Set<String>) -> [LiveDelta] {
        deltas.filter { !durableSteps.contains($0.stepKey) }
    }

    /// Forgets the buffered text of a turn that just became durable.
    private func dropLiveDeltas(upTo turn: Int) {
        liveDeltas.removeAll { $0.turn <= turn }
    }

    /// The attempt finished. Not a turn end — the durable message for the step
    /// follows, and the turn's later steps may still run.
    func endDelta(turn: Int, attempt: String) {
        projection.endDelta(turn: turn, attempt: attempt)
        // Boundary: the model stopped producing, so the throttled thinking tail
        // and the text tail must be on screen before the step's authoritative
        // message replaces the blocks. Not a final flush: more steps may come.
        flushThinkingTails()
        commitTexts(finalFlush: false)
    }

    // MARK: - Sealing

    /// Close the running turn locally.
    ///
    /// Called by the page's STOP handler BEFORE the cancel request: `turn/end`
    /// may never arrive for a cancelled turn, and a thinking block stuck in its
    /// streaming state forever is worse than a cancel request that fails.
    func sealActiveTurn() {
        sealActiveTurnInternal(publish: true)
    }

    private func sealActiveTurnInternal(publish: Bool) {
        let sealingTurn = streamingTurn
        flushThinkingTails()
        commitTexts(finalFlush: true)
        // A tool block still `.running`/`.streaming` would render as a tool that
        // runs forever; the local adapter marks those `.cancelled` at seal.
        for chat in vm.messages where chat.role == .assistant {
            for block in chat.blocks {
                switch block.toolStatus {
                case .streaming, .running:
                    block.toolStatus = .cancelled
                default:
                    break
                }
            }
        }
        setRunning(false, turn: nil)
        if publish { vm.publishUnlessTransitioning() }
        // [T-dsh-writer-trace] The sealed turn's final shape, as it stands on
        // screen — the number a reload of the same Session has to reproduce.
        let assistant = vm.messages.last(where: { $0.role == .assistant })
        NSLog("[DSH] writer seal t=\(sealingTurn.map(String.init) ?? "nil") msgs=\(vm.messages.count) blocks=\(assistant?.blocks.count ?? -1)")
    }

    /// [T-dsh-writer-trace] One line per durable `assistant/message`: the block
    /// shape of the row it rewrote. `kinds` uses single letters in ARRAY order so
    /// a streamed turn and a reloaded turn can be diffed mechanically:
    /// `t` text, `r` reasoning, `x` tool call, `T` tool result / info.
    private func logDurableStep(turn: Int, step: Int?) {
        guard let row = projection.rows.first(where: { row in
            if case .assistant(let rowTurn) = row.kind { return rowTurn == turn }
            return false
        }), let chat = rowChat[row.key] else { return }
        // The durable event carries no attempt id; the deltas that preceded it on
        // the same step are the only real source for one.
        let attempt = step.flatMap { attemptByStep["\(turn)|\($0)"] } ?? "nil"
        var letters = ""
        var chars = 0
        for block in chat.blocks {
            chars += block.content.count
            switch block.kind {
            case .text: letters += "t"
            case .thinking: letters += "r"
            case .info: letters += "T"
            default: letters += "x"
            }
        }
        let shown = letters.count > 24 ? String(letters.prefix(24)) + "…" : letters
        NSLog("[DSH] writer apply t=\(turn) s=\(step.map(String.init) ?? "nil") a=\(attempt) blocks=\(chat.blocks.count) kinds=\(shown) chars=\(chars)")
    }

    // MARK: - Optimistic user rows

    /// Insert the user's message locally, before the host has it.
    func appendOptimisticUser(text: String, requestId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let chat = ChatMessage(role: .user, content: trimmed)
        pendingOptimistic.append(OptimisticUser(requestId: requestId, text: trimmed, chat: chat))
        syncMessageOrder()
        vm.publishUnlessTransitioning()
        vm.scrollToBottomSignal.send()
    }

    /// The host accepted the send.
    ///
    /// Besides clearing the pending flag this flips `isRunning`, because the
    /// composer has to show STOP from the moment the prompt is queued — waiting
    /// for the first delta (or `turn/start`) leaves a window in which the send key
    /// is still live and the user can fire the same message twice.
    func markSendSucceeded(requestId: String) {
        guard let index = pendingOptimistic.firstIndex(where: { $0.requestId == requestId }) else { return }
        pendingOptimistic[index].succeeded = true
        setRunning(true, turn: streamingTurn)
    }

    /// The host refused the send: keep the bubble, mark it red, and let the page
    /// restore the draft.
    func markSendFailed(requestId: String, reason: String?) {
        guard let index = pendingOptimistic.firstIndex(where: { $0.requestId == requestId }) else { return }
        pendingOptimistic[index].chat.error = reason ?? AppLocalized("The computer did not accept this message.")
        vm.publishUnlessTransitioning()
    }

    /// Match the authoritative `user/message` echo to its optimistic row and hand
    /// that row's `ChatMessage` object over to the projection.
    ///
    /// Key: the trimmed TEXT. `requestId` never appears in the event log, and the
    /// harness' own message id is not knowable at send time, so text is the only
    /// key both sides share. FIFO among pending rows makes two identical sends in
    /// a row resolve correctly, and every injected kind is dropped by the
    /// classifier before it can consume a row.
    private func promoteOptimisticUser(echo: DSHHistoryEvent) {
        guard !pendingOptimistic.isEmpty else { return }
        guard case .user(let id, let text) = DSHTranscript.classify(echo) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pendingIdx = pendingOptimistic.firstIndex(where: { $0.text == trimmed }) else { return }
        let pending = pendingOptimistic.remove(at: pendingIdx)
        let key = "user:\(id)"
        // Reuse the SAME object: the bubble does not blink, and an error stamped
        // on it by a failed send survives its eventual echo.
        rowChat[key] = pending.chat
        // Only write when the value really changes.
        //
        // The echo usually carries the text the optimistic row already shows, and an
        // unconditional assignment was an in-place write to a `@Published` property:
        // the reference stayed the same, so a diffable list that compares identities
        // had nothing to reconfigure and the OLD text stayed on screen. Writing only
        // on a real change keeps the row's identity stable while still telling
        // observers (and the publisher below) that there is something to redraw.
        var changed = false
        if pending.chat.content != text {
            pending.chat.content = text
            changed = true
        }
        if pending.chat.error != nil {
            pending.chat.error = nil
            changed = true
        }
        if changed {
            NSLog("[DSH] optimistic user promoted key=\(key) len=\(text.count)")
            vm.publishUnlessTransitioning()
        }
    }

    // MARK: - Rendering

    /// Render every row. Cheap: a row whose parts did not change is a no-op.
    private func renderAll() {
        // [T-dsh-writer-trace] Wall-clock for the whole render pass. This is the
        // half of "opening a Session" that the client's own timings cannot see:
        // decode happens in DSHRemoteStream, then `renderAll` builds the blocks
        // and publishes, and the LIST lays out N markdown cells afterwards. With
        // this number the three costs can be told apart from a device log.
        let started = CFAbsoluteTimeGetCurrent()
        syncMessageOrder()
        for row in projection.rows {
            render(row)
        }
        vm.publishUnlessTransitioning()
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        NSLog("[DSH] renderAll rows=\(projection.rows.count) msgs=\(vm.messages.count) ms=\(Int(elapsed))")
    }

    /// Keep `vm.messages` in the projection's order, reusing existing objects.
    ///
    /// The assignment is skipped when the order is unchanged: `$messages` drives
    /// a full diffable snapshot in the list, and firing it per delta is what made
    /// streaming stutter.
    private func syncMessageOrder() {
        var order: [String] = projection.rows.map(\.key)
        order.append(contentsOf: pendingOptimistic.map { "optimistic:\($0.requestId)" })
        guard order != renderedOrder else { return }

        var next: [ChatMessage] = []
        var nextRows: [String: ChatMessage] = [:]
        for key in order {
            if let existing = rowChat[key] {
                next.append(existing)
                nextRows[key] = existing
                continue
            }
            if key.hasPrefix("optimistic:") {
                let requestId = String(key.dropFirst("optimistic:".count))
                guard let pending = pendingOptimistic.first(where: { $0.requestId == requestId }) else { continue }
                next.append(pending.chat)
                nextRows[key] = pending.chat
                continue
            }
            guard let row = projectionRow(key) else { continue }
            let chat = makeChat(row)
            next.append(chat)
            nextRows[key] = chat
        }
        rowChat = nextRows
        renderedOrder = order
        vm.messages = next
    }

    private func projectionRow(_ key: String) -> DSHTranscriptRow? {
        guard let index = projection.index(ofRow: key), index < projection.rows.count else { return nil }
        return projection.rows[index]
    }

    /// Build a row's `ChatMessage` when it first appears.
    private func makeChat(_ row: DSHTranscriptRow) -> ChatMessage {
        let text: String
        if case .text(let value) = row.parts.first { text = value } else { text = "" }
        switch row.kind {
        case .user:
            return ChatMessage(role: .user, content: text)
        case .notice:
            let chat = ChatMessage(role: .systemInfo, content: text)
            chat.systemIcon = row.noticeIcon ?? "info.circle"
            return chat
        case .checkpoint:
            let chat = ChatMessage(role: .compactDivider, content: AppLocalized("Context compacted"))
            chat.compactSummary = text.isEmpty ? nil : text
            chat.systemIcon = "arrow.down.right.and.arrow.up.left"
            return chat
        case .assistant:
            let chat = ChatMessage(role: .assistant, content: "")
            // [T-dsh-remote-brand] The identity row reads DSH, not Minis.
            chat.assistantDisplayName = row.assistantName ?? "DSH"
            return chat
        case .orphanTool:
            return ChatMessage(role: .assistant, content: "")
        }
    }

    /// Bring one row's blocks up to date with its parts.
    private func render(_ row: DSHTranscriptRow) {
        guard let chat = rowChat[row.key] else { return }
        if chat.isCompactedHistory != row.compacted { chat.isCompactedHistory = row.compacted }

        if case .orphanTool(let callId) = row.kind {
            renderOrphanTool(row, chat: chat, callId: callId)
            return
        }
        guard chat.role == .assistant else { return }
        if let usage = row.usage { chat.usage = tokenUsage(usage) }

        var state = rowState[row.key] ?? RenderedRow()
        let parts = row.parts

        // 1. First part that is not already rendered identically.
        var divergence = 0
        while divergence < min(parts.count, state.parts.count),
              parts[divergence] == state.parts[divergence] {
            divergence += 1
        }

        // 2. A tool result REPLACES the tool-use part at its own index. That is
        //    an in-place fill, not a rebuild: recreating the block would throw
        //    away the running card the user is already watching.
        if divergence < min(parts.count, state.parts.count),
           case .toolUse(let use) = state.parts[divergence],
           case .toolResult(let result) = parts[divergence],
           use.toolUseId == result.toolUseId,
           let blockIdx = state.partBlock[safe: divergence], blockIdx >= 0,
           blockIdx < chat.blocks.count {
            applyToolResult(result, to: chat.blocks[blockIdx])
            state.parts[divergence] = parts[divergence]
            divergence += 1
            while divergence < min(parts.count, state.parts.count),
                  parts[divergence] == state.parts[divergence] {
                divergence += 1
            }
        }

        // 3. Growth of the tail part is applied in place (the hot path: every
        //    streamed token). Anything else truncates at the divergence point and
        //    replays from there, which is how a durable message REWRITES the
        //    step it owns instead of appending a second copy of it.
        let canExtendTail = divergence == parts.count - 1
            && divergence < state.parts.count
            && Self.isExtension(from: state.parts[divergence], to: parts[divergence])

        rowState[row.key] = state

        if canExtendTail {
            extendTail(row.key, from: state.parts[divergence], to: parts[divergence], chat: chat)
            if var updated = rowState[row.key] {
                updated.parts[divergence] = parts[divergence]
                rowState[row.key] = updated
            }
            return
        }

        guard divergence < parts.count || divergence < state.parts.count else { return }
        truncate(chat: chat, key: row.key, at: divergence)
        for index in divergence..<parts.count {
            appendPart(parts[index], at: index, chat: chat, key: row.key)
        }
    }

    // MARK: Block construction

    /// Append one part as a new block (or, for a tool result whose call is
    /// already on this row, fill that block).
    private func appendPart(_ part: ContentPart, at partIndex: Int, chat: ChatMessage, key: String) {
        // Every new block is a boundary: the thinking tail and the text tail of
        // whatever was open must be on screen BEFORE the new block appears, or
        // the previous segment stays truncated (invariant 3). Runs before any
        // state mutation, while the pointers still name the open segments.
        flushThinkingTails()
        commitTexts(finalFlush: true)

        var state = rowState[key] ?? RenderedRow()
        while state.parts.count < partIndex { state.parts.append(.text("")) }
        if state.parts.count == partIndex {
            state.parts.append(part)
        } else {
            state.parts[partIndex] = part
        }

        switch part {
        case .reasoning(let text):
            state.textBlock = -1
            state.textPending = ""
            let block = AssistantBlock(kind: .thinking, content: "")
            chat.blocks.append(block)
            state.setPartBlock(partIndex, chat.blocks.count - 1)
            state.thinkingBlock = chat.blocks.count - 1
            state.thinkingPendingLength = 0
            state.lastThinkingFlush = .distantPast
            // Saved BEFORE the growth call: the growth helpers read `rowState`
            // themselves (single source of truth), so the new block pointer has to
            // be in there or the first flush would look at the previous segment.
            rowState[key] = state
            // First content of a new block: forced out in the same frame, with
            // the empty → filled signal (invariant 2).
            appendThinking(text, chat: chat, key: key, force: true)

        case .text(let text):
            state.thinkingBlock = -1
            state.thinkingPendingLength = 0
            let block = AssistantBlock(kind: .text, content: "")
            chat.blocks.append(block)
            state.setPartBlock(partIndex, chat.blocks.count - 1)
            state.textBlock = chat.blocks.count - 1
            state.textPending = ""
            state.lastTextFlush = .distantPast
            rowState[key] = state
            appendText(text, chat: chat, key: key, force: true)

        case .toolUse(let use):
            state.thinkingBlock = -1
            state.thinkingPendingLength = 0
            state.textBlock = -1
            state.textPending = ""
            let block = Self.makeToolBlock(use)
            chat.blocks.append(block)
            state.setPartBlock(partIndex, chat.blocks.count - 1)
            rowState[key] = state

        case .toolResult(let result):
            if let blockIdx = chat.blocks.firstIndex(where: { $0.toolUseId == result.toolUseId }) {
                applyToolResult(result, to: chat.blocks[blockIdx])
                state.setPartBlock(partIndex, blockIdx)
            } else {
                let block = AssistantBlock(kind: .info, content: result.output)
                block.toolUseId = result.toolUseId
                block.toolStatus = result.success ? .success : .failed(message: "")
                chat.blocks.append(block)
                state.setPartBlock(partIndex, chat.blocks.count - 1)
            }
            rowState[key] = state

        case .mediaRef:
            let block = AssistantBlock(kind: .info, content: "")
            chat.blocks.append(block)
            state.setPartBlock(partIndex, chat.blocks.count - 1)
            rowState[key] = state
        }
    }

    /// Extend the tail part's block with whatever it grew by.
    private func extendTail(_ key: String, from previous: ContentPart, to current: ContentPart,
                            chat: ChatMessage) {
        switch (previous, current) {
        case (.reasoning(let old), .reasoning(let new)):
            let suffix = String(new.dropFirst(old.count))
            if !suffix.isEmpty { appendThinking(suffix, chat: chat, key: key, force: false) }
        case (.text(let old), .text(let new)):
            let suffix = String(new.dropFirst(old.count))
            if !suffix.isEmpty { appendText(suffix, chat: chat, key: key, force: false) }
        default:
            break
        }
    }

    /// Drop every block built for parts at or after `index`.
    private func truncate(chat: ChatMessage, key: String, at index: Int) {
        guard var state = rowState[key], index <= state.partBlock.count else { return }
        var firstBlock = chat.blocks.count
        for partIndex in index..<state.partBlock.count {
            let blockIdx = state.partBlock[partIndex]
            if blockIdx >= 0 { firstBlock = min(firstBlock, blockIdx) }
        }
        if firstBlock < chat.blocks.count {
            chat.blocks.removeSubrange(firstBlock..<chat.blocks.count)
        }
        state.parts = Array(state.parts.prefix(index))
        state.partBlock = Array(state.partBlock.prefix(index))
        if state.thinkingBlock >= firstBlock { state.thinkingBlock = -1 }
        if state.textBlock >= firstBlock { state.textBlock = -1 }
        state.thinkingPendingLength = 0
        state.textPending = ""
        rowState[key] = state
    }

    // MARK: Thinking / text growth

    /// Append to the open thinking block, throttled.
    ///
    /// `flushThinkingBlock` is the ONLY publish point: it copies the block's
    /// buffer into `content` and sends the empty → filled height nudge. Calling
    /// `flushThinkingBuffer()` directly grew the block without telling the list,
    /// which is the overlap the contract calls out.
    private func appendThinking(_ delta: String, chat: ChatMessage, key: String, force: Bool) {
        guard var state = rowState[key],
              state.thinkingBlock >= 0, state.thinkingBlock < chat.blocks.count else { return }
        let block = chat.blocks[state.thinkingBlock]
        guard block.kind == .thinking else { return }
        block.appendThinkingDelta(delta)
        state.thinkingPendingLength += delta.count
        let length = block.content.count + state.thinkingPendingLength
        let interval = AssistantBlock.thinkingFlushInterval(forLength: length)
        let now = Date()
        guard force || now.timeIntervalSince(state.lastThinkingFlush) >= interval else {
            rowState[key] = state
            return
        }
        state.lastThinkingFlush = now
        state.thinkingPendingLength = 0
        rowState[key] = state
        vm.flushThinkingBlock(messageIdx: messageIndex(of: chat), blockIdx: state.thinkingBlock)
        scrollIfNeeded()
    }

    /// Append to the open text block, throttled, through the view model's own
    /// streaming commit (`setStreamingTextBlockContent`): it owns the markdown
    /// cache, the suspend/defer behaviour and the empty → filled signal.
    private func appendText(_ delta: String, chat: ChatMessage, key: String, force: Bool) {
        guard var state = rowState[key], state.textBlock >= 0,
              state.textBlock < chat.blocks.count else { return }
        state.textPending += delta
        let block = chat.blocks[state.textBlock]
        let projected = block.content.count + state.textPending.count
        let interval = StreamTextPresenter.throttleInterval(forAccumulatedLength: projected)
        let now = Date()
        guard force || now.timeIntervalSince(state.lastTextFlush) >= interval else {
            rowState[key] = state
            return
        }
        state.lastTextFlush = now
        rowState[key] = state
        commitText(key: key, finalFlush: false)
        scrollIfNeeded()
    }

    // MARK: Boundaries

    /// Force every open thinking block's buffered tail into its `content`.
    private func flushThinkingTails() {
        for key in Array(rowState.keys) {
            guard let chat = rowChat[key], let state = rowState[key] else { continue }
            guard state.thinkingBlock >= 0, state.thinkingBlock < chat.blocks.count else { continue }
            var updated = state
            updated.lastThinkingFlush = .distantPast
            updated.thinkingPendingLength = 0
            rowState[key] = updated
            vm.flushThinkingBlock(messageIdx: messageIndex(of: chat), blockIdx: state.thinkingBlock)
        }
    }

    /// Force one row's pending text into its block.
    private func commitText(key: String, finalFlush: Bool) {
        guard var state = rowState[key], state.textBlock >= 0, !state.textPending.isEmpty,
              let chat = rowChat[key], state.textBlock < chat.blocks.count else { return }
        let block = chat.blocks[state.textBlock]
        guard block.kind == .text else {
            state.textPending = ""
            rowState[key] = state
            return
        }
        let full = block.content + state.textPending
        state.textPending = ""
        rowState[key] = state
        let prepared = prepareMarkdownForRender(full)
        vm.setStreamingTextBlockContent(
            msgIdx: messageIndex(of: chat),
            blockIdx: state.textBlock,
            text: full,
            parsedMarkdown: MarkdownContent(prepared),
            cacheAttributedString: finalFlush,
            requestScroll: true
        )
    }

    /// Force every row's pending text into its block.
    private func commitTexts(finalFlush: Bool) {
        for key in Array(rowState.keys) {
            commitText(key: key, finalFlush: finalFlush)
        }
    }

    // MARK: Orphan tool rows

    /// A `tool/result` whose call never appeared in an assistant message.
    ///
    /// Rendered as a single `.info` block carrying the output — the same
    /// fallback the local adapter uses (`dshRenderToolResult`), so an orphaned
    /// result is visible instead of silently dropped.
    private func renderOrphanTool(_ row: DSHTranscriptRow, chat: ChatMessage, callId: String) {
        if let state = rowState[row.key], state.parts.count == row.parts.count, !chat.blocks.isEmpty {
            return
        }
        guard case .toolResult(let result) = row.parts.first else { return }
        let block = AssistantBlock(kind: .info, content: result.output)
        block.toolUseId = callId
        block.toolStatus = result.success ? .success : .failed(message: "")
        chat.blocks = [block]
        var state = rowState[row.key] ?? RenderedRow()
        state.parts = row.parts
        rowState[row.key] = state
        vm.publishUnlessTransitioning()
    }

    // MARK: Helpers

    private func applyToolResult(_ result: ToolResult, to block: AssistantBlock) {
        block.content = result.output
        switch result.status {
        case "cancelled": block.toolStatus = .cancelled
        case "failed": block.toolStatus = .failed(message: "")
        case "success": block.toolStatus = .success
        default: block.toolStatus = result.success ? .success : .failed(message: "")
        }
    }

    /// The tool block exactly as `toChatMessage` builds it on a reload.
    ///
    /// Routed through `toChatMessage` instead of a local `switch` on purpose: the
    /// kind mapping (shell / file / browser / image / memory, argument
    /// extraction, the `.running` seed, `toolInputArgs`) is written once, in the
    /// type that owns the renderer, so a streamed tool card and a reloaded one
    /// cannot drift apart as that mapping grows.
    private static func makeToolBlock(_ use: ToolUse) -> AssistantBlock {
        let raw = RawMessage(
            id: "tool-probe", sessionId: "", role: .assistant,
            parts: [.toolUse(use)], createdAt: Date()
        )
        let probe = raw.toChatMessage(mediaResolver: mediaResolver, showThinking: false)
        if let block = probe.blocks.first {
            block.toolStatus = .running
            block.toolStartTime = Date()
            return block
        }
        let block = AssistantBlock(kind: .shellTool(command: use.name), content: use.name)
        block.toolUseId = use.toolUseId
        block.toolStatus = .running
        block.toolStartTime = Date()
        return block
    }

    private func tokenUsage(_ usage: DSHHistoryUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: Int(usage.inputTokens ?? 0),
            outputTokens: Int(usage.outputTokens ?? 0),
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            latestContextTokens: Int(usage.totalTokens ?? 0),
            cacheReported: false
        )
    }

    private func messageIndex(of chat: ChatMessage) -> Int {
        vm.messages.firstIndex(where: { $0 === chat }) ?? -1
    }

    private func scrollIfNeeded() {
        if vm.isNearBottom { vm.scrollToBottomSignal.send() }
    }

    private func setRunning(_ running: Bool, turn: Int?) {
        if isRunning != running { isRunning = running }
        if streamingTurn != turn { streamingTurn = turn }
        if vm.isProcessing != running { vm.isProcessing = running }
    }

    private static func isExtension(from old: ContentPart, to new: ContentPart) -> Bool {
        switch (old, new) {
        case (.reasoning(let a), .reasoning(let b)): return b.hasPrefix(a)
        case (.text(let a), .text(let b)): return b.hasPrefix(a)
        default: return false
        }
    }
}

// MARK: - Row render state

/// Incremental block bookkeeping for one row.
private struct RenderedRow {
    /// The parts this row's blocks were built from, index-aligned with
    /// `partBlock`.
    var parts: [ContentPart] = []
    /// Part index → index in the `ChatMessage`'s blocks (-1 for "no block").
    var partBlock: [Int] = []
    var thinkingBlock = -1
    var textBlock = -1
    var thinkingPendingLength = 0
    var textPending = ""
    var lastThinkingFlush: Date = .distantPast
    var lastTextFlush: Date = .distantPast

    mutating func setPartBlock(_ partIndex: Int, _ blockIndex: Int) {
        while partBlock.count <= partIndex { partBlock.append(-1) }
        partBlock[partIndex] = blockIndex
    }
}

private struct OptimisticUser {
    let requestId: String
    let text: String
    let chat: ChatMessage
    var succeeded = false
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
