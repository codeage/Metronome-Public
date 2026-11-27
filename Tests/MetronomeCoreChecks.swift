import Foundation

#if !XCODE_UNIT_TESTS
@main
#endif
struct MetronomeCoreChecks {
    static let sampleRate = 48_000.0

    #if !XCODE_UNIT_TESTS
    static func main() throws {
        try checkSettingsMigration()
        checkTapTempo()
        checkTempoDialDrag()
        checkRenderTiming()
        checkTrainingAndGhostBars()
        checkTempoChange()
        checkVoiceAndBalance()
        checkSubdivisions()
        checkLoudness()
        print("Metronome core checks passed.")
    }
    #endif

    static func checkTempoDialDrag() {
        let range = 30...250
        func point(at degrees: Double, radius: Double = 100) -> CGPoint {
            let angle = degrees * .pi / 180
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }

        precondition(TempoDialDrag.zeroAngle == 90)
        precondition(TempoDialDrag.progress(for: 0, in: range) == 0)
        precondition(TempoDialDrag.progress(for: 30, in: range) == 0.12)
        precondition(TempoDialDrag.progress(for: 125, in: range) == 0.5)
        precondition(TempoDialDrag.progress(for: 250, in: range) == 1)
        precondition(TempoDialDrag.progress(for: 150, in: 20...300) == 0.5)
        precondition(TempoDialDrag.progress(for: 300, in: 20...300) == 1)
        var drag = TempoDialDrag(tempo: 120, range: range, start: point(at: 175))
        precondition(drag.tempo == 120)
        drag.update(to: point(at: -175)) // Clockwise across atan2's wrap.
        precondition((121...135).contains(drag.tempo))
        drag.update(to: point(at: 175))
        precondition(drag.tempo == 120)

        var radial = TempoDialDrag(tempo: 120, range: range, start: point(at: 175))
        radial.update(to: point(at: 180, radius: 70))
        precondition(radial.tempo == 120)
        radial.update(to: .zero)
        radial.update(to: point(at: 50))
        precondition(radial.tempo == 120) // Re-anchor after a center crossing.

        for (limit, turn) in [(range.lowerBound, -20.0), (range.upperBound, 20.0)] {
            var edge = TempoDialDrag(tempo: limit, range: range, start: point(at: 90))
            edge.update(to: point(at: 90 + turn))
            precondition(edge.tempo == limit)
            edge.update(to: point(at: 90))
            precondition(edge.tempo != limit) // Reversing direction responds immediately.
        }
    }

    static func checkSettingsMigration() throws {
        precondition(BeatSettings(beats: 17, unit: 32).isValid)
        precondition(BeatSettings(beats: 32, unit: 64).isValid)
        let legacy = Data(#"{"bpm":275,"beats":6,"unit":8,"subdivision":3,"accent":false}"#.utf8)
        let migrated = try JSONDecoder().decode(BeatSettings.self, from: legacy)
        precondition(migrated.isValid && migrated.bpm == 275 && migrated.meter == "6/8")
        precondition(migrated.rhythm == .triplet && migrated.accents == Array(repeating: .weak, count: 6))
        var preset = MetronomePreset(id: UUID(), name: "练习曲", settings: migrated)
        preset.settings.beats = 32
        preset.settings.accents[31] = .silent
        preset.settings.sound = .voice
        preset.settings.rhythm = .swing
        let encoded = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(MetronomePreset.self, from: encoded)
        precondition(decoded == preset)
        let currentPreferences = MetronomePreferences()
        precondition(currentPreferences.volume == 1 && currentPreferences.flash)
        let data = try JSONEncoder().encode(currentPreferences)
        guard var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            preconditionFailure("Expected preference fields")
        }
        for oldLevel in [0.8, 0.25, 0.0] {
            fields["volume"] = oldLevel
            let oldData = try JSONSerialization.data(withJSONObject: fields)
            let migrated = try JSONDecoder().decode(MetronomePreferences.self, from: oldData)
            precondition(migrated.volume == oldLevel)
        }
        precondition(BeatSettings(subdivision: .min).rhythm == .quarter)
        precondition(BeatSettings().bpm == 120 && BeatSettings().meter == "4/4")
        precondition(BeatAccent.strong.next.next.next.next == .strong)
    }

