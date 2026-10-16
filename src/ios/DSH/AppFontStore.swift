//
//  AppFontStore.swift
//  Minis
//
//  The persisted font choice: one Latin face + weight and one CJK face + weight
//  per category, plus the two global switches.
//
//  WHY PER CATEGORY, AND WHY TWO FACES PER CATEGORY
//  ---------------------------------------------------------------------------
//  The app has four different kinds of text and they do not want the same face:
//  a title wants weight, a body wants an editorial serif at reading size, code
//  wants a monospace that lines up, and UI chrome wants something quieter than
//  the body. Each category therefore carries its own pair.
//
//  The pair is two faces, not one, because no single font can serve both scripts
//  here: the Latin faces have no CJK glyphs at all, and a Song face's own Latin
//  is a full-width design that nobody wants for English. That is exactly what
//  the reference stack does — `D:\AI\_fontcheck\warm-parchment.fonts.css`
//  declares `'Warm Serif', 'Warm Song SC', …` and `'Warm Sans', 'Warm Sans SC',
//  …`, a Latin face in front of a Chinese face. The two are combined into one
//  `UIFont` with a `cascadeList`, so a mixed paragraph needs no run splitting.
//
//  WHY USERDEFAULTS, AND WHY THE READ SIDE IS LOCKED
//  ---------------------------------------------------------------------------
//  UserDefaults because the app owns its own plist and rewrites it at launch: a
//  value written from inside the app survives, a value poked in from outside
//  does not. (The same gotcha is documented for the spill budget.) Every read
//  goes through `AppFontStore` rather than a copied constant, so a change is
//  live for the next font request; `AppFont` keys its cache on `generation` so
//  a change also invalidates everything already built.
//
//  The lock is not decoration: `AppFont.ui(_:)` is called from measurement paths
//  (table width, message height) that are not guaranteed to be on the main
//  actor, and this type is deliberately NOT `@MainActor` for the same reason
//  `DSHTodoStore` is not (see its header). Mutations only ever come from the
//  settings UI, i.e. the main actor.
//

import Combine
import Foundation
import UIKit

extension Notification.Name {
    /// Posted after any font choice changes. `AppFontRuntime` listens to
    /// re-apply the UIKit appearance proxies and restyle labels already on
    /// screen, which is what makes the change visible without a relaunch.
    static let appFontSettingsChanged = Notification.Name("appFontSettingsChanged")
}

// MARK: - Category

/// The four text categories the app routes through the stack.
///
/// The set is chosen from the call sites that exist, not from a type scale:
/// `title` is what the markdown heading renderer asks for, `body` is the chat
/// text and the default for anything that does not say otherwise, `code` is
/// every code block and inline code span, and `ui` is the chrome the app cannot
/// reach from SwiftUI (navigation bars, bar buttons, tab bar, segmented
/// controls, plain UIKit labels). Four is the smallest set that maps 1:1 onto
/// those call sites — a fifth category would have no caller, and fewer would
/// force code blocks and body text to share a face, which is the one pair that
/// must never match.
enum AppFontCategory: String, CaseIterable, Identifiable {
    case title
    case body
    case code
    case ui

    var id: String { rawValue }

    /// Shipped default for this category.
    var defaultSelection: AppFontSelection {
        switch self {
        case .title:
            return AppFontSelection(latinFaceId: AppFontLibrary.loraFaceId,
                                    latinWeight: .bold,
                                    cjkFaceId: AppFontLibrary.songFaceId,
                                    cjkWeight: .bold)
        case .body:
            return AppFontSelection(latinFaceId: AppFontLibrary.loraFaceId,
                                    latinWeight: .regular,
                                    cjkFaceId: AppFontLibrary.songFaceId,
                                    cjkWeight: .regular)
        case .code:
            return AppFontSelection(latinFaceId: AppFontLibrary.monoFaceId,
                                    latinWeight: .regular,
                                    cjkFaceId: AppFontLibrary.songFaceId,
                                    cjkWeight: .regular)
        case .ui:
            return AppFontSelection(latinFaceId: AppFontLibrary.loraFaceId,
                                    latinWeight: .medium,
                                    cjkFaceId: AppFontLibrary.songFaceId,
                                    cjkWeight: .regular)
        }
    }

