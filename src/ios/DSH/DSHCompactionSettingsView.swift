//
//  DSHCompactionSettingsView.swift
//  Minis
//
//  The compaction trigger, and the runaway bound that is not a turn budget.
//
//  WHY THIS FILE SITS IN `src/ios/DSH/`
//  ---------------------------------------------------------------------------
//  `DSH/` is a `PBXFileSystemSynchronizedRootGroup` in Minis.xcodeproj, so a file
//  dropped here is compiled with no project edit — in both trees, whose pbxproj
//  files are not copies of each other. `DSHCompactionSettings` (the store this
//  screen edits) lives in the same file for the same reason, and because the read
//  sites are all inside `DSH/`.
//
//  WHAT THE NUMBERS MEAN
//  ---------------------------------------------------------------------------
//  The trigger is upstream's, unchanged:
//
//      threshold = floor(min(W × thresholdRatio, (W − O) − headroomTokens))
//
//  (`packages/compaction/compaction-basic/src/config.ts:191-194`; ratio 0.8 at
//  `:20`, headroom 65 536 at `:75`.) Both terms are shown below because the user
//  sets only one of them and the OTHER can be the one in force: on the 262 144
//  route in `F:\smb\log\minis-2026-10-19.log` the ratio term resolves to 209 715
//  and the headroom term to 188 416, so a slider reading "80%" was describing a
//  trigger that was actually firing at 71.9% of the window. The `Binding` row
//  names which term won.
//
//  `O` in that formula is the routed request's output reservation. This screen
//  resolves the readout against the driver's own default reservation
//  (`DSHTurnDriverConfig().maxTokens` — read from the type rather than typed in
//  twice, so the two cannot drift). A conversation whose model carries a
//  per-model output override reserves more, which lowers the headroom term and
//  therefore the trigger — which is why the turn-start log line carries the
//  numbers that were actually in force rather than only the two settings.
//
//  NO EXPLANATION COPY
//  ---------------------------------------------------------------------------
//  Same rule as `DSHSpillSettingsView`: the controls and the live readout only.
//  Rows may say what they are and what the value currently is; a paragraph saying
//  why is a comment, not a footer.
//

import SwiftUI

// MARK: - Store

/// The compaction settings, read live on every turn rather than cached.
///
/// Re-read per use for the reason `DSHSpillFeature.config` is: a turn is
/// long-lived, the read is cheap, and a cached copy would keep a stale trigger for
/// the rest of the process after the setting changed. The keys are registered
/// here (`register(defaults:)`) so the app's own defaults carry the shipped values
/// — this app rewrites its plist at launch and discards an external write, so a
/// value that exists only as a fallback in code would be invisible to `-defaults`
/// and to anyone inspecting the plist.
enum DSHCompactionSettings {

    /// Window fraction, as `DSHCompactionPolicy.thresholdRatio`.
    static let triggerRatioKey = "minis.dshCompactTriggerRatio"

    /// Pressure headroom, as `DSHCompactionPolicy.headroomTokens`.
    static let headroomTokensKey = "minis.dshCompactHeadroomTokens"

    /// Explicit per-turn step ceiling. 0 (the shipped value) means no ceiling.
    ///
    /// Deliberately a number rather than a switch plus a number: the driver's
    /// field is already an `Int?`, and "the ceiling is off" is the same fact as
    /// "there is no ceiling", which one key states without two sources of truth.
    static let stepLimitKey = "minis.dshMaxStepsPerTurn"

    /// DSH's own published defaults, and this app's shipped values.
    ///
    /// Not changed by this screen: the screen writes a stored override and the
    /// policy is built from it, so a user who never opens the screen runs the
    /// upstream values exactly.
    static let shippedThresholdRatio = 0.8
    static let shippedHeadroomTokens = 65_536

    /// How far below DSH's 0.8 the slider is allowed to go. A trigger under a
    /// tenth of the window would compact a conversation that has barely started.
    static let minThresholdRatio = 0.1

    /// The shipped step ceiling: none. See `DSHTurnDriverConfig.maxStepsPerTurn`.
    static let shippedStepLimit = 0

    /// Ceiling on the step-limit field. Above this the number is not a backstop,
    /// it is a typo.
    static let maxStepLimit = 10_000
    /// Ceiling on the headroom field: beyond the largest window this app routes,
    /// a larger headroom simply makes the trigger unresolvable.
    static let maxHeadroomTokens = 200_000

