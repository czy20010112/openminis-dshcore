//
//  DSHContextPanel.swift
//  Minis
//
//  The context ring in the composer, and the breakdown sheet behind it.
//
//  Two numbers describe "how full is the context", and they come from different
//  places on purpose:
//
//    * the ring's arc and the sheet's HEADER use what the PROVIDER reported for
//      its last call — `ChatMessage.usage.latestContextTokens` on the newest
//      usage-bearing assistant row. That is the only measured figure in this
//      file, and it is what the model will actually be sent next turn;
//    * the three component ROWS are measured while the request is assembled, in
//      `DSHTurnDriver.buildRequest()`, where the system prompt, the tool roster
//      and the conversation are all in hand at once. Estimating them afterwards
//      (from the UI, against the surface) would describe a different request
//      than the one that was sent.
//
//  ON SCREEN, that difference is carried by ONE short line under the rows
//  ("Estimated from character count at 3.6 characters per token. The top figure
//  is the provider's own count, so these rows may sum a few percent above or
//  below it.") and by nothing else. The panel used to say it three more times —
//  a "WHO MEASURED WHAT" paragraph, a "measured by the provider" caption under
//  the header figure, and a "Measured / Provider" pair at the bottom — and the
//  operator had each of them removed, one round at a time. Do not restore them:
//  the long form of the attribution is this comment, and the one line under the
//  rows is what keeps the two figures from reading as one number.
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

// MARK: - Reading

/// The provider's own context figure for the last call, and the window it is
/// measured against.
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

    var hasWindow: Bool { windowTokens > 0 }

    var fraction: Double {
        guard windowTokens > 0 else { return 0 }
        return min(max(Double(usedTokens) / Double(windowTokens), 0), 1)
    }

    var percent: Int { Int((fraction * 100).rounded()) }

    /// Newest provider-reported context size among these messages, or nil when
    /// no assistant row carries usage yet.
    static func latest(messages: [ChatMessage], window: Int?) -> DSHContextReading? {
        let reported = messages.last {
            $0.role == .assistant && ($0.usage?.latestContextTokens ?? 0) > 0
        }
        guard let used = reported?.usage?.latestContextTokens, used > 0 else { return nil }
        return DSHContextReading(usedTokens: used, windowTokens: window ?? 0)
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
    var capturedAt: Date

    var estimatedTotal: Int { systemPromptTokens + toolTokens + surfaceTokens }
}

/// Holds the newest breakdown so the sheet can show it.
///
/// A store rather than a ViewModel property because the writer is the turn
/// driver (once per step, mid-turn) and the reader is a sheet the composer owns;
/// routing it through the ViewModel would add a published property that only
/// this panel reads.
@MainActor
final class DSHContextBreakdownStore: ObservableObject {

    static let shared = DSHContextBreakdownStore()

    @Published private(set) var latest: DSHContextBreakdown?

    private init() {}

    /// Record one assembled request.
    ///
    /// Called from `DSHTurnDriver.buildRequest()` immediately before the request
    /// is returned, so what is measured is what is sent. The conversation row is
    /// measured over the DSH surface — the same list `maybeCompact` measures —
    /// rather than over the provider-facing projection, so this row and the
    /// compaction decision can never disagree about the conversation's size.
    func record(
        systemPrompt: String,
        tools: [DSHToolSchema],
        surface: [DSHLogEntry],
        sectionNames: [String],
        model: String,
        provider: String
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
            capturedAt: Date()
        )
        if next != latest { latest = next }
    }

    /// Drop the measurement, so a later session cannot open the panel on the
    /// previous session's request. Not wired to a call site yet: the next turn of
    /// any session overwrites it, and the panel is opened from a composer whose
    /// own turn has assembled at least one request.
    func clear() {
        if latest != nil { latest = nil }
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
    /// nil until the provider has reported usage for this session. The ring is
    /// still drawn — an empty ring means "nothing measured yet", which is
    /// information, and the width stays constant so the read-aloud toggle's width
    /// budget stays a constant too.
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
        guard let reading else { return AppLocalized("Context: no usage reported yet") }
        let ratio = DSHContextFormat.ratio(used: reading.usedTokens, window: reading.windowTokens)
        // One key with two arguments, the same shape the iOS 26 line already uses
        // for the reading of this ring.
        return String(format: AppLocalized("Context %lld%% used — %@"), reading.percent, ratio)
    }
}

