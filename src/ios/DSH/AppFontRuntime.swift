//
//  AppFontRuntime.swift
//  Minis
//
//  Making the chosen stack the app's DEFAULT, rather than one more face a few
//  call sites opt into.
//
//  THE PROBLEM THIS SOLVES
//  ---------------------------------------------------------------------------
//  A SwiftUI `Text` with no `.font()` inherits nothing custom — it renders in
//  the system font whatever `AppFont` says. That is why the custom stack looked
//  like it only reached the chat: the chat views call `AppFont.ui()` explicitly,
//  and everything else (settings rows, panels, sheets, UIKit-backed lists) never
//  asked. Two mechanisms close the gap:
//
//    1. `\.font` in the environment, set ONCE at the app root. Every `Text`
//       that does not set its own font inherits it, i.e. the majority of the
//       app, with no edits at those call sites.
//    2. UIKit appearance proxies, set before the first view is built. SwiftUI's
//       environment does not reach UIKit: navigation bar titles, bar buttons,
//       tab bar items, segmented controls and plain `UILabel`s are styled by
//       their own defaults.
//
//  WHERE THIS STOPS, HONESTLY
//  ---------------------------------------------------------------------------
//  A call site that hard-codes `.font(.system(size:…))` or `.font(.caption)`
//  still wins over the environment — there are ~1,300 such call sites in this
//  codebase, mostly in debug and browser screens. They are not rewritten here;
//  the environment change covers what those views did NOT specify, and the
//  categories cover the chat/agent surfaces that matter most. Making the whole
//  tree obey would need every one of those sites edited, which is a different
//  change with a different risk profile.
//
//  HOT RELOAD
//  ---------------------------------------------------------------------------
//  A choice change posts `.appFontSettingsChanged`. This file listens and
//  (a) rebuilds the appearance proxies, and (b) walks the live view hierarchy
//  and restyles labels/fields that are still on a SYSTEM font. (b) is what makes
//  the change visible on screens that are already on screen, without a
//  relaunch. Labels that were deliberately given a font — including monospaced
//  ones, which is how code and counters protect themselves — are left alone.
//
//  A restart can still be needed for UIKit chrome that was already laid out when
//  the change happened, because a navigation bar does not re-read the appearance
//  proxy for a title it has already measured. The screen says so.
//

import Foundation
import UIKit

enum AppFontRuntime {

    // MARK: - Install

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false

