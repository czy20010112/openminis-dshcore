import SwiftUI
import UIKit

/// App-wide typography: 方正宋三简体 (Founder Song III) for CJK, Inter for Latin.
///
/// WHY THIS FILE SITS IN `src/ios/DSH/`
/// ---------------------------------------------------------------------------
/// `DSH/` is declared in Minis.xcodeproj as a `PBXFileSystemSynchronizedRootGroup`
/// (`path = DSH`), so every `.swift` under it is compiled automatically. Adding
/// this file therefore costs ZERO `project.pbxproj` edits — in BOTH trees, which
/// already carry that group. Putting it under `Shared/` or `Views/` would have
/// needed a hand edit of the pbxproj in each tree, and the two pbxproj files are
/// not copies of each other (3991 vs 3808 lines).
///
/// FACE NAMES ARE POSTSCRIPT NAMES, READ OUT OF THE SHIPPED BINARIES
/// ---------------------------------------------------------------------------
/// `UIFont(name:)` and `Font.custom` take the *PostScript* name (name-table
/// ID 6) — not the file name, not the family name. A wrong string does not
/// throw and does not log: CoreText silently substitutes the system font. The
/// strings below were dumped from the actual resources with
/// `_tools/ttf-name-table.js`:
///
///   Resources/Fonts/FZSongSanJianTi.ttf
///       nameID 6 (3/1)     = "FZS3JW--GB1-0"
///       nameID 1 (3/1/2052) = "方正宋三简体",  (3/1/1033) = "FZSong III-Z05S"
///   Resources/Fonts/Inter-Regular.ttf   nameID 6 = "Inter-Regular"
///   Resources/Fonts/Inter-Medium.ttf    nameID 6 = "Inter-Medium"
///   Resources/Fonts/Inter-SemiBold.ttf  nameID 6 = "Inter-SemiBold"
///
/// ONE CJK WEIGHT, NO CJK ITALIC
/// ---------------------------------------------------------------------------
/// 方正宋三简体 ships exactly one face: `OS/2.usWeightClass = 400`,
/// `head.macStyle = 0`, no `fvar`. iOS does not synthesise bold or italic for a
/// custom font, so a bare "add the bold/italic trait" request silently collapses
/// back to Regular. `bold(_:)` and `italic(_:)` below are what this stack does
/// instead of that.
enum AppFont {

    // MARK: - Verified PostScript names

    /// 方正宋三简体 — the only 宋三 face in the bundle.
    static let cjkFaceName = "FZS3JW--GB1-0"

    /// Inter 4.001 static faces (SIL Open Font License 1.1).
    static let latinRegularFaceName = "Inter-Regular"
    static let latinMediumFaceName = "Inter-Medium"
    static let latinSemiBoldFaceName = "Inter-SemiBold"

    /// Everything this file builds. `bold`/`italic` use it to tell "our" fonts
    /// apart from faces that already carry a real bold/italic (Menlo in code
    /// spans, `UIFont.systemFont` everywhere else), which must keep the plain
    /// descriptor-trait behaviour.
    private static let ownedFaceNames: Set<String> = [
        cjkFaceName, latinRegularFaceName, latinMediumFaceName, latinSemiBoldFaceName,
    ]

    // MARK: - Cascade order
    //
    // INTER FIRST, 宋三 SECOND — deliberately not the other way round.
    //
    // A `cascadeList` entry is only consulted for code points the PRIMARY font
    // does not map. Measured with `_tools/ttf-cmap-probe.js`: 方正宋三简体 maps
    // the whole ASCII range itself (U+0041 → gid 34, U+0061 → gid 66), so a
    // "宋三 primary + Inter cascade" stack would NEVER reach Inter for Latin
    // text — every letter, digit and full stop in a reply would come out in the
    // Song face's own half-width Latin. Inter first inverts that: Inter maps
    // Latin, Greek, Cyrillic, arrows and geometric marks but no CJK at all
    // (U+4E2D → no glyph), while 宋三 maps CJK, full-width punctuation
    // (U+FF0C) and box drawing (U+2500). Each script therefore lands on the
    // face intended for it, with no per-character run splitting anywhere.
    //
    // Same shape the codebase already relies on for code blocks:
    // `SelectableMarkdownTheme.inlineCodeFont` / `codeBlockFont` are Menlo
    // primary + PingFang SC cascade, a far wider metric gap than this one.
    //
    // PingFang SC trails the list as a second CJK hop so that a failed 宋三
    // registration still leaves CJK text on a Chinese face rather than on the
    // Latin face's fallback.
    private static let cjkCascadeNames = [cjkFaceName, "PingFang SC"]

