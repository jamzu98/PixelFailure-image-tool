import AppKit
import SwiftUI

struct TextInspector: View {
    @ObservedObject var document: PixelDocument
    let layerID: UUID
    let config: TextConfig
    @Environment(\.undoManager) private var undoManager
    @FocusState private var textFocused: Bool
    @State private var rangeStart = 0
    @State private var rangeLength = 1

    var body: some View {
        Section("Text") {
            TextEditor(text: textBinding)
                .font(.body)
                .frame(minHeight: 48, maxHeight: 96)
                .focused($textFocused)
                .onChange(of: textFocused) { _, focused in
                    // One undo step per editing session instead of per keystroke.
                    if focused {
                        document.beginGesture()
                    } else {
                        document.endGesture(undoManager, actionName: "Edit Text")
                    }
                }

            FontFamilyPicker(selection: modify(\.fontFamily, action: "Font"),
                             families: availableFamilies)

            Picker("Weight", selection: modify(\.weight, action: "Weight")) {
                ForEach(FontWeightChoice.allCases, id: \.self) { weight in
                    Text(weight.displayName).tag(weight)
                }
            }

            Toggle("Italic", isOn: modify(\.italic, action: "Italic"))
            Toggle("All Caps", isOn: modify(\.allCaps, action: "All Caps"))

            sliderRow("Size", value: \.size, range: 8...800, defaultValue: 160, action: "Text Size")
            sliderRow("Tracking", value: \.tracking, range: -20...120, defaultValue: 8, action: "Tracking")
            sliderRow("Line Height", value: \.lineHeight, range: 0.7...2.2, defaultValue: 1.1, action: "Line Height")

            Picker("Alignment", selection: modify(\.alignment, action: "Alignment")) {
                ForEach(TextAlignmentChoice.allCases, id: \.self) { alignment in
                    Text(alignment.displayName).tag(alignment)
                }
            }
            .pickerStyle(.segmented)

            ColorPicker("Color", selection: Binding(
                get: { config.color.color(in: document.model.colorSettings.workingSpace) },
                set: { newValue in
                    document.update(undoManager, actionName: "Text Color") { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyText { $0.color = RGBAColor(colorValue: newValue, in: document.model.colorSettings.workingSpace) }
                        }
                    }
                }
            ))

            Toggle("Paragraph Box", isOn: Binding(
                get: { config.boxSize != nil },
                set: { enabled in
                    document.update(undoManager, actionName: "Paragraph Box") { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyText { $0.boxSize = enabled ? CGSize(width: 700, height: 420) : nil }
                        }
                    }
                }))
            if let box = config.boxSize {
                LabeledContent("Box Size") {
                    TextField("W", value: Binding(
                        get: { Double(box.width) },
                        set: { value in setBox(width: max(value, 40), height: box.height) }),
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 62)
                    Text("×")
                    TextField("H", value: Binding(
                        get: { Double(box.height) },
                        set: { value in setBox(width: box.width, height: max(value, 40)) }),
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 62)
                }
                Picker("Vertical", selection: Binding(
                    get: { config.verticalAlignment ?? .top },
                    set: { value in document.update(undoManager, actionName: "Vertical Alignment") {
                        $0.modifyLayer(id: layerID) { $0.modifyText { $0.verticalAlignment = value } }
                    }})) {
                    ForEach(TextVerticalAlignment.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            DisclosureGroup("OpenType") {
                Toggle("Ligatures", isOn: Binding(
                    get: { config.ligatures ?? true },
                    set: { value in document.update(undoManager, actionName: "Ligatures") {
                        $0.modifyLayer(id: layerID) { $0.modifyText { $0.ligatures = value } }
                    }}))
                Toggle("Small Caps", isOn: Binding(
                    get: { config.smallCaps ?? false },
                    set: { value in document.update(undoManager, actionName: "Small Caps") {
                        $0.modifyLayer(id: layerID) { $0.modifyText { $0.smallCaps = value } }
                    }}))
                Stepper("Stylistic Alternate \(config.stylisticAlternates ?? 0)", value: Binding(
                    get: { config.stylisticAlternates ?? 0 },
                    set: { value in document.update(undoManager, actionName: "Stylistic Alternate") {
                        $0.modifyLayer(id: layerID) { $0.modifyText { $0.stylisticAlternates = value } }
                    }}), in: 0...20)
            }

            let pathLayers = document.model.allLayers.filter(\.kind.isPath)
            if !pathLayers.isEmpty {
                Picker("Text Path", selection: Binding(
                    get: { config.pathLayerID },
                    set: { value in
                        document.update(undoManager, actionName: "Text on Path") {
                            $0.modifyLayer(id: layerID) { $0.modifyText { $0.pathLayerID = value } }
                        }
                    })) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(pathLayers) { path in Text(path.name).tag(Optional(path.id)) }
                }
            }

            DisclosureGroup("Per-range Styling") {
                HStack {
                    TextField("Start", value: $rangeStart, format: .number).frame(width: 55)
                    TextField("Length", value: $rangeLength, format: .number).frame(width: 55)
                    Button("Add") { addStyleRun() }
                }
                ForEach(config.styleRuns ?? []) { run in
                    HStack {
                        Text("\(run.location)…\(run.location + run.length)")
                            .font(.caption.monospacedDigit())
                        ColorPicker("", selection: Binding(
                            get: { (run.color ?? config.color).color(in: document.model.colorSettings.workingSpace) },
                            set: { color in updateRun(run.id) { $0.color = RGBAColor(colorValue: color, in: document.model.colorSettings.workingSpace) } }))
                            .labelsHidden()
                        Button {
                            document.update(undoManager, actionName: "Remove Text Style") {
                                $0.modifyLayer(id: layerID) {
                                    $0.modifyText { $0.styleRuns?.removeAll { $0.id == run.id } }
                                }
                            }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }

            // Quick palette swatches for the text color. Enumerate a snapshot
            // (capturing values, not live indices) so a shrinking palette
            // can't produce an out-of-range subscript in a stale row.
            HStack(spacing: 6) {
                ForEach(Array(document.model.palette.colors.enumerated()), id: \.offset) { _, swatch in
                    Button {
                        document.update(undoManager, actionName: "Text Color") { model in
                            model.modifyLayer(id: layerID) { layer in
                                layer.modifyText { $0.color = swatch }
                            }
                        }
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .stroke(.secondary.opacity(0.4), lineWidth: 1)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func setBox(width: CGFloat, height: CGFloat) {
        document.update(undoManager, actionName: "Text Box Size") {
            $0.modifyLayer(id: layerID) { $0.modifyText { $0.boxSize = CGSize(width: width, height: height) } }
        }
    }

    private func addStyleRun() {
        let maxLength = (config.displayText as NSString).length
        let start = min(max(rangeStart, 0), maxLength)
        let length = min(max(rangeLength, 1), max(maxLength - start, 0))
        guard length > 0 else { return }
        let run = TextStyleRun(location: start, length: length,
                               weight: .bold, size: config.size,
                               color: document.model.palette.color(1))
        document.update(undoManager, actionName: "Add Text Style") {
            $0.modifyLayer(id: layerID) {
                $0.modifyText { text in
                    if text.styleRuns == nil { text.styleRuns = [] }
                    text.styleRuns?.append(run)
                }
            }
        }
    }

    private func updateRun(_ id: UUID, _ change: @escaping (inout TextStyleRun) -> Void) {
        document.update(undoManager, actionName: "Text Range Style") {
            $0.modifyLayer(id: layerID) {
                $0.modifyText { text in
                    guard let index = text.styleRuns?.firstIndex(where: { $0.id == id }) else { return }
                    change(&text.styleRuns![index])
                }
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { document.model.layer(id: layerID)?.textConfig?.text ?? "" },
            set: { newValue in
                document.updateDuringGesture { model in
                    model.modifyLayer(id: layerID) { layer in
                        layer.modifyText { $0.text = newValue }
                    }
                }
            }
        )
    }

    private var availableFamilies: [String] {
        var families = NSFontManager.shared.availableFontFamilies
        if !families.contains(config.fontFamily) {
            families.insert(config.fontFamily, at: 0)
        }
        return families
    }

    private func modify<T: Hashable>(_ keyPath: WritableKeyPath<TextConfig, T>, action: String) -> Binding<T> {
        Binding(
            get: { document.model.layer(id: layerID)?.textConfig?[keyPath: keyPath] ?? config[keyPath: keyPath] },
            set: { newValue in
                document.update(undoManager, actionName: action) { model in
                    model.modifyLayer(id: layerID) { layer in
                        layer.modifyText { $0[keyPath: keyPath] = newValue }
                    }
                }
            }
        )
    }

    private func sliderRow(_ label: String, value keyPath: WritableKeyPath<TextConfig, Double>,
                           range: ClosedRange<Double>, defaultValue: Double,
                           action: String) -> some View {
        LabeledContent(label) {
            NumericSlider(value: Binding(
                get: { document.model.layer(id: layerID)?.textConfig?[keyPath: keyPath] ?? config[keyPath: keyPath] },
                set: { newValue in
                    document.updateDuringGesture { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyText { $0[keyPath: keyPath] = newValue }
                        }
                    }
                }
            ), range: range, defaultValue: defaultValue) { editing in
                if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: action) }
            }
        }
    }
}

/// Form-style font family control. Opens a popover where each family name is
/// drawn in that face so users can preview before selecting — SwiftUI's
/// native `Picker` menu strips custom fonts on macOS.
private struct FontFamilyPicker: View {
    @Binding var selection: String
    let families: [String]
    @State private var isOpen = false

    var body: some View {
        LabeledContent("Font") {
            Button {
                isOpen = true
            } label: {
                HStack(spacing: 4) {
                    Text(selection)
                        .font(FontFamilyPreview.font(for: selection, size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                FontFamilyPickerList(selection: $selection, families: families, isOpen: $isOpen)
            }
        }
    }
}

private struct FontFamilyPickerList: View {
    @Binding var selection: String
    let families: [String]
    @Binding var isOpen: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(families, id: \.self) { family in
                        fontRow(family)
                            .id(family)
                    }
                }
                .padding(6)
            }
            .frame(width: 280)
            .frame(maxHeight: 480)
            .onAppear {
                proxy.scrollTo(selection, anchor: .center)
            }
        }
    }

    private func fontRow(_ family: String) -> some View {
        let isSelected = selection == family
        return Button {
            selection = family
            isOpen = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                Text(family)
                    .font(FontFamilyPreview.font(for: family, size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private enum FontFamilyPreview {
    static func font(for family: String, size: CGFloat) -> Font {
        let nsFont = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont(name: family, size: size)
            ?? NSFont.systemFont(ofSize: size)
        return Font(nsFont as CTFont)
    }
}
