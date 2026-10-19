//
//  DSHSpill.swift
//  Minis
//
//  Tool-result spill, ported from DeepSeek Harness
//  (packages/spill/spill-policy/src/{index,retention,notice}.ts).
//
//  WHAT IT IS
//  ----------
//  DSH's spill is NOT a tool the model can call. It is a post-execute hook on
//  the tool pipeline: when a tool result is too large to be worth its tokens,
//  the COMPLETE result is written to a file, the conversation keeps only the
//  head and the tail of it, and a notice is appended saying how many bytes went
//  missing and where the full text now lives.
//
//  The model therefore never loses the answer — it loses the middle, and it is
//  told the path of the file it can read or grep to get the middle back. That
//  only holds if the locator is a path the model's own tools can actually open,
//  which is why the iOS side stores spill files under the session's
//  `/var/minis/offloads/` bucket (see `DSHSpillStore`).
//
//  Ported semantics, kept identical on purpose:
//
//  1. `read` results are NEVER spilled — re-reading the file a spilled result
//     pointed at is the intended recovery, and spilling that read would make
//     recovery itself lossy.
//  2. Only text and image content is handled. Anything else is left alone.
//  3. The unit is TOKENS, never characters.
//  4. The budget is split evenly between the head and the tail (`ceil`/`floor`),
//     and each end is reduced by binary search to the longest run that fits —
//     never cutting a UTF-16 surrogate pair in half.
//  5. Images are indivisible. When one does not fit, the whole image is dropped.
//  6. `\n\n[...]\n\n` marks the elision, and adjacent text blocks are merged.
//  7. The notice wording is fixed (see `DSHSpill.noticeText`).
//
//  The upstream shipped budget is 12 500 tokens, and an OMITTED config disables
//  the feature. Both are reproduced here: `DSHSpillConfig.maxInlineTokens` is an
//  optional, and `DSHSpillConfig.resolvedFromDefaults()` returns nil while the
//  user has never set one.
//
//  This file is deliberately Foundation-only and free of UIKit, file I/O, and
//  any dependency on `AIChatViewModel`: the retention decision is pure and can
//  be exercised without a device. Storage lives in `DSHSpillStore`, wiring in
//  `DSHSpillHook`.
//

import Foundation

// [SELFTEST-COPY-BEGIN] Everything between these two markers is the pure half of
// this file. `_tools/sync-dsh-spill-selftest.ps1` copies it verbatim into
// `_tools/dsh-spill-selftest.swift` (dropping `public`), where it is compiled and
// run on a real Swift toolchain, because this machine cannot run Swift at all.
// The markers exist so the tested copy cannot drift from the shipped one.

// MARK: - Retainable Content

/// One piece of a tool result whose text can be split and whose pixels cannot.
///
/// The iOS tool pipeline produces a result as a string plus an optional image
/// blob, so an image is represented here as one indivisible element carrying an
/// empty string — the shape DSH's `RetainableBlock` reduces to when a result has
/// exactly one image and no separate text run for it.
public struct DSHSpillContent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        case image
    }

    public let kind: Kind
    /// The text run. Empty for an image, whose bytes are indivisible and never
    /// live in this type.
    public let text: String

    public static func text(_ text: String) -> DSHSpillContent {
        DSHSpillContent(kind: .text, text: text)
    }

    public static let image = DSHSpillContent(kind: .image, text: "")

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

// MARK: - Retention

/// What survived a retention pass, in the order the model will see it.
public struct DSHSpillRetention: Sendable, Equatable {
    public let head: [DSHSpillContent]
    public let tail: [DSHSpillContent]
    /// UTF-8 text bytes the pass removed.
    public let omittedBytes: Int
    /// Whole images the pass removed.
    public let omittedImages: Int

    public init(head: [DSHSpillContent], tail: [DSHSpillContent], omittedBytes: Int, omittedImages: Int) {
        self.head = head
        self.tail = tail
        self.omittedBytes = omittedBytes
        self.omittedImages = omittedImages
    }
}

// MARK: - Spill

/// The pure half of the spill policy: budget arithmetic and head/tail retention.
public enum DSHSpill {

    /// The elision marker between the retained head and the retained tail.
    public static let gap = "\n\n[...]\n\n"

