import XCTest

/// Acceptance walk for the DSH remote integration, driven by XCUITest because
/// `simctl` cannot tap, scroll or type.
///
/// Written by the verification line (approved by the lead): it only *observes*
/// the product — it never changes app behaviour. Screenshots land in the
/// simulator's `/tmp` (host side:
/// `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/tmp/*.png`).
///
/// Inputs (passed by `xcodebuild test` as `TEST_RUNNER_…`, which the runner
/// strips to the bare name):
///   DSH_INJECT_B64   base64 of the `DSHRemoteSession` JSON
///   DSH_SESSION_ID   the remote Session to open (also drives `-MINIS_DSH_AUTOSELECT`)
@MainActor
final class DSHRemoteAcceptance: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Harness

    private func launchRemoteSession() throws {
        let env = ProcessInfo.processInfo.environment
        let b64 = env["DSH_INJECT_B64"] ?? ""
        let session = env["DSH_SESSION_ID"] ?? "1"
        // SKIP, not fail: this case only means anything with a recorded Session
        // handed to it, and a CI run that merely builds or spot-runs the UI suite
        // must not go red because that fixture is absent. Manual run:
        //   TEST_RUNNER_DSH_INJECT_B64=… TEST_RUNNER_DSH_SESSION_ID=… xcodebuild test …
        try XCTSkipIf(b64.isEmpty, "acceptance walk needs TEST_RUNNER_DSH_INJECT_B64 (manual run only)")

        app = XCUIApplication()
        // System alerts (dictation / paste permission) would otherwise swallow the
        // tap that is supposed to hit Send.
        addUIInterruptionMonitor(withDescription: "system alert") { alert in
            for label in ["以后", "以后再说", "不允许", "Not Now", "Don’t Allow", "OK", "好"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launchArguments = [
            "-MINIS_DSH_SESSION_B64", b64,
            "-MINIS_DSH_AUTOSELECT", session,
        ]
        app.launch()
        // The stream's first snapshot, plus the list round-trip, need a moment.
        Thread.sleep(forTimeInterval: 8)
    }

    /// Screenshots go out as XCTAttachments: the test runner is a sandboxed app,
    /// so writing to `/tmp` lands in its own container and cannot be pulled off
    /// the device. Attachments end up in the `.xcresult` bundle on the Mac,
    /// where `xcrun xcresulttool export attachments` extracts them by name.
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Wait for the transcript instead of guessing a fixed delay: the first
    /// snapshot arrives asynchronously and the bridge needs a round-trip.
    @discardableResult
    private func waitForTranscript(timeout: TimeInterval = 40) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var count = app.staticTexts.count
        while Date() < deadline, count <= 5 {
            Thread.sleep(forTimeInterval: 0.5)
            count = app.staticTexts.count
        }
        print("[acceptance] transcript staticTexts=\(count) after \(Int(timeout - max(0, deadline.timeIntervalSinceNow)))s")
        return count
    }

    /// The transcript is a UICollectionView; fall back to the first scroll view,
    /// then the app itself, so a container rename does not break the walk.
    private var scroller: XCUIElement {
        let collection = app.collectionViews.firstMatch
        if collection.exists { return collection }
        let scroll = app.scrollViews.firstMatch
        if scroll.exists { return scroll }
        return app
    }

    private var textInput: XCUIElement? {
        let views = app.textViews
        if views.count > 0 { return views.element(boundBy: 0) }
        let fields = app.textFields
        if fields.count > 0 { return fields.element(boundBy: 0) }
        return nil
    }

    // MARK: - 1. Block sequence + system notice (issues 1 and 2)

    func testScrollAndBlocks() throws {
        try launchRemoteSession()
        shot("20-top")

        // A blank transcript would make every later shot meaningless.
        let texts = waitForTranscript()
        XCTAssertGreaterThan(texts, 5, "transcript looks empty — the snapshot never rendered")

        // Walk up through the turn: 思考块 → 正文 → 工具卡 → 思考块 …
        for index in 1...12 {
            scroller.swipeDown()
            Thread.sleep(forTimeInterval: 1.0)
            shot("21-scroll-\(index)")
            let hit = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "model switched")
            ).firstMatch
            print("[acceptance] scroll \(index): staticTexts=\(app.staticTexts.count) notice=\(hit.exists)")
            if hit.exists {
                shot("22-notice")
                break
            }
        }

        // The identity row must read `DSH`, not `Minis`.
        let dshRow = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "DSH")).firstMatch
        print("[acceptance] dshLabel exists=\(dshRow.exists) count=\(app.staticTexts.count)")

        // The notice must be a thin system line, not a user bubble.
        let notice = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "model switched")
        ).firstMatch
        print("[acceptance] notice exists=\(notice.exists)")
        if notice.exists {
            notice.tap()
            Thread.sleep(forTimeInterval: 0.6)
            shot("22-notice")
        }

        // Count user bubbles on the visible page (issue 1 criterion).
        let bubbles = app.cells.count
        print("[acceptance] visible cells=\(bubbles)")
        shot("23-blocks")
    }

    // MARK: - 2. Composer: type, send, watch the scripted turn (issue 3)

    func testSend() throws {
        try launchRemoteSession()

        guard let input = textInput else {
            XCTFail("no text input found in the composer")
            return
        }
        input.tap()
        Thread.sleep(forTimeInterval: 1.0)
        input.typeText("hello from the phone")
        shot("30-typed")

        // Send: named button first, then the paper-plane coordinate (keyboard up).
        var sent = false
        let named = app.buttons.matching(identifier: "sendButton").firstMatch
        if named.exists {
            named.tap()
            sent = true
        } else {
            // The send button is the bottom-right-most hittable button once the
            // keyboard pushes the composer up; a fixed normalized offset lands on
            // the keyboard instead (measured: the ↑ sits at ~0.43 of the height).
            app.tap()   // let the interruption monitor run once
            // Locate Send geometrically: it is the right-most button in the
            // composer row, i.e. within ~140 pt BELOW the text view's bottom.
            // (Picking "the right-most button" globally lands on the keyboard's
            // dictation key, which raises a system alert instead.)
            let row = app.buttons.allElementsBoundByIndex.filter {
                $0.isHittable && $0.frame.minY >= (input.frame.maxY - 8) && $0.frame.minY <= (input.frame.maxY + 140)
            }
            print("[acceptance] composerButtons=\(row.count) " +
                  row.map { "[\($0.label)|\($0.identifier)|\(NSCoder.string(for: $0.frame))]" }.joined())
            if let send = row.max(by: { $0.frame.maxX < $1.frame.maxX }) {
                print("[acceptance] sendButton label=\(send.label) frame=\(NSCoder.string(for: send.frame))")
                send.tap()
                sent = true
            } else {
                // Last resort: 30 pt in from the right edge, 40 pt under the field.
                let point = CGVector(dx: (app.frame.width - 30) / app.frame.width,
                                     dy: (input.frame.maxY + 40) / app.frame.height)
                print("[acceptance] send fallback point=\(point)")
                app.coordinate(withNormalizedOffset: point).tap()
                sent = true
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        print("[acceptance] sendTapped=\(sent)")
        shot("31-sent")

        Thread.sleep(forTimeInterval: 3)
        shot("32-streaming")
        Thread.sleep(forTimeInterval: 10)
        shot("33-done")
    }
}
