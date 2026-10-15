//
//  DSHToolDispatchBridge.swift
//  Minis
//
//  Runs one assistant step's tool calls through the DSH scheduler, driving
//  OpenMinis' existing tool handlers.
//
//  WHY THIS EXISTS
//  ---------------
//  OpenMinis' own dispatch used a raw `withTaskGroup` with an in-flight cap and
//  then stitched results back into model order by tagging each child task with
//  its source index. Two properties that the loop needs were not expressed
//  anywhere:
//
//  1. Which tools may run concurrently at all. Every tool was treated as
///     parallel-eligible, so a `file_write` could overlap a `shell_execute`
///     that rewrote the same file.
///  2. That a call's slot is exclusive while it runs. The cap bounded how many
///     ran, not which could run together.
///
///  The stitch-back was also the fragile part: `outcomesByIndex` keyed by the
///  dispatch index, and any index that never harvested left its slot empty. The
///  code then had to guard every read with `guard let outcome = ... else { continue }`,
///  which silently drops a tool result and produces the orphaned-tool_use 400
///  that a separate pre-send scan exists to paper over.
///
///  The DSH scheduler states both properties as data: each tool declares
///  `.exclusive` or `.parallel`. An exclusive call forms a barrier; parallel
///  calls run in a bounded pool. Results commit in model order by construction —
///  the committer advances only across contiguous settled slots, so there is no
///  index to lose.
//

import Foundation

/// Wraps OpenMinis' tool handlers as DSH tools with declared concurrency.
@MainActor
enum DSHToolDispatch {

    /// Concurrency class for one Minis tool.
    ///
    /// Shell commands and file mutations are exclusive: they touch shared
    /// sandbox state, and overlapping two of them is a correctness bug rather
    /// than a performance loss. Reads and pure lookups are parallel.
    static func mode(for name: String) -> DSHToolExecutionMode {
        switch name {
        case "shell_execute", "file_write", "file_edit", "memory_write":
            return .exclusive
        case "file_read", "read_image", "memory_get":
            return .parallel
        default:
            // Unknown tools default to exclusive. A new tool that is safe to
            // parallelize must say so, rather than inheriting parallelism by
            // omission.
            return .exclusive
        }
    }

    /// The DSH execution mode map, for diagnostics.
    static var modeMap: [String: DSHToolExecutionMode] {
        var out: [String: DSHToolExecutionMode] = [:]
        for name in ["shell_execute", "file_read", "file_write", "file_edit", "read_image", "memory_write", "memory_get"] {
            out[name] = mode(for: name)
        }
        return out
    }
}