    /// The stored ratio, or DSH's default.
    static var triggerRatio: Double {
        let store = UserDefaults.standard
        guard store.object(forKey: triggerRatioKey) != nil else { return shippedThresholdRatio }
        let value = store.double(forKey: triggerRatioKey)
        guard value >= minThresholdRatio, value <= 1 else { return shippedThresholdRatio }
        return value
    }

    /// The stored headroom, or DSH's default.
    static var headroomTokens: Int {
        let store = UserDefaults.standard
        guard let value = store.object(forKey: headroomTokensKey) as? Int,
              value >= 0, value <= maxHeadroomTokens else { return shippedHeadroomTokens }
        return value
    }

    /// The stored step ceiling, or nil for none.
    ///
    /// nil is the shipped answer and it is what every caller that has not opted in
    /// gets: a turn's real bound is the context window, and a fixed step count
    /// reported long work as a failure.
    static var stepLimitPerTurn: Int? {
        let store = UserDefaults.standard
        guard let value = store.object(forKey: stepLimitKey) as? Int, value > 0 else { return nil }
        return min(value, maxStepLimit)
    }

    /// The policy to hand a turn, built from the stored settings.
    ///
    /// `retainRatio` and the two retry budgets are DSH's own and are not exposed:
    /// the screen moves the trigger, never what a compaction keeps.
    static func policy() -> DSHCompactionPolicy {
        DSHCompactionPolicy(
            thresholdRatio: triggerRatio,
            headroomTokens: headroomTokens
        )
    }

    // MARK: Writes

    static func store(triggerRatio ratio: Double) {
        let clamped = min(1, max(minThresholdRatio, ratio))
        let store = UserDefaults.standard
        store.register(defaults: [triggerRatioKey: shippedThresholdRatio])
        store.set(clamped, forKey: triggerRatioKey)
    }

    static func store(headroomTokens tokens: Int) {
        let clamped = min(maxHeadroomTokens, max(0, tokens))
        let store = UserDefaults.standard
        store.register(defaults: [headroomTokensKey: shippedHeadroomTokens])
        store.set(clamped, forKey: headroomTokensKey)
    }

    /// Store an explicit ceiling, or remove it.
    ///
    /// `0` is written rather than the key removed, so "no ceiling" is a recorded
    /// choice — the same reason `DSHSpillConfig.setEnabled` writes 0 instead of
    /// deleting its key.
    static func store(stepLimitPerTurn limit: Int?) {
        let store = UserDefaults.standard
        store.register(defaults: [stepLimitKey: shippedStepLimit])
        guard let limit, limit > 0 else {
            store.set(0, forKey: stepLimitKey)
            return
        }
        store.set(min(limit, maxStepLimit), forKey: stepLimitKey)
    }

    /// The context window THIS SESSION is being compacted against, for the readout.
    ///
    /// It is the driver's own capacity, not a survey of the model pool: every
    /// assembled request stamps `DSHContextBreakdown.windowTokens` with
    /// `DSHTurnDriverConfig.contextWindow`, which is the same
    /// `effectiveContextWindow(for:)` value the turn-start line prints as `window=`
    /// (`DSHTurnDriverRun.swift:806` builds the config, `:862` logs it). One number,
    /// written where the request is built and read here, so this row and the trigger
    /// below it cannot describe two different capacities.
    ///
    /// The pool figure used to be the answer: on a device routed to 262 144 tokens it
    /// printed 786 432 — the widest of 29 configured models — and both trigger terms
    /// were then priced against a window no request ever used.
    ///
    /// `@MainActor` because `ProviderConfigStore` and `DSHContextBreakdownStore` are:
    /// both are main-actor state, and a nonisolated reader would be a data race the
    /// compiler is right to refuse. The only caller is this screen's body, which is
    /// already on the main actor.
    @MainActor
    static var sessionContextWindow: Int? {
        // The stamp is the answer whenever a request has been assembled in THIS
        // process. Read without filtering on a session key: the driver's config
        // carries `sessionKey == nil` on the device path, so a filter would reject
        // every real stamp (the same reason `DSHContextBreakdownStore` attributes an
        // unnamed assembly to its bound session), and the sheet this screen belongs
        // to is opened for the conversation on screen.
        //
        // [T-dsh-breakdown-durable] A copy RESTORED from disk does not count: the
        // store now remembers the last assembly per conversation across launches,
        // and its `windowTokens` describes whichever route that run used. On a
        // cold start this screen must say what the pool offers (or what the next
        // turn will resolve), not what a previous run was routed to — the row is
        // labelled with the session's window, and claiming one before this process
        // has seen a request would be the same "stale readout" the composer's
        // usage line had.
        let store = DSHContextBreakdownStore.shared
        if !store.latestIsRestoredFromDisk,
           let stamped = store.latest?.windowTokens, stamped > 0 {
            return stamped
        }
        return widestPoolContextWindow
    }

