//
//  DSHToolScheduler.swift
//  Minis
//
//  Tool-call scheduling, ported from DeepSeek Harness
//  (packages/agent-loop/src/tool-calls.ts).
//
//  Exclusive calls form barriers; parallel calls use a bounded rolling pool and
//  are reclassified before start. Dispatch may overlap, while results commit in
//  model order — the model must see results in the order it asked for them,
//  regardless of which finished first.
//

import Foundation

/// One scheduled call after argument parsing.
struct DSHPlannedCall {
    let block: DSHToolCallBlock
    let arguments: [String: Any]
    let parseError: DSHFailure?
}

/// Lock-guarded slot store. A slot is written once by the call that owns it and
/// read by the ordered committer, so the guard only has to make those two
/// operations safe; the store itself stays a plain typed array.
final class DSHSlotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [DSHToolExecutionResult?]

    init(count: Int) {
        self.slots = Array(repeating: nil, count: count)
    }

    /// Publish the result of one settled call.
    func set(_ result: DSHToolExecutionResult, at index: Int) {
        lock.lock()
        slots[index] = result
        lock.unlock()
    }

    /// Read the result at `index`, or nil while that call has not settled.
    func get(_ index: Int) -> DSHToolExecutionResult? {
        lock.lock()
        defer { lock.unlock() }
        return slots[index]
    }
}

/// Outcome of one scheduler group.
struct DSHGroupOutcome {
    let consumed: Int
    let aborted: Bool
    /// Whether any committed result carried `concludesTurn`.
    let concluded: Bool
}

/// Outcome of scheduling one assistant step's tool calls.
public struct DSHScheduleOutcome {
    /// Committed results in model order, including synthetic results for calls
    /// skipped after cancellation.
    public let commits: [DSHToolCommit]
    /// Whether the step was aborted.
    public let aborted: Bool
    /// Whether any result concluded the turn.
    public let concluded: Bool
}

/// One committed tool result, reported to the UI in model order.
public struct DSHToolCommit: Sendable {
    public let block: DSHToolCallBlock
    public let result: DSHToolExecutionResult
    /// False for calls skipped after cancellation.
    public let started: Bool

    public init(block: DSHToolCallBlock, result: DSHToolExecutionResult, started: Bool) {
        self.block = block
        self.result = result
        self.started = started
    }
}

/// Schedules one assistant step's tool calls by their live concurrency mode.
///
/// Committed results are returned in model order rather than streamed through a
/// callback: a callback that ran asynchronously could observe results out of
/// order, which would corrupt the conversation the model sees.
public enum DSHToolScheduler {

    public static func execute(
        registry: DSHToolRegistry,
        turn: Int,
        step: Int,
        toolCalls: [DSHToolCallBlock],
        signal: DSHCancellationToken,
        maxParallel: Int = 4
    ) async -> DSHScheduleOutcome {
        var planned: [DSHPlannedCall] = []
        planned.reserveCapacity(toolCalls.count)

        for block in toolCalls {
            do {
                let args = try DSHToolArguments.parse(block.arguments)
                planned.append(DSHPlannedCall(block: block, arguments: args, parseError: nil))
            } catch let failure as DSHFailure {
                planned.append(DSHPlannedCall(block: block, arguments: [:], parseError: failure))
            } catch {
                planned.append(DSHPlannedCall(
                    block: block, arguments: [:],
                    parseError: DSHFailure(message: String(describing: error), code: "INVALID_ARGUMENTS")
                ))
            }
        }

        var commits: [DSHToolCommit] = []
        var next = 0
        var concluded = false

        while next < planned.count {
            let first = planned[next]
            let mode = registry.executionMode(name: first.block.name)
            let group = mode == .parallel ? Array(planned[next...]) : [first]
            let outcome = await runGroup(
                registry: registry, turn: turn, step: step,
                group: group, mode: mode, signal: signal,
                maxParallel: maxParallel
            ) { commit in
                commits.append(commit)
            }
            next += outcome.consumed
            concluded = concluded || outcome.concluded
            if outcome.aborted {
                // Every remaining model call receives an ordered synthetic
                // result so replay stays valid.
                for call in planned[next...] {
                    commits.append(DSHToolCommit(
                        block: call.block,
                        result: DSHToolExecutionResult(
                            content: "Error: tool call aborted before dispatch",
                            isError: true
                        ),
                        started: false
                    ))
                }
                return DSHScheduleOutcome(
                    commits: commits,
                    aborted: true,
                    concluded: concluded
                )
            }
        }

        return DSHScheduleOutcome(commits: commits, aborted: false, concluded: concluded)
    }

