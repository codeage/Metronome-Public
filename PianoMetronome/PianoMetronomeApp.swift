import AppIntents
import SwiftUI

@main
@MainActor
struct PianoMetronomeApp: App {
    @StateObject private var metronome = Metronome.shared
    @Environment(\.scenePhase) private var scenePhase

    init() { MetronomeShortcuts.updateAppShortcutParameters() }

    var body: some Scene {
        WindowGroup {
            MetronomeView(metronome: metronome)
                .onOpenURL { metronome.handle($0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    metronome.setForeground(phase == .active)
                }
        }
    }
}

enum MeterOption: String, CaseIterable, Sendable, Identifiable {
    case oneFour = "1/4", twoFour = "2/4", threeFour = "3/4", fourFour = "4/4"
    case twoTwo = "2/2", threeEight = "3/8", sixEight = "6/8", nineEight = "9/8"
    case twelveEight = "12/8", fiveFour = "5/4"

    var id: Self { self }

    func apply(to settings: inout BeatSettings) {
        let values = rawValue.split(separator: "/").compactMap { Int($0) }
        settings.beats = values[0]
        settings.unit = values[1]
    }
}

enum MetronomePalette {
    static let background = Color(red: 0.02, green: 0.08, blue: 0.17)
    static let surface = Color(red: 0.10, green: 0.19, blue: 0.32)
    static let track = Color(red: 0.16, green: 0.29, blue: 0.46)
    static let cyan = Color(red: 0.44, green: 0.89, blue: 0.98)
}

@MainActor
private struct MetronomeView: View {
    enum Panel: String, Identifiable {
        case meter, settings
        var id: Self { self }
    }

    @ObservedObject var metronome: Metronome
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var keyboardFocused: Bool
    @ScaledMetric(relativeTo: .title3) private var playButtonHeight = 62
    @State private var panel: Panel?
    @State private var tapPromptID: UUID?

