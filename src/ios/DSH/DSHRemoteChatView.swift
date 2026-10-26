import SwiftUI
import Combine

/// Translates one remote harness Session into the Minis message model and keeps
/// it live.
///
/// Everything visual is the existing pipeline: `CollectionViewMessageListV3` →
/// `AssistantBlockView` / thinking blocks / tool capsules / `SelectableMarkdownView`.
/// This class only feeds `vm.messages` — and since protocol v2 it does that by
/// forwarding stream frames to `DSHRemoteTranscriptWriter`, which owns block
/// identity, the empty→full height signal and the three flush boundaries (see
/// the contract, §3.2). Nothing in here touches blocks directly.
@MainActor
final class DSHRemoteChatAdapter: ObservableObject {
    let vm: AIChatViewModel
    /// One writer per view model: it accumulates a turn's blocks into `vm.messages`
    /// and publishes whether a turn is running.
    let writer: DSHRemoteTranscriptWriter

    /// Session title; `DSH` when the Session has no name yet.
    @Published var title = "DSH"
    /// The page is opening (closing the old stream, resolving the title).
    @Published var isLoading = false
    /// A turn is running on the host — this is what turns the composer's send key
    /// into STOP. Taken from the writer, not from the store's list snapshot: the
    /// list refreshes a beat behind, and a send key that lags is a send key that
    /// fires twice.
    @Published private(set) var isRunning = false
    /// `submit` is in flight, or a stop has been requested and not settled.
    @Published private(set) var isSending = false
    /// Connection-level error (no stream, host refused the stream). One line, with
    /// a retry — never a stack of dialogs.
    @Published private(set) var errorText: String?
    /// A send that the host rejected. Separate from `errorText` because the page
    /// keeps working (the draft is restored) and the two must not overwrite each
    /// other.
    @Published private(set) var sendErrorText: String?
    /// No snapshot frame yet: the transcript is empty because nothing has arrived,
    /// not because the Session is empty.
    @Published private(set) var awaitingSnapshot = true
    /// The context ring's numbers.
    ///
    /// Published **state**, not a computed property: its sources are the shared
    /// `DSHRemoteStore.sessions` list and the stream's own `snapshot`, neither of
    /// which this view owns and therefore observes. As a computed property the
    /// value was only re-read when some unrelated property of this adapter
    /// changed, so a Session list that landed late left the ring empty for the
    /// lifetime of the screen even though the numbers were sitting in the store.
    @Published private(set) var contextReading: DSHContextReading?

    private var loadedSessionId: String?
    private var streamToken: UUID?
    private var sessionsSubscription: AnyCancellable?
    private var runningSubscription: AnyCancellable?
    private var storeErrorSubscription: AnyCancellable?
    /// Text blocks whose `cachedAttributedString` is current, valued by the
    /// content length that string was built from. See `refreshHeightMetadata`.
    private var renderedTextLengths: [UUID: Int] = [:]

    init() {
        let model = AIChatViewModel()
        vm = model
        writer = DSHRemoteTranscriptWriter(vm: model)
        // `$rows`, not `$sessions`: rows is the published property, sessions is the
        // model view derived from it. Any list refresh — pull-to-refresh, a
        // reconnect, the `refreshConversations()` this page fires when its Session
        // is not in the list yet — re-derives the ring and the title from here.
        sessionsSubscription = DSHRemoteStore.shared.$rows
            .sink { [weak self] rows in
                Task { @MainActor in self?.apply(rows: rows) }
            }
        runningSubscription = writer.$isRunning
            .sink { [weak self] value in
                Task { @MainActor in
                    guard let self else { return }
                    let wasRunning = self.isRunning
                    self.isRunning = value
                    // true → false is the seal (a `turn/end`, a STOP, or the
                    // writer's own seal when the host goes quiet). The blocks that
                    // were growing are final from here on, so this is the moment
                    // their true height can be cached — and the moment the cells
                    // that were laid out on an estimate need to be told.
                    if wasRunning, !value { self.refreshHeightMetadata(nudge: true) }
                }
            }
        storeErrorSubscription = DSHRemoteStore.shared.$errorText
            .sink { [weak self] value in
                Task { @MainActor in
                    guard let self, let value, !value.isEmpty else { return }
                    // Only while this page owns a stream: otherwise a sidebar
                    // refresh failure would paint a red line inside a transcript
                    // that is perfectly fine.
                    guard self.streamToken != nil else { return }
                    self.errorText = value
                    // A stream error also ends the "waiting for the first
                    // snapshot" state: leaving the spinner up would hide the red
                    // line behind a progress indicator that will never finish.
                    self.awaitingSnapshot = false
                }
            }
    }

    // MARK: - Lifecycle