// MARK: - Panel

/// The context breakdown sheet, presented from the composer's ring.
struct DSHContextPanel: View {

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
        // Ends the sheet near the content's bottom edge instead of leaving the
        // full page sheet (iOS 15) or the 0.8-fraction detent (iOS 16) standing
        // open under it. See `DSHContextSheetHeightProbe`.
        .background(DSHContextSheetHeightProbe())
    }

    // MARK: Header

    /// The top-right figure: `~296K / 1M`. Two numbers and a separator, so it is
    /// not a catalog key; it is set in the CODE face so the digits are tabular
    /// and line up with the value column of the rows underneath.
    private var ratioText: String {
        guard let reading else { return "—" }
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
                Text(headerSubtitle)
                    .font(Font(AppFont.ui(12, category: .ui)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            // The provider's figure, and the window it is measured against. This
            // is the measured number; everything below it is our estimate, and
            // the note under the rows says so. Two captions used to sit under
            // this figure — a "via <provider>" line and then "measured by the
            // provider" — and the operator called the second one unnecessary:
            // the note says the same thing in the sentence that needs it.
            Text(ratioText)
                .font(AppFont.sw(15, weight: .semibold, category: .code))
                .foregroundStyle(.primary)

            Button("Done") { dismiss() }
                .font(Font(AppFont.ui(15, category: .body)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// The one line under "Context": how full the window is. It does not carry
    /// the attribution of the two figures — the note under the rows does, and a
    /// reader who needs the long version has the comment at the top of this file.
    ///
    /// Built as a `String` through `AppLocalized`/`String(format:)` rather than as
    /// a `LocalizedStringKey`: the sentence is assembled from a format and a name,
    /// and `LocalizedStringKey` does not convert to `String` on the iOS 15 line,
    /// so a composed key could not be handed to `AppLocalized` there.
    private var headerSubtitle: String {
        guard let reading else { return AppLocalized("No usage reported yet") }
        guard reading.hasWindow else { return AppLocalized("The model's window is unknown") }
        return String(format: AppLocalized("%lld%% of the window"), reading.percent)
    }

    // MARK: Rows

    private var components: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This request, estimated")
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
                ContextRow(
                    label: "Total (estimated)",
                    value: DSHContextFormat.approx(b.estimatedTotal),
                    detail: nil,
                    emphasised: true
                )
                // Replaces the old "WHO MEASURED WHAT" paragraph: the same
                // information — these figures are ours, the header's is the
                // provider's — in the one line a reader needs for it.
                Text("Estimated from character count at 3.6 characters per token. The top figure is the provider's own count, so these rows may sum a few percent above or below it.")
                    .font(Font(AppFont.ui(11, category: .ui)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
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
/// to `AIChatView`, which asks for `[.fraction(0.8), .large]` through
/// `compatDetents` — and `compatDetents` is a NO-OP below iOS 16, which is the
/// line installed on the device. Measured on the iPhone 13 / iOS 15.3.1 target
/// (screenshot plus the accessibility tree): the sheet is the full page sheet
/// (top edge y≈52, bottom 844) while the panel's content ends at y≈495 — 349pt
/// of empty sheet under it, which is the operator's "too much blank space at the
/// bottom". Below iOS 16 `PresentationDetent` has no custom height at all, so the
/// content-proportionate value UIKit does offer is the medium detent (about half
/// the screen ≈ 420pt, against ≈310pt of content once the provenance rows are
/// gone). `.large` stays in the set so a taller panel can still be pulled up.
/// `UISheetPresentationController`, `Detent.medium()` / `.large()`,
/// `selectedDetentIdentifier` and `animateChanges` are all iOS 15.0, so nothing
/// here is an iOS 16 API.
///
/// The one-detent guard below is the "do not fight" rule: it pins only while the
/// sheet is still at UIKit's own default, i.e. while nothing else has expressed a
/// height preference. On iOS 16+, where `compatDetents` does reach SwiftUI and
/// `AIChatView` has already set `[.fraction(0.8), .large]`, this leaves those
/// alone rather than overwriting them from underneath. That line is where the
/// iOS 26 line's own blank space has to be fixed — out of this file's scope.
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
