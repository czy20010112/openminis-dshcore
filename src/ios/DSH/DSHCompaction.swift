//
//  DSHCompaction.swift
//  Minis
//
//  Context compaction, ported from DeepSeek Harness
//  (packages/compaction/compaction-basic/src/region.ts,
//   packages/compaction/compaction/src/tool-pairing.ts).
//
//  The selection rule matches DSH exactly:
//
//  1. Never compact the system head. A `system` message at surface node 0 stays
//     outside every range.
//  2. Walk the surface backwards accumulating token cost, stopping once the
//     retained tail reaches `retainTokens`.
//  3. Walk the candidate cut further back until it is tool-pairing balanced, so
//     a compaction never strands a tool call without its result.
//  4. Shadow the resulting positional range with one summary entry.
//
//  The transaction is a bracket: `start` is committed before the summary call
//  yields, `end` after it lands. An unmatched `start` is the compaction lock, so
//  two compactions cannot interleave — the condition OpenMinis guarded with a
//  separate `compactionsThisLoop` counter plus a queued-drain deferral.
//

import Foundation

// MARK: - Token Estimation

/// Token estimator for the compaction decision.
///
/// DSH routes this through a per-model token meter. On iOS the app already
/// carries a heuristic estimator (`estimateContextTokens`); the compaction only
/// needs relative cost, so a character-proportional estimate is sufficient and
/// keeps the decision independent of any provider's tokenizer.
public enum DSHTokenEstimate {
    /// Rough tokens per character for mixed prose and code.
    private static let charsPerToken = 3.6

    public static func tokens(for message: DSHMessage) -> Int {
        let chars = message.blocks.reduce(0) { partial, block in
            switch block {
            case let text as DSHTextBlock: return partial + text.text.count
            case let reasoning as DSHReasoningBlock: return partial + reasoning.text.count
            case let call as DSHToolCallBlock: return partial + call.name.count + call.arguments.count
            case let result as DSHToolResultBlock: return partial + result.content.count
            case let image as DSHImageBlock: return partial + 1200   // image tokens dominate
            case let file as DSHFileBlock: return partial + file.name.count + 64
            default: return partial
            }
        }
        return Int((Double(chars) / charsPerToken).rounded())
    }

    public static func tokens(for entry: DSHLogEntry) -> Int {
        tokens(for: entry.message)
    }

    public static func total(_ surface: [DSHLogEntry]) -> Int {
        surface.reduce(0) { $0 + tokens(for: $1) }
    }
}

// MARK: - Selection

/// One validated inclusive span of surface positions to compact.
public struct DSHCompactableRange: Sendable, Equatable {
    /// First surface index in the range.
    public let startIndex: Int
    /// Last surface index in the range (inclusive).
    public let endIndex: Int
    /// Seqs of the entries the range covers.
    public let shadowedSeqs: [DSHSeq]
    /// Estimated token count of the shadowed content.
    public let shadowedTokenCount: Int
    /// Estimated token count of the retained tail.
    public let retainedTokenCount: Int

    public init(
        startIndex: Int,
        endIndex: Int,
        shadowedSeqs: [DSHSeq],
        shadowedTokenCount: Int,
        retainedTokenCount: Int
    ) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.shadowedSeqs = shadowedSeqs
        self.shadowedTokenCount = shadowedTokenCount
        self.retainedTokenCount = retainedTokenCount
    }

    public var isEmpty: Bool { startIndex > endIndex }
}

/// Selects the range a compaction shadows.
public enum DSHCompactionSelection {

