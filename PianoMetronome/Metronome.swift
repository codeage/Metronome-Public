import AVFoundation
import QuartzCore
import SwiftUI
import UIKit

enum MetronomeError: LocalizedError {
    case invalidSettings, audioUnavailable, invalidCommand, subscriptionRequired

    var errorDescription: String? {
        switch self {
        case .invalidSettings: "速度或拍号超出当前范围。可以在设置里开启专业速度范围或扩展拍号。"
        case .audioUnavailable: "无法启动节拍音频。"
        case .invalidCommand: "无法识别节拍器快捷指令的参数。"
        case .subscriptionRequired: "请打开节拍器，订阅、买断或恢复购买后再使用。"
        }
    }
}

@MainActor
final class Metronome: ObservableObject {
    static let shared = Metronome()
    let subscription = MetronomeSubscription()

    @Published private(set) var settings: BeatSettings
    @Published private(set) var preferences: MetronomePreferences
    @Published private(set) var presets: [MetronomePreset]
    @Published private(set) var playing = false
    @Published private(set) var currentBeat: Int?
    @Published private(set) var effectiveTempo: Int?
    @Published private(set) var ghostBar = false
    @Published private(set) var flashTick: UInt64 = 0
    @Published private(set) var outputName = "默认输出"
    @Published private(set) var outputLatency: TimeInterval = 0
    @Published var error: String?

    private var audio = MetronomeAudio()
    private let display = BeatDisplayLink()
    private let haptics = BeatHaptics()
    private let liveActivity = MetronomeLiveActivity()
    private var observers: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false
    private var foreground = false
    private var beatSerial: UInt64 = 0
    private var hapticSerial: UInt64 = 0
    private var tapTempo = TapTempo()

    private init() {
        var initialSettings = Self.read(BeatSettings.self, key: "beatSettings").flatMap { $0.isValid ? $0 : nil } ?? BeatSettings()
        let saved = Self.read(MetronomePreferences.self, key: "metronomePreferences")
        var preferences = saved ?? MetronomePreferences()
        if saved == nil {
            preferences.professionalTempo = !(30...250).contains(initialSettings.bpm)
            preferences.extendedMeter = initialSettings.beats > 16
        }
        initialSettings.bpm = min(preferences.tempoRange.upperBound,
                                  max(preferences.tempoRange.lowerBound, initialSettings.bpm))
        initialSettings.beats = min(preferences.beatsRange.upperBound, initialSettings.beats)
        settings = initialSettings
        if preferences.migrateVolumeDefault() {
            Self.write(preferences, key: "metronomePreferences")
        }
        self.preferences = preferences
        presets = (Self.read([MetronomePreset].self, key: "metronomePresets") ?? [])
            .filter { $0.settings.isValid }

        subscription.onAccessLost = { [weak self] in
            guard let self else { return }
            error = nil
            stop()
        }
        display.tick = { [weak self] time in self?.renderDisplay(at: time) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { @Sendable [weak self] notice in
            let type = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notice.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.handleInterruption(type, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { @Sendable [weak self] notice in
            let reason = notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reason) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: nil, queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor in self?.recoverAudio() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor in self?.mediaServicesReset() }
        })
    }

    var latencyMilliseconds: Double { outputLatency * 1_000 }

    func update(_ value: BeatSettings) throws {
        try subscription.requireAccess()
        guard valid(value) else { throw MetronomeError.invalidSettings }
        guard value != settings else { return }
        save(value)
        audio?.configure(settings, preferences)
        syncLiveActivity()
    }

