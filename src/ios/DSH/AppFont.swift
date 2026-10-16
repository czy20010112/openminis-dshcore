//
//  AppFont.swift
//  Minis
//
//  App-wide typography. Latin and CJK come from two faces at once, chosen per
//  category, persisted in `AppFontStore`.
//
//  WHY THIS FILE SITS IN `src/ios/DSH/`
//  ---------------------------------------------------------------------------
//  `DSH/` is declared in Minis.xcodeproj as a `PBXFileSystemSynchronizedRootGroup`
//  (`path = DSH`), so every `.swift` under it is compiled automatically. Adding
//  this file therefore costs ZERO `project.pbxproj` edits — in BOTH trees, which
//  already carry that group. Putting it under `Shared/` or `Views/` would have
//  needed a hand edit of the pbxproj in each tree, and the two pbxproj files are
//  not copies of each other.
//
//  FACE NAMES ARE POSTSCRIPT NAMES, READ OUT OF THE SHIPPED BINARIES
//  ---------------------------------------------------------------------------
//  `UIFont(name:)` takes the *PostScript* name (name table ID 6) — not the file
//  name, not the family name. A wrong string does not throw and does not log:
//  CoreText silently substitutes the system font. Every name lives in
//  `AppFontLibrary.builtInFaces`, dumped with `_tools/ttf-name-table.js` and
//  recorded in `Resources/Fonts/README-fonts.txt`.
//
//  THE STACK, AND WHERE IT COMES FROM
//  ---------------------------------------------------------------------------
//  The reference implementation is `D:\AI\_fontcheck\warm-parchment.fonts.css`
//  plus `demo/index.html`, which replace the Anthropic faces with OFL ones:
//  Lora for editorial body text, Literata as the long-form alternative,
//  JetBrains Mono for code, Inter for UI chrome only, and a Song face for
//  Chinese. Its two rules are the ones implemented here:
//
//    * a Latin face in front of a Chinese face in the same stack
//      (`'Warm Serif', 'Warm Song SC'`), so each script lands on the face
//      intended for it;
//    * Chinese display text is 宋体 at a real weight — "宋体加黑" — which needs
//      a Song family that actually has weights.
//
//  ONE CJK FACE, ONE CJK WEIGHT — THE PART THAT IS NOT PRETENDED AWAY
//  ---------------------------------------------------------------------------
//  方正宋三简体 ships exactly one face: `OS/2.usWeightClass = 400`, no `fvar`,
//  no bold. iOS does not synthesise bold for a custom font, so a bare "add the
//  bold trait" request collapses back to Regular. Chinese weight is therefore
//  served by the second Song face in the bundle (思源宋体 / Noto Serif SC), and
//  `AppFontStore.lendsCJKWeight` decides whether that substitution happens. Off,
//  Chinese stays Regular at every weight, and the settings screen says so.
//
//  The cascade direction is Latin-first because a Song face maps the whole
//  ASCII range itself (`_tools/ttf-cmap-probe.js`: U+0041 → gid 34), so Song
//  first would never reach the Latin face. Latin first inverts that. This is
//  also the shape `SelectableMarkdownTheme` already used for code (Menlo +
//  PingFang SC).
//

import SwiftUI
import UIKit

/// The one logger this stack writes to. `[AppFont]` lines are the only place a
/// silent font substitution becomes visible: a missing file, a missing
/// `UIAppFonts` entry and a wrong PostScript name all render as the system font
/// with no error at any layer.
enum AppFontLog {
    static let log = AppLogger(category: "Fonts")
}

enum AppFont {

    // MARK: - API

    /// The app's reading font for `category`: Latin face in front, CJK face
    /// behind it, combined into one `UIFont` through a `cascadeList`.
    ///
    /// `weight` reaches both halves: the Latin side gets the matching static
    /// instance, the CJK side gets its own instance when the chosen Song face
    /// has one (see `AppFontStore.lendsCJKWeight`).
    static func ui(_ size: CGFloat,
                   weight: UIFont.Weight = .regular,
                   category: AppFontCategory = .body) -> UIFont {
        font(size: size, weight: weight, category: category, latinOnly: false)
    }

    /// Latin only, with no CJK cascade — for strings known to be pure Latin.
    static func uiLatin(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        font(size: size, weight: weight, category: .body, latinOnly: true)
    }

    /// Headings and navigation titles.
    static func title(_ size: CGFloat, weight: UIFont.Weight = .bold) -> UIFont {
        ui(size, weight: weight, category: .title)
    }

