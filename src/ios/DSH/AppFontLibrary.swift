//
//  AppFontLibrary.swift
//  Minis
//
//  The font library: the faces the app ships with, plus any the user imports
//  from the Files app.
//
//  WHY THE FACES ARE ADDRESSED BY POSTSCRIPT NAME
//  ---------------------------------------------------------------------------
//  `UIFont(name:)` takes nameID 6, not the file name and not the family name. A
//  wrong string does not throw and does not log — CoreText substitutes the
//  system font, which looks like "the app is ignoring my font" rather than like
//  an error. Every string in `builtInFaces` was therefore dumped from the
//  binary that ships, with `_tools/ttf-name-table.js`, and the same dump is kept
//  in `Resources/Fonts/README-fonts.txt`. `AppFontSettingsView` prints the
//  resolved names back on screen so a device with no log access can still see
//  which face actually won.
//
//  WHY STATIC INSTANCES AND NOT VARIABLE FONTS
//  ---------------------------------------------------------------------------
//  Same reason as above, one level down: reaching a `wght` axis needs a
//  `kCTFontVariationAttribute` descriptor, a path with its own silent no-op
//  failure mode, and it leaves `UIFontDescriptor.TraitKey.weight` with nothing
//  to match. Each shipped weight is a static instance with its own PostScript
//  name, so a bucket either resolves or is visibly absent.
//
//  WHY AN IMPORTED FONT IS REGISTERED AT RUNTIME
//  ---------------------------------------------------------------------------
//  `UIAppFonts` is a build-time manifest and cannot name a file the user picked
//  five seconds ago, so imported files are copied into Application Support and
//  registered with `CTFontManagerRegisterFontsForURL(.process)`. Registration is
//  repeated at every launch (`restoreImportedFonts`) because the process scope
//  dies with the process — and because the font CACHE that feeds the pickers is
//  rebuilt from the same pass, so a file that disappears between launches
//  cannot leave a dangling choice behind.
//

import Combine
import CoreText
import Foundation
import UIKit

// MARK: - Weight

/// The four weight buckets the customisation offers.
///
/// Buckets, not a continuous value: the app ships STATIC instances, so every
/// bucket is a real face with its own PostScript name. A face with no instance
/// for a bucket falls back to its nearest one instead of asking iOS for a
/// weight a custom font cannot be given (iOS does not synthesise bold for a
/// font that has no bold face — that request collapses back to Regular with no
/// error anywhere).
enum AppFontWeight: Int, CaseIterable, Identifiable, Comparable, Hashable {
    case regular = 400
    case medium = 500
    case semibold = 600
    case bold = 700

    var id: Int { rawValue }

    var uiWeight: UIFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    /// nameID 2 of the shipped instance for this bucket (`Lora-**SemiBold**`).
    var subfamily: String {
        switch self {
        case .regular: return "Regular"
        case .medium: return "Medium"
        case .semibold: return "SemiBold"
        case .bold: return "Bold"
        }
    }

    static func < (lhs: AppFontWeight, rhs: AppFontWeight) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Nearest bucket for a `UIFont.Weight` a call site asked for.
    static func bucket(for weight: UIFont.Weight) -> AppFontWeight {
        if weight.rawValue >= UIFont.Weight.bold.rawValue { return .bold }
        if weight.rawValue >= UIFont.Weight.semibold.rawValue { return .semibold }
        if weight.rawValue >= UIFont.Weight.medium.rawValue { return .medium }
        return .regular
    }
}

// MARK: - Script

/// Which half of a mixed-script run a face is used for.
///
/// A stack needs two faces per script, not one: a Latin serif has no CJK glyphs
/// and a Song face's own Latin is a full-width design nobody wants for English.
/// The two are combined with a `cascadeList` — Latin primary, CJK behind it —
/// so a run of either script lands on the face intended for it without any
/// per-character splitting at the call sites.
enum AppFontScript: String, Hashable {
    case latin
    case cjk
}

// MARK: - Face

