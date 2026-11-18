import SwiftUI

/// Preset browser on the left, editable preset details on the right —
/// the Photoshop New Document layout.
struct NewDocumentPane: View {
    let launcher: DocumentLauncher
    let close: () -> Void

    @Bindable private var home = HomeModel.shared
    @State private var store = NewDocumentStore.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("New Document")
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 32)
                    .padding(.top, 44)
                    .padding(.bottom, 18)

                CategoryBar(selection: $home.category)

                ScrollView {
                    presetGrid
                        .padding(.horizontal, 32)
                        .padding(.vertical, 22)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            PresetDetails(settings: $home.draft,
                          create: { launcher.create(home.draft) },
                          close: close)
                .frame(width: 300)
        }
        .onChange(of: home.draft) { _, draft in
            // A preset stays selected only while the size still matches it.
            if let id = home.selectedPresetID,
               let preset = store.presets(in: home.category).first(where: { $0.id == id }),
               !draft.hasSameFormat(as: preset.settings) {
                home.selectedPresetID = nil
            }
        }
    }

    @ViewBuilder
    private var presetGrid: some View {
        let presets = store.presets(in: home.category)
        if presets.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: home.category == .saved ? "bookmark" : "clock")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.textFaint)
                Text(home.category == .saved ? "No saved presets" : "No recent documents")
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 148), spacing: 14)],
                      alignment: .leading, spacing: 14) {
                ForEach(presets) { preset in
                    FormatTile(title: preset.name,
                               subtitle: preset.settings.dimensionSummary,
                               size: preset.settings.pixelSize,
                               isSelected: home.selectedPresetID == preset.id) {
                        select(preset)
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        select(preset)
                        launcher.create(home.draft)
                    })
                    .contextMenu {
                        Button("Create") {
                            select(preset)
                            launcher.create(home.draft)
                        }
                        if home.category == .saved || home.category == .recent {
                            Divider()
                            Button(home.category == .saved ? "Delete Preset" : "Remove from Recent") {
                                store.remove(preset.settings, from: home.category)
                            }
                        }
                    }
                }
            }
        }
    }

    private func select(_ preset: DocumentPreset) {
        switch home.category {
        case .recent, .saved:
            // Remembered entries carry their full setup, not just the size.
            home.draft = preset.settings
        default:
            home.draft = home.draft.applyingFormat(of: preset.settings)
        }
        home.selectedPresetID = preset.id
    }
}

private struct CategoryBar: View {
    @Binding var selection: PresetCategory

    var body: some View {
        HStack(spacing: 22) {
            ForEach(PresetCategory.allCases, id: \.self) { category in
                let isSelected = category == selection
                VStack(spacing: 7) {
                    Text(category.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.text : Theme.textDim)
                    Rectangle()
                        .fill(isSelected ? Theme.accent : .clear)
                        .frame(height: 2)
                }
                .fixedSize()
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = category
                    HomeModel.shared.selectedPresetID = nil
                }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }
}

// MARK: - Details

private struct PresetDetails: View {
    @Binding var settings: NewDocumentSettings
    let create: () -> Void
    let close: () -> Void

    @State private var isSavingPreset = false
    @State private var presetName = ""
    @State private var userPalettes = UserPaletteStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preset Details")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    presetName = settings.name == "Untitled" ? "" : settings.name
                    isSavingPreset = true
                } label: {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(IconButtonStyle())
                .help("Save Preset")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.top, 44)
            .padding(.bottom, 10)

