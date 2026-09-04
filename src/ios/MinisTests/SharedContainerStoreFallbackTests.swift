import XCTest
@testable import Minis

final class SharedContainerStoreFallbackTests: XCTestCase {
    func testUsesAppGroupContainerWhenAvailable() {
        let group = URL(fileURLWithPath: "/tmp/group", isDirectory: true)
        let library = URL(fileURLWithPath: "/tmp/library", isDirectory: true)

        XCTAssertEqual(
            SharedContainerStore.resolvePersistentContainerRoot(
                appGroupContainer: group,
                libraryDirectory: library
            ),
            group
        )
    }

    func testFallsBackToAppLibraryWhenEntitlementIsUnavailable() {
        let library = URL(fileURLWithPath: "/tmp/library", isDirectory: true)

        XCTAssertEqual(
            SharedContainerStore.resolvePersistentContainerRoot(
                appGroupContainer: nil,
                libraryDirectory: library
            ),
            library.appendingPathComponent("MinisChat", isDirectory: true)
        )
    }
}
