//
//  DSHToolDispatchBridge.swift
//  Minis
//
//  Declares each Minis tool's concurrency class for the DSH scheduler.
//
//  OpenMinis treated every tool as parallel-eligible behind a single in-flight
//  cap, then stitched results back by dispatch index. That assumes tools do not
//  share state, which is false for anything that touches the sandbox or the
//  browser. Here the property is stated as data: an exclusive call forms a
//  barrier, a parallel call joins a bounded pool.
//
//  The same rules still hold — only their expression changed.
//

import Foundation

/// Wraps OpenMinis' tool handlers as DSH tools with declared concurrency.
@MainActor
enum DSHToolDispatch {

    /// Concurrency class for one Minis tool.
    ///
    /// Shell commands, file mutations, browser actions and delegation all touch
    /// shared state, and overlapping two of them is a correctness bug rather
    /// than a performance loss. Reads and pure lookups are parallel.
    static func mode(for name: String) -> DSHToolExecutionMode {
        switch name {
        case "shell_execute", "file_write", "file_edit", "memory_write":
            return .exclusive
        case "browser_use":
            // One browser, up to three tabs, one shared cookie store and a
            // viewport override: two overlapping actions race on all of it.
            return .exclusive
        case "subagent_task":
            // `SubAgentDefinition.toolName` on the iOS 26 line. Delegation
            // mutates the sub-agent roster and consumes one of three slots, so
            // it must not overlap itself. The literal is used rather than the
            // constant because that type does not exist on the iOS 15 line, and
            // this file is identical on both.
            return .exclusive
        case "file_read", "read_image", "memory_get":
            return .parallel
        case "web_search":
            // [T-tools-web-search] A network read of a third party's index: it
            // touches no local state, so two of them overlap safely, and a model
            // comparing several sources should not have them serialised.
            return .parallel
        case "todo_write", "exit_plan_mode":
            // [T-tools-todo-plan] Session state that the prompt and the composer
            // panel both read. Both also default to exclusive, but state it: the
            // next person to add a parallel class needs to see that this one was
            // decided rather than inherited.
            return .exclusive
        default:
            // Unknown tools default to exclusive. A new tool that is safe to
            // parallelize must say so, rather than inheriting parallelism by
            // omission.
            return .exclusive
        }
    }
}