    static func checkTapTempo() {
        var taps = TapTempo()
        precondition(taps.tap(at: 0, within: 30...250) == nil)
        precondition(taps.tap(at: 0.5, within: 30...250) == nil)
        precondition(taps.tap(at: 1, within: 30...250) == 120)
        precondition(taps.tap(at: 1.54, within: 30...250) == 117)
        precondition(taps.tap(at: 5, within: 30...250) == nil)

        var professional = TapTempo()
        precondition(professional.tap(at: 0, within: 20...300) == nil)
        precondition(professional.tap(at: 3, within: 20...300) == nil)
        precondition(professional.tap(at: 6, within: 20...300) == 20)
    }

    static func checkRenderTiming() {
        withRenderer { renderer in
            metronome_configure(renderer, configuration(bpm: 137))
            let events = renderEvents(renderer, seconds: 58)
            precondition(events.count == 133)
            for (index, event) in events.enumerated() {
                let ideal = Double(index) * 60 / 137
                precondition(abs(event.hostSeconds - (100 + ideal)) <= 1.00001 / sampleRate)
                precondition(event.beat == index % 4)
            }
            var event = MetronomeBeatEvent()
            precondition(!metronome_event_at(renderer, 99, &event))
            metronome_reset(renderer)
            precondition(!metronome_event_at(renderer, 200, &event))
        }
    }

    static func checkTrainingAndGhostBars() {
        withRenderer { renderer in
            var config = configuration(bpm: 200, beats: 2)
            config.trainerStart = 120
            config.trainerTarget = 130
            config.trainerStep = 5
            config.trainerBars = 1
            config.audibleBars = 1
            config.silentBars = 1
            config.accents = UInt64(BeatAccent.silent.rawValue) << 2
            metronome_configure(renderer, config)
            let events = renderEvents(renderer, seconds: 4)
            let expected: [UInt32] = [120, 120, 125, 125, 130, 130, 130, 130]
            precondition(events.prefix(8).map(\.bpm) == expected)
            precondition(events.prefix(8).map(\.ghost) == [false, false, true, true, false, false, true, true])
            precondition(events.prefix(8).map(\.audible) == [true, false, false, false, true, false, false, false])
            precondition(events[1].accent == UInt32(BeatAccent.silent.rawValue))
        }
    }

    static func checkTempoChange() {
        withRenderer { renderer in
            metronome_configure(renderer, configuration(bpm: 60))
            _ = renderEvents(renderer, seconds: 0.5)
            metronome_configure(renderer, configuration(bpm: 120))
            let events = renderEvents(renderer, seconds: 0.3, start: 0.5)
            let secondBeat = events.first { $0.beat == 1 }
            precondition(secondBeat?.bpm == 120)
            precondition(abs((secondBeat?.hostSeconds ?? 0) - 100.75) <= 1 / sampleRate)
        }
    }

    static func checkVoiceAndBalance() {
        withRenderer { renderer in
            var config = configuration(bpm: 120, beats: 1)
            config.sound = UInt32(BeatSound.voice.rawValue)
            config.balance = -1
            metronome_configure(renderer, config)
            let voice: [Float] = [0.1, 0.2, 0.4, 0.6]
            voice.withUnsafeBufferPointer {
                precondition(metronome_load_voice(renderer, 0, $0.baseAddress, UInt32($0.count)))
                precondition(!metronome_load_voice(renderer, 0, $0.baseAddress, UInt32($0.count)))
            }
            var left = Array(repeating: Float.zero, count: 4)
            var right = left
            metronome_render(renderer, &left, &right, 4, 100)
            precondition(left[2] > 0.7 && abs(left[3] - 0.98) < 0.00001)
            precondition(right.allSatisfy { $0 == 0 })
        }
    }

