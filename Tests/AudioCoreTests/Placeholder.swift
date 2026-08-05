import Testing
@testable import AudioCore

@Test func levelMeterStartsSilent() {
    let meter = LevelMeter()
    #expect(meter.isDigitalSilence)
    #expect(meter.rms == 0)
}
