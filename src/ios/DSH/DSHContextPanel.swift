//
//  DSHContextPanel.swift
//  Minis
//
//  The context ring in the composer, and the breakdown sheet behind it.
//
//  Two figures describe "how full is the context":
//
//    * the ring's arc and the sheet's HEADER show what the PROVIDER reported for
//      its last call — `ChatMessage.usage.latestContextTokens` on the newest
//      usage-bearing assistant row. That is the measured figure, and it is what
//      the model will actually be sent next turn. While a turn is still running
//      there is no such row yet, and if the panel were gated on one it would sit
//      blank for the whole first turn — the operator's report that the main
//      conversation showed no context figure at all;
//    * ...so that same slot falls back to OUR OWN estimate of the request that is
//      already in flight: `DSHContextBreakdown.estimatedTotal`, measured in
//      `DSHTurnDriver.buildRequest()` before the request goes out. It is the same
//      value the `Total (estimated)` row further down this sheet renders, so the
//      ring and the row can never disagree — two estimators on one screen is how
//      the "the ring says X, the rows say Y" class of bug starts.
//
//  The three component ROWS are measured in `DSHTurnDriver.buildRequest()` too,
//  where the system prompt, the tool roster and the conversation are all in hand
//  at once; estimating them afterwards (from the UI, against the surface) would
//  describe a different request than the one that was sent.
//
//  ON SCREEN, the panel says NOTHING about which of the two figures it is
//  showing WHILE BOTH ARE PROVIDER COUNTS — a labelled estimate is the one
//  exception, see below. It used to say it four
//  times — a "WHO MEASURED WHAT" paragraph, a "measured by the provider" caption
//  under the header figure, a "Measured / Provider" pair at the bottom, and a
//  one-line note under the rows ("Estimated from character count at 3.6
//  characters per token…"). The operator had each of them removed, one round at a
//  time, and the last one came with the instruction that no other words may take
//  its place in this window.
//
//  THE ONE EXCEPTION, added 2026-10-18: a figure that is NOT a provider count is
//  labelled as its own kind. The defect that round was about was not a missing
//  caption — it was a request-envelope ESTIMATE rendered exactly like a measured
//  occupancy ("~60K used" while the provider charged 189,546 for every step of
//  the same turn, and "~13K used" in a chat with no messages in it). Silence
//  about provenance is only honest while the provenance is uniform. The labels
//  are the sheet's section heading and its total row, they appear only in the
//  estimated state, and the measured state is worded exactly as the operator left
//  it.
//
//  The provenance of the FIGURES lives in `DSHContextUsage.swift`: a provider
//  count or nothing, with the estimator demoted to a labelled, expiring fallback
//  that is never published as the context's occupancy.
//
//  A THIRD FIGURE, and the only measured ROW in the sheet, sits under the total:
//  the provider's cache-hit share for its newest response
//  (`DSHContextBreakdownStore.latestUsage`), written on every response report by
//  whichever loop is driving the turn — the DSH driver's per-step report and the
//  legacy agent loop's per-iteration stamp — so it moves with each model call
//  rather than only when the turn ends. Its value comes from `DSHCacheHitFormat`, a
//  port of the upstream client's `formatCacheHitPercent` (the rules, and why a
//  partial hit never prints 100%, are documented on that type); its denominator is
//  the prompt-side total of the SAME response, so it cannot disagree with the
//  header figure about which request is being described. When the backend reports
//  no cache buckets the row is absent rather than reading 0%: silence about the
//  cache is not a cache miss.
//
//  The denominator is the model's WINDOW (`AIChatViewModel
//  .currentModelContextWindow`), not the compaction pressure threshold. The
//  threshold is a policy of ours — 80% of the window on the iOS 26 line — and a
//  ring that fills at a policy line reads as "the window is nearly full" at 80%,
//  which is exactly the misreading this panel exists to prevent.
//
//  Why this file reads `ChatMessage` and `DSHTokenEstimate` rather than the
//  iOS 26 line's `ContextUsage` / `ContextSizeMeter`: everything under
//  `src/ios/DSH/` is byte-identical on both lines, and neither of those two
//  types exists on the iOS 15 line. `DSHToolDispatchBridge` states the same rule
//  for the same reason ("that type does not exist on the iOS 15 line, and this
//  file is identical on both"). The estimator chosen is the DSH layer's own
//  (`DSHTokenEstimate`, chars/token 3.6) — the one the compaction decision
//  already uses — so a component measured from text and a component measured
//  from blocks stay comparable.
//
//  Also note which sections the panel can list, because it reports the ones that
//  reached the request: the DSH turn registers `harness:identity`, the `minis:*`
//  sections (environment, working-method, tool-use, honesty, runtime-context,
//  app-system-prompt, model-capability, model-behaviour, skills, mcp, memory-*),
//  and `plan:policy` — see `DSHTurnDriverRun` and `dshRegisterContextSections`.
//  Nothing on this path registers a `prompt.context(...)`, so
//  `DSHSystemPrompt.renderContextSnapshot` is always empty here and the system
//  prompt is entirely section text.
//

import Foundation
import SwiftUI
import UIKit

// MARK: - Formatting

/// Compact token counts for a context readout: "847", "9.8K", "296K", "1M".
///
/// Deliberately NOT `TokenCountFormatter.short` (`ChatModels.swift`, ~line 369).
/// That formatter renders the message-footer capsule and the composer usage
/// line, and it is the wrong shape for this readout in three ways:
///
///   * lowercase `k` ("124k"), where this readout is compared against window
///     sizes the rest of the UI quotes as "1M";
///   * no M tier at all, so a 1,000,000-token window renders as "1000k";
///   * no approximation marker, and every number in this panel is an
///     approximation of something.
///
/// Changing the shared formatter would change the footer capsule's strings for
/// no reason, so the two coexist: the capsule keeps its own, this panel gets the
/// shape a window readout needs. It exists on both lines because it depends on
/// nothing but `Int`.
enum DSHContextFormat {

