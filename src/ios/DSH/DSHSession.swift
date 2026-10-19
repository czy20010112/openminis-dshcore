//
//  DSHSession.swift
//  Minis
//
//  Durable conversation surface, ported from DeepSeek Harness
//  (packages/session — surface nodes, replace semantics, tool-pairing balance).
//
//  WHY THIS EXISTS
//  ---------------
//  OpenMinis' agent loop addressed conversation entries by bare `Int` index into
//  a mutable array (`agentHistory[i]`, `messages[msgIdx]`). Everything that
//  mutated that array mid-turn — in-loop compaction's divider insert, an iCloud
//  sync's wholesale rebuild, a user delete — silently invalidated every index a
//  running loop held. The failure mode was subtle rather than loud: the loop
//  kept streaming into a detached `ChatMessage`, so the UI froze on the last
//  rendered block while the database kept advancing.
//
//  The accumulated fix was a resync at every subscript site: re-anchor by stable
//  id, else adopt the trailing assistant, else append a fresh one. Each site is
//  individually correct and collectively fragile, because a new array mutation
//  needs a new resync at every site that could observe it.
//
//  DSH removes the class of bug instead of patching it:
//
//  - The log is append-only. Entries are never moved, replaced, or removed.
//  - Every entry carries a monotonic `seq` assigned once at append time.
//  - Compaction does not mutate the log. It appends a summary event that SHADOWS
//    a positional range, and the surface is the log read through the current
//    shadow set. A running loop therefore cannot observe a mutation: the entries
//    it holds seqs for still exist, unchanged.
//  - Cut positions are validated for tool-pairing balance, so a compaction can
//    never strand a tool call without its result — the provider-level 400 that
//    OpenMinis patched separately with an "orphan tool_use" scan.
//
//  This module is the Swift port of that model. It is deliberately independent
//  of UIKit and of OpenMinis' ChatStore: it owns the conversation's identity and
//  ordering, nothing else.
//

import Foundation

// MARK: - Sequence Number

/// Monotonic per-surface sequence number, assigned once when an entry is
/// appended and never reused.
///
/// Branded in DSH as an opaque id. Here it is a plain `Int` with a dedicated
/// type so it cannot be passed where an array offset is expected — the exact
/// confusion that produced the index-drift bugs.
public struct DSHSeq: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let value: Int

    public init(_ value: Int) {
        precondition(value > 0, "seq must be positive; 0 is reserved for 'none'")
        self.value = value
    }

    public static func < (lhs: DSHSeq, rhs: DSHSeq) -> Bool { lhs.value < rhs.value }
    public var description: String { "#\(value)" }
}

// MARK: - Log Entry

/// One durable entry in the conversation log.
///
/// Entries are immutable once appended. A compaction never rewrites one: it
/// shadows a positional range, and the surface is derived.
public struct DSHLogEntry: Sendable, Identifiable {
    public let seq: DSHSeq
    public let message: DSHMessage
    /// Turn this entry belongs to, or nil for a standalone bracket.
    public let turn: Int?
    /// Set when this entry is a compaction summary that shadows a range.
    public let shadows: ClosedRange<DSHSeq>?
    /// Set when this entry is a tool-result PRUNE replacement rather than a
    /// compaction summary.
    ///
    /// [T-dsh-tool-result-prune] A prune shadows exactly one node — itself — and
    /// its message is that node's result with a bounded middle, not a summary.
    /// The two are alike in the only way the fold cares about (a range taken out
    /// of the surface, this entry put where its first node was) and unlike in
    /// every way the rest of the app cares about: a summary is materialised as a
    /// `<context-summary>` entry, is the subject of a compaction marker, and is
    /// revertible by `revertLastCompaction()`. None of that is true of a prune,
    /// so the distinction is carried on the entry rather than inferred from
    /// `shadows`.
    public let isPrune: Bool

