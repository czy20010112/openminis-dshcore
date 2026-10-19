//
//  DSHToolResultPruner.swift
//  Minis
//
//  Deterministic, model-free tool-result pruning, ported from DeepSeek Harness
//  (packages/compaction/compaction-tool-result-pruner/src/{index,config,types}.ts,
//   tag dsh-v0.2.1-rc.2).
//
//  WHY THIS EXISTS
//  ---------------
//  Compaction had exactly one mechanism: cross the pressure threshold, select the
//  oldest range, ask the model to summarize it. Upstream runs a pass BEFORE that
//  choice which calls no model at all: every tool result whose text exceeds
//  `thresholdChars` is replaced by its first `headChars` plus a fixed marker plus
//  its last `tailChars`. If the remeasured request falls back under the threshold,
//  `compaction-basic` returns WITHOUT summarizing (`index.ts:319-327`), and the
//  turn pays nothing.
//
//  The device log shows why that matters here. On 2026-10-19 a ~810 KB request
//  (~189k provider tokens) was dominated by ~60 `file_read` results of 15,235
//  characters each. Pruning rewrites each to 5,140 characters (~34%), which is
//  ~605,700 characters ≈ 139k provider tokens — enough to drop 189k under the
//  188,416-token threshold on its own. Each compaction that fires instead costs
//  a summary request the engine prices as a COLD prefill of 132–141k tokens at a
//  43–47 s TTFT (`cache=13`), because that request shares no prefix with the
//  conversation.
//
//  WHAT IS PRUNED, AND WHERE
//  -------------------------
//  Upstream prunes the SURFACE, not the log: `pruneSession` walks
//  `session.surface.nodes`, derives each `tool/result` event's message, and lands
//  a replacement through `surfaceOp: { op: 'replace', startSeq, endSeq }`
//  (`index.ts:136-182`). The original event stays in the append-only log, "for
//  exact replay and inspection" (README "Summary"). The model sees the head, the
//  marker, and the tail; nothing else changes.
//
//  This port keeps that shape exactly. `run(_:)` takes one snapshot of
//  `DSHSession.surface()`, prunes each over-budget result in it, and lands each
//  replacement with `DSHSession.appendPrune`, which is the same positional
//  replacement `appendCompaction` performs — the replacement takes the place of
//  the node it shadows (`DSHSession.surface()`), it is not appended to the end.
//  A prune is deliberately NOT a `DSHCompactionRecord`: it has no summary, must
//  never be materialised as a `<context-summary>` entry, and must not be
//  revertible as a compaction. What it does share is the `shadows` range, which
//  is what makes the fold place it where the pruned result was.
//
//  Non-text tool-result content is not touched. On this side that is the block's
//  own image bytes, page URL, and durable image path, all of which ride the
//  replacement unchanged; only `DSHToolResultBlock.content` is rewritten.
//
//  CONFIGURATION (upstream defaults, `config.ts:10-14`)
//  ---------------------------------------------------
//  `thresholdChars 8192`, `headChars 4096`, `tailChars 1024`, marker
//  `"\n\n[... tool result middle pruned ...]\n\n"` (`config.ts:7`). The budget
//  validation is upstream's: each field must be an integer of the right sign, and
//  `head + marker + tail` must not exceed `threshold`, so a valid configuration
//  can only shrink an over-budget result, never grow it
//  (`config.ts:36-65`). Character budgets are code points, never UTF-16 units:
//  slicing must not split a surrogate pair (`config.ts:27-29`).
//

import Foundation

// MARK: - Configuration

/// One resolved, immutable set of pruning budgets.
///
/// Field-by-field port of upstream's `ResolvedConfig` (`types.ts:15-19`); the
/// values live in ``DSHToolResultPruner/Config/defaults``.
public struct DSHToolResultPruneConfig: Sendable, Equatable {

    /// The shipped budgets: prune a tool result whose text exceeds 8,192 code
    /// points down to its first 4,096 plus its last 1,024.
    public struct Defaults: Sendable {
        /// Prune when the combined text exceeds this many code points.
        public static let thresholdChars = 8_192
        /// Leading code points retained.
        public static let headChars = 4_096
        /// Trailing code points retained.
        public static let tailChars = 1_024
    }

    /// Prune when the combined text exceeds this many code points.
    public let thresholdChars: Int
    /// Leading code points retained.
    public let headChars: Int
    /// Trailing code points retained.
    public let tailChars: Int

