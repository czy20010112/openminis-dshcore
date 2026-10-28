import XCTest

/// Debug-only screen capture walk for the DSH remote integration.
/// Writes PNGs into the simulator's /tmp so they can be pulled off the host.
final class DSHRemoteScreens: XCTestCase {
    func testCaptureSidebarAndSettings() throws {
        // Opt-in only: a screen-capture walk is a manual tool, never a CI gate.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MINIS_SCREENS"] == "1",
                          "set MINIS_SCREENS=1 to run the capture walk")
        let app = XCUIApplication()
        app.launch()
        sleep(4)
        try shot("01-chat")

        // Back chevron, top-left.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.071)).tap()
        sleep(2)
        try shot("02-sidebar")

        // Trailing ellipsis menu.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.071)).tap()
        sleep(2)
        try shot("03-menu")
    }

    private func shot(_ name: String) throws {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let url = URL(fileURLWithPath: "/tmp/\(name).png")
        try png.write(to: url)
    }
}