    /// Opens the Session: resolve the title, clear the writer, start the stream.
    ///
    /// `load()` does not fetch a history page of its own: the stream's first frame
    /// IS the newest page (`snapshot`), and `DSHRemoteStore` seeds it with the
    /// cursor this device has already seen. Fetching both would race two writers
    /// into `vm.messages`.
    func load(sessionId: String, force: Bool = false) async {
        // The detail screen is reached with the sidebar's conversation id; inside
        // the DSH layer the Session id is the conversation id without the
        // transport prefix, so normalize before every lookup.
        let sessionId = DSHRemoteSidebar.conversationId(from: sessionId)
        // `streamToken == nil` is the "no live stream right now" half of this
        // guard, and it is load-bearing: `close()` (page disappears) leaves the
        // Session id in place, so without it re-entering the same Session would
        // return here and leave the page with no stream, no snapshot and a
        // spinner that never resolves. `close()` also clears `loadedSessionId`;
        // both halves are kept so either one alone is enough.
        guard force || streamToken == nil || loadedSessionId != sessionId else { return }
        // Close the outgoing Session's stream BEFORE the writer is reset, so no
        // late frame from it can land in the new transcript.
        closeStream()
        loadedSessionId = sessionId
        isLoading = true
        awaitingSnapshot = true
        errorText = nil
        sendErrorText = nil
        writer.reset(sessionId: sessionId)
        // A new Session's blocks are new objects; the old ids would only keep
        // memory alive and could match a recycled id by accident.
        renderedTextLengths.removeAll(keepingCapacity: true)
        // Resolve now as well as through the subscription: the list is usually
        // already here (the user tapped a row it painted).
        apply(rows: DSHRemoteStore.shared.rows)
        guard DSHRemoteStore.shared.host != nil else {
            errorText = AppLocalized("Pair this device with your computer to open a DSH session.")
            isLoading = false
            return
        }
        openStream(sessionId: sessionId)
        isLoading = false
    }

    /// Leaving the page: stop receiving, and nothing else.
    ///
    /// Deliberately NOT `writer.sealActiveTurn()`: the turn keeps running on the
    /// computer, and sealing would mark a live tool block as cancelled in the
    /// copy this device is holding. Re-entering rebuilds from the stream's
    /// snapshot.
    ///
    /// `loadedSessionId` is cleared so that coming back to the SAME Session takes
    /// the full open path again (title, writer reset, new stream). Without it the
    /// `load()` guard saw "same Session, already loaded" and returned with no
    /// stream at all — the page then sat on an empty transcript forever.
    func close() {
        closeStream()
        loadedSessionId = nil
        renderedTextLengths.removeAll(keepingCapacity: true)
    }

    /// Opens the Session's live stream. The store owns the socket, the cursor and
    /// the reconnect backoff; this page only receives frames — and the token it
    /// gets back is how it detaches on the way out.
    private func openStream(sessionId: String) {
        streamToken = DSHRemoteStore.shared.openStream(sessionId: sessionId) { [weak self] frame in
            self?.receive(frame)
        }
    }

    private func closeStream() {
        if let token = streamToken {
            DSHRemoteStore.shared.closeStream(token)
        }
        streamToken = nil
    }

    // MARK: - Frames

    /// One frame from the store, on the main actor, in order.
    private func receive(_ frame: DSHRemoteStreamFrame) {
        // Any frame at all proves the stream is alive.
        awaitingSnapshot = false
        switch frame {
        case .snapshot(_, _, _, _, let snapshotTitle, let pressure):
            // A snapshot proves the stream is alive, so whatever the last
            // connection error said no longer describes this page.
            errorText = nil
            if let snapshotTitle {
                let trimmed = snapshotTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { title = trimmed }
            }
            if let pressure { apply(pressure: pressure) }
        case .event, .delta, .deltaEnd:
            break
        }
        // The writer is the only place blocks are created, so this is the single
        // entry point for all four frame kinds.
        writer.apply(frame)
        // …and this is the single place the cells' height can be made right: the
        // list has not applied a snapshot yet at this point (SwiftUI updates after
        // this call returns), so caching here is what makes `applySnapshot` seed a
        // TextKit-accurate `precalcHeight` instead of a coarse estimate.
        refreshHeightMetadata(nudge: false)
    }

    // MARK: - Height metadata

