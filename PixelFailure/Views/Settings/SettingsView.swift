import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, interface, tools, guides, smartSelection, generators, export, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .interface: "Interface"
        case .tools: "Tools"
        case .guides: "Guides & Grid"
        case .smartSelection: "Smart Selection"
        case .generators: "Generators"
        case .export: "Export"
        case .shortcuts: "Keyboard Shortcuts"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .interface: "macwindow"
        case .tools: "paintbrush.pointed"
        case .guides: "squareshape.split.3x3"
        case .smartSelection: "sparkles.rectangle.stack"
        case .generators: "dice"
        case .export: "square.and.arrow.up"
        case .shortcuts: "keyboard"
        }
    }
}

/// The Settings window (⌘,): a category sidebar and the selected pane.
struct SettingsView: View {
    @AppStorage("settings.pane") private var pane: SettingsPane = .general
    @State private var confirmsShortcutReset = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                Group {
                    switch pane {
                    case .shortcuts: ShortcutsSettingsPane()
                    default:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) { paneContent }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 18)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.panel)
        }
        .frame(width: 840, height: 600)
        // Innermost style wins: ours must sit inside panelStyle's.
        .labeledContentStyle(SettingsLabeledContentStyle())
        .panelStyle()
        .navigationTitle(pane.title)
        .confirmationDialog("Restore all keyboard shortcuts to their defaults?",
                            isPresented: $confirmsShortcutReset) {
            Button("Restore Defaults", role: .destructive) { ShortcutStore.shared.resetAll() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { item in
                if item == .shortcuts {
                    Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 6)
                }
                SettingsSidebarRow(title: item.title, icon: item.icon, isSelected: pane == item) {
                    pane = item
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Theme.header)
        .hairline(.trailing)
    }

    private var header: some View {
        HStack {
            Text(pane.title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("Restore Defaults") { restoreDefaults() }
                .disabled(pane == .shortcuts && !ShortcutStore.shared.hasCustomizations)
        }
        .padding(.horizontal, 24)
        .frame(height: 52)
        .hairline(.bottom)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .general: GeneralSettings()
        case .interface: InterfaceSettings()
        case .tools: ToolSettings()
        case .guides: GuideSettings()
        case .smartSelection: SmartSelectionSettings()
        case .generators: GeneratorSettings()
        case .export: ExportSettings()
        case .shortcuts: EmptyView()
        }
    }

    private func restoreDefaults() {
        let prefs = Preferences.shared
        switch pane {
        case .general: prefs.resetGeneral()
        case .interface: prefs.resetInterface()
        case .tools: prefs.resetTools()
        case .guides: prefs.resetGuides()
        case .smartSelection: prefs.resetSmartSelection()
        case .generators: prefs.resetGenerators()
        case .export: prefs.resetExport()
        case .shortcuts: confirmsShortcutReset = true
        }
    }
}

// MARK: - Panes

private struct GeneralSettings: View {
    @Bindable private var prefs = Preferences.shared
    @AppStorage(LaunchAction.defaultsKey) private var launchAction: LaunchAction = .home
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false