    /// The largest context window this device currently routes.
    ///
    /// The cold-start fallback for `sessionContextWindow`: a fresh launch, or a
    /// session that has not assembled a request yet, has no stamp to read, and a
    /// blank row is worse than a labelled preview of the trigger. It is a POOL
    /// figure — the widest of every routed (or configured) model — so it says
    /// nothing about the route in force; it is what the row showed all the time
    /// before the stamp existed.
    @MainActor
    static var widestPoolContextWindow: Int? {
        // `contextWindowTokens`, not `contextWindow`: the latter is optional and is often
        // nil for an entry whose window the app learned from the endpoint, which is the
        // number `effectiveContextWindow(for:)` routes on and the one the trigger uses.
        // A profile whose agent-loop selection was never recorded lists no routed
        // entries, and the screen then said "none routed" for a route that plainly works.
        // Fall back to every configured model: this figure previews the trigger, it does
        // not decide the route.
        let routed = ProviderConfigStore.shared.resolvedAgentLoopEntries
        let candidates = routed.isEmpty
            ? ProviderConfigStore.shared.config.modelEntries
            : routed
        return candidates
            .map { $0.model.contextWindowTokens }
            .filter { $0 > 0 }
            .max()
    }

    /// One rendering of the trigger for the readout.
    static func readout(window: Int?, reserved: Int) -> DSHCompactionThresholdBreakdown? {
        guard let window else { return nil }
        return policy().thresholdBreakdown(
            contextWindow: window,
            reservedCompletionTokens: reserved
        )
    }
}

// MARK: - View

struct DSHCompactionSettingsView: View {

    /// Percent form of the ratio, so the slider's own unit and the label match.
    @State private var triggerPercent: Double
    @State private var headroomText: String
    @State private var stepCapEnabled: Bool
    @State private var stepCapText: String

    /// The driver's per-request stamp, observed so this screen's readout follows a
    /// running turn instead of freezing at whatever the last presentation saw.
    /// Same wiring as `DSHContextPanel.breakdowns`: the store is main-actor and its
    /// `latest` is `@Published`, so an `@ObservedObject` reference is enough — the
    /// property wrapper subscribes on install, and any write to `latest` re-renders
    /// this body. `DSHContextPanel.swift:886` is the sibling use.
    @ObservedObject private var breakdowns = DSHContextBreakdownStore.shared

    /// Retained-tail ratio is DSH's (`0.16`) and is not editable; this is only
    /// here so the "Retained tail" row can state the budget in effect.
    private let reservedCompletionTokens = DSHTurnDriverConfig().maxTokens

    init() {
        let policy = DSHCompactionSettings.policy()
        _triggerPercent = State(initialValue: (policy.thresholdRatio * 100).rounded())
        _headroomText = State(initialValue: String(policy.headroomTokens))
        let limit = DSHCompactionSettings.stepLimitPerTurn
        _stepCapEnabled = State(initialValue: limit != nil)
        _stepCapText = State(initialValue: String(limit ?? 200))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Trigger percentage")
                        Spacer(minLength: 12)
                        Text("\(Int(triggerPercent))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $triggerPercent,
                        in: (DSHCompactionSettings.minThresholdRatio * 100)...100,
                        step: 5,
                        onEditingChanged: { editing in
                            if !editing { DSHCompactionSettings.store(triggerRatio: triggerPercent / 100) }
                        }
                    )
                }

                HStack {
                    Text("Headroom")
                    Spacer(minLength: 12)
                    // Persisted when the field is LEFT, not on every keystroke: a
                    // half-typed 50000 passes through 5, and a stored headroom of
                    // 5 would make every request trip the trigger.
                    TextField("tokens", text: $headroomText, onEditingChanged: { editing in
                        if !editing { writeHeadroom() }
                    })
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                    Text("tokens")
                        .foregroundStyle(.secondary)
                }

