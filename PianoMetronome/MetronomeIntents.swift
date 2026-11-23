#if canImport(AppIntents)
import AppIntents

@available(iOS 16, *)
struct StartMetronomeIntent: AppIntent {
    static let title: LocalizedStringResource = "启动节拍器"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try Metronome.shared.start()
        return .result()
    }
}

@available(iOS 16, *)
struct StopMetronomeIntent: AppIntent {
    static let title: LocalizedStringResource = "停止节拍器"

    @MainActor
    func perform() async throws -> some IntentResult {
        Metronome.shared.stop()
        return .result()
    }
}

@available(iOS 16, *)
struct SetMetronomeIntent: AppIntent {
    static let title: LocalizedStringResource = "设置节拍"
    static let openAppWhenRun = true

    @Parameter(title: "速度 BPM") var bpm: Int
    @Parameter(title: "每小节拍数") var beats: Int
    @Parameter(title: "拍型分母") var unit: Int
    @Parameter(title: "每拍细分") var subdivision: Int
    @Parameter(title: "小节首拍重音") var accent: Bool
    @Parameter(title: "设置后播放", default: true) var play: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("将节拍设为 \(\.$bpm) BPM、\(\.$beats)/\(\.$unit) 拍") {
            \.$subdivision
            \.$accent
            \.$play
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let settings = BeatSettings(bpm: bpm, beats: beats, unit: unit, subdivision: subdivision, accent: accent)
        if play {
            try Metronome.shared.start(settings)
        } else {
            try Metronome.shared.update(settings)
        }
        return .result()
    }
}

extension MeterOption: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "拍号"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .oneFour: DisplayRepresentation(title: "四一拍"),
        .twoTwo: DisplayRepresentation(title: "二二拍"),
        .threeEight: DisplayRepresentation(title: "八三拍"),
        .fiveFour: DisplayRepresentation(title: "四五拍"),
        .twoFour: DisplayRepresentation(title: "四二拍"),
        .threeFour: DisplayRepresentation(title: "四三拍"),
        .fourFour: DisplayRepresentation(title: "四四拍"),
        .sixEight: DisplayRepresentation(title: "八六拍"),
        .nineEight: DisplayRepresentation(title: "八九拍"),
        .twelveEight: DisplayRepresentation(title: "八十二拍")
    ]
}

struct SetMetronomeTempoIntent: AppIntent {
    static let title: LocalizedStringResource = "设置节拍器的速度"

    @Parameter(title: "速度", requestValueDialog: "每分钟多少拍？")
    var bpm: Int

    static var parameterSummary: some ParameterSummary {
        Summary("将速度设为每分钟 \(\.$bpm) 拍")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try Metronome.shared.setTempo(bpm)
        return .result(dialog: "速度已设为每分钟 \(bpm) 拍。")
    }
}

struct SetMetronomeMeterIntent: AppIntent {
    static let title: LocalizedStringResource = "设置节拍器的拍号"

    @Parameter(title: "拍号", requestValueDialog: "要设成什么拍号？")
    var meter: MeterOption

    static var parameterSummary: some ParameterSummary {
        Summary("将拍号设为 \(\.$meter)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var settings = Metronome.shared.settings
        meter.apply(to: &settings)
        try Metronome.shared.update(settings)
        return .result(dialog: "拍号已设为 \(meter.rawValue)。")
    }
}

@available(iOS 16, *)
struct MetronomeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartMetronomeIntent(), phrases: ["启动 \(.applicationName)", "Start \(.applicationName)"],
                    shortTitle: "启动节拍器", systemImageName: "play.fill")
        AppShortcut(intent: StopMetronomeIntent(), phrases: ["停止 \(.applicationName)", "Stop \(.applicationName)"],
                    shortTitle: "停止节拍器", systemImageName: "stop.fill")
        AppShortcut(intent: SetMetronomeTempoIntent(),
                    phrases: ["设置 \(.applicationName) 的速度", "Set \(.applicationName) tempo"],
                    shortTitle: "设置速度", systemImageName: "metronome")
        AppShortcut(intent: SetMetronomeMeterIntent(),
                    phrases: ["设置 \(.applicationName) 的拍号", "把 \(.applicationName) 的拍号设为 \(\.$meter)",
                              "Set \(.applicationName) time signature", "Set \(.applicationName) to \(\.$meter)"],
                    shortTitle: "设置拍号", systemImageName: "music.note.list")
    }
}
#endif