    /// The scene of the app this category actually controls. The settings screen
    /// renders this as a `Text` literal so the string catalog can extract it;
    /// see the localisation note in `AppFontSettingsView`.
}

// MARK: - Selection

/// One category's Latin face + weight and CJK face + weight.
struct AppFontSelection: Equatable {
    var latinFaceId: String
    var latinWeight: AppFontWeight
    var cjkFaceId: String
    var cjkWeight: AppFontWeight
}

// MARK: - Store

/// Not `@MainActor` on purpose — see the header.
final class AppFontStore: ObservableObject {

    static let shared = AppFontStore()

    let objectWillChange = ObservableObjectPublisher()

    private let lock = NSLock()
    private var storedSelections: [AppFontCategory: AppFontSelection] = [:]
    private var storedGeneration: Int = 0
    private var storedTakeOver: Bool = true
    private var storedLendCJK: Bool = true

    private enum Keys {
        static func face(_ category: AppFontCategory) -> String { "appFont.v1.\(category.rawValue).face" }
        static func weight(_ category: AppFontCategory) -> String { "appFont.v1.\(category.rawValue).weight" }
        static func cjkFace(_ category: AppFontCategory) -> String { "appFont.v1.\(category.rawValue).cjkFace" }
        static func cjkWeight(_ category: AppFontCategory) -> String { "appFont.v1.\(category.rawValue).cjkWeight" }
        static let takeOver = "appFont.v1.takeOverAppText"
        static let lendCJK = "appFont.v1.lendCJKWeight"
    }

    private init() {
        let defaults = UserDefaults.standard
        for category in AppFontCategory.allCases {
            let fallback = category.defaultSelection
            let latinFace = defaults.string(forKey: Keys.face(category)) ?? fallback.latinFaceId
            let cjkFace = defaults.string(forKey: Keys.cjkFace(category)) ?? fallback.cjkFaceId
            let latinWeight = AppFontWeight(rawValue: defaults.integer(forKey: Keys.weight(category))) ?? fallback.latinWeight
            let cjkWeight = AppFontWeight(rawValue: defaults.integer(forKey: Keys.cjkWeight(category))) ?? fallback.cjkWeight
            storedSelections[category] = AppFontSelection(latinFaceId: latinFace,
                                                          latinWeight: latinWeight,
                                                          cjkFaceId: cjkFace,
                                                          cjkWeight: cjkWeight)
        }
        // Both switches default ON — a stored `false` is the only way to turn
        // them off, and `object(forKey:)` is the only way to tell "off" from
        // "never set" for a Bool.
        storedTakeOver = defaults.object(forKey: Keys.takeOver) as? Bool ?? true
        storedLendCJK = defaults.object(forKey: Keys.lendCJK) as? Bool ?? true
    }

    // MARK: Reading