    /// Give every settled text block the TextKit metadata the list seeds cell
    /// heights from, and — when asked — tell the list to re-lay those cells out.
    ///
    /// [T-dsh-overlap-estimate-fallback] The list seeds a cell's height from
    /// `block.cachedAttributedString` (a TextKit measure, accurate) and falls back
    /// to a character-count estimate when it is nil. On iOS 15 the self-sizing
    /// measure itself can throw —
    ///
    ///     NSInternalInconsistencyException — Content view returned an invalid size
    ///     {1.7976931348623157e+308, 28} from -systemLayoutSizeFittingSize:…
    ///
    /// — and `SelfSizingCell` then keeps whatever the layout seeded ("using
    /// fallback height"). For a long paragraph that seed was a ONE-LINE estimate
    /// while the block renders many lines, and since `contentView` does not clip,
    /// the text painted over the block below it: the "blocks overlap" report. The
    /// local chat path never shows this because `loadSession` caches an attributed
    /// string for every text block before its first snapshot, so even the fallback
    /// height is the true one; the remote writer only caches at final-flush
    /// boundaries, so a page rebuilt from a snapshot started on estimates.
    ///
    /// Cost control: the length gate means each block is rendered once per content
    /// version, and the growing tail of a running turn is skipped outright (it is
    /// still changing; the writer caches it itself when it commits). `nudge` is
    /// only used on the seal, where the item list does not change and the layout
    /// would otherwise keep the height it already reserved.
    private func refreshHeightMetadata(nudge: Bool) {
        let messages = vm.messages
        guard !messages.isEmpty else { return }
        let running = isRunning
        var nudged: [(messageId: UUID, blockId: UUID)] = []
        var cached = 0
        for (index, message) in messages.enumerated() where message.role == .assistant {
            // The last message of a running turn is the block that is being
            // appended to right now: rendering it here would re-parse its markdown
            // on every token for a height nobody can trust until it settles.
            if running, index == messages.count - 1 { continue }
            for block in message.blocks where block.kind == .text {
                let length = block.content.count
                guard length > 0, renderedTextLengths[block.id] != length else { continue }
                vm.cacheAttributedString(for: block)
                renderedTextLengths[block.id] = length
                cached += 1
                if nudge { nudged.append((messageId: message.id, blockId: block.id)) }
            }
        }
        // [T-ios-sizing-throw-counter] One line per pass that actually did work,
        // so the device log proves the pass is bounded: `nudge` is the number of
        // list reconfigures this pass costs.
        if cached > 0 {
            NSLog("[DSH] heightMeta cached=\(cached) nudge=\(nudged.count) running=\(running) msgs=\(messages.count)")
        }
        guard nudge, !nudged.isEmpty else { return }
        // One runloop later: the list drops a signal for an item it does not have
        // in its snapshot yet ("fill signal MISSED"), and the item list is only
        // rebuilt after this frame's `vm.messages` change has been rendered.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for pair in nudged {
                self.vm.blockContentFilledSignal.send(pair)
            }
        }
    }

    // MARK: - Send / stop

    /// Sends one message. Returns false when the host rejected it; the caller
    /// then restores the draft (contract §3.1).
    ///
    /// The optimistic bubble is inserted by the writer, which also owns the
    /// de-duplication against the echoed `user/message` event — one implementation,
    /// not two.
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending, !isRunning,
              let sessionId = loadedSessionId else { return false }
        let requestId = UUID().uuidString
        isSending = true
        sendErrorText = nil
        writer.appendOptimisticUser(text: trimmed, requestId: requestId)
        defer { isSending = false }
        do {
            try await DSHRemoteStore.shared.submit(sessionId: sessionId, text: trimmed, requestId: requestId)
            writer.markSendSucceeded(requestId: requestId)
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            writer.markSendFailed(requestId: requestId, reason: message)
            sendErrorText = message
            return false
        }
    }

    /// Stops the running turn.
    ///
    /// The local seal happens FIRST: `turn/end` may never arrive for a cancelled
    /// turn, and a thinking block that keeps its streaming state forever is worse
    /// than a cancel request that fails.
    func stop() async {
        guard let sessionId = loadedSessionId else { return }
        writer.sealActiveTurn()
        do {
            try await DSHRemoteStore.shared.cancel(sessionId: sessionId)
        } catch {
            sendErrorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func dismissSendError() {
        sendErrorText = nil
    }

    // MARK: - Title / ring

    /// Title and ring from the Session list, in one place.
    private func apply(rows: [DSHHostSessionRow]) {
        guard let sessionId = loadedSessionId else { contextReading = nil; return }
        guard let row = rows.first(where: { $0.session.sessionId == sessionId }) else {
            // Not in the list yet (opened from a restored selection before
            // `connect()` returned): ask the store, so both the title and the ring
            // fill in through this subscription instead of waiting for a refresh
            // the user may never trigger.
            Task { await DSHRemoteStore.shared.refreshConversations() }
            contextReading = nil
            return
        }
        title = Self.title(for: row.session)
        if let pressure = row.session.contextPressure {
            apply(pressure: pressure)
        } else {
            // No figure for this Session (a blank Session, a bridge that never
            // reported pressure): the composer then draws no fill at all, which is
            // the honest state. What it must never do is draw zeros, which read as
            // "0% used".
            contextReading = nil
        }
    }

    private func apply(pressure: DSHContextPressure) {
        guard let used = pressure.usedTokens, used > 0,
              let window = pressure.contextWindow, window > 0 else {
            contextReading = nil
            return
        }
        contextReading = DSHContextReading(
            usedTokens: Int(used),
            windowTokens: Int(window),
            source: .providerMeasured
        )
    }

    /// The navigation title: the Session's own name, else the brand.
    static func title(for session: DSHHostSession) -> String {
        let raw = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "DSH" : raw
    }
}

/// Detail screen for a harness Session. Rendering is the shared Minis list; only
/// the data source is remote.
///
/// Writable since protocol v2: the composer below the transcript posts to
/// `/dsh/submissions` and the stop key posts to `/dsh/cancel`. The identity row
/// of every assistant turn reads `DSH` — the transcript writer stamps
/// `ChatMessage.assistantDisplayName` on the rows it builds (see
/// `DSHTranscript`), so the local conversation path keeps showing the SOUL name.
struct DSHRemoteChatView: View {
    let conversationId: String
    @StateObject private var adapter = DSHRemoteChatAdapter()
    @State private var draft = ""
    /// Measured composer height, handed to the list as its bottom inset. The list
    /// is the only view that knows how much of the bottom it must keep clear.
    @State private var composerHeight: CGFloat = 0
    /// Mirrors the editor's focus so the list keeps its "keyboard raised → scroll
    /// to bottom" behaviour.
    @State private var composerFocused = false

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let sendError = adapter.sendErrorText {
                statusLine(sendError, retryTitle: AppLocalized("Retry")) {
                    adapter.dismissSendError()
                    send()
                }
            }
            if let error = adapter.errorText {
                statusLine(error, retryTitle: AppLocalized("Reconnect")) {
                    Task { await adapter.load(sessionId: conversationId, force: true) }
                }
            }
            DSHRemoteComposer(
                text: $draft,
                contextReading: adapter.contextReading,
                isRunning: adapter.isRunning,
                isSending: adapter.isSending,
                onSend: { send() },
                onStop: { Task { await adapter.stop() } },
                onHeightChange: { composerHeight = $0 },
                onFocusChange: { composerFocused = $0 }
            )
        }
        .navigationTitle(adapter.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if adapter.isLoading {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button {
                        Task { await adapter.load(sessionId: conversationId, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(Text("Refresh", comment: "Reload this remote session"))
                }
            }
        }
        .task { await adapter.load(sessionId: conversationId) }
        // Leaving the screen closes the stream. The turn itself keeps running on
        // the computer — see `DSHRemoteChatAdapter.close()`.
        .onDisappear { adapter.close() }
    }

    /// The transcript itself. `floatingBarHeight: 0` and `panelHeights: 0`: a
    /// remote Session has no floating tool preview and no goal/todo bar, and
    /// reserving space for bars that never draw put a dead gap between the last
    /// message and the composer.
    private var transcript: some View {
        ZStack {
            CollectionViewMessageListV3(
                vm: adapter.vm,
                inputFocused: composerFocused,
                onRetryMessage: nil,
                onRetryLast: nil,
                onEdit: nil,
                onWithdraw: nil,
                onResume: nil,
                onStop: { Task { await adapter.stop() } },
                onCompact: nil,
                maxContentWidth: 0,
                floatingBarHeight: 0,
                inputBarHeight: composerHeight > 0 ? composerHeight : 132,
                panelHeights: 0
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if adapter.awaitingSnapshot, !adapter.isLoading {
                ProgressView()
            }
        }
    }

    /// One red line, one action. The brief rules out stacked dialogs: a connection
    /// failure or a rejected send says what happened, in the page, and offers the
    /// single step that retries it.
    private func statusLine(_ text: String, retryTitle: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
            Text(text)
                .font(AppFont.sw(12, weight: .regular, category: .ui))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Button(retryTitle, action: retry)
                .font(AppFont.sw(12, weight: .semibold, category: .ui))
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Hands the draft to the adapter. The draft is cleared up front (the bubble
    /// appears immediately, optimistically) and restored on failure — only when the
    /// composer is still empty, so a message the user has started typing since is
    /// never overwritten.
    private func send() {
        let outgoing = draft
        guard !outgoing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        // Same order as the local composer (`AIChatView.performSend`): ask the
        // list to follow the bottom BEFORE the new row lands, so the optimistic
        // bubble is what the user sees rather than being left below the fold.
        adapter.vm.forceScrollToBottom.send()
        Task {
            let accepted = await adapter.send(outgoing)
            if !accepted, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = outgoing
            }
        }
    }
}
