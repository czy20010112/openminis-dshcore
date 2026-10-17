//
//  DSHWebSearchSettingsView.swift
//  Minis
//
//  The Web Search screen: the priority queue the `web_search` tool walks, and a
//  button that proves it works.
//
//  WHY THIS FILE SITS IN `src/ios/DSH/`
//  ---------------------------------------------------------------------------
//  `DSH/` is a `PBXFileSystemSynchronizedRootGroup`, so a file dropped here is
//  compiled with no project edit — in both trees, whose pbxproj files are not
//  copies of each other. A settings screen would normally live under
//  `Views/Settings/`, but a new file there is not compiled until it is added to
//  the pbxproj by hand, twice.
//
//  THE QUEUE IS THE FORM, ONE ENTRY PER BUBBLE
//  ---------------------------------------------------------------------------
//  Every bubble IS an entry of `DSHWebSearchConfig.entries`: switch it off, rename
//  it, change its provider, its key, its endpoint, move it up or down, delete it.
//  Order on screen is priority order — the tool tries the first bubble first. The
//  same provider may appear in several bubbles, each with its own key and endpoint.
//
//  Each entry is its OWN `Section`. That is what makes the bubble: the system
//  draws one card per section, and inside it one hairline separator per row. The
//  fields are one row EACH (label left, value right, one font and one weight on
//  every row) rather than a `VStack` of controls inside a single row — a stacked
//  block draws no separators and no two rows line up. The row shape is the one
//  the Background permissions screen uses
//  (`Views/Settings/EnhancedBackgroundSettingsView.swift`, `statusRow`).
//
//  THE SHIPPED DEFAULT IS AN EMPTY QUEUE
//  ---------------------------------------------------------------------------
//  No entry ships enabled, and none ships at all: a search key is the user's, so
//  shipping a row that says `needs a key` would open the screen on a problem the
//  app created. The screen therefore starts with just "Add Search Entry", the
//  clear button returns to that state, and an empty queue is what `web_search`
//  reports when it is called with nothing configured.
//
//  WHY THE "TEST SEARCH" BUTTON IS THE POINT OF THE SCREEN
//  ---------------------------------------------------------------------------
//  A search backend fails in ways a form cannot show: a key that is valid for
//  everything except search, an endpoint whose path is one segment off, a
//  provider that answers 200 with an empty array. All three look identical in the
//  settings UI and identical in a chat transcript. So the button runs the real
//  queue — fallback and all — against a fixed query and reduces the run to a
//  verdict beside it: a green check when something came back, a red exclamation
//  when nothing did. The text behind that verdict — the source line, and the raw
//  error the model would see — is not laid out under the form; it opens in a sheet
//  when the verdict is tapped.
//

import SwiftUI

struct DSHWebSearchSettingsView: View {

    @StateObject private var store = DSHWebSearchStore()

    // MARK: - Test search state

    @State private var testRunning = false
    /// The probe's text, kept so the verdict's sheet can show it. Nothing on this
    /// screen renders these lines directly any more.
    @State private var testLines: [String] = []
    @State private var testFailed = false
    /// The sheet the verdict opens. The result is on demand, never on the screen.
    @State private var showTestResult = false

    /// The entries whose key field is currently revealed. Masked is the state a
    /// paste leaves the field in; the eye reveals one row at a time.
    @State private var revealedKeys: Set<String> = []

    /// The probe query. The operator's own reproduction: a question whose answer
    /// is only knowable by searching, so a working engine returns current model
    /// names and a broken one returns nothing.
    private static let testQuery = "deepseek最新的模型是什么"

    var body: some View {
        List {
            entrySections
            testSection
            clearSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Web Search")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTestResult) {
            testResultSheet
        }
    }

    // MARK: - Entries

    /// One bubble per entry, then the button that makes another one.
    @ViewBuilder
    private var entrySections: some View {
        ForEach($store.entries) { $entry in
            entrySection($entry)
        }

        Section {
            Button {
                store.addEntry()
            } label: {
                Label("Add Search Entry", systemImage: "plus.circle.fill")
            }
        }
    }