    public init(
        seq: DSHSeq,
        message: DSHMessage,
        turn: Int?,
        shadows: ClosedRange<DSHSeq>? = nil,
        isPrune: Bool = false
    ) {
        self.seq = seq
        self.message = message
        self.turn = turn
        self.shadows = shadows
        self.isPrune = isPrune
    }

    public var id: Int { seq.value }
}

// MARK: - Compaction Events

/// A recorded compaction, kept so the operation is replayable and revertible.
public struct DSHCompactionRecord: Sendable {
    public let seq: DSHSeq
    /// Positional span this summary shadows.
    public let shadowedRange: ClosedRange<DSHSeq>
    /// Estimated token count of the shadowed content.
    public let shadowedTokenCount: Int
    /// The model that wrote the summary.
    public let model: String
    /// The provider route that wrote the summary.
    public let provider: String
    /// Whether the bracket closed cleanly.
    public let completed: Bool

    public init(
        seq: DSHSeq,
        shadowedRange: ClosedRange<DSHSeq>,
        shadowedTokenCount: Int,
        model: String,
        provider: String,
        completed: Bool
    ) {
        self.seq = seq
        self.shadowedRange = shadowedRange
        self.shadowedTokenCount = shadowedTokenCount
        self.model = model
        self.provider = provider
        self.completed = completed
    }
}

// MARK: - Session

/// Append-only conversation log with a derived surface.
///
/// Thread safety: all mutations and reads go through one lock. The lock is held
/// only for the duration of a single append or surface computation, never across
/// an await, so a summarization call cannot interleave with another mutation.
public final class DSHSession: @unchecked Sendable {

    private let lock = NSLock()
    private var log: [DSHLogEntry] = []
    private var nextSeq: Int = 1
    private var compactions: [DSHCompactionRecord] = []
    private var replacements: Int = 0

    public init() {}

    // MARK: - Append

    /// Append one entry and return its assigned seq.
    ///
    /// The only mutating operation. An append never invalidates a seq another
    /// caller already holds, which is what makes concurrent readers safe.
    @discardableResult
    public func append(_ message: DSHMessage, turn: Int?) -> DSHSeq {
        lock.lock()
        defer { lock.unlock() }
        let seq = DSHSeq(nextSeq)
        nextSeq += 1
        log.append(DSHLogEntry(seq: seq, message: message, turn: turn))
        return seq
    }

    /// Append a compaction summary that shadows an inclusive positional range.
    ///
    /// The shadowed entries stay in the log; the surface drops them. Shadowing
    /// is therefore revertible and auditable, unlike an in-place array rewrite.
    @discardableResult
    public func appendCompaction(
        summary: DSHMessage,
        shadows: ClosedRange<DSHSeq>,
        shadowedTokenCount: Int,
        model: String,
        provider: String,
        turn: Int?
    ) -> DSHSeq {
        let seq = appendReplacement(message: summary, shadows: shadows, turn: turn, isPrune: false)
        lock.lock()
        defer { lock.unlock() }
        compactions.append(DSHCompactionRecord(
            seq: seq,
            shadowedRange: shadows,
            shadowedTokenCount: shadowedTokenCount,
            model: model,
            provider: provider,
            completed: true
        ))
        return seq
    }

    /// Append a tool-result PRUNE replacement that shadows the one node it
    /// replaces.
    ///
    /// The same positional replacement a compaction performs — the replacement
    /// takes the place of the node it shadows, which is what makes the model see
    /// the pruned result where the full one was — recorded as a prune rather than
    /// as a compaction. See `DSHLogEntry.isPrune` for why the two must be
    /// distinguishable, and `DSHToolResultPruner` for the rule that produces the
    /// replacement.
    ///
    /// The shadowed original stays in the log, unmodified: pruning is a change to
    /// the projection the model reads, never to the conversation record.
    ///
    /// - Parameters:
    ///   - message: the replacement message — the tool result with a bounded middle.
    ///   - shadows: the single node being replaced.
    ///   - turn: the enclosing turn, or nil for a standalone replacement.
    /// - Returns: the assigned seq of the replacement.
    @discardableResult
    public func appendPrune(
        message: DSHMessage,
        shadows: ClosedRange<DSHSeq>,
        turn: Int? = nil
    ) -> DSHSeq {
        appendReplacement(message: message, shadows: shadows, turn: turn, isPrune: true)
    }

