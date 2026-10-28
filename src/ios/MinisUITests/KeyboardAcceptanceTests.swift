import XCTest

/// Keyboard acceptance for the `/` menu and for the composer it lives in.
///
/// WHY XCUITEST AND NOT THE DEVICE
/// -------------------------------
/// The device-side runner (`ios-mcp press_key`) goes through an IOHID usage table:
/// it has no `escape` at all, and the last round showed `down` arriving while `up`
/// left the frame byte-identical (handover §4). That is either a mapping gap in the
/// runner or a real bug in the app, and only a driver that sends REAL key events can
/// tell the two apart. `XCUIElement.typeKey(_:modifierFlags:)` is that driver.
///
/// WHICH CODE PATH EACH CASE REACHES
/// ---------------------------------
/// The app answers these keys two ways:
///   * iOS 17+ — `onKeyPress` on the menu (`DSHRemoteComposer.slashMenu(query:)`)
///   * iOS 15/16 — `UIKeyCommand`s on the composer's text view, which call the
///     optional `onReturnIntercept` / `onEscape` / `onArrowUp` / `onArrowDown` hooks
///
/// A simulator on the iOS 26 runtime reaches **only the first**. The second is what
/// the iPhone 13 (iOS 15.3.1) actually runs, and there is currently no iOS 15/16
/// simulator runtime on the build machine — so C25 in the acceptance matrix stays
/// unverifiable until one is installed. Do not read a green run of this suite as
/// proof that the `UIKeyCommand` path works.
///
/// BOTH CASES SKIP BY DEFAULT
/// --------------------------
/// A UI suite must not depend on a paired host, a seeded conversation or a fixture
/// that may not be there: a red build caused by a missing fixture teaches people to
/// ignore the suite. `MINIS_KB_REMOTE=1` / `MINIS_KB_LOCAL=1` opt in, and a missing
/// fixture is a SKIP with the reason in the log, never a failure.
///
/// HOW TO RUN (simulator, macOS host)
/// ----------------------------------
///   MINIS_KB_LOCAL=1  xcodebuild test -scheme Minis \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///     -only-testing:MinisUITests/KeyboardAcceptanceTests/testLocalComposerDoesNotRegress
///
///   MINIS_KB_REMOTE=1 xcodebuild test … \
///     -only-testing:MinisUITests/KeyboardAcceptanceTests/testRemoteSlashMenuArrowKeys
///
/// Under `xcodebuild test` the runner strips a `TEST_RUNNER_` prefix, so a shell
/// `TEST_RUNNER_MINIS_KB_REMOTE=1` reaches this process as `MINIS_KB_REMOTE=1`.
///
/// THE REMOTE CASE EXPECTS A **PAIRED** SIMULATOR. The fixture supplies only the
/// Session id to open — never a transcript, never credentials. That is deliberate:
/// a test entry point that can fabricate a whole remote Session from a base64 blob
/// is indistinguishable from a backdoor to anyone reading the repo.
@MainActor
final class KeyboardAcceptanceTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - A. Remote `/` menu

    func testRemoteSlashMenuArrowKeys() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["MINIS_KB_REMOTE"] == "1",
                          "set MINIS_KB_REMOTE=1 on a PAIRED simulator to run the / menu key walk")

        let sessionId = try requireFixture("remote-session",
                                           hint: "one remote Session id (see Tests/fixtures/README.md)")

        app = XCUIApplication()
        app.launchArguments += ["-MINIS_DSH_AUTOSELECT", sessionId]
        app.launch()

        let composer = try remoteComposer()
        composer.tap()
        composer.typeText("/")

        let menu = slashMenu(timeout: 8)
        try XCTSkipIf(menu == nil,
                      "the / menu did not open — this simulator has no remote Session selected "
                      + "(autoselect got '\(sessionId)'), so the remote composer is not on screen")

        let rows = menu!.buttons
        XCTAssertGreaterThanOrEqual(rows.count, 2,
                                    "the menu opened with \(rows.count) row(s); arrows need at least 2")

        // Row 0 is selected on open. If this fails, the visible highlight and the
        // logical selection disagree, and every later assertion is meaningless.
        XCTAssertTrue(rows.element(boundBy: 0).isSelected,
                      "row 0 is not selected on open — the highlight does not follow `slashSelection`")

        // ↓ moves to row 1.
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(rows.element(boundBy: 1).isSelected, "↓ did not select the second row")

        // ↑ must come back. THIS is the assertion the device runner cannot make:
        // `press_key up` produced a byte-identical frame there.
        app.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(rows.element(boundBy: 0).isSelected, "↑ did not return to the first row")

        // Return executes the highlighted row: the draft becomes `/cmd` and NO
        // message is sent. The menu legitimately stays open (the new draft still
        // matches its own filter), so "menu closed" is the wrong assertion here.
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        let draft = (composer.value as? String) ?? ""
        XCTAssertTrue(draft.hasPrefix("/"),
                      "Return on a menu row did not put a command in the draft (got '\(draft)')")
        XCTAssertGreaterThan(draft.count, 1,
                             "Return left a bare '/' — the row's command was not executed")

        // Esc closes the menu without sending.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNil(slashMenu(timeout: 2), "Esc did not close the / menu")
        XCTAssertEqual((composer.value as? String) ?? "", "",
                       "Esc left the draft populated — it should clear it")
    }

    // MARK: - B. Local composer must not regress

    /// The interceptor exists so the menu can swallow Return FIRST. With no menu
    /// open every hook returns false, so Return must still mean "send" and
    /// Shift+Return must still mean "newline". That is the regression this case
    /// guards, and it needs NO pairing — only a local conversation.
    func testLocalComposerDoesNotRegress() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["MINIS_KB_LOCAL"] == "1",
                          "set MINIS_KB_LOCAL=1 in a simulator that can reach a local conversation")

        app = XCUIApplication()
        app.launch()

        let composer = try awaitLocalComposer()
        composer.tap()

        // 1. Return SENDS.
        composer.typeText("abc")
        app.typeKey(.return, modifierFlags: [])
        let sent = app.staticTexts["abc"].firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10),
                      "Return no longer sends in the local composer (no 'abc' bubble appeared)")
        XCTAssertEqual((composer.value as? String) ?? "", "",
                       "the draft survived a send")

        // 2. Shift+Return inserts a NEWLINE and does NOT send.
        composer.tap()
        composer.typeText("line1")
        app.typeKey(.return, modifierFlags: [.shift])
        composer.typeText("line2")
        let draft = (composer.value as? String) ?? ""
        XCTAssertTrue(draft.contains("line1") && draft.contains("line2"),
                      "Shift+Return lost the draft (got '\(draft)')")
        XCTAssertFalse(app.staticTexts["line1"].exists,
                       "Shift+Return SENT the message instead of inserting a newline")

        // 3. Esc dismisses the keyboard (and must not send).
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Esc no longer dismisses the keyboard")
    }

    // MARK: - Locating surfaces

    /// The remote composer is the accessory view under the transcript. Its own
    /// identifier is `dshComposer` (on the SwiftUI surface), but the element that
    /// accepts typing is the `UITextView` inside it — so try the identifier first
    /// and fall back to the first text view.
    private func remoteComposer() throws -> XCUIElement {
        let surface = app.otherElements["dshComposer"].firstMatch
        if surface.waitForExistence(timeout: 20) {
            let inner = surface.textViews.firstMatch
            if inner.exists { return inner }
        }
        let any = app.textViews.firstMatch
        guard any.waitForExistence(timeout: 20) else {
            throw XCTSkip("no text view on screen — the simulator is not showing a conversation")
        }
        return any
    }

    /// A local conversation's composer. The simulator has no hook that opens a local
    /// chat, so this tries the current screen, then the first row of the list, and
    /// SKIPS (with the reason) when neither gets there. A skip here is a real
    /// result: it says "this simulator cannot reach a local conversation", not
    /// "the composer is fine".
    private func awaitLocalComposer() throws -> XCUIElement {
        if app.textViews.firstMatch.waitForExistence(timeout: 6) {
            return app.textViews.firstMatch
        }
        // Cold start lands on the conversation list: open the first row.
        let cells = app.cells
        if cells.count > 0 {
            cells.element(boundBy: 0).tap()
            if app.textViews.firstMatch.waitForExistence(timeout: 8) {
                return app.textViews.firstMatch
            }
        }
        // A "new conversation" affordance, by the identifiers the app exposes.
        for id in ["newConversationButton", "newChatButton", "composeButton"] {
            let b = app.buttons[id].firstMatch
            if b.exists && b.isHittable {
                b.tap()
                if app.textViews.firstMatch.waitForExistence(timeout: 8) {
                    return app.textViews.firstMatch
                }
            }
        }
        throw XCTSkip("no local conversation reachable in this simulator "
                      + "(cells=\(cells.count), textViews=\(app.textViews.count)) — "
                      + "open a local chat first, then re-run")
    }

    /// Find the `/` menu by identifier, tolerating SwiftUI wrapping it in an
    /// `otherElement` or flattening it.
    private func slashMenu(timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let byID = app.descendants(matching: .any)
                .matching(identifier: KeyboardAcceptanceIDs.slashMenu).firstMatch
            if byID.exists { return byID }
            // The rows carry the visible selection; if the container identifier is
            // lost in a SwiftUI rewrite, a row with a command label still proves it.
            let slashRow = app.buttons.containing(
                NSPredicate(format: "label BEGINSWITH %@", "/")).firstMatch
            if slashRow.exists { return app.otherElements.firstMatch }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    // MARK: - Fixtures

    /// Reads a one-line fixture from `Tests/fixtures/<name>.txt` inside the test
    /// bundle. The folder is searched through the bundle's resource tree rather than
    /// a hard-coded subdirectory, because a synchronised Xcode folder group may
    /// flatten it. Absent or still holding the placeholder → SKIP, never fail.
    private func requireFixture(_ name: String, hint: String) throws -> String {
        guard let value = Self.fixtureValue(named: name) else {
            throw XCTSkip("fixture missing: Tests/fixtures/\(name).txt — needs \(hint)")
        }
        if value == "REPLACE_ME" {
            throw XCTSkip("fixture Tests/fixtures/\(name).txt still holds the placeholder — "
                          + "put \(hint) in it to run this case")
        }
        return value
    }

    private static func fixtureValue(named name: String) -> String? {
        let bundle = Bundle(for: KeyboardAcceptanceTests.self)
        let direct = [
            bundle.url(forResource: name, withExtension: "txt", subdirectory: "fixtures"),
            bundle.url(forResource: name, withExtension: "txt"),
        ].compactMap { $0 }
        // Flattened-folder fallback: walk the bundle for `<name>.txt`.
        var walked: [URL] = []
        if let root = bundle.resourceURL {
            let fm = FileManager.default
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let u as URL in e where u.lastPathComponent == "\(name).txt" {
                    walked.append(u)
                }
            }
        }
        for url in direct + walked {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let first = text.split(whereSeparator: \.isNewline).first {
                let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}

// MARK: - Accessibility identifiers this suite depends on

/// Kept next to the test so a rename in the app is one grep away.
///
/// `dshSlashMenu` is set at `DSHRemoteComposer.swift` on the menu's outer VStack;
/// `dshComposer` on the composer surface. Everything else asserted here is
/// behaviour (`isSelected`, the draft's text, the keyboard's existence), not pixels.
enum KeyboardAcceptanceIDs {
    static let slashMenu = "dshSlashMenu"
    static let composer = "dshComposer"
}
