import Foundation

// MARK: - Summary refresh cadence

/// When the Session summary (goal / todos / last compaction) is refetched:
/// opening the Session, every `turn/end`, and every SECOND snapshot frame.
///
/// Not every frame: a streaming turn emits hundreds of snapshots and the panels
/// change at step boundaries, not per token — refetching per frame would hammer
/// the host for data that has not changed. Not a timer either: the page is asleep
/// when the screen is off, and a poll with no viewer is pure host load.
///
/// Split out of the page so the edge logic is testable without a network: this is
/// the piece that decides how often `GET /dsh/summary` runs.
struct DSHRemoteSummaryCadence {
    private var snapshotsSinceFetch = 0

    /// Opening a Session (or an explicit user refresh) always refetches.
    mutating func onOpen() { snapshotsSinceFetch = 0 }

    /// A `snapshot` frame: true on every second one.
    mutating func onSnapshot() -> Bool {
        snapshotsSinceFetch += 1
        guard snapshotsSinceFetch >= 2 else { return false }
        snapshotsSinceFetch = 0
        return true
    }

    /// `turn/end` always refetches: the host writes goal and todo at the end of a
    /// turn, so this is the one edge that matters.
    mutating func onTurnEnd() -> Bool {
        snapshotsSinceFetch = 0
        return true
    }
}