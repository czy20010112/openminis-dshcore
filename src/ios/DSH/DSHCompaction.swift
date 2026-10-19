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
//  MUTUAL EXCLUSION IS A REAL LOCK, NOT AN INFERRED ONE. Upstream refuses a
//  second compaction while one is open, at two seams: the durable record
//  (`assertCompactionInactive` over the session's compaction events,
//  `packages/compaction/compaction-basic/src/region.ts:185-189`) and the
//  automatic pressure path (`assertNoActiveCompaction`, `index.ts:305`). This
//  app has no durable `compaction/start` to infer that from — `compact` composes
//  the summary FIRST and appends one replacement entry afterwards, so the only
//  before/after pair exists in memory — so the equivalent is the in-process half
//  of upstream's rule: `Bracket` admits one compaction at a time and the second
//  caller gets `.busy` (upstream's `ManualCompactionError('busy', …)`). It is
//  held across the summary `await`, never as a held `NSLock` (see `Bracket`).
//  The durable half is `.surfaceChanged`: the surface is re-read after the
//  summary lands and a span that no longer exists is refused before anything is
//  appended, which is what a compaction killed mid-flight leaves behind.
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

    /// Estimated tokens for a rendered string — the assembled system prompt, or
    /// one tool's schema text.
    ///
    /// Same ratio as the per-message path above, so a component measured from
    /// text stays comparable with one measured from blocks. `[T-ctx-breakdown]`
    /// the composer's context panel is the caller: it reports the three
    /// components of one request, and the conversation row comes from
    /// `total(_:)` so the panel and the compaction decision can never disagree
    /// about the conversation's size.
    public static func tokens(forText text: String) -> Int {
        Int((Double(text.count) / charsPerToken).rounded())
    }

    /// Estimated tokens for a tool roster, measured from what the model is
    /// actually sent.
    ///
    /// The JSON Schema object is serialized rather than walked: the serialized
    /// form is the thing that goes on the wire, and it needs no agreement with
    /// the providers about which keys of a schema carry text. A schema that
    /// cannot be serialized contributes its name and description only.
    public static func tokens(forToolSchemas schemas: [DSHToolSchema]) -> Int {
        schemas.reduce(0) { partial, schema in
            var total = partial + tokens(forText: schema.name) + tokens(forText: schema.description)
            if let data = try? JSONSerialization.data(withJSONObject: schema.parameters),
               let json = String(data: data, encoding: .utf8) {
                total += tokens(forText: json)
            }
            return total
        }
    }

    /// Per-tool constant for the JSON punctuation and the `input_schema` /
    /// `required` keys a text walk cannot count.
    static let toolSchemaScaffoldingTokens = 8

    /// Estimated tokens for the provider-facing roster, measured from what the
    /// model is actually sent.
    ///
    /// The same measurement as `tokens(forToolSchemas:)`, over the other end of
    /// `DSHToolSchemaBridge`: a summary request now carries the conversation's
    /// own tool schemas (`compaction-basic/src/summarizer.ts:152-162` passes
    /// `input.tools`, which `region.ts:560` takes from the last routed request's
    /// header), and the roster is ~14k tokens that are part of the request but
    /// part of nothing the region can shrink. A budget that ignores it prices
    /// every summary request low by exactly that much — the same defect class
    /// `summarizeMeterRatioFloor`'s comment documents for the excerpt.
    ///
    /// The walk is over the definition rather than over a serialized schema:
    /// `AgentToolDefinition` holds a name, a description and a property map, and
    /// this app has no `AgentToolDefinition` → `DSHToolSchema` conversion to
    /// serialize from.
    ///
    /// INTERNAL, unlike its `[DSHToolSchema]` twin: `DSHToolSchema` is public and
    /// `AgentToolDefinition` is not, so a `public` member would be the
    /// "public … uses an internal type" error rather than a style choice. Only
    /// this target measures a roster.
    static func tokens(forTools tools: [AgentToolDefinition]) -> Int {
        tools.reduce(0) { partial, tool in
            var total = partial + tokens(forText: tool.name) + tokens(forText: tool.description)
            for (name, parameter) in tool.parameters {
                total += tokens(forText: name)
                    + tokens(forText: parameter.type.rawValue)
                    + tokens(forText: parameter.description)
                if let values = parameter.enumValues {
                    total += tokens(forText: values.joined(separator: ","))
                }
            }
            total += tokens(forText: tool.required.joined(separator: ","))
            return total + toolSchemaScaffoldingTokens
        }
    }
}

// MARK: - Trigger Policy

/// Failure resolving a trigger budget from model capacity and the routed request.
///
/// The iOS counterpart of DSH's `TargetPressureConfigError`. It carries the
/// exact route as a stable key so a caller can warn once per target instead of
/// once per step: the misconfiguration is a property of the deployment, and a
/// model that declares no capacity would otherwise produce one warning per
/// model request for the life of the conversation.
public struct DSHCompactionConfigError: Error, Sendable, Equatable {
    /// Exact `provider/model` route the failure belongs to.
    public let targetKey: String
    /// Actionable configuration detail.
    public let detail: String

    public init(targetKey: String, detail: String) {
        self.targetKey = targetKey
        self.detail = detail
    }