    /// Select the compactable range for a surface.
    ///
    /// Mirrors DSH's `selectCompactableRange`: the system head is never inside
    /// the range, the recent tail is retained verbatim up to `retainTokens`, and
    /// the cut is walked back to a tool-pairing balanced position.
    ///
    /// - Parameters:
    ///   - surface: current surface, oldest first.
    ///   - retainTokens: minimum recent-tail budget retained verbatim.
    ///   - pressureThreshold: total tokens above which compaction is worth doing.
    ///     When the surface is below this, selection returns nil.
    /// - Returns: the range to compact, or nil when nothing should be compacted.
    public static func select(
        surface: [DSHLogEntry],
        retainTokens: Int,
        pressureThreshold: Int
    ) -> DSHCompactableRange? {
        guard !surface.isEmpty else { return nil }

        let totalTokens = DSHTokenEstimate.total(surface)
        guard totalTokens >= pressureThreshold else { return nil }

        // A system head at node 0 is never inside the range.
        let firstIdx = isSystemHead(surface[0]) ? 1 : 0
        guard surface.count > firstIdx + 1 else { return nil }

        // Walk backwards accumulating the retained tail.
        var accumulated = 0
        var keepFromIdx = surface.count
        var index = surface.count - 1
        while index >= firstIdx {
            accumulated += DSHTokenEstimate.tokens(for: surface[index])
            keepFromIdx = index
            if accumulated >= retainTokens { break }
            index -= 1
        }
        if keepFromIdx <= firstIdx { return nil }

        // Walk the cut back to a tool-pairing balanced position.
        guard let balanced = DSHToolPairing.nearestBalancedBefore(
            surface: surface, index: keepFromIdx
        ) else { return nil }
        if balanced <= firstIdx { return nil }
        keepFromIdx = balanced

        let rangeSeqs = surface[firstIdx..<keepFromIdx].map(\.seq)
        let shadowedTokens = surface[firstIdx..<keepFromIdx]
            .reduce(0) { $0 + DSHTokenEstimate.tokens(for: $1) }
        let retainedTokens = surface[keepFromIdx...]
            .reduce(0) { $0 + DSHTokenEstimate.tokens(for: $1) }

        return DSHCompactableRange(
            startIndex: firstIdx,
            endIndex: keepFromIdx - 1,
            shadowedSeqs: rangeSeqs,
            shadowedTokenCount: shadowedTokens,
            retainedTokenCount: retainedTokens
        )
    }

    private static func isSystemHead(_ entry: DSHLogEntry) -> Bool {
        entry.message.role == .system
    }
}

// MARK: - Transaction

/// Failure captured after `compaction/start` committed, so the bracket always
/// closes exactly once.
public enum DSHCompactionError: Error, Sendable, Equatable {
    /// A compaction is already open on this session.
    case busy
    /// No open turn to enclose an automatic compaction.
    case noOpenTurn
    /// The summary call failed.
    case summaryFailed(String)
    /// The surface changed under the summary, so the span is no longer valid.
    case surfaceChanged
    /// The summary would not shrink the surface enough to be worth it.
    case noShrink

    public var message: String {
        switch self {
        case .busy: return "a compaction is already open on this session"
        case .noOpenTurn: return "automatic compaction requires an open turn"
        case .summaryFailed(let reason): return "summarization failed: \(reason)"
        case .surfaceChanged: return "the surface changed while summarizing"
        case .noShrink: return "the summary would not shrink the surface"
        }
    }
}

/// Outcome of one compaction.
public struct DSHCompactionOutcome: Sendable {
    public let summarySeq: DSHSeq
    public let range: DSHCompactableRange
    /// Tokens the surface held before the compaction.
    public let beforeTokens: Int
    /// Tokens the surface holds after it.
    public let afterTokens: Int

    public var shrinkRatio: Double {
        guard beforeTokens > 0 else { return 0 }
        return Double(beforeTokens - afterTokens) / Double(beforeTokens)
    }
}

/// Runs the compaction transaction.
public enum DSHCompaction {

    /// Bracket state, tracked so two compactions cannot interleave.
    private final class Bracket: @unchecked Sendable {
        var open = false
        var turn: Int?
        let lock = NSLock()

        func begin(turn: Int?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !open else { return false }
            open = true
            self.turn = turn
            return true
        }

        func end() {
            lock.lock(); defer { lock.unlock() }
            open = false
            turn = nil
        }
    }

