//
//  DSHCompactBoundary.swift
//  Minis
//
//  Where a persisted compaction marker puts the transcript divider, and how much
//  of the transcript it greys — decided in one place, with no view state.
//
//  WHY THIS IS A SEPARATE, PURE TYPE
//  ---------------------------------
//  The reload path that restores a compaction record lived inline in
//  `AIChatViewModel+Persistence` (Phase 2.5), spread over four nested branches
//  that each reassigned `insertIdx` and a free-form `boundaryResolutionPath`
//  string. Two of its failure modes are indistinguishable from the outside:
//
//    * "the divider is there and the replaced rows are greyed"   — correct;
//    * "the divider is there and nothing is greyed"              — insertIdx 0;
//    * "there is no divider at all"                              — the caller
//      never reached the insert because the marker could not be resolved.
//
//  The operator reported the third one on a device ("重新打开对话，压缩的记录没了,
//  压缩之前的对话的 toolcall 的条一个都没了"), and from the rendered transcript it
//  is indistinguishable from "no marker was ever written". A resolver that
//  always returns a decision, that names the decision it made, and that can be
//  run against a real fixture outside the app is what makes those two cases
//  separable — and it is what lets a decision of "put the divider at the top and
//  grey nothing" be a REPORTED outcome rather than a silent one.
//
//  The marker shapes themselves are NOT redefined here. `CompactMarker` (the
//  store's row) and `RawMessage` / `ChatMessage` (the app's own types) are the
//  inputs; this file only decides positions, and it takes them as plain values
//  so it compiles without UIKit, SwiftUI, or the store.
//
//  THREE RULES THIS FILE NOW ENFORCES (F3, 2026-10-18)
//  ---------------------------------------------------
//  1. A DEGRADED anchor is never trusted. A marker whose anchor is a position
//     rather than a store row (`anchorIsDegraded`) resolves on the kept tail, not
//     through a clock-based guess — see branch 0 below.
//  2. A clock-based heal NEVER names the transcript's last row. That heal used to
//     fire for every degraded marker (the marker's `createdAt` is later than every
//     row it covers, so "the newest row older than the marker" is the newest row,
//     always), which put the divider at the bottom and greyed the WHOLE transcript
//     — live rows included. It looked like a correct restore in the log.
//  3. The divider POSITION is conservative; the DIMMING is exact. A UI row is a
//     merged run of raw rows (`AIChatViewModel+Persistence` Phase 2), so the
//     anchor routinely lands in the middle of one bubble. The divider is still
//     placed by ROW: this resolver never puts it after a bubble the marker only
//     reached into, so it can lag the anchor by the rest of that bubble. Dimming
//     is no longer row-granular — it is BLOCK-first, with the row as the floor:
//
//       * the view dims each block on `isCompactedHistory || block.isCompactedHistory`
//         (`CollectionViewMessageListV3`, the block's `.opacity(...)`), so both
//         flags reach the same pixel exactly once;
//       * the caller marks the exact blocks at or below the anchor from
//         `ChatMessage.blockSortOrders` through `compactedBlockIndices` below
//         (`AIChatViewModel+Persistence`, [F4-compaction-visibility]), which is
//         what makes a mid-bubble anchor dim the blocks it really covers;
//       * the per-row flag is the FALLBACK for a row that carries no per-block
//         provenance (a live row, or a caller not yet taught to fill it): such a
//         row is one opaque unit and none of it is ever claimed.
//
//     `grayedBlockCount` / `uiGrayedBlockCount` keep reporting both answers — the
//     blocks the marker covers and the blocks the caller's loop will dim — so a
//     divergence between them is a visible number instead of a guess.
//
//  Both trees carry this file byte-identically (it is under `src/ios/DSH/`), so
//  the ios15 and ios26 builds cannot drift in where the divider lands.
//

import Foundation

// MARK: - Inputs

