//
//  DSHWebSearchSettingsView.swift
//  Minis
//
//  The Web Search screen: which backend the `web_search` tool uses, its key, its
//  endpoint, and a button that proves it works.
//
//  WHY THIS FILE SITS IN `src/ios/DSH/`
//  ---------------------------------------------------------------------------
//  `DSH/` is a `PBXFileSystemSynchronizedRootGroup`, so a file dropped here is
//  compiled with no project edit — in both trees, whose pbxproj files are not
//  copies of each other. A settings screen would normally live under
//  `Views/Settings/`, but a new file there is not compiled until it is added to
//  the pbxproj by hand, twice.
//
//  WHY THE "TEST SEARCH" BUTTON IS THE POINT OF THE SCREEN
//  ---------------------------------------------------------------------------
//  A search backend fails in ways a form cannot show: a key that is valid for
//  everything except search, an endpoint whose path is one segment off (Tavily's
//  proxy is `/tavily/search`, not `/search`), a provider that answers 200 with an
//  empty array. All three look identical in the settings UI and identical in a
//  chat transcript. So the screen runs the real code path against a fixed query
//  and prints what came back, including the raw error text the model would see.
//
//  WHAT THE READOUT SHOWS
//  ---------------------------------------------------------------------------
//  The "In force" section reads through `DSHWebSearchProvider.effectiveKey()` and
//  `effectiveBase()` — the same accessors the tool uses — not from the fields
//  above. The two differ exactly when a value is stored from an earlier session
//  or the operator default is filling in, which is the state a user cannot infer
//  from the form.
//

import SwiftUI

struct DSHWebSearchSettingsView: View {

    @StateObject private var store = DSHWebSearchStore()

    /// The provider the form's fields belong to. `onChange` runs after the bound
    /// value has changed, so the outgoing provider is held here instead.
    @State private var formProvider: DSHWebSearchProvider = DSHWebSearchConfig.provider

    // MARK: - Test search state

    @State private var testRunning = false
    @State private var testLines: [String] = []
    @State private var testFailed = false

    /// The probe query. The operator's own reproduction: a novel whose author
    /// and title are both distinctive, so a working engine returns the novel and
    /// a broken one returns nothing.
    private static let testQuery = "泯冬 召唤魅魔 小说"

    var body: some View {
        List {
            providerSection
            credentialsSection
            testSection
            inForceSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Web Search")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Provider

    private var providerSection: some View {
        Section {
            Picker("Search provider", selection: $store.provider) {
                ForEach(DSHWebSearchProvider.allCases) { provider in
                    Text(verbatim: provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: store.provider) { newValue in
                store.providerChanged(to: newValue, from: formProvider)
                formProvider = newValue
            }
            Text(LocalizedStringKey(store.provider.summary))
                .font(AppFont.sw(12, category: .ui))
                .foregroundStyle(.secondary)

            Text(LocalizedStringKey(store.provider.needsKey
                ? "This provider needs an API key from its own website. Jina and a self-hosted SearXNG do not."
                : "This provider works without an API key."))
                .font(AppFont.sw(12, category: .ui))
                .foregroundStyle(.secondary)
        } header: {
            Text("Provider")
        }
    }

    // MARK: - Key and endpoint

    private var credentialsSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text("API Key")
                Spacer(minLength: 12)
                TextField("sk-…", text: $store.apiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .multilineTextAlignment(.trailing)
                    .font(AppFont.sw(13, category: .code))
                    .onChange(of: store.apiKey) { newValue in
                        store.keyChanged(newValue)
                    }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Endpoint")
                Spacer(minLength: 12)
                TextField("Provider default", text: $store.endpointText)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
                    .font(AppFont.sw(13, category: .code))
                    .onChange(of: store.endpointText) { newValue in
                        store.endpointChanged(newValue)
                    }
            }


            Button("Reset to the shipped defaults") {
                store.resetToDefaults()
                formProvider = store.provider
                testLines = []
                testFailed = false
            }
            .foregroundStyle(.red)
        } header: {
            Text("Credentials")
        } footer: {
            Text("The key is sent only to the endpoint above. Leave the endpoint empty to use the provider's own default. The snippets the search returns are placed in the conversation, so the provider you choose sees your query.")
        }
    }

    // MARK: - Test

    private var testSection: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack {
                    Text(testRunning ? "Testing…" : "Test Search")
                    if testRunning {
                        Spacer(minLength: 8)
                        ProgressView()
                    }
                }
            }
            .disabled(testRunning)

            if !testLines.isEmpty {
                ForEach(Array(testLines.enumerated()), id: \.offset) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: item.element)
                            .font(AppFont.sw(12, category: item.offset == 0 ? .ui : .body))
                            .foregroundStyle(testFailed && item.offset == 0 ? .red : .primary)
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button {
                            UIPasteboard.general.string = item.element
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Copy"))
                    }
                }
            }
        } header: {
            Text("Results")
        } footer: {
            Text("Runs a real search through the settings above and prints the hits, or the exact error the tool would have handed the model. Nothing is added to the conversation.")
        }
    }

    // MARK: - In force

    private var inForceSection: some View {
        Section {
            readout("Search provider", LocalizedStringKey(store.provider.displayName))
            readout("State", LocalizedStringKey(store.keyState))
            readout("Endpoint", LocalizedStringKey(store.effectiveBase.isEmpty
                ? "Not set"
                : store.effectiveBase))
            readout("Search tool", "web_search")
            readout("Results per search", LocalizedStringKey("up to \(DSHWebSearchConfig.maxLimit)"))
            readout("Request timeout", LocalizedStringKey("\(Int(DSHWebSearchTransport.timeout)) seconds"))
        } header: {
            Text("Current Effect")
        } footer: {
            Text("Read from what the tool will actually use, not from the fields above — the two differ whenever a value was stored earlier or a shipped default is filling in.")
        }
    }

    // MARK: - Rows

    /// One label/value row. Both halves are `LocalizedStringKey`s: `Text(_: String)`
    /// does not consult the catalog, so a `String` value would render English on
    /// a Chinese device while the rest of the row translated. A value that is a
    /// URL, a tool name or a number simply has no catalog entry and renders as
    /// written.
    private func readout(_ label: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        HStack(alignment: .top) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .font(AppFont.sw(13, category: .ui))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    // MARK: - Test search

    private func runTest() {
        testRunning = true
        testFailed = false
        testLines = [AppLocalized("Searching…")]
        let provider = store.provider
        let query = Self.testQuery
        Task {
            let outcome = await DSHWebSearchTool.run(
                args: ["query": query, "limit": 3],
                provider: provider
            )
            let lines = outcome.output
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            testLines = lines.isEmpty ? [outcome.output] : lines
            testFailed = !outcome.success
            testRunning = false
        }
    }
}