    /// Code blocks and inline code.
    static func code(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        ui(size, weight: weight, category: .code)
    }

    /// UIKit chrome: navigation bars, bar buttons, tab bar, segmented controls.
    static func chrome(_ size: CGFloat, weight: UIFont.Weight = .medium) -> UIFont {
        ui(size, weight: weight, category: .ui)
    }

    /// SwiftUI counterpart.
    ///
    /// `Font.custom(name, size:relativeTo:)` is deliberately NOT used: it
    /// addresses one face by PostScript name and drops the cascade list, so CJK
    /// inside such text would fall back to the system face instead of a Song
    /// face. A `UIFont`-backed `Font` keeps the cascade, which means Dynamic
    /// Type has to be applied to the point size explicitly here — that is all
    /// `relativeTo` does. Do NOT combine this with `FontSettings`' own
    /// `scaled*` helpers: those are the app's own scaling and would stack.
    static func sw(_ size: CGFloat,
                   relativeTo style: Font.TextStyle = .body,
                   weight: UIFont.Weight = .regular,
                   category: AppFontCategory = .body) -> Font {
        let scaled = UIFontMetrics(forTextStyle: style.uiKitTextStyle).scaledValue(for: size)
        return Font(ui(scaled, weight: weight, category: category))
    }

    /// What the app root hands to `\.font`.
    ///
    /// `nil` when the user has switched the takeover off, which restores the
    /// stock behaviour (SwiftUI's own default font everywhere nothing sets one).
    ///
    /// The size is resolved through `UIFontMetrics` with the APP's own scale
    /// level as the trait, not the system one. This app overrides the preferred
    /// content size category for its own "app base" setting
    /// (`FontSettings.appBaseScale`), and a fixed-size `Font` ignores that
    /// override entirely — every plain `Text` used to be a semantic font that
    /// scaled with it, so without this the scale setting would silently stop
    /// affecting most of the app the moment the takeover went on.
    static func environmentFont(appScale: FontScaleLevel) -> Font? {
        guard AppFontStore.shared.takeOverAppText else { return nil }
        let traits = UITraitCollection(preferredContentSizeCategory: appScale.contentSizeCategory)
        let size = UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits)
        return Font(ui(size, category: .body))
    }

    // MARK: - Weight resolution for our own faces

    /// Markdown `**strong**`, and any other "same font, heavier" request.
    ///
    /// Our faces are addressed through a face → instance map, so "heavier" means
    /// swapping in the heavier static instance everywhere in the stack — the
    /// primary face AND each CJK entry in its cascade list. A trait request
    /// cannot do that: the trait finds no match inside a family whose weights
    /// live in separate families/instances, and CoreText then renders Regular
    /// with no error.
    static func bold(_ font: UIFont) -> UIFont {
        if let moved = map(font, to: .bold) { return moved }
        guard !AppFontLibrary.ownedPostScriptNames.contains(font.fontName) else {
            // Ours, and there is no heavier instance of it (single-face Song).
            // Returning it unchanged is the honest outcome; a trait request here
            // would look like it worked while rendering the same glyphs.
            return font
        }
        // Not ours — code spans and system text really do have bold faces.
        let descriptor = font.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]
        ])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// Markdown `*emphasis*`.
    ///
    /// Neither Song face nor the Latin faces ship an italic, and iOS will not
    /// synthesise one for a custom font, so a trait request would return the
    /// upright face — every `*emphasis*` in a reply would stop looking
    /// emphasised, with no error anywhere. Shearing the descriptor keeps the
    /// slant (this is the mechanism UIKit itself uses for synthetic oblique).
    static func italic(_ font: UIFont) -> UIFont {
        guard AppFontLibrary.ownedPostScriptNames.contains(font.fontName) else {
            let combined = font.fontDescriptor.symbolicTraits.union(.traitItalic)
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(combined) else { return font }
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return sheared(font)
    }

    /// Synthetic oblique for the custom stack. The cascade list is re-attached
    /// explicitly because a matrix-transformed descriptor is the one place
    /// CoreText is free to drop other attributes, and losing it would drop the
    /// CJK fallback with it.
    private static func sheared(_ font: UIFont) -> UIFont {
        let base = font.fontDescriptor
        var kept: [UIFontDescriptor.AttributeName: Any] = [:]
        if let cascade = base.object(forKey: .cascadeList) { kept[.cascadeList] = cascade }
        let shear = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
        return UIFont(descriptor: base.withMatrix(shear).addingAttributes(kept), size: font.pointSize)
    }

    // MARK: - Reporting

    /// Whether the stack the app is currently configured to use resolves.
    ///
    /// `UIFont(name:) == nil` is the only signal iOS gives: a font missing from
    /// `UIAppFonts`, a typo'd PostScript name and an unreadable file all look
    /// exactly like success at every call site (the system font renders).
    static func available() -> (cjk: Bool, latin: Bool) {
        let selection = AppFontStore.shared.selection(for: .body)
        let latin = AppFontLibrary.face(id: selection.latinFaceId)
        let cjk = AppFontLibrary.face(id: selection.cjkFaceId)
        return (cjk: resolves(cjk, at: selection.cjkWeight),
                latin: resolves(latin, at: selection.latinWeight))
    }

    private static func resolves(_ face: AppFontFace?, at weight: AppFontWeight) -> Bool {
        guard let face, !face.isSystem else { return false }
        guard let name = face.postScriptName(for: weight) else { return false }
        return UIFont(name: name, size: 12) != nil
    }

    /// The PostScript names each category actually resolves to, for the settings
    /// screen's readout — the same information the launch log carries, on screen,
    /// for a device where reading a log is not convenient.
    static func resolvedNames(for category: AppFontCategory) -> (latin: String, cjk: String, note: String?) {
        let selection = AppFontStore.shared.selection(for: category)
        let latinFace = AppFontLibrary.face(id: selection.latinFaceId)
        let cjkFace = AppFontLibrary.face(id: selection.cjkFaceId)

        let latin = latinFace?.isSystem == true
            ? "System"
            : (latinFace?.postScriptName(for: selection.latinWeight) ?? "unresolved")
        var cjk = cjkFace?.isSystem == true
            ? "System"
            : (cjkFace?.postScriptName(for: selection.cjkWeight) ?? "unresolved")
        var note: String?
        if let face = cjkFace, !face.isSystem, !face.hasWeightVariants, selection.cjkWeight > .regular {
            if AppFontStore.shared.lendsCJKWeight,
               let lender = AppFontLibrary.face(id: AppFontLibrary.weightLendingCJKFaceId),
               let lent = lender.postScriptName(for: selection.cjkWeight) {
                cjk = "\(lent) → \(cjk)"
                note = "borrowed weight"
            } else {
                note = "single weight"
            }
        }
        return (latin, cjk, note)
    }

    // MARK: - Cache
    //
    // LOAD-BEARING, not an optimisation. `ChatInputBar` compares
    // `tv.font != inputFont` on every parent re-render and calls
    // `invalidateIntrinsicContentSize()` when they differ, and compares
    // `label.font != inputFont` for the placeholder. `UIFont.systemFont(ofSize:)`
    // is interned, so that guard used to be stable for free; two independently
    // built descriptor fonts are not guaranteed to compare equal, so handing out
    // one cached instance per (size, category, weight, latinOnly) is what keeps
    // the comparison exact instead of permanently "different" (which would
    // invalidate the composer's intrinsic size on every single render pass).
    //
    // The cache is dropped whenever `AppFontStore.generation` moves, so a
    // settings change reaches the next font request rather than the next launch.
    //
    // The lock follows the house pattern used by SessionLockStore.swift:386-387
    // and ISHExecutionCoordinator.swift:745-746: a `static let` NSLock plus a
    // `nonisolated(unsafe)` `static var` that is only ever touched while holding it.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: UIFont] = [:]
    nonisolated(unsafe) private static var cacheGeneration: Int = -1

    private struct Key: Hashable {
        let size: CGFloat
        let category: String
        let weight: Int
        let latinOnly: Bool
        let generation: Int
    }

    private static func font(size: CGFloat,
                             weight: UIFont.Weight,
                             category: AppFontCategory,
                             latinOnly: Bool) -> UIFont {
        let generation = AppFontStore.shared.generation
        let key = Key(size: size,
                      category: category.rawValue,
                      weight: AppFontWeight.bucket(for: weight).rawValue,
                      latinOnly: latinOnly,
                      generation: generation)
        lock.lock()
        if cacheGeneration != generation {
            cache.removeAll()
            cacheGeneration = generation
        }
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let built = build(size: size, category: category, bucket: AppFontWeight.bucket(for: weight), latinOnly: latinOnly)

        lock.lock()
        cache[key] = built
        lock.unlock()
        return built
    }

    // MARK: - Build

    private static func build(size: CGFloat,
                              category: AppFontCategory,
                              bucket: AppFontWeight,
                              latinOnly: Bool) -> UIFont {
        let store = AppFontStore.shared
        let selection = store.selection(for: category)
        let latinFace = AppFontLibrary.face(id: selection.latinFaceId) ?? AppFontLibrary.systemFace
        let cjkFace = AppFontLibrary.face(id: selection.cjkFaceId) ?? AppFontLibrary.systemFace

        let latin = latinFont(size: size, face: latinFace, bucket: bucket, fallbackWeight: bucket.uiWeight)

        if latinOnly { return latin }

        let cascade = cjkCascade(size: size, face: cjkFace, bucket: bucket, lendWeight: store.lendsCJKWeight)
        guard !cascade.isEmpty else { return latin }
        return UIFont(descriptor: latin.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: size)
    }

    private static func latinFont(size: CGFloat,
                                  face: AppFontFace,
                                  bucket: AppFontWeight,
                                  fallbackWeight: UIFont.Weight) -> UIFont {
        if face.isSystem { return .systemFont(ofSize: size, weight: fallbackWeight) }
        if let name = face.postScriptName(for: bucket), let font = UIFont(name: name, size: size) {
            return font
        }
        // The face did not register. Falling back to the system font keeps the
        // reply readable rather than dropping the whole stack.
        return .systemFont(ofSize: size, weight: fallbackWeight)
    }

    /// The CJK side of the stack: the chosen face's instance for `bucket`, or —
    /// when the chosen face has only one instance and a heavier weight was asked
    /// for — the multi-weight Song face, with the chosen face kept directly
    /// behind it so every character it can draw still comes from it.
    private static func cjkCascade(size: CGFloat,
                                   face: AppFontFace,
                                   bucket: AppFontWeight,
                                   lendWeight: Bool) -> [UIFontDescriptor] {
        var cascade: [UIFontDescriptor] = []
        if !face.isSystem, let name = face.postScriptName(for: bucket), UIFont(name: name, size: size) != nil {
            let borrowed = borrowWeight(size: size,
                                        from: face,
                                        ownName: name,
                                        bucket: bucket,
                                        lendWeight: lendWeight)
            if let borrowed {
                cascade.append(named(borrowed, size))
                // Directly behind the lender, so a character it cannot draw
                // still comes from the face the user actually chose.
                cascade.append(named(name, size))
            } else {
                cascade.append(named(name, size))
            }
        }
        // Last resort so that a face which failed to register still leaves
        // Chinese on a Chinese face rather than on the Latin face's fallback.
        if UIFont(name: "PingFang SC", size: size) != nil {
            cascade.append(named("PingFang SC", size))
        }
        return cascade
    }

    /// The PostScript name of the face that should supply a heavier CJK weight
    /// the chosen face cannot, or `nil` when the chosen face must serve itself.
    private static func borrowWeight(size: CGFloat,
                                     from face: AppFontFace,
                                     ownName: String,
                                     bucket: AppFontWeight,
                                     lendWeight: Bool) -> String? {
        guard !face.hasWeightVariants, bucket > .regular, lendWeight else { return nil }
        guard let lender = AppFontLibrary.face(id: AppFontLibrary.weightLendingCJKFaceId),
              lender.id != face.id,
              let lentName = lender.postScriptName(for: bucket),
              lentName != ownName,
              UIFont(name: lentName, size: size) != nil else { return nil }
        return lentName
    }

    /// A cascade entry by PostScript name.
    ///
    /// Built from the name rather than from a live `UIFont`'s descriptor so the
    /// `.name` attribute is guaranteed to be present: `bold(_:)` reads it back
    /// to move the whole cascade to the heavier instance, and a descriptor
    /// without it would silently stop following the weight.
    private static func named(_ postScriptName: String, size: CGFloat) -> UIFontDescriptor {
        UIFontDescriptor(fontAttributes: [.name: postScriptName, .size: size])
    }

    /// Move a whole stack (primary + every cascade entry we own) to `bucket`.
    ///
    /// Returns `nil` when nothing moved — i.e. the font is not one of ours and
    /// the plain descriptor-trait request is still the right answer.
    private static func map(_ font: UIFont, to bucket: AppFontWeight) -> UIFont? {
        guard let face = AppFontLibrary.faceOwning(postScriptName: font.fontName) else { return nil }
        var didMove = false
        var primary = font
        if let name = face.postScriptName(for: bucket), name != font.fontName,
           let moved = UIFont(name: name, size: font.pointSize) {
            primary = moved
            didMove = true
        }
        var attributes: [UIFontDescriptor.AttributeName: Any] = [:]
        if let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [UIFontDescriptor] {
            var movedCascade: [UIFontDescriptor] = []
            var cascadeMoved = false
            for descriptor in cascade {
                guard let name = descriptor.object(forKey: .name) as? String,
                      let owning = AppFontLibrary.faceOwning(postScriptName: name) else {
                    // "PingFang SC" and anything else we do not own: leave it.
                    movedCascade.append(descriptor)
                    continue
                }
                if let lent = borrowWeight(size: font.pointSize,
                                           from: owning,
                                           ownName: name,
                                           bucket: bucket,
                                           lendWeight: AppFontStore.shared.lendsCJKWeight) {
                    // Single-face Song asked to go heavier: lend it a weight and
                    // keep it behind the lender for coverage.
                    movedCascade.append(named(lent, size: font.pointSize))
                    movedCascade.append(descriptor)
                    cascadeMoved = true
                } else if let heavier = owning.postScriptName(for: bucket),
                          heavier != name,
                          UIFont(name: heavier, size: font.pointSize) != nil {
                    movedCascade.append(named(heavier, size: font.pointSize))
                    cascadeMoved = true
                } else {
                    movedCascade.append(descriptor)
                }
            }
            if cascadeMoved {
                attributes[.cascadeList] = movedCascade
                didMove = true
            }
        }
        guard didMove else { return nil }
        return UIFont(descriptor: primary.fontDescriptor.addingAttributes(attributes), size: font.pointSize)
    }

    // MARK: - Launch report

    /// Called from `MinisApp.init` and again from the root `.onAppear` (after
    /// logging is switched on) — the second call is the one that reaches a file.
    ///
    /// Logs the resolved state of every shipped face, the `UIAppFonts` manifest
    /// against the built bundle, what each category currently resolves to, and
    /// every imported face. That is enough to tell "font file not in the bundle"
    /// apart from "file in the bundle but not declared" apart from "declared but
    /// the PostScript name is wrong" — three different fixes that all look like
    /// "the app is using the system font".
    @discardableResult
    static func logRegistrationState() -> (cjk: Bool, latin: Bool) {
        let state = available()
        // EVERY instance of EVERY shipped face, not one per family: the whole
        // point of this line is to say which PostScript name failed to resolve,
        // and a family that reports "ok" through its Regular instance while its
        // Bold is missing is exactly the case that would hide here.
        let checkName: (String) -> String = { UIFont(name: $0, size: 12) != nil ? "ok" : "MISSING" }
        let faces = AppFontLibrary.builtInFaces.flatMap { face -> [String] in
            let names = face.names.values.sorted()
            if !names.isEmpty { return names.map { "\($0)=\(checkName($0))" } }
            if let single = face.singleFaceName { return ["\(single)=\(checkName(single))"] }
            return ["\(face.displayName)=system"]
        }.joined(separator: " ")

        let declared = (Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String]) ?? []
        let bundled = declared.map { entry -> String in
            let file = (entry as NSString).lastPathComponent
            let dir = (entry as NSString).deletingLastPathComponent
            let found = Bundle.main.url(forResource: file, withExtension: nil,
                                        subdirectory: dir.isEmpty ? nil : dir) != nil
            return "\(entry)=\(found ? "present" : "ABSENT")"
        }.joined(separator: " ")

        let resolved = AppFontCategory.allCases.map { category -> String in
            let names = resolvedNames(for: category)
            let note = names.note.map { " (\($0))" } ?? ""
            return "\(category.rawValue)[\(names.latin) + \(names.cjk)\(note)]"
        }.joined(separator: " ")

        let imported = AppFontLibrary.importedFaces
        let importedLine = imported.isEmpty
            ? "none"
            : imported.map { "\($0.displayName)=\($0.anyPostScriptName ?? "?")" }.joined(separator: " ")

        let line = "[AppFont] cjk=\(state.cjk ? "registered" : "FALLBACK-TO-SYSTEM")"
            + " latin=\(state.latin ? "registered" : "FALLBACK-TO-SYSTEM")"
            + " | faces: \(faces)"
            + " | categories: \(resolved)"
            + " | imported: \(importedLine)"
            + " | UIAppFonts[\(declared.count)]: \(bundled.isEmpty ? "<none>" : bundled)"
        if state.cjk && state.latin { AppFontLog.log.info(line) } else { AppFontLog.log.error(line) }
        return state
    }
}

// MARK: - Helpers

private extension Font.TextStyle {
    /// `Font.TextStyle` has no UIKit counterpart accessor, and `UIFontMetrics`
    /// needs a `UIFont.TextStyle` to scale by.
    var uiKitTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}