/// One raw row, reduced to what the boundary decision reads.
///
/// Bound from `RawMessage` by the caller: `id` is its database id, `sortOrder`
/// its persisted order, `createdAt` the clock that survives a re-index.
public struct DSHCompactRawRow: Equatable {
    public let id: String
    public let sortOrder: Int
    public let createdAt: Date
    public let role: String
    public let hasText: Bool
    public let isToolResultOnly: Bool

    public init(
        id: String,
        sortOrder: Int,
        createdAt: Date,
        role: String,
        hasText: Bool,
        isToolResultOnly: Bool
    ) {
        self.id = id
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.role = role
        self.hasText = hasText
        self.isToolResultOnly = isToolResultOnly
    }
}

/// One UI row (Phase 2's output), reduced to the same facts.
///
/// `firstSortOrder`/`lastSortOrder` are the inclusive range Phase 2 folded into
/// this row: a multi-row assistant turn becomes ONE UI row whose range spans
/// every raw row it swallowed, so an anchor that landed mid-run still maps back
/// to it.
public struct DSHCompactUIRow: Equatable {
    public let firstSortOrder: Int?
    public let lastSortOrder: Int?
    public let role: String
    public let hasText: Bool
    /// The `sortOrder` of the raw row that produced each block, in block order.
    ///
    /// A UI row is a MERGE of one or more raw rows, so `first...last` says which
    /// raw rows a bubble covers but not which BLOCK came from which. Without that
    /// the question "how much of this bubble is at or below the anchor" can only
    /// be answered as "the whole bubble or none of it", which is the over-claim
    /// the block-level accounting exists to expose: on a device session Phase 2
    /// folded 231 database rows into 15 UI rows, so a mid-run anchor is the norm,
    /// not the exception.
    ///
    /// Empty means "the caller has no per-block information" (a live row, or a
    /// caller not yet taught to fill it): the row is then treated as one opaque
    /// unit and none of it is ever claimed as compacted.
    public let blockSortOrders: [Int]

    public init(
        firstSortOrder: Int?,
        lastSortOrder: Int?,
        role: String,
        hasText: Bool,
        blockSortOrders: [Int] = []
    ) {
        self.firstSortOrder = firstSortOrder
        self.lastSortOrder = lastSortOrder
        self.role = role
        self.hasText = hasText
        self.blockSortOrders = blockSortOrders
    }

    /// Blocks this row renders.
    public var blockCount: Int { blockSortOrders.count }

    /// Blocks at or below `sortOrder` — the exact count, from per-block data.
    public func blocksAtOrBelow(_ sortOrder: Int) -> Int {
        blockSortOrders.reduce(0) { $0 + ($1 <= sortOrder ? 1 : 0) }
    }
}

/// A persisted compaction marker, reduced to the fields the boundary reads.
///
/// `version` matters: a v2 marker resolves ONLY through `lastCompactedMessageId`
/// (the legacy sort-order fields were written as past-end sentinels and reading
/// them back as real boundaries points at a coincidental row). A v3 marker
/// records the same id-only shape but with an anchor that is a POSITION rather
/// than a store row — see `isDegradedAnchor`.
public struct DSHCompactMarkerFacts: Equatable {
    public let version: Int
    public let firstKeptMessageId: String?
    public let boundaryMessageId: String?
    public let lastCompactedMessageId: String?
    public let firstKeptSortOrder: Int
    public let compactedCount: Int
    public let createdAt: Date

    public init(
        version: Int,
        firstKeptMessageId: String?,
        boundaryMessageId: String?,
        lastCompactedMessageId: String?,
        firstKeptSortOrder: Int,
        compactedCount: Int,
        createdAt: Date
    ) {
        self.version = version
        self.firstKeptMessageId = firstKeptMessageId
        self.boundaryMessageId = boundaryMessageId
        self.lastCompactedMessageId = lastCompactedMessageId
        self.firstKeptSortOrder = firstKeptSortOrder
        self.compactedCount = compactedCount
        self.createdAt = createdAt
    }