    var body: some View {
        SettingsGroup("Startup") {
            LabeledContent("On Launch") {
                Picker("On Launch", selection: $launchAction) {
                    ForEach(LaunchAction.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            LabeledContent("Welcome") {
                Button("Show on Next Document") { didCompleteOnboarding = false }
                    .disabled(!didCompleteOnboarding)
            }
        }
        SettingsGroup("History") {
            LabeledContent("History States") {
                SettingsNumber(value: Binding(get: { Double(prefs.historyStates) },
                                              set: { prefs.historyStates = Int($0) }),
                               range: 10...2000, step: 10, unit: "undo steps")
            }
        }
        SettingsGroup("Crash Recovery") {
            SettingsToggle("Save Recovery Data", isOn: $prefs.autoRecoveryEnabled)
            LabeledContent("Save After") {
                Picker("Save After", selection: $prefs.autoRecoveryDelay) {
                    Text("2 seconds idle").tag(2.0)
                    Text("10 seconds idle").tag(10.0)
                    Text("30 seconds idle").tag(30.0)
                    Text("1 minute idle").tag(60.0)
                    Text("5 minutes idle").tag(300.0)
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(!prefs.autoRecoveryEnabled)
        }
    }
}

private struct InterfaceSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup("Canvas") {
            LabeledContent("Surround") {
                HStack(spacing: 8) {
                    Picker("Surround", selection: $prefs.canvasSurround) {
                        ForEach(Preferences.CanvasSurround.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if prefs.canvasSurround == .custom {
                        ColorPicker("Custom", selection: prefs.colorBinding(\.customSurroundHex),
                                    supportsOpacity: false)
                            .labelsHidden()
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(prefs.canvasSurroundColor)
                            .stroke(Theme.fieldBorder, lineWidth: 1)
                            .frame(width: 38, height: 18)
                    }
                }
            }
            SettingsToggle("Show Status Bar", isOn: $prefs.showsStatusBar)
        }
        SettingsGroup("Panels") {
            SettingsToggle("Show Shortcuts in Tooltips", isOn: $prefs.showsShortcutsInTooltips)
            LabeledContent("Panel Layout") {
                Button("Reset Collapsed Sections") { prefs.resetPanelLayout() }
            }
        }
    }
}

private struct ToolSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup("Tool Keys") {
            SettingsToggle("Use Shift Key for Tool Switch", isOn: $prefs.useShiftForToolSwitch)
                .help("On: ⇧ + key cycles tools that share a key. Off: press the key again.")
            SettingsToggle("Spring-Loaded Tools", isOn: $prefs.springLoadedTools)
                .help("Hold a tool key to use the tool briefly; release to switch back")
        }
        SettingsGroup("Navigation") {
            SettingsToggle("Zoom with Scroll Wheel", isOn: $prefs.zoomWithScrollWheel)
                .help("Scroll zooms; ⌥ or ⌘ + scroll pans")
            SettingsToggle("Zoom Tool Zooms on Clicked Point", isOn: $prefs.zoomToClickedPoint)
        }
        SettingsGroup("Move & Snap") {
            LabeledContent("Nudge") {
                SettingsNumber(value: $prefs.nudgeDistance, range: 0.1...100, step: 1, unit: "px",
                               fractionDigits: 1)
            }
            LabeledContent("Shift-Nudge") {
                SettingsNumber(value: $prefs.shiftNudgeDistance, range: 1...1000, step: 5, unit: "px")
            }
            LabeledContent("Snap Distance") {
                SettingsNumber(value: $prefs.snapDistance, range: 1...40, step: 1, unit: "screen px")
            }
        }
        SettingsGroup("Painting") {
            LabeledContent("Brush Cursor") {
                Picker("Brush Cursor", selection: $prefs.brushCursor) {
                    ForEach(Preferences.BrushCursor.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("⇪ Caps Lock switches to the precise cursor")
            }
            LabeledContent("Default Colors") {
                HStack(spacing: 6) {
                    ColorPicker("Foreground", selection: prefs.colorBinding(\.defaultForegroundHex),
                                supportsOpacity: false)
                        .labelsHidden()
                    Text("Foreground").foregroundStyle(Theme.textDim)
                    ColorPicker("Background", selection: prefs.colorBinding(\.defaultBackgroundHex),
                                supportsOpacity: false)
                        .labelsHidden()
                        .padding(.leading, 10)
                    Text("Background").foregroundStyle(Theme.textDim)
                }
                .fixedSize()
                .help("Restored with " + (ShortcutStore.shared.combo(for: .defaultColors)?.displayString ?? "Default Colors"))
            }
        }
    }
}

private struct GuideSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup("Guides") {
            LabeledContent("Guide Color") {
                ColorPicker("Guide Color", selection: prefs.colorBinding(\.guideColorHex), supportsOpacity: false)
                    .labelsHidden()
            }
            LabeledContent("Smart Guides") {
                ColorPicker("Smart Guides", selection: prefs.colorBinding(\.smartGuideColorHex),
                            supportsOpacity: false)
                    .labelsHidden()
            }
        }
        SettingsGroup("Grid") {
            LabeledContent("Grid Color") {
                ColorPicker("Grid Color", selection: prefs.colorBinding(\.gridColorHex), supportsOpacity: false)
                    .labelsHidden()
            }
            LabeledContent("Grid Opacity") {
                NumericSlider(value: $prefs.gridOpacity, range: 0.03...1, defaultValue: 0.13, percent: true)
                    .frame(width: 220)
            }
            SettingsToggle("Pixel Grid at 600% and Above", isOn: $prefs.showsPixelGrid)
        }
        SettingsGroup("Selection") {
            SettingsToggle("Animate Selection Edges", isOn: $prefs.animatesSelectionEdges)
        }
    }
}

private struct SmartSelectionSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup("Object Select") {
            SettingsToggle("Highlight Object Under Pointer", isOn: $prefs.smartSelectHoverPreview)
            SettingsToggle("Analyze Image When Tool Is Chosen", isOn: $prefs.smartSelectPrefetch)
                .help("Makes the first hover and click instant at the cost of background work")
        }
        SettingsGroup("Selection Defaults") {
            LabeledContent("Feather") {
                SettingsNumber(value: $prefs.defaultFeather, range: 0...80, step: 1, unit: "px")
            }
            LabeledContent("Wand Tolerance") {
                NumericSlider(value: $prefs.defaultWandTolerance, range: 0.02...0.9,
                              defaultValue: 0.25, percent: true)
                    .frame(width: 220)
            }
        }
    }
}

private struct GeneratorSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup("New Pattern Layers") {
            LabeledContent("Parameters") {
                Picker("Parameters", selection: $prefs.newPatternParameters) {
                    ForEach(Preferences.NewPatternParameters.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        SettingsGroup("Randomize") {
            SettingsToggle("Also Pick a New Palette", isOn: $prefs.randomizeSwitchesPalette)
        }
    }
}

private struct ExportSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup("Defaults") {
            LabeledContent("Format") {
                Picker("Format", selection: $prefs.defaultExportFormat) {
                    ForEach(ExportSheet.Format.allCases.filter(\.isAvailable), id: \.self) {
                        Text($0.rawValue).tag($0.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsToggle("Remember Last Used Format", isOn: $prefs.rememberExportFormat)
            LabeledContent("Lossy Quality") {
                NumericSlider(value: $prefs.defaultExportQuality, range: 0.5...1, defaultValue: 0.9, percent: true)
                    .frame(width: 220)
            }
        }
    }
}

// MARK: - Components

/// A titled box of settings rows.
struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.headerFont)
                .foregroundStyle(Theme.textDim)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.header, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        }
    }
}

/// A checkbox aligned to the control column.
struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        // Checkbox then title, in the control column (empty label column).
        HStack(spacing: 6) {
            Toggle(title, isOn: $isOn).labelsHidden()
            Text(title)
                .foregroundStyle(Theme.text)
                .onTapGesture { isOn.toggle() }
        }
        .padding(.leading, SettingsLabeledContentStyle.labelWidth + 12)
        .frame(minHeight: 22)
    }
}

/// Value box + stepper + unit.
struct SettingsNumber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    var fractionDigits = 0

    var body: some View {
        HStack(spacing: 6) {
            PanelNumberField(label: nil, value: Binding(
                get: { value },
                set: { value = min(max($0, range.lowerBound), range.upperBound) }
            ), fractionDigits: fractionDigits, width: 60)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
            if !unit.isEmpty {
                Text(unit).foregroundStyle(Theme.textFaint)
            }
        }
    }
}

struct SettingsLabeledContentStyle: LabeledContentStyle {
    static let labelWidth: CGFloat = 150

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .trailing)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 22)
    }
}

private struct SettingsSidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.text : Theme.icon)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.text : Theme.textDim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(isSelected ? Theme.rowSelected : (isHovering ? Theme.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