    /// "847" · "9.8K" · "296K" · "1M" · "1.5M"
    static func magnitude(_ count: Int) -> String {
        let n = max(count, 0)
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 {
            let k = Double(n) / 1_000
            // One decimal below 10K ("9.8K"): that is still a visible share of
            // the ring. Above it the decimal is noise in a number that is
            // approximate anyway.
            return k < 10 ? trimZero(String(format: "%.1f", k)) + "K" : "\(Int(k.rounded()))K"
        }
        return trimZero(String(format: "%.1f", Double(n) / 1_000_000)) + "M"
    }

    /// "~296K" — the marker carries the meaning "measured or estimated, not
    /// exact", which is true of every number in this panel.
    static func approx(_ count: Int) -> String { "~" + magnitude(count) }

    /// "~296K / 1M" — used / window.
    static func ratio(used: Int, window: Int) -> String {
        "\(approx(used)) / \(magnitude(window))"
    }

    private static func trimZero(_ s: String) -> String {
        s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}

// MARK: - Cache hit

/// The provider's cache-hit share, ported from the upstream DSH client.
///
/// `formatCacheHitPercent` — `packages/client/ui-chat/src/client/chat/token-format.ts`
/// in the upstream checkout — is the one definition of this number there: the
/// composer's cache pill reads it over the session's SUMMED buckets
/// (`StatsPills.cacheHitPercent`, no decimal), and the per-turn usage panel reads
/// it over one turn's buckets with one decimal (`TurnUsagePanel`). This app's
/// panel describes one request at a time, so the per-turn reading is the one
/// ported here: same numerator (tokens served from cache), same denominator (the
/// request's prompt-side billing buckets: uncached input + cache reads + cache
/// writes), same precision rule, same `nil` for "no prompt input".
///
/// Each rule below is a choice upstream made deliberately, and the obvious
/// `cacheRead / prompt * 100` breaks all three:
///
///   * the denominator is the three disjoint input buckets, NOT `totalTokens` —
///     output tokens are not something a cache could have served;
///   * rounding is half-UP on exact percentage units and done in integer
///     arithmetic, so 2/3 cannot come out "66.99999";
///   * a partial hit is NEVER rounded up to 100%. 999/1000 would print "100" with
///     one decimal, so the formatter widens the display to as many decimals as
///     the gap needs and prints `99.9…X`; only an exact hit prints "100".
///
/// It exists on both lines because it depends on nothing but `Int`.
enum DSHCacheHitFormat {

    /// "78.5" · "99.9" · "100" · nil when there is no rate to state.
    ///
    /// The percent sign belongs to the row, not here: keeping it out makes every
    /// value below comparable, value for value, with upstream's.
    static func percent(_ reading: DSHUsageReading?, decimalPlaces: Int = 1) -> String? {
        guard let reading else { return nil }
        // The upstream fold relies on `cacheRead <= prompt`: with a negative gap
        // its `while` loop multiplies a negative number and never terminates. Every
        // mapping in this app upholds the invariant — `TokenUsage.inputTokens` is
        // uncached-only and `promptTokens` adds the cache buckets back, both from
        // the same response (`TokenUsage.add`, `minisTokenUsage`) — so this is a
        // trap for a malformed receipt, not a state the UI reaches. An impossible
        // ratio is reported as "no rate" rather than hanging the main thread.
        guard reading.cacheReadTokens <= reading.promptTokens else { return nil }
        return formatCacheHitPercent(
            reading.cacheReadTokens,
            reading.promptTokens,
            decimalPlaces
        )
    }

    /// Display-ready cache-hit share without rounding a partial hit to 100%.
    /// - Parameters:
    ///   - cacheReadTokens: exact prompt tokens served from cache.
    ///   - promptTokens: exact aggregate prompt tokens.
    ///   - decimalPlaces: ordinary-ratio precision; a partial hit that would round
    ///     to 100 automatically uses enough additional precision to stay honest.
    /// - Returns: percentage text, or nil when there was no prompt input.
    static func formatCacheHitPercent(_ cacheReadTokens: Int, _ promptTokens: Int, _ decimalPlaces: Int = 0) -> String? {
        if promptTokens == 0 {
            return nil
        }
        let missedInputTokens = promptTokens - cacheReadTokens
        if missedInputTokens == 0 {
            return "100"
        }

        let roundedUnits = roundedPercentUnits(cacheReadTokens, promptTokens, decimalPlaces)
        let fullHitUnits = decimalPlaces == 0 ? 100 : 1_000
        if roundedUnits < fullHitUnits {
            return displayPercentUnits(roundedUnits, decimalPlaces)
        }

        // A partial hit that rounds to a full 100: widen the display instead of
        // claiming the hit, so the extra decimals carry the miss.
        var distinguishingPlaces = 1
        var scaledDoubleGap = missedInputTokens * 200
        let promptTens = promptTokens / 10
        while scaledDoubleGap <= promptTens {
            scaledDoubleGap *= 10
            distinguishingPlaces += 1
        }
        let promptOnes = promptTokens % 10
        var roundedLoss = 5
        for loss in 1..<5 {
            let factor = loss * 2 + 1
            let threshold = factor * promptTens + (factor * promptOnes) / 10
            if scaledDoubleGap <= threshold {
                roundedLoss = loss
                break
            }
        }
        return "99." + String(repeating: "9", count: distinguishingPlaces - 1) + String(10 - roundedLoss)
    }

    /// Round a cache-read ratio to exact percentage units, with positive ties
    /// rounded up.
    ///
    /// Integer arithmetic throughout, mirroring upstream: every candidate is
    /// compared against `ceil((2·candidate − 1)·prompt / (2·scale))`, which is
    /// "round half up" without ever forming a floating-point quotient. The search
    /// is a bisection because the comparison cannot be inverted in closed form
    /// once the residual is carried separately.
    private static func roundedPercentUnits(_ cacheReadTokens: Int, _ promptTokens: Int, _ decimalPlaces: Int) -> Int {
        let unitsPerPercent = decimalPlaces == 0 ? 1 : 10
        let scale = unitsPerPercent * 100
        let doubledScale = scale * 2
        let promptQuotient = promptTokens / doubledScale
        let promptRemainder = promptTokens % doubledScale
        var lower = 0
        var upper = scale
        while lower < upper {
            let candidate = (lower + upper + 1) / 2
            let factor = candidate * 2 - 1
            let threshold = factor * promptQuotient + (factor * promptRemainder + doubledScale - 1) / doubledScale
            if cacheReadTokens >= threshold {
                lower = candidate
            } else {
                upper = candidate - 1
            }
        }
        return lower
    }