/// One selectable face in the font library.
struct AppFontFace: Identifiable, Equatable {
    let id: String
    /// A proper noun (Lora, 方正宋三简体) — shown verbatim, never localised.
    let displayName: String
    let scripts: Set<AppFontScript>
    /// Weight bucket → PostScript name (nameID 6), dumped from the binary.
    let names: [AppFontWeight: String]
    /// A face with exactly ONE instance in the bundle (方正宋三简体). Weight
    /// requests cannot be honoured by it, and the UI says so instead of
    /// pretending: this is the honest description of a single-face font.
    let singleFaceName: String?
    /// Where it came from and under which licence — shown under the picker.
    ///
    /// This string is a CATALOG KEY, not display text: its English value is the
    /// key itself, and `AppFontSettingsView` renders it through a
    /// `LocalizedStringKey`, so the sentence translates with the rest of the
    /// screen. The FACE NAME inside it stays verbatim in every language (a proper
    /// noun), which is why the name is written into each translation separately
    /// rather than interpolated.
    ///
    /// `displayName` above is NOT a key: a proper noun has one spelling in every
    /// language and is rendered with `Text(verbatim:)`.
    let provenance: String
    let isSystem: Bool
    let isImported: Bool

    init(id: String,
         displayName: String,
         scripts: Set<AppFontScript>,
         names: [AppFontWeight: String] = [:],
         singleFaceName: String? = nil,
         provenance: String,
         isSystem: Bool = false,
         isImported: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.scripts = scripts
        self.names = names
        self.singleFaceName = singleFaceName
        self.provenance = provenance
        self.isSystem = isSystem
        self.isImported = isImported
    }

    /// `true` when the face ships more than one instance, i.e. when the weight
    /// picker can actually change the rendering.
    var hasWeightVariants: Bool { singleFaceName == nil && !isSystem }

    /// Weights the picker may offer for this face.
    var availableWeights: [AppFontWeight] {
        if isSystem { return AppFontWeight.allCases }
        if singleFaceName != nil { return [.regular] }
        return names.keys.sorted()
    }

    /// PostScript name to hand `UIFont(name:)`, or `nil` for the system face.
    ///
    /// A bucket the face has no instance for resolves to the NEAREST one it
    /// does have, deliberately: asking iOS for a missing weight either throws
    /// nothing and renders Regular, or renders a synthesised smear. Being
    /// explicit here means "Bold" on a three-weight face gives SemiBold and the
    /// UI can show that that is what happened.
    func postScriptName(for weight: AppFontWeight) -> String? {
        if isSystem { return nil }
        if let single = singleFaceName { return single }
        if let exact = names[weight] { return exact }
        let nearest = names.keys.min { lhs, rhs in
            abs(lhs.rawValue - weight.rawValue) < abs(rhs.rawValue - weight.rawValue)
        }
        return nearest.flatMap { names[$0] }
    }

    /// PostScript name of the face's own bundle file, for the launch report.
    var anyPostScriptName: String? { singleFaceName ?? names[AppFontWeight.regular] }
}

// MARK: - Import errors

enum AppFontImportError: Error, LocalizedError {
    case unreadable
    case noFaces
    case alreadyPresent(String)
    case registrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The file could not be read."
        case .noFaces:
            return "No usable font face was found in that file."
        case .alreadyPresent(let name):
            return "A font with the same contents is already in the library (\(name))."
        case .registrationFailed(let reason):
            return reason
        }
    }
}

// MARK: - Library

/// The face registry: built-ins plus whatever the user imported.
enum AppFontLibrary {

    // MARK: Built-in ids

    static let systemFaceId = "system"
    static let loraFaceId = "lora"
    static let literataFaceId = "literata"
    static let monoFaceId = "jetbrains-mono"
    static let interFaceId = "inter"
    static let songFaceId = "fz-song"
    static let sourceSongFaceId = "noto-serif-sc"

    /// What a category starts on.
    static let defaultLatinFaceId = loraFaceId
    static let defaultCJKFaceId = songFaceId

    /// The multi-weight Song face the single-face 方正宋三简体 borrows from
    /// when a heavier weight is asked for. See `AppFontStore.lendsCJKWeight`.
    static let weightLendingCJKFaceId = sourceSongFaceId

    // MARK: Built-in faces

