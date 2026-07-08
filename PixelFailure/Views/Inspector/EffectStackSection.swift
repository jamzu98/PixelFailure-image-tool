import SwiftUI

/// Where an effect stack lives: on an image layer, or on the whole canvas.
enum EffectsTarget {
    case layer(UUID)
    case canvas

    /// Mutates the target's effects array inside the model.
    func withEffects(_ model: inout ProjectModel, _ change: (inout [Effect]) -> Void) {
        switch self {
        case .layer(let id):
            model.modifyLayer(id: id) { layer in
                layer.modifyImage { config in
                    change(&config.effects)
                }
            }
        case .canvas:
            change(&model.canvasEffects)
        }
    }
}

/// The non-destructive effect stack UI: reorder, toggle, tune, add, remove.
/// Shared between image layers and the canvas-level adjustment stack.
struct EffectStackSection: View {
    @ObservedObject var document: PixelDocument
    let title: String
    let target: EffectsTarget
    let effects: [Effect]
    var footnote: String?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Section {
            ForEach(Array(effects.enumerated()), id: \.element.id) { index, effect in
                effectRow(effect, index: index)
            }

            Menu("Add Effect") {
                ForEach(EffectType.allCases, id: \.self) { type in
                    Button(type.displayName) {
                        document.update(undoManager, actionName: "Add \(type.displayName)") { model in
                            target.withEffects(&model) { effects in
                                effects.append(Effect(type: type, params: type.defaultParams))
                            }
                        }
                    }
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let footnote, !effects.isEmpty || footnote.contains("PNG") {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if effects.isEmpty {
                Text("Effects stack non-destructively, in order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func effectRow(_ effect: Effect, index: Int) -> some View {
        DisclosureGroup {
            ParamControls(document: document,
                          specs: effect.type.specs,
                          values: effect.params) { model, key, value in
                target.withEffects(&model) { effects in
                    guard let i = effects.firstIndex(where: { $0.id == effect.id }) else { return }
                    effects[i].params.set(key, value)
                }
            }
        } label: {
            HStack {
                Toggle("", isOn: Binding(
                    get: { effect.isEnabled },
                    set: { newValue in
                        document.update(undoManager, actionName: "Toggle Effect") { model in
                            target.withEffects(&model) { effects in
                                guard let i = effects.firstIndex(where: { $0.id == effect.id }) else { return }
                                effects[i].isEnabled = newValue
                            }
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()

                Text(effect.type.displayName)

                Spacer()

                Button {
                    moveEffect(effect.id, by: -1)
                } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)

                Button {
                    moveEffect(effect.id, by: 1)
                } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(index == effects.count - 1)

                Button {
                    document.update(undoManager, actionName: "Remove Effect") { model in
                        target.withEffects(&model) { effects in
                            effects.removeAll { $0.id == effect.id }
                        }
                    }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func moveEffect(_ effectID: UUID, by delta: Int) {
        document.update(undoManager, actionName: "Reorder Effects") { model in
            target.withEffects(&model) { effects in
                guard let i = effects.firstIndex(where: { $0.id == effectID }) else { return }
                let j = i + delta
                guard effects.indices.contains(j) else { return }
                effects.swapAt(i, j)
            }
        }
    }
}
