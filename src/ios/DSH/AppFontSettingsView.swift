//
//  AppFontSettingsView.swift
//  Minis
//
//  The 字体设置 screen: the library of faces, and the per-category choice.
//
//  WHY THIS FILE SITS IN `src/ios/DSH/`
//  ---------------------------------------------------------------------------
//  `DSH/` is a `PBXFileSystemSynchronizedRootGroup` in Minis.xcodeproj, so a file
//  dropped here is compiled with no project edit — in both trees, whose pbxproj
//  files are not copies of each other. A settings screen would normally live
//  under `Views/Settings/`, but a new file there is not compiled until it is
//  added to the pbxproj by hand, twice.
//
//  WHY THE LIBRARY IS TWO LISTS
//  ---------------------------------------------------------------------------
//  Built-in faces come from the bundle and are always there; imported ones are
//  files the user picked, and they can be deleted. One list with a delete swipe
//  only on half its rows reads as a bug, so the two are separate sections, and
//  the importer sits with the imported ones.
//
//  WHY EACH CATEGORY ASKS FOR TWO FACES
//  ---------------------------------------------------------------------------
//  A Latin serif has no CJK glyphs, and a Song face's own Latin is a full-width
//  design nobody wants for English — so every category needs a Latin face and a
//  Chinese face, which is also what the reference stack does. See
//  `AppFontStore`'s header.
//
//  LOCALISATION
//  ---------------------------------------------------------------------------
//  Every string in this screen is an English literal inside `Text("…")`, which
//  is the key form `Localizable.xcstrings` extracts. The category copy is
//  written as a literal `switch` rather than built from a stored string for the
//  same reason: a computed string is not a catalog key. Font names (Lora,
//  方正宋三简体) are proper nouns and are rendered `verbatim`, deliberately.
//

import SwiftUI
import UniformTypeIdentifiers

struct AppFontSettingsView: View {

    /// Bumped after an import or a delete so the lists below re-read
    /// `AppFontLibrary.faces`, which is not itself observable.
    @State private var libraryVersion = 0
    @State private var showImporter = false
    @State private var alertMessage = ""
    @State private var showAlert = false

    @ObservedObject private var store = AppFontStore.shared

    var body: some View {
        List {
            librarySection
            importedSection
            globalSection
            ForEach(AppFontCategory.allCases) { category in
                categorySection(category)
            }
        }
        .listStyle(.insetGrouped)
        // Re-keying on the import counter is what makes the library list re-read
        // `AppFontLibrary.faces`, which is a plain registry rather than an
        // observable. It only moves on an import or a delete, so the cost is a
        // list rebuild exactly when the list content actually changed.
        .id(libraryVersion)
        .navigationTitle("Font Settings")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: allowedTypes,
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .alert("Font import", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(verbatim: alertMessage)
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        Section {
            ForEach(AppFontLibrary.builtInFaces) { face in
                faceRow(face)
            }
        } header: {
            Text("Font Library")
        } footer: {
            Text("Faces the app ships with. Latin faces carry the weight; a Chinese face is used for every character a Latin face cannot draw, which is the whole of Chinese.")
        }
    }

    private func faceRow(_ face: AppFontFace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: face.displayName)
                Spacer(minLength: 8)
                Text(verbatim: scriptLabel(face))
                    .font(AppFont.sw(12, category: .ui))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: face.provenance)
                .font(AppFont.sw(11, category: .ui))
                .foregroundStyle(.secondary)
            if !face.hasWeightVariants && !face.isSystem {
                Text("One weight only — see the note under each category.")
                    .font(AppFont.sw(11, category: .ui))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func scriptLabel(_ face: AppFontFace) -> String {
        if face.isSystem { return "Latin + Chinese" }
        var parts: [String] = []
        if face.scripts.contains(.latin) { parts.append("Latin") }
        if face.scripts.contains(.cjk) { parts.append("Chinese") }
        return parts.joined(separator: " + ")
    }

    // MARK: - Imported

    private var importedSection: some View {
        Section {
            let imported = AppFontLibrary.importedFaces
            if imported.isEmpty {
                Text("No imported fonts yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(imported) { face in
                    faceRow(face)
                }
                .onDelete { offsets in
                    delete(offsets, from: imported)
                }
            }
            Button {
                showImporter = true
            } label: {
                Label("Import Font from Files", systemImage: "plus.circle")
            }
        } header: {
            Text("Imported")
        } footer: {
            Text("Pick a .ttf, .otf or .ttc from the Files app. The file is copied into the app's own storage and registered for this process at every launch, so it stays available until you delete it here. Redistribution of an imported face is your responsibility — check its licence before sharing a build.")
        }
    }

    private func delete(_ offsets: IndexSet, from imported: [AppFontFace]) {
        for index in offsets {
            guard imported.indices.contains(index) else { continue }
            do {
                try AppFontLibrary.deleteImportedFace(id: imported[index].id)
            } catch {
                report("\(imported[index].displayName): \(error.localizedDescription)")
            }
        }
        // A deleted face may still be selected somewhere; put those categories
        // back on their shipped defaults rather than leaving a stack that
        // silently falls back at every draw.
        AppFontStore.shared.repairSelections()
        libraryVersion += 1
    }

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.font]
        if let ttf = UTType(filenameExtension: "ttf") { types.append(ttf) }
        if let otf = UTType(filenameExtension: "otf") { types.append(otf) }
        if let ttc = UTType(filenameExtension: "ttc") { types.append(ttc) }
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            report(error.localizedDescription)
        case .success(let urls):
            var added: [String] = []
            var notes: [String] = []
            for url in urls {
                do {
                    added.append(contentsOf: try AppFontLibrary.importFont(from: url).map { $0.displayName })
                } catch AppFontImportError.alreadyPresent(let name) {
                    notes.append("Already in the library: \(name).")
                } catch {
                    notes.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !added.isEmpty {
                notes.insert("Added: \(added.joined(separator: ", ")).", at: 0)
                libraryVersion += 1
            }
            report(notes.joined(separator: "\n"))
        }
    }