    /// Compact a session's surface.
    ///
    /// - Parameters:
    ///   - session: the session to compact.
    ///   - turn: the enclosing turn for an automatic compaction, or nil for a
    ///     standalone manual one.
    ///   - retainTokens: recent-tail budget retained verbatim.
    ///   - pressureThreshold: total tokens above which compaction runs.
    ///   - summarize: builds the summary for the shadowed content. Called with
    ///     the surface text of the range being compacted.
    ///   - model / provider: recorded on the summary so "which model wrote this"
    ///     has a durable answer.
    /// - Returns: the outcome, or an error.
    public static func compact(
        session: DSHSession,
        turn: Int?,
        retainTokens: Int,
        pressureThreshold: Int,
        model: String,
        provider: String,
        summarize: @escaping @Sendable (String) async throws -> String
    ) async -> Result<DSHCompactionOutcome, DSHCompactionError> {
        let surface = session.surface()
        let beforeTokens = DSHTokenEstimate.total(surface)

        guard let range = DSHCompactionSelection.select(
            surface: surface,
            retainTokens: retainTokens,
            pressureThreshold: pressureThreshold
        ) else {
            return .failure(.noShrink)
        }

        let shadowedText = surface[range.startIndex...range.endIndex]
            .map { entry in Self.renderForSummary(entry) }
            .joined(separator: "\n\n")

        let summaryText: String
        do {
            summaryText = try await summarize(shadowedText)
        } catch {
            return .failure(.summaryFailed(String(describing: error)))
        }

        // Re-read the surface: an append during the summary call is fine (the
        // range's seqs are still valid), but a compaction that landed in
        // between invalidates the span we built from.
        let currentSurface = session.surface()
        let currentSeqs = Set(currentSurface.map { $0.seq.value })
        if !range.shadowedSeqs.allSatisfy({ currentSeqs.contains($0.value) }) {
            return .failure(.surfaceChanged)
        }

        // The summary replaces the range, so it must cost less than what it
        // shadows. Otherwise compaction churns context for no gain.
        let summaryMessage = DSHMessage(role: .user, blocks: [
            DSHTextBlock(text: Self.summaryEnvelope(summaryText))
        ])
        let summaryTokens = DSHTokenEstimate.tokens(for: summaryMessage)
        guard summaryTokens < range.shadowedTokenCount else {
            return .failure(.noShrink)
        }

        let shadowedRange = range.shadowedSeqs.first!...range.shadowedSeqs.last!
        let summarySeq = session.appendCompaction(
            summary: summaryMessage,
            shadows: shadowedRange,
            shadowedTokenCount: range.shadowedTokenCount,
            model: model,
            provider: provider,
            turn: turn
        )

        let afterTokens = DSHTokenEstimate.total(session.surface())
        return .success(DSHCompactionOutcome(
            summarySeq: summarySeq,
            range: range,
            beforeTokens: beforeTokens,
            afterTokens: afterTokens
        ))
    }

    // MARK: - Summary Envelope

    /// Wrap a summary so the model treats it as background rather than as the
    /// current instruction.
    ///
    /// The precedence clause matters: without it a stale summary can override a
    /// newer, shorter user instruction, which is the failure the envelope exists
    /// to prevent.
    static func summaryEnvelope(_ summary: String) -> String {
        """
        <context-summary>
        The following is a summary of earlier conversation that was compacted to save context space.

        Treat it as background context only. The user's most recent message takes precedence — if it changes the task, the goal, or any numbers or scope, follow the new instruction and do not resume the old plan from this summary. Do not re-run discovery (reading memory, scanning skills, re-reading files) unless the new instruction requires it.

        \(summary)
        </context-summary>
        """
    }

    /// Render one entry as text for the summarizer.
    static func renderForSummary(_ entry: DSHLogEntry) -> String {
        var lines: [String] = []
        let role = entry.message.role.rawValue
        for block in entry.message.blocks {
            switch block {
            case let text as DSHTextBlock:
                lines.append("[\(role)] \(text.text)")
            case let reasoning as DSHReasoningBlock:
                lines.append("[\(role) reasoning] \(reasoning.text)")
            case let call as DSHToolCallBlock:
                lines.append("[\(role) tool-call \(call.name)] \(call.arguments)")
            case let result as DSHToolResultBlock:
                let status = result.isError ? "error" : "ok"
                lines.append("[tool-result \(result.name) \(status)] \(result.content)")
            case let image as DSHImageBlock:
                lines.append("[\(role) image] \(image.mimeType) \(image.path ?? "(inline)")")
            case let file as DSHFileBlock:
                lines.append("[\(role) file] \(file.name) (\(file.size) bytes)")
            default:
                continue
            }
        }
        return lines.joined(separator: "\n")
    }
}
