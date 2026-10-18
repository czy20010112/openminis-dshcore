//
//  DSHContextUsage.swift
//  Minis
//
//  What "how full is the context" is allowed to be answered with.
//
//  The device log of 2026-10-18 is the reason this file exists. One 262k-window
//  session, one turn, and the two figures the app published for the same request:
//
//    [DSH] usage report: prompt=189546        ← what the provider counted
//    [CompactDiag] estimate … total=77655tok  ← what the app published
//
//  2.44× apart, and the low one was on screen. The app's figure is a
//  character-proportional heuristic (`DSHTokenEstimate`, 3.6 chars/token;
//  `estimateContextTokens`, 3.5) over `String.count`, plus a per-image constant.
//  Both halves of that are wrong on this corpus:
//
//    * the density constant. The same log's own per-message dump is
//      `115750chars+9905imgTok → 42976tok`, i.e. 69,668 tokens
//      `(42976 − 9905) × 2` … and the provider charged 189,546 for that
//      conversation's request. The text tokens the provider actually billed
//      cannot be reconciled with 3.5 chars/token at that character count — the
//      real corpus is token-dense CJK/tool JSON/base64, not the mixed prose the
//      constant assumes;
//    * the per-image constant (~85–1,100) against a vision model's real
//      per-image cost, which is thousands;
//    * nothing at all for the request framing — role tags, per-block JSON
//      structure, or the tool-result envelope.
//
//  Upstream DSH does not have this problem, and the mechanism it uses is copied
//  here: `packages/llm/token-meter/src/index.ts` reprices under its fixed-density
//  heuristic only while the latest successful call's request envelope no longer
//  matches; matching means the provider's own `TokenUsage` is reused, and it is
//  the provider's figure that `compaction-basic` gates on
//  (`packages/compaction/compaction-basic/src/index.ts`, `meter.measure`). The
//  heuristic there is a fallback, never the published number.
//
//  So this type holds the measured figure and says so, and the estimator is
//  demoted to what the estimate must be: a value with an expiry and a label.
//

import Foundation

// MARK: - One measured request

/// What the provider counted for the newest request it answered, plus the
/// surface it counted it against.
///
/// This is the single source of truth for a context readout. It is not an
/// estimate and carries no estimate of its own: the only arithmetic it offers is
/// the growth of the conversation since the request went out, and that growth is
/// signed so a compaction is allowed to make the figure smaller.
public struct DSHMeasuredContext: Sendable, Equatable {

    /// The provider's own prompt-side count for that response: uncached input
    /// plus both cache buckets, which is `TokenUsage.latestContextTokens` and the
    /// same denominator the cache-hit row uses.
    public let promptTokens: Int

    /// The app's **whole-envelope** estimate the same request was assembled from:
    /// system prompt + tool roster + surface, which is exactly the figure the
    /// breakdown sheet displays. The surface alone would be the wrong baseline
    /// for growth — the conversation is the only part of the envelope that grows
    /// between two requests, so the two estimates must be taken over the same
    /// components for their difference to mean anything.
    public let envelopeTokens: Int

    /// The conversation that request belonged to.
    public let sessionKey: String

    /// When the provider's report landed.
    public let reportedAt: Date

    public init(promptTokens: Int, envelopeTokens: Int, sessionKey: String, reportedAt: Date) {
        self.promptTokens = promptTokens
        self.envelopeTokens = envelopeTokens
        self.sessionKey = sessionKey
        self.reportedAt = reportedAt
    }

    /// The measured figure with `envelopeTokensNow`'s growth since the request
    /// added to it.
    ///
    /// Growth is `now − atReport`, so a surface that shrank — a compaction, an
    /// offload, an image trim — subtracts, and the readout follows it down
    /// instead of freezing at its pre-compaction value until the next response.
    ///
    /// - Parameter envelopeTokensNow: the current estimate of the same envelope.
    /// - Returns: the provider's count for the request this envelope would make.
    public func projected(envelopeTokensNow: Int) -> Int {
        promptTokens + (envelopeTokensNow - envelopeTokens)
    }