    private var wide: Bool { horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        GeometryReader { viewport in
            let contentWidth = max(44, min(viewport.size.width, 900) - 32)
            let detailWidth = (contentWidth - 28) / 2
            let sectionSpacing: CGFloat = viewport.size.height >= 620 ? 28 : 20
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if wide || (viewport.size.width > viewport.size.height && !dynamicTypeSize.isAccessibilitySize) {
                        HStack(alignment: .top, spacing: 28) {
                            tempo(diameter: min(detailWidth, viewport.size.height * 0.50), width: detailWidth)
                                .frame(width: detailWidth)
                            VStack(spacing: sectionSpacing) {
                                soundControls(width: detailWidth)
                                accentGrid(width: detailWidth)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: sectionSpacing) {
                            soundControls(width: contentWidth)
                            tempo(diameter: min(contentWidth * 0.80, max(164, viewport.size.height * 0.44)),
                                  width: contentWidth)
                            accentGrid(width: contentWidth)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            playButton
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                .background(MetronomePalette.background)
        }
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
            switch panel {
            case .meter: MeterEditor(metronome: metronome)
            case .settings: MetronomeSettingsView(metronome: metronome)
            }
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

    private var header: some View {
        HStack {
            Text("节拍器")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                panel = .settings
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(SettingsButtonBackground())
            .accessibilityLabel("设置")
        }
    }

    private func soundControls(width: CGFloat) -> some View {
        let spacing: CGFloat = 8
        let capsuleWidth = (width - 2 * spacing) / 3
        return HStack(spacing: spacing) {
            Button {
                panel = .meter
            } label: {
                optionCapsule(metronome.settings.meter, width: capsuleWidth)
            }
            .accessibilityLabel("拍号，\(metronome.settings.meter)")
            .accessibilityIdentifier("meter-option")

            Menu {
                Picker("细分节奏", selection: metronome.setting(\.rhythm)) {
                    ForEach(BeatRhythm.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                optionCapsule(metronome.settings.rhythm.title, width: capsuleWidth)
            }
            .accessibilityLabel("细分节奏，\(metronome.settings.rhythm.title)")
            .accessibilityIdentifier("rhythm-option")

            Menu {
                Picker("音色", selection: metronome.setting(\.sound)) {
                    ForEach(BeatSound.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                optionCapsule(metronome.settings.sound.title, width: capsuleWidth)
            }
            .accessibilityLabel("音色，\(metronome.settings.sound.title)")
            .accessibilityIdentifier("sound-option")
        }
        .buttonStyle(.plain)
    }

    private func optionCapsule(_ title: String, width: CGFloat) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(MetronomePalette.cyan)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minWidth: width, maxWidth: width, minHeight: 44)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(MetronomePalette.surface, in: Capsule())
        .contentShape(Capsule())
    }

    private func tempo(diameter: CGFloat, width: CGFloat) -> some View {
        let controlWidth = min(width, max(diameter, dynamicTypeSize.isAccessibilitySize ? 340 : 275))
        let range = metronome.preferences.tempoRange
        let bpm = metronome.settings.bpm
        let displayed = metronome.preferences.trainer.enabled ? metronome.effectiveTempo ?? bpm : bpm
        return VStack(spacing: 12) {
            TempoDial(bpm: displayed, diameter: diameter, range: range,
                      mark: metronome.preferences.showTempoMark ? BeatSettings(bpm: displayed).tempoMark : nil,
                      setTempo: { metronome.performTempo($0) })
                .overlay {
                    if metronome.preferences.flash && !reduceMotion {
                        Circle().strokeBorder(MetronomePalette.cyan, lineWidth: 4)
                            .keyframeAnimator(initialValue: 0.0, trigger: metronome.flashTick) { view, opacity in
                                view.opacity(opacity)
                            } keyframes: { _ in
                                LinearKeyframe(0.19, duration: 0.03)
                                LinearKeyframe(0, duration: 0.15)
                            }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            HStack(spacing: 12) {
                tempoButton(-1, symbol: "minus", label: "减慢一拍每分钟")
                Button {
                    tapPromptID = UUID()
                    metronome.perform { try metronome.tap() }
                } label: {
                    Text(tapPromptID == nil ? "点按测速" : "请连续点击")
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
                Text(metronome.ghostBar ? "静音小节" : "发声小节")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func accentGrid(width: CGFloat) -> some View {
        let gridWidth = min(width, 520)
        let count = metronome.settings.accents.count
        let gap: CGFloat = 6
        let columns = min(count, max(1, Int((gridWidth + gap) / (44 + gap))))
        let cellWidth = min(50, (gridWidth - CGFloat(columns - 1) * gap) / CGFloat(columns))

        return VStack(spacing: gap) {
            ForEach(Array(stride(from: 0, to: count, by: columns)), id: \.self) { start in
                HStack(spacing: gap) {
                    ForEach(start..<min(start + columns, count), id: \.self) { beat in
                        accentButton(beat)
                            .frame(width: cellWidth)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: gridWidth)
        .frame(maxWidth: .infinity)
    }

    private func accentButton(_ beat: Int) -> some View {
        let accent = metronome.settings.accents[beat]
        let active = metronome.currentBeat == beat
        return Button {
            metronome.perform { try metronome.cycleAccent(beat) }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: accent.symbol)
                    .foregroundStyle(active ? MetronomePalette.cyan : .primary)
                Text("\(beat + 1)").font(.caption2.monospacedDigit())
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(active ? MetronomePalette.track : MetronomePalette.surface,
                        in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(beat + 1) 拍")
        .accessibilityValue(accent.title)
        .accessibilityHint("切换重音")
    }

    private var playButton: some View {
        Button(action: togglePlayback) {
            Label(metronome.playing ? "停止" : "开始",
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
        if metronome.playing { metronome.stop() } else { metronome.perform { try metronome.start() } }
    }

    private func tempoButton(_ delta: Int, symbol: String, label: String) -> some View {
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

private struct SettingsButtonBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
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
    let setTempo: (Int) -> Void

    @GestureState private var previewTempo: Int?
    @ScaledMetric(relativeTo: .largeTitle) private var speedScale: CGFloat = 1
    private let startAngle = 140.0
    private let sweep = 300.0
    private var minimumArc: Double { 360 - sweep }
    private let tempoCurve = 0.62

    var body: some View {
        let value = previewTempo ?? bpm
        let span = Double(range.upperBound - range.lowerBound)
        let progress = pow(Double(value - range.lowerBound) / span, tempoCurve)
        let lineWidth = diameter * 0.049

        ZStack {
            Circle().strokeBorder(MetronomePalette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: (minimumArc + progress * sweep) / 360)
                .stroke(MetronomePalette.cyan, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .padding(lineWidth / 2)
                .rotationEffect(.degrees(startAngle - minimumArc))
                .shadow(color: MetronomePalette.cyan.opacity(0.42), radius: 8)
            VStack(spacing: 2) {
                Text("速度").font(.headline).foregroundStyle(.secondary)
                Text("\(value)")
                    .font(.system(size: diameter * min(0.31, 0.25 * speedScale), weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                if let mark { Text(mark).font(.subheadline) }
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 4)
            .updating($previewTempo) { drag, preview, _ in
                if isOnRim(drag.startLocation) { preview = tempo(at: drag.location, startingAt: drag.startLocation) }
            }
            .onEnded { drag in
                if isOnRim(drag.startLocation) { setTempo(tempo(at: drag.location, startingAt: drag.startLocation)) }
            })
        .accessibilityElement(children: .ignore)
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

    private func isOnRim(_ point: CGPoint) -> Bool {
        hypot(point.x - diameter / 2, point.y - diameter / 2) >= diameter * 0.34
    }

    private func angle(at point: CGPoint) -> Double {
        let degrees = atan2(Double(point.y - diameter / 2), Double(point.x - diameter / 2)) * 180 / .pi
        return (degrees - startAngle + 720).truncatingRemainder(dividingBy: 360)
    }

    private func tempo(at point: CGPoint, startingAt start: CGPoint) -> Int {
        let offset = angle(at: point)
        if offset <= sweep {
            let span = Double(range.upperBound - range.lowerBound)
            return range.lowerBound + Int((pow(offset / sweep, 1 / tempoCurve) * span).rounded())
        }
        let initial = angle(at: start)
        if initial > sweep { return initial < (360 + sweep) / 2 ? range.upperBound : range.lowerBound }
        return initial > sweep / 2 ? range.upperBound : range.lowerBound
    }
}