    /// Run one exclusive barrier or parallel pool.
    private static func runGroup(
        registry: DSHToolRegistry,
        turn: Int,
        step: Int,
        group: [DSHPlannedCall],
        mode: DSHToolExecutionMode,
        signal: DSHCancellationToken,
        maxParallel: Int,
        emit: @escaping @Sendable (DSHToolCommit) -> Void
    ) async -> DSHGroupOutcome {
        let store = DSHSlotStore(count: group.count)
        var concluded = false
        var committed = 0
        var started = 0
        var nextToStart = 0
        var aborted = signal.isCancelled

        // `committed` advances only across contiguous model-order slots, so a
        // result never overtakes an earlier call.
        func commitReady() {
            while committed < group.count {
                guard let result = store.get(committed) else { break }
                let call = group[committed]
                emit(DSHToolCommit(block: call.block, result: result, started: true))
                concluded = concluded || result.concludesTurn
                committed += 1
            }
        }

        func settle(_ index: Int, with result: DSHToolExecutionResult) {
            store.set(result, at: index)
        }

        // Run one call and settle its slot. Overlaps only when the caller
        // dispatches it as a detached task.
        func runCall(_ index: Int) async {
            let call = group[index]
            started += 1

            if let parseError = call.parseError {
                settle(index, with: DSHToolExecutionResult(
                    content: "Error: \(parseError.message)", isError: true
                ))
                return
            }

            guard let tool = registry.tool(named: call.block.name) else {
                settle(index, with: DSHToolExecutionResult.error(
                    "unknown tool \"\(call.block.name)\""
                ))
                return
            }

            let context = DSHToolRunContext(
                callId: call.block.id, signal: signal, turn: turn, step: step
            )

            do {
                settle(index, with: try await tool.run(call.arguments, context: context))
            } catch {
                let message: String
                if let failure = error as? DSHFailure {
                    message = failure.message
                } else if signal.isCancelled {
                    message = "tool call cancelled"
                } else {
                    message = String(describing: error)
                }
                settle(index, with: DSHToolExecutionResult(
                    content: "Error: \(message)", isError: true
                ))
            }
        }

        if mode == .parallel {
            // Bounded rolling pool: fill up to `maxParallel` in flight, then
            // refill as calls settle. Awaiting a real task group keeps the
            // thread suspended instead of spinning on `Task.yield()`.
            var inFlight = [Task<Void, Never>]()

            while nextToStart < group.count && !aborted {
                // Re-read later modes after ordered commits so a registry
                // change can create a barrier.
                if nextToStart > 0
                    && registry.executionMode(name: group[nextToStart].block.name) != .parallel {
                    break
                }

                while inFlight.count < maxParallel && nextToStart < group.count {
                    let index = nextToStart
                    nextToStart += 1
                    inFlight.append(Task { await runCall(index) })
                }

                // Suspend until at least one in-flight call finishes, then
                // commit every result that is ready in model order.
                let finished = await waitForAny(inFlight)
                inFlight.removeAll { $0.isFinished }
                _ = finished
                commitReady()
                if signal.isCancelled { aborted = true }
            }

            for task in inFlight { await task.value }
            commitReady()
        } else {
            // Exclusive barrier: one call at a time, committed in order.
            while nextToStart < group.count && !aborted {
                await runCall(nextToStart)
                nextToStart += 1
                commitReady()
                if signal.isCancelled { aborted = true }
            }
        }

        if aborted {
            return DSHGroupOutcome(consumed: started, aborted: true, concluded: concluded)
        }

        return DSHGroupOutcome(consumed: started, aborted: false, concluded: concluded)
    }

    /// Suspend until at least one of `tasks` has finished.
    ///
    /// Each task installs its own continuation resumption, so the caller is
    /// woken exactly once by whichever call completes first rather than polling
    /// for completion.
    private static func waitForAny(_ tasks: [Task<Void, Never>]) async -> Int {
        guard !tasks.isEmpty else { return -1 }
        return await withTaskGroup(of: Int.self) { group in
            for (index, task) in tasks.enumerated() {
                group.addTask {
                    await task.value
                    return index
                }
            }
            // The first settled child wins; the rest are abandoned, which is
            // safe because every call already settled its own slot.
            let first = await group.next() ?? -1
            group.cancelAll()
            return first
        }
    }
}