    /// Token cost of one text run.
    ///
    /// CHARACTER-CLASS HEURISTIC, not a BPE count. The app's real BPE tokenizer
    /// (`BPETokenizer`, cl100k_base) is `UIKit`-bound and lives behind a
    /// singleton, so calling it here would make the retention decision
    /// untestable off-device and couple a pure policy to the UI layer.
    ///
    /// What the policy actually needs is a MONOTONIC estimate — the retention
    /// pass binary-searches on it, so any positive function of retained length
    /// chooses the same cut for its own notion of "fits". Regressing to an
    /// exact tokenizer changes how much survives, never whether the algorithm is
    /// correct.
    ///
    /// Calibration, checked against cl100k_base on the same three inputs the
    /// app's own estimator was fitted on:
    ///
    ///   * ASCII words and code — letters at 4 per token and punctuation at 2 is
    ///     cl100k's own rough ratio, so word-dominated prose lands within ~10% of
    ///     the real count.
    ///   * CJK — one token per Han/Kana/Hangul scalar plus a 1.5x allowance for
    ///     the 2–3-byte UTF-8 form those scalars carry.
    ///   * Dense binary-ish output (`ls -la`, git logs, base64) — digits at 2 per
    ///     token, which BPE undercuts by roughly twice, hence the density term.
    ///     Long undifferentiated runs are exactly the results that trip a spill,
    ///     so undercounting them is the failure that matters.
    ///
    /// THE ESTIMATE MUST BE MONOTONIC. `retention` binary-searches on it, and a
    /// price that does not rise with retained length makes that search unsound.
    /// The high-density term was an unconditional 2x multiplier on any multi-line
    /// text whose average line ran under 8 characters, which is NOT monotonic:
    /// the average moves as the prefix grows, so a longer prefix can price lower
    /// than a shorter one, and the search then converges on a cut that does not
    /// fit. `_tools/dsh-spill-selftest.swift` caught exactly that (test 10). The
    /// term is therefore a bounded ADDITION rather than a multiplier: it is
    /// non-decreasing in the text length by construction, and it can overstate a
    /// short dense snippet by at most the number of characters in it.
    ///
    /// The density factor is derived, not guessed: cl100k splits a line of
    /// punctuation, digits and single letters into roughly one token per two
    /// characters where the base ratios above give four, so those lines are
    /// priced at 2x — a factor that is 1.0 for prose (average line length far
    /// above 8) and 2.0 for `ls -la`, `git log`, `ps`, base64 and JSON.
    public static func tokenEstimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var letters = 0
        var digits = 0
        var punctuation = 0
        var wide = 0
        var lines = 0
        var copy = text
        copy.withUTF8 { bytes in
            for byte in bytes {
                if byte == 0x0A {
                    lines += 1
                    punctuation += 1
                } else if byte < 0x80 {
                    if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) {
                        letters += 1
                    } else if byte >= 0x30 && byte <= 0x39 {
                        digits += 1
                    } else {
                        punctuation += 1
                    }
                } else if byte & 0xC0 != 0x80 {
                    // One scalar per UTF-8 lead byte; continuation bytes are the
                    // rest of a scalar already counted.
                    wide += 1
                }
            }
        }
        let base = Double(letters) / 4.0 + Double(digits) / 2.0
            + Double(punctuation) / 2.0 + Double(wide) * 1.5
        // Line-structured, high-density text: the shorter the average line, the
        // more the base ratios undercount. Linear and clamped to [0, 1], so this
        // term only ever adds, and never more than the text's own length.
        let total = letters + digits + punctuation + wide
        let averageLine = lines > 0 ? Double(total) / Double(lines) : Double(total)
        let density = max(0.0, min(1.0, (8.0 - averageLine) / 8.0))
        return max(1, Int((base * (1.0 + density) + density * Double(total)).rounded()))
    }

    /// Token cost of one retained block, including the framing a provider adds
    /// per tool-result part. Zero-cost for an image: pixels are not text, and an
    /// image that is kept contributes its own price through the caller's
    /// `imageTokens`, not through this function.
    public static func price(_ block: DSHSpillContent, imageTokens: Int = 0) -> Int {
        switch block.kind {
        case .image: return imageTokens
        case .text: return tokenEstimate(block.text)
        }
    }

    // MARK: - Head / Tail Retention

    /// UTF-16 view of a string that can be cut by offset.
    ///
    /// Swift's own `String.Index` arithmetic is `O(n)` per step, which is `O(n²)`
    /// across a binary search over a multi-hundred-kilobyte result. A `[UInt16]`
    /// array is the same code-unit view DSH's `charCodeAt`/`slice` pair works on,
    /// so the surrogate rule is checked on the exact units upstream checks.
    private struct UTF16Buffer {
        let units: [UInt16]

        init(_ text: String) { units = Array(text.utf16) }

        /// Longest run at one end of `lower..<upper` whose price fits `budget`.
        ///
        /// Monotone by construction: candidate length rises with `middle`, and a
        /// candidate shorter by one code unit never prices higher.
        func fit(lower: Int, upper: Int, tail: Bool, budget: Int, price: (DSHSpillContent) -> Int) -> [UInt16] {
            var low = 0
            var high = upper - lower
            while low < high {
                let middle = (low + high + 1) / 2
                let slice = self.slice(lower: lower, upper: upper, count: middle, tail: tail)
                let cost = price(.text(String(decoding: slice, as: UTF16.self)))
                if slice.isEmpty || cost <= budget {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            return self.slice(lower: lower, upper: upper, count: low, tail: tail)
        }

        /// The first `count` code units of `lower..<upper`, or the LAST `count`
        /// for the tail. `count` is a LENGTH in `0...upper - lower`, never an
        /// offset — mixing the two is what collapsed the tail to nothing.
        ///
        /// The two directions snap a cut differently, and that asymmetry is the
        /// whole point: a head cut must land where the next code point STARTS, a
        /// tail cut where the previous one ENDS. Applying one rule to both left
        /// an unpaired surrogate at the boundary of emoji-heavy text — invisible
        /// in the byte count, and decoded as U+FFFD in front of the model.
        func slice(lower: Int, upper: Int, count: Int, tail: Bool) -> [UInt16] {
            guard upper > lower else { return [] }
            let range = Array(units[lower..<upper])
            let wanted = min(max(0, count), range.count)
            // The whole range, and nothing at all, are decided before the offset
            // arithmetic: a request for the entire range computes an offset of 0
            // from the tail and `range.count` from the head, and both would be
            // mistaken for "no room" by the boundary checks below. That mistake
            // is what emptied the tail for every single-block result.
            if wanted >= range.count { return range }
            if wanted == 0 { return [] }
            var position = tail ? range.count - wanted : wanted
            // Both adjustments move toward the sub-range's own start, so a cut
            // never leaves a dangling low surrogate at its leading edge.
            if position > 0 && position < range.count {
                let previous = range[position - 1]
                let current = range[position]
                let splits = previous >= 0xD800 && previous <= 0xDBFF
                    && current >= 0xDC00 && current <= 0xDFFF
                if splits { position -= 1 }
            }
            if position <= 0 { return [] }
            if position >= range.count { return range }
            return tail ? Array(range[position...]) : Array(range[..<position])
        }
    }

    /// Retain contiguous ends of `content` inside `budget` tokens.
    ///
    /// Mirrors DSH's `retainContent`: the head gets `ceil(budget/2)` and the tail
    /// `floor(budget/2)`, greedy in order from each end, with a partial text run
    /// reduced by binary search. Space an indivisible image cannot use stays
    /// unused rather than being handed to the other end.
    ///
    /// - Parameters:
    ///   - content: ordered blocks, including any images.
    ///   - budget: token budget for the retained ends together.
    ///   - imageTokens: what one retained image costs.
    /// - Returns: the retained ends and the omitted byte and image counts.
    public static func retention(
        of content: [DSHSpillContent],
        budget: Int,
        imageTokens: Int = 1_200
    ) -> DSHSpillRetention {
        func price(_ block: DSHSpillContent) -> Int { self.price(block, imageTokens: imageTokens) }

        var head: [DSHSpillContent] = []
        var tail: [DSHSpillContent] = []
        var first = 0
        var last = content.count - 1
        // How many code units of `content[i]` the head kept, so the tail resumes
        // exactly where the head stopped. NOT the head slice's own length:
        // snapping a cut onto a code-point boundary drops at most one unit, and
        // taking the slice length as a start offset either leaves that unit
        // unpaired in front of the model or, worse, starts the tail a whole run
        // late and silently truncates. The consumed count is the run minus what
        // the slice left behind, and `textSlice` guarantees the leftover begins
        // on a code-point boundary.
        var headUnits: [Int] = Array(repeating: 0, count: content.count)

        var remaining = (budget + 1) / 2
        while first <= last {
            let block = content[first]
            let cost = price(block)
            if cost <= remaining {
                head.append(block)
                remaining -= cost
                headUnits[first] = block.kind == .text ? block.text.utf16.count : 0
                first += 1
                continue
            }
            if block.kind == .text {
                let buffer = UTF16Buffer(block.text)
                let fitted = buffer.fit(lower: 0, upper: buffer.units.count, tail: false, budget: remaining, price: price)
                if !fitted.isEmpty {
                    head.append(.text(String(decoding: fitted, as: UTF16.self)))
                    headUnits[first] = buffer.units.count - fitted.count
                }
            }
            break
        }

        remaining = budget / 2
        while last >= first {
            let block = content[last]
            // A whole block fits: take it as-is. An image is only ever taken
            // whole — it is indivisible, and space one cannot use stays unused.
            if price(block) <= remaining {
                tail.append(block)
                remaining -= price(block)
                last -= 1
                continue
            }
            guard block.kind == .text else { break }
            let buffer = UTF16Buffer(block.text)
            // A run the head already drew from: the tail may only have what the
            // head left. `headUnits[last]` is 0 for a block the head never
            // touched, so one expression covers both cases.
            let start = headUnits[last]
            let fitted = buffer.fit(lower: start, upper: buffer.units.count, tail: true, budget: remaining, price: price)
            if !fitted.isEmpty {
                tail.append(.text(String(decoding: fitted, as: UTF16.self)))
            }
            break
        }
        tail.reverse()

        func bytes(_ blocks: [DSHSpillContent]) -> Int {
            blocks.reduce(0) { $0 + ($1.kind == .text ? $1.text.utf8.count : 0) }
        }
        func images(_ blocks: [DSHSpillContent]) -> Int {
            blocks.reduce(0) { $0 + ($1.kind == .image ? 1 : 0) }
        }
        return DSHSpillRetention(
            head: head,
            tail: tail,
            omittedBytes: bytes(content) - bytes(head) - bytes(tail),
            omittedImages: images(content) - images(head) - images(tail)
        )
    }

    // MARK: - Notice

    /// The retention notice, in DSH's shape and this app's tool names.
    ///
    /// `(Omitted {N} bytes.{ Omitted {M} images.} Full formatted result stored
    /// at: {locator}. Use file_read with offset/limit, or a shell_execute grep on
    /// this path to search within it.)`
    ///
    /// - Parameters:
    ///   - omittedBytes: UTF-8 text bytes removed by the retention pass.
    ///   - images: whole images removed alongside the text.
    ///   - locator: path the full result was written to.
    ///   - priorLocator: path the TOOL LAYER already wrote the complete output to,
    ///     present only when the result this pass shortened had itself been
    ///     truncated before it arrived (see `toolTruncationMarker`).
    /// - Returns: the notice sentence, without a leading separator.
    ///
    /// The two recovery tools are named as this app spells them: DSH says "read"
    /// and "grep", and this app has neither — it has `file_read`, and its grep is a
    /// `shell_execute`. An instruction naming a tool that does not exist is worse
    /// than no instruction: the model is told how to recover and then finds the
    /// tool missing. `hasNotice` matches this string literally, so the two move
    /// together or the idempotence guard stops recognising its own notices.
    ///
    /// WHY THERE ARE TWO PROVENANCE SENTENCES.
    ///
    /// "Full formatted result stored at: {locator}" is a promise about the FILE,
    /// and this pass can only keep it when the content it was handed was the
    /// whole result. It is not: `MAX_TOOL_RESULT_CHARS` runs before this hook, so
    /// a 48 KB command output reaches here already cut to 15 KB plus the tool
    /// layer's own offload notice. Spilling THAT writes the preview to
    /// `{locator}` — so the old sentence pointed the model at a file holding the
    /// preview while claiming it held the result, and the tool layer's own
    /// pointer to the 48 KB original survived only if it happened to fall inside
    /// the retained tail. The model then either re-read a file that was still
    /// truncated or re-ran the command, which is the "result looks short, turn
    /// does not move" report.
    ///
    /// So the notice states which of the two it is: the locator holds the result
    /// (nothing was shortened before this pass), or the locator holds the retained
    /// head and tail of an ALREADY-truncated result and the complete output is at
    /// the path the tool layer named. The recovery sentence after the locator is
    /// byte-identical in both forms, and `hasNotice` keys on it, so a preview
    /// written by either form is still recognised as a preview.
    public static func noticeText(
        omittedBytes: Int,
        images: Int,
        locator: String,
        priorLocator: String? = nil,
        priorTruncated: Bool = false
    ) -> String {
        let imageNotice = images > 0 ? " Omitted \(images) images." : ""
        // Explicitly branched rather than `map`/`??`: the forms differ in what they
        // claim about the file, so the choice is worth reading as one.
        let provenance: String
        if !priorTruncated {
            provenance = fullResultProvenance
        } else if let priorLocator {
            provenance = priorTruncationProvenance + priorTruncationCompleteClause
                + priorLocator + ". This preview is stored at: "
        } else {
            provenance = priorTruncationProvenance + priorTruncationNoCopyClause
                + " This preview is stored at: "
        }
        return "(Omitted \(omittedBytes) bytes.\(imageNotice)\(provenance)"
            + "\(locator)\(recoveryTail)"
    }

    /// The separator between a retained tail and the notice: the notice is its
    /// own paragraph, matching DSH's `"\n\n" + notice`.
    public static let noticeSeparator = "\n\n"

    /// The sentence that tells the model how to read the whole thing back. Both
    /// notice forms end with it, `hasNotice` matches it literally, and the two
    /// therefore cannot drift apart.
    ///
    /// [T-spill-notice-voice] This sentence is the one place a spill says what to
    /// DO, so it carries the whole burden of keeping the model on task. It used to
    /// read `Use file_read with offset/limit, or a shell_execute grep on this path
    /// to search within it.` — an accurate sentence that names no offset and does
    /// not say the content is recoverable, which is how a bounded result got
    /// reported to the user as "内容被截断了" (operator report, 2026-10-19). A
    /// truncation the tool handled is not a failure the user needs to hear about;
    /// it is an instruction the model should follow. The wording is an imperative
    /// naming the offset parameter, and states outright that nothing was lost.
    public static let recoveryTail =
        ". Nothing was lost: the result was relocated to disk, not discarded."
        + " To read it, call file_read with offset=<line number> on this path,"
        + " or run a shell_execute grep on this path to search within it.)"

    /// Provenance sentence for a result this pass shortened from the original.
    public static let fullResultProvenance = " Full formatted result stored at: "

    /// Provenance sentence for a result the TOOL LAYER had already shortened
    /// before this pass saw it. A different claim from the sentence above: what
    /// sits at the locator after it is a preview, not the result.
    ///
    /// Split in three so the sentence can finish honestly in both cases: the tool
    /// layer's own notice usually names the file holding the complete output (its
    /// `… saved to: <path>` clause), but not always — the offload read-back branch
    /// truncates in place and names no new file. `hasNotice` keys on the shared
    /// prefix, so all three forms are recognised as previews.
    ///
    /// [T-spill-notice-voice] Was `The tool layer had already truncated this
    /// result; `. "Already truncated" reads as a fault the model should report and
    /// is the second half of the same operator complaint the recovery tail carries
    /// a note about; the replacement states the same fact as a description of the
    /// text in hand ("a preview"), which is what the model needs in order to tell
    /// a bounded result from a lost one.
    public static let priorTruncationProvenance =
        " This result was cut to a preview before this pass saw it; "

    /// Completion of that sentence when the tool layer named a file.
    public static let priorTruncationCompleteClause = "the complete output is saved at: "

    /// Completion of that sentence when it did not.
    ///
    /// [T-spill-notice-voice] Was `no complete copy of it is addressable from
    /// here.` — the one sentence in either notice that gives the model nothing to
    /// do, which made it the most likely thing in the result to be quoted back to
    /// the user as a defect. The replacement is true in the same case and points
    /// at the two things that actually remain available.
    public static let priorTruncationNoCopyClause =
        "the untruncated text is not addressable as a file from here;"
        + " work from the preview above, or re-run the command with a narrower query."

    /// Whether a result carries a spill notice at its end.
    ///
    /// Used to keep an already-spilled result from being spilled again when a
    /// session is replayed or resumed: the second pass would truncate an
    /// already-truncated preview and point the model at a file that contains the
    /// preview rather than the original.
    ///
    /// The notice always sits at the very end of the result, so this scans for
    /// the LAST opening parenthesis rather than for a `"\n\n("` separator. The
    /// bound form carries a locator that can itself contain `\n\n(` — a spilled
    /// result whose own text ended in a parenthesis is exactly that — and
    /// requiring the separator before it made a real notice unrecognisable.
    ///
    /// The provenance sentence is checked as well as the recovery tail: the tail
    /// alone would also match the tool layer's own offload notice, whose point is
    /// the opposite (it is bounded, not a spill preview, and must still be
    /// spillable when the budget asks for it).
    public static func hasNotice(_ text: String) -> Bool {
        guard text.hasSuffix(")") else { return false }
        guard let open = text.range(of: "(", options: .backwards) else { return false }
        let candidate = text[open.upperBound...]
        guard candidate.hasPrefix("Omitted ") else { return false }
        guard candidate.contains(recoveryTail) else { return false }
        return candidate.contains(fullResultProvenance)
            || candidate.contains(priorTruncationProvenance)
    }
}

// MARK: - Decision

/// What the spill policy decided about one tool result.
public struct DSHSpillDecision: Sendable {
    /// The result the model will see: retained head, elision marker, retained
    /// tail, and the notice.
    public let blocks: [DSHSpillContent]
    public let omittedBytes: Int
    public let omittedImages: Int
    /// True when an image the model produced was dropped whole. The result's own
    /// image blob is then dropped with it, so the model is not handed pixels its
    /// text no longer accounts for.
    public let imageDropped: Bool
    /// The tool layer's own offload path, when the result this pass shortened had
    /// already been truncated before the spill saw it. Carried so the caller can
    /// log which of the two cuts a `[DSH][Spill]` line is describing.
    public let priorLocator: String?

    /// The model-facing text, blocks joined with nothing between them (text runs
    /// were merged by construction).
    public var text: String {
        blocks.reduce(into: "") { accumulated, block in
            if block.kind == .text { accumulated += block.text }
        }
    }

    public init(
        blocks: [DSHSpillContent],
        omittedBytes: Int,
        omittedImages: Int,
        imageDropped: Bool,
        priorLocator: String? = nil
    ) {
        self.blocks = blocks
        self.omittedBytes = omittedBytes
        self.omittedImages = omittedImages
        self.imageDropped = imageDropped
        self.priorLocator = priorLocator
    }
}

// MARK: - Config

/// Spill configuration.
///
/// `maxInlineTokens` is an OPTIONAL and its absence is the off switch, which is
/// DSH's own rule for this plugin: the deployed plugin carries no value, and
/// omitting `maxInlineTokens` leaves the feature inert. `0` and any negative
/// value disable it too, so a key explicitly set to zero is not ambiguous.
public struct DSHSpillConfig: Sendable, Equatable {

    /// Maximum estimated tokens in a retained tool result, including the notice.
    /// nil disables spill entirely.
    public var maxInlineTokens: Int?

    /// What one retained image is charged. Images are priced from pixel count in
    /// DSH; on iOS the result's blob is already on disk by the time it reaches
    /// the model (its durable path is what the model re-reads), so a fixed
    /// allowance is used instead of decoding the image on the main actor.
    public var imageTokens: Int

    /// Age in days after which a spill file is eligible for the one-shot startup
    /// sweep. `0` disables cleanup. Fresh, unrelated, and non-matching entries
    /// are never touched.
    public var cleanupPeriodDays: Int

    /// What one retained image is charged when the caller does not say.
    public static let defaultImageTokens = 1_200

    public init(maxInlineTokens: Int? = nil, imageTokens: Int = DSHSpillConfig.defaultImageTokens, cleanupPeriodDays: Int = 30) {
        self.maxInlineTokens = maxInlineTokens
        self.imageTokens = imageTokens
        self.cleanupPeriodDays = cleanupPeriodDays
    }

    /// DSH's shipped budget on the host, and the value used here once the user
    /// turns the feature on.
    public static let shippedMaxInlineTokens = 12_500

    /// UserDefaults key. Absent, non-numeric, `0`, or negative all mean DISABLED.
    public static let maxInlineTokensKey = "minis.dshSpillMaxInlineTokens"

    /// UserDefaults key for the cleanup window, in days. Only read once the
    /// feature is on; absent means 30.
    public static let cleanupPeriodDaysKey = "minis.dshSpillCleanupDays"

    /// Compile-time probe, in the same spirit as `dshCompactionProbeEnabled`.
    ///
    /// A probe build spills every result over `probeMaxInlineTokens`, so a device
    /// log carries a real `[DSHSpill]` line without anyone having to find the
    /// switch first — which matters because the feature has never been exercised
    /// on a device. It is a compilation condition and not a runtime key for the
    /// same reason the compaction probe is: the app registers its own defaults at
    /// launch and rewrites the plist, so a key written from outside is discarded.
    /// Off unless the build asks for it (CI: the `spill_probe` input).
    public static var probeEnabled: Bool {
        #if DSH_SPILL_PROBE
        return true
        #else
        return false
        #endif
    }

    /// The budget a probe build runs on. Low enough that an ordinary `shell`,
    /// `web_fetch` or `browser_use` result crosses it, high enough that the
    /// retained head and tail still have something to keep.
    public static let probeMaxInlineTokens = 600

    /// Turn the feature on or off, and set the budget that applies while it is on.
    ///
    /// Writes `0` rather than removing the key when the switch goes off:
    /// `resolvedFromDefaults` treats an absent key and a non-positive one alike, and
    /// an explicit zero records that the choice was made on purpose — which an
    /// absent key cannot distinguish from "never asked".
    ///
    /// - Parameter maxInlineTokens: the budget to store while enabled. A
    ///   non-positive value is raised to 1 rather than stored as-is, because a
    ///   stored 0 would mean "off" and make the switch disagree with itself.
    public static func setEnabled(
        _ enabled: Bool,
        maxInlineTokens: Int,
        cleanupPeriodDays: Int? = nil,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled ? max(1, maxInlineTokens) : 0, forKey: maxInlineTokensKey)
        if let days = cleanupPeriodDays {
            defaults.set(max(0, days), forKey: cleanupPeriodDaysKey)
        }
    }

    /// Resolve the configuration from user defaults.
    ///
    /// Deliberately built on `object(forKey:)` rather than `integer(forKey:)`:
    /// `integer` cannot distinguish "never set" from "set to 0", and the whole
    /// point of the optional is that unset means off.
    ///
    /// - Returns: the resolved configuration, or nil while spill is disabled.
    public static func resolvedFromDefaults(_ defaults: UserDefaults = .standard) -> DSHSpillConfig? {
        // The probe is checked first and it wins: a probe build exists to produce a
        // spill, and a stored setting that quietly suppressed it would make the
        // build lie about what it is. The cleanup window is still honoured, since
        // it cannot stop a spill from happening.
        if probeEnabled {
            let days = (defaults.object(forKey: cleanupPeriodDaysKey) as? Int) ?? 30
            return DSHSpillConfig(
                maxInlineTokens: probeMaxInlineTokens,
                cleanupPeriodDays: max(0, days)
            )
        }
        guard let stored = defaults.object(forKey: maxInlineTokensKey) as? Int else { return nil }
        guard stored > 0 else { return nil }
        let days = (defaults.object(forKey: cleanupPeriodDaysKey) as? Int) ?? 30
        return DSHSpillConfig(
            maxInlineTokens: stored,
            cleanupPeriodDays: max(0, days)
        )
    }

    /// The budget handed to `plan`, or nil when disabled.
    public var effectiveBudget: Int? {
        guard let cap = maxInlineTokens, cap > 0 else { return nil }
        return cap
    }
}

