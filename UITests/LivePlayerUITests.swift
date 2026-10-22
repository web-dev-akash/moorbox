import XCTest

/// Opt-in UI test against a real emulator already running in embedded mode
/// (`-qt-hide-window -grpc-use-token`). Captures screenshots of the player window.
///
///     TEST_RUNNER_MOORBOX_LIVE_AVD_HOME=/path/to/avd/home TEST_RUNNER_MOORBOX_LIVE_DEVICE=<avd id> \
///       xcodebuild … -only-testing:MoorboxUITests/LivePlayerUITests test
@MainActor
final class LivePlayerUITests: XCTestCase {
    func testPlayerWindowShowsAndDrivesTheDevice() throws {
        let env = ProcessInfo.processInfo.environment
        guard let avdHome = env["MOORBOX_LIVE_AVD_HOME"], let deviceID = env["MOORBOX_LIVE_DEVICE"] else {
            throw XCTSkip("Set MOORBOX_LIVE_AVD_HOME and MOORBOX_LIVE_DEVICE to run against a live emulator.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["ANDROID_AVD_HOME"] = avdHome
        app.launchArguments += ["-setupCompleted", "YES", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let row = app.descendants(matching: .any).matching(identifier: "device.\(deviceID)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.buttons["Show"].waitForExistence(timeout: 30), "device should be running in embedded mode")
        row.buttons["Show"].click()

        let player = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", deviceID)).firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 20))
        let screen = player.images["Android device screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 20))
        // Wait for frames: the overlay disappears once the stream delivers.
        let starting = player.staticTexts["Starting Android…"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: starting)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 30), .completed)
        attach(player, "1-player")

        // Toolbar → device keys, and a tap on the screen.
        player.buttons["Home"].click()
        sleep(1)
        player.buttons["Recent apps"].click()
        sleep(2)
        attach(player, "2-recents")
        player.buttons["Home"].click()
        sleep(1)
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo:
            screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        )
        sleep(2)
        attach(player, "3-after-swipe-up")
        player.buttons["Home"].click()
    }

    /// Start from Moorbox → the player window opens and boots → closing it stops the device.
    func testStartOpensPlayerAndClosingTheWindowStopsTheDevice() throws {
        let env = ProcessInfo.processInfo.environment
        guard let avdHome = env["MOORBOX_LIVE_AVD_HOME"], let deviceID = env["MOORBOX_LIVE_DEVICE"],
              let sdk = env["MOORBOX_LIVE_SDK"] else {
            throw XCTSkip("Set MOORBOX_LIVE_AVD_HOME, MOORBOX_LIVE_DEVICE and MOORBOX_LIVE_SDK (device must be stopped).")
        }
        let app = XCUIApplication()
        app.launchEnvironment["ANDROID_AVD_HOME"] = avdHome
        app.launchArguments += ["-setupCompleted", "YES", "-displayInMoorbox", "YES", "-sdkPath", sdk, "-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let row = app.descendants(matching: .any).matching(identifier: "device.\(deviceID)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.buttons["Start"].waitForExistence(timeout: 10), "device must be stopped before this test")
        row.buttons["Start"].click()

        let player = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", deviceID)).firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 20), "Start should open the player window")
        let running = NSPredicate(format: "title CONTAINS 'Running'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: running, object: player)], timeout: 180), .completed)
        sleep(2)
        attach(player, "4-started-from-moorbox")

        player.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(row.staticTexts["Stopped"].waitForExistence(timeout: 120), "closing the player window should stop the device")
    }

    private func attach(_ window: XCUIElement, _ name: String) {
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