            TextField("Name", text: $settings.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.fieldBorder, lineWidth: 1))
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Rectangle().fill(Theme.separator).frame(height: 1)

            ScrollView {
                VStack(spacing: 0) {
                    InspectorSection("Canvas Size") { sizeRows }
                    InspectorSection("Color Mode") { colorRows }
                    InspectorSection("Starting Content") { contentRows }
                    InspectorSection("Workspace") { layoutRows }
                }
                .padding(.top, 2)
            }

            HStack(spacing: 8) {
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .tint(Theme.accent)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(14)
            .hairline(.top)
        }
        .panelStyle()
        .background(Theme.panel)
        .hairline(.leading)
        .alert("Save Preset", isPresented: $isSavingPreset) {
            TextField("Preset Name", text: $presetName)
            Button("Save") {
                var preset = settings
                let name = presetName.trimmingCharacters(in: .whitespaces)
                preset.name = name.isEmpty ? settings.dimensionSummary : name
                NewDocumentStore.shared.savePreset(preset)
                HomeModel.shared.category = .saved
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Canvas size

    @ViewBuilder
    private var sizeRows: some View {
        LabeledContent("Width") {
            HStack(spacing: 6) {
                PanelNumberField(label: nil, value: dimension(\.width),
                                 fractionDigits: settings.unit.fractionDigits, width: 84)
                Picker("Unit", selection: unit) {
                    ForEach(MeasurementUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 96)
            }
        }
        LabeledContent("Height") {
            HStack(spacing: 6) {
                PanelNumberField(label: nil, value: dimension(\.height),
                                 fractionDigits: settings.unit.fractionDigits, width: 84)
                Button { setPortrait(true) } label: { Image(systemName: "rectangle.portrait") }
                    .buttonStyle(IconButtonStyle(size: 22, isActive: settings.height > settings.width))
                    .help("Portrait")
                Button { setPortrait(false) } label: { Image(systemName: "rectangle") }
                    .buttonStyle(IconButtonStyle(size: 22, isActive: settings.width > settings.height))
                    .help("Landscape")
            }
        }
        LabeledContent("Resolution") {
            HStack(spacing: 6) {
                PanelNumberField(label: nil, value: resolution, fractionDigits: 0, width: 84)
                Text("ppi").foregroundStyle(Theme.textDim)
            }
        }
        LabeledContent("Image Size") {
            Text(imageSizeSummary)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textDim)
        }
    }

    /// Width/height shown in the chosen unit, stored in pixels.
    private func dimension(_ keyPath: WritableKeyPath<NewDocumentSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings.unit.fromPixels(settings[keyPath: keyPath], dpi: settings.dpi) },
            set: { value in
                settings[keyPath: keyPath] = NewDocumentSettings.clampDimension(
                    settings.unit.toPixels(value, dpi: settings.dpi))
            })
    }

    private var unit: Binding<MeasurementUnit> {
        Binding(get: { settings.unit }, set: { settings.unit = $0 })
    }

    /// With a physical unit, changing resolution keeps the printed size and
    /// resamples the pixel count — as in Photoshop.
    private var resolution: Binding<Double> {
        Binding(
            get: { settings.dpi },
            set: { newValue in
                let dpi = min(max(newValue, 1), 2400)
                if settings.unit != .pixels {
                    let w = settings.unit.fromPixels(settings.width, dpi: settings.dpi)
                    let h = settings.unit.fromPixels(settings.height, dpi: settings.dpi)
                    settings.width = NewDocumentSettings.clampDimension(settings.unit.toPixels(w, dpi: dpi))
                    settings.height = NewDocumentSettings.clampDimension(settings.unit.toPixels(h, dpi: dpi))
                }
                settings.dpi = dpi
            })
    }

    private func setPortrait(_ portrait: Bool) {
        let isPortrait = settings.height > settings.width
        guard portrait != isPortrait, settings.width != settings.height else { return }
        (settings.width, settings.height) = (settings.height, settings.width)
    }

    private var imageSizeSummary: String {
        let size = settings.pixelSize
        let bytes = size.width * size.height * 4 * Double(settings.bitDepth.rawValue / 8)
        let memory = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        return "\(Int(size.width)) × \(Int(size.height)) px  ·  \(memory)"
    }

    // MARK: Color

    @ViewBuilder
    private var colorRows: some View {
        PanelPicker("Color Space", selection: $settings.workingSpace) {
            ForEach(WorkingColorSpace.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        PanelPicker("Bit Depth", selection: $settings.bitDepth) {
            ForEach(RasterBitDepth.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        LabeledContent("Background") {
            HStack(spacing: 6) {
                Picker("Background", selection: $settings.background) {
                    ForEach(BackgroundChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                ColorPicker("Background Color", selection: backgroundColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44)
            }
        }
    }

    /// Picking a color switches the choice to Custom.
    private var backgroundColor: Binding<Color> {
        Binding(
            get: { settings.backgroundColor.color },
            set: { color in
                settings.customBackground = RGBAColor(colorValue: color)
                settings.background = .custom
            })
    }

    // MARK: Content

    @ViewBuilder
    private var contentRows: some View {
        PanelPicker("Start With", selection: $settings.starterGenerator) {
            Text("Blank").tag(GeneratorType?.none)
            Divider()
            ForEach(GeneratorType.allCases.filter { $0 != .sampledGrid }, id: \.self) { type in
                Text(type.displayName).tag(GeneratorType?.some(type))
            }
        }
        PanelPicker("Palette", selection: $settings.palette) {
            ForEach(BuiltInPalettes.all, id: \.self) { Text($0.name).tag($0) }
            if !userPalettes.palettes.isEmpty {
                Divider()
                ForEach(userPalettes.palettes, id: \.self) { Text($0.name).tag($0) }
            }
        }
        LabeledContent("") {
            HStack(spacing: 0) {
                ForEach(Array(settings.palette.colors.enumerated()), id: \.offset) { _, color in
                    Rectangle().fill(color.color)
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.fieldBorder, lineWidth: 1))
        }
    }

    // MARK: Layout

    @ViewBuilder
    private var layoutRows: some View {
        PanelPicker("Guides", selection: $settings.guides) {
            ForEach(GuideLayout.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        LabeledContent("Show") {
            HStack(spacing: 14) {
                Toggle("Rulers", isOn: $settings.showsRulers)
                Toggle("Grid", isOn: $settings.showsGrid)
            }
        }
    }
}