    public var message: String { detail }
}

/// Concrete token budgets for one routed request, scaled to its model capacity.
///
/// DSH's `ResolvedCompactSpec`. `thresholdTokens` is compared against the priced
/// request envelope (system prompt, tool roster, and surface), never against the
/// surface alone — the envelope is what the provider counts.
public struct DSHCompactionSpec: Sendable, Equatable {
    /// Capacity of the routed model.
    public let contextWindow: Int
    /// Output tokens the routed request reserves inside that capacity.
    public let reservedCompletionTokens: Int
    /// Window fraction used in the threshold.
    public let thresholdRatio: Double
    /// Pressure headroom beyond the output reservation.
    public let headroomTokens: Int
    /// Priced-envelope tokens at or above which pressure compaction runs.
    public let thresholdTokens: Int
    /// Recent-tail budget retained verbatim.
    public let retainTokens: Int
    /// Extra condensation attempts after the first while pressure remains.
    ///
    /// Carried on the resolved spec rather than read from the policy at the call
    /// site, so one resolved value drives the whole retry sequence.
    public let compactionRetries: Int
    /// Maximum retries after a provider-confirmed context overflow.
    public let maxOverflowRetries: Int

    public init(
        contextWindow: Int,
        reservedCompletionTokens: Int,
        thresholdRatio: Double,
        headroomTokens: Int,
        thresholdTokens: Int,
        retainTokens: Int,
        compactionRetries: Int,
        maxOverflowRetries: Int
    ) {
        self.contextWindow = contextWindow
        self.reservedCompletionTokens = reservedCompletionTokens
        self.thresholdRatio = thresholdRatio
        self.headroomTokens = headroomTokens
        self.thresholdTokens = thresholdTokens
        self.retainTokens = retainTokens
        self.compactionRetries = compactionRetries
        self.maxOverflowRetries = maxOverflowRetries
    }

    /// Replace the derived threshold with an absolute one.
    ///
    /// An override moves *when* a compaction fires, never what it keeps: the
    /// retained-tail budget, the capacity checks, and the retry budgets stay as
    /// derived. It exists for deployments whose window is too large to fill by
    /// hand (a probe build, a device experiment), so the pressure path is
    /// reachable without manufacturing a 262k-token conversation.
    public func overridingThreshold(_ tokens: Int) -> DSHCompactionSpec {
        DSHCompactionSpec(
            contextWindow: contextWindow,
            reservedCompletionTokens: reservedCompletionTokens,
            thresholdRatio: thresholdRatio,
            headroomTokens: headroomTokens,
            thresholdTokens: tokens,
            retainTokens: retainTokens,
            compactionRetries: compactionRetries,
            maxOverflowRetries: maxOverflowRetries
        )
    }
}

/// Pressure and retention policy resolved against one routed model.
///
/// Port of DSH `compaction-basic`'s `resolveConfig` defaults plus
/// `resolveCompactSpec`. The defaults are DSH's own published values
/// (`thresholdRatio` 0.8, `headroomTokens` 65536, `retainRatio` 0.16,
/// `compactionRetries` 1, `maxOverflowRetries` 1) so a compaction fires at the
/// same point this app's upstream does.
public struct DSHCompactionPolicy: Sendable {

    /// Window fraction used in `min(W × thresholdRatio, W − O − headroomTokens)`.
    public var thresholdRatio: Double
    /// Additional pressure headroom beyond the routed output reservation.
    public var headroomTokens: Int
    /// Recent tail kept verbatim as a fraction of `W − O`.
    public var retainRatio: Double
    /// Absolute recent-tail budget; nil derives `floor((W − O) × retainRatio)`.
    public var retainTokens: Int?
    /// Extra condensation attempts after the first while pressure remains.
    public var compactionRetries: Int
    /// Maximum retries after a provider-confirmed context overflow.
    public var maxOverflowRetries: Int

    public init(
        thresholdRatio: Double = 0.8,
        headroomTokens: Int = 65_536,
        retainRatio: Double = 0.16,
        retainTokens: Int? = nil,
        compactionRetries: Int = 1,
        maxOverflowRetries: Int = 1
    ) {
        self.thresholdRatio = thresholdRatio
        self.headroomTokens = headroomTokens
        self.retainRatio = retainRatio
        self.retainTokens = retainTokens
        self.compactionRetries = compactionRetries
        self.maxOverflowRetries = maxOverflowRetries
    }