    static func checkSubdivisions() {
        let offsets: [[Int]] = [[], [12_000], [8_000, 16_000], [6_000, 12_000, 18_000],
                                [18_000], [6_000, 18_000], [16_000]]
        for rhythm in BeatRhythm.allCases {
            withRenderer { renderer in
                var config = configuration(bpm: 120)
                config.rhythm = UInt32(rhythm.rawValue)
                metronome_configure(renderer, config)
                var left = Array(repeating: Float.zero, count: 24_000)
                var right = left
                metronome_render(renderer, &left, &right, 24_000, 100)
                var detected: [Int] = []
                for frame in 4_000..<left.count where abs(left[frame]) > 0.025 {
                    if detected.last.map({ frame - $0 > 3_500 }) ?? true { detected.append(frame) }
                }
                let expected = offsets[rhythm.rawValue]
                precondition(detected.count == expected.count)
                precondition(zip(detected, expected).allSatisfy { abs($0 - $1) < 45 })
            }
        }
    }

    static func checkLoudness() {
        for sound in BeatSound.allCases {
            withRenderer { renderer in
                var config = configuration(bpm: 300, beats: 3)
                config.sound = UInt32(sound.rawValue)
                config.accents = 0b10_01_00
                if sound == .voice {
                    let voice: [Float] = [0.1, 0.2, 0.4, 0.6]
                    voice.withUnsafeBufferPointer { samples in
                        for beat in 0..<3 {
                            precondition(metronome_load_voice(renderer, UInt32(beat), samples.baseAddress, UInt32(samples.count)))
                        }
                    }
                }
                metronome_configure(renderer, config)
                let frames = 28_800
                var left = Array(repeating: Float.zero, count: frames)
                var right = left
                metronome_render(renderer, &left, &right, UInt32(frames), 100)
                let expected: [Float] = [0.98, 0.98 * 0.88, 0.98 * 0.75]
                for (beat, target) in expected.enumerated() {
                    let start = beat * 9_600
                    let end = start + 9_600
                    let peak = left[start..<end].map { abs($0) }.max() ?? 0
                    precondition(abs(peak - target) < 0.00001)
                }
            }
        }
        withRenderer { renderer in
            var config = configuration(bpm: 300, beats: 1)
            config.sound = UInt32(BeatSound.voice.rawValue)
            config.rhythm = UInt32(BeatRhythm.sixteenth.rawValue)
            metronome_configure(renderer, config)
            let voice = [Float](repeating: 0.3, count: 9_600)
            voice.withUnsafeBufferPointer {
                precondition(metronome_load_voice(renderer, 0, $0.baseAddress, UInt32($0.count)))
            }
            var left = [Float](repeating: 0, count: 9_600)
            var right = left
            metronome_render(renderer, &left, &right, 9_600, 100)
            let peak = left.map(abs).max() ?? 0
            precondition(peak > 0.98 && peak < 1)
        }
    }

    static func configuration(bpm: UInt32, beats: UInt32 = 4) -> MetronomeRenderSettings {
        var settings = MetronomeRenderSettings()
        settings.bpm = bpm
        settings.beats = beats
        settings.volume = 1
        return settings
    }

    static func withRenderer(_ body: (OpaquePointer) -> Void) {
        guard let renderer = metronome_create(sampleRate) else { fatalError("Renderer allocation failed") }
        defer { metronome_destroy(renderer) }
        body(renderer)
    }

    static func renderEvents(_ renderer: OpaquePointer, seconds: Double, start: Double = 0) -> [MetronomeBeatEvent] {
        let block = 113
        var left = Array(repeating: Float.zero, count: block)
        var right = left
        var events: [MetronomeBeatEvent] = []
        let count = Int(seconds * sampleRate)
        for first in stride(from: 0, to: count, by: block) {
            let frames = min(block, count - first)
            let host = 100 + start + Double(first) / sampleRate
            metronome_render(renderer, &left, &right, UInt32(frames), host)
            var event = MetronomeBeatEvent()
            if metronome_event_at(renderer, host + Double(frames - 1) / sampleRate + 0.000000001, &event),
               events.last?.serial != event.serial {
                events.append(event)
            }
        }
        return events
    }
}
