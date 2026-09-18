import XCTest

// XCTest is required by Apple's UI automation runner and VoiceOver service.
@MainActor
final class SelectionAccessibilityTests: XCTestCase {
    func testNativeMenuAppliesAndRemovesSelectionOnce() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        app.activate()
        XCTAssertTrue(app.menuButtons["labels-menu"].waitForExistence(timeout: 5))
        app.menuButtons["labels-menu"].click()
        app.menuItems["Linux"].click()
        XCTAssertEqual(app.staticTexts["selection-count"].value as? String, "Selected: 3 of 3")
        XCTAssertEqual(app.staticTexts["command-count"].value as? String, "Commands: 1")
        app.menuButtons["labels-menu"].click()
        app.menuItems["Linux"].click()
        XCTAssertEqual(app.staticTexts["selection-count"].value as? String, "Selected: 0 of 3")
        XCTAssertEqual(app.staticTexts["command-count"].value as? String, "Commands: 2")
    }

    func testVoiceOverReadsTheNativeLabelMenu() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        app.activate()
        XCTAssertTrue(app.menuButtons["labels-menu"].waitForExistence(timeout: 5))
        let service = XCUIDevice.shared.voiceOverService
        let wasEnabled = service.isEnabled
        defer {
            if !wasEnabled {
                do { try service.disable() }
                catch { XCTFail("Could not restore VoiceOver: \(error)") }
            }
        }
        if !wasEnabled { try service.enable() }
        app.menuButtons["labels-menu"].click()
        var speech: [String] = []
        speech.append(try service.currentSpeech().utterance)
        // Bounded traversal avoids matching a stale utterance from another app.
        for _ in 0..<8 where !speech.contains(where: { $0.contains("Linux") }) {
            speech.append(try service.moveForward().utterance)
        }
        let transcript = XCTAttachment(string: speech.joined(separator: "\n"))
        transcript.name = "VoiceOver menu transcript"
        transcript.lifetime = .keepAlways
        add(transcript)
        XCTAssertTrue(speech.contains(where: { $0.contains("Linux") }), "VoiceOver did not read the label menu: \(speech)")
        app.typeKey(.escape, modifierFlags: [])
    }
}