// MARK: - Planning

extension DSHSpill {

    /// Tools whose results are never spilled.
    ///
    /// The read half is DSH's own exclusion and it is the load-bearing one: the
    /// notice tells the model to read the spill file back, so spilling a read would
    /// make the recovery step lossy in exactly the case the feature exists for.
    /// `read_image` is the iOS analogue — it is how a dropped image is recovered.
    ///
    /// DSH spells the read tool `read`; this app spells it `file_read` (its roster
    /// is `shell_execute`, `file_read`, `file_write`, `file_edit`, `browser_use`,
    /// `memory_write`, `memory_get`, `read_image`, `todo_write`, `exit_plan_mode`).
    /// The name here has to be THIS app's spelling. Measured on a device
    /// 2026-10-17: with `read` the exemption never fired, so a spilled result was
    /// read back with `file_read`, that read was spilled too, and the model spent a
    /// turn reading spill files instead of answering.
    public static let exemptTools: Set<String> = ["file_read", "read_image"]

    /// What the TOOL LAYER writes into a result it shortened itself.
    ///
    /// `AIChatViewModel.executeSingleToolUse` caps a tool result at
    /// `kMaxToolResultChars`, writes the complete output under `/var/minis/offloads/`
    /// and appends `[OUTPUT TRUNCATED]` followed by that path. `file_read` marks its
    /// own, different cut with a `truncated at N chars` header instead.
    ///
    /// The spill policy did not know about either marker, which made it treat an
    /// already-bounded result as an unbounded one and spill it a second time. That
    /// is not merely redundant: the second pass writes what it was GIVEN, so the
    /// file it names holds the first cut, and the notice's "full result" claim was
    /// false. Both markers are therefore recognised here.
    public static let toolTruncationMarker = "[OUTPUT TRUNCATED]"