    /// "78" · "78.5" — a trailing zero tenth is dropped, so 78.0 prints "78".
    private static func displayPercentUnits(_ units: Int, _ decimalPlaces: Int) -> String {
        if decimalPlaces == 0 {
            return String(units)
        }
        let whole = units / 10
        let tenths = units % 10
        if tenths == 0 {
            return String(whole)
        }
        return "\(whole).\(tenths)"
    }
}

// MARK: - Reading

/// One reading of "how full is the context", and the kind of figure it is.
///
/// Derived at the call site rather than taken from a ViewModel property, because
/// the iOS 26 line's `AIChatViewModel.contextUsage` does not exist on the iOS 15
/// line. It reads the same source that property is built from
/// (`TokenUsage.latestContextTokens`, the input size of the newest
/// usage-bearing assistant row), so the two agree by construction.
struct DSHContextReading: Equatable {

    var usedTokens: Int
    /// 0 when the model's window is unknown — the ring then draws nothing and
    /// the panel says so rather than showing a percentage of zero.
    var windowTokens: Int
    /// Which figure `usedTokens` is. Never inferred from the two numbers above:
    /// the whole 2026-10-18 defect was two different kinds of figure rendered
    /// identically, so the kind travels with the value.
    var source: DSHContextUsageSource = .providerMeasured

    var hasWindow: Bool { windowTokens > 0 }

    /// True while the figure is the app's own estimate of the request envelope
    /// rather than a provider count. The ring's accessibility text says so, and
    /// the sheet's heading and total row say so; `fraction` deliberately does
    /// not change, because an estimate of an over-window request is still a real
    /// overflow signal.
    var isEstimate: Bool { source == .requestEnvelopeEstimate }

    var fraction: Double {
        guard windowTokens > 0 else { return 0 }
        return min(max(Double(usedTokens) / Double(windowTokens), 0), 1)
    }

    var percent: Int { Int((fraction * 100).rounded()) }

    /// Newest provider-reported context size among these messages, or nil when
    /// no assistant row carries usage yet.
    ///
    /// The database row is a durable receipt, so this answers for a session
    /// restored after a relaunch even though the in-process store is empty then.
    /// It is a real count for the request it describes — the request that
    /// produced that row — and `occupancy` supersedes it as soon as this process
    /// has one it measured itself.
    static func reported(messages: [ChatMessage], window: Int?) -> DSHContextReading? {
        let reported = messages.last {
            $0.role == .assistant && ($0.usage?.latestContextTokens ?? 0) > 0
        }
        guard let used = reported?.usage?.latestContextTokens, used > 0 else { return nil }
        return DSHContextReading(
            usedTokens: used, windowTokens: window ?? 0, source: .providerMeasured
        )
    }

    /// What the ring and the sheet's header show, in priority order:
    ///
    ///  1. the newest provider count for THIS session, carried forward by the
    ///     conversation's growth since it was reported (`DSHContextUsageStore`);
    ///  2. the durable receipt on the newest usage-bearing row, which is how a
    ///     conversation restored from the database answers — those rows ARE the
    ///     transcript the caller is showing, so they belong to this conversation
    ///     by construction, and this branch states no session of its own;
    ///  3. the app's estimate of the request envelope — while a request is
    ///     actually in flight, and only then. It is labelled as an estimate
    ///     wherever it is rendered.
    ///
    /// A brand-new conversation answers with nil at every step, and the callers
    /// render that as "no figure" rather than as zero or as a request envelope's
    /// size: before the first message this app has sent, no request envelope
    /// describes anything the user has done, which is why a fresh chat used to
    /// open on "~13K used".
    ///
    /// - Parameters:
    ///   - messages: the transcript, for the durable receipt.
    ///   - window: the serving model's window, or nil when unknown.
    ///   - sessionId: the conversation the reading describes. The measured store
    ///     and the request breakdown are both session-scoped, so a value that
    ///     belongs to another conversation is refused rather than shown.
    ///   - requestInFlight: whether a turn is running. The estimate is admitted
    ///     only here — it describes the request being streamed, which no receipt
    ///     covers yet.
    /// - Returns: the reading, or nil when this session has no figure at all.
    /// - Note: `@MainActor` because it reads `DSHContextBreakdownStore.shared`
    ///   and `DSHContextUsageStore.shared`, which are main-actor isolated. Every
    ///   caller is a view body.
    @MainActor
    static func display(
        messages: [ChatMessage],
        window: Int?,
        sessionId: String? = nil,
        requestInFlight: Bool = false
    ) -> DSHContextReading? {
        let windowTokens = window ?? 0
        let breakdown = DSHContextBreakdownStore.shared.latest
        let breakdownIsThisSession = breakdown?.sessionKey != nil && breakdown?.sessionKey == sessionId

        if let envelopeNow = breakdownIsThisSession ? breakdown?.estimatedTotal : nil,
           let occupancy = DSHContextUsageStore.shared.occupancy(envelopeTokensNow: envelopeNow) {
            return DSHContextReading(
                usedTokens: occupancy, windowTokens: windowTokens, source: .providerMeasured
            )
        }
        if let reported = reported(messages: messages, window: window) { return reported }
        guard requestInFlight, breakdownIsThisSession,
              let estimate = breakdown?.estimatedTotal, estimate > 0 else { return nil }
        return DSHContextReading(
            usedTokens: estimate, windowTokens: windowTokens, source: .requestEnvelopeEstimate
        )
    }

