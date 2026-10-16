import Foundation

// MARK: - StreamTextPresenter
//
// Lives here rather than beside the view model it serves for a build-system
// reason, not a design one: `src/ios/Agent/Chat/` files are listed explicitly in
// Minis.xcodeproj, while `src/ios/DSH/` is a PBXFileSystemSynchronizedRootGroup
// already wired into the app target — a new file there compiles with no project
// edit, and a new file in Agent/Chat/ silently would not. The DSH directory in
// turn already holds the app-side bridges of the DSH port, so this is consistent
// with what else is in it.
//
// [T-ios-streamtext-one-owner] One implementation of "streamed text becomes the
// transcript row's text block", used by both agent loops.
//
// The two loops used to keep separate copies of four things: which text block is
// being filled, what text has been accumulated for it, when to flush, and how to
// parse the markdown. The copies drifted, and every drift that showed up on
// device was one of these:
//
//   * the DSH copy dropped the legacy newline gate's `unflushed >= 50` clause, so
//     a box-drawing stream flushed on every one of its two-character lines
//     instead of once per line group;
//   * the DSH copy cleared its pending buffer *before* proving the target block
//     still existed, so on the miss the text was dropped rather than retained;
//   * the DSH copy kept the block index and the accumulated text in two separate
//     variables that a tool call could pull apart, so a flush could write text
//     accumulated for one block into another — the row then showed a sentence's
//     tail instead of the sentence.
//
// So: one state machine, two callers. The DISPLAY write is unchanged — both paths
// end in `AIChatViewModel.setStreamingTextBlockContent`, which is the app's
// existing streaming flush (suspend/defer, markdown cache, empty→filled signal,
// scroll). Nothing here re-implements the display path; re-implementing it was
// the original mistake.
//
// Threading: this type is deliberately NOT actor-isolated. `takeFlushPayload`
// runs on the caller's executor, so the markdown parse happens off the main
// thread when the legacy loop (a `nonisolated` function) calls it, exactly as it
// did before. Only `beginBlock()` and the commit hop to the main actor.

/// A prepared flush: the full text for the block, plus its markdown parsed
/// off-main. Handed to `AIChatViewModel.commitStreamText(_:plan:finalFlush:)`.
struct StreamTextFlushPlan {
    let text: String
    let parsedMarkdown: MarkdownContent
}

final class StreamTextPresenter {

    private static let logger = AppLogger(category: "StreamText")

    // MARK: - State

    /// The transcript row this turn writes into. `-1` means "no row".
    var msgIdx: Int = -1

    /// The text block currently being streamed into. `-1` means "no block yet".
    private(set) var blockIdx: Int = -1

    /// Everything streamed into the CURRENT block, in order.
    ///
    /// Bound to `blockIdx` by `beginBlock()`. That binding is the point of the
    /// type: a block is only ever written with the text accumulated for it.
    private(set) var accumulated: String = ""

    /// Text streamed since the last commit. Drives the throttle only.
    private var pending: String = ""

    private var lastFlushAt: Date = .distantPast
    private var lastCommittedLength: Int = 0

    // Read-aloud state, per block, matching what the legacy loop kept inline.
    private var spokenOffset: Int = 0
    private var hasStoppedPreviousTTS = false
    private var speakBuffer: String = ""

    private weak var vm: AIChatViewModel?

    init(vm: AIChatViewModel) {
        self.vm = vm
    }

    // MARK: - Block lifecycle

    /// Append a fresh empty text block to the row and rebind the accumulator to
    /// it. Returns the new block index, or nil when the row is gone.
    ///
    /// This is the same append + `[TextDrift]` line + activity-tracker update the
    /// legacy loop performed inside `case .contentBlockStart(.text)`.
    @MainActor
    func beginBlock() -> Int? {
        guard let vm else { return nil }
        let idx = msgIdx
        guard idx >= 0, idx < vm.messages.count else { return nil }

        let blockCount = vm.messages[idx].blocks.count
        let prevBlockKind: String = blockCount > 0
            ? "\(vm.messages[idx].blocks[blockCount - 1].kind)"
            : "none"
        vm.messages[idx].blocks.append(AssistantBlock(kind: .text, content: ""))
        let newIdx = vm.messages[idx].blocks.count - 1
        Self.logger.info(
            "[TextDrift] New empty text block appended at idx=\(blockCount) "
            + "prevBlockKind=\(prevBlockKind) totalBlocks=\(blockCount + 1)"
        )
        if let sid = vm.sessionId {
            SessionActivityTracker.shared.updateToolInfo(
                sessionId: sid, toolName: "text", toolStatus: "streaming"
            )
        }

        blockIdx = newIdx
        accumulated = ""
        pending = ""
        lastFlushAt = .distantPast
        lastCommittedLength = 0
        spokenOffset = 0
        hasStoppedPreviousTTS = false
        return newIdx
    }

    // MARK: - Accumulate

    /// Close the current block: the next delta starts a new one.
    ///
    /// Text before and after a tool call are two different transcript blocks, and
    /// the block the presenter points at is forgotten here rather than at the next
    /// delta, so nothing can extend a block that has already been left behind.
    func endBlock() {
        blockIdx = -1
        accumulated = ""
        pending = ""
        lastCommittedLength = 0
        // The read-aloud offset indexes `accumulated`, so it resets with it —
        // otherwise the next block's speech starts part-way through its own text.
        spokenOffset = 0
    }