                Button("Reset to the DSH defaults") {
                    triggerPercent = (DSHCompactionSettings.shippedThresholdRatio * 100).rounded()
                    headroomText = String(DSHCompactionSettings.shippedHeadroomTokens)
                    DSHCompactionSettings.store(triggerRatio: DSHCompactionSettings.shippedThresholdRatio)
                    DSHCompactionSettings.store(headroomTokens: DSHCompactionSettings.shippedHeadroomTokens)
                }
            } header: {
                Text("Compaction Trigger")
            }

            Section {
                readout("Session model window", windowLabel)
                readout("Trigger in force", thresholdLabel)
                readout("By percentage", percentTermLabel)
                readout("By headroom", headroomTermLabel)
                readout("Binding", bindingLabel)
                readout("Retained tail", retainLabel)
            } header: {
                Text("Current Effect")
            }

            Section {
                Toggle("Limit steps per turn", isOn: $stepCapEnabled)
                    .onChange(of: stepCapEnabled) { _ in writeStepCap() }

                HStack {
                    Text("Steps")
                    Spacer(minLength: 12)
                    if stepCapEnabled {
                        TextField("steps", text: $stepCapText, onEditingChanged: { editing in
                            if !editing { writeStepCap() }
                        })
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 110)
                    } else {
                        // No cap means no number: showing the stored 200 while the toggle
                        // is off reads as "the cap is 200".
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Turn Steps")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Context Compaction")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Rows

    /// One label/value row. Both halves are `LocalizedStringKey`s: `Text(_:
    /// String)` does not consult the catalog, so a plain-`String` value renders
    /// English on a Chinese device — the same defect `DSHSpillSettingsView`
    /// carries a note about.
    private func readout(_ label: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .font(AppFont.sw(13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var breakdown: DSHCompactionThresholdBreakdown? {
        DSHCompactionSettings.readout(
            window: DSHCompactionSettings.sessionContextWindow,
            reserved: reservedCompletionTokens
        )
    }

    private var windowLabel: LocalizedStringKey {
        guard let window = DSHCompactionSettings.sessionContextWindow else { return "none routed" }
        return "\(DSHCompactionThresholdBreakdown.format(window)) tok"
    }

    private var thresholdLabel: LocalizedStringKey {
        guard let breakdown else { return "unresolvable for this route" }
        return "\(DSHCompactionThresholdBreakdown.format(breakdown.threshold)) tok"
    }

    private var percentTermLabel: LocalizedStringKey {
        guard let breakdown else { return "-" }
        return "\(DSHCompactionThresholdBreakdown.format(breakdown.windowFraction)) tok"
    }

    private var headroomTermLabel: LocalizedStringKey {
        guard let breakdown else { return "-" }
        return "\(DSHCompactionThresholdBreakdown.format(breakdown.headroomBound)) tok"
    }

    private var bindingLabel: LocalizedStringKey {
        guard let breakdown else { return "-" }
        return breakdown.binding == .headroom ? "headroom" : "percentage"
    }

    private var retainLabel: LocalizedStringKey {
        guard let window = DSHCompactionSettings.sessionContextWindow else { return "-" }
        guard let spec = try? DSHCompactionSettings.policy().resolveSpec(
            targetKey: "readout",
            contextWindow: window,
            reservedCompletionTokens: reservedCompletionTokens
        ) else { return "-" }
        return "\(DSHCompactionThresholdBreakdown.format(spec.retainTokens)) tok"
    }

    // MARK: - Write

    /// A field that does not parse is ignored rather than clamped to something
    /// surprising: the text stays as typed so the mistake is visible and the
    /// stored value keeps applying. Same rule as the spill screen.
    private func writeHeadroom() {
        guard let tokens = Int(headroomText.trimmingCharacters(in: .whitespaces)) else { return }
        DSHCompactionSettings.store(headroomTokens: tokens)
        headroomText = String(DSHCompactionSettings.headroomTokens)
    }

    private func writeStepCap() {
        guard stepCapEnabled else {
            DSHCompactionSettings.store(stepLimitPerTurn: nil)
            return
        }
        let typed = Int(stepCapText.trimmingCharacters(in: .whitespaces))
        DSHCompactionSettings.store(stepLimitPerTurn: typed ?? DSHCompactionSettings.maxStepLimit)
        stepCapText = String(DSHCompactionSettings.stepLimitPerTurn ?? 200)
    }
}
