import SwiftUI

struct PatternInspector: View {
    @ObservedObject var document: PixelDocument
    let layerID: UUID
    let config: PatternConfig
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Section(config.generator.displayName) {
            // Seed row: reroll or dial in a specific seed.
            LabeledContent("Seed") {
                HStack(spacing: 6) {
                    Text(String(config.seed % 100000))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        document.reroll(layerID: layerID, randomizeParams: false, undoManager: undoManager)
                    } label: {
                        Image(systemName: "dice")
                    }
                    .buttonStyle(.borderless)
                    .help("Reroll seed (⌘R)")

                    Button {
                        document.reroll(layerID: layerID, randomizeParams: true, undoManager: undoManager)
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(.borderless)
                    .help("Randomize parameters too (⌥⌘R)")
                }
            }

            if config.generator.generator.needsSourceImage {
                sourceImagePicker
            }

            ParamControls(document: document,
                          specs: config.generator.generator.specs,
                          values: config.params) { model, key, value in
                model.modifyLayer(id: layerID) { layer in
                    layer.modifyPattern { $0.params.set(key, value) }
                }
            }
        }
    }

    /// Sampled-grid generators need an image layer to read from.
    @ViewBuilder
    private var sourceImagePicker: some View {
        let imageLayers = document.model.layers.filter(\.kind.isImage)
        if imageLayers.isEmpty {
            Text("Add an image layer to sample from.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Picker("Source Image", selection: Binding(
                get: { config.sourceImageLayerID ?? imageLayers.last?.id },
                set: { newValue in
                    document.update(undoManager, actionName: "Source Image") { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyPattern { $0.sourceImageLayerID = newValue }
                        }
                    }
                }
            )) {
                ForEach(imageLayers) { imageLayer in
                    Text(imageLayer.name).tag(Optional(imageLayer.id))
                }
            }
        }
    }
}
