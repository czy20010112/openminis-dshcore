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
                    TextField("tokens", text: $tokensText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        .onChange(of: tokensText) { _ in write() }
                    Text("tokens")
                        .foregroundStyle(.secondary)
                }
                .disabled(!enabled)

                HStack {
                    Text("Delete spill files after")
                    Spacer(minLength: 12)
                    TextField("days", text: $daysText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        .onChange(of: daysText) { _ in write() }
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
            } footer: {
                Text("A tool result larger than the inline budget is written to disk in full and replaced, in the conversation, by a short notice naming the file. The model then reads it back with `file_read`. This is DSH's own behaviour on the host; the budget here is the same one it ships with.")
                    .font(AppFont.sw(12))
            }

            Section {
                readout("State", storedState)
                readout("Budget in force", budgetState)
                readout("Images", "one retained image is charged \(DSHSpillConfig.defaultImageTokens) tokens")
                readout("Folder", DSHSpillStore.offloadsDisplayPath)
                readout("Never spilled", DSHSpill.exemptTools.sorted().joined(separator: ", "))
            } header: {
                Text("Current Effect")
            } footer: {
                Text("Read from the settings the app will actually use, not from the switch above — the two differ whenever a probe build is in force.")
                    .font(AppFont.sw(12))
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

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .font(AppFont.sw(13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var storedState: String {
        guard !DSHSpillConfig.probeEnabled else { return "forced on by the probe" }
        return enabled ? "on" : "off"
    }

    private var budgetState: String {
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
    /// last good value keeps applying.
    private func write() {
        let tokens = Int(tokensText.trimmingCharacters(in: .whitespaces))
        let days = Int(daysText.trimmingCharacters(in: .whitespaces))
        DSHSpillConfig.setEnabled(
            enabled,
            maxInlineTokens: tokens ?? DSHSpillConfig.shippedMaxInlineTokens,
            cleanupPeriodDays: days
        )
    }
}