    /// Marker version at which `lastCompactedMessageId` stops naming a store row.
    ///
    /// A DSH compaction whose shadowed range reaches into rows the turn has not
    /// persisted yet has no database id to anchor on. The record must still be
    /// written (a lost record is unrecoverable, see `dshWriteCompactionMarker`),
    /// so it is written as a POSITION and marked with this version. The value
    /// shares `lastCompactedMessageId` with v2 on purpose — one column, no
    /// migration — and any id left in it keeps whatever was known at write time,
    /// for diagnostics. NOTHING on such a marker is a position: the forward
    /// boundary fields are ignored too, because the version means "no anchor".
    public static let degradedAnchorVersion = 3

    /// True when this marker's anchor is a position, not a store row.
    public var isDegradedAnchor: Bool {
        version >= DSHCompactMarkerFacts.degradedAnchorVersion
    }

    /// The shape every DSH compaction writes (`dshWriteCompactionMarker`): no
    /// forward boundary, so the marker is anchored by `lastCompactedMessageId`
    /// alone. Named because the legacy sort-order fallback must be SKIPPED for
    /// it — `firstKeptSortOrder` is 0 for these markers and reading it as a
    /// boundary would grey nothing.
    public var isCompactAllShape: Bool {
        firstKeptMessageId == nil && boundaryMessageId == nil && lastCompactedMessageId != nil
    }

    /// Whether the marker carries a usable forward boundary at all. A marker
    /// with neither a forward boundary nor a backward anchor describes no
    /// range, and no position can be derived from it.
    ///
    /// A degraded marker DOES describe a range — it just cannot name its right
    /// edge — so it must not take the "describes no range" branch.
    public var describesARange: Bool {
        firstKeptMessageId != nil
            || boundaryMessageId != nil
            || lastCompactedMessageId != nil
            || version < 2
            || isDegradedAnchor
    }
}

// MARK: - Outputs

/// Where the divider goes and how it was decided.
public struct DSHCompactBoundaryDecision: Equatable {
    /// Index the divider is inserted at. Everything BELOW it stays active.
    public let insertIndex: Int
    /// The decision's own name, so a device log says which branch ran instead of
    /// leaving "no divider" and "divider greyed nothing" to look alike.
    public let resolutionPath: String
    /// Database id the marker resolved to, when a real anchor was found.
    public let resolvedAnchorId: String?
    /// True when the marker was rewritten and has to be written back.
    public let healedMarkerAnchorId: String?
    /// True when the position did NOT come from the marker's own anchor.
    ///
    /// This is the flag the reload path warns on. Before it existed, a marker
    /// whose anchor named no store row resolved through a clock-based guess to
    /// the transcript's LAST row — divider at the bottom, every row greyed — and
    /// because that state greys something it was reported as a correct restore.
    public let degradedAnchor: Bool
    /// Blocks the marker says are compacted (exact, from per-block data).
    public let grayedBlockCount: Int
    /// Blocks the caller's message-granular greying loop will actually grey.
    ///
    /// Always `<= grayedBlockCount`: when the anchor lands inside a merged
    /// bubble, that bubble is left active rather than greyed whole. The two
    /// numbers are reported so "the tail the model still sees was dimmed" is a
    /// measurement rather than an inference.
    public let uiGrayedBlockCount: Int

    public init(
        insertIndex: Int,
        resolutionPath: String,
        resolvedAnchorId: String?,
        healedMarkerAnchorId: String? = nil,
        degradedAnchor: Bool = false,
        grayedBlockCount: Int = 0,
        uiGrayedBlockCount: Int = 0
    ) {
        self.insertIndex = insertIndex
        self.resolutionPath = resolutionPath
        self.resolvedAnchorId = resolvedAnchorId
        self.healedMarkerAnchorId = healedMarkerAnchorId
        self.degradedAnchor = degradedAnchor
        self.grayedBlockCount = grayedBlockCount
        self.uiGrayedBlockCount = uiGrayedBlockCount
    }

    /// Whether any row is greyed by this decision.
    public var greysAnything: Bool { insertIndex > 0 }

    /// Blocks greyed that the marker does NOT cover. Must stay 0: dimming rows
    /// the model still sees is the failure this decision refuses to make.
    public var overClaimedBlockCount: Int {
        max(0, uiGrayedBlockCount - grayedBlockCount)
    }