    /// Scale this policy into concrete budgets for one model's capacity.
    ///
    /// Pressure is capped by both the window fraction and the capacity left
    /// after the routed output reservation plus headroom. Retention scales the
    /// message budget before headroom is deducted. Every rejection is a load- or
    /// first-use-time misconfiguration rather than a silent skip: a policy that
    /// cannot resolve must not silently disable compaction, or the failure looks
    /// exactly like "the conversation was never under pressure".
    ///
    /// - Parameters:
    ///   - contextWindow: adapter-declared capacity for the routed model.
    ///   - reservedCompletionTokens: output tokens one routed request reserves.
    /// - Returns: pressure and retention budgets for that route.
    /// - Throws: `DSHCompactionConfigError` naming the route and the cause.
    public func resolveSpec(
        targetKey: String,
        contextWindow: Int,
        reservedCompletionTokens: Int
    ) throws -> DSHCompactionSpec {
        guard contextWindow > 0 else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "contextWindow (\(contextWindow)) must be a positive integer"
            )
        }
        guard reservedCompletionTokens >= 0 else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "reservedCompletionTokens (\(reservedCompletionTokens)) "
                    + "must be a non-negative integer"
            )
        }
        guard thresholdRatio > 0, thresholdRatio <= 1 else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "thresholdRatio (\(thresholdRatio)) must be a number in (0, 1]"
            )
        }
        guard headroomTokens >= 0 else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "headroomTokens (\(headroomTokens)) must be non-negative"
            )
        }
        // A window that has to be fully spent on the output reservation plus
        // headroom leaves nothing to measure pressure against.
        let messageBudgetTokens = contextWindow - reservedCompletionTokens
        guard messageBudgetTokens > 0 else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "\(targetKey) reserves \(reservedCompletionTokens) completion tokens "
                    + "of its \(contextWindow)-token context window, leaving no message budget"
            )
        }
        let pressureBudgetTokens = messageBudgetTokens - headroomTokens
        guard pressureBudgetTokens > 0 else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "\(targetKey) reserves \(reservedCompletionTokens) completion tokens "
                    + "and \(headroomTokens) headroom tokens of its \(contextWindow)-token "
                    + "context window, leaving no pressure budget"
            )
        }
        let windowFraction = Int((Double(contextWindow) * thresholdRatio).rounded(.down))
        let thresholdTokens = min(windowFraction, pressureBudgetTokens)
        let derivedRetain = Int((Double(messageBudgetTokens) * retainRatio).rounded(.down))
        let retainTokens = self.retainTokens ?? derivedRetain
        guard retainTokens < thresholdTokens else {
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "retainTokens (\(retainTokens)) must be less than threshold tokens "
                    + "(\(thresholdTokens))"
            )
        }
        return DSHCompactionSpec(
            contextWindow: contextWindow,
            reservedCompletionTokens: reservedCompletionTokens,
            thresholdRatio: thresholdRatio,
            headroomTokens: headroomTokens,
            thresholdTokens: thresholdTokens,
            retainTokens: retainTokens,
            compactionRetries: compactionRetries,
            maxOverflowRetries: maxOverflowRetries
        )
    }

    /// The route key used to report one misconfiguration once.
    public static func targetKey(provider: String, model: String) -> String {
        "\(provider)/\(model)"
    }
}

// MARK: - Unified Trigger

/// Which of the two terms of `min()` is holding the trigger down.
///
/// The formula is a `min` of two bounds and the user only ever set one of them,
/// so "why is it firing here and not there" is otherwise unanswerable from the
/// settings screen. Named terms rather than two raw numbers for that reason.
public enum DSHCompactionThresholdBinding: String, Sendable, Equatable {
    /// `W × thresholdRatio` is the smaller term: the window fraction decides.
    case windowRatio = "window-ratio"
    /// `(W − O) − headroomTokens` is the smaller term: headroom decides.
    case headroom = "headroom"
}

/// The trigger, with the two terms it was chosen from.
///
/// ONE resolution of one formula, shared by every path that decides whether a
/// conversation is under pressure — the engine's mid-turn check
/// (`DSHTurnDriver.compactForPressure`) and the pre-send capacity check on the
/// view-model side. Log 2026-10-19 showed the same conversation carrying two
/// rulers: `[CtxMeter] … threshold=242144` (legacy `W − 20000`) against
/// `[CompactDiag] … threshold=188416` (this policy). Two numbers for one
/// decision is a bug even when both are individually defensible, so the
/// arithmetic moved here and the legacy site is meant to read it too.
public struct DSHCompactionThresholdBreakdown: Sendable, Equatable {
    /// Capacity of the routed model.
    public let window: Int
    /// Output tokens the routed request reserves.
    public let reserved: Int
    /// Pressure headroom beyond the output reservation.
    public let headroom: Int
    /// `floor(W × ratio)`.
    public let windowFraction: Int
    /// `(W − O) − headroom`.
    public let headroomBound: Int
    /// `min(windowFraction, headroomBound)` — the trigger actually in force.
    public let threshold: Int
    /// Which term produced `threshold`.
    public let binding: DSHCompactionThresholdBinding

    /// `windowFraction` as a percentage of the window, for the settings readout.
    public var windowPercentLabel: String {
        guard window > 0 else { return "0%" }
        return "\(Int((Double(windowFraction) / Double(window) * 100).rounded()))%"
    }

    /// Thousands-separated token count, for the settings readout.
    public static func format(_ tokens: Int) -> String {
        let digits = Array(String(tokens))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }
}

extension DSHCompactionPolicy {

    // MARK: - The one spec resolution

