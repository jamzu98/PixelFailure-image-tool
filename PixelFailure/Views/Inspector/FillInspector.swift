import SwiftUI

struct FillInspector: View {
    @ObservedObject var document: PixelDocument
    let layerID: UUID
    let config: FillConfig
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Section("Fill") {
            Picker("Style", selection: Binding(
                get: { config.style },
                set: { newValue in
                    modify("Fill Style") { $0.style = newValue }
                }
            )) {
                ForEach(FillStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }

            if config.style == .linearGradient {
                LabeledContent("Angle") {
                    NumericSlider(value: Binding(
                        get: { config.angle },
                        set: { newValue in
                            document.updateDuringGesture { model in
                                model.modifyLayer(id: layerID) { layer in
                                    layer.modifyFill { $0.angle = newValue }
                                }
                            }
                        }
                    ), range: 0...360, defaultValue: 90, fractionDigits: 0) { editing in
                        if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: "Gradient Angle") }
                    }
                }
            }

            // Color stops.
            ForEach(config.colors.indices, id: \.self) { i in
                HStack {
                    ColorPicker(config.style == .solid ? "Color" : "Stop \(i + 1)", selection: Binding(
                        get: { config.colors[i].color },
                        set: { newValue in
                            modify("Fill Color") { fill in
                                guard fill.colors.indices.contains(i) else { return }
                                fill.colors[i] = RGBAColor(colorValue: newValue)
                            }
                        }
                    ))
                    if config.style != .solid && config.colors.count > 2 {
                        Button {
                            modify("Remove Stop") { fill in
                                guard fill.colors.indices.contains(i) else { return }
                                fill.colors.remove(at: i)
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if config.style != .solid {
                HStack {
                    Button("Add Stop") {
                        modify("Add Stop") { fill in
                            let last = fill.colors.last ?? .white
                            fill.colors.append(last)
                        }
                    }
                    .disabled(config.colors.count >= 6)

                    Button("From Palette") {
                        let palette = document.model.palette
                        modify("Palette Colors") { fill in
                            let count = min(max(fill.colors.count, 2), palette.colors.count)
                            fill.colors = (0..<count).map { palette.color($0) }
                        }
                    }
                }
            }
        }
    }

    private func modify(_ action: String, _ change: @escaping (inout FillConfig) -> Void) {
        document.update(undoManager, actionName: action) { model in
            model.modifyLayer(id: layerID) { layer in
                layer.modifyFill(change)
            }
        }
    }
}
