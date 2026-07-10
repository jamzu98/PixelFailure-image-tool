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

            Picker("Font", selection: modify(\.fontFamily, action: "Font")) {
                ForEach(availableFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }

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