    /// Bumped on every change; `AppFont` folds it into its cache key, which is
    /// what makes a change take effect on the very next font request.
    var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedGeneration
    }

    func selection(for category: AppFontCategory) -> AppFontSelection {
        lock.lock()
        defer { lock.unlock() }
        return storedSelections[category] ?? category.defaultSelection
    }

    /// Replace every canvas with the shipped default. Imported faces stay in
    /// the library — resetting choices must not delete the user's files.
    func resetToDefaults() {
        lock.lock()
        for category in AppFontCategory.allCases {
            storedSelections[category] = category.defaultSelection
        }
        storedTakeOver = true
        storedLendCJK = true
        storedGeneration &+= 1
        lock.unlock()
        let defaults = UserDefaults.standard
        for category in AppFontCategory.allCases {
            defaults.removeObject(forKey: Keys.face(category))
            defaults.removeObject(forKey: Keys.weight(category))
            defaults.removeObject(forKey: Keys.cjkFace(category))
            defaults.removeObject(forKey: Keys.cjkWeight(category))
        }
        defaults.removeObject(forKey: Keys.takeOver)
        defaults.removeObject(forKey: Keys.lendCJK)
        notifyChanged()
    }

    // MARK: Writing

    func set(_ selection: AppFontSelection, for category: AppFontCategory) {
        lock.lock()
        guard storedSelections[category] != selection else {
            lock.unlock()
            return
        }
        storedSelections[category] = selection
        storedGeneration &+= 1
        lock.unlock()
        let defaults = UserDefaults.standard
        defaults.set(selection.latinFaceId, forKey: Keys.face(category))
        defaults.set(selection.latinWeight.rawValue, forKey: Keys.weight(category))
        defaults.set(selection.cjkFaceId, forKey: Keys.cjkFace(category))
        defaults.set(selection.cjkWeight.rawValue, forKey: Keys.cjkWeight(category))
        notifyChanged()
    }

    /// Take over the app's default text font.
    ///
    /// ON is what "make that the default" means: SwiftUI `Text` with no
    /// `.font()` inherits nothing, so without this the majority of the app keeps
    /// rendering in SF no matter what the library says. Turning it off is the
    /// A/B switch for anything that looks wrong.
    var takeOverAppText: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedTakeOver
        }
        set {
            lock.lock()
            guard storedTakeOver != newValue else {
                lock.unlock()
                return
            }
            storedTakeOver = newValue
            storedGeneration &+= 1
            lock.unlock()
            UserDefaults.standard.set(newValue, forKey: Keys.takeOver)
            notifyChanged()
        }
    }

    /// Let 方正宋三简体 borrow 思源宋体's weight.
    ///
    /// 方正宋三简体 ships ONE face, so a Chinese title either stays Regular or
    /// is synthesised into a smear — iOS does not synthesise bold for a custom
    /// font at all, so in practice it stays Regular. With this on, any weight
    /// above Regular on a single-face CJK font is served by the multi-weight
    /// Song face, with the chosen face kept directly behind it in the cascade so
    /// every character it can draw still comes from it. Both faces are Song, so
    /// the change is a weight, not a change of voice.
    var lendsCJKWeight: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedLendCJK
        }
        set {
            lock.lock()
            guard storedLendCJK != newValue else {
                lock.unlock()
                return
            }
            storedLendCJK = newValue
            storedGeneration &+= 1
            lock.unlock()
            UserDefaults.standard.set(newValue, forKey: Keys.lendCJK)
            notifyChanged()
        }
    }

    /// Drop choices that point at a face which is not (or no longer) available.
    ///
    /// An imported face can disappear between launches; the alternative to this
    /// is a picker that shows a face id nobody can render, and a stack that
    /// quietly falls back at every draw.
    func repairSelections() {
        var repaired: [AppFontCategory: AppFontSelection] = [:]
        var didChange = false
        lock.lock()
        for category in AppFontCategory.allCases {
            var selection = storedSelections[category] ?? category.defaultSelection
            let fallback = category.defaultSelection
            if AppFontLibrary.face(id: selection.latinFaceId) == nil {
                selection.latinFaceId = fallback.latinFaceId
                didChange = true
            }
            if AppFontLibrary.face(id: selection.cjkFaceId) == nil {
                selection.cjkFaceId = fallback.cjkFaceId
                didChange = true
            }
            repaired[category] = selection
        }
        if didChange {
            storedSelections = repaired
            storedGeneration &+= 1
        }
        lock.unlock()
        guard didChange else { return }
        let defaults = UserDefaults.standard
        for (category, selection) in repaired {
            defaults.set(selection.latinFaceId, forKey: Keys.face(category))
            defaults.set(selection.cjkFaceId, forKey: Keys.cjkFace(category))
        }
        notifyChanged()
    }

    private func notifyChanged() {
        objectWillChange.send()
        NotificationCenter.default.post(name: .appFontSettingsChanged, object: nil)
        // The chat caches (AIChatViewModel, CollectionViewMessageListV3) already
        // listen for this one to throw away rendered markdown and heights. A
        // font change is the same event as a size change from their point of
        // view: everything measured with the old font is now wrong.
        NotificationCenter.default.post(name: .fontSettingsMessageBaseChanged, object: nil)
    }
}
