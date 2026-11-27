import SwiftUI
import UIKit
import StoreKit

@MainActor
extension Metronome {
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }

    func performTempo(_ bpm: Int) {
        perform { try setTempo(bpm) }
    }

    func setting<Value>(_ key: WritableKeyPath<BeatSettings, Value>) -> Binding<Value> {
        Binding {
            self.settings[keyPath: key]
        } set: { value in
            var next = self.settings
            next[keyPath: key] = value
            self.perform { try self.update(next) }
        }
    }

    func option<Value>(_ key: WritableKeyPath<MetronomePreferences, Value>) -> Binding<Value> {
        Binding {
            self.preferences[keyPath: key]
        } set: { value in
            var next = self.preferences
            next[keyPath: key] = value
            self.perform { try self.changePreferences(next) }
        }
    }
}

@MainActor
struct MeterEditor: View {
    @ObservedObject var metronome: Metronome
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("常用拍号") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                        ForEach(MeterOption.allCases) { meter in
                            let selected = metronome.settings.meter == meter.rawValue
                            Button {
                                var settings = metronome.settings
                                meter.apply(to: &settings)
                                metronome.perform { try metronome.update(settings) }
                                dismiss()
                            } label: {
                                Text(meter.rawValue)
                                    .font(.headline.monospacedDigit())
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                                                in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("自定义拍号") {
                    Stepper("每小节 \(metronome.settings.beats) 拍",
                            value: metronome.setting(\.beats), in: metronome.preferences.beatsRange)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("拍号分母")
                        Picker("拍号分母", selection: metronome.setting(\.unit)) {
                            ForEach(BeatSettings.units, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("拍号分母")
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("拍号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

@MainActor
struct MetronomeSettingsView: View {
    @ObservedObject var metronome: Metronome
    @ObservedObject private var subscription: MetronomeSubscription
    @Environment(\.dismiss) private var dismiss
    @State private var showingSubscriptionManagement = false
    @State private var confirmingSettingsReset = false

    init(metronome: Metronome) {
        self.metronome = metronome
        self.subscription = metronome.subscription
    }

    var body: some View {
        NavigationStack {
            Form {
                audioSection
                latencySection
                rangeSection
                trainingSection
                ghostSection
                feedbackSection
                Section {
                    NavigationLink("曲目预设") { MetronomePresetsView(metronome: metronome) }
                }
                Section {
                    if subscription.ownsLifetime {
                        Label("已永久解锁", systemImage: "checkmark")
                    } else {
                        NavigationLink("一次性买断") {
                            MetronomeSubscriptionView(subscription: subscription, buyoutOnly: true)
                        }
                    }
                    Button {
                        showingSubscriptionManagement = true
                    } label: {
                        HStack {
                            Text("管理订阅")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    NavigationLink("隐私政策") { MetronomePrivacyPolicyView() }
                }
                Section {
                    Button("恢复默认设置") { confirmingSettingsReset = true }
                }
                Section("关于") {
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        LabeledContent("版本", value: version)
                    }
                    if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                        LabeledContent("构建号", value: build)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .alert("恢复默认设置？", isPresented: $confirmingSettingsReset) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                metronome.perform { try metronome.resetSettings() }
            }
        } message: {
            Text("所有节拍器设置都将恢复默认值。已保存的曲目预设会保留。")
        }
        .manageSubscriptionsSheet(isPresented: $showingSubscriptionManagement)
        .onChange(of: showingSubscriptionManagement) { _, isShowing in
            if !isShowing { Task { await metronome.subscription.refresh() } }
        }
    }

    private var audioSection: some View {
        Section("音频") {
            LabeledContent("音色") {
                BeatSoundMenu(metronome: metronome, identifier: "settings-sound-option")
                    .frame(width: 118, height: 44)
            }
            VStack(alignment: .leading) {
                Text("音量")
                Slider(value: metronome.option(\.volume), in: 0...1)
                    .accessibilityLabel("音量")
            }
            VStack(alignment: .leading) {
                Text("声道平衡")
                Slider(value: metronome.option(\.balance), in: -1...1, step: 0.05) {
                    Text("声道平衡")
                } minimumValueLabel: {
                    Text("左")
                } maximumValueLabel: {
                    Text("右")
                }
            }
            Toggle("与其他 App 混音", isOn: metronome.option(\.mixWithOthers))
        }
    }

    private var latencySection: some View {
        Section("输出延迟校准") {
            LabeledContent("当前输出", value: metronome.outputName)
            LabeledContent("系统输出延迟") {
                Text("\(metronome.latencyMilliseconds, specifier: "%.1f") 毫秒").monospacedDigit()
            }
            Stepper("手动补偿 \(metronome.preferences.offsetMilliseconds) 毫秒",
                    value: metronome.option(\.offsetMilliseconds), in: -500...500)
            Text("正值让拍点提示延后，负值让它提前。蓝牙输出时可边听边调。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var rangeSection: some View {
        Section("速度与拍号") {
            Toggle("专业速度范围（20–300）", isOn: metronome.option(\.professionalTempo))
            Toggle("显示意大利语速度标记", isOn: metronome.option(\.showTempoMark))
            Toggle("扩展至每小节 32 拍", isOn: metronome.option(\.extendedMeter))
        }
    }

    private var trainingSection: some View {
        let trainer = metronome.preferences.trainer
        let range = metronome.preferences.tempoRange
        return Section("渐快训练") {
            Toggle("开启渐快训练", isOn: metronome.option(\.trainer.enabled))
            if trainer.enabled {
                Stepper("起始速度 \(trainer.start)", value: metronome.option(\.trainer.start), in: range)
                Stepper("目标速度 \(trainer.target)", value: metronome.option(\.trainer.target),
                        in: trainer.start...range.upperBound)
                Stepper("每次加快 \(trainer.step) 拍", value: metronome.option(\.trainer.step), in: 1...50)
                Stepper("每 \(trainer.bars) 小节递增", value: metronome.option(\.trainer.bars), in: 1...64)
            }
        }
    }

    private var ghostSection: some View {
        let ghost = metronome.preferences.ghost
        return Section("间歇静音") {
            Toggle("开启间歇静音", isOn: metronome.option(\.ghost.enabled))
            if ghost.enabled {
                Stepper("发声 \(ghost.audible) 小节", value: metronome.option(\.ghost.audible), in: 1...64)
                Stepper("静音 \(ghost.silent) 小节", value: metronome.option(\.ghost.silent), in: 1...64)
            }
        }
    }

    private var feedbackSection: some View {
        Section("反馈与屏幕") {
            Toggle("播放时保持屏幕常亮", isOn: metronome.option(\.keepAwake))
            Toggle("圆环随拍闪烁", isOn: metronome.option(\.flash))
            Toggle("节拍触觉反馈", isOn: metronome.option(\.haptics))
                .disabled(!BeatHaptics.available)
        }
    }
}

@MainActor
struct BeatSoundMenu: View {
    @ObservedObject var metronome: Metronome
    let identifier: String

    private static let displayOrder: [BeatSound] = [
        .mechanical, .wood, .electronic, .voice, .bell, .softTap, .shortDrum
    ]

    var body: some View {
        StableOptionMenu(title: String(localized: "音色"), selection: metronome.settings.sound.title,
                         options: Self.displayOrder.map(\.title), identifier: identifier) { value in
            if let sound = Self.displayOrder.first(where: { $0.title == value }) {
                metronome.perform { try metronome.selectSound(sound) }
            }
        }
    }
}

@MainActor
struct StableOptionMenu: UIViewRepresentable {
    let title: String
    let selection: String
    let options: [String]
    let identifier: String
    var compactWidth: CGFloat?
    let select: (String) -> Void

    @MainActor
    final class Coordinator {
        var selection: String?
        var options: [String] = []
        var accessibilityTitle: String?
        var contentSizeCategory: UIContentSizeCategory?
        var compactWidth: CGFloat?
        var select: ((String) -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        button.accessibilityIdentifier = identifier
        if compactWidth != nil {
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        guard let compactWidth else { return nil }
        return CGSize(width: compactWidth, height: proposal.height ?? 44)
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let coordinator = context.coordinator
        button.isEnabled = context.environment.isEnabled
        coordinator.select = button.isEnabled ? select : nil
        let category = button.traitCollection.preferredContentSizeCategory
        let menuChanged = coordinator.selection != selection || coordinator.options != options
        // Playback can redraw the parent on every beat. Keep the open menu and its selection intact.
        guard menuChanged || coordinator.accessibilityTitle != title || coordinator.contentSizeCategory != category
                || coordinator.compactWidth != compactWidth else { return }
        coordinator.selection = selection
        coordinator.options = options
        coordinator.accessibilityTitle = title
        coordinator.contentSizeCategory = category
        coordinator.compactWidth = compactWidth

        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: button.traitCollection)
        let chevron = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10))
        let horizontalInset: CGFloat = 7
        let imagePadding: CGFloat = 5
        var configuration: UIButton.Configuration
        if #available(iOS 26, *) {
            configuration = .glass()
        } else {
            configuration = .filled()
            configuration.baseBackgroundColor = UIColor(MetronomePalette.surface)
        }
        configuration.title = selection
        if compactWidth != nil {
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = font
                return attributes
            }
        }
        configuration.baseForegroundColor = UIColor(MetronomePalette.cyan)
        configuration.cornerStyle = .capsule
        configuration.image = chevron
        configuration.imagePlacement = .trailing
        configuration.imagePadding = imagePadding
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset)
        configuration.titleLineBreakMode = .byTruncatingTail
        button.configuration = configuration
        button.titleLabel?.minimumScaleFactor = 0.6
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.accessibilityLabel = title
        button.accessibilityValue = selection
        if menuChanged {
            button.menu = UIMenu(children: options.map { option in
                UIAction(title: option, state: option == selection ? .on : .off) { [weak coordinator] _ in
                    coordinator?.select?(option)
                }
            })
        }
    }
}

@MainActor
struct MetronomePresetsView: View {
    @ObservedObject var metronome: Metronome
    var showsCloseButton = false
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    @State private var editing: UUID?
    @State private var pendingDeletion: MetronomePreset?
    @State private var name = ""
    @State private var naming = false

    var body: some View {
        List {
            Section {
                Button("保存当前设置", systemImage: "plus") { edit(nil) }
                    .disabled(editMode.isEditing)
            }
            ForEach(metronome.presets) { preset in
                Button {
                    guard !editMode.isEditing else { return }
                    do {
                        try metronome.loadPreset(preset)
                        dismiss()
                    } catch {
                        metronome.error = error.localizedDescription
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.name)
                        Text("\(preset.settings.bpm) · \(preset.settings.meter) · \(preset.settings.rhythm.title)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button("删除", systemImage: "trash", role: .destructive) { pendingDeletion = preset }
                    Button("重命名", systemImage: "pencil") { edit(preset) }
                        .tint(.blue)
                }
                .contextMenu {
                    Button("重命名", systemImage: "pencil") { edit(preset) }
                    Button("删除", systemImage: "trash", role: .destructive) { pendingDeletion = preset }
                }
            }
            .onMove(perform: metronome.movePresets)
        }
        .navigationTitle("曲目预设")
        .toolbar {
            if metronome.presets.count > 1 || editMode.isEditing {
                ToolbarItem(placement: showsCloseButton ? .topBarLeading : .topBarTrailing) {
                    EditButton()
                }
            }
            if showsCloseButton && !editMode.isEditing {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .alert(editing == nil ? LocalizedStringKey("保存曲目") : LocalizedStringKey("重命名曲目"), isPresented: $naming) {
            TextField("曲目名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let editing { metronome.renamePreset(editing, to: name) }
                else { metronome.savePreset(named: name) }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("删除曲目预设？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { preset in
            Button("删除", role: .destructive) { metronome.deletePreset(preset.id) }
        } message: { preset in
            Text(preset.name)
        }
    }

    private func edit(_ preset: MetronomePreset?) {
        editing = preset?.id
        name = preset?.name ?? ""
        naming = true
    }
}