    /// The same measurement, re-based onto an envelope measured later.
    ///
    /// A response whose request was priced before a later assembly reported a
    /// different envelope would otherwise carry a stale baseline forward. The
    /// prompt count is the provider's and does not move; only the baseline does.
    ///
    /// - Parameter envelopeTokens: the envelope to measure growth from now on.
    /// - Returns: the measurement with a replaced baseline.
    public func rebased(envelopeTokens: Int) -> DSHMeasuredContext {
        DSHMeasuredContext(
            promptTokens: promptTokens,
            envelopeTokens: envelopeTokens,
            sessionKey: sessionKey,
            reportedAt: reportedAt
        )
    }
}

// MARK: - Store

/// Which figure a readout is showing.
///
/// A readout is never allowed to be ambiguous about this: the defect this enum
/// was added for is a request-envelope estimate rendered exactly like a measured
/// occupancy, which is how a 262k window came to read "~60K used" while the
/// provider was charging 189,546 for every step.
public enum DSHContextUsageSource: Sendable, Equatable {
    /// The provider's own tokenizer counted it. This is the context's occupancy.
    case providerMeasured
    /// The app's estimator priced the request envelope (system prompt + tool
    /// roster + surface). Not the occupancy: a value with an expiry, shown only
    /// while no provider count covers the request on screen.
    case requestEnvelopeEstimate
    /// Nothing has been sent in this session and nothing has been reported for
    /// it. There is no figure, and a caller must render none rather than zero.
    case none
}

/// The store every context readout and every budget fallback reads.
///
/// One owner per fact: the measured figure is written where the provider reports
/// and nowhere else, and every consumer reads that value rather than keeping its
/// own. Before this existed the ring, the breakdown sheet's row, the compaction
/// gate and `dynamicMaxTokens` each read a different estimator, which is how the
/// same request could be 77,655 tokens in the log and 189,546 in the engine.
///
/// Main-actor isolated rather than lock-guarded, matching
/// `DSHContextBreakdownStore`: every writer is already on the main actor (the
/// driver's request assembly, the adapter's usage report) and every reader is a
/// view body. This app has no main-thread watchdog budget for a second
/// concurrency scheme here.
@MainActor
final class DSHContextUsageStore {

    static let shared = DSHContextUsageStore()

    /// The newest provider report, or nil when none has landed for `sessionKey`.
    private(set) var measured: DSHMeasuredContext?

    /// The session every value in this store belongs to.
    ///
    /// The store is process-global and the app switches conversations, so a value
    /// that outlives its session is worse than no value: a new chat used to open
    /// on its predecessor's numbers because nothing reset the shared store —
    /// `DSHContextBreakdownStore.clear()` exists but had no caller.
    private(set) var sessionKey: String?

    private init() {}

    /// Point the store at a session, dropping every value that belonged to
    /// another one.
    ///
    /// - Parameter sessionKey: the conversation the next readout describes.
    /// - Returns: true when the binding moved, so a caller can tell a first
    ///   binding from a repeat.
    @discardableResult
    func bind(sessionKey: String?) -> Bool {
        guard sessionKey != self.sessionKey else { return false }
        self.sessionKey = sessionKey
        measured = nil
        return true
    }

    /// Record the provider's count for a response, against the envelope the
    /// request carrying it was built from.
    ///
    /// - Parameters:
    ///   - promptTokens: the provider's prompt-side total for that response.
    ///   - envelopeTokens: the whole-envelope estimate measured when the same
    ///     request was assembled. Zero is accepted and simply disables growth
    ///     projection until an envelope is measured again.
    ///   - sessionKey: the conversation the response belongs to. A report for a
    ///     session the store is not bound to is dropped rather than adopted: a
    ///     late response from the conversation the user just left must not become
    ///     the new one's occupancy.
    /// - Returns: true when the stored measurement changed.
    @discardableResult
    func record(promptTokens: Int, envelopeTokens: Int, sessionKey: String?, at date: Date = Date()) -> Bool {
        guard promptTokens > 0 else { return false }
        guard let sessionKey, sessionKey == self.sessionKey else { return false }
        let next = DSHMeasuredContext(
            promptTokens: promptTokens,
            envelopeTokens: max(0, envelopeTokens),
            sessionKey: sessionKey,
            reportedAt: date
        )
        guard next != measured else { return false }
        measured = next
        return true
    }