    // MARK: - Cache
    //
    // LOAD-BEARING, not an optimisation. `ChatInputBar` compares
    // `tv.font != inputFont` on every parent re-render and calls
    // `invalidateIntrinsicContentSize()` when they differ, and compares
    // `label.font != inputFont` for the placeholder. `UIFont.systemFont(ofSize:)`
    // is interned, so that guard used to be stable for free; two independently
    // built descriptor fonts are not guaranteed to compare equal, so handing out
    // one cached instance per (size, weight, latinOnly) is what keeps the
    // comparison exact instead of permanently "different" (which would
    // invalidate the composer's intrinsic size on every single render pass).
    //
    // The lock follows the house pattern used by SessionLockStore.swift:386-387
    // and ISHExecutionCoordinator.swift:745-746 under Swift 6 language mode: a
    // `static let` NSLock plus a `nonisolated(unsafe)` `static var` that is only
    // ever touched while holding it.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: UIFont] = [:]

    private struct Key: Hashable {
        let size: CGFloat
        let weight: CGFloat
        let latinOnly: Bool
    }

    // MARK: - API

    /// The app's reading font: Latin → Inter, CJK → 方正宋三简体.
    ///
    /// `weight` only reaches the Latin side. 宋三 has a single weight, so CJK
    /// stays Regular at every weight value; callers should not read that as a
    /// bug (see `bold(_:)`).
    static func ui(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        font(size: size, weight: weight, latinOnly: false)
    }

    /// Inter only, with no CJK cascade — for strings known to be pure Latin.
    static func uiLatin(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        font(size: size, weight: weight, latinOnly: true)
    }

    /// SwiftUI counterpart.
    ///
    /// `Font.custom(name, size:relativeTo:)` is deliberately NOT used: it
    /// addresses one face by PostScript name and drops the cascade list, so CJK
    /// inside such text would silently fall back to the system face instead of
    /// 宋三. A `UIFont`-backed `Font` keeps the cascade, which means Dynamic
    /// Type has to be applied to the point size explicitly here — that is all
    /// `relativeTo` does. Do NOT combine this with `FontSettings`' own
    /// `scaled*` helpers: those are the app's own scaling and would stack.
    static func sw(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        Font(ui(UIFontMetrics(forTextStyle: style.uiKitTextStyle).scaledValue(for: size)))
    }

    /// Whether both halves of the stack resolved.
    ///
    /// `UIFont(name:) == nil` is the only signal iOS gives: a font missing from
    /// `UIAppFonts`, a typo'd PostScript name and an unreadable file all look
    /// exactly like success at every call site (the system font renders).
    static func available() -> (cjk: Bool, latin: Bool) {
        (cjk: UIFont(name: cjkFaceName, size: 12) != nil,
         latin: UIFont(name: latinRegularFaceName, size: 12) != nil)
    }

    // MARK: - Weight resolution for our own faces