    /// The one place a positional replacement is written to the log.
    ///
    /// Both replacements advance `surfaceReplacementGeneration`, and for the same
    /// reason: that counter is the proof a retry has something new to send. A
    /// pruned surface is exactly such a change — upstream authorizes the
    /// context-overflow retry on `replaceGeneration` alone and records a prune as
    /// a replacement (`compaction-tool-result-pruner/src/index.ts:165-171`,
    /// `surfaceOp: { op: 'replace', startSeq: seq, endSeq: seq }`).
    @discardableResult
    private func appendReplacement(
        message: DSHMessage,
        shadows: ClosedRange<DSHSeq>,
        turn: Int?,
        isPrune: Bool
    ) -> DSHSeq {
        lock.lock()
        defer { lock.unlock() }
        let seq = DSHSeq(nextSeq)
        nextSeq += 1
        log.append(DSHLogEntry(
            seq: seq, message: message, turn: turn, shadows: shadows, isPrune: isPrune
        ))
        replacements += 1
        return seq
    }

    /// Monotonic count of committed surface replacements.
    ///
    /// DSH's `surface.replaceGeneration`. A caller that reacted to a failed
    /// request by compacting has to prove the surface actually moved before it
    /// retries: without that proof the retry re-sends a request that was already
    /// rejected, and the pair of them repeat for as long as the caller is
    /// willing to loop. Append-only growth does not advance this — only a
    /// replacement that shadows a range does, which is exactly the change a retry
    /// depends on.
    ///
    /// [T-dsh-tool-result-prune] A tool-result prune counts, and it has to:
    /// upstream authorizes the context-overflow retry on this generation alone and
    /// lands its prunes as `surfaceOp: { op: 'replace' }`
    /// (`compaction-basic/src/index.ts:302` — "A model-free prune can land before
    /// later summary work fails. That durable reduction is sufficient retry
    /// proof"). Without that, a turn whose prune relieved the overflow would
    /// refuse to retry and end on the provider's error.
    public var surfaceReplacementGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return replacements
    }

    // MARK: - Redrive

    /// Drop every entry after `seq`, and any compaction whose summary or
    /// shadowed range went with it.
    ///
    /// This is the one place the log is not append-only, and it exists for one
    /// reason: a retry or a resume asks for a turn to be produced *again*, so the
    /// incomplete tail of the previous attempt has to go. It is safe only because
    /// no loop is running when it is called — a held seq would dangle, which is
    /// precisely the failure mode the append-only log exists to remove.
    ///
    /// `nextSeq` is deliberately not rewound: seqs stay unique for the life of
    /// the session, so a stale one can never be mistaken for a reused one.
    ///
    /// - Parameter seq: keep entries up to and including this seq. `nil` clears
    ///   the log.
    /// - Returns: how many entries were dropped.
    @discardableResult
    public func truncate(after seq: DSHSeq?) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = seq?.value ?? 0
        let before = log.count
        log.removeAll { $0.seq.value > cutoff }
        compactions.removeAll {
            $0.seq.value > cutoff || $0.shadowedRange.upperBound.value > cutoff
        }
        return before - log.count
    }

    /// The seq of the newest user turn, or nil when the log has none.
    ///
    /// A redrive has to leave the surface ending on the user's own message:
    /// everything the previous attempt appended after it — assistant text, tool
    /// calls, tool results — is what is being retried.
    public func lastUserSeq() -> DSHSeq? {
        lock.lock()
        defer { lock.unlock() }
        return log.last { $0.message.role == .user }?.seq
    }

    // MARK: - Read

    /// Every log entry, in append order. Includes shadowed entries.
    public func allEntries() -> [DSHLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    /// The entry carrying `seq`, or nil when it is not in the log.
    public func entry(at seq: DSHSeq) -> DSHLogEntry? {
        lock.lock()
        defer { lock.unlock() }
        return log.first { $0.seq == seq }
    }

    /// The current surface: the log read through the active shadow set.
    ///
    /// [T-dsh-surface-replace-position] A summary entry takes the POSITION of the
    /// range it shadows — it is a replacement copy, not an append. That is the
    /// semantics the surface fold implements upstream, and the difference is
    /// visible rather than cosmetic:
    ///
    ///   * `foldSurface` applies a replace as
    ///     `nodes.splice(startIdx, endIdx - startIdx + 1, seq)`
    ///     (`packages/core/session/src/surface.ts`), i.e. the summary lands AT the
    ///     range's first position; the compaction transaction appends its
    ///     checkpoint with `surfaceOp: { op: 'replace', startSeq, endSeq }`
    ///     (`packages/compaction/compaction-basic/src/region.ts`,
    ///     `commitCompactionBody`). The log keeps the summary at the tail; the
    ///     MODEL-VISIBLE surface puts it where the shadowed range was.
    ///   * Appending it at the summary entry's own log position instead pins the
    ///     summary to the end of the conversation on every read, so the messages
    ///     after it (which the surface really does keep) sort BEFORE it. On the
    ///     device this showed up as the summary being pushed down into the newest
    ///     position on each of a turn's compactions, and as a compaction that
    ///     re-eats the same entries: the next range always starts at surface node
    ///     `firstIdx`, so it consumed the previous summary plus the tail again,
    ///     which is why one long turn compacted five times for a ~34k-token step
    ///     each time instead of once.
    ///
    /// The position is derived by replaying the log the way `foldSurface` reads it,
    /// which is a single pass in seq order: each message-producing entry joins the
    /// surface, and a summary takes the range it names out of the surface and puts
    /// itself where the first of those entries was —
    /// `nodes.splice(startIdx, endIdx - startIdx + 1, seq)`
    /// (`packages/core/session/src/surface.ts`, `applySurfacePlan`).
    ///
    /// A replacement's own node stays in the surface, so a later range can name it.
    /// Upstream's own regression test is exactly that case — two appends, a
    /// replacement of node 0, then a replacement of nodes 2…1 — and the surface it
    /// asserts is `[3]`: the second replacement swallowed the first summary as well
    /// as the entry it replaced (`packages/core/session/tests/surface.spec.ts`,
    /// "shares ordered entries and nested replacement ranges with foldSurface").
    /// That is what keeps DSH's cumulative summaries one line.
    ///
    /// Walking the log in order rather than collecting replacements first is also
    /// what makes the range lookup work: the entries a compaction replaces are
    /// appended to the log before its own summary, so they are already in the
    /// surface by the time the summary is reached.
    public func surface() -> [DSHLogEntry] {
        lock.lock()
        defer { lock.unlock() }

        // Replay the log in seq order, exactly as `foldSurface` does: a
        // message-producing entry joins the surface, and a replacement takes the
        // range it names out of the surface and puts itself where the first of those
        // entries was — `nodes.splice(startIdx, endIdx - startIdx + 1, seq)`
        // (`packages/core/session/src/surface.ts`, `applySurfacePlan`).
        //
        // A replacement's own node stays in the surface, so a later range can name it
        // as well as the entries under it. That is what makes a cumulative summary
        // one line: the newer range covers the previous summary's position, and the
        // splice takes it out.
        var nodes: [DSHLogEntry] = []
        for entry in log {
            guard let range = entry.shadows else {
                nodes.append(entry)
                continue
            }
            // Both ends of the range, by identity. A range is only ever selected from
            // the surface it is compacting, so both are present in every real
            // compaction; a range that names a position this surface does not hold is
            // dropped rather than placed, because a summary pinned anywhere but where
            // its range was is the defect this method exists to remove.
            // [T-dsh-compact-no-range]
            guard let startIdx = nodes.firstIndex(where: { $0.seq == range.lowerBound }),
                  let endIdx = nodes.firstIndex(where: { $0.seq == range.upperBound }) else {
                continue
            }
            let from = min(startIdx, endIdx)
            let to = max(startIdx, endIdx)
            nodes.replaceSubrange(from...to, with: [entry])
        }
        return nodes
    }

    /// The surface's messages, ready to project into a provider request.
    public func surfaceMessages() -> [DSHMessage] {
        surface().map(\.message)
    }

    /// Recorded compactions, oldest first.
    public func compactionHistory() -> [DSHCompactionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return compactions
    }

    /// Number of log entries, including shadowed ones.
    public var logCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return log.count
    }

    /// Number of surface entries.
    public var surfaceCount: Int {
        surface().count
    }

    /// Drop every entry, resetting the seq counter.
    ///
    /// Only for a wholesale session reset. A running loop must not call this:
    /// its held seqs would dangle, which is exactly the failure mode this module
    /// exists to prevent.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        log.removeAll()
        compactions.removeAll()
        nextSeq = 1
    }

    // MARK: - Compaction Revert

    /// Undo the most recent completed compaction, restoring its shadowed range.
    ///
    /// A tool-result prune is NOT a compaction and is skipped by name
    /// (`DSHLogEntry.isPrune`): it has no `DSHCompactionRecord` and no store-side
    /// marker, so reverting one would delete a replacement the marker database
    /// knows nothing about and report a `nil` record to a caller that has already
    /// deleted that row.
    ///
    /// - Returns: the reverted record, or nil when there is nothing to revert.
    @discardableResult
    public func revertLastCompaction() -> DSHCompactionRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = log.lastIndex(where: { $0.shadows != nil && !$0.isPrune }) else {
            return nil
        }
        let entry = log[index]
        // Remove the summary entry itself; its shadowed range returns to the
        // surface because no remaining entry shadows it.
        log.remove(at: index)
        return compactions.last { $0.seq == entry.seq }
    }
}