    /// One entry as its own group, with where it sits in the queue as its header —
    /// the order IS the priority the tool walks.
    private func entrySection(_ entry: Binding<DSHWebSearchEntry>) -> some View {
        let value = entry.wrappedValue
        let index = store.entries.firstIndex(where: { $0.id == value.id }) ?? 0
        return Section {
            entryRows(entry)
        } header: {
            Text("Search Entry \(index + 1)")
        }
    }

    /// The rows of one bubble: one field per row, so the section's own separators
    /// fall between them. Every row is the same shape — label left, value right,
    /// the same font and the same weight — which is what makes the fields read as
    /// a list instead of a stack of unrelated controls.
    private func entryRows(_ entry: Binding<DSHWebSearchEntry>) -> some View {
        let value = entry.wrappedValue
        let index = store.entries.firstIndex(where: { $0.id == value.id }) ?? 0
        let revealed = revealedKeys.contains(value.id)
        return Group {
            Toggle(isOn: entry.enabled) {
                HStack(spacing: 8) {
                    Text(verbatim: value.title)
                    if let status = value.status {
                        // A state, not a sentence: `needs a key` is a catalog key,
                        // and `String` only reaches the catalog through
                        // `LocalizedStringKey`.
                        Text(LocalizedStringKey(status))
                            .font(AppFont.sw(12, category: .ui))
                            .foregroundStyle(.red)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                // `Search provider`, not `Provider`: the latter is the LLM-vendor
                // label ("AI 服务商"), which is wrong for a search backend.
                Text("Search provider")
                Spacer(minLength: 12)
                Picker("Provider", selection: entry.provider) {
                    ForEach(DSHWebSearchProvider.allCases) { provider in
                        Text(verbatim: provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            field("Name", text: entry.label, prompt: "")

            // The key, masked, with the eye that reveals it. Kept in its own
            // builder because the masked/unmasked pair is two controls, and the
            // plain `field` row above is one.
            keyRow(entry, revealed: revealed)

            field(
                "Endpoint",
                text: entry.endpoint,
                prompt: value.provider.defaultBase,
                keyboard: .URL
            )

            HStack(spacing: 22) {
                Button {
                    store.moveUp(value.id)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)

                Button {
                    store.moveDown(value.id)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(index >= store.entries.count - 1)

                Spacer(minLength: 12)

                Button {
                    store.remove(value.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
            .font(AppFont.sw(13, category: .ui))
        }
    }

    /// A labelled field on its own row. The label is a catalog key; the placeholder
    /// is a value (a key shape, or the provider's default endpoint) and is rendered
    /// verbatim. The value's face — code, regular weight, trailing — is the one the
    /// provider screens use for the same kind of text
    /// (`Views/Providers/ProviderInstanceDetailView.swift`, the model-id row).
    private func field(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        prompt: String,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            TextField(prompt, text: text)
                .font(AppFont.sw(17, weight: .regular, category: .code))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
        }
    }

    /// The key row: a `SecureField`, so a paste lands in a field that draws only
    /// bullets, and the eye swaps it for a plain field when the user wants to read
    /// or fix what is in there. This is the credential row of the provider screens
    /// (`Views/Providers/AddProviderView.swift`, `apiKeySection`), down to
    /// `.textContentType(.oneTimeCode)`: an undeclared secure field makes iOS treat
    /// the form as a login form and hang a password AutoFill bar on the nearest
    /// preceding text field, which on this screen is the entry's Name row.
    private func keyRow(_ entry: Binding<DSHWebSearchEntry>, revealed: Bool) -> some View {
        let id = entry.wrappedValue.id
        return HStack(alignment: .firstTextBaseline) {
            Text("API Key")
            Spacer(minLength: 12)

            if revealed {
                TextField("sk-…", text: entry.apiKey)
                    .font(AppFont.sw(17, weight: .regular, category: .code))
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            } else {
                SecureField("sk-…", text: entry.apiKey)
                    .font(AppFont.sw(17, weight: .regular, category: .code))
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.trailing)
            }

            Button {
                if revealed {
                    revealedKeys.remove(id)
                } else {
                    revealedKeys.insert(id)
                }
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(revealed
                                     ? LocalizedStringKey("Hide")
                                     : LocalizedStringKey("Show")))
        }
    }

    // MARK: - Test

    /// One row: the button that runs the probe, and the verdict on its right. The
    /// result is a second tap away, so the form stays the form.
    private var testSection: some View {
        Section {
            HStack {
                Button {
                    runTest()
                } label: {
                    // Both branches spell out LocalizedStringKey: a plain ternary of
                    // two literals is inferred as String, and `Text(String)` does not
                    // consult the catalog, so the title would stay English in Chinese.
                    Text(testRunning
                         ? LocalizedStringKey("Testing…")
                         : LocalizedStringKey("Test Search"))
                        // The label fills the row, so the whole free width is the
                        // button — a tap to the right of the words runs the probe
                        // instead of doing nothing.
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .disabled(testRunning)

                if testRunning {
                    ProgressView()
                } else if let succeeded = testVerdict {
                    // Tap the verdict for the run's text. Nothing else on this
                    // screen shows it, so the row is quiet until it is asked.
                    Button {
                        showTestResult = true
                    } label: {
                        Image(systemName: succeeded
                              ? "checkmark.circle.fill"
                              : "exclamationmark.circle.fill")
                            .foregroundStyle(succeeded ? Color.green : Color.red)
                            .frame(minWidth: 24, minHeight: 24)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(succeeded
                                             ? LocalizedStringKey("Test succeeded")
                                             : LocalizedStringKey("Test failed")))
                }
            }
        }
    }

    /// What the test row shows: nothing before the probe has run, then whether it
    /// came back with something.
    private var testVerdict: Bool? {
        guard !testRunning, !testLines.isEmpty else { return nil }
        return !testFailed
    }

    /// The probe's output, in the sheet the verdict opens: the source line first,
    /// then the raw text the model would have read, with a copy button per line so
    /// a rejected key can be reported without retyping it.
    private var testResultSheet: some View {
        CompatNavigationStack {
            List {
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
            .navigationTitle("Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showTestResult = false
                    }
                }
            }
        }
        .compatDetents([.medium, .large])
    }

    // MARK: - Clear

    /// Clearing IS the reset: the shipped default holds no entries, so there is no
    /// key or endpoint the app could put back that the user did not type.
    private var clearSection: some View {
        Section {
            Button("Clear Search Entries", role: .destructive) {
                store.clear()
                testLines = []
                testFailed = false
            }
            .disabled(store.entries.isEmpty)
        }
    }

    // MARK: - Test search

    private func runTest() {
        testRunning = true
        testFailed = false
        testLines = [AppLocalized("Searching…")]
        let query = Self.testQuery
        Task {
            let outcome = await DSHWebSearchTool.run(args: ["query": query, "limit": 3])
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

/// The queue the screen edits, and the write-through to `UserDefaults`.
///
/// One stored value holds the whole queue, so every edit persists the array as
/// it stands rather than tracking which field of which row was touched. Order is
/// the array's order, which is the priority order the tool walks.
@MainActor
final class DSHWebSearchStore: ObservableObject {

    @Published var entries: [DSHWebSearchEntry] {
        didSet { DSHWebSearchConfig.setEntries(entries) }
    }

    init() {
        entries = DSHWebSearchConfig.entries
    }

    // MARK: Editing

    func addEntry() {
        entries.append(DSHWebSearchEntry())
    }

    func remove(_ id: DSHWebSearchEntry.ID) {
        entries.removeAll { $0.id == id }
    }

    /// Step one entry past its neighbour. The row's arrow buttons move it a place,
    /// which is the whole reorder gesture this screen has: the entries are one
    /// section each, so the list cannot offer a drag handle that spans them.
    func moveUp(_ id: DSHWebSearchEntry.ID) { step(id, by: -1) }

    func moveDown(_ id: DSHWebSearchEntry.ID) { step(id, by: 1) }

    private func step(_ id: DSHWebSearchEntry.ID, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
    }

    /// Empty the queue — the shipped default, restored.
    func clear() {
        DSHWebSearchConfig.resetToDefaults()
        entries = DSHWebSearchConfig.entries
    }
}
