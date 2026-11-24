import XCTest

final class MetronomeTests: XCTestCase {
    func testLegacySettingsAndPresetRoundTrip() throws { try MetronomeCoreChecks.checkSettingsMigration() }
    func testTapTempo() { MetronomeCoreChecks.checkTapTempo() }
    func testTempoDialDrag() { MetronomeCoreChecks.checkTempoDialDrag() }
    func testFractionalSampleTiming() { MetronomeCoreChecks.checkRenderTiming() }
    func testTrainingAndGhostBars() { MetronomeCoreChecks.checkTrainingAndGhostBars() }
    func testLiveTempoChange() { MetronomeCoreChecks.checkTempoChange() }
    func testSubdivisionOffsets() { MetronomeCoreChecks.checkSubdivisions() }
    func testLoudnessAndMixHeadroom() { MetronomeCoreChecks.checkLoudness() }
    func testVoiceAndBalance() { MetronomeCoreChecks.checkVoiceAndBalance() }
}