    /// Every PostScript name below was read out of the shipped file with
    /// `_tools/ttf-name-table.js`; see `Resources/Fonts/README-fonts.txt`.
    static let builtInFaces: [AppFontFace] = [
        AppFontFace(
            id: systemFaceId,
            displayName: "System",
            scripts: [.latin, .cjk],
            provenance: "iOS system faces (SF / PingFang). The behaviour every other entry replaces."
        ),
        AppFontFace(
            id: loraFaceId,
            displayName: "Lora",
            scripts: [.latin],
            names: [
                .regular: "Lora-Regular",
                .medium: "Lora-Medium",
                .semibold: "Lora-SemiBold",
                .bold: "Lora-Bold",
            ],
            provenance: "Lora — SIL OFL 1.1 · google/fonts ofl/lora. Editorial serif; the Latin writing face."
        ),
        AppFontFace(
            id: literataFaceId,
            displayName: "Literata",
            scripts: [.latin],
            names: [
                .regular: "Literata-Regular",
                .medium: "Literata-Medium",
                .semibold: "Literata-SemiBold",
                .bold: "Literata-Bold",
            ],
            provenance: "Literata — SIL OFL 1.1 · google/fonts ofl/literata. Larger x-height; the long-form alternative."
        ),
        AppFontFace(
            id: interFaceId,
            displayName: "Inter",
            scripts: [.latin],
            names: [
                .regular: "Inter-Regular",
                .medium: "Inter-Medium",
                .semibold: "Inter-SemiBold",
            ],
            provenance: "Inter 4.001 — SIL OFL 1.1 (bundled since 1.13). Neutral UI sans; kept selectable, not the default."
        ),
        AppFontFace(
            id: monoFaceId,
            displayName: "JetBrains Mono",
            scripts: [.latin],
            names: [
                .regular: "JetBrainsMono-Regular",
                .medium: "JetBrainsMono-Medium",
                .semibold: "JetBrainsMono-SemiBold",
                .bold: "JetBrainsMono-Bold",
            ],
            provenance: "JetBrains Mono — SIL OFL 1.1 · google/fonts ofl/jetbrainsmono. Code blocks and inline code."
        ),
        AppFontFace(
            id: songFaceId,
            displayName: "方正宋三简体",
            scripts: [.cjk],
            singleFaceName: "FZS3JW--GB1-0",
            provenance: "方正宋三简体 — bundled (operator-supplied). ONE face: OS/2.usWeightClass = 400, no bold, no italic."
        ),
        AppFontFace(
            id: sourceSongFaceId,
            displayName: "思源宋体 Noto Serif SC",
            scripts: [.cjk],
            names: [
                .regular: "NotoSerifSC-Regular",
                .semibold: "NotoSerifSC-SemiBold",
                .bold: "NotoSerifSC-Bold",
            ],
            provenance: "Noto Serif SC — SIL OFL 1.1 · google/fonts ofl/notoserifsc. Subset to 方正宋三简体's own character coverage (8,054 codepoints, no Chinese character dropped) so it can carry Chinese BOLD without shipping a 25 MB face."
        ),
    ]

    /// The face that means "do nothing", used wherever a stored choice no longer
    /// resolves (an imported file that has been deleted, most often).
    static var systemFace: AppFontFace {
        builtInFaces.first { $0.isSystem } ?? builtInFaces[0]
    }

    // MARK: Registry

    private static let lock = NSLock()
    nonisolated(unsafe) private static var imported: [AppFontFace] = []

    /// Built-ins first, imported after — the picker lists them in this order.
    static var faces: [AppFontFace] {
        lock.lock()
        defer { lock.unlock() }
        return builtInFaces + imported
    }

    static var importedFaces: [AppFontFace] {
        lock.lock()
        defer { lock.unlock() }
        return imported
    }

    static func face(id: String) -> AppFontFace? {
        builtInFaces.first { $0.id == id } ?? importedFaces.first { $0.id == id }
    }

    /// Which face a PostScript name belongs to — used by `AppFont.bold(_:)` to
    /// move a whole stack (primary + cascade) to a heavier instance.
    static func faceOwning(postScriptName: String) -> AppFontFace? {
        faces.first { face in
            if face.singleFaceName == postScriptName { return true }
            return face.names.values.contains(postScriptName)
        }
    }

    /// Every PostScript name the app itself puts on screen. `AppFont.bold(_:)`
    /// and `italic(_:)` use it to tell "our" faces (which have no bold/italic
    /// faces to look up) apart from faces that do.
    static var ownedPostScriptNames: Set<String> {
        var names: Set<String> = []
        for face in faces {
            if let single = face.singleFaceName { names.insert(single) }
            names.formUnion(face.names.values)
        }
        return names
    }

    // MARK: Imported files