    /// The same marker after it was reworded to stop reading as a failure.
    ///
    /// The sentence that follows it now says the result was moved rather than lost and
    /// names the call that reaches the rest, because the model used to relay "the tool
    /// output was truncated" to the user as if the work had failed. Both spellings name
    /// a second file, so both have to resolve a locator — results written by older
    /// builds are still on disk.
    public static let toolShortenedMarker = "[OUTPUT SHORTENED]"

    /// Whether a result was already shortened by the tool layer.
    ///
    /// `file_read`'s header form is deliberately NOT included: it is a paging
    /// header on a bounded read (`truncated at N chars, next_offset=…`) with no
    /// second file behind it, so there is nothing to point a notice at, and the
    /// spill budget still has to be able to bound that result.
    public static func hasToolTruncationMarker(_ text: String) -> Bool {
        text.contains(toolTruncationMarker) || text.contains(toolShortenedMarker)
    }

    /// The path the tool layer named as holding the complete output, when it
    /// shortened this result.
    ///
    /// Read out of the marker's own sentence — `… saved to: <path>` — and stopped
    /// at the first line break, so the `minis_url:` line that follows it and the
    /// "Use file_read tool to read the complete output." line after that are not
    /// swallowed into the path. Returns nil rather than an empty or partial path
    /// when the sentence is not there: a notice pointing at nothing is worse than
    /// a notice that does not mention a second file.
    public static func toolTruncationLocator(in text: String) -> String? {
        guard hasToolTruncationMarker(text) else { return nil }
        guard let range = text.range(of: "saved to: ", options: .backwards) else { return nil }
        let rest = text[range.upperBound...]
        let line = rest.prefix { $0 != "\n" && $0 != "\r" }
        let path = line.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    /// The one-line record a SHORTENED tool result leaves in the app log.
    ///
    /// One shape for every site that shortens one — the tool layer's character cap
    /// and this spill — so a device log can be read for "was anything shortened,
    /// and was the model told" without knowing which mechanism did it. `notified`
    /// is the field that matters and it is always written: a shortening with no
    /// model-visible marker is the failure mode this line exists to expose, and it
    /// cannot be reported by a line that is only emitted when a marker was added.
    ///
    /// - Parameters:
    ///   - mechanism: `tool-cap` for `kMaxToolResultChars`, `spill` for this pass.
    ///   - originalChars: the result's length before it was shortened.
    ///   - keptChars: what the model received, notice included.
    ///   - locator: where the complete text went, when there is one.
    ///   - notified: whether the model's copy names the cut and its locator.
    public static func truncationLogLine(
        toolName: String,
        callId: String,
        mechanism: String,
        originalChars: Int,
        keptChars: Int,
        locator: String?,
        notified: Bool
    ) -> String {
        "[ToolResult] truncated tool=\(toolName) id=\(callId) by=\(mechanism)"
            + " original=\(originalChars) kept=\(keptChars)"
            + " locator=\(locator ?? "-") notified=\(notified ? "yes" : "no")"
    }

    /// Decide whether one tool result must be spilled, and if so what the model
    /// sees instead.
    ///
    /// Pure: no file is written and no default is read. The caller writes
    /// `content` to disk and substitutes the returned locator into the notice.
    ///
    /// - Parameters:
    ///   - toolName: the tool that produced the result.
    ///   - content: the result's text and any indivisible image.
    ///   - budget: `maxInlineTokens` from the config.
    ///   - locatorPlaceholder: path text to put in the notice; the caller
    ///     replaces it once the file exists, so the decision never has to wait
    ///     for I/O.
    ///   - imageTokens: what one retained image is charged.
    /// - Returns: the decision, or nil when the result fits, is exempt, or is
    ///   already a spill preview.
    public static func plan(
        toolName: String,
        content: [DSHSpillContent],
        budget: Int,
        locatorPlaceholder: String,
        imageTokens: Int = 1_200
    ) -> DSHSpillDecision? {
        guard budget > 0 else { return nil }
        guard !exemptTools.contains(toolName) else { return nil }
        // Only text and image content is handled; anything else is left alone.
        guard !content.isEmpty else { return nil }
        let retainable = content.allSatisfy { $0.kind == .text || $0.kind == .image }
        guard retainable else { return nil }

        func price(_ block: DSHSpillContent) -> Int { DSHSpill.price(block, imageTokens: imageTokens) }
        let hasImages = content.contains(where: { $0.kind == .image })
        // A result with neither text nor pixels has nothing to retain, so it is
        // left alone rather than being replaced by a bare notice.
        let hasText = content.contains(where: { $0.kind == .text && !$0.text.isEmpty })
        guard hasText || hasImages else { return nil }

        var combinedText = ""
        for block in content where block.kind == .text { combinedText += block.text }
        let imageCount = content.reduce(0) { $0 + ($1.kind == .image ? 1 : 0) }
        let combinedTotal = tokenEstimate(combinedText) + imageCount * imageTokens
        var perBlockTotal = 0
        for block in content { perBlockTotal += price(block) }
        let total = max(perBlockTotal, combinedTotal)
        guard total > budget else { return nil }
        // A result already carrying a notice is a preview: spilling it again
        // would point the model at a file holding the preview, not the original.
        guard !hasNotice(combinedText) else { return nil }

        // A result the TOOL LAYER already bounded is the same hazard one step
        // earlier, so it gets the same treatment with the difference stated: this
        // pass still bounds it (its 15 000 characters are what the budget is
        // arguing with), but the notice names the tool layer's own file as the
        // home of the complete output instead of claiming the spill file is —
        // and says so plainly when the tool layer's notice names no file at all.
        let priorTruncated = hasToolTruncationMarker(combinedText)
        let priorLocator = toolTruncationLocator(in: combinedText)

        let totalBytes = combinedText.utf8.count
        let worstNotice = noticeText(
            omittedBytes: totalBytes,
            images: imageCount,
            locator: locatorPlaceholder,
            priorLocator: priorLocator,
            priorTruncated: priorTruncated
        )

        // DSH reserves the gap and the notice before retaining, and sizes the
        // rest of the result against what is left. A 2% margin is added on top:
        // the estimator overstates real token counts by up to ~2x on dense text,
        // but it can still land a token or two above its own budget when the
        // density term changes across the retained slices, and an exact cap is
        // worth more than the handful of tokens the margin costs. The
        // reservation can exceed the budget in principle; `retention` then keeps
        // nothing and the notice stands alone, which is a bounded result rather
        // than an unbounded one.
        let reserved = tokenEstimate(gap) + tokenEstimate(noticeSeparator + worstNotice)
        let margin = max(0, budget / 50)
        let retained = retention(of: content, budget: budget - reserved - margin, imageTokens: imageTokens)
        let notice = noticeText(
            omittedBytes: retained.omittedBytes,
            images: retained.omittedImages,
            locator: locatorPlaceholder,
            priorLocator: priorLocator,
            priorTruncated: priorTruncated
        )

        var blocks: [DSHSpillContent] = retained.head
        if !retained.head.isEmpty || !retained.tail.isEmpty {
            blocks.append(.text(gap))
            blocks.append(contentsOf: retained.tail)
            blocks.append(.text(noticeSeparator + notice))
        } else {
            blocks = [.text(notice)]
        }

        // Adjacent text has one framing cost on the wire and in the preview, so
        // the retained runs and the notice are merged into single text blocks.
        var merged: [DSHSpillContent] = []
        var mergedText = ""
        for block in blocks {
            if block.kind == .text {
                mergedText += block.text
            } else {
                if !mergedText.isEmpty {
                    merged.append(.text(mergedText))
                    mergedText = ""
                }
                merged.append(block)
            }
        }
        if !mergedText.isEmpty { merged.append(.text(mergedText)) }

        return DSHSpillDecision(
            blocks: merged,
            omittedBytes: retained.omittedBytes,
            omittedImages: retained.omittedImages,
            imageDropped: hasImages && retained.omittedImages > 0,
            priorLocator: priorLocator
        )
    }

    /// Replace the placeholder locator with the real path once the file exists.
    ///
    /// - Parameters:
    ///   - decision: the decision returned by `plan`.
    ///   - locator: the path the full result was written to.
    /// - Returns: the decision with the locator substituted.
    public static func binding(_ decision: DSHSpillDecision, to locator: String) -> DSHSpillDecision {
        let rebound = decision.blocks.map { block -> DSHSpillContent in
            guard block.kind == .text, block.text.contains(locatorPlaceholder) else { return block }
            return .text(block.text.replacingOccurrences(of: locatorPlaceholder, with: locator))
        }
        return DSHSpillDecision(
            blocks: rebound,
            omittedBytes: decision.omittedBytes,
            omittedImages: decision.omittedImages,
            imageDropped: decision.imageDropped,
            priorLocator: decision.priorLocator
        )
    }

    /// The token the notice carries until the spill file has a real path.
    public static let locatorPlaceholder = "\u{0}DSHSPILL-LOCATOR\u{0}"

    /// The one-line record a spilled result leaves in the app log.
    ///
    /// The shape is DSH's and the fields already parsed elsewhere are unchanged at
    /// the front; the three appended ones are what a truncation post-mortem needs
    /// and what the older line could not answer — how much the model actually
    /// received, whether it was told, and whether this spill was sitting on top of
    /// an earlier cut. `notified=yes` is unconditional here because this line is
    /// only emitted after the notice has been bound into the result.
    ///
    /// - Parameters:
    ///   - toolName: the tool whose result was spilled.
    ///   - callId: the provider-side call id.
    ///   - tokens: estimated tokens in the original result.
    ///   - omittedBytes: UTF-8 bytes the model did not receive.
    ///   - locator: where the full result was written.
    ///   - keptChars: characters the model received, notice included. Zero means
    ///     the caller did not measure it, and the field is then omitted.
    ///   - priorLocator: the tool layer's own offload path, when this result had
    ///     already been truncated before the spill saw it.
    /// - Returns: the log line.
    public static func logLine(
        toolName: String,
        callId: String,
        tokens: Int,
        omittedBytes: Int,
        locator: String,
        keptChars: Int = 0,
        priorLocator: String? = nil
    ) -> String {
        var line = "[DSH][Spill] tool=\(toolName) id=\(callId) tokens=\(tokens)"
            + " omitting=\(omittedBytes) locator=\(locator)"
        if keptChars > 0 { line += " kept=\(keptChars)" }
        line += " notified=yes"
        if let priorLocator { line += " prior=\(priorLocator)" }
        return line
    }
}

// [SELFTEST-COPY-END]
