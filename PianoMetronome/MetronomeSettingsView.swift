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
                    Button("管理订阅") { showingSubscriptionManagement = true }
                    NavigationLink("隐私政策") { MetronomePrivacyPolicyView() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
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

    var body: some View {
        StableOptionMenu(title: String(localized: "音色"), selection: metronome.settings.sound.title,
                         options: BeatSound.allCases.map(\.title), identifier: identifier) { value in
            if let sound = BeatSound.allCases.first(where: { $0.title == value }) {
                metronome.setting(\.sound).wrappedValue = sound
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
        coordinator.select = select
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
        Group {
            if editMode == .active {
                PresetReorderList(metronome: metronome)
            } else {
                presetList
            }
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

    private var presetList: some View {
        List {
            Section {
                Button("保存当前设置", systemImage: "plus") { edit(nil) }
            }
            ForEach(metronome.presets) { preset in
                Button {
                    do {
                        try metronome.loadPreset(preset)
                        dismiss()
                    } catch {
                        metronome.error = error.localizedDescription
                    }
                } label: {
                    PresetRowLabel(preset: preset)
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
        }
    }

    private func edit(_ preset: MetronomePreset?) {
        editing = preset?.id
        name = preset?.name ?? ""
        naming = true
    }
}

private struct PresetRowLabel: View {
    let preset: MetronomePreset

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preset.name)
            Text("\(preset.settings.bpm) · \(preset.settings.meter) · \(preset.settings.rhythm.title)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct PresetReorderList: UIViewRepresentable {
    @ObservedObject var metronome: Metronome

    func makeCoordinator() -> Coordinator { Coordinator(metronome: metronome) }

    func makeUIView(context: Context) -> UITableView {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "preset")
        table.dataSource = context.coordinator
        table.dragDelegate = context.coordinator
        table.dropDelegate = context.coordinator
        table.dragInteractionEnabled = true
        table.allowsSelection = false
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 56
        return table
    }

    func updateUIView(_ table: UITableView, context: Context) {
        context.coordinator.reloadIfChanged(table)
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDragDelegate, UITableViewDropDelegate {
        private let metronome: Metronome
        private var presets: [MetronomePreset]
        private let presetsSection = 1

        init(metronome: Metronome) {
            self.metronome = metronome
            presets = metronome.presets
        }

        func reloadIfChanged(_ table: UITableView) {
            guard !table.hasActiveDrag, presets != metronome.presets else { return }
            presets = metronome.presets
            table.reloadData()
        }

        func numberOfSections(in tableView: UITableView) -> Int { 2 }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            section == presetsSection ? presets.count : 1
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "preset", for: indexPath)
            if indexPath.section == presetsSection {
                let preset = presets[indexPath.row]
                cell.contentConfiguration = UIHostingConfiguration {
                    HStack {
                        PresetRowLabel(preset: preset)
                        Spacer(minLength: 8)
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                cell.accessibilityCustomActions = [
                    moveAction(String(localized: "上移"), by: -1, preset: preset.id, in: tableView),
                    moveAction(String(localized: "下移"), by: 1, preset: preset.id, in: tableView)
                ]
            } else {
                cell.contentConfiguration = UIHostingConfiguration {
                    Label("保存当前设置", systemImage: "plus")
                        .foregroundStyle(.secondary)
                        .disabled(true)
                }
                cell.accessibilityCustomActions = nil
            }
            return cell
        }

        func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession,
                       at indexPath: IndexPath) -> [UIDragItem] {
            guard indexPath.section == presetsSection, presets.count > 1,
                  let cell = tableView.cellForRow(at: indexPath) else { return [] }
            let preset = presets[indexPath.row]
            session.localContext = self
            let item = UIDragItem(itemProvider: NSItemProvider(object: preset.id.uuidString as NSString))
            item.localObject = preset.id
            let preview = makePreview(for: preset.name, cell: cell)
            item.previewProvider = { preview }
            return [item]
        }

        func tableView(_ tableView: UITableView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
            true
        }

        func tableView(_ tableView: UITableView, dragSessionDidEnd session: UIDragSession) {
            Task { reloadIfChanged(tableView) }
        }

        func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
            session.localDragSession?.localContext as? Coordinator === self && session.items.count == 1
        }

        func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession,
                       withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
            guard self.tableView(tableView, canHandle: session),
                  destinationIndexPath?.section == presetsSection else {
                return UITableViewDropProposal(operation: .cancel)
            }
            return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }

        func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
            guard let item = coordinator.items.first, let source = item.sourceIndexPath,
                  let id = item.dragItem.localObject as? UUID,
                  let proposed = coordinator.destinationIndexPath, proposed.section == presetsSection,
                  source.section == presetsSection, presets.indices.contains(source.row),
                  presets[source.row].id == id, presets == metronome.presets else { return }
            let destination = IndexPath(row: min(proposed.row, presets.count - 1), section: presetsSection)
            if source == destination || move(in: tableView, from: source, to: destination) {
                coordinator.drop(item.dragItem, toRowAt: destination)
            }
        }

        private func move(in table: UITableView, from source: IndexPath, to destination: IndexPath) -> Bool {
            let offset = destination.row > source.row ? destination.row + 1 : destination.row
            guard metronome.movePresets(fromOffsets: IndexSet(integer: source.row), toOffset: offset) else {
                return false
            }
            table.performBatchUpdates {
                self.presets = self.metronome.presets
                table.deleteRows(at: [source], with: .automatic)
                table.insertRows(at: [destination], with: .automatic)
            }
            return true
        }

        private func moveAction(_ title: String, by offset: Int, preset: UUID,
                                in table: UITableView) -> UIAccessibilityCustomAction {
            UIAccessibilityCustomAction(name: title) { [weak self, weak table] _ in
                guard let self, let table, presets == metronome.presets,
                      let row = presets.firstIndex(where: { $0.id == preset }),
                      presets.indices.contains(row + offset) else { return false }
                return move(in: table, from: IndexPath(row: row, section: presetsSection),
                            to: IndexPath(row: row + offset, section: presetsSection))
            }
        }

        private func makePreview(for name: String, cell: UITableViewCell) -> UIDragPreview {
            let bounds = CGRect(x: 0, y: 0, width: min(cell.bounds.width * 0.75, 360), height: cell.bounds.height)
            let capsule = UIView(frame: bounds)
            capsule.backgroundColor = UIColor.tertiarySystemGroupedBackground.resolvedColor(with: cell.traitCollection)
            capsule.layer.cornerRadius = bounds.height / 2

            let label = UILabel(frame: bounds.insetBy(dx: 20, dy: 0))
            label.text = name
            label.font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: cell.traitCollection)
            label.textColor = UIColor.label.resolvedColor(with: cell.traitCollection)
            label.lineBreakMode = .byTruncatingTail
            capsule.addSubview(label)

            let path = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2)
            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = path
            parameters.shadowPath = path
            return UIDragPreview(view: capsule, parameters: parameters)
        }
    }
}
