import SwiftUI

struct ShapeInspector: View {
    @ObservedObject var document: PixelDocument
    let layerID: UUID
    let config: ShapeConfig
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Section("Shape") {
            Picker("Shape", selection: Binding(
                get: { config.kind },
                set: { newValue in modify("Shape Kind") { $0.kind = newValue } }
            )) {
                ForEach(ShapeKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            sizeSlider("Width", keyPath: \.width)
            sizeSlider("Height", keyPath: \.height)

            if config.kind == .roundedRectangle {
                gestureSlider("Corner Radius", value: config.cornerRadius, range: 0...0.5) { shape, value in
                    shape.cornerRadius = value
                }
            }
            if config.kind == .polygon || config.kind == .star {
                LabeledContent("Sides: \(config.sides)") {
                    Slider(value: Binding(
                        get: { Double(config.sides) },
                        set: { newValue in
                            document.updateDuringGesture { model in
                                model.modifyLayer(id: layerID) { layer in
                                    layer.modifyShape { $0.sides = Int(newValue.rounded()) }
                                }
                            }
                        }
                    ), in: 3...16) { editing in
                        if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: "Sides") }
                    }
                }
            }
            if config.kind == .star {
                gestureSlider("Inner Radius", value: config.starInnerRatio, range: 0.1...0.95) { shape, value in
                    shape.starInnerRatio = value
                }
            }

            // Fill color (optional).
            Toggle("Fill", isOn: Binding(
                get: { config.fill != nil },
                set: { on in
                    let palette = document.model.palette
                    modify(on ? "Enable Fill" : "Disable Fill") { shape in
                        shape.fill = on ? palette.color(1) : nil
                    }
                }
            ))
            if let fill = config.fill {
                ColorPicker("Fill Color", selection: Binding(
                    get: { fill.color },
                    set: { newValue in modify("Fill Color") { $0.fill = RGBAColor(colorValue: newValue) } }
                ))
            }

            // Stroke (optional).
            Toggle("Stroke", isOn: Binding(
                get: { config.stroke != nil },
                set: { on in
                    let palette = document.model.palette
                    modify(on ? "Enable Stroke" : "Disable Stroke") { shape in
                        shape.stroke = on ? palette.color(0) : nil
                    }
                }
            ))
            if let stroke = config.stroke {
                ColorPicker("Stroke Color", selection: Binding(
                    get: { stroke.color },
                    set: { newValue in modify("Stroke Color") { $0.stroke = RGBAColor(colorValue: newValue) } }
                ))
                gestureSlider("Stroke Width", value: config.strokeWidth, range: 0.5...120) { shape, value in
                    shape.strokeWidth = value
                }
            }
        }
    }

    private func sizeSlider(_ label: String, keyPath: WritableKeyPath<CGSize, CGFloat>) -> some View {
        LabeledContent("\(label): \(Int(config.size[keyPath: keyPath]))") {
            Slider(value: Binding(
                get: { Double(config.size[keyPath: keyPath]) },
                set: { newValue in
                    document.updateDuringGesture { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyShape { $0.size[keyPath: keyPath] = CGFloat(newValue) }
                        }
                    }
                }
            ), in: 16...4000) { editing in
                if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: label) }
            }
        }
    }

    private func gestureSlider(_ label: String, value: Double, range: ClosedRange<Double>,
                               apply: @escaping (inout ShapeConfig, Double) -> Void) -> some View {
        LabeledContent(label) {
            Slider(value: Binding(
                get: { value },
                set: { newValue in
                    document.updateDuringGesture { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyShape { apply(&$0, newValue) }
                        }
                    }
                }
            ), in: range) { editing in
                if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: label) }
            }
        }
    }

    private func modify(_ action: String, _ change: @escaping (inout ShapeConfig) -> Void) {
        document.update(undoManager, actionName: action) { model in
            model.modifyLayer(id: layerID) { layer in
                layer.modifyShape(change)
            }
        }
    }
}