    /// Our estimate alone: the request `DSHTurnDriver.buildRequest()` measured
    /// last, which is the request the token currently being streamed belongs to.
    ///
    /// nil until this process has assembled one request for this session. A
    /// session whose conversation was loaded from the database after a relaunch
    /// has messages but no breakdown, and the panel has a line that says exactly
    /// that.
    ///
    /// - Parameter window: the serving model's window.
    /// - Parameter sessionId: the conversation the estimate must belong to.
    @MainActor
    static func estimated(window: Int?, sessionId: String? = nil) -> DSHContextReading? {
        guard let breakdown = DSHContextBreakdownStore.shared.latest,
              breakdown.sessionKey != nil, breakdown.sessionKey == sessionId,
              breakdown.estimatedTotal > 0 else { return nil }
        return DSHContextReading(
            usedTokens: breakdown.estimatedTotal,
            windowTokens: window ?? 0,
            source: .requestEnvelopeEstimate
        )
    }
}

// MARK: - Measurement

/// One assembled request, measured where it was assembled.
///
/// Every count here is an estimate from `DSHTokenEstimate`, the DSH layer's own
/// estimator: char-proportional at 3.6 chars/token, which is enough for relative
/// cost — the compaction decision is made with the same number. The provider's
/// own count (the header) additionally carries request framing, cache accounting
/// and its tokenizer, so the two are related but not equal, and neither side is
/// adjusted to make them add up.
struct DSHContextBreakdown: Equatable {
    var systemPromptTokens: Int
    var systemPromptChars: Int
    var toolTokens: Int
    var toolCount: Int
    var surfaceTokens: Int
    var surfaceMessageCount: Int
    /// Names of the sections that actually carried text into this request.
    /// `plan:policy` appears only while plan mode is on: the section is
    /// registered on every turn but renders as the empty string when the mode is
    /// off, and `renderPrompt` drops empty sections.
    var sectionNames: [String]
    var model: String
    var provider: String
    /// The conversation this request was assembled for.
    ///
    /// The store is process-global and the app switches conversations, so a
    /// breakdown without an owner is a breakdown from whichever chat was last
    /// open. `nil` is a session that has no id yet (a draft), which never matches
    /// a bound session and therefore never leaks either.
    var sessionKey: String?
    var capturedAt: Date

    var estimatedTotal: Int { systemPromptTokens + toolTokens + surfaceTokens }

    /// The envelope the newest provider count was taken against, or nil when no
    /// provider has reported one for this session.
    ///
    /// The recorded envelope equals the current assembly's immediately after a
    /// response lands, because the driver assembles once per step and reports
    /// once per step — so an exact match identifies the sheet's figures as the
    /// ones the provider counted. It drifts as soon as the next step's tool
    /// result is appended, and the sheet then describes an estimate again.
    var measuredEnvelopeTokens: Int?

    /// True when the sheet's total is the envelope a provider counted, rather
    /// than this app's estimate of one.
    ///
    /// Derived from the store's own record of what it measured — never inferred
    /// from how close two numbers are — so the row's label and the header's
    /// figure cannot disagree about the request they describe.
    var isMeasured: Bool {
        guard let measured = DSHContextUsageStore.shared.measured else { return false }
        return measured.sessionKey == sessionKey && measured.envelopeTokens == estimatedTotal
    }

    /// "This request, estimated" · "This request, measured".
    var sectionTitle: String {
        isMeasured ? "This request, measured" : "This request, estimated"
    }

    /// "Total (estimated)" · "Total (measured)".
    var totalLabel: String {
        isMeasured ? "Total (measured)" : "Total (estimated)"
    }
}

/// The provider's own accounting for ONE response, in the two numbers a
/// cache-hit share needs.
///
/// Both come from one receipt, which is what makes their ratio mean anything: the
/// numerator is what the cache served, the denominator what the request cost. The
/// `promptTokens` construction is `TokenUsage.latestContextTokens` exactly
/// (uncached input + cache reads + cache writes), so this panel's rate and the
/// row's own context figure describe the same request.
///
/// A reading exists only while the backend is accounting for the cache. A backend
/// that reports neither cache bucket says nothing about caching, and a 0% row for
/// it would be fabrication — which is why this is optional and why the panel drops
/// the row rather than defaulting to zero.
struct DSHUsageReading: Equatable {

    /// Prompt-side tokens of that response: uncached input + cache reads + cache writes.
    var promptTokens: Int
    /// Of those, the tokens the provider served from its cache.
    var cacheReadTokens: Int
}

/// Holds the newest breakdown so the sheet can show it.
///
/// A store rather than a ViewModel property because the writer is the turn
/// driver (once per step, mid-turn) and the reader is a sheet the composer owns;
/// routing it through the ViewModel would add a published property that only
/// this panel reads. It carries two things — this session's request measurement
/// and the newest provider receipt — because between them they describe the one
/// request the panel is about.
@MainActor
final class DSHContextBreakdownStore: ObservableObject {

    static let shared = DSHContextBreakdownStore()

    @Published private(set) var latest: DSHContextBreakdown?

    /// The newest provider receipt, which is the one measured figure the panel
    /// has: its cache-hit share. Written by whichever path is driving the turn,
    /// each time a response reports usage (`recordUsage`), so it moves with every
    /// model call of an agent loop rather than only at the end of the turn.
    @Published private(set) var latestUsage: DSHUsageReading?

    private init() {}