    /// Resolve one route's budgets from this policy: the ONLY place a policy
    /// meets a window.
    ///
    /// Upstream has exactly one resolver — `resolveCompactSpec(policy,
    /// contextWindow, reservedCompletionTokens)` in
    /// `packages/compaction/compaction-basic/src/config.ts:153-217` — and every
    /// consumer of a trigger budget calls it: the pressure path
    /// (`index.ts:314-318`) and the overflow path's own policy lookup. This app
    /// had TWO assemblers for the same arithmetic — the driver's `resolveSpec`
    /// (window + policy + both preference overrides) and `/compact`'s
    /// `dshCompactionSpec` (the same three inputs with a different `targetKey`) —
    /// so "the manual command keeps what an automatic compaction keeps" was a
    /// claim about two functions agreeing rather than about one function.
    ///
    /// The optional inputs are the app's two device-experiment overrides, both of
    /// which belong to the resolution and not to its callers:
    /// `retainOverride` replaces the derived retained tail, `pressureThresholdOverride`
    /// replaces the derived trigger. Applying them here is what keeps the ORDER
    /// fixed — policy first, then the overrides on the RESOLVED spec — which is
    /// the order both callers used.
    ///
    /// - Parameters:
    ///   - targetKey: exact `provider/model` route, used to name a
    ///     misconfiguration once per route.
    ///   - contextWindow: adapter-declared capacity, or nil when none is known.
    ///   - reservedCompletionTokens: output tokens one routed request reserves.
    ///   - retainOverride: absolute retained-tail budget, or nil to derive it.
    ///   - pressureThresholdOverride: absolute pressure threshold, or nil to
    ///     derive it.
    /// - Returns: the resolved budget for that route.
    /// - Throws: `DSHCompactionConfigError` when no capacity is known, or when the
    ///   policy cannot be scaled to the capacity that is.
    public func resolvedSpec(
        targetKey: String,
        contextWindow: Int?,
        reservedCompletionTokens: Int,
        retainOverride: Int?,
        pressureThresholdOverride: Int?
    ) throws -> DSHCompactionSpec {
        guard let contextWindow else {
            // Upstream reports the same case as a target configuration error and
            // skips proactive compaction until the adapter declares a window
            // (`compaction-basic/src/index.ts:307-313`).
            throw DSHCompactionConfigError(
                targetKey: targetKey,
                detail: "no context capacity for \(targetKey); the serving model "
                    + "declares no context window"
            )
        }
        var policy = self
        if let retainOverride { policy.retainTokens = retainOverride }
        let spec = try policy.resolveSpec(
            targetKey: targetKey,
            contextWindow: contextWindow,
            reservedCompletionTokens: reservedCompletionTokens
        )
        guard let pressureThresholdOverride else { return spec }
        return spec.overridingThreshold(pressureThresholdOverride)
    }

    /// Resolve the trigger from one policy and one model capacity, keeping both
    /// terms.
    ///
    /// The formula is upstream's, unchanged and unabridged:
    /// `Math.floor(Math.min(contextWindow * thresholdRatio, pressureBudgetTokens))`
    /// (`packages/compaction/compaction-basic/src/config.ts:191-194`, with
    /// `pressureBudgetTokens = contextWindow - reservedCompletionTokens -
    /// headroomTokens` at `:181` and `:172`). The defaults are upstream's own
    /// published values (`DEFAULT_THRESHOLD_RATIO = 0.8` at `:20`,
    /// `headroomTokens ?? 65_536` at `:75`, `DEFAULT_RETAIN_RATIO = 0.16` at
    /// `:23`) and are NOT changed by the settings screen: the screen writes a
    /// stored override, and `resolveSpec` keeps applying this formula to it. The
    /// same clamps `resolveSpec` enforces apply here, so a caller can show the
    /// resolved number without first being able to throw.
    ///
    /// - Parameters:
    ///   - contextWindow: adapter-declared capacity for the routed model.
    ///   - reservedCompletionTokens: output tokens one routed request reserves.
    /// - Returns: the trigger with both of its terms, or nil when the pair cannot
    ///   yield one (non-positive window, or nothing left after output and
    ///   headroom) — the cases `resolveSpec` reports as misconfiguration.
    public func thresholdBreakdown(
        contextWindow: Int,
        reservedCompletionTokens: Int
    ) -> DSHCompactionThresholdBreakdown? {
        guard contextWindow > 0, reservedCompletionTokens >= 0 else { return nil }
        let messageBudget = contextWindow - reservedCompletionTokens
        guard messageBudget > 0 else { return nil }
        let pressureBudget = messageBudget - headroomTokens
        guard pressureBudget > 0 else { return nil }
        let windowFraction = Int((Double(contextWindow) * thresholdRatio).rounded(.down))
        let threshold = min(windowFraction, pressureBudget)
        return DSHCompactionThresholdBreakdown(
            window: contextWindow,
            reserved: reservedCompletionTokens,
            headroom: headroomTokens,
            windowFraction: windowFraction,
            headroomBound: pressureBudget,
            threshold: threshold,
            binding: windowFraction <= pressureBudget ? .windowRatio : .headroom
        )
    }
}

// MARK: - Overflow Classification