    func changePreferences(_ value: MetronomePreferences) throws {
        try subscription.requireAccess()
        var next = value
        let range = next.tempoRange
        next.offsetMilliseconds = min(500, max(-500, next.offsetMilliseconds))
        next.volume = min(1, max(0, next.volume))
        next.balance = min(1, max(-1, next.balance))
        next.trainer.start = min(range.upperBound, max(range.lowerBound, next.trainer.start))
        next.trainer.target = min(range.upperBound, max(next.trainer.start, next.trainer.target))
        next.trainer.step = min(50, max(1, next.trainer.step))
        next.trainer.bars = min(64, max(1, next.trainer.bars))
        next.ghost.audible = min(64, max(1, next.ghost.audible))
        next.ghost.silent = min(64, max(1, next.ghost.silent))

        if playing && preferences.mixWithOthers != next.mixWithOthers {
            try audio?.changeMixing(next.mixWithOthers)
        }
        preferences = next
        Self.write(next, key: "metronomePreferences")
        var compatible = settings
        compatible.bpm = min(range.upperBound, max(range.lowerBound, compatible.bpm))
        compatible.beats = min(preferences.beatsRange.upperBound, compatible.beats)
        if compatible != settings { save(compatible) }
        audio?.configure(settings, preferences)
        updateScreenPolicy()
        syncLiveActivity()
    }

    func setTempo(_ value: Int) throws {
        var next = settings
        next.bpm = value
        try update(next)
    }

    func tap() throws {
        try subscription.requireAccess()
        if let tempo = tapTempo.tap(at: CACurrentMediaTime(), within: preferences.tempoRange) {
            try setTempo(tempo)
        }
    }

    func cycleAccent(_ beat: Int) throws {
        guard settings.accents.indices.contains(beat) else { return }
        var next = settings
        next.accents[beat] = next.accents[beat].next
        try update(next)
    }

    func start(_ value: BeatSettings? = nil) throws {
        try subscription.requireAccess()
        let next = value ?? settings
        guard valid(next) else { throw MetronomeError.invalidSettings }
        if playing {
            try update(next)
            return
        }
        guard let audio else { throw MetronomeError.audioUnavailable }
        audio.configure(next, preferences)
        try audio.start(mixing: preferences.mixWithOthers)
        resumeAfterInterruption = false
        save(next)
        playing = true
        refreshRoute()
        updateScreenPolicy()
        syncLiveActivity()
    }

    func stop() {
        resumeAfterInterruption = false
        endPlayback(deactivate: true)
    }