    /// Where imported fonts live. Application Support, not Documents: this is
    /// app-managed data that must not show up as a user document.
    static var importedDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AppFonts", isDirectory: true)
    }

    /// Register every previously imported file, once per process.
    ///
    /// Called from `AppFontRuntime.install()` at launch. The process-scope
    /// registration from the previous launch is gone by then, so without this a
    /// font the user imported last week would resolve to `nil` and the app would
    /// silently fall back to the system face.
    @discardableResult
    static func restoreImportedFonts() -> [AppFontFace] {
        let dir = importedDirectory
        var found: [AppFontFace] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                 includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let ext = url.pathExtension.lowercased()
            guard ["ttf", "otf", "ttc", "otc"].contains(ext) else { continue }
            if let error = register(url: url) {
                AppFontLog.log.error("[AppFont] restore failed \(url.lastPathComponent): \(error)")
                continue
            }
            found.append(contentsOf: faces(inFileAt: url, fileStem: url.deletingPathExtension().lastPathComponent))
        }
        lock.lock()
        imported = found
        lock.unlock()
        if !found.isEmpty {
            AppFontLog.log.info("[AppFont] imported faces: \(found.map { $0.displayName }.joined(separator: ", "))")
        }
        return found
    }

    /// Import a font file the user picked in Files.
    ///
    /// The file is COPIED into Application Support first: the URL handed over by
    /// `.fileImporter` is security-scoped and stops being readable when the
    /// callback returns, so registering it in place would produce a font that
    /// works until the next launch and then silently disappears.
    static func importFont(from url: URL) throws -> [AppFontFace] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try? Data(contentsOf: url)
        guard let data, !data.isEmpty else { throw AppFontImportError.unreadable }

        let dir = importedDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "-")
        let ext = url.pathExtension.isEmpty ? "ttf" : url.pathExtension.lowercased()
        let dest = dir.appendingPathComponent("\(stem).\(ext)")

        // Same bytes already here? Then this is a repeat import, not an error
        // worth a second copy on disk.
        if let existing = try? Data(contentsOf: dest), existing == data {
            let faces = faces(inFileAt: dest, fileStem: stem)
            merge(faces)
            guard !faces.isEmpty else { throw AppFontImportError.noFaces }
            throw AppFontImportError.alreadyPresent(faces[0].displayName)
        }

        var target = dest
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(stem)-\(suffix).\(ext)")
            suffix += 1
        }
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw AppFontImportError.unreadable
        }

        if let error = register(url: target) {
            throw AppFontImportError.registrationFailed(error)
        }
        let stemForId = target.deletingPathExtension().lastPathComponent
        let faces = faces(inFileAt: target, fileStem: stemForId)
        guard !faces.isEmpty else { throw AppFontImportError.noFaces }
        merge(faces)
        AppFontLog.log.info("[AppFont] imported \(target.lastPathComponent) faces=\(faces.count) names=\(faces.flatMap { $0.names.values }.joined(separator: ","))")
        return faces
    }

    /// Remove an imported face (and the file it came from).
    ///
    /// One file can hold more than one family, in which case several faces share
    /// a file and only the first carries the bare `imported:<stem>` id. Removing
    /// the file therefore removes every face that came from it, not just the id
    /// the swipe landed on.
    static func deleteImportedFace(id: String) throws {
        guard let face = importedFaces.first(where: { $0.id == id }) else { return }
        let dir = importedDirectory
        let stem = String(id.dropFirst("imported:".count).prefix { $0 != "#" })
        let filePrefix = "imported:" + stem
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.deletingPathExtension().lastPathComponent == stem {
            var error: Unmanaged<CFError>?
            _ = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error)
            try? FileManager.default.removeItem(at: url)
        }
        lock.lock()
        imported.removeAll { $0.id == face.id || $0.id.hasPrefix(filePrefix + "#") }
        lock.unlock()
        AppFontLog.log.info("[AppFont] removed imported face \(face.displayName)")
    }

    private static func merge(_ faces: [AppFontFace]) {
        lock.lock()
        for face in faces where !imported.contains(where: { $0.id == face.id }) {
            imported.append(face)
        }
        lock.unlock()
    }

    // MARK: CoreText plumbing

    /// `nil` when the file registered; otherwise the CoreText error to report.
    ///
    /// "Already registered" is treated as success: the same face can be reached
    /// twice per launch (once from `UIAppFonts`, once from the import pass), and
    /// that is not a failure.
    private static func register(url: URL) -> String? {
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if ok { return nil }
        guard let cfError = error?.takeRetainedValue() else { return nil }
        let code = CFErrorGetCode(cfError)
        // kCTFontManagerErrorAlreadyRegistered == 105
        if code == 105 { return nil }
        var description = "unknown error"
        if let copied = CFErrorCopyDescription(cfError) {
            description = copied as String
        }
        return "\(description) (code \(code))"
    }

    /// Build library entries for every face inside one file.
    ///
    /// One file can hold a whole family (a `.ttc`, or a TTF with several named
    /// instances), so descriptors are grouped by family name into one library
    /// entry with a weight → name map. A family whose faces cannot be told
    /// apart by weight collapses into a single-face entry rather than offering
    /// a weight picker that changes nothing.
    private static func faces(inFileAt url: URL, fileStem: String) -> [AppFontFace] {
        let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
        guard !descriptors.isEmpty else { return [] }

        var byFamily: [String: [(name: String, weight: AppFontWeight, scripts: Set<AppFontScript>)]] = [:]
        var order: [String] = []
        for descriptor in descriptors {
            guard let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { continue }
            let family = (CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String) ?? postScript
            let weight = weightBucket(of: descriptor)
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            let scripts = scriptsCovered(by: font)
            if byFamily[family] == nil { order.append(family) }
            byFamily[family, default: []].append((postScript, weight, scripts))
        }

        var result: [AppFontFace] = []
        for (index, family) in order.enumerated() {
            guard let entries = byFamily[family], let first = entries.first else { continue }
            let id = "imported:\(fileStem)" + (order.count > 1 ? "#\(index + 1)" : "")
            var names: [AppFontWeight: String] = [:]
            for entry in entries where names[entry.weight] == nil {
                names[entry.weight] = entry.name
            }
            let scripts = entries.reduce(into: Set<AppFontScript>()) { $0.formUnion($1.scripts) }
            let single = names.count <= 1 ? (names.values.first ?? first.name) : nil
            result.append(AppFontFace(
                id: id,
                displayName: family,
                scripts: scripts.isEmpty ? [.latin] : scripts,
                names: single == nil ? names : [:],
                singleFaceName: single,
                provenance: "Imported from Files — \(fileStem). Licence and redistribution are the importer's responsibility.",
                isImported: true
            ))
        }
        return result
    }

    /// CoreText's normalised weight trait (−1 … 1) → one of our four buckets.
    private static func weightBucket(of descriptor: CTFontDescriptor) -> AppFontWeight {
        let raw = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute)
        var normalized: Double?
        if let traits = raw as? [String: Any] {
            normalized = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue
        } else if let traits = raw as? NSDictionary {
            normalized = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue
        }
        guard let value = normalized else { return .regular }
        // CoreText's normalised scale: 0.0 = regular, 0.23 ≈ medium,
        // 0.30 ≈ semibold, 0.40 = bold, negative = the light side.
        if value >= 0.34 { return .bold }
        if value >= 0.26 { return .semibold }
        if value >= 0.10 { return .medium }
        return .regular
    }

    /// Which script a face is FOR, decided from the glyphs it actually has.
    ///
    /// A Song face also carries Latin, so "has an A" cannot be the test — the
    /// test is "has 中", which makes it a CJK face, and its Latin is then
    /// ignored in favour of the Latin face in front of it in the stack.
    ///
    /// Glyph IDs, not `CTFontCopyCharacterSet`: one API call, no bridging, and
    /// a glyph id of 0 is exactly the "this face cannot draw it" answer that
    /// matters. `CTFontGetGlyphsForCharacters` returns false for the whole call
    /// when ANY character is unmapped, hence the per-probe calls.
    private static func scriptsCovered(by font: CTFont) -> Set<AppFontScript> {
        if fontHasGlyph(font, 0x4E2D) { return [.cjk] }   // 中
        if fontHasGlyph(font, 0x0041) { return [.latin] } // A
        return [.latin]
    }

    private static func fontHasGlyph(_ font: CTFont, _ codeUnit: UniChar) -> Bool {
        var characters: [UniChar] = [codeUnit]
        var glyphs: [CGGlyph] = [0]
        let mapped = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1)
        return mapped && glyphs[0] != 0
    }
}