    private func report(_ message: String) {
        guard !message.isEmpty else { return }
        alertMessage = message
        showAlert = true
    }

    // MARK: - Global

    private var globalSection: some View {
        Section {
            Toggle("Use this stack as the app's default text font", isOn: Binding(
                get: { store.takeOverAppText },
                set: { store.takeOverAppText = $0 }
            ))
            Toggle("Let a single-weight Chinese face borrow weight", isOn: Binding(
                get: { store.lendsCJKWeight },
                set: { store.lendsCJKWeight = $0 }
            ))
            Button("Reset to the shipped defaults") {
                store.resetToDefaults()
                libraryVersion += 1
            }
        } header: {
            Text("Global")
        } footer: {
            Text("The first switch is what makes this the app's default: with it on, text that never asked for a font inherits the Body face above. The second switch is about Chinese weight — 方正宋三简体 has one face and iOS does not synthesise bold for a custom font, so with it on a heavier Chinese request is served by 思源宋体 with 方正宋三简体 kept directly behind it for coverage.")
        }
    }

    // MARK: - Category

    private func categorySection(_ category: AppFontCategory) -> some View {
        let selection = store.selection(for: category)
        let resolved = AppFont.resolvedNames(for: category)
        return Section {
            Text(verbatim: specimen)
                .font(Font(AppFont.ui(17, weight: selection.cjkWeight.uiWeight, category: category)))
                .padding(.vertical, 2)

            Picker("Latin face", selection: binding(category).latinFaceId) {
                ForEach(latinFaces) { face in
                    Text(verbatim: face.displayName).tag(face.id)
                }
            }
            Picker("Latin weight", selection: binding(category).latinWeight) {
                ForEach(AppFontLibrary.face(id: selection.latinFaceId)?.availableWeights ?? AppFontWeight.allCases) { weight in
                    Text(verbatim: weight.subfamily).tag(weight)
                }
            }
            Picker("Chinese face", selection: binding(category).cjkFaceId) {
                ForEach(cjkFaces) { face in
                    Text(verbatim: face.displayName).tag(face.id)
                }
            }
            Picker("Chinese weight", selection: binding(category).cjkWeight) {
                ForEach(AppFontLibrary.face(id: selection.cjkFaceId)?.availableWeights ?? AppFontWeight.allCases) { weight in
                    Text(verbatim: weight.subfamily).tag(weight)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Resolves to")
                Spacer(minLength: 12)
                Text(verbatim: "\(resolved.latin) + \(resolved.cjk)" + (resolved.note.map { " (\($0))" } ?? ""))
                    .font(AppFont.sw(12, category: .ui))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            categoryHeader(category)
        } footer: {
            categoryFooter(category)
        }
    }

    @ViewBuilder
    private func categoryHeader(_ category: AppFontCategory) -> some View {
        switch category {
        case .title: Text("Titles")
        case .body: Text("Body Text")
        case .code: Text("Code")
        case .ui: Text("UI Chrome")
        }
    }

    @ViewBuilder
    private func categoryFooter(_ category: AppFontCategory) -> some View {
        switch category {
        case .title:
            Text("Markdown headings and the app's own large titles.")
        case .body:
            Text("Chat messages, the composer and every settings row that does not ask for another category.")
        case .code:
            Text("Fenced code blocks and inline code spans. Chinese inside code is drawn by the Chinese face too, which is what keeps a code block's own alignment intact.")
        case .ui:
            Text("Navigation bars, bar buttons, tab bar items, segmented controls and plain UIKit labels. UIKit reads some of these when it builds a view, so a change may need a restart to reach chrome that was already on screen.")
        }
    }

    /// The specimen is intentionally not localised: it is a type sample, and a
    /// translated one would stop testing the faces it is there to show.
    private var specimen: String {
        "永和九年 Handgloves 0123456789 — 岁在癸丑"
    }

    // MARK: - Selection plumbing

    private var latinFaces: [AppFontFace] {
        AppFontLibrary.faces.filter { $0.isSystem || $0.scripts.contains(.latin) }
    }

    private var cjkFaces: [AppFontFace] {
        AppFontLibrary.faces.filter { $0.isSystem || $0.scripts.contains(.cjk) }
    }

    private func binding(_ category: AppFontCategory) -> Binding<AppFontSelection> {
        Binding(
            get: { AppFontStore.shared.selection(for: category) },
            set: { AppFontStore.shared.set($0, for: category) }
        )
    }
}