/// Recognizes the provider wording that means "this request exceeded the model's
/// context window".
///
/// Port of DSH's `isContextWindowExceededError`. Overflow recovery hangs off this
/// classifier, so a miss is not cosmetic: an unclassified over-length refusal
/// ends the turn as a provider error instead of being answered with a compaction
/// and a retry. The patterns are the same ones DSH ships — the structured
/// `context_length_exceeded`/`context window exceeded` family, the
/// "maximum context length" family, and the three phrasings that tie "too
/// large"/"exceeds" to the model's context specifically.
///
/// DSH's adapters normalize recognized failures to a `CONTEXT_WINDOW_EXCEEDED`
/// code. This app's providers surface the provider's own message text, so the
/// classifier is the only route to the same decision; callers must therefore
/// pass every piece of text a failure carries (code, status, message), not just
/// the message.
public enum DSHContextOverflow {

    /// Structured codes and plain phrases that explicitly name a context bound
    /// being exceeded.
    private static let structured = #"(?:^|[^a-z0-9])context[\s_-](?:length|window)[\s_-](?:exceed(?:ed|s)?|overflow(?:ed)?|limit[\s_-]exceeded)(?:$|[^a-z0-9])"#

    /// Request-size wording that ties "too large" directly to model capacity.
    private static let tooLargeForContext = #"\b(?:request|prompt|input|messages?)\s+(?:is\s+|are\s+)?too\s+(?:large|long)\s+for\s+(?:(?:this|the)\s+)?(?:model(?:'s)?\s+)?context(?:\s+window)?\b"#

    /// "Exceeds" wording is safe only when its object is explicitly the model
    /// context.
    private static let exceedsModelContext = #"\b(?:input|prompt|request|messages?)\b.{0,40}\b(?:exceed(?:s|ed)?|overflows?|is\s+larger\s+than)\b.{0,40}\b(?:the\s+)?(?:model(?:'s)?\s+)?context(?:\s+(?:length|window))?\b"#

    /// The declared maximum context, named as such.
    private static let maximumContext = #"\b(?:maximum|max)(?:\s+(?:allowed|supported))?\s+context\s+(?:length|window)\b"#

    /// "too long for this model", without naming the context explicitly.
    private static let tooLongForModel = #"\b(?:input|prompt|request)\s+(?:is\s+)?too\s+(?:long|large)\s+for\s+(?:this|the)\s+model\b"#

    /// The canonical provider-neutral code DSH normalizes this failure to.
    public static let code = "CONTEXT_WINDOW_EXCEEDED"

    /// Whether a failure's text identifies a request exceeding the model window.
    ///
    /// - Parameter detail: provider code, status, and message text joined into
    ///   one string, so in-band and thrown delivery styles share one classifier.
    /// - Returns: true when the detail names a context bound being exceeded.
    public static func isContextWindowExceeded(_ detail: String) -> Bool {
        if detail.contains(code) { return true }
        return matches(structured, detail)
            || matches(maximumContext, detail)
            || matches(tooLargeForContext, detail)
            || matches(tooLongForModel, detail)
            || matches(exceedsModelContext, detail)
    }