    /// Markdown `**strong**`, and any other "same font, heavier" request.
    static func bold(_ font: UIFont) -> UIFont {
        guard isOwned(font) else {
            // Not ours — code spans (Menlo) and system text do have real bold
            // faces, so the original descriptor-weight request is correct.
            let descriptor = font.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]
            ])
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        // Ours: neither the trait request nor a weight-trait lookup can work.
        // 宋三 has one face, and Inter's SemiBold lives in a DIFFERENT family
        // ("Inter SemiBold" vs "Inter"), so a weight trait finds no match inside
        // the base family and collapses to Regular. Rebuild through our own
        // constructor: Latin gets the real Inter-SemiBold face, CJK stays 宋三
        // Regular — which is the honest answer, because no bold 宋三 glyph
        // exists in the bundle.
        return ui(font.pointSize, weight: .semibold)
    }

    /// Markdown `*emphasis*`.
    static func italic(_ font: UIFont) -> UIFont {
        guard isOwned(font) else {
            let combined = font.fontDescriptor.symbolicTraits.union(.traitItalic)
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(combined) else { return font }
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return sheared(font)
    }

    /// Synthetic oblique for the custom stack.
    ///
    /// Neither 宋三 nor Inter-Regular/Medium/SemiBold has an italic face and iOS
    /// will not synthesise one for a custom font, so a trait request here would
    /// return the upright face — every `*emphasis*` in a reply would stop looking
    /// emphasised, with no error anywhere. Shearing the descriptor keeps the
    /// slant (this is the mechanism UIKit itself uses for synthetic oblique).
    /// The cascade list is re-attached explicitly because a matrix-transformed
    /// descriptor is the one place CoreText is free to drop other attributes,
    /// and losing it would drop the CJK fallback with it.
    private static func sheared(_ font: UIFont) -> UIFont {
        let base = font.fontDescriptor
        var kept: [UIFontDescriptor.AttributeName: Any] = [:]
        if let cascade = base.object(forKey: .cascadeList) { kept[.cascadeList] = cascade }
        let shear = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
        return UIFont(descriptor: base.withMatrix(shear).addingAttributes(kept), size: font.pointSize)
    }

    private static func isOwned(_ font: UIFont) -> Bool {
        ownedFaceNames.contains(font.fontName)
    }

    // MARK: - Build

    private static func font(size: CGFloat, weight: UIFont.Weight, latinOnly: Bool) -> UIFont {
        let key = Key(size: size, weight: weight.rawValue, latinOnly: latinOnly)
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let built = build(size: size, weight: weight, latinOnly: latinOnly)
        cache[key] = built
        return built
    }

    private static func build(size: CGFloat, weight: UIFont.Weight, latinOnly: Bool) -> UIFont {
        let latin = UIFont(name: latinFaceName(for: weight), size: size)
            ?? UIFont(name: latinRegularFaceName, size: size)
        let cjk = UIFont(name: cjkFaceName, size: size)

        if latinOnly { return latin ?? .systemFont(ofSize: size, weight: weight) }

        guard let cjk else {
            // 宋三 did not register. Latin still comes from Inter so a reply
            // does not end up split across two unrelated system faces.
            return latin ?? .systemFont(ofSize: size, weight: weight)
        }
        guard let latin else {
            // Inter did not register. Song carries its own Latin, which keeps
            // the run in one family rather than mixing a Latin system face with
            // a CJK Song face.
            return cjk
        }

        var cascade = [cjk.fontDescriptor]
        for name in cjkCascadeNames.dropFirst() {
            if let extra = UIFont(name: name, size: size) { cascade.append(extra.fontDescriptor) }
        }
        return UIFont(descriptor: latin.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: size)
    }

    /// `UIFont.Weight` → one of our three Latin faces.
    ///
    /// The three-way split is not cosmetic: the composer's context-usage hint
    /// asks for `.medium` (`ChatInputBar.attributedHint`) and deliberately wants
    /// one step up, not a full semibold — routing `.medium` to SemiBold there
    /// would undo a decision the code documents.
    private static func latinFaceName(for weight: UIFont.Weight) -> String {
        if weight.rawValue >= UIFont.Weight.semibold.rawValue { return latinSemiBoldFaceName }
        if weight.rawValue >= UIFont.Weight.medium.rawValue { return latinMediumFaceName }
        return latinRegularFaceName
    }

    // MARK: - Launch report

    private static let log = AppLogger(category: "Fonts")

    /// Called once from `MinisApp.init`. Logs the resolved state of every face
    /// plus the `UIAppFonts` manifest, and the presence of each declared file in
    /// the built bundle — enough to tell "font file not in the bundle" apart
    /// from "file in the bundle but not declared" apart from "declared but the
    /// PostScript name is wrong", which are three different fixes and otherwise
    /// all look like "the app is using the system font".
    @discardableResult
    static func logRegistrationState() -> (cjk: Bool, latin: Bool) {
        let state = available()
        let faces = [cjkFaceName, latinRegularFaceName, latinMediumFaceName, latinSemiBoldFaceName]
            .map { "\($0)=\(UIFont(name: $0, size: 12) != nil ? "ok" : "MISSING")" }
            .joined(separator: " ")
        let declared = (Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String]) ?? []
        let bundled = declared.map { entry -> String in
            let file = (entry as NSString).lastPathComponent
            let dir = (entry as NSString).deletingLastPathComponent
            let found = Bundle.main.url(forResource: file, withExtension: nil,
                                        subdirectory: dir.isEmpty ? nil : dir) != nil
            return "\(entry)=\(found ? "present" : "ABSENT")"
        }.joined(separator: " ")

        let line = "[AppFont] cjk=\(state.cjk ? "registered" : "FALLBACK-TO-SYSTEM")"
            + " latin=\(state.latin ? "registered" : "FALLBACK-TO-SYSTEM")"
            + " | faces: \(faces)"
            + " | UIAppFonts[\(declared.count)]: \(bundled.isEmpty ? "<none>" : bundled)"
        if state.cjk && state.latin { log.info(line) } else { log.error(line) }
        return state
    }
}

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
