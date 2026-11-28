import AppIntents
import SwiftUI
import UIKit

@main
@MainActor
struct PianoMetronomeApp: App {
    @StateObject private var metronome = Metronome.shared
    @StateObject private var purchases = Metronome.shared.purchases
    @Environment(\.scenePhase) private var scenePhase
    @State private var didCheckForUpdate = false
    @State private var availableUpdate: MetronomeUpdate?
    @AppStorage("pdmxServerOverride") private var pdmxServerOverride = ""

    init() { MetronomeShortcuts.updateAppShortcutParameters() }

    var body: some Scene {
        WindowGroup {
            MetronomeView(metronome: metronome, hasAccess: purchases.hasAccess,
                          scoreEndpoint: ScoreEndpoint(address: pdmxServerOverride)
                              ?? ScoreEndpoint(address: Bundle.main.object(forInfoDictionaryKey: "PDMXServerURL") as? String ?? ""))
            .onOpenURL { url in
                if let endpoint = ScoreEndpoint(connectionURL: url) {
                    pdmxServerOverride = endpoint.baseURL.absoluteString
                } else {
                    Task { await metronome.handle(url) }
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                metronome.setForeground(phase == .active)
                if phase == .active && !didCheckForUpdate {
                    didCheckForUpdate = true
                    Task { availableUpdate = await MetronomeUpdate.checkAtLaunch() }
                }
            }
            .task(id: scenePhase) {
                if scenePhase == .active { await purchases.refresh() }
            }
            .alert("有新版本", isPresented: Binding(
                get: { purchases.hasAccess && availableUpdate != nil },
                set: { if !$0 { availableUpdate = nil } }
            ), presenting: availableUpdate) { update in
                Button(update.destination.buttonTitle) { openUpdate(update.destination) }
                Button("稍后", role: .cancel) {}
            } message: { update in
                Text("节拍器 \(update.version) 已可更新。")
            }
        }
    }

    private func openUpdate(_ destination: MetronomeUpdate.Destination) {
        switch destination {
        case .appStore(let url):
            UIApplication.shared.open(url)
        case .testFlight:
            guard let appURL = URL(string: "itms-beta://"),
                  let fallback = URL(string: "https://testflight.apple.com/") else { return }
            Task {
                let opened = await UIApplication.shared.open(appURL)
                if !opened { _ = await UIApplication.shared.open(fallback) }
            }
        }
    }
}

enum MeterOption: String, CaseIterable, Sendable, Identifiable {
    case oneFour = "1/4", twoFour = "2/4", threeFour = "3/4", fourFour = "4/4"
    case twoTwo = "2/2", threeEight = "3/8", sixEight = "6/8", nineEight = "9/8"
    case twelveEight = "12/8", fiveFour = "5/4"

    var id: Self { self }

    static var displayOrder: [Self] {
        BeatSettings.freeMeters.compactMap(Self.init(rawValue:)) + [.sixEight]
            + allCases.filter { !BeatSettings.freeMeters.contains($0.rawValue) && $0 != .sixEight }
    }

    func apply(to settings: inout BeatSettings) {
        let values = rawValue.split(separator: "/").compactMap { Int($0) }
        settings.beats = values[0]
        settings.unit = values[1]
    }
}

enum MetronomePalette {
    static let background = Color("MetronomeBackground")
    static let surface = Color(red: 0.10, green: 0.19, blue: 0.32)
    static let track = Color(red: 0.16, green: 0.29, blue: 0.46)
    static let cyan = Color(red: 0.44, green: 0.89, blue: 0.98)
}

@MainActor
private struct MetronomeView: View {
    enum Panel: String, Identifiable {
        case meter, presets, settings, purchase
        var id: Self { self }
    }