    /// Record one assembled request.
    ///
    /// Called from `DSHTurnDriver.buildRequest()` immediately before the request
    /// is returned, so what is measured is what is sent. The conversation row is
    /// measured over the DSH surface — the same list `maybeCompact` measures —
    /// rather than over the provider-facing projection, so this row and the
    /// compaction decision can never disagree about the conversation's size.
    ///
    /// The same assembly re-bases the measured store's growth baseline, because
    /// this is the only point that knows the envelope the NEXT receipt will cover:
    /// the response's tokens are appended to the surface before a later receipt
    /// arrives, so a baseline left where the previous request put it would count
    /// that append twice.
    ///
    /// - Parameters:
    ///   - sessionKey: the conversation being assembled for. A change of
    ///     conversation drops the previous one's receipt here as well, so a
    ///     value from another chat cannot be paired with this request's rows.
    func record(
        systemPrompt: String,
        tools: [DSHToolSchema],
        surface: [DSHLogEntry],
        sectionNames: [String],
        model: String,
        provider: String,
        sessionKey: String?
    ) {
        let next = DSHContextBreakdown(
            systemPromptTokens: DSHTokenEstimate.tokens(forText: systemPrompt),
            systemPromptChars: systemPrompt.count,
            toolTokens: DSHTokenEstimate.tokens(forToolSchemas: tools),
            toolCount: tools.count,
            surfaceTokens: DSHTokenEstimate.total(surface),
            surfaceMessageCount: surface.count,
            sectionNames: sectionNames,
            model: model,
            provider: provider,
            sessionKey: sessionKey,
            capturedAt: Date()
        )
        let moved = latest?.sessionKey != sessionKey
        if next != latest { latest = next }
        if moved {
            if latestUsage != nil { latestUsage = nil }
        }
        DSHContextUsageStore.shared.bind(sessionKey: sessionKey)
        DSHContextUsageStore.shared.rebase(envelopeTokens: next.estimatedTotal)
    }

    /// Record one response's own accounting.
    ///
    /// Called where a response's usage lands on its row, and nowhere else, so this
    /// always holds the NEWEST response of a running turn instead of the turn's
    /// total: an agent loop issues one request per tool round, and the panel has to
    /// move with each of them — a rate that only appeared when the whole turn ended
    /// was the reported defect.
    ///
    /// A response that names no cache bucket CLEARS the reading rather than leaving
    /// the previous one standing. Keeping it would put a stale cache share beside a
    /// newer occupancy figure — the panel draws them together — and the pair would
    /// silently describe two different requests.
    ///
    /// The same receipt is the app's one measured context figure, so it is also
    /// handed to `DSHContextUsageStore` with the envelope this sheet is showing —
    /// one write, two readers, no second derivation of the number.
    ///
    /// - Parameter usage: the response's own accounting.
    /// - Parameter sessionKey: the conversation the response belongs to. A
    ///   response for a session the measured store is not bound to is refused
    ///   there (it belongs to the chat the user just left).
    func recordUsage(_ usage: TokenUsage, sessionKey: String?) {
        let next = usage.cacheReported && usage.latestContextTokens > 0
            ? DSHUsageReading(
                promptTokens: usage.latestContextTokens,
                cacheReadTokens: usage.cacheReadTokens
            )
            : nil
        if next != latestUsage { latestUsage = next }

        // Bind first, so a report from the legacy agent loop — which assembles no
        // DSH request and therefore records no breakdown — still counts as this
        // session's measurement rather than being dropped for want of an owner.
        // The binding is idempotent and only wipes a value that belonged to
        // another conversation.
        bind(sessionKey: sessionKey)

        // The measured figure and its growth baseline are `DSHContextUsageStore`'s
        // to own: this method reports ONE receipt and nothing else, and the
        // baseline is re-based by `record()` on the next assembly, which is the
        // only place that knows the envelope the receipt covers.
        DSHContextUsageStore.shared.record(
            promptTokens: usage.latestContextTokens,
            envelopeTokens: latest?.sessionKey == sessionKey ? (latest?.estimatedTotal ?? 0) : 0,
            sessionKey: sessionKey
        )
    }

    /// Drop the measurement, so a later session cannot open the panel on the
    /// previous session's request.
    ///
    /// - Parameter sessionKey: the conversation to bind to, or nil to unbind.
    ///   Binding is what makes the previous session's value unusable: the
    ///   measured store drops its own value on a move, and a breakdown stamped
    ///   with another key is refused by every reader. `DSHContextUsageStore` is
    ///   the authority for the binding; this only follows it so the sheet's rows
    ///   cannot outlive the figure above them.
    func bind(sessionKey: String?) {
        DSHContextUsageStore.shared.bind(sessionKey: sessionKey)
        if latest?.sessionKey != sessionKey {
            if latest != nil { latest = nil }
            if latestUsage != nil { latestUsage = nil }
        }
    }