    func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        refreshRoute()
        updateScreenPolicy()
        if foreground {
            if playing { recoverAudio() }
            syncLiveActivity()
        }
    }

    func syncLiveActivity() {
        var liveSettings = settings
        if let effectiveTempo { liveSettings.bpm = effectiveTempo }
        liveActivity.sync(playing: playing, settings: liveSettings)
    }

    func savePreset(named name: String) {
        guard subscription.hasAccess, let name = Self.cleanedName(name) else { return }
        presets.append(.init(id: UUID(), name: name, settings: settings))
        storePresets()
    }

    func renamePreset(_ id: UUID, to name: String) {
        guard subscription.hasAccess, let name = Self.cleanedName(name),
              let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = name
        storePresets()
    }

    func deletePreset(_ id: UUID) {
        guard subscription.hasAccess else { return }
        presets.removeAll { $0.id == id }
        storePresets()
    }

    func loadPreset(_ preset: MetronomePreset) throws {
        var next = preferences
        if !next.tempoRange.contains(preset.settings.bpm) { next.professionalTempo = true }
        if !next.beatsRange.contains(preset.settings.beats) { next.extendedMeter = true }
        if next != preferences { try changePreferences(next) }
        try update(preset.settings)
    }

    func handle(_ url: URL) async {
        do {
            guard url.scheme == "bytereset-metronome", let action = url.host,
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.path.isEmpty, parts.fragment == nil else { throw MetronomeError.invalidCommand }
            try await subscription.verifyAccess()
            let items = parts.queryItems ?? []
            if action == "stop" {
                guard items.isEmpty else { throw MetronomeError.invalidCommand }
                stop()
                return
            }
            guard action == "start" || action == "settings" else { throw MetronomeError.invalidCommand }
            var next = settings
            var used = Set<String>()
            for item in items {
                guard used.insert(item.name).inserted, let raw = item.value, let value = Int(raw) else {
                    throw MetronomeError.invalidCommand
                }
                switch item.name {
                case "bpm": next.bpm = value
                case "beats": next.beats = value
                case "unit": next.unit = value
                case "subdivision" where (1...4).contains(value): next.subdivision = value
                case "accent" where value == 0 || value == 1: next.accent = value == 1
                default: throw MetronomeError.invalidCommand
                }
            }
            if action == "start" { try start(next) } else { try update(next) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func renderDisplay(at target: TimeInterval) {
        let latency = outputLatency + Double(preferences.offsetMilliseconds) / 1_000
        let audioTarget = target - latency
        let visual = audio?.event(at: audioTarget)
        var highlighted: Int?
        if let visual {
            let bpm = Int(visual.bpm)
            let age = audioTarget - visual.hostSeconds
            if age < min(0.16, 24 / Double(bpm)) { highlighted = Int(visual.beat) }
            if visual.serial != beatSerial {
                beatSerial = visual.serial
                if preferences.flash && highlighted != nil { flashTick = visual.serial }
                if ghostBar != visual.ghost { ghostBar = visual.ghost }
                if bpm != effectiveTempo {
                    effectiveTempo = bpm
                    syncLiveActivity()
                }
            }
        }
        if currentBeat != highlighted { currentBeat = highlighted }
        if preferences.haptics {
            let present = CACurrentMediaTime() - latency
            if let event = audio?.event(at: present), event.serial != hapticSerial {
                hapticSerial = event.serial
                if present - event.hostSeconds < 0.06, event.audible,
                   let accent = BeatAccent(rawValue: Int(event.accent)) {
                    haptics.play(accent)
                }
            }
        }
    }

    private func updateScreenPolicy() {
        UIApplication.shared.isIdleTimerDisabled = playing && foreground && preferences.keepAwake
        if playing && foreground {
            display.start()
            if preferences.haptics { haptics.start() } else { haptics.stop() }
        } else {
            display.stop()
            haptics.stop()
        }
    }

    private func endPlayback(deactivate: Bool) {
        audio?.stop(deactivate: deactivate)
        playing = false
        currentBeat = nil
        effectiveTempo = nil
        ghostBar = false
        beatSerial = 0
        hapticSerial = 0
        updateScreenPolicy()
        syncLiveActivity()
    }

    private func handleInterruption(_ type: UInt?, options: UInt) {
        switch type {
        case AVAudioSession.InterruptionType.began.rawValue:
            resumeAfterInterruption = playing
            endPlayback(deactivate: false)
        case AVAudioSession.InterruptionType.ended.rawValue:
            let resume = resumeAfterInterruption
            resumeAfterInterruption = false
            if resume && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                do { try start() } catch { self.error = error.localizedDescription }
            }
        default: break
        }
    }

    private func refreshRoute() {
        outputLatency = audio?.outputLatency ?? 0
        let output = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName)
        outputName = output.isEmpty ? "默认输出" : output.joined(separator: "、")
    }

    private func handleRouteChange(_ reason: UInt?) {
        refreshRoute()
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            || reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue {
            recoverAudio()
        }
    }

    private func recoverAudio() {
        guard playing, let audio, !audio.isRunning else { return }
        guard subscription.hasAccess else {
            stop()
            return
        }
        do {
            try audio.start(mixing: preferences.mixWithOthers)
            refreshRoute()
        } catch {
            endPlayback(deactivate: true)
            self.error = error.localizedDescription
        }
    }

    private func mediaServicesReset() {
        endPlayback(deactivate: false)
        resumeAfterInterruption = false
        audio = MetronomeAudio()
    }

    private func valid(_ value: BeatSettings) -> Bool {
        value.isValid && preferences.tempoRange.contains(value.bpm) && preferences.beatsRange.contains(value.beats)
    }

    private func save(_ value: BeatSettings) {
        settings = value
        Self.write(value, key: "beatSettings")
    }

    private func storePresets() {
        Self.write(presets, key: "metronomePresets")
    }

    private static func cleanedName(_ name: String) -> String? {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(80))
    }

    private static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func write<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