    @ObservedObject var metronome: Metronome
    let hasAccess: Bool
    let scoreEndpoint: ScoreEndpoint?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TempoTheme.storageKey) private var tempoTheme: TempoTheme = .ring
    @FocusState private var keyboardFocused: Bool
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .title3) private var playButtonHeight = 62
    @State private var panel: Panel?
    @State private var tapPromptID: UUID?
    @State private var scoreQuery = ""

    private let portraitControlsWidth: CGFloat = 400

    var body: some View {
        layout
        .task(id: tapPromptID) { [tapPromptID] in
            guard let tapPromptID else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                if self.tapPromptID == tapPromptID { self.tapPromptID = nil }
            } catch {
                // A new tap restarts the two-second prompt.
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onKeyPress(.space, phases: .down) { _ in
            guard panel == nil, !searchFocused else { return .ignored }
            togglePlayback()
            return .handled
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(MetronomePalette.background.ignoresSafeArea())
        .tint(MetronomePalette.cyan)
        .preferredColorScheme(.dark)
        .sheet(item: $panel, onDismiss: { keyboardFocused = true }) { panel in
            panelView(panel)
        }
        .alert("节拍器", isPresented: Binding(
            get: { metronome.error != nil },
            set: { if !$0 { metronome.error = nil } }
        )) {
            Button("好", role: .cancel) { metronome.error = nil }
        } message: {
            Text(metronome.error ?? "")
        }
    }

    private var layout: some View {
        GeometryReader { window in
            let compactPortrait = UIDevice.current.userInterfaceIdiom == .pad && window.size.height >= window.size.width

            if compactPortrait {
                mainControls(compactPortrait: true)
            } else {
                mainControls(compactPortrait: false)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        playButton
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: 900)
                            .frame(maxWidth: .infinity)
                            .background(MetronomePalette.background)
                    }
            }
        }
    }

    private func mainControls(compactPortrait: Bool) -> some View {
        GeometryReader { viewport in
            let width = max(0, min(viewport.size.width, 900) - 32)
            let height = viewport.size.height
            let regularLandscape = horizontalSizeClass == .regular && width >= 600 && viewport.size.width > height
            let sideBySide = !compactPortrait && (regularLandscape || viewport.size.width > height * 1.6)
            let gap: CGFloat = height >= 600 ? 18 : 10
            let headerGap: CGFloat = 11
            let inlineHeader = sideBySide && width >= 600
            let headerHeight: CGFloat = inlineHeader ? 46 : 92 + headerGap
            let dialGap: CGFloat = height >= 600 ? 17 : 10
            let accentGap: CGFloat = height >= 600 ? 21 : 11
            let playbackGap: CGFloat = 28
            let inlinePlaybackHeight = compactPortrait ? playButtonHeight + playbackGap : 0
            let detailWidth = (width - gap) / 2
            let ghostHeight: CGFloat = metronome.preferences.ghost.enabled && metronome.playing ? 40 : 0
            let accents = AccentGridLayout(count: metronome.settings.accents.count,
                                           availableWidth: sideBySide ? detailWidth : width)
            let dialBudget = sideBySide
                ? height - 16 - headerHeight - gap - 48 - dialGap - ghostHeight
                : height - 16 - headerHeight - accents.height - 21 - 48 - gap - dialGap - accentGap
                    - ghostHeight - inlinePlaybackHeight
            let dialWidth = sideBySide ? detailWidth : width * 0.86
            let diameter = min(dialWidth, max(52, dialBudget), compactPortrait ? 560 : .infinity)

            VStack(spacing: gap) {
                header(width: width, rowSpacing: headerGap, inline: inlineHeader)
                if sideBySide {
                    HStack(alignment: .center, spacing: gap) {
                        tempo(diameter: diameter, width: detailWidth, controlGap: dialGap)
                            .frame(width: detailWidth)
                        beatAccents(accents)
                            .frame(width: detailWidth)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: playbackGap) {
                        VStack(spacing: accentGap) {
                            tempo(diameter: diameter, width: width, controlGap: dialGap,
                                  controlWidthLimit: compactPortrait ? portraitControlsWidth : .infinity)
                            beatAccents(accents)
                        }
                        if compactPortrait {
                            playButton
                                .frame(maxWidth: portraitControlsWidth)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.vertical, 8)
            .frame(width: width)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .top) {
                if searchFocused, !scoreQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScoreSearchResults(query: scoreQuery, endpoint: scoreEndpoint) { searchFocused = false }
                        .frame(maxWidth: min(width, 440))
                        .padding(.top, 62)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func panelView(_ panel: Panel) -> some View {
        switch panel {
        case .meter: MeterEditor(metronome: metronome)
        case .presets:
            NavigationStack {
                MetronomePresetsView(metronome: metronome, showsCloseButton: true)
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .settings: MetronomeSettingsView(metronome: metronome)
        case .purchase: MetronomePurchaseSheet(purchases: metronome.purchases)
        }
    }

    private func header(width: CGFloat, rowSpacing: CGFloat, inline: Bool) -> some View {
        let headerWidth = min(width, inline ? 720 : 440)
        return Group {
            if inline {
                HStack(spacing: rowSpacing) {
                    searchToolbar
                    beatControls(width: headerWidth * 0.43)
                }
            } else {
                VStack(spacing: rowSpacing) {
                    searchToolbar
                    beatControls(width: headerWidth)
                }
            }
        }
        .frame(width: headerWidth)
        .foregroundStyle(.primary)
    }

    private var searchToolbar: some View {
        HStack(spacing: 9) {
            presetsButton
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索曲谱", text: $scoreQuery)
                    .focused($searchFocused)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .accessibilityIdentifier("score-search")
                if searchFocused || !scoreQuery.isEmpty {
                    Button {
                        if scoreQuery.isEmpty { searchFocused = false }
                        else { scoreQuery = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(scoreQuery.isEmpty ? LocalizedStringKey("取消搜索") : LocalizedStringKey("清除搜索"))
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 13)
            .frame(height: 46)
            .modifier(SettingsButtonBackground(capsule: true))
            settingsButton
        }
    }

    private var presetsButton: some View {
        Button {
            panel = .presets
        } label: {
            Image(systemName: "music.note.list")
                .font(.body.weight(.semibold))
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SettingsButtonBackground())
        .accessibilityLabel("曲目预设")
        .accessibilityIdentifier("presets-button")
    }

    private var settingsButton: some View {
        Button {
            panel = .settings
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SettingsButtonBackground())
        .accessibilityLabel("设置")
    }

    private func beatControls(width: CGFloat) -> some View {
        let spacing: CGFloat = 8
        let availableWidth = max(0, width - spacing)
        let meterWidth = availableWidth * 0.38
        let rhythmWidth = availableWidth - meterWidth
        let custom = String(localized: "自定义拍号")
        let options = MeterOption.displayOrder
            .filter { $0 != .oneFour && $0 != .fiveFour }
            .map(\.rawValue) + [custom]
        let locked = hasAccess ? Set<String>() : Set(options.filter { !BeatSettings.freeMeters.contains($0) })
        return HStack(spacing: spacing) {
            StableOptionMenu(
                title: String(localized: "拍号"), selection: metronome.settings.meter,
                options: options, identifier: "meter-option", compactWidth: meterWidth, lockedOptions: locked
            ) { value in
                if locked.contains(value) {
                    panel = .purchase
                    return
                }
                guard let meter = MeterOption(rawValue: value) else {
                    panel = .meter
                    return
                }
                var settings = metronome.settings
                meter.apply(to: &settings)
                metronome.perform { try metronome.update(settings) }
            }
            .frame(width: meterWidth, height: 46)

            StableOptionMenu(
                title: String(localized: "细分节奏"), selection: metronome.settings.rhythm.title,
                options: BeatRhythm.allCases.map(\.title), identifier: "rhythm-option",
                compactWidth: rhythmWidth
            ) { value in
                if let rhythm = BeatRhythm.allCases.first(where: { $0.title == value }) {
                    metronome.setting(\.rhythm).wrappedValue = rhythm
                }
            }
            .frame(width: rhythmWidth, height: 46)
        }
    }

    private func tempo(diameter: CGFloat, width: CGFloat, controlGap: CGFloat,
                       controlWidthLimit: CGFloat = .infinity) -> some View {
        let controlWidth = min(width, controlWidthLimit, dynamicTypeSize.isAccessibilitySize ? 310 : 258)
        let range = metronome.preferences.tempoRange
        let bpm = metronome.settings.bpm
        let displayed = metronome.preferences.trainer.enabled ? metronome.effectiveTempo ?? bpm : bpm
        return VStack(spacing: controlGap) {
            let mark = metronome.preferences.showTempoMark ? BeatSettings(bpm: displayed).tempoMark : nil
            let flashTick = metronome.preferences.flash && !reduceMotion ? metronome.flashTick : nil
            if tempoTheme == .ring {
                TempoDial(bpm: displayed, diameter: diameter, range: range, mark: mark, flashTick: flashTick,
                          setTempo: metronome.performTempo)
                HStack(spacing: 9) {
                    tempoButton(-1, symbol: "minus", label: "减慢一拍每分钟")
                    tapTempoButton
                    tempoButton(1, symbol: "plus", label: "加快一拍每分钟")
                }
                .frame(maxWidth: controlWidth)
            } else {
                TempoRuler(bpm: displayed, range: range, mark: mark, flashTick: flashTick,
                           controlWidth: controlWidth,
                           decrease: tempoButton(-1, symbol: "minus", label: "减慢一拍每分钟"),
                           increase: tempoButton(1, symbol: "plus", label: "加快一拍每分钟"),
                           height: min(205, max(58, diameter)), setTempo: metronome.performTempo)
                    .frame(maxWidth: 410)
                tapTempoButton.frame(maxWidth: min(width, 152))
            }
            if metronome.preferences.ghost.enabled && metronome.playing {
                Text(metronome.ghostBar ? LocalizedStringKey("静音小节") : LocalizedStringKey("发声小节"))
                    .font(.footnote)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tapTempoButton: some View {
        Button {
            tapPromptID = UUID()
            metronome.perform { try metronome.tap() }
        } label: {
            Text(tapPromptID == nil ? LocalizedStringKey("点按测速") : LocalizedStringKey("请连续点击"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(MetronomePalette.cyan)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .modifier(SettingsButtonBackground(capsule: true))
        .accessibilityHint("连续点按三到四次")
        .accessibilityIdentifier("tap-tempo")
    }

    private func beatAccents(_ layout: AccentGridLayout) -> some View {
        VStack(spacing: 5) {
            Text("重音")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            accentGrid(layout)
        }
    }

    private func accentGrid(_ layout: AccentGridLayout) -> some View {
        let count = metronome.settings.accents.count
        return VStack(spacing: layout.rowSpacing) {
            ForEach(Array(stride(from: 0, to: count, by: layout.columns)), id: \.self) { start in
                HStack(spacing: layout.columnSpacing) {
                    ForEach(start..<min(start + layout.columns, count), id: \.self) { beat in
                        accentButton(beat, layout: layout)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: layout.height)
    }

    private func accentButton(_ beat: Int, layout: AccentGridLayout) -> some View {
        let accent = metronome.settings.accents[beat]
        let active = metronome.currentBeat == beat
        let compact = layout.cellWidth < 44
        let symbolFont: Font = compact ? .system(size: min(17, max(10, layout.cellWidth * 0.45))) : .body
        let numberFont: Font = compact ? .system(size: min(12, max(9, layout.cellWidth * 0.34))) : .caption2
        return Button {
            metronome.perform { try metronome.cycleAccent(beat) }
        } label: {
            VStack(spacing: compact ? 1 : 3) {
                Image(systemName: accent.symbol)
                    .font(symbolFont)
                    .foregroundStyle(active ? MetronomePalette.cyan : .primary)
                Text("\(beat + 1)")
                    .font(numberFont.monospacedDigit())
                    .lineLimit(1)
            }
            .frame(width: layout.cellWidth, height: layout.cellHeight)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .background(active ? MetronomePalette.track : MetronomePalette.surface,
                        in: RoundedRectangle(cornerRadius: compact ? 6 : 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(beat + 1) 拍")
        .accessibilityValue(accent.title)
        .accessibilityHint("切换重音")
    }

    private var playButton: some View {
        Button(action: togglePlayback) {
            Label(metronome.playing ? LocalizedStringKey("停止") : LocalizedStringKey("开始"),
                  systemImage: metronome.playing ? "stop.fill" : "play.fill")
                .font(.title2.weight(.semibold))
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: playButtonHeight)
                .foregroundStyle(MetronomePalette.background)
                .background(MetronomePalette.cyan.gradient, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func togglePlayback() {
        if metronome.playing {
            metronome.stop()
        } else {
            metronome.perform { try metronome.start() }
        }
    }

    private func tempoButton(_ delta: Int, symbol: String, label: LocalizedStringKey) -> some View {
        Button {
            metronome.performTempo(metronome.settings.bpm + delta)
        } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .modifier(SettingsButtonBackground())
        .buttonRepeatBehavior(.enabled)
        .disabled(!metronome.preferences.tempoRange.contains(metronome.settings.bpm + delta))
        .sensoryFeedback(.selection, trigger: metronome.settings.bpm) { old, new in
            metronome.preferences.haptics && new - old == delta
        }
        .accessibilityLabel(label)
    }
}

private extension BeatAccent {
    var symbol: String {
        switch self {
        case .strong: "circle.fill"
        case .medium: "circle.lefthalf.filled"
        case .weak: "circle"
        case .silent: "speaker.slash"
        }
    }
}

private struct AccentGridLayout {
    let columns: Int
    let columnSpacing: CGFloat
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let height: CGFloat
    let rowSpacing: CGFloat = 4

    init(count: Int, availableWidth: CGFloat) {
        let width = min(max(availableWidth, 1), 520)
        let usesFullSize = CGFloat(count) * 44 + CGFloat(max(0, count - 1)) * 6 <= width
        columnSpacing = usesFullSize ? 6 : 3
        let maxColumns = max(1, Int((width + columnSpacing) / (24 + columnSpacing)))
        let rows = max(1, (count + maxColumns - 1) / maxColumns)
        columns = max(1, (count + rows - 1) / rows)
        cellWidth = min(44, (width - CGFloat(columns - 1) * columnSpacing) / CGFloat(columns))
        cellHeight = min(48, max(30, cellWidth * 1.12))
        height = CGFloat(rows) * cellHeight + CGFloat(rows - 1) * rowSpacing
    }
}

private struct SettingsButtonBackground: ViewModifier {
    var capsule = false

    func body(content: Content) -> some View {
        if capsule {
            if #available(iOS 26, *) {
                content.glassEffect(.regular.interactive(), in: .capsule)
            } else {
                content.background(MetronomePalette.surface, in: Capsule())
            }
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(MetronomePalette.surface, in: Circle())
        }
    }
}

enum TempoTheme: String, CaseIterable {
    static let storageKey = "metronome.tempoTheme"

    case ring
    case ruler

    var title: String {
        switch self {
        case .ring: String(localized: "圆环")
        case .ruler: String(localized: "刻度")
        }
    }
}

private struct TempoRuler<Step: View>: View {
    let bpm: Int
    let range: ClosedRange<Int>
    let mark: String?
    let flashTick: UInt64?
    let controlWidth: CGFloat
    let decrease: Step
    let increase: Step
    let height: CGFloat
    let setTempo: (Int) -> Void

    var body: some View {
        let spacious = height >= 120
        VStack(spacing: spacious ? 8 : 3) {
            if spacious {
                Text("速度").font(.headline).foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                decrease
                Group {
                    if let flashTick {
                        value(spacious: spacious)
                            .keyframeAnimator(initialValue: 0.0, trigger: flashTick) { content, amount in
                                content.brightness(amount * 0.25)
                            } keyframes: { _ in
                                LinearKeyframe(0.85, duration: 0.035)
                                CubicKeyframe(0, duration: 0.19)
                            }
                    } else {
                        value(spacious: spacious)
                    }
                }
                .frame(maxWidth: .infinity)
                increase
            }
            .frame(maxWidth: controlWidth)
            Slider(value: Binding(get: { Double(bpm) }, set: { setTempo(Int($0.rounded())) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .accessibilityLabel("速度")
                .accessibilityValue("每分钟 \(bpm) 拍")
                .accessibilityIdentifier("tempo-ruler")
            if spacious {
                Canvas { context, size in
                    var ticks = Path()
                    for index in 0...24 {
                        let x = size.width * CGFloat(index) / 24
                        ticks.move(to: CGPoint(x: x, y: 0))
                        ticks.addLine(to: CGPoint(x: x, y: index.isMultiple(of: 4) ? size.height : size.height * 0.55))
                    }
                    context.stroke(ticks, with: .color(MetronomePalette.track), lineWidth: 1)
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                HStack {
                    Text("\(range.lowerBound)")
                    Spacer()
                    Text("\(range.upperBound)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        }
        .frame(minHeight: height)
        .padding(.horizontal, 10)
    }

    private func value(spacious: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(bpm)")
                .font(.system(size: spacious ? 78 : 30, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
            if let mark { Text(mark).font(.caption) }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityHidden(true)
    }
}

private struct TempoDial: View {
    let bpm: Int
    let diameter: CGFloat
    let range: ClosedRange<Int>
    let mark: String?
    let flashTick: UInt64?
    let setTempo: (Int) -> Void

    @GestureState private var touchingRim = false
    @State private var drag: TempoDialDrag?
    @ScaledMetric(relativeTo: .largeTitle) private var speedScale: CGFloat = 1

    var body: some View {
        let value = drag?.tempo ?? bpm
        let progress = TempoDialDrag.progress(for: value, in: range)
        let diameter = diameter
        ZStack {
            if let flashTick {
                Self.ring(diameter: diameter, progress: progress, pulse: 0)
                    .keyframeAnimator(initialValue: 0.0, trigger: flashTick) { _, pulse in
                        Self.ring(diameter: diameter, progress: progress, pulse: pulse)
                    } keyframes: { _ in
                        LinearKeyframe(1, duration: 0.035)
                        CubicKeyframe(0, duration: 0.19)
                    }
            } else {
                Self.ring(diameter: diameter, progress: progress, pulse: 0)
            }
            VStack(spacing: 2) {
                Text("速度").font(.headline).foregroundStyle(.secondary)
                Text("\(value)")
                    .font(.system(size: diameter * min(0.31, 0.25 * speedScale), weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                if let mark { Text(mark).font(.subheadline) }
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            Color.clear
                .contentShape(TempoDialRim(), eoFill: true)
                .gesture(turn)
        }
        .onChange(of: touchingRim) { _, touching in
            if !touching { drag = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("tempo-dial")
        .accessibilityLabel("速度")
        .accessibilityValue("每分钟 \(value) 拍")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setTempo(min(range.upperBound, bpm + 1))
            case .decrement: setTempo(max(range.lowerBound, bpm - 1))
            @unknown default: break
            }
        }
    }

    nonisolated private static func ring(diameter: CGFloat, progress: Double, pulse strength: Double) -> some View {
        let pulse = min(max(strength, 0), 1)
        let lineWidth = diameter * 0.049
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [MetronomePalette.cyan.opacity(0.16 * pulse), .clear],
                                     center: .center, startRadius: 0, endRadius: diameter / 2))
            Circle().strokeBorder(MetronomePalette.track, lineWidth: lineWidth)
            Circle()
                .strokeBorder(MetronomePalette.cyan.opacity(0.55 * pulse), lineWidth: lineWidth)
                .shadow(color: MetronomePalette.cyan.opacity(0.65 * pulse), radius: 15 * pulse)
            Circle()
                .trim(from: 0, to: progress * TempoDialDrag.sweep / 360)
                .stroke(MetronomePalette.cyan, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .padding(lineWidth / 2)
                .rotationEffect(.degrees(TempoDialDrag.zeroAngle))
                .brightness(0.18 * pulse)
                .shadow(color: MetronomePalette.cyan.opacity(0.38 + 0.42 * pulse), radius: 8 + 4 * pulse)
            Capsule()
                .fill(.white.opacity(0.85))
                .frame(width: max(2, lineWidth * 0.18), height: lineWidth * 0.9)
                .offset(y: (diameter - lineWidth) / 2)
        }
        .scaleEffect(1 + 0.018 * pulse)
    }

    private var turn: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($touchingRim) { _, touching, _ in touching = true }
            .onChanged { value in
                if drag == nil {
                    drag = TempoDialDrag(tempo: bpm, range: range, start: centered(value.startLocation))
                }
                drag?.update(to: centered(value.location))
            }
            .onEnded { value in
                guard var drag else { return }
                drag.update(to: centered(value.location))
                let next = drag.tempo
                self.drag = nil
                if next != bpm { setTempo(next) }
            }
    }

    private func centered(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - diameter / 2, y: point.y - diameter / 2)
    }
}

private struct TempoDialRim: Shape {
    func path(in rect: CGRect) -> Path {
        let touchWidth = min(44, rect.width * 0.27)
        var path = Path(ellipseIn: rect)
        path.addEllipse(in: rect.insetBy(dx: touchWidth, dy: touchWidth))
        return path
    }
}