    /// Re-base the stored measurement on a newer envelope assembly.
    ///
    /// Called where an envelope is assembled and no response is waiting on it —
    /// the request path that prices the same request the provider is about to see.
    /// Without it the growth projection would count everything appended between
    /// the measurement and the new assembly as growth twice: once by the provider
    /// itself in its own count, and again as this difference.
    ///
    /// - Parameter envelopeTokens: the envelope just assembled. Zero (no
    ///   envelope measured) is a no-op rather than a reset: an unknown envelope is
    ///   not a smaller one.
    func rebase(envelopeTokens: Int) {
        guard let measured, envelopeTokens > 0, measured.envelopeTokens != envelopeTokens else { return }
        self.measured = measured.rebased(envelopeTokens: envelopeTokens)
    }

    /// The measurement projected onto a request whose whole envelope is known.
    ///
    /// The one place the growth projection is formed, so the ring, the sheet and
    /// `dynamicMaxTokens` cannot disagree about it by passing different baselines.
    ///
    /// The arithmetic is deliberately open-ended in both directions. It has to be:
    /// the caller supplies the CURRENT estimate of the same envelope the
    /// measurement was taken against, so the difference is the conversation's
    /// growth since the provider counted it — positive while a turn runs, negative
    /// after a compaction, and in neither case something to clamp away. A
    /// readout that only ever climbs cannot show a compaction working, and one
    /// that freezes at the last count cannot show a turn filling the window.
    ///
    /// - Parameters:
    ///   - promptTokensNow: this app's estimate of the system prompt as it is
    ///     assembled now.
    ///   - toolTokensNow: this app's estimate of the tool roster now.
    ///   - surfaceTokensNow: this app's estimate of the conversation now.
    /// - Returns: the measurement projected onto this request, or nil when no
    ///   provider has reported one for this session.
    func occupancy(promptTokensNow: Int, toolTokensNow: Int, surfaceTokensNow: Int) -> Int? {
        guard let measured, measured.promptTokens > 0 else { return nil }
        let envelopeNow = max(0, promptTokensNow) + max(0, toolTokensNow) + max(0, surfaceTokensNow)
        // A zero baseline means no request was ever measured against this
        // session's envelope — there is no delta to add, so the provider's own
        // count stands rather than a guess about growth.
        let baseline = measured.envelopeTokens > 0 ? measured.envelopeTokens : envelopeNow
        return max(1, measured.promptTokens + (envelopeNow - baseline))
    }

    /// The convenience form for a readout whose "envelope" figure is one number —
    /// the whole request, as the context sheet and `dynamicMaxTokens` both hold it.
    ///
    /// - Parameter envelopeTokensNow: this app's estimate of the whole request
    ///   envelope (prompt + roster + conversation).
    /// - Returns: the measurement projected onto this request, or nil.
    func occupancy(envelopeTokensNow: Int) -> Int? {
        occupancy(promptTokensNow: 0, toolTokensNow: 0, surfaceTokensNow: envelopeTokensNow)
    }

    /// The envelope estimate the newest measured report was taken against, or nil
    /// when none has been reported for this session.
    ///
    /// Exposed because it is what `DSHContextBreakdown.isMeasured` compares its own
    /// total against, and a comparison against a private field could not be
    /// asserted from outside the file.
    var measuredEnvelopeTokens: Int? { measured?.envelopeTokens }

    /// Drop the measurement, keeping the session binding.
    ///
    /// Not wired to a call site: `bind(sessionKey:)` covers the only case that
    /// matters (the conversation changed). It exists so a caller that knows the
    /// session's content was replaced — a clear, a rewind — has one call to make
    /// rather than a private field to reach for.
    func clearMeasurement() {
        if measured != nil { measured = nil }
    }
}