    /// Compacted blocks the caller shows as live because the anchor landed in
    /// the middle of a merged bubble.
    public var deferredBlockCount: Int {
        max(0, grayedBlockCount - uiGrayedBlockCount)
    }

    /// True when the divider sits at the end of the transcript, i.e. every row is
    /// inside the greyed region.
    public func greysEverything(uiRowCount: Int) -> Bool {
        uiRowCount > 0 && insertIndex >= uiRowCount
    }
}

// MARK: - Resolver

/// Resolve where a marker's divider goes in the restored transcript.
///
/// Returns ALWAYS. Every failure mode except "the marker describes no range at
/// all" produces a decision, because the three outcomes a user can see — the
/// record is gone, the record is there with nothing greyed, the record is there
/// and correct — have to be distinguishable and each has to be intentional.
///
/// The answer is always a position INSIDE the transcript: `insertIndex` is
/// clamped to `0...uiRows.count`, so the caller's `insert(at:)` and its
/// `0..<insertIndex` greying loop can never index out of bounds.
///
/// Order, and why:
///
///   0. **Degraded marker** (`anchorIsDegraded`, version 3): the compaction
///      happened and the record must be restored, but its anchor names a
///      position rather than a row, so there is nothing to look up. Go straight
///      to the kept tail — a clock-based guess would name the newest row (the
///      marker is written after it) and grey everything.
///   1. **Forward boundary** (`firstKeptMessageId` → `boundaryMessageId`), when
///      it is a row the transcript really holds. A marker that names the first
///      row it KEPT is exact: the divider goes immediately before it. This is
///      the shape `compactBefore` writes.
///   2. **v2 anchor** (`lastCompactedMessageId`): the divider goes immediately
///      AFTER the anchor row — or immediately BEFORE its UI row when the anchor
///      is mid-bubble, because a bubble is the smallest thing the view can grey.
///      That is the `compactAll` shape the DSH path writes.
///   3. **Anchor by `createdAt`**: the newest raw row that predates the marker
///      — the same self-heal `anchorByCreatedAt` performs, and the only repair
///      available when the anchor's row was deleted or re-indexed. Applied to
///      v2/compactAll markers only; a legacy marker with a readable sort-order
///      boundary is not rewritten. REFUSED when it names the transcript's last
///      row: that is the shape of a guess, not of a repair (see rule 2 at the
///      top of this file).
///   4. **Kept tail**: the last `keepRecentUserTurns` user rows stay active and
///      everything above them is greyed. Not exact, but monotone: it never
///      claims MORE is active than the marker compacted beyond, so no row the
///      marker covered is presented as live context.
///   5. **Top, nothing greyed**: only when the transcript is empty or the marker
///      describes no range. Reported by name, so it is a symptom rather than a
///      silent no-op.
public enum DSHCompactBoundary {

    /// Recent user turns kept active by the last-resort fallback.
    public static let keepRecentUserTurns = 3

    /// The block indices a compaction covers inside ONE row.
    ///
    /// [F4-compaction-visibility] `DSHCompactUIRow.blocksAtOrBelow` counts the
    /// covered blocks; this names them, because the count is a report and the
    /// transcript has to know WHICH blocks to dim.
    ///
    /// It is the same predicate, applied to the same per-block provenance, so the
    /// number the decision logs and the number of dimmed blocks cannot disagree.
    /// A row with no provenance returns nothing: it is one opaque unit, and the
    /// resolver already refuses to claim any of it.
    ///
    /// - Parameters:
    ///   - blockSortOrders: `sortOrder` of the raw row that produced each block,
    ///     in block order (`ChatMessage.blockSortOrders`).
    ///   - anchorSortOrder: `sortOrder` of the raw row the marker names as the last
    ///     COMPACTED one. Everything at or below it is compacted history.
    public static func compactedBlockIndices(
        blockSortOrders: [Int],
        anchorSortOrder: Int
    ) -> [Int] {
        blockSortOrders.enumerated().compactMap { $0.element <= anchorSortOrder ? $0.offset : nil }
    }

