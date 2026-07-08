import SwiftUI

struct ImageInspector: View {
    @ObservedObject var document: PixelDocument
    let layerID: UUID
    let config: ImageConfig
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        cropSection
        effectsSection
    }

    // MARK: - Crop

    private var cropSection: some View {
        Section("Crop") {
            cropSlider("Left", key: \.minX)
            cropSlider("Top", key: \.minY)
            cropSlider("Width", key: \.width)
            cropSlider("Height", key: \.height)
            if config.crop != nil {
                Button("Reset Crop") {
                    document.update(undoManager, actionName: "Reset Crop") { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyImage { $0.crop = nil }
                        }
                    }
                }
            }
        }
    }

    private enum CropKey { case minX, minY, width, height }

    private func cropSlider(_ label: String, key: KeyPath<CGRect, CGFloat>) -> some View {
        let crop = config.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return LabeledContent(label) {
            Slider(value: Binding(
                get: { Double(crop[keyPath: key]) },
                set: { newValue in
                    document.updateDuringGesture { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyImage { imageConfig in
                                var rect = imageConfig.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                                switch key {
                                case \.minX: rect.origin.x = min(newValue, 0.95)
                                case \.minY: rect.origin.y = min(newValue, 0.95)
                                case \.width: rect.size.width = max(newValue, 0.05)
                                case \.height: rect.size.height = max(newValue, 0.05)
                                default: break
                                }
                                // Keep the crop inside the image.
                                rect.size.width = min(rect.width, 1 - rect.minX)
                                rect.size.height = min(rect.height, 1 - rect.minY)
                                imageConfig.crop = rect
                            }
                        }
                    }
                }
            ), in: 0...1) { editing in
                if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: "Crop") }
            }
        }
    }

    // MARK: - Effects stack

    private var effectsSection: some View {
        Section {
            ForEach(Array(config.effects.enumerated()), id: \.element.id) { index, effect in
                effectRow(effect, index: index)
            }

            Menu("Add Effect") {
                ForEach(EffectType.allCases, id: \.self) { type in
                    Button(type.displayName) {
                        document.update(undoManager, actionName: "Add \(type.displayName)") { model in
                            model.modifyLayer(id: layerID) { layer in
                                layer.modifyImage {
                                    $0.effects.append(Effect(type: type, params: type.defaultParams))
                                }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Effects")
        } footer: {
            if config.effects.isEmpty {
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
                model.modifyLayer(id: layerID) { layer in
                    layer.modifyImage { imageConfig in
                        guard let i = imageConfig.effects.firstIndex(where: { $0.id == effect.id }) else { return }
                        imageConfig.effects[i].params.set(key, value)
                    }
                }
            }
        } label: {
            HStack {
                Toggle("", isOn: Binding(
                    get: { effect.isEnabled },
                    set: { newValue in
                        document.update(undoManager, actionName: "Toggle Effect") { model in
                            model.modifyLayer(id: layerID) { layer in
                                layer.modifyImage { imageConfig in
                                    guard let i = imageConfig.effects.firstIndex(where: { $0.id == effect.id }) else { return }
                                    imageConfig.effects[i].isEnabled = newValue
                                }
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
                    .disabled(index == config.effects.count - 1)

                Button {
                    document.update(undoManager, actionName: "Remove Effect") { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyImage { $0.effects.removeAll { $0.id == effect.id } }
                        }
                    }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func moveEffect(_ effectID: UUID, by delta: Int) {
        document.update(undoManager, actionName: "Reorder Effects") { model in
            model.modifyLayer(id: layerID) { layer in
                layer.modifyImage { imageConfig in
                    guard let i = imageConfig.effects.firstIndex(where: { $0.id == effectID }) else { return }
                    let j = i + delta
                    guard imageConfig.effects.indices.contains(j) else { return }
                    imageConfig.effects.swapAt(i, j)
                }
            }
        }
    }
}
