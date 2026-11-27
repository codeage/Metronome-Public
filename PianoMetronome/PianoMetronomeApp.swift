import AppIntents
import SwiftUI
import UIKit

@main
@MainActor
struct PianoMetronomeApp: App {
    @StateObject private var metronome = Metronome.shared
    @StateObject private var subscription = Metronome.shared.subscription
    @Environment(\.scenePhase) private var scenePhase
    @State private var didCheckForUpdate = false
    @State private var availableUpdate: MetronomeUpdate?

    init() { MetronomeShortcuts.updateAppShortcutParameters() }

    var body: some Scene {
        WindowGroup {
            MetronomeView(metronome: metronome, hasAccess: subscription.hasAccess)
            .onOpenURL { url in
                Task { await metronome.handle(url) }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                metronome.setForeground(phase == .active)
                if phase == .active && !didCheckForUpdate {
                    didCheckForUpdate = true
                    Task { availableUpdate = await MetronomeUpdate.checkAtLaunch() }
                }
            }
            .task(id: scenePhase) {
                if scenePhase == .active { await subscription.refresh() }
            }
            .alert("有新版本", isPresented: Binding(
                get: { subscription.hasAccess && availableUpdate != nil },
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
        case meter, presets, settings, subscription
        var id: Self { self }
    }

    @ObservedObject var metronome: Metronome
    let hasAccess: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var keyboardFocused: Bool
    @ScaledMetric(relativeTo: .title3) private var playButtonHeight = 62
    @State private var panel: Panel?
    @State private var tapPromptID: UUID?

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
            guard panel == nil else { return .ignored }
            togglePlayback()
            return .handled
        }
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
            let gap: CGFloat = height >= 600 ? 24 : 12
            let dialGap: CGFloat = compactPortrait || height >= 600 ? 24 : 16
            let accentGap: CGFloat = compactPortrait ? 30 : gap
            let playbackGap: CGFloat = 56
            let inlinePlaybackHeight = compactPortrait ? playButtonHeight + playbackGap : 0
            let detailWidth = (width - gap) / 2
            let ghostHeight: CGFloat = metronome.preferences.ghost.enabled && metronome.playing ? 40 : 0
            let accents = AccentGridLayout(count: metronome.settings.accents.count,
                                           availableWidth: sideBySide ? detailWidth : width)
            let dialBudget = sideBySide
                ? height - 64 - gap - 54 - dialGap - ghostHeight
                : height - 64 - 44 - accents.height - 54 - gap * 2 - dialGap - accentGap
                    - ghostHeight - inlinePlaybackHeight
            let dialWidth = sideBySide ? detailWidth : width * 0.86
            let diameter = min(dialWidth, max(52, dialBudget), compactPortrait ? 560 : .infinity)

            VStack(spacing: gap) {
                header
                if sideBySide {
                    HStack(alignment: .center, spacing: gap) {
                        tempo(diameter: diameter, width: detailWidth, controlGap: dialGap)
                            .frame(width: detailWidth)
                        VStack(spacing: gap) {
                            rhythmControls(width: detailWidth)
                            accentGrid(accents)
                        }
                        .frame(width: detailWidth)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    rhythmControls(width: width)
                    VStack(spacing: playbackGap) {
                        VStack(spacing: accentGap) {
                            tempo(diameter: diameter, width: width, controlGap: dialGap,
                                  controlWidthLimit: compactPortrait ? portraitControlsWidth : .infinity)
                            accentGrid(accents)
                        }
                        if compactPortrait {
                            playButton
                                .frame(maxWidth: portraitControlsWidth)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.vertical, 10)
            .frame(width: width)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        case .subscription: MetronomePurchaseSheet(subscription: metronome.subscription)
        }
    }

    private var header: some View {
        HStack {
            Button {
                panel = .presets
            } label: {
                Label("预设", systemImage: "music.note.list")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .modifier(SettingsButtonBackground(capsule: true))
            .accessibilityLabel("曲目预设")
            .accessibilityIdentifier("presets-button")

            Spacer()

            Button {
                panel = .settings
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(SettingsButtonBackground())
            .accessibilityLabel("设置")
        }
        .foregroundStyle(.primary)
    }

    private func rhythmControls(width: CGFloat) -> some View {
        let spacing: CGFloat = 8
        let availableWidth = max(0, width - spacing)
        let meterWidth = min(120, availableWidth * 0.38)
        let rhythmWidth = availableWidth - meterWidth
        let custom = String(localized: "自定义拍号")
        let options = MeterOption.displayOrder.map(\.rawValue) + [custom]
        let locked = hasAccess ? Set<String>() : Set(options.filter { !BeatSettings.freeMeters.contains($0) })
        return HStack(spacing: spacing) {
            StableOptionMenu(
                title: String(localized: "拍号"), selection: metronome.settings.meter,
                options: options, identifier: "meter-option", compactWidth: meterWidth, lockedOptions: locked
            ) { value in
                if locked.contains(value) {
                    panel = .subscription
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
            .frame(width: meterWidth, height: 44)

            StableOptionMenu(
                title: String(localized: "细分节奏"), selection: metronome.settings.rhythm.title,
                options: BeatRhythm.allCases.map(\.title), identifier: "rhythm-option",
                compactWidth: rhythmWidth
            ) { value in
                if let rhythm = BeatRhythm.allCases.first(where: { $0.title == value }) {
                    metronome.setting(\.rhythm).wrappedValue = rhythm
                }
            }
            .frame(width: rhythmWidth, height: 44)
        }
    }

    private func tempo(diameter: CGFloat, width: CGFloat, controlGap: CGFloat,
                       controlWidthLimit: CGFloat = .infinity) -> some View {
        let controlWidth = min(width, controlWidthLimit, max(diameter, dynamicTypeSize.isAccessibilitySize ? 340 : 275))
        let range = metronome.preferences.tempoRange
        let bpm = metronome.settings.bpm
        let displayed = metronome.preferences.trainer.enabled ? metronome.effectiveTempo ?? bpm : bpm
        return VStack(spacing: controlGap) {
            TempoDial(bpm: displayed, diameter: diameter, range: range,
                      mark: metronome.preferences.showTempoMark ? BeatSettings(bpm: displayed).tempoMark : nil,
                      flashTick: metronome.preferences.flash && !reduceMotion ? metronome.flashTick : nil,
                      setTempo: { bpm in
                          metronome.performTempo(bpm)
                      })
            HStack(spacing: 12) {
                tempoButton(-1, symbol: "minus", label: "减慢一拍每分钟")
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
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(MetronomePalette.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("连续点按三到四次")
                .accessibilityIdentifier("tap-tempo")
                tempoButton(1, symbol: "plus", label: "加快一拍每分钟")
            }
            .frame(maxWidth: controlWidth)
            if metronome.preferences.ghost.enabled && metronome.playing {
                Text(metronome.ghostBar ? LocalizedStringKey("静音小节") : LocalizedStringKey("发声小节"))
                    .font(.footnote)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
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
                .background(MetronomePalette.cyan, in: RoundedRectangle(cornerRadius: 18))
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
                .frame(width: 54, height: 54)
                .background(MetronomePalette.surface, in: Circle())
        }
        .buttonStyle(.plain)
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