    public init(
        thresholdChars: Int = Defaults.thresholdChars,
        headChars: Int = Defaults.headChars,
        tailChars: Int = Defaults.tailChars
    ) {
        self.thresholdChars = thresholdChars
        self.headChars = headChars
        self.tailChars = tailChars
    }
}

/// Why a pruning budget set cannot be used.
///
/// Upstream rejects the plugin at construction time rather than at first use
/// (`config.ts:36-65`), and the reason is the same here: a configuration that can
/// fail on a tool result would fail in the middle of a turn.
public struct DSHToolResultPruneConfigError: Error, Sendable, Equatable {
    /// The field or rule that did not hold.
    public let detail: String

    public init(detail: String) { self.detail = detail }

    public var message: String { detail }
}

// MARK: - Result

/// One landed replacement, for the diagnostic line and for tests.
public struct DSHToolResultPrunedEntry: Sendable, Equatable {
    /// Seq of the tool-result node that was replaced.
    public let originalSeq: DSHSeq
    /// Seq of the replacement node that now stands in its place.
    public let replacementSeq: DSHSeq
    /// The tool call both nodes belong to.
    public let callId: String
    /// Text size before pruning, in code points.
    public let charsBefore: Int
    /// Text size after pruning, in code points.
    public let charsAfter: Int
}

/// Aggregate outcome of one pruning pass.
public struct DSHToolResultPruneResult: Sendable, Equatable {
    /// Replacements, in the order the snapshot held them.
    public let pruned: [DSHToolResultPrunedEntry]
    /// Code points removed across every replacement.
    public let charsRemoved: Int
    /// Code points held by the over-budget results the pass rewrote, before it
    /// rewrote them — the denominator of the saving the log reports.
    public let charsPrunedBefore: Int
    /// Tool results that were over budget and so were rewritten.
    public var prunableCount: Int { pruned.count }

    public init(
        pruned: [DSHToolResultPrunedEntry],
        charsRemoved: Int,
        charsPrunedBefore: Int
    ) {
        self.pruned = pruned
        self.charsRemoved = charsRemoved
        self.charsPrunedBefore = charsPrunedBefore
    }

    /// Whether the pass changed anything.
    public var isEmpty: Bool { pruned.isEmpty }

    /// One `[CompactDiag]` line for this pass, or nil when nothing was rewritten.
    ///
    /// An outcome that leaves no line is the shape this project has been burned
    /// by: "the surface did not shrink" and "the pruning pass never ran" are then
    /// the same log. The line carries every figure the decision used — before,
    /// after, the threshold, the budget split, and the skipped-summary verdict —
    /// so a device log answers "was this pass the reason no summary was sent".
    ///
    /// - Parameters:
    ///   - skippedSummary: whether the caller then skipped summarization because
    ///     the pruned request was under the pressure threshold.
    ///   - config: the budgets the pass ran with, printed so the line is readable
    ///     against a non-default configuration.
    /// - Returns: the line, or nil when the pass pruned nothing.
    public func diagnosticLine(
        skippedSummary: Bool,
        config: DSHToolResultPruneConfig = DSHToolResultPruneConfig()
    ) -> String? {
        guard !pruned.isEmpty else { return nil }
        let bypassed = skippedSummary ? "yes" : "no"
        return "[CompactDiag] tool-result prune: pruned=\(pruned.count) "
            + "before=\(charsPrunedBefore) after=\(charsPrunedBefore - charsRemoved) "
            + "removed=\(charsRemoved) budget=\(config.headChars)"
            + "+\(DSHToolResultPruner.markerCodePointCount)+\(config.tailChars) "
            + "threshold=\(config.thresholdChars) skippedSummary=\(bypassed)"
    }
}

// MARK: - Pruner

/// Deterministic head/middle/tail pruning of the current tool-result surface.
///
/// Upstream ships this as a cordis service so the token meter can price each
/// shadowed node (`index.ts:44-61`). Here the pricing is a pure function of the
/// block — `DSHTokenEstimate.tokens(for:)`, the same estimator the threshold and
/// the retained-tail budget already use — so the pruner needs no service, only
/// the session it rewrites.
public enum DSHToolResultPruner {

    /// Fixed marker substituted for every removed middle span.
    ///
    /// Byte-for-byte upstream's `PRUNE_MARKER` (`config.ts:7`), which the README
    /// also publishes as what the model sees ("Model Experience").
    public static let marker = "\n\n[... tool result middle pruned ...]\n\n"

    /// Code points the marker occupies, for the budget check.
    public static let markerCodePointCount = codePointCount(marker)

