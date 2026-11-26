import XCTest

final class MetronomeUITests: XCTestCase {
    @MainActor
    func testTempoControlsPlaybackAndAccent() throws {
        let app = launch()
        let tempo = app.descendants(matching: .any)["tempo-dial"].firstMatch
        XCTAssertTrue(tempo.waitForExistence(timeout: 15))
        let oldTempo = try XCTUnwrap(tempo.value as? String)
        app.buttons["Increase tempo by one beat per minute"].tap()
        XCTAssertNotEqual(tempo.value as? String, oldTempo)
        app.buttons["Decrease tempo by one beat per minute"].tap()
        XCTAssertEqual(tempo.value as? String, oldTempo)

        let tapTempo = app.buttons["tap-tempo"]
        tapTempo.tap()
        XCTAssertEqual(tapTempo.label, "Keep Tapping")
        let reset = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Tap Tempo"), object: tapTempo)
        XCTAssertEqual(XCTWaiter.wait(for: [reset], timeout: 6), .completed)

        let accent = app.buttons["Beat 1"]
        let previous = try XCTUnwrap(accent.value as? String)
        accent.tap()
        XCTAssertNotEqual(accent.value as? String, previous)

        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 6))
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 6))
    }

    @MainActor
    func testTimeSignatureRhythmSoundAndPresetSheets() {
        let app = launch()
        let meter = app.buttons["meter-option"]
        let rhythm = app.buttons["rhythm-option"]
        XCTAssertTrue(meter.waitForExistence(timeout: 15))
        XCTAssertTrue(rhythm.isHittable)
        XCTAssertLessThan(meter.frame.maxX, rhythm.frame.minX)
        XCTAssertEqual(meter.frame.midY, rhythm.frame.midY, accuracy: 2)

        meter.tap()
        let sixEight = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "6/8")).firstMatch
        XCTAssertTrue(sixEight.waitForExistence(timeout: 5))
        sixEight.tap()
        XCTAssertEqual(meter.value as? String, "6/8")

        rhythm.tap()
        let eighth = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Eighth Note")).firstMatch
        XCTAssertTrue(eighth.waitForExistence(timeout: 5))
        eighth.tap()
        XCTAssertEqual(rhythm.value as? String, "Eighth Note")

        app.buttons["Settings"].tap()
        let sound = app.buttons["settings-sound-option"]
        XCTAssertTrue(sound.waitForExistence(timeout: 6))
        sound.tap()
        let beep = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Beep")).firstMatch
        XCTAssertTrue(beep.waitForExistence(timeout: 5))
        beep.tap()
        XCTAssertEqual(sound.value as? String, "Beep")
        app.buttons["Done"].tap()

        app.buttons["presets-button"].tap()
        XCTAssertTrue(app.buttons["Save Current Settings"].waitForExistence(timeout: 6))
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.bytereset.metronome")
        app.launchArguments = ["--metronome-layout-preview", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }
}

