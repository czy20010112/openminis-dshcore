//
//  DSHSpillSettingsView.swift
//  Minis
//
//  The switch for the tool-result spill, and the budget it runs on.
//
//  WHY THIS FILE SITS IN `src/ios/DSH/`
//  ---------------------------------------------------------------------------
//  `DSH/` is a `PBXFileSystemSynchronizedRootGroup` in Minis.xcodeproj, so a file
//  dropped here is compiled with no project edit — in both trees, whose pbxproj
//  files are not copies of each other. A settings screen would normally live
//  under `Views/Settings/`, but a new file there is not compiled until it is
//  added to the pbxproj by hand, twice.
//
//  WHY THERE IS A SWITCH AT ALL
//  ---------------------------------------------------------------------------
//  The policy in `DSHSpillConfig` follows DSH exactly: an absent budget means the
//  feature is inert, which is the right default and a bad diagnostic. Until this
//  screen existed there was no way to turn it on from the app, and a key written
//  to the plist from outside does not survive: the app registers its own defaults
//  at launch and rewrites the plist, so an external write is discarded. The
//  feature therefore had no reachable switch at all.
//
//  WHAT THE SWITCH DOES NOT DO
//  ---------------------------------------------------------------------------
//  It does not cache the budget. `DSHSpillFeature.config` re-reads the defaults on
//  every tool result and every turn re-reads them when it builds its hook, so a
//  change here takes effect on the very next tool call, with no relaunch — which
//  is the point of a switch that exists to be tried on a device.
//
//  NO EXPLANATION COPY
//  ---------------------------------------------------------------------------
//  The two section footers this screen started with explained what a spill is and
//  where the readout comes from. The operator removed that class of text from the
//  settings screens on 2026-10-17 ("很影响观看"), so the screen now shows the
//  controls and the live readout only. Rows may say what they are and what the
//  value currently is; a paragraph saying why is a comment, not a footer.
//

import SwiftUI

struct DSHSpillSettingsView: View {

    /// Off unless something is stored, or unless this build is a probe build.
    ///
    /// A probe build spills whether or not anything is stored, so the switch has
    /// to come up ON or the screen would contradict the behaviour in force.
    @State private var enabled: Bool
    @State private var tokensText: String
    @State private var daysText: String

    init() {
        let resolved = DSHSpillConfig.resolvedFromDefaults()
        _enabled = State(initialValue: DSHSpillConfig.probeEnabled || resolved != nil)
        _tokensText = State(initialValue: String(resolved?.maxInlineTokens ?? DSHSpillConfig.shippedMaxInlineTokens))
        _daysText = State(initialValue: String(resolved?.cleanupPeriodDays ?? 30))
    }

    var body: some View {
        List {
            Section {
                Toggle("Offload oversized tool results", isOn: $enabled)
                    .onChange(of: enabled) { _ in write() }

                HStack {
                    Text("Inline budget")
                    Spacer(minLength: 12)
                    // Persisted when the field is LEFT, not on every keystroke:
                    // typing "300" passes through "3" and "30", and a stored budget
                    // of 3 tokens would spill every tool result in the gap between
                    // two keystrokes. The readout below doubles as the confirmation
                    // that what is typed is what is in force.
                    TextField("tokens", text: $tokensText, onEditingChanged: { editing in
                        if !editing { write() }
                    })
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                    Text("tokens")
                        .foregroundStyle(.secondary)
                }
                .disabled(!enabled)

                HStack {
                    Text("Delete spill files after")
                    Spacer(minLength: 12)
                    TextField("days", text: $daysText, onEditingChanged: { editing in
                        if !editing { write() }
                    })
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                    Text("days")
                        .foregroundStyle(.secondary)
                }
                .disabled(!enabled)

                Button("Reset to the shipped budget") {
                    tokensText = String(DSHSpillConfig.shippedMaxInlineTokens)
                    daysText = "30"
                    write()
                }
                .disabled(!enabled)
            } header: {
                Text("Tool Result Spill")
            }

            Section {
                readout("State", storedState)
                readout("Budget in force", budgetState)
                readout("Images", "one retained image is charged \(DSHSpillConfig.defaultImageTokens) tokens")
                readout("Folder", LocalizedStringKey(DSHSpillStore.offloadsDisplayPath))
                readout("Never spilled", LocalizedStringKey(DSHSpill.exemptTools.sorted().joined(separator: ", ")))
            } header: {
                Text("Current Effect")
            }

            if DSHSpillConfig.probeEnabled {
                Section {
                    Text("This is a probe build: the budget above is forced and the stored setting is ignored. A probe build is never published.")
                        .font(AppFont.sw(13))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Probe")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tool Result Spill")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Rows

    /// One label/value row of the "current effect" readout.
    ///
    /// Both halves are `LocalizedStringKey`s rather than `String`s. They used to be
    /// plain strings, and `Text(_: String)` does NOT consult the catalog, so the
    /// whole readout stayed English on a Chinese device while every other row of
    /// the same screen localised. A value that is a path, a tool name or a number
    /// simply has no catalog entry and renders exactly as written.
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

    private var storedState: LocalizedStringKey {
        guard !DSHSpillConfig.probeEnabled else { return "forced on by the probe" }
        return enabled ? "on" : "off"
    }

    private var budgetState: LocalizedStringKey {
        guard let budget = DSHSpillConfig.resolvedFromDefaults()?.effectiveBudget else {
            return "off — nothing spills"
        }
        return "\(budget) tokens"
    }

    // MARK: - Write

    /// Persist what the switch and the two fields say.
    ///
    /// A field that does not parse is ignored rather than clamped to something
    /// surprising: the text stays as typed so the mistake is visible, and the
    /// value already stored keeps applying. Only when nothing is stored yet — the
    /// switch turned on with the field empty — does the shipped budget step in, so
    /// that turning the feature on always leaves a usable budget behind.
    private func write() {
        let tokens = Int(tokensText.trimmingCharacters(in: .whitespaces))
        let days = Int(daysText.trimmingCharacters(in: .whitespaces))
        let stored = DSHSpillConfig.resolvedFromDefaults()?.maxInlineTokens
        DSHSpillConfig.setEnabled(
            enabled,
            maxInlineTokens: tokens ?? stored ?? DSHSpillConfig.shippedMaxInlineTokens,
            cleanupPeriodDays: days
        )
    }
}
