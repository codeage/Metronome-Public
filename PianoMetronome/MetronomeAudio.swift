import AVFoundation
import CoreHaptics
import Darwin
import QuartzCore
import UIKit

// Ownership remains stable for the AVAudioSourceNode block's lifetime.
// The bridge uses lock-free atomic snapshots for all concurrent access.
private final class RenderStorage: @unchecked Sendable {
    static let sampleRate = 48_000.0
    let pointer: OpaquePointer
    let secondsPerHostTick: Double

    init?() {
        guard let pointer = metronome_create(Self.sampleRate) else { return nil }
        self.pointer = pointer
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerHostTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    deinit { metronome_destroy(pointer) }

    func render(
        silence: UnsafeMutablePointer<ObjCBool>, timestamp: UnsafePointer<AudioTimeStamp>,
        frames: AVAudioFrameCount, output: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let output = UnsafeMutableAudioBufferListPointer(output)
        guard output.count == 2,
              let left = output[0].mData?.assumingMemoryBound(to: Float.self),
              let right = output[1].mData?.assumingMemoryBound(to: Float.self) else {
            return kAudio_ParamError
        }
        let stamp = timestamp.pointee
        let host = stamp.mFlags.contains(.hostTimeValid) ? Double(stamp.mHostTime) * secondsPerHostTick : -1
        metronome_render(pointer, left, right, frames, host)
        silence.pointee = false
        return noErr
    }
}

@MainActor
final class MetronomeAudio {
    private let storage: RenderStorage
    private let engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private let speech = AVSpeechSynthesizer()
    private var nextVoice = 0
    private var voiceBuffer: [Float] = []
    private var loadingVoice = false

    var isRunning: Bool { engine.isRunning }
    var outputLatency: TimeInterval { session.outputLatency }

    init?() {
        guard let storage = RenderStorage(),
              let format = AVAudioFormat(standardFormatWithSampleRate: RenderStorage.sampleRate, channels: 2)
        else { return nil }
        self.storage = storage
        let block: AVAudioSourceNodeRenderBlock = { @Sendable silence, timestamp, frames, output in
            storage.render(silence: silence, timestamp: timestamp, frames: frames, output: output)
        }
        let source = AVAudioSourceNode(format: format, renderBlock: block)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        speech.usesApplicationAudioSession = false
    }

    func configure(_ settings: BeatSettings, _ preferences: MetronomePreferences) {
        let accents = settings.accents.enumerated().reduce(UInt64(0)) { bits, entry in
            bits | (UInt64(entry.element.rawValue) << (entry.offset * 2))
        }
        let trainer = preferences.trainer
        let ghost = preferences.ghost
        let command = MetronomeRenderSettings(
            bpm: UInt32(settings.bpm), beats: UInt32(settings.beats),
            rhythm: UInt32(settings.rhythm.rawValue), sound: UInt32(settings.sound.rawValue),
            trainerStart: UInt32(trainer.start), trainerTarget: UInt32(trainer.target),
            trainerStep: UInt32(trainer.step), trainerBars: trainer.enabled ? UInt32(trainer.bars) : 0,
            audibleBars: ghost.enabled ? UInt32(ghost.audible) : 0,
            silentBars: ghost.enabled ? UInt32(ghost.silent) : 0,
            accents: accents, volume: Float(preferences.volume), balance: Float(preferences.balance)
        )
        metronome_configure(storage.pointer, command)
        if settings.sound == .voice { loadNextVoice() }
    }

    func start(mixing: Bool) throws {
        try session.setCategory(.playback, mode: .default, options: mixing ? [.mixWithOthers] : [])
        // The route may reject the preferred duration. Its actual latency remains authoritative.
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        metronome_reset(storage.pointer)
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop(deactivate: true)
            throw error
        }
    }

    func changeMixing(_ mixing: Bool) throws {
        try session.setCategory(.playback, mode: .default, options: mixing ? [.mixWithOthers] : [])
    }