    public static func resolve(
        marker: DSHCompactMarkerFacts,
        rawRows: [DSHCompactRawRow],
        uiRows: [DSHCompactUIRow],
        historyDbIds: Set<String>,
        keepRecentUserTurns: Int = DSHCompactBoundary.keepRecentUserTurns
    ) -> DSHCompactBoundaryDecision {
        clamp(resolveUnclamped(
            marker: marker,
            rawRows: rawRows,
            uiRows: uiRows,
            historyDbIds: historyDbIds,
            keepRecentUserTurns: keepRecentUserTurns
        ), uiRows: uiRows)
    }

    /// Keep every answer inside the transcript the caller is about to splice into.
    private static func clamp(
        _ decision: DSHCompactBoundaryDecision,
        uiRows: [DSHCompactUIRow]
    ) -> DSHCompactBoundaryDecision {
        let bounded = min(max(0, decision.insertIndex), uiRows.count)
        guard bounded != decision.insertIndex else { return decision }
        return DSHCompactBoundaryDecision(
            insertIndex: bounded,
            resolutionPath: decision.resolutionPath,
            resolvedAnchorId: decision.resolvedAnchorId,
            healedMarkerAnchorId: decision.healedMarkerAnchorId,
            degradedAnchor: decision.degradedAnchor,
            grayedBlockCount: decision.grayedBlockCount,
            uiGrayedBlockCount: decision.uiGrayedBlockCount
        )
    }