    /// Called once from `MinisApp.init`, before any view exists.
    static func install() {
        lock.lock()
        if installed {
            lock.unlock()
            return
        }
        installed = true
        lock.unlock()

        // Imported fonts first: their faces have to be resolvable before the
        // appearance proxies ask for them, and a stored choice that points at
        // one must not be repaired away just because this process has not
        // registered the file yet.
        AppFontLibrary.restoreImportedFonts()
        AppFontStore.shared.repairSelections()

        applyUIKitAppearance()

        // The tokens are discarded on purpose: this observer lives for the
        // lifetime of the process, and `install()` runs exactly once.
        _ = NotificationCenter.default.addObserver(forName: .appFontSettingsChanged,
                                                   object: nil,
                                                   queue: .main) { _ in
            applyUIKitAppearance()
            refreshLiveUIKitFonts()
        }
        // A system Dynamic Type change re-scales the environment font through
        // SwiftUI, but the UIKit proxies were computed at the old size and have
        // to be recomputed or the chrome would keep the old point size.
        _ = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification,
                                                   object: nil,
                                                   queue: .main) { _ in
            applyUIKitAppearance()
            refreshLiveUIKitFonts()
        }
    }

    // MARK: - UIKit appearance

    /// Style the UIKit chrome from the `ui`/`title` categories.
    ///
    /// `UILabel.appearance().font` etc. only apply to views created AFTER the
    /// proxy is set, which is why this runs from `init` and why a change also
    /// runs `refreshLiveUIKitFonts`.
    static func applyUIKitAppearance() {
        let takeOver = AppFontStore.shared.takeOverAppText

        let barTitle = AppFont.chrome(UIFontMetrics(forTextStyle: .headline).scaledValue(for: 17), weight: .semibold)
        let largeTitle = AppFont.title(UIFontMetrics(forTextStyle: .largeTitle).scaledValue(for: 34), weight: .bold)
        let barItem = AppFont.chrome(UIFontMetrics(forTextStyle: .body).scaledValue(for: 17))
        let small = AppFont.chrome(UIFontMetrics(forTextStyle: .footnote).scaledValue(for: 13))
        let tab = AppFont.chrome(UIFontMetrics(forTextStyle: .caption2).scaledValue(for: 10))
        let body = AppFont.ui(UIFontMetrics(forTextStyle: .body).scaledValue(for: 17))

        if takeOver {
            UINavigationBar.appearance().titleTextAttributes = [.font: barTitle]
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: largeTitle]
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: barItem], for: .normal)
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: barItem], for: .highlighted)
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: barItem], for: .disabled)
            UISegmentedControl.appearance().setTitleTextAttributes([.font: small], for: .normal)
            UITabBarItem.appearance().setTitleTextAttributes([.font: tab], for: .normal)
            UITabBarItem.appearance().setTitleTextAttributes([.font: tab], for: .selected)
            UILabel.appearance().font = body
            UITextField.appearance().font = body
            UITextView.appearance().font = body
        } else {
            UINavigationBar.appearance().titleTextAttributes = nil
            UINavigationBar.appearance().largeTitleTextAttributes = nil
            UIBarButtonItem.appearance().setTitleTextAttributes(nil, for: .normal)
            UIBarButtonItem.appearance().setTitleTextAttributes(nil, for: .highlighted)
            UIBarButtonItem.appearance().setTitleTextAttributes(nil, for: .disabled)
            UISegmentedControl.appearance().setTitleTextAttributes(nil, for: .normal)
            UITabBarItem.appearance().setTitleTextAttributes(nil, for: .normal)
            UITabBarItem.appearance().setTitleTextAttributes(nil, for: .selected)
            UILabel.appearance().font = nil
            UITextField.appearance().font = nil
            UITextView.appearance().font = nil
        }

        AppFontLog.log.info("[AppFont] appearance applied takeOver=\(takeOver)"
            + " navTitle=\(barTitle.fontName) body=\(body.fontName)")
    }

    // MARK: - Live restyle

    /// Restyle what is already on screen.
    ///
    /// Only views still on a SYSTEM font are touched: any label that was given a
    /// face on purpose — monospaced counters, code, SF-Symbol-bearing labels —
    /// keeps it. This is the difference between "the app now uses the chosen
    /// stack" and "the app guessed at every font in the hierarchy".
    static func refreshLiveUIKitFonts() {
        guard AppFontStore.shared.takeOverAppText else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { refreshLiveUIKitFonts() }
            return
        }
        var touched = 0
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                touched += restyle(window)
            }
        }
        if touched > 0 {
            AppFontLog.log.info("[AppFont] restyled \(touched) live UIKit text view(s)")
        }
    }

    @discardableResult
    private static func restyle(_ view: UIView) -> Int {
        var count = 0
        if let label = view as? UILabel, label.attributedText == nil, let font = label.font,
           isSystemFont(font) {
            label.font = AppFont.ui(font.pointSize)
            count += 1
        }
        if let field = view as? UITextField, let font = field.font, isSystemFont(font) {
            field.font = AppFont.ui(font.pointSize)
            count += 1
        }
        if let text = view as? UITextView, !text.isEditable, let font = text.font, isSystemFont(font) {
            // Editable text views belong to the composer and the terminal; both
            // set their own face and are not this function's business.
            text.font = AppFont.ui(font.pointSize)
            count += 1
        }
        if let control = view as? UISegmentedControl,
           control.titleTextAttributes(for: .normal)?[.font] == nil {
            control.setTitleTextAttributes([.font: AppFont.chrome(13)], for: .normal)
        }
        for subview in view.subviews {
            count += restyle(subview)
        }
        return count
    }

    /// A font the system supplied, rather than one a call site chose.
    ///
    /// System faces are private-named (`.SFUI-Regular`, `.AppleSystemUIFont`);
    /// the monospaced ones are excluded on purpose, because "Menlo"/".SFMono" in
    /// this app means "this text is code or a number that must line up".
    private static func isSystemFont(_ font: UIFont) -> Bool {
        let name = font.fontName
        if AppFontLibrary.ownedPostScriptNames.contains(name) { return false }
        if font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) { return false }
        if name.hasPrefix(".") { return true }
        let family = font.familyName
        return family.hasPrefix(".") || family == "System Font" || family == "SF Pro Text"
            || family == "SF Pro Display" || family == "System"
    }
}