    private static func matches(_ pattern: String, _ detail: String) -> Bool {
        detail.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
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
    ///   - pressureThreshold: priced tokens above which compaction is worth doing.
    ///     When the measurement passed below is below this, selection returns
    ///     nil. Pass `0` to select the maximal balanced head reduction with no
    ///     pressure gate at all — the provider-confirmed overflow path, where the
    ///     request has already failed.
    ///   - measuredTokens: the priced request envelope the gate compares, i.e.
    ///     system prompt + tool roster + surface. DSH gates on the token meter's
    ///     envelope total, not on the surface total; measuring the surface alone
    ///     under-reports exactly the part of the request this app cannot shrink
    ///     and lets a request overflow while the surface still looks small.
    /// - Returns: the range to compact, or nil when nothing should be compacted.
    public static func select(
        surface: [DSHLogEntry],
        retainTokens: Int,
        pressureThreshold: Int,
        measuredTokens: Int
    ) -> DSHCompactableRange? {
        guard !surface.isEmpty else { return nil }

        guard measuredTokens >= pressureThreshold else { return nil }

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
    /// The model that wrote the summary, recorded so "which model wrote this"
    /// has a durable answer rather than being inferred from the provider route.
    public let model: String
    /// The provider route the summary came from.
    public let provider: String

    public var shrinkRatio: Double {
        guard beforeTokens > 0 else { return 0 }
        return Double(beforeTokens - afterTokens) / Double(beforeTokens)
    }
}

/// Runs the compaction transaction.
public enum DSHCompaction {

    /// The compaction lock, in memory.
    ///
    /// The mutex is taken only to flip the flag — never across the summary
    /// `await` — so a long summarization cannot block another compaction's
    /// caller, and there is no lock for a suspension point to re-enter. What is
    /// held for the duration of a compaction is the *flag*, which is what makes
    /// `begin` the answer to "is a compaction already open" rather than to "is one
    /// running right now on this thread".
    ///
    /// Upstream's equivalent is durable rather than in-memory
    /// (`region.ts:185-189`'s `assertCompactionInactive`, `index.ts:305`'s
    /// `assertNoActiveCompaction`), because its marker pair is written before the
    /// summary call. See the file header for why this app's is the in-process
    /// half of the same rule.
    private final class Bracket: @unchecked Sendable {
        var open = false
        var turn: Int?
        let lock = NSLock()

        /// Claim the bracket for one compaction.
        ///
        /// - Parameter turn: enclosing turn for an automatic compaction, nil for a
        ///   standalone manual one. Recorded for diagnostics only.
        /// - Returns: false when another compaction already holds it — the caller
        ///   answers `.busy` rather than waiting, exactly as upstream refuses
        ///   (`ManualCompactionError('busy', …)`).
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

    /// The one bracket every compaction goes through, on either loop.
    private static let bracket = Bracket()

    /// Compact a session's surface.
    ///
    /// Exactly one compaction runs at a time in this process: a second caller —
    /// the driver's mid-turn pressure path, its overflow recovery, or `/compact` —
    /// gets `.busy` instead of interleaving with the one in flight. See `Bracket`
    /// and the file header for the upstream rule this stands in for.
    ///
    /// - Parameters:
    ///   - session: the session to compact.
    ///   - turn: the enclosing turn for an automatic compaction, or nil for a
    ///     standalone manual one.
    ///   - retainTokens: recent-tail budget retained verbatim. `0` retains only
    ///     the newest surface node, which is the maximal balanced head reduction.
    ///   - pressureThreshold: priced tokens above which compaction runs; `0`
    ///     removes the gate (the provider-confirmed overflow path).
    ///   - measuredTokens: the priced request envelope `pressureThreshold` is
    ///     compared against. Must be the same value the caller gated on.
    ///   - summaryTools: the conversation's own tool roster, as the routed request
    ///     carries it. Supplied by the caller because this function cannot see a
    ///     registry: `DSHTurnDriver` passes what its `DSHToolRegistry` declares and
    ///     `/compact` passes `dshAgentTools()`. Upstream takes the same value from
    ///     the last routed request's header (`region.ts:548,560`), which is what
    ///     makes the auxiliary call a prefix of the conversation.
    ///   - summarize: builds the summary for the shadowed content. Called with the
    ///     replayed region — its messages, the derived system head, and this
    ///     roster — as `DSHSummaryInput`, never with a flattened excerpt.
    ///   - model / provider: recorded on the summary so "which model wrote this"
    ///     has a durable answer.
    /// - Returns: the outcome, or an error.
    ///
    /// INTERNAL, not public. `summaryTools` is `[AgentToolDefinition]`, which is
    /// internal to this target, and a public member may not name an internal type
    /// — the exact "method cannot be declared public because its parameter uses an
    /// internal type" error this project has already paid a CI round for
    /// (`PIPELINE-NOTES.md` §3, and `preflight-swift.ps1`'s typecheck flags it).
    /// Both callers are in this module, so internal is the honest declaration: the
    /// `public` on this function was never load-bearing.
    static func compact(
        session: DSHSession,
        turn: Int?,
        retainTokens: Int,
        pressureThreshold: Int,
        measuredTokens: Int,
        model: String,
        provider: String,
        summaryTools: [AgentToolDefinition],
        summarize: @escaping @Sendable (DSHSummaryInput) async throws -> String
    ) async -> Result<DSHCompactionOutcome, DSHCompactionError> {
        // Upstream's first act, before anything is read or selected
        // (`region.ts:183-189`): refuse while a compaction is already open. The
        // bracket is released on every exit of this function, including the
        // failure returns below — `defer` rather than a trailing `end()`.
        guard Self.bracket.begin(turn: turn) else { return .failure(.busy) }
        defer { Self.bracket.end() }

        let surface = session.surface()
        let beforeTokens = DSHTokenEstimate.total(surface)

        guard let range = DSHCompactionSelection.select(
            surface: surface,
            retainTokens: retainTokens,
            pressureThreshold: pressureThreshold,
            measuredTokens: measuredTokens
        ) else {
            return .failure(.noShrink)
        }

        let input = await Self.summaryInput(
            surface: surface,
            range: range,
            tools: summaryTools
        )

        let summaryText: String
        do {
            summaryText = try await summarize(input)
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

        // [T-nonmonotonic-seq-range] `shadowedSeqs` is in surface order, not seq order: a
        // range that ends inside the previously kept tail yields descending values, and
        // `first!...last!` would then trap in `ClosedRange.init` (a crash, not a throw).
        // The range only means "the span of seqs this summary shadows", so take the
        // extremes.
        guard let shadowedLow = range.shadowedSeqs.min(),
              let shadowedHigh = range.shadowedSeqs.max(),
              shadowedLow <= shadowedHigh else {
            return .failure(.noShrink)
        }
        let shadowedRange = shadowedLow...shadowedHigh
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
            afterTokens: afterTokens,
            model: model,
            provider: provider
        ))
    }

    // MARK: - Summary Envelope

    /// Wrap a summary so the model treats it as background rather than as the
    /// current instruction.
    ///
    /// The precedence clause matters: without it a stale summary can override a
    /// newer, shorter user instruction, which is the failure the envelope exists
    /// to prevent.
    ///
    /// The text itself is `AIChatViewModel.compactSummaryWrappedText` — the
    /// envelope the store-side compaction has always used, i.e. the one upstream
    /// Minis ships. It used to be paraphrased here, and the paraphrase differed in
    /// three places ("the earlier conversation", "(below or in the next turn)",
    /// "numbers/scope"), so a session compacted by the driver and one compacted by
    /// the store showed the model two different framings of the same fact. One
    /// wording, one function.
    static func summaryEnvelope(_ summary: String) -> String {
        AIChatViewModel.compactSummaryWrappedText(summary)
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

// MARK: - Summary Input Assembly

/// The replayed conversation prefix one summary request carries.
///
/// The iOS counterpart of upstream's `SummarizationInput`
/// (`packages/compaction/compaction-basic/src/summarizer.ts:79-84`) plus the
/// region it was built from. Upstream's shape is
/// `messages: [system?, ...regionMessages]` with the last routed request's
/// tools beside it, and the compaction directive appended as the FINAL user
/// message (`:145-151`) — not a separate "summarizer system prompt". This
/// type is that prefix, with one structural difference the app's provider
/// protocol forces: `AgentMessage.Role` has only `user` and `assistant`, so
/// the derived system head cannot be a member of `messages` and rides in
/// `systemPrompt` instead — which is exactly where
/// `streamAgentMessageClamped` puts it, so the wire request still has the
/// system message first.
///
/// INTERNAL, and so are its members. Its only use in a signature is
/// `compact`, which is internal because it takes the internal
/// `AgentToolDefinition` roster — and a public declaration may not name an
/// internal type (`PIPELINE-NOTES.md` §3: that error has already cost a CI
/// round). With no public signature naming this type, `public` here would be a
/// no-op at best and a trap at worst.
struct DSHSummaryInput {

    /// The region's messages, in surface order, with no `system` role.
    let messages: [AgentMessage]

    /// The derived system head: the text of a `system` message at surface
    /// node 0, or nil when the surface has none.
    ///
    /// Upstream reads it from the session's own `system/message` event
    /// (`region.ts:551-552`). THIS APP'S SESSIONS DO NOT CARRY ONE — the
    /// rendered system prompt is assembled per step (`DSHTurnDriver.buildRequest`)
    /// and never appended to the log — so this is nil in the shipped
    /// configuration. The parameter is kept because the rule is upstream's
    /// and because a caller that does hold a head (a seeded session, a future
    /// one that logs its prompt) must not need a second shape. See
    /// `summaryInput(surface:range:tools:)`.
    let systemPrompt: String?

    /// The conversation's tool roster, reused for prefix-cache alignment.
    ///
    /// Absent when the routed request carried none — upstream models that as
    /// an optional field (`summarizer.ts:79-84`) and omits the key rather
    /// than sending `[]`.
    let tools: [AgentToolDefinition]

    /// The region rendered as text: `[role] text` lines per entry, entries
    /// separated by `"\n\n"`.
    ///
    /// Not sent. It is the diagnostic figure (`excerptChars=`,
    /// `excerptTokensEst=`) and the fallback rendering a region with no
    /// entries is summarized from.
    let renderedText: String

    /// The surface entries `messages` were projected from, oldest first and
    /// index-aligned with it.
    ///
    /// The budget is spent at THIS granularity: an `AgentMessage` cannot be
    /// measured in the estimator's units (`DSHTokenEstimate.tokens(for:)`
    /// reads blocks) and cannot be cut at a tool-pairing boundary without
    /// inspecting `AgentContentPart` — an enum whose associated values differ
    /// between the iOS 15 and iOS 26 lines, which is precisely why the two
    /// files that touch it are the two the trees are allowed to differ in.
    /// `DSHCompaction.swift` is byte-identical in both trees, so the region
    /// travelling beside its projection is what lets one shared file budget,
    /// trim and segment it without ever matching a part.
    let entries: [DSHLogEntry]

    init(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        renderedText: String,
        entries: [DSHLogEntry]
    ) {
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.renderedText = renderedText
        self.entries = entries
    }

    /// The region's rendered text, per entry, in the same order as `entries`.
    var entryTexts: [String] {
        entries.map { DSHCompaction.renderForSummary($0) }
    }
}

extension DSHCompaction {

    /// Build the request-shaped view of a selected range.
    ///
    /// One rendering of upstream's `buildSummarizationInput`
    /// (`packages/compaction/compaction-basic/src/region.ts:544-563`):
    ///
    ///   * the system head is `systemHead(session, surface.nodes[0])` — node 0
    ///     only, and only when it is a `system` message (`:99`, `:551-552`);
    ///   * the region is `shadowedSeqs.map(session.deriveEventMessage).filter(non-null)`
    ///     (`:553-558`) — every entry of the range, in surface order, projected
    ///     the same way the conversation's own request projects it;
    ///   * `tools` is the caller's roster (`:560`), because this function cannot
    ///     see a registry.
    ///
    /// THE PROJECTION IS THE LOOP'S OWN. `DSHSessionProjection.toAgentMessage`
    /// is what `DSHTurnDriver.projectMessages` and the view model both use, so a
    /// summary request replays the same parts — the same verbatim tool-call
    /// arguments (`AgentToolArguments.wire`), the same tool-result images, the
    /// same roles — as the request it is a prefix of. It is `@MainActor`, and
    /// this function is not, hence the single hop below; both callers of `compact`
    /// are already on the main actor, so this costs a suspension, not a thread.
    ///
    /// - Parameters:
    ///   - surface: the session's surface, oldest first.
    ///   - range: the span being compacted, as `select` returned it.
    ///   - tools: the conversation's own tool roster.
    /// - Returns: the region as a request prefix.
    static func summaryInput(
        surface: [DSHLogEntry],
        range: DSHCompactableRange,
        tools: [AgentToolDefinition]
    ) async -> DSHSummaryInput {
        let entries = Array(surface[range.startIndex...range.endIndex])
        let projected = await MainActor.run {
            entries.map { DSHSessionProjection.toAgentMessage($0) }
        }
        // A message with no parts is not a message any provider accepts, and the
        // loop's own projection drops it too (`projectMessages`, `guard !parts.isEmpty`).
        // `toAgentMessage` returns one for an entry whose only blocks are a kind
        // this line does not know. The two arrays are filtered TOGETHER so
        // `entries[i]` stays the source of `messages[i]` — the budget is spent on
        // the entries and the messages are sent, so an off-by-one here would
        // budget one entry and send another.
        var keptEntries: [DSHLogEntry] = []
        var keptMessages: [AgentMessage] = []
        for (entry, message) in zip(entries, projected) where !message.parts.isEmpty {
            keptEntries.append(entry)
            keptMessages.append(message)
        }
        let rendered = keptEntries.map { DSHCompaction.renderForSummary($0) }
            .joined(separator: "\n\n")
        return DSHSummaryInput(
            messages: keptMessages,
            systemPrompt: systemHeadText(surface),
            tools: tools,
            renderedText: rendered,
            entries: keptEntries
        )
    }

    /// The system head's text, when surface node 0 is a `system` message.
    ///
    /// Upstream's `systemHead` recognises the event type
    /// (`packages/compaction/compaction-basic/src/region.ts:99`); in this app the
    /// head is a message role. Multiple text blocks are joined with `"\n\n"` —
    /// the same separator `DSHCompaction.compact` joins entries with, so the head
    /// reads as one block when it reaches the provider's system slot.
    ///
    /// - Parameter surface: the session's surface, oldest first.
    /// - Returns: the head's text, or nil when there is no system head.
    static func systemHeadText(_ surface: [DSHLogEntry]) -> String? {
        guard let head = surface.first, head.message.role == .system else { return nil }
        let text = head.message.blocks
            .compactMap { ($0 as? DSHTextBlock)?.text }
            .joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }
}

// MARK: - The Compaction Directive

/// Upstream's `COMPACTION_INSTRUCTION`, verbatim
/// (`packages/compaction/compaction-basic/src/summarizer.ts:32-67`).
///
/// Delivered as the FINAL user message after the replayed conversation, never as
/// a summarizer system prompt: that is what keeps the auxiliary call a genuine
/// prefix of the last routed request, so the provider's KV cache is reused
/// instead of invalidated (`:26-31`). The text is copied line for line, including
/// the empty lines and the `Rules:` list — a summarizer that is asked for a
/// different structure produces a checkpoint the next model cannot resume from,
/// and the failure shows up as a vague answer three turns later.
///
/// The one substitution is `${SUMMARY_OPEN_TAG}` (`:66`) → `<compacted-summary>`,
/// its declared value at `:22`. This app's envelope is a different literal (see
/// `DSHCompaction.summaryEnvelope`), but the RULE the last line states — merge a
/// prior checkpoint rather than copying it forward — is about the model's own
/// output, and it names the tag this instruction's structure produces.
public enum DSHCompactionInstruction {

    /// The directive, as the one string it is.
    public static let text: String = [
        "You are now acting as a compaction engine for this AI coding assistant. Condense the conversation ABOVE into a structured checkpoint that lets another model resume the work with no loss of essential context.",
        "",
        "Output EXACTLY the Markdown structure below: keep every section, in order. Use terse bullets, not prose paragraphs. Write \"(none)\" for an empty section — never drop a section.",
        "",
        "## Primary Request and Intent",
        "- [the user's original and evolving goals; quote verbatim where the exact wording matters]",
        "",
        "## Key Technical Concepts",
        "- [technologies, frameworks, patterns, and conventions in play]",
        "",
        "## Files and Code",
        "- [exact path: why it matters, key changes or snippets]",
        "",
        "## Errors and Fixes",
        "- [error: how it was resolved, plus any related user feedback]",
        "",
        "## Pending Jobs",
        "- [explicitly requested work not yet completed]",
        "",
        "## Current Work",
        "- [precisely what was in progress at this checkpoint]",
        "",
        "## Next Step",
        "- [the single next action, directly in line with the most recent request, or \"(none)\"]",
        "",
        "## Critical Context",
        "- [decisions and their rationale, constraints, user preferences, open questions, data needed to continue]",
        "",
        "Rules:",
        "- Write concise English engineering prose. Preserve exact file paths, commands, error strings, identifiers, numeric values, function signatures, and syntax fragments.",
        "- Capture user feedback and explicit instructions faithfully, especially corrections.",
        "- Do NOT mention this summarization request or that the context was compacted.",
        "- Output only the checkpoint text: do not call any tool or take any other action.",
        "- If the conversation already contains a <compacted-summary> block, it is a PRIOR checkpoint. Do not copy it forward verbatim: preserve still-true facts, drop stale ones, and merge newer information into a single consolidated summary under the same structure.",
    ].joined(separator: "\n")
}