    func stop(deactivate: Bool) {
        engine.stop()
        metronome_reset(storage.pointer)
        if deactivate { try? session.setActive(false, options: [.notifyOthersOnDeactivation]) }
    }

    func event(at time: TimeInterval) -> MetronomeBeatEvent? {
        var event = MetronomeBeatEvent()
        return metronome_event_at(storage.pointer, time, &event) ? event : nil
    }

    private func loadNextVoice() {
        guard !loadingVoice, nextVoice < 32 else { return }
        loadingVoice = true
        let utterance = AVSpeechUtterance(string: String(nextVoice + 1))
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.6
        speech.write(utterance) { @Sendable [weak self] audioBuffer in
            guard let pcm = audioBuffer as? AVAudioPCMBuffer else { return }
            let ended = pcm.frameLength == 0
            let samples = Self.monoSamples(pcm)
            DispatchQueue.main.async {
                self?.receiveVoice(samples, ended: ended)
            }
        }
    }

    private nonisolated static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return [] }
        let ratio = buffer.format.sampleRate / RenderStorage.sampleRate
        let outputCount = min(24_000, Int(Double(buffer.frameLength) / ratio))
        let stride = buffer.stride
        if let data = buffer.floatChannelData?[0] {
            return (0..<outputCount).map { data[Int(Double($0) * ratio) * stride] }
        }
        if let data = buffer.int16ChannelData?[0] {
            return (0..<outputCount).map { Float(data[Int(Double($0) * ratio) * stride]) / 32768 }
        }
        return []
    }

    private func receiveVoice(_ samples: [Float], ended: Bool) {
        if !ended {
            voiceBuffer.append(contentsOf: samples.prefix(24_000 - voiceBuffer.count))
            return
        }
        if let first = voiceBuffer.firstIndex(where: { abs($0) > 0.012 }) {
            let clipped = Array(voiceBuffer[max(0, first - 64)...])
            clipped.withUnsafeBufferPointer {
                _ = metronome_load_voice(storage.pointer, UInt32(nextVoice), $0.baseAddress, UInt32($0.count))
            }
        }
        voiceBuffer.removeAll(keepingCapacity: true)
        nextVoice += 1
        loadingVoice = false
        loadNextVoice()
    }
}

@MainActor
final class BeatDisplayLink: NSObject {
    private var link: CADisplayLink?
    var tick: ((TimeInterval) -> Void)?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        tick?(link.targetTimestamp)
    }
}

@MainActor
final class BeatHaptics {
    private var engine: CHHapticEngine?
    private var running = false
    private var patterns: [BeatAccent: CHHapticPattern] = [:]

    static var available: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    func start() {
        guard Self.available, !running else { return }
        do {
            let engine: CHHapticEngine
            if let existing = self.engine {
                engine = existing
            } else {
                engine = try CHHapticEngine()
                engine.playsHapticsOnly = true
                engine.stoppedHandler = { @Sendable [weak self] _ in
                    Task { @MainActor in self?.running = false }
                }
                engine.resetHandler = { @Sendable [weak self] in
                    Task { @MainActor in self?.running = false }
                }
                self.engine = engine
            }
            try engine.start()
            running = true
        } catch {
            running = false
        }
    }

    func stop() {
        guard running else { return }
        engine?.stop(completionHandler: nil)
        running = false
    }

    func play(_ accent: BeatAccent) {
        guard accent != .silent else { return }
        if !running { start() }
        guard running, let engine else { return }
        do {
            let pattern: CHHapticPattern
            if let existing = patterns[accent] {
                pattern = existing
            } else {
                let intensity: Float = accent == .strong ? 1 : accent == .medium ? 0.72 : 0.48
                let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                    .init(parameterID: .hapticIntensity, value: intensity),
                    .init(parameterID: .hapticSharpness, value: 0.6)
                ], relativeTime: 0)
                pattern = try CHHapticPattern(events: [event], parameters: [])
                patterns[accent] = pattern
            }
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            running = false
        }
    }
}
