import AppKit
import SwiftUI

struct TextInspector: View {
    @ObservedObject var document: PixelDocument
    let layerID: UUID
    let config: TextConfig
    @Environment(\.undoManager) private var undoManager
    @FocusState private var textFocused: Bool

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

            sliderRow("Size", value: \.size, range: 8...800, action: "Text Size")
            sliderRow("Tracking", value: \.tracking, range: -20...120, action: "Tracking")
            sliderRow("Line Height", value: \.lineHeight, range: 0.7...2.2, action: "Line Height")

            Picker("Alignment", selection: modify(\.alignment, action: "Alignment")) {
                ForEach(TextAlignmentChoice.allCases, id: \.self) { alignment in
                    Text(alignment.displayName).tag(alignment)
                }
            }
            .pickerStyle(.segmented)

            ColorPicker("Color", selection: Binding(
                get: { config.color.color },
                set: { newValue in
                    document.update(undoManager, actionName: "Text Color") { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyText { $0.color = RGBAColor(colorValue: newValue) }
                        }
                    }
                }
            ))

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
                           range: ClosedRange<Double>, action: String) -> some View {
        LabeledContent(label) {
            Slider(value: Binding(
                get: { document.model.layer(id: layerID)?.textConfig?[keyPath: keyPath] ?? config[keyPath: keyPath] },
                set: { newValue in
                    document.updateDuringGesture { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyText { $0[keyPath: keyPath] = newValue }
                        }
                    }
                }
            ), in: range) { editing in
                if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: action) }
            }
        }
    }
}