    private static func resolveUnclamped(
        marker: DSHCompactMarkerFacts,
        rawRows: [DSHCompactRawRow],
        uiRows: [DSHCompactUIRow],
        historyDbIds: Set<String>,
        keepRecentUserTurns: Int
    ) -> DSHCompactBoundaryDecision {

        // A marker that names no range at all cannot place a divider anywhere
        // meaningful. Say so rather than pretending the top is a boundary.
        guard marker.describesARange else {
            return unboundedDecision(
                insertIndex: 0,
                resolutionPath: "markerDescribesNoRange",
                resolvedAnchorId: nil,
                uiRows: uiRows
            )
        }
        guard !uiRows.isEmpty else {
            return DSHCompactBoundaryDecision(
                insertIndex: 0,
                resolutionPath: "emptyTranscript",
                resolvedAnchorId: nil
            )
        }

        let rawById = Dictionary(rawRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let uiIndexBySortOrder = uiIndexMap(uiRows)

        // ── 0. Degraded marker ─────────────────────────────────────────────
        //
        // The anchor is a position, not a store row. Nothing here can be looked
        // up, so the honest answer is the kept tail — the same tail
        // `effectiveAgentHistory()` keeps for such a marker, so the transcript's
        // greyed region and the model's view of it agree. Explicitly NOT the
        // clock heal: see rule 2 at the top of this file.
        //
        // [T-dsh-compact-kept-head] THIS RULE STAYS AHEAD OF RULE 1, and that is a
        // decision rather than an oversight. A v3 marker may well carry a
        // `firstKeptMessageId` that is not its own: `ChatStore`'s legacy upgrade
        // (`repairSessionIfNeeded`, run on every session open) fills that column into
        // any marker whose two id columns are NULL — which is exactly a degraded one —
        // out of `firstKeptSortOrder`, a column DSH markers write as 0, i.e. the
        // session's FIRST row. Reading that as a forward boundary would put the
        // divider at the top of the transcript and grey nothing, which is the
        // "restored nothing" state this file exists to make impossible.
        //
        // The writer therefore does not mark a record v3 when it HAS a forward
        // boundary of its own (`dshWriteCompactionMarker`: `positionOnly`), rather
        // than this resolver being taught to prefer a field a repair can forge.
        if marker.isDegradedAnchor {
            return tailDecision(
                marker: marker,
                uiRows: uiRows,
                keepRecentUserTurns: keepRecentUserTurns,
                degradedAnchor: true
            )
        }

        // ── 1. Forward boundary ────────────────────────────────────────────
        //
        // `firstKeptMessageId` is the authoritative name when present: it is the
        // first row the compaction KEPT, so the divider sits immediately before
        // its UI row.
        if let id = marker.firstKeptMessageId ?? marker.boundaryMessageId,
           rawById[id] != nil {
            let path = marker.firstKeptMessageId == id ? "firstKeptMessageId" : "boundaryMessageId"
            if let idx = uiIndex(forRawId: id, rawById: rawById, uiIndexBySortOrder: uiIndexBySortOrder) {
                return unboundedDecision(
                    insertIndex: idx,
                    resolutionPath: path,
                    resolvedAnchorId: id,
                    uiRows: uiRows
                )
            }
            // The named row exists but Phase 2 gave no UI row its sort order —
            // fall through to the anchor ladder rather than greying nothing.
        }

        // ── 2/3. The backward anchor, exact then repaired ──────────────────
        if let lcmId = marker.lastCompactedMessageId {
            if let raw = rawById[lcmId],
               let idx = uiIndexBySortOrder[raw.sortOrder] {
                return anchoredDecision(
                    anchorRow: raw,
                    anchorRowIndex: idx,
                    resolutionPath: marker.version >= 2 ? "v2(lcmId)" : "compactAll(lastCompactedMessageId)",
                    resolvedAnchorId: lcmId,
                    healedMarkerAnchorId: nil,
                    uiRows: uiRows
                )
            }
            // The anchor's row is gone (deleted, or re-indexed by a sync
            // migration). Rebuild it from the clock, which survives both — but
            // only when the rebuild names something OLDER than the newest row.
            // A heal that names the newest row claims the whole transcript was
            // replaced, which is exactly what a degraded anchor produces, and its
            // failure mode is indistinguishable from a correct restore.
            if let heal = anchorByCreatedAt(
                rawRows: rawRows,
                markerCreatedAt: marker.createdAt,
                historyDbIds: historyDbIds
            ), !namesNewestRow(heal, rawRows: rawRows),
               let idx = uiIndexBySortOrder[heal.sortOrder] {
                return anchoredDecision(
                    anchorRow: heal,
                    anchorRowIndex: idx,
                    resolutionPath: marker.version >= 2
                        ? "v2(orphan→healByCreatedAt)"
                        : "compactAll(orphanedLcm→healByCreatedAt)",
                    resolvedAnchorId: lcmId,
                    healedMarkerAnchorId: heal.id,
                    uiRows: uiRows
                )
            }
        }

        // ── 3b. Legacy sort-order boundary ─────────────────────────────────
        //
        // Skipped for the compactAll shape: those markers wrote
        // `firstKeptSortOrder` as a past-end sentinel, and reading it back after
        // the session has grown names a coincidental row.
        if !marker.isCompactAllShape, marker.version < 2 {
            if let raw = rawRows.first(where: { $0.sortOrder >= marker.firstKeptSortOrder }),
               let idx = uiIndexBySortOrder[raw.sortOrder] {
                return unboundedDecision(
                    insertIndex: idx,
                    resolutionPath: "firstKeptSortOrder(legacy)",
                    resolvedAnchorId: raw.id,
                    uiRows: uiRows
                )
            }
        }

        // ── 4. Kept tail ───────────────────────────────────────────────────
        //
        // Monotone and self-limiting: the tail is active, the prefix is greyed,
        // and the divider records that the session WAS compacted even though the
        // exact boundary is unrecoverable.
        return tailDecision(
            marker: marker,
            uiRows: uiRows,
            keepRecentUserTurns: keepRecentUserTurns,
            degradedAnchor: true
        )
    }

    // MARK: - Decisions

    /// A decision whose position came from no row at all: the divider sits
    /// immediately before `insertIndex`, so nothing inside a bubble is claimed.
    private static func unboundedDecision(
        insertIndex: Int,
        resolutionPath: String,
        resolvedAnchorId: String?,
        uiRows: [DSHCompactUIRow]
    ) -> DSHCompactBoundaryDecision {
        let coverage = blockCoverage(
            insertIndex: insertIndex,
            compactedInsideBoundaryRow: 0,
            uiRows: uiRows
        )
        return DSHCompactBoundaryDecision(
            insertIndex: insertIndex,
            resolutionPath: resolutionPath,
            resolvedAnchorId: resolvedAnchorId,
            healedMarkerAnchorId: nil,
            degradedAnchor: false,
            grayedBlockCount: coverage.exact,
            uiGrayedBlockCount: coverage.greyed
        )
    }

    /// A decision anchored on a raw row that the transcript holds.
    ///
    /// Two shapes, and the difference is the whole of rule 3:
    ///
    ///   * the anchor is the LAST raw row of its UI row → the bubble is entirely
    ///     at or below the anchor, so the divider goes after it and the caller
    ///     greys it whole: exact and greyed agree;
    ///   * the anchor is mid-bubble → the divider goes BEFORE the bubble and the
    ///     bubble stays active. The blocks at or below the anchor are reported as
    ///     `grayedBlockCount` and the (larger) greyed answer is not used, because
    ///     greying the bubble would dim rows the model still sees.
    private static func anchoredDecision(
        anchorRow: DSHCompactRawRow,
        anchorRowIndex idx: Int,
        resolutionPath: String,
        resolvedAnchorId: String?,
        healedMarkerAnchorId: String?,
        uiRows: [DSHCompactUIRow]
    ) -> DSHCompactBoundaryDecision {
        let row = uiRows[idx]
        let rowTail = row.lastSortOrder ?? row.firstSortOrder ?? anchorRow.sortOrder
        let anchorIsRowTail = anchorRow.sortOrder >= rowTail
        let insertIndex = anchorIsRowTail ? idx + 1 : idx
        let compactedInsideRow = anchorIsRowTail ? 0 : row.blocksAtOrBelow(anchorRow.sortOrder)
        let coverage = blockCoverage(
            insertIndex: insertIndex,
            compactedInsideBoundaryRow: compactedInsideRow,
            uiRows: uiRows
        )
        return DSHCompactBoundaryDecision(
            insertIndex: insertIndex,
            resolutionPath: resolutionPath,
            resolvedAnchorId: resolvedAnchorId,
            healedMarkerAnchorId: healedMarkerAnchorId,
            degradedAnchor: false,
            grayedBlockCount: coverage.exact,
            uiGrayedBlockCount: coverage.greyed
        )
    }

    /// The kept-tail rung, shared by the degraded marker and the unresolvable
    /// anchor. Reports itself as degraded in both cases: the position did not
    /// come from the marker's own anchor, and the reload path has to say so.
    private static func tailDecision(
        marker: DSHCompactMarkerFacts,
        uiRows: [DSHCompactUIRow],
        keepRecentUserTurns: Int,
        degradedAnchor: Bool
    ) -> DSHCompactBoundaryDecision {
        let tail = uiAnchorIndexForKeptTail(uiRows: uiRows, keepUserTurns: keepRecentUserTurns)
        guard tail > 0 else {
            let top = unboundedDecision(
                insertIndex: 0,
                resolutionPath: "unresolved→noGray",
                resolvedAnchorId: nil,
                uiRows: uiRows
            )
            return DSHCompactBoundaryDecision(
                insertIndex: top.insertIndex,
                resolutionPath: top.resolutionPath,
                resolvedAnchorId: top.resolvedAnchorId,
                healedMarkerAnchorId: nil,
                degradedAnchor: degradedAnchor,
                grayedBlockCount: top.grayedBlockCount,
                uiGrayedBlockCount: top.uiGrayedBlockCount
            )
        }
        let coverage = blockCoverage(
            insertIndex: tail,
            compactedInsideBoundaryRow: 0,
            uiRows: uiRows
        )
        return DSHCompactBoundaryDecision(
            insertIndex: tail,
            resolutionPath: marker.version >= 2
                ? "v2(orphan→tailAnchor)"
                : "compactAll(orphanedLcm→tailAnchor)",
            resolvedAnchorId: nil,
            healedMarkerAnchorId: nil,
            degradedAnchor: degradedAnchor,
            grayedBlockCount: coverage.exact,
            uiGrayedBlockCount: coverage.greyed
        )
    }

    /// Blocks the caller's greying loop will mark, and blocks the marker covers.
    ///
    /// The caller greys the UI rows above the divider and skips status rows
    /// (`systemInfo`), so this counting does the same — a number that described
    /// the caller's loop differently from the loop itself would be a readout that
    /// measures itself.
    private static func blockCoverage(
        insertIndex: Int,
        compactedInsideBoundaryRow: Int,
        uiRows: [DSHCompactUIRow]
    ) -> (exact: Int, greyed: Int) {
        let upTo = min(max(0, insertIndex), uiRows.count)
        var greyed = 0
        for i in 0..<upTo where !isStatusRow(uiRows[i]) {
            greyed += uiRows[i].blockCount
        }
        return (greyed + max(0, compactedInsideBoundaryRow), greyed)
    }

    /// A row the caller never greys: the transcript's own status lines.
    private static func isStatusRow(_ row: DSHCompactUIRow) -> Bool {
        row.role != "user" && row.role != "assistant"
    }

    // MARK: - Lookups

    /// sortOrder → the UI row whose inclusive range covers it.
    private static func uiIndexMap(_ uiRows: [DSHCompactUIRow]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (idx, row) in uiRows.enumerated() {
            guard let first = row.firstSortOrder else { continue }
            let last = row.lastSortOrder ?? first
            guard last >= first else { continue }
            for so in first...last where map[so] == nil { map[so] = idx }
        }
        return map
    }

    private static func uiIndex(
        forRawId id: String,
        rawById: [String: DSHCompactRawRow],
        uiIndexBySortOrder: [Int: Int]
    ) -> Int? {
        guard let raw = rawById[id] else { return nil }
        return uiIndexBySortOrder[raw.sortOrder]
    }

    /// Whether `row` is the newest row the transcript holds.
    ///
    /// The clock heal is refused in exactly this case. `anchorByCreatedAt` picks
    /// the newest row older than the marker, and a marker is written AFTER the
    /// rows it covers, so for a marker with no real anchor the answer is always
    /// this row — "everything was compacted", divider at the bottom. See rule 2.
    static func namesNewestRow(_ row: DSHCompactRawRow, rawRows: [DSHCompactRawRow]) -> Bool {
        guard let newest = rawRows.last else { return false }
        return newest.id == row.id || newest.sortOrder == row.sortOrder
    }

    /// The newest raw row that predates the marker and is still bound to an
    /// agentHistory row.
    ///
    /// The history-presence filter is load-bearing: `effectiveAgentHistory()`
    /// resolves a marker by looking the id up in `agentHistory` on every send,
    /// so a healed anchor that is not there just re-enters the degraded path and
    /// the heal was cosmetic.
    static func anchorByCreatedAt(
        rawRows: [DSHCompactRawRow],
        markerCreatedAt: Date,
        historyDbIds: Set<String>
    ) -> DSHCompactRawRow? {
        rawRows.last { raw in
            guard raw.createdAt < markerCreatedAt else { return false }
            return historyDbIds.isEmpty || historyDbIds.contains(raw.id)
        }
    }

    /// The UI index of the `n`th-from-last user row that carries visible text —
    /// the "kept tail" a compactAll-shaped marker leaves active.
    ///
    /// Matches the agentHistory rule it stands in for: a tool-result-only user
    /// row is not a turn the user typed, so it does not count.
    static func uiAnchorIndexForKeptTail(uiRows: [DSHCompactUIRow], keepUserTurns n: Int) -> Int {
        guard n > 0, !uiRows.isEmpty else { return 0 }
        var seen = 0
        for i in stride(from: uiRows.count - 1, through: 0, by: -1) {
            let row = uiRows[i]
            guard row.role == "user", row.hasText else { continue }
            seen += 1
            if seen == n { return i }
        }
        return 0
    }
}