    /// Count Unicode code points without splitting surrogate pairs.
    ///
    /// A Swift `Character` is an extended grapheme cluster, which is STRICTER than
    /// upstream's `Array.from(text)` split; the two agree for every text that has
    /// no combining sequence. The property that matters is shared and asserted:
    /// the cut index never falls inside a surrogate pair.
    ///
    /// - Parameter text: text to measure.
    /// - Returns: the code-point count.
    public static func codePointCount(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// Resolve and validate pruning budgets.
    ///
    /// Upstream's own rules, in upstream's own order (`config.ts:36-65`):
    /// `thresholdChars` a positive integer, `headChars`/`tailChars` non-negative
    /// integers, and `head + marker + tail` at most `threshold`.
    ///
    /// - Parameter config: the requested budgets.
    /// - Returns: the validated budgets.
    /// - Throws: ``DSHToolResultPruneConfigError`` naming the field that failed.
    public static func resolveConfig(
        _ config: DSHToolResultPruneConfig = DSHToolResultPruneConfig()
    ) throws -> DSHToolResultPruneConfig {
        guard config.thresholdChars > 0 else {
            throw DSHToolResultPruneConfigError(
                detail: "DSHToolResultPruneConfig: thresholdChars "
                    + "(\(config.thresholdChars)) must be a positive integer"
            )
        }
        guard config.headChars >= 0 else {
            throw DSHToolResultPruneConfigError(
                detail: "DSHToolResultPruneConfig: headChars "
                    + "(\(config.headChars)) must be a non-negative integer"
            )
        }
        guard config.tailChars >= 0 else {
            throw DSHToolResultPruneConfigError(
                detail: "DSHToolResultPruneConfig: tailChars "
                    + "(\(config.tailChars)) must be a non-negative integer"
            )
        }
        let emitted = config.headChars + markerCodePointCount + config.tailChars
        guard emitted <= config.thresholdChars else {
            throw DSHToolResultPruneConfigError(
                detail: "DSHToolResultPruneConfig: headChars + marker + tailChars "
                    + "(\(emitted)) must be at most thresholdChars (\(config.thresholdChars))"
            )
        }
        return config
    }

    // MARK: Content

    /// Measure a tool result's text by code point; the block's other fields cost
    /// nothing, exactly as upstream's `measureContent` counts only `text` blocks
    /// (`index.ts:63-74`).
    ///
    /// - Parameter content: the manipulated result text.
    /// - Returns: its code-point count.
    public static func measureContent(_ content: String) -> Int {
        codePointCount(content)
    }

    /// Replace an over-budget text middle, or return nil when the text is within
    /// budget.
    ///
    /// The arithmetic is upstream's (`index.ts:76-122`): the removed span is
    /// `[headChars, totalChars - tailChars)`, the marker is emitted at the START
    /// of that span, and the result is head + marker + tail. Upstream applies the
    /// same rule to a list of blocks, where a removed span can straddle several of
    /// them; this port's tool result carries its text in one `content` string, so
    /// the loop collapses to the single span it would compute. The two shipped
    /// assertions are kept: an over-budget input must yield at least one removed
    /// span, and the replacement must be strictly smaller and within threshold.
    ///
    /// - Parameter content: the result text.
    /// - Returns: the pruned text, or nil when nothing should be pruned.
    public static func pruneContent(
        _ content: String,
        config: DSHToolResultPruneConfig = DSHToolResultPruneConfig()
    ) -> String? {
        let totalChars = measureContent(content)
        guard totalChars > config.thresholdChars else { return nil }

        let removedStart = config.headChars
        let removedEnd = totalChars - config.tailChars
        let intersectsRemoved = 0 < removedEnd && totalChars > removedStart
        guard intersectsRemoved else {
            // Upstream's `failed to locate the removed text span` (`index.ts:115`).
            return nil
        }

        let scalars = Array(content.unicodeScalars)
        let headEnd = min(scalars.count, max(0, removedStart))
        let tailStart = min(scalars.count, max(0, removedEnd))
        let head = String(String.UnicodeScalarView(scalars[0..<headEnd]))
        let tail = String(String.UnicodeScalarView(scalars[tailStart...]))
        let pruned = head + marker + tail

        let charsAfter = measureContent(pruned)
        guard charsAfter <= config.thresholdChars, charsAfter < totalChars else {
            // Upstream's `replacement must be smaller and within threshold`
            // (`index.ts:118-120`).
            return nil
        }
        return pruned
    }

    /// Prune one tool-result block, preserving every field but its text.
    ///
    /// - Parameters:
    ///   - block: the result as the session holds it.
    ///   - config: the pruning budgets.
    /// - Returns: the replacement block, or nil when the result is within budget.
    public static func prune(
        _ block: DSHToolResultBlock,
        config: DSHToolResultPruneConfig = DSHToolResultPruneConfig()
    ) -> DSHToolResultBlock? {
        guard let content = pruneContent(block.content, config: config) else { return nil }
        return DSHToolResultBlock(
            callId: block.callId,
            name: block.name,
            content: content,
            isError: block.isError,
            imageData: block.imageData,
            imageMimeType: block.imageMimeType,
            pageURL: block.pageURL,
            imageLinuxPath: block.imageLinuxPath
        )
    }

    // MARK: Pass

    /// Every `tool/result` node of one stable surface snapshot, with its seq.
    ///
    /// Upstream reads the snapshot and keeps the events of type `tool/result`
    /// (`index.ts:136-143`). It is deliberately not filtered by tool NAME or by
    /// AGE: there is no skip condition in the shipped pruner beyond the size
    /// budget. Age is expressed by what the budget can still reach — a result the
    /// retained tail keeps verbatim is pruned by exactly the same rule as an old
    /// one, because it is the CONTEXT that is over budget, not the entry.
    ///
    /// - Parameter surface: the surface snapshot, oldest first.
    /// - Returns: `(seq, block)` pairs in surface order.
    public static func toolResultBlocks(
        in surface: [DSHLogEntry]
    ) -> [(seq: DSHSeq, block: DSHToolResultBlock)] {
        var found: [(seq: DSHSeq, block: DSHToolResultBlock)] = []
        for entry in surface {
            for block in entry.message.blocks {
                guard let result = block as? DSHToolResultBlock else { continue }
                found.append((entry.seq, result))
            }
        }
        return found
    }

    /// Prune every over-budget tool result from one stable surface snapshot.
    ///
    /// One snapshot, one replacement per over-budget node, and a replacement can
    /// never itself be re-pruned: `pruneContent` returns nil for anything already
    /// at or under the threshold, and the budget rule guarantees the emitted
    /// result is within it (README, "Setting the size limits": "a valid
    /// configuration trims every over-budget result without growth or repeated
    /// rewriting").
    ///
    /// The snapshot is taken once and iterated as a value, so the replacements this
    /// pass appends are not visited again by this pass.
    ///
    /// - Parameters:
    ///   - session: the session whose surface is rewritten.
    ///   - config: the pruning budgets.
    /// - Returns: the landed replacements and their aggregate saving.
    public static func run(
        _ session: DSHSession,
        config: DSHToolResultPruneConfig = DSHToolResultPruneConfig()
    ) -> DSHToolResultPruneResult {
        let snapshot = toolResultBlocks(in: session.surface())
        var pruned: [DSHToolResultPrunedEntry] = []
        var charsRemoved = 0
        var charsPrunedBefore = 0

        for candidate in snapshot {
            guard let replacement = prune(candidate.block, config: config) else { continue }
            let charsBefore = measureContent(candidate.block.content)
            let charsAfter = measureContent(replacement.content)
            let seq = session.appendPrune(
                message: DSHMessage(role: .tool, blocks: [replacement]),
                shadows: candidate.seq...candidate.seq
            )
            pruned.append(DSHToolResultPrunedEntry(
                originalSeq: candidate.seq,
                replacementSeq: seq,
                callId: candidate.block.callId,
                charsBefore: charsBefore,
                charsAfter: charsAfter
            ))
            charsRemoved += charsBefore - charsAfter
            charsPrunedBefore += charsBefore
        }
        return DSHToolResultPruneResult(
            pruned: pruned,
            charsRemoved: charsRemoved,
            charsPrunedBefore: charsPrunedBefore
        )
    }

    /// The one `[CompactDiag]` line a pruning pass leaves, or nil when it pruned
    /// nothing.
    ///
    /// - Parameters:
    ///   - result: what the pass landed.
    ///   - skippedSummary: whether summarization was then skipped because the
    ///     pruned request is under the pressure threshold.
    ///   - config: the budgets the pass ran with.
    /// - Returns: the line, or nil.
    public static func diagnosticLine(
        for result: DSHToolResultPruneResult,
        skippedSummary: Bool,
        config: DSHToolResultPruneConfig = DSHToolResultPruneConfig()
    ) -> String? {
        result.diagnosticLine(skippedSummary: skippedSummary, config: config)
    }
}
