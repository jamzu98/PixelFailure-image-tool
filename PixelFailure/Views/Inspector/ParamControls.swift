import SwiftUI

/// Renders any [ParamSpec] as controls. Sliders coalesce their whole drag
/// into one undo step; discrete controls register undo immediately.
struct ParamControls: View {
    @ObservedObject var document: PixelDocument
    let specs: [ParamSpec]
    let values: ParamValues
    /// Writes one key/value into the model (the caller knows where the params live).
    let write: @MainActor (inout ProjectModel, _ key: String, _ value: Double) -> Void
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ForEach(specs) { spec in
            control(for: spec)
        }
    }

    @ViewBuilder
    private func control(for spec: ParamSpec) -> some View {
        switch spec.kind {
        case .slider(let min, let max):
            LabeledContent(spec.label) {
                Slider(value: gestureBinding(spec), in: min...max) { editing in
                    if editing {
                        document.beginGesture()
                    } else {
                        document.endGesture(undoManager, actionName: spec.label)
                    }
                }
            }

        case .intSlider(let min, let max):
            LabeledContent("\(spec.label): \(values.int(spec.key, Int(spec.defaultValue)))") {
                Slider(value: gestureBinding(spec, rounded: true),
                       in: Double(min)...Double(max)) { editing in
                    if editing {
                        document.beginGesture()
                    } else {
                        document.endGesture(undoManager, actionName: spec.label)
                    }
                }
            }

        case .toggle:
            Toggle(spec.label, isOn: Binding(
                get: { values.bool(spec.key, spec.defaultValue >= 0.5) },
                set: { newValue in
                    document.update(undoManager, actionName: spec.label) { model in
                        write(&model, spec.key, newValue ? 1 : 0)
                    }
                }
            ))

        case .choice(let options):
            Picker(spec.label, selection: Binding(
                get: { Swift.min(values.int(spec.key, Int(spec.defaultValue)), options.count - 1) },
                set: { newValue in
                    document.update(undoManager, actionName: spec.label) { model in
                        write(&model, spec.key, Double(newValue))
                    }
                }
            )) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i]).tag(i)
                }
            }
        }
    }

    private func gestureBinding(_ spec: ParamSpec, rounded: Bool = false) -> Binding<Double> {
        Binding(
            get: { values.double(spec.key, spec.defaultValue) },
            set: { newValue in
                let value = rounded ? newValue.rounded() : newValue
                document.updateDuringGesture { model in
                    write(&model, spec.key, value)
                }
            }
        )
    }
}
