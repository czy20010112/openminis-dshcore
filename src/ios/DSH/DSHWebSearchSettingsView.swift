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
//  THE QUEUE IS THE FORM
//  ---------------------------------------------------------------------------
//  Every row IS an entry of `DSHWebSearchConfig.entries`: switch it off, rename
//  it, change its provider, its key, its endpoint, move it up or down, delete it.
//  Order on screen is priority order — the tool tries row 1 first. The same
//  provider may appear in several rows, each with its own key and endpoint.
//
//  WHY THE "TEST SEARCH" BUTTON IS THE POINT OF THE SCREEN
//  ---------------------------------------------------------------------------
//  A search backend fails in ways a form cannot show: a key that is valid for
//  everything except search, an endpoint whose path is one segment off, a
//  provider that answers 200 with an empty array. All three look identical in the
//  settings UI and identical in a chat transcript. So the button runs the real
//  queue — fallback and all — against a fixed query, and prints what came back,
//  including the raw error text the model would see.
//

import SwiftUI

struct DSHWebSearchSettingsView: View {

    @StateObject private var store = DSHWebSearchStore()

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
            entriesSection
            testSection
            resetSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Web Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Drag to reorder, and the red delete circles, both live in edit
            // mode. The row buttons below do the same two things without it.
            EditButton()
        }
    }

    // MARK: - Entries

    private var entriesSection: some View {
        Section {
            ForEach($store.entries) { $entry in
                entryRow($entry)
            }
            .onMove { source, destination in
                store.move(from: source, to: destination)
            }
            .onDelete { offsets in
                store.delete(at: offsets)
            }

            Button {
                store.addEntry()
            } label: {
                Label("Add Search Entry", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Search Entries")
        }
    }

    /// One row of the queue: the whole entry, editable in place.
    private func entryRow(_ entry: Binding<DSHWebSearchEntry>) -> some View {
        let value = entry.wrappedValue
        let index = store.entries.firstIndex(where: { $0.id == value.id }) ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: entry.enabled) {
                HStack(spacing: 8) {
                    Text(verbatim: value.title)
                        .font(AppFont.sw(14, category: .ui))
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
                Text("Provider")
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
            field("API Key", text: entry.apiKey, prompt: "sk-…")
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
        .padding(.vertical, 4)
    }

    /// A labelled field on its own line. The label is a catalog key; the
    /// placeholder is a value (a key shape, or the provider's default endpoint)
    /// and is rendered verbatim.
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
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .font(AppFont.sw(13, category: .code))
        }
    }

    // MARK: - Test

    private var testSection: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack {
                    // Both branches spell out LocalizedStringKey: a plain ternary of
                    // two literals is inferred as String, and `Text(String)` does not
                    // consult the catalog, so the title would stay English in Chinese.
                    Text(testRunning
                         ? LocalizedStringKey("Testing…")
                         : LocalizedStringKey("Test Search"))
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
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button("Reset to the shipped defaults") {
                store.resetToDefaults()
                testLines = []
                testFailed = false
            }
            .foregroundStyle(.red)
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

    func delete(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
    }

    func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
    }

    /// Step one entry past its neighbour. The row buttons move it a place; the
    /// drag handles in edit mode move it anywhere.
    func moveUp(_ id: DSHWebSearchEntry.ID) { step(id, by: -1) }

    func moveDown(_ id: DSHWebSearchEntry.ID) { step(id, by: 1) }

    private func step(_ id: DSHWebSearchEntry.ID, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
    }

    func resetToDefaults() {
        DSHWebSearchConfig.resetToDefaults()
        entries = DSHWebSearchConfig.entries
    }
}
