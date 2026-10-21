import XCTest

/// UI tests against a fake, self-contained environment: a temporary AVD folder with two
/// devices and a minimal fake SDK, so they behave the same on any Mac or CI runner and never
/// touch real devices or the network-dependent setup paths.
@MainActor
final class MoorboxUITests: XCTestCase {
    private var root: URL!
    private var avdHome: URL {
        root.appendingPathComponent("avd")
    }

    private var sdk: URL {
        root.appendingPathComponent("sdk")
    }

    override func setUp() async throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("moorbox-uitests-\(UUID().uuidString)")
        try makeFakeSDK()
        try makeDevice(id: "UI_Test_Phone", name: "UI Test Phone")
        try makeDevice(id: "UI_Tablet", name: "UI Tablet", landscape: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// An SDK that passes the health check (real Mach-O binaries) but has no system images
    /// and no cmdline-tools, so nothing can actually boot or be installed.
    private func makeFakeSDK() throws {
        let fm = FileManager.default
        for (dir, name) in [("emulator", "emulator"), ("platform-tools", "adb")] {
            let folder = sdk.appendingPathComponent(dir)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(atPath: "/usr/bin/true", toPath: folder.appendingPathComponent(name).path)
        }
        try "Pkg.Revision=36.5.11\n".write(to: sdk.appendingPathComponent("emulator/source.properties"), atomically: true, encoding: .utf8)
    }

    private func makeDevice(id: String, name: String, landscape: Bool = false) throws {
        let dir = avdHome.appendingPathComponent("\(id).avd")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "avd.ini.encoding=UTF-8\npath=\(dir.path)\ntarget=android-36\n"
            .write(to: avdHome.appendingPathComponent("\(id).ini"), atomically: true, encoding: .utf8)
        try """
        avd.ini.displayname=\(name)
        hw.ramSize=2048
        hw.cpu.ncore=2
        hw.lcd.width=1080
        hw.lcd.height=2400
        hw.lcd.density=420
        hw.initialOrientation=\(landscape ? "landscape" : "portrait")
        image.sysdir.1=system-images/android-36/google_apis/arm64-v8a/
        tag.display=Google APIs
        """.write(to: dir.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
    }

    private func launch(setupCompleted: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ANDROID_AVD_HOME"] = avdHome.path
        // NSArgumentDomain overrides user defaults for this launch only.
        app.launchArguments += [
            "-setupCompleted",
            setupCompleted ? "YES" : "NO",
            "-sdkPath",
            sdk.path,
            "-ApplePersistenceIgnoreState",
            "YES",
        ]
        app.launch()
        return app
    }

    /// `waitForExistence` returns as soon as an element exists, so it can't check dismissal.
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "device.\(id)").firstMatch
    }

    // MARK: Tests

    func testFirstRunShowsSetupAssistant() {
        let app = launch(setupCompleted: false)
        XCTAssertTrue(app.staticTexts["Welcome to Moorbox"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Check this Mac"].exists)
        app.buttons["Done"].click()
        XCTAssertTrue(waitForDisappearance(app.staticTexts["Welcome to Moorbox"]))
    }

    func testDevicesAreListedFromTheAVDFolder() {
        let app = launch()
        XCTAssertTrue(row(app, "UI_Test_Phone").waitForExistence(timeout: 10))
        XCTAssertTrue(row(app, "UI_Tablet").exists)
        XCTAssertTrue(row(app, "UI_Test_Phone").staticTexts["UI Test Phone"].exists)
        XCTAssertTrue(row(app, "UI_Test_Phone").staticTexts["Stopped"].exists)
        XCTAssertTrue(row(app, "UI_Test_Phone").buttons["Start"].exists)
        // The device icon is decorative and hidden from VoiceOver.
        XCTAssertEqual(row(app, "UI_Test_Phone").images.count, 0)
    }

    func testSidebarNavigation() {
        let app = launch()
        XCTAssertTrue(row(app, "UI_Test_Phone").waitForExistence(timeout: 10))
        app.descendants(matching: .any).matching(identifier: "sidebar.apps").firstMatch.click()
        XCTAssertTrue(app.staticTexts["No running device"].waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "sidebar.diagnostics").firstMatch.click()
        XCTAssertTrue(app.staticTexts["This Mac"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Check adb connection"].exists)
        app.descendants(matching: .any).matching(identifier: "sidebar.devices").firstMatch.click()
        XCTAssertTrue(row(app, "UI_Test_Phone").waitForExistence(timeout: 5))
    }

    func testNewDeviceExplainsMissingTools() {
        let app = launch()
        XCTAssertTrue(row(app, "UI_Test_Phone").waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        // The fake SDK has no command-line tools and no images, so creation is gated with a reason.
        XCTAssertTrue(app.staticTexts["Can’t create devices yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Setup Assistant"].exists)
        app.buttons["Cancel"].click()
    }

    func testStartingWithMissingSystemImageReportsTheProblem() {
        let app = launch()
        let phone = row(app, "UI_Test_Phone")
        XCTAssertTrue(phone.waitForExistence(timeout: 10))
        phone.buttons["Start"].click()
        XCTAssertTrue(app.staticTexts["Failed to run"].waitForExistence(timeout: 5))
        let detail = app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'system image this device uses is not installed'"))
        XCTAssertTrue(detail.firstMatch.waitForExistence(timeout: 5))
        // Nothing was deleted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: avdHome.appendingPathComponent("UI_Test_Phone.avd/config.ini").path))
    }

    func testRenameUpdatesTheDeviceOnDisk() throws {
        let app = launch()
        let phone = row(app, "UI_Test_Phone")
        XCTAssertTrue(phone.waitForExistence(timeout: 10))
        phone.rightClick()
        app.menuItems["Rename…"].click()
        let field = app.textFields["rename.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        // Paste instead of typeText: typing is unreliable with some keyboard input sources.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Renamed Phone", forType: .string)
        field.typeKey("v", modifierFlags: .command)
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Renamed Phone"].waitForExistence(timeout: 5))
        let config = try String(contentsOf: avdHome.appendingPathComponent("UI_Test_Phone.avd/config.ini"), encoding: .utf8)
        XCTAssertTrue(config.contains("avd.ini.displayname=Renamed Phone"))
    }

    func testDeleteAsksForConfirmation() {
        let app = launch()
        let tablet = row(app, "UI_Tablet")
        XCTAssertTrue(tablet.waitForExistence(timeout: 10))
        tablet.rightClick()
        app.menuItems["Delete…"].click()
        XCTAssertTrue(app.buttons["Move to Trash"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: []) // Escape = Cancel in a confirmation dialog
        XCTAssertTrue(waitForDisappearance(app.buttons["Move to Trash"]))
        XCTAssertTrue(tablet.exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: avdHome.appendingPathComponent("UI_Tablet.avd").path))
    }

    func testDeviceMenuReflectsSelection() {
        let app = launch()
        let phone = row(app, "UI_Test_Phone")
        XCTAssertTrue(phone.waitForExistence(timeout: 10))
        phone.click()
        let menu = app.menuBars.menuBarItems["Device"]
        menu.click()
        XCTAssertTrue(app.menuItems["Start"].isEnabled)
        XCTAssertFalse(app.menuItems["Rotate"].isEnabled) // not running
        XCTAssertFalse(app.menuItems["Take Screenshot"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }
}