// MARK: - Tool-Pairing Balance

/// Tool-pairing balance over a surface.
///
/// A compaction cut must never separate a tool call from its result: the
/// provider rejects the request outright. OpenMinis patched this with a
/// pre-send "orphan tool_use" scan that injected placeholder results; here the
/// cut position itself is validated, so an unbalanced cut is never selected.
public enum DSHToolPairing {

    /// Balance of every cut in a surface: entry `i` is the cut before surface
    /// node `i`, and the final entry is the cut after the tail.
    ///
    /// A cut is balanced when no unanswered tool call crosses it.
    public static func cutBalances(_ surface: [DSHLogEntry]) -> [Bool] {
        var balances: [Bool] = [true]   // the cut before node 0
        var inProgress = 0
        for entry in surface {
            for block in entry.message.blocks {
                if block is DSHToolCallBlock { inProgress += 1 }
                else if let result = block as? DSHToolResultBlock {
                    // A result without its call means the surface is already
                    // corrupt; treat the cut as unbalanced rather than
                    // silently accepting a request the provider will reject.
                    if inProgress == 0 { balances.append(false); continue }
                    inProgress -= 1
                }
            }
            balances.append(inProgress == 0)
        }
        return balances
    }

    /// Whether the cut immediately before surface index `index` is balanced.
    public static func balancedBefore(surface: [DSHLogEntry], index: Int) -> Bool {
        let balances = cutBalances(surface)
        guard index >= 0 && index < balances.count else { return false }
        return balances[index]
    }

    /// Nearest balanced cut at or before `index`, or nil when none exists.
    ///
    /// Used to walk a candidate cut back to a safe position without stranding a
    /// tool call.
    public static func nearestBalancedBefore(surface: [DSHLogEntry], index: Int) -> Int? {
        let balances = cutBalances(surface)
        var candidate = index
        while candidate >= 0 {
            if candidate < balances.count && balances[candidate] { return candidate }
            candidate -= 1
        }
        return nil
    }
}