// MARK: - Store

/// The settings the screen edits, and the write-through to `UserDefaults`.
///
/// The key and the endpoint are stored PER PROVIDER, so the picker has to save
/// the outgoing provider's values and load the incoming one's. That is a
/// sequence, not a binding, so persistence is explicit: the three `@Published`
/// fields hold what is on screen, and `providerChanged` / `keyChanged` /
/// `endpointChanged` are the only writers. Persisting from a `didSet` instead
/// made loading a provider's saved values write them straight back, and made the
/// order of two `didSet`s decide what ended up stored.
@MainActor
final class DSHWebSearchStore: ObservableObject {

    @Published var provider: DSHWebSearchProvider
    @Published var apiKey: String = ""
    @Published var endpointText: String = ""

    /// Mirrors of what `DSHWebSearchConfig` resolves, so the readout does not
    /// have to be recomputed mid-render.
    @Published private(set) var effectiveBase: String = ""
    @Published private(set) var keyState: String = ""
    @Published private(set) var hasStoredKey: Bool = false

    init() {
        let configured = DSHWebSearchConfig.provider
        provider = configured
        let storedKey = DSHWebSearchConfig.apiKey(for: configured)
        let storedEndpoint = DSHWebSearchConfig.endpointOverride(for: configured)
        apiKey = storedKey
        endpointText = storedEndpoint
        refreshReadout()
    }

    // MARK: Writing

    /// Persist what is on screen under the provider it belongs to, record the new
    /// selection, then show the new provider's own stored values.
    ///
    /// `outgoing` is passed in rather than read from a captured `oldValue`: the
    /// key being saved belongs to the provider that was selected when the user
    /// typed it, and that is not recoverable once `provider` has moved.
    func providerChanged(to provider: DSHWebSearchProvider, from outgoing: DSHWebSearchProvider) {
        guard provider != outgoing else { return }
        DSHWebSearchConfig.setAPIKey(apiKey, for: outgoing)
        DSHWebSearchConfig.setEndpointOverride(endpointText, for: outgoing)
        DSHWebSearchConfig.provider = provider
        apiKey = DSHWebSearchConfig.apiKey(for: provider)
        endpointText = DSHWebSearchConfig.endpointOverride(for: provider)
        refreshReadout()
    }

    func keyChanged(_ value: String) {
        DSHWebSearchConfig.setAPIKey(value, for: provider)
        refreshReadout()
    }

    /// Persist the endpoint override and refresh the readout. The refresh matters
    /// on clearing the field: that is the transition from an override back to the
    /// provider's default, and the readout would otherwise keep showing the old
    /// endpoint until the screen was reopened.
    func endpointChanged(_ value: String) {
        DSHWebSearchConfig.setEndpointOverride(value, for: provider)
        refreshReadout()
    }

    func resetToDefaults() {
        DSHWebSearchConfig.resetToDefaults()
        let restored = DSHWebSearchConfig.provider
        provider = restored
        apiKey = DSHWebSearchConfig.apiKey(for: restored)
        endpointText = DSHWebSearchConfig.endpointOverride(for: restored)
        refreshReadout()
    }

    private func refreshReadout() {
        let resolved = provider
        effectiveBase = resolved.effectiveBase()
        hasStoredKey = !DSHWebSearchConfig.apiKey(for: resolved).isEmpty
        if !resolved.needsKey {
            keyState = "no key needed"
        } else if resolved.effectiveKey().isEmpty {
            keyState = "needs a key"
        } else {
            keyState = "your own key"
        }
    }
}
