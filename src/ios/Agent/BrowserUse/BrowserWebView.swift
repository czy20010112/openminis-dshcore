import SwiftUI
import WebKit

/// UIViewRepresentable wrapper that displays a `BrowserUseManager`'s WKWebView.
///
/// [T-ios-browser-offwindow-load] This is the ONLY place a browser tab's
/// WKWebView gets a superview, so it is also the place that has to reconcile the
/// panel with the manager. Two hazards live here, and both look the same to the
/// user ("the browser opens and never loads"):
///
///  1. **Off-window load.** The manager's webView is created with a viewport-sized
///     frame but no superview, and `BrowserTabPool` starts loading it the moment
///     a tab exists. WebKit does not reliably commit a navigation for a webView
///     that is in no view hierarchy, so the load can be issued into the void.
///     `makeUIView` / `updateUIView` therefore tell the manager to reissue it.
///  2. **Stale instance.** `BrowserUseManager.setUserAgent` and `setViewport`
///     REPLACE `manager.webView` with a whole new WKWebView. `makeUIView` runs
///     once, so a panel that was already on screen keeps displaying the replaced
///     instance — blank, and never loading, while the agent drives the new one
///     happily. Presenting a second sheet "fixes" it only because that runs
///     `makeUIView` again and picks up the current instance. So `updateUIView`
///     also swaps the displayed view for the manager's current one.
struct BrowserWebView: UIViewRepresentable {
    let manager: BrowserUseManager

    func makeUIView(context: Context) -> WKWebView {
        let wv = manager.webView
        BrowserLoadLog.present(manager: manager, hook: "makeUIView")
        // First attach: recover a load that was issued with no window. This call
        // usually runs before the view is in a window (the panel logs `win=0`),
        // so ALSO schedule one attempt for the next runloop turn — by then
        // SwiftUI has attached it, and `updateUIView` remains the main trigger.
        // One-shot, and harmless when nothing is pending (the guard is a nil
        // check on `pendingOffWindowURL`).
        manager.retryPendingNavigationIfOffWindow()
        DispatchQueue.main.async { [weak manager] in
            manager?.retryPendingNavigationIfOffWindow()
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // [T-ios-browser-stale-webview] Reconcile a replaced webView. Without
        // this the panel shows a view the manager no longer loads into.
        if uiView !== manager.webView {
            let current = manager.webView
            BrowserLoadLog.instanceReplaced(manager: manager, displayed: uiView, current: current)
            if let parent = uiView.superview {
                parent.insertSubview(current, aboveSubview: uiView)
                current.frame = uiView.frame
            }
            uiView.removeFromSuperview()
        }
        // Cheap: returns immediately unless an off-window load is pending.
        manager.retryPendingNavigationIfOffWindow()
    }
}

/// [T-ios-browser-load-log] The `[Browser]` log family — presentation side.
/// Kept as one place so every entry point reports the same fields
/// (`present hook=… win=… hidden=… size=… super=…`), which is what makes two
/// different presentations of the same tab comparable in
/// `pull-device-log.ps1 -Pattern '\[Browser\]'`.
@MainActor
enum BrowserLoadLog {
    private static let logger = AppLogger(category: "BrowserUse")

    /// Log one presentation event for a tab. `hook` names the entry point
    /// (`makeUIView`, `sheet-appear`, `ui-panel`, `takeover-sheet`).
    static func present(manager: BrowserUseManager, hook: String) {
        let url = manager.currentURL
        logger.info("[Browser] present hook=\(hook) url=\(url.isEmpty ? "nil" : String(url.prefix(140))) \(manager.presentationState)")
    }

    /// [T-ios-browser-stale-webview] The panel was displaying a WKWebView the
    /// manager has already replaced (`setViewport` / `setUserAgent` create a new
    /// one). Logged with both object identities so this is never mistaken for an
    /// off-window load in the device log.
    static func instanceReplaced(manager: BrowserUseManager, displayed: WKWebView, current: WKWebView) {
        logger.warning("[Browser] stale_webview_swapped displayed=\(ObjectIdentifier(displayed)) current=\(ObjectIdentifier(current)) url=\(String(manager.currentURL.prefix(140))) displayedWin=\(displayed.window != nil ? 1 : 0) \(manager.presentationState)")
    }

    /// [T-ios-browser-offwindow-load] The other half of the same report: the
    /// panel opened with NO active manager, so `BrowserSheetView` rendered its
    /// `Color(.systemBackground)` placeholder and there is no webView to attach
    /// — a differently-rooted "opens to a dead panel" than the off-window case.
    /// Logged so the two are never confused in a device log.
    static func presentMissingManager(pool: BrowserTabPool, hook: String) {
        logger.warning("[Browser] present_no_manager hook=\(hook) tabs=\(pool.tabs.count) selected=\(pool.selectedTabId) — panel is showing the background placeholder, nothing to attach")
    }
}