    /// Drop the measurement unconditionally, keeping the session binding.
    func clear() {
        if latest != nil { latest = nil }
        if latestUsage != nil { latestUsage = nil }
        DSHContextUsageStore.shared.clearMeasurement()
    }
}

// MARK: - Ring

/// The context ring: a hairline circle with a clockwise arc for the used share.
///
/// Drawing notes, because both were wrong in the obvious version:
///
///   * the track is `strokeBorder`, not `stroke` — a stroke straddles the path,
///     half of it falls outside the frame, and at 22pt the ring looked clipped at
///     the cardinal points. `strokeBorder` insets the path instead. It is also
///     NOT a filled circle: a filled disc reads as a button badge, and the point
///     of this control is that the FILL LEVEL is visible;
///   * `trim(from: 0, to: fraction)` starts at 3 o'clock, so the arc needs a -90°
///     rotation to start at 12 o'clock and run clockwise;
///   * the arc is drawn only when `fraction > 0.001`. A `.round` line cap on a
///     near-zero arc still paints a dot, which reads as "a little used" when the
///     truth is "nothing measured yet".
///
/// The `trim` + `rotationEffect` arc is the pattern the speech capsule's ring
/// already uses (`Views/Chat/Voice/SpeechPlayerControl.swift`, ~line 602).
struct DSHContextRing: View {
    /// 0…1 of the window. Clamped here so a caller cannot draw past full.
    var fraction: Double
    var diameter: CGFloat = 22
    var lineWidth: CGFloat = 2

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color(UIColor.tertiaryLabel).opacity(0.35), lineWidth: lineWidth)
            if clamped > 0.001 {
                Circle()
                    .trim(from: 0, to: CGFloat(clamped))
                    .stroke(
                        ChatColors.sendButton,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Composer button

/// The tappable ring in the composer's control row.
///
/// A plain `Button` with a circular content shape: this control opens a sheet, so
/// it has none of `MicButton`'s press-and-hold semantics, and copying that drag
/// handling would add a gesture competing with the transcript's scroll view.
struct DSHContextRingButton: View {
    /// The reading to draw — `DSHContextReading.display`, i.e. the provider's
    /// figure once one has arrived and our estimate of the request in flight
    /// before that. It is nil only when neither exists (no request assembled in
    /// this process and no receipt): the ring is still drawn then, because an
    /// empty ring means "nothing measured yet", which is information, and the
    /// width stays constant so the read-aloud toggle's width budget stays a
    /// constant too.
    var reading: DSHContextReading?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            DSHContextRing(fraction: reading?.fraction ?? 0, diameter: 22, lineWidth: 2)
                // The hit area is the 34pt slot the other controls use, not the
                // 22pt circle.
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        // Nothing to report at all — a session with no request assembled in this
        // process yet, which is also the only state in which the panel below is
        // empty. Name the control and stop: this slot used to read "no usage
        // reported yet", the operator removed the sentence from both here and the
        // panel's title row.
        //
        // Since 2026-10-18 an empty slot is a REAL state again rather than a
        // corner case: a conversation that has sent nothing reads nil here, and
        // reading it as "0 tokens used" would be the same class of fabrication as
        // the request-envelope figure this round removed.
        guard let reading else { return AppLocalized("Context") }
        let ratio = DSHContextFormat.ratio(used: reading.usedTokens, window: reading.windowTokens)
        // An estimate is announced as one. The key is shared with the measured
        // reading so the two states cannot drift apart in wording, and the
        // qualification is appended rather than substituted because a screen
        // reader must hear the number either way.
        let used = String(format: AppLocalized("Context %lld%% used — %@"), reading.percent, ratio)
        return reading.isEstimate ? used + " · " + AppLocalized("estimated request envelope") : used
    }
}

// MARK: - Panel

/// The context breakdown sheet, presented from the composer's ring.
struct DSHContextPanel: View {

    /// The height this panel's content needs, for the iOS 26 line's sheet to be
    /// sized to exactly that instead of to a fraction of the screen.
    ///
    /// Measured on the iPhone 13 / iOS 15.3.1 target through the accessibility
    /// tree, with the frame of every row read back (the same screenshots-plus-tree
    /// method the probe below was written from): header 68pt + divider 1pt +
    /// rows 179pt (heading 14, three 18pt rows and the total row, 10pt apart,
    /// 20pt padding) = **248pt** of content. The 288 here is that 248 plus the
    /// 34pt home-indicator strip a sheet's last row must not be drawn under, plus
    /// 6pt of margin for a longer localized label or a larger Dynamic Type step.
    ///
    /// A number rather than `.fraction(0.3)`: a fraction is a fraction of the
    /// SCREEN, so the same value is right on one device and wrong on the next —
    /// this panel's content does not grow with the screen. Under- rather than
    /// over-sizing is the safe direction in any case: the rows are inside a
    /// `ScrollView`, so a short sheet scrolls instead of clipping anything.
    ///
    /// The 6pt of margin is the whole of it. The header's subtitle is
    /// `.lineLimit(2)`, so in a long translation (German is the one to watch: the
    /// title column has ~131pt) it can take a second line and add ~16pt — that
    /// eats the margin and puts the last row 10pt into the home-indicator strip,
    /// which is still on screen, not clipped. If a device ever shows that, this
    /// constant is the single number to raise (304 restores the margin).
    ///
    /// Used by the iOS 26 line (`AIChatView`, its context-panel `.sheet`). The
    /// iOS 15 line cannot use it — below iOS 16 there is no custom detent at all —
    /// and pins `.medium` from inside instead, see `DSHContextSheetHeightProbe`.
    ///
    /// The cache row added under the total costs one more divider plus one more
    /// 18pt row and their 10pt gaps — 39pt — and this constant was deliberately
    /// NOT raised with it. It is a device measurement (the frames above), the
    /// cache row is conditional on the backend reporting cache buckets, and the
    /// rows live in a `ScrollView`, so a short sheet scrolls by ~39pt on the iOS 26
    /// line instead of clipping anything; the iOS 15 line pins `.medium` (456pt)
    /// and has 200pt of blank to absorb it. Raising it to 327 is the correct
    /// follow-up, and it needs a device measurement plus an update to
    /// `_tools/context-usage-selftest.cjs`, which pins this number to the frames
    /// above. Both are the Lead's call, not this agent's.
    static let sheetHeight: CGFloat = 288

    /// Snapshot taken when the sheet was presented; the presenting view
    /// re-evaluates this on every change it observes, so a running turn updates
    /// it.
    var reading: DSHContextReading?
    @ObservedObject private var breakdowns = DSHContextBreakdownStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    components
                }
                .padding(20)
            }
        }
        // Ends the sheet at the content's bottom edge instead of leaving the full
        // page sheet standing open under it: the iOS 26 line sizes the sheet to
        // `DSHContextPanel.sheetHeight`, this line has no custom detent to size it
        // with and pins `.medium` from inside. See `DSHContextSheetHeightProbe`.
        .background(DSHContextSheetHeightProbe())
    }

    // MARK: Header

    /// The top-right figure: `~296K / 1M`. Two numbers and a separator, so it is
    /// not a catalog key; it is set in the CODE face so the digits are tabular
    /// and line up with the value column of the rows underneath.
    private var ratioText: String {
        // Same guard as `headerSubtitle`, for the same reason: without a window
        // there is no ratio to state, and `ratio(used:window:)` would render the
        // nonsense "~12K / 0". A bare em dash is the placeholder the earlier
        // "no usage reported yet" sentence was removed in favour of.
        guard let reading, reading.hasWindow else { return "—" }
        return DSHContextFormat.ratio(used: reading.usedTokens, window: reading.windowTokens)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            DSHContextRing(
                fraction: reading?.fraction ?? 0,
                diameter: 40,
                lineWidth: 4
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Context")
                    .font(Font(AppFont.ui(17, weight: .semibold, category: .body)))
                // Omitted rather than rendered empty: an empty `Text` still takes
                // a line of the header, and this slot is the one the operator
                // asked to carry no words when there is no percentage to state.
                if !headerSubtitle.isEmpty {
                    Text(headerSubtitle)
                        .font(Font(AppFont.ui(12, category: .ui)))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            // The figure the ring also draws — the provider's own count once a
            // receipt has arrived, and our estimate of the request in flight
            // before that (`DSHContextReading.display`). Everything below it is
            // the breakdown of how that figure is spent. Two captions used to sit
            // under this number — a "via <provider>" line and then "measured by
            // the provider" — and the operator called the second one unnecessary;
            // nothing was put in its place.
            Text(ratioText)
                .font(AppFont.sw(15, weight: .semibold, category: .code))
                .foregroundStyle(.primary)

            Button("Done") { dismiss() }
                .font(Font(AppFont.ui(15, category: .body)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// The one line under "Context": how full the window is, and nothing else.
    ///
    /// `""` — no line at all — when there is no percentage to state: no reading
    /// (this session has sent nothing and been told nothing) or an unknown
    /// window. The operator asked for exactly that.
    ///
    /// ONE qualification is appended when the figure is the estimate rather than
    /// a provider count, and only then. The operator's removals were of captions
    /// that sat there in EVERY state — including the measured one, where they
    /// said nothing the number did not already mean. This one exists because the
    /// alternative it replaces did: the same slot rendered a request-envelope
    /// estimate as "~60K used / 262K" while the provider was charging 189,546
    /// per step, and no wording anywhere on the sheet distinguished the two.
    ///
    /// Built as a `String` through `AppLocalized`/`String(format:)` rather than as
    /// a `LocalizedStringKey`: the sentence is assembled from a format and a name,
    /// and `LocalizedStringKey` does not convert to `String` on the iOS 15 line,
    /// so a composed key could not be handed to `AppLocalized` there.
    private var headerSubtitle: String {
        guard let reading, reading.hasWindow else { return "" }
        let percent = String(format: AppLocalized("%lld%% of the window"), reading.percent)
        guard reading.isEstimate else { return percent }
        return percent + " · " + AppLocalized("estimated request envelope")
    }

    // MARK: Rows

    private var components: some View {
        VStack(alignment: .leading, spacing: 10) {
            // "estimated" while the envelope has not been priced by a provider,
            // "measured" once it has — one word that tells the reader whether the
            // rows below are what the model was charged or what this app thinks it
            // will be charged.
            Text(LocalizedStringKey(breakdowns.latest?.sectionTitle ?? "This request, estimated"))
                .font(Font(AppFont.ui(11, weight: .semibold, category: .ui)))
                .foregroundStyle(.secondary)

            if let b = breakdowns.latest {
                ContextRow(
                    label: "System prompt",
                    value: DSHContextFormat.approx(b.systemPromptTokens),
                    detail: "\(count(b.systemPromptChars, .char)) · \(count(b.sectionNames.count, .section))"
                )
                ContextRow(
                    label: "Tool definitions",
                    value: DSHContextFormat.approx(b.toolTokens),
                    detail: count(b.toolCount, .tool)
                )
                ContextRow(
                    label: "Conversation",
                    value: DSHContextFormat.approx(b.surfaceTokens),
                    detail: count(b.surfaceMessageCount, .entry)
                )
                Divider()
                // Measured or estimated — the row says which, from the store's own
                // record of what it measured (`DSHContextBreakdown.isMeasured`),
                // never from a rule of thumb about the two numbers being close.
                ContextRow(
                    label: LocalizedStringKey(b.totalLabel),
                    value: DSHContextFormat.approx(b.estimatedTotal),
                    detail: nil,
                    emphasised: true
                )
                // The panel's one MEASURED row, under the same heading as the
                // estimated ones because it is the same request's receipt and the
                // panel carries no words to say so (the provenance of every figure
                // here is this file's header comment). Same denominator as the row
                // above it, from the same response, so the two can never describe
                // different requests. Absent — never "0%" — while the backend
                // reports no cache buckets at all: `DSHUsageReading`.
                //
                // It sits INSIDE the breakdown branch on purpose. The receipt and
                // the breakdown are written together on the DSH path (`buildRequest`
                // measures the request, the response reports the usage), so the
                // pair is either both present or both absent; on the legacy agent
                // loop, which never records a breakdown, drawing the row anyway
                // would put a measured rate right under the "no request has been
                // assembled yet in this session" sentence. Moving these two lines
                // out of the branch is all it takes to show it there too.
                if let hit = DSHCacheHitFormat.percent(breakdowns.latestUsage) {
                    Divider()
                    ContextRow(label: "Cache Hit Rate", value: hit + "%")
                }
                // Nothing under the rows. A one-line note used to sit here
                // ("Estimated from character count at 3.6 characters per token…")
                // carrying the attribution of the two figures; the operator had it
                // removed and asked for no replacement, the same way the other
                // three explanations of it had gone before. The provenance is the
                // comment at the top of this file.
            } else {
                // Nothing has been assembled in this session, or the app has not
                // driven a turn since launch. Saying so beats three rows of
                // zeroes that read as "the context is empty".
                Text("No request has been assembled yet in this session.")
                    .font(Font(AppFont.ui(13, category: .body)))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "1 char" · "812 chars" — through `AppLocalized`, because a key built from
    /// a variable cannot go through `Text`'s `LocalizedStringKey` initialiser and
    /// would render English on every device.
    private func count(_ n: Int, _ noun: CountUnit) -> String {
        String(format: AppLocalized(noun.key(for: n)), n)
    }
}

// MARK: - Sheet height

/// Pins this panel's sheet to the medium detent — the closest thing to "the
/// height this content needs" that iOS 15 offers — so the sheet stops near the
/// panel's bottom edge instead of standing open far below it.
///
/// Why this is not a `.presentationDetents` call in this file: the sheet belongs
/// to `AIChatView`, whose detent modifier is a NO-OP below iOS 16, which is the
/// line installed on the iPhone. Below iOS 16 `PresentationDetent` has no custom
/// height at all, so the only value UIKit does offer is the medium detent.
/// `UISheetPresentationController`, `Detent.medium()` / `.large()`,
/// `selectedDetentIdentifier` and `animateChanges` are all iOS 15.0, so nothing
/// here is an iOS 16 API.
///
/// MEASURED on the iPhone 13 / iOS 15.3.1 target (screenshot plus the frame of
/// every row from the accessibility tree), and the reason this file now carries
/// `DSHContextPanel.sheetHeight`:
///
///   * before this probe existed, the sheet was the full page sheet — top edge
///     y≈52 to 844 — with the content ending at y≈495: 349pt of blank under it;
///   * with `.medium` pinned here, the sheet is 456pt tall (top edge y=388) and
///     the content, note included, ended at y=676 — 168pt of blank;
///   * with the note removed (the panel's own 288pt `sheetHeight` derivation
///     lists the per-row frames), the same sheet leaves 208pt of blank.
///
/// That last number is why the iOS 26 line no longer uses `.medium`: on iOS 16
/// and later the sheet can be sized to the content (`sheetHeight`), which is what
/// the operator asked for when he called the blank "too big" a second time. This
/// probe cannot do the same on the iOS 15 line, and `.medium` is already the
/// smallest detent there is below iOS 16; the blank on this line is accepted, not
/// overlooked.
///
/// The one-detent guard below is the "do not fight" rule: it pins only while the
/// sheet is still at UIKit's own default, i.e. while nothing else has expressed a
/// height preference. On iOS 16+, where SwiftUI's `.presentationDetents` does
/// reach the sheet, this leaves those alone rather than overwriting them from
/// underneath — and that is also how the log line tells the two lines apart: no
/// `[DSH][Context] panel sheet detents` line means SwiftUI sized the sheet.
///
/// Fail-soft by construction: if the enclosing sheet controller cannot be
/// reached, no detent is written and the log line says so. And once it has acted
/// — or decided not to — it never runs again, so a detent the user dragged to is
/// not snapped back.
private struct DSHContextSheetHeightProbe: UIViewRepresentable {

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.pin(from: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // Also the retry path: the first attempt can run before the sheet's
        // presentation controller exists.
        context.coordinator.pin(from: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Same shape as `TranscriptScrollProbe`'s: a plain zero-size `UIView` that
    /// walks the UIKit tree it was dropped into. Purely an observer — no gesture,
    /// no hit-testing change.
    final class Coordinator: NSObject {

        /// There is nothing left to do: either the sheet was given detents here,
        /// or its detents belong to someone else.
        private var settled = false
        private var reportedMiss = false

        func pin(from view: UIView) {
            guard !settled else { return }
            // Defer one runloop turn: at `makeUIView` time the probe is not in
            // the window yet, and the presentation controller is attached while
            // the sheet is being presented, which can be later still.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, !self.settled else { return }
                // Not in the hierarchy yet: say nothing, a later update retries.
                guard view.window != nil else { return }
                guard let sheet = Self.enclosingSheet(of: view) else {
                    if !self.reportedMiss {
                        self.reportedMiss = true
                        AppLogger(category: "DSHContext").warning(
                            "[DSH][Context] panel has no reachable UISheetPresentationController — sheet height left as it is")
                    }
                    return
                }
                // More than one detent means somebody else has already chosen a
                // height for this sheet: SwiftUI's `.presentationDetents`, which
                // `compatDetents` only reaches on iOS 16 and later. Leave it be.
                guard sheet.detents.count <= 1 else {
                    self.settled = true
                    return
                }
                self.settled = true
                sheet.animateChanges {
                    sheet.detents = [.medium(), .large()]
                    sheet.selectedDetentIdentifier = .medium
                }
                AppLogger(category: "DSHContext").info(
                    "[DSH][Context] panel sheet detents → medium + large, showing medium")
            }
        }

        /// The sheet this view is inside: walk the responder chain for a view
        /// controller, then that controller's ancestors — a sheet's presentation
        /// controller hangs off the controller that was presented.
        private static func enclosingSheet(of view: UIView) -> UISheetPresentationController? {
            var responder: UIResponder? = view
            var hops = 0
            while let current = responder, hops < 64 {
                if let controller = current as? UIViewController {
                    var candidate: UIViewController? = controller
                    while let node = candidate {
                        if let sheet = node.presentationController as? UISheetPresentationController {
                            return sheet
                        }
                        candidate = node.parent
                    }
                }
                responder = current.next
                hops += 1
            }
            return nil
        }
    }
}

/// The count units the panel names, each carrying its OWN singular and plural
/// catalog key.
///
/// Not a noun the code appends an "s" to: "entry" would become "entrys", which is
/// not a word, and the two forms are already separate keys in the catalog (it has
/// no plural variations). Spelling both out is also what keeps the key names
/// greppable when someone audits the table.
enum CountUnit {
    case char
    case section
    case tool
    case entry

    func key(for n: Int) -> String {
        switch self {
        case .char: return n == 1 ? "%lld char" : "%lld chars"
        case .section: return n == 1 ? "%lld section" : "%lld sections"
        case .tool: return n == 1 ? "%lld tool" : "%lld tools"
        case .entry: return n == 1 ? "%lld entry" : "%lld entries"
        }
    }
}

/// One row of the panel.
///
/// Local to this file because `StatRow` in `AIChatView.swift` is `private` to that
/// file, and because these rows carry an optional detail column the usage sheet's
/// rows do not have.
private struct ContextRow: View {
    let label: LocalizedStringKey
    let value: String
    var detail: String?
    var emphasised: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(Font(AppFont.ui(14, weight: emphasised ? .semibold : .regular, category: .body)))
            if let detail {
                Text(detail)
                    .font(AppFont.sw(12, category: .code))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // The numbers are the point of this panel, so they are set in the CODE
            // face — the same one the composer's other numeric readouts use — which
            // also makes every digit tabular and the column line up.
            Text(value)
                .font(AppFont.sw(14, weight: emphasised ? .semibold : .regular, category: .code))
                .foregroundStyle(emphasised ? .primary : .secondary)
        }
    }
}