    /// Take one text delta. Cheap and off-main safe: string appends only.
    func accumulate(_ delta: String) {
        accumulated += delta
        pending += delta
    }

    // MARK: - Throttle

    /// The existing tiered throttle, unchanged: markdown re-parsing is O(n²) on
    /// dense streams and re-parsing per delta tripped the main-thread watchdog.
    static func throttleInterval(forAccumulatedLength len: Int) -> TimeInterval {
        len < 500 ? 0.20
            : len < 2000 ? 0.30
            : len < 32_000 ? 0.50
            : len < 64_000 ? 1.00
            : len < 128_000 ? 1.50
            : 2.00
    }

    /// Decide whether a delta-driven commit is due, and prepare it.
    ///
    /// Non-isolated on purpose: the markdown parse runs on the caller's thread, so
    /// it stays off the main thread for the legacy loop.
    ///
    /// - Parameter force: a brand-new block is committed immediately and ignoring
    ///   the throttle. The list's height invalidator runs off the empty → filled
    ///   signal and gives up silently if the block it names is not yet in the
    ///   data-source snapshot, which leaves the cell at its ~0pt empty height.
    func takeFlushPayload(force: Bool = false) -> StreamTextFlushPlan? {
        guard !pending.isEmpty, blockIdx >= 0 else { return nil }

        let len = accumulated.count
        let unflushed = len - lastCommittedLength
        // Below 5000 chars a newline plus a real batch (>= 50 unflushed) commits
        // early, for a line-by-line feel. At/above 5000 chars the fast path is
        // off: ASCII-art and table runs emit a newline every couple of characters
        // and would pin the effective interval at the per-chunk delay.
        let newlineFlush = len < 5000 && pending.contains("\n") && unflushed >= 50
        let elapsed = Date().timeIntervalSince(lastFlushAt)
        guard force || newlineFlush || elapsed >= Self.throttleInterval(forAccumulatedLength: len) else {
            return nil
        }

        let text = accumulated
        guard !text.isEmpty else { return nil }

        // Clear the pending buffer only now that a payload is actually being
        // handed over — the earlier "clear, then look for the block" order is what
        // silently dropped text when the lookup failed.
        pending = ""
        lastFlushAt = Date()
        lastCommittedLength = len

        let prepared = prepareMarkdownForRender(text)
        return StreamTextFlushPlan(text: text, parsedMarkdown: MarkdownContent(prepared))
    }

    /// Prepare a commit for everything accumulated so far, ignoring the throttle.
    ///
    /// Used where the legacy loop committed unconditionally: before a tool block
    /// is appended, and at stream end. Off-main for the same reason as
    /// `takeFlushPayload`.
    func forcePayload() -> StreamTextFlushPlan? {
        guard blockIdx >= 0 else { return nil }
        let text = accumulated
        guard !text.isEmpty else { return nil }
        pending = ""
        lastFlushAt = Date()
        lastCommittedLength = text.count
        let prepared = prepareMarkdownForRender(text)
        return StreamTextFlushPlan(text: text, parsedMarkdown: MarkdownContent(prepared))
    }

    /// Put a refused payload back on the buffer, so a commit that the display
    /// layer declined (see the shrink guard in `commitStreamText`) is retried
    /// rather than lost.
    func requeue(_ text: String) {
        guard !text.isEmpty else { return }
        pending = text
        lastCommittedLength = 0
    }

    // MARK: - Streaming read-aloud

    /// Speak completed sentences as they arrive — the same path the legacy loop
    /// used, with the same once-per-turn TTS queue clear.
    func speakStreamedText() async {
        guard let vm else { return }
        guard await MainActor.run(body: { vm.speakEnabled }) else { return }

        if !hasStoppedPreviousTTS {
            hasStoppedPreviousTTS = true
            await MainActor.run {
                // Once per TURN, not per iteration/step: this session's previous
                // reply stops when new text actually arrives, and the shared flag
                // makes later steps of the same turn append behind it instead of
                // cutting it off.
                guard !vm.hasClearedTTSForCurrentTurn else { return }
                vm.hasClearedTTSForCurrentTurn = true
                vm.stopSpeechForThisSession()
            }
        }

        let (sentences, newOffset) = vm.extractNewSentences(
            from: accumulated, spokenOffset: spokenOffset
        )
        guard !sentences.isEmpty else { return }
        spokenOffset = newOffset
        // A newline between units lets the dynamic window cut on a whole-sentence
        // boundary, which keeps the timbre consistent across one batch.
        if !speakBuffer.isEmpty { speakBuffer += "\n" }
        speakBuffer += sentences.joined(separator: "\n")
        let buffered = speakBuffer
        speakBuffer = await MainActor.run { vm.feedDynamicTTS(buffered, force: false) }
    }

    /// Flush the speech buffer and drop the read-aloud state at end of turn.
    func sealSpeech() async {
        guard let vm else { return }
        guard !speakBuffer.isEmpty else { return }
        let buffered = speakBuffer
        speakBuffer = ""
        _ = await MainActor.run { vm.feedDynamicTTS(buffered, force: true) }
    }

    // MARK: - Diagnostics

    /// Drop the turn's streaming state, after the last commit.
    ///
    /// `speakBuffer` is deliberately left alone: `sealSpeech()` owns it, and it
    /// flushes what is left before clearing.
    func reset() {
        endBlock()
        hasStoppedPreviousTTS = false
    }
}
