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

    public init(
        firstSortOrder: Int?,
        lastSortOrder: Int?,
        role: String,
        hasText: Bool
    ) {
        self.firstSortOrder = firstSortOrder
        self.lastSortOrder = lastSortOrder
        self.role = role
        self.hasText = hasText
    }
}

/// A persisted compaction marker, reduced to the fields the boundary reads.
///
/// `version` matters: a v2 marker resolves ONLY through `lastCompactedMessageId`
/// (the legacy sort-order fields were written as past-end sentinels and reading
/// them back as real boundaries points at a coincidental row).
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
    public var describesARange: Bool {
        firstKeptMessageId != nil
            || boundaryMessageId != nil
            || lastCompactedMessageId != nil
            || version < 2
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

    public init(
        insertIndex: Int,
        resolutionPath: String,
        resolvedAnchorId: String?,
        healedMarkerAnchorId: String? = nil
    ) {
        self.insertIndex = insertIndex
        self.resolutionPath = resolutionPath
        self.resolvedAnchorId = resolvedAnchorId
        self.healedMarkerAnchorId = healedMarkerAnchorId
    }

    /// Whether any row is greyed by this decision.
    public var greysAnything: Bool { insertIndex > 0 }
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
///   1. **Forward boundary** (`firstKeptMessageId` → `boundaryMessageId`), when
///      it is a row the transcript really holds. A marker that names the first
///      row it KEPT is exact: the divider goes immediately before it. This is
///      the shape `compactBefore` writes.
///   2. **v2 anchor** (`lastCompactedMessageId`): the divider goes immediately
///      AFTER the UI row whose inclusive sort-order range contains the anchor
///      row. That is the `compactAll` shape the DSH path writes.
///   3. **Anchor by `createdAt`**: the newest raw row that predates the marker
///      — the same self-heal `anchorByCreatedAt` performs, and the only repair
///      available when the anchor's row was deleted or re-indexed. Applied to
///      v2/compactAll markers only; a legacy marker with a readable sort-order
///      boundary is not rewritten.
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
            healedMarkerAnchorId: decision.healedMarkerAnchorId
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
            return DSHCompactBoundaryDecision(
                insertIndex: 0,
                resolutionPath: "markerDescribesNoRange",
                resolvedAnchorId: nil
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

        // ── 1. Forward boundary ────────────────────────────────────────────
        //
        // `firstKeptMessageId` is the authoritative name when present: it is the
        // first row the compaction KEPT, so the divider sits immediately before
        // its UI row.
        if let id = marker.firstKeptMessageId ?? marker.boundaryMessageId,
           rawById[id] != nil {
            let path = marker.firstKeptMessageId == id ? "firstKeptMessageId" : "boundaryMessageId"
            if let idx = uiIndex(forRawId: id, rawById: rawById, uiIndexBySortOrder: uiIndexBySortOrder) {
                return DSHCompactBoundaryDecision(
                    insertIndex: idx,
                    resolutionPath: path,
                    resolvedAnchorId: id
                )
            }
            // The named row exists but Phase 2 gave no UI row its sort order —
            // fall through to the anchor ladder rather than greying nothing.
        }

        // ── 2/3. The backward anchor, exact then repaired ──────────────────
        if let lcmId = marker.lastCompactedMessageId {
            if let raw = rawById[lcmId],
               let idx = uiIndexBySortOrder[raw.sortOrder] {
                return DSHCompactBoundaryDecision(
                    insertIndex: idx + 1,
                    resolutionPath: marker.version >= 2 ? "v2(lcmId)" : "compactAll(lastCompactedMessageId)",
                    resolvedAnchorId: lcmId
                )
            }
            // The anchor's row is gone (deleted, or re-indexed by a sync
            // migration). Rebuild it from the clock, which survives both.
            if let heal = anchorByCreatedAt(
                rawRows: rawRows,
                markerCreatedAt: marker.createdAt,
                historyDbIds: historyDbIds
            ), let idx = uiIndexBySortOrder[heal.sortOrder] {
                return DSHCompactBoundaryDecision(
                    insertIndex: idx + 1,
                    resolutionPath: marker.version >= 2
                        ? "v2(orphan→healByCreatedAt)"
                        : "compactAll(orphanedLcm→healByCreatedAt)",
                    resolvedAnchorId: lcmId,
                    healedMarkerAnchorId: heal.id
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
                return DSHCompactBoundaryDecision(
                    insertIndex: idx,
                    resolutionPath: "firstKeptSortOrder(legacy)",
                    resolvedAnchorId: raw.id
                )
            }
        }

        // ── 4. Kept tail ───────────────────────────────────────────────────
        //
        // Monotone and self-limiting: the tail is active, the prefix is greyed,
        // and the divider records that the session WAS compacted even though the
        // exact boundary is unrecoverable.
        let tail = uiAnchorIndexForKeptTail(uiRows: uiRows, keepUserTurns: keepRecentUserTurns)
        if tail > 0 {
            return DSHCompactBoundaryDecision(
                insertIndex: tail,
                resolutionPath: marker.version >= 2
                    ? "v2(orphan→tailAnchor)"
                    : "compactAll(orphanedLcm→tailAnchor)",
                resolvedAnchorId: nil
            )
        }

        // ── 5. Top ─────────────────────────────────────────────────────────
        return DSHCompactBoundaryDecision(
            insertIndex: 0,
            resolutionPath: "unresolved→noGray",
            resolvedAnchorId: nil
        )
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
