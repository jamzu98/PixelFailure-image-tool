import AppKit
import SwiftUI

nonisolated enum NumericSliderValue {
    static func normalized(_ proposed: Double, range: ClosedRange<Double>, step: Double?) -> Double {
        var number = min(max(proposed, range.lowerBound), range.upperBound)
        if let step, step > 0 {
            number = range.lowerBound + ((number - range.lowerBound) / step).rounded() * step
            number = min(max(number, range.lowerBound), range.upperBound)
        }
        return number
    }
}

/// A value-editing slider with desktop-editor conveniences. The slider keeps
/// its normal drag behavior; command-click restores the declared default and
/// double-click opens an exact numeric entry popover.
struct NumericSlider<Value>: View where Value: BinaryFloatingPoint, Value.Stride: BinaryFloatingPoint {
    @Binding var value: Value
    let range: ClosedRange<Value>
    let defaultValue: Value
    var step: Value.Stride?
    var fractionDigits = 2
    /// Shows an editable value box to the right of the track.
    var showsValue = true
    /// Displays and accepts the value as a percentage of 1.
    var percent = false
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var showsValueEditor = false
    @State private var draftValue = ""
    @FocusState private var valueEditorFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            slider
            if showsValue {
                SliderValueField(value: Double(value), fractionDigits: fractionDigits,
                                 percent: percent) { commit(Value($0)) }
            }
        }
    }

    private var slider: some View {
        NumericSliderBridge(
            value: Binding(get: { Double(value) }, set: { value = Value($0) }),
            range: Double(range.lowerBound)...Double(range.upperBound),
            step: step.map { Double($0) },
            onEditingChanged: onEditingChanged,
            onCommandClick: { commit(defaultValue) },
            onDoubleClick: { originalValue in
                value = Value(originalValue)
                openValueEditor(value: originalValue)
            })
            .help("⌘-click to reset")
            .popover(isPresented: $showsValueEditor, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Value")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Value", text: $draftValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .focused($valueEditorFocused)
                        .onSubmit { commitDraft() }
                        .onKeyPress(.escape) {
                            showsValueEditor = false
                            return .handled
                        }
                }
                .padding(12)
                .onAppear { valueEditorFocused = true }
            }
    }

    private func openValueEditor(value: Double? = nil) {
        draftValue = String(format: "%.*f", fractionDigits, value ?? Double(self.value))
        showsValueEditor = true
    }

    private func commitDraft() {
        let normalized = draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let number = Double(normalized), number.isFinite else { return }
        commit(Value(number))
        showsValueEditor = false
    }

    private func commit(_ proposed: Value) {
        let normalized = NumericSliderValue.normalized(
            Double(proposed),
            range: Double(range.lowerBound)...Double(range.upperBound),
            step: step.map { Double($0) })
        onEditingChanged(true)
        value = Value(normalized)
        onEditingChanged(false)
    }
}

/// The editable number box beside a slider. Commits on Return or when focus
/// leaves; mirrors the slider while not being edited.
private struct SliderValueField: View {
    let value: Double
    let fractionDigits: Int
    let percent: Bool
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 10.5).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 4)
            .frame(width: 44, height: 18)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(isFocused ? Theme.accent : Theme.fieldBorder, lineWidth: 1))
            .focused($isFocused)
            .onSubmit { apply() }
            .onChange(of: isFocused) { _, focused in if !focused { apply() } }
            .onAppear { sync() }
            .onChange(of: value) { _, _ in if !isFocused { sync() } }
    }

    private func sync() {
        text = percent
            ? "\(Int((value * 100).rounded()))%"
            : String(format: "%.*f", fractionDigits, value)
    }

    private func apply() {
        let cleaned = text.replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let number = Double(cleaned), number.isFinite else { sync(); return }
        let proposed = percent ? number / 100 : number
        if abs(proposed - value) > 1e-9 { commit(proposed) }
        sync()
    }
}

private struct NumericSliderBridge: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let onEditingChanged: (Bool) -> Void
    let onCommandClick: () -> Void
    let onDoubleClick: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> GestureSlider {
        let slider = GestureSlider(value: value, minValue: range.lowerBound,
                                   maxValue: range.upperBound,
                                   target: context.coordinator,
                                   action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true
        slider.onEditingChanged = onEditingChanged
        slider.onCommandClick = onCommandClick
        slider.onDoubleClick = onDoubleClick
        return slider
    }

    func updateNSView(_ slider: GestureSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.altIncrementValue = step ?? 0
        slider.onEditingChanged = onEditingChanged
        slider.onCommandClick = onCommandClick
        slider.onDoubleClick = onDoubleClick
    }

    final class Coordinator: NSObject {
        var parent: NumericSliderBridge

        init(parent: NumericSliderBridge) { self.parent = parent }

        @objc func valueChanged(_ sender: NSSlider) {
            parent.value = NumericSliderValue.normalized(sender.doubleValue,
                                                         range: parent.range,
                                                         step: parent.step)
        }
    }
}

private final class GestureSlider: NSSlider {
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onCommandClick: () -> Void = {}
    var onDoubleClick: (Double) -> Void = { _ in }
    private var valueBeforePossibleDoubleClick: Double?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            let originalValue = valueBeforePossibleDoubleClick ?? doubleValue
            doubleValue = originalValue
            sendAction(action, to: target)
            valueBeforePossibleDoubleClick = nil
            onDoubleClick(originalValue)
            return
        }
        if event.modifierFlags.contains(.command) {
            onCommandClick()
            return
        }
        valueBeforePossibleDoubleClick = doubleValue
        onEditingChanged(true)
        super.mouseDown(with: event)
        onEditingChanged(false)
        let capturedValue = valueBeforePossibleDoubleClick
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) { [weak self] in
            guard self?.valueBeforePossibleDoubleClick == capturedValue else { return }
            self?.valueBeforePossibleDoubleClick = nil
        }
    }
}

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
                NumericSlider(value: gestureBinding(spec), range: min...max,
                              defaultValue: spec.defaultValue, fractionDigits: 2) { editing in
                    if editing {
                        document.beginGesture()
                    } else {
                        document.endGesture(undoManager, actionName: spec.label)
                    }
                }
            }

        case .intSlider(let min, let max):
            LabeledContent(spec.label) {
                NumericSlider(value: gestureBinding(spec, rounded: true),
                              range: Double(min)...Double(max),
                              defaultValue: spec.defaultValue, step: 1,
                              fractionDigits: 0) { editing in
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
            PanelPicker(spec.label, selection: Binding(
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
