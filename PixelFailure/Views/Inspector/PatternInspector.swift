import SwiftUI

struct PatternInspector: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let layerID: UUID
    let config: PatternConfig
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager
    @State private var showVariations = false

    private var selectedKeyframe: AnimationKeyframe? {
        guard editorState.animationLayerID == layerID,
              let id = editorState.selectedAnimationKeyframeID else { return nil }
        return document.model.animation.keyframes.first(where: { $0.id == id && $0.layerID == layerID })
    }

    private var displayedConfig: PatternConfig {
        guard editorState.animationLayerID == layerID else { return config }
        if let selectedKeyframe {
            var displayed = config
            displayed.seed = selectedKeyframe.seed
            displayed.params.storage = selectedKeyframe.parameters
            return displayed
        }
        return document.model.model(at: editorState.animationPlayhead).layer(id: layerID)?.patternConfig ?? config
    }

    private var animationIsReadOnly: Bool {
        editorState.animationLayerID == layerID && selectedKeyframe == nil
    }

    var body: some View {
        Section(config.generator.displayName) {
            if editorState.animationLayerID == layerID {
                if let selectedKeyframe {
                    Label("Editing keyframe at \(selectedKeyframe.time, specifier: "%.2f") s",
                          systemImage: "diamond.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("Scrubbing preview — add or select a keyframe to edit its values.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Swap the algorithm in place — shared parameters carry over.
            Picker("Generator", selection: Binding(
                get: { config.generator },
                set: { switchGenerator(to: $0) }
            )) {
                ForEach(GeneratorType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }

            // Seed row: reroll or dial in a specific seed.
            LabeledContent("Seed") {
                HStack(spacing: 6) {
                    Text(String(displayedConfig.seed % 100000))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        reroll(randomizeParams: false)
                    } label: {
                        Image(systemName: "dice")
                    }
                    .buttonStyle(.borderless)
                    .help("Reroll seed (⌘R)")

                    Button {
                        reroll(randomizeParams: true)
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(.borderless)
                    .help("Randomize parameters too (⌥⌘R)")
                }
                .disabled(animationIsReadOnly)
            }

            Button("Variations Grid…") { showVariations = true }
                .disabled(animationIsReadOnly)
            Button(editorState.animationLayerID == layerID ? "Close Generator Timeline" : "Animate Generator…") {
                if editorState.animationLayerID == layerID {
                    editorState.animationLayerID = nil
                    editorState.selectedAnimationKeyframeID = nil
                    editorState.isAnimationPlaying = false
                } else {
                    editorState.animationLayerID = layerID
                    editorState.animationPlayhead = min(editorState.animationPlayhead,
                                                         document.model.animation.duration)
                    editorState.selectedAnimationKeyframeID = nil
                }
            }

            if config.generator.generator.needsSourceImage {
                sourceImagePicker
            }

            ParamControls(document: document,
                          specs: config.generator.generator.specs,
                          values: displayedConfig.params) { model, key, value in
                if let keyframeID = editorState.selectedAnimationKeyframeID,
                   editorState.animationLayerID == layerID,
                   let index = model.animation.keyframes.firstIndex(where: { $0.id == keyframeID }) {
                    model.animation.keyframes[index].parameters[key] = value
                } else {
                    model.modifyLayer(id: layerID) { layer in
                        layer.modifyPattern { $0.params.set(key, value) }
                    }
                }
            }
            .disabled(animationIsReadOnly)
        }
        .sheet(isPresented: $showVariations) {
            VariationsSheet(document: document, layerID: layerID,
                            baseConfig: displayedConfig, renderStore: renderStore,
                            keyframeID: selectedKeyframe?.id)
        }
    }

    private func reroll(randomizeParams: Bool) {
        guard let keyframe = selectedKeyframe else {
            document.reroll(layerID: layerID, randomizeParams: randomizeParams,
                            undoManager: undoManager)
            return
        }
        let seed = SeededRNG.randomSeed()
        var params = displayedConfig.params
        if randomizeParams {
            params = ParamValues.randomized(specs: config.generator.generator.specs,
                                             seed: seed, keeping: params)
        }
        document.updateAnimationKeyframe(keyframe.id, seed: seed,
                                         parameters: randomizeParams ? params : nil,
                                         undoManager: undoManager,
                                         actionName: randomizeParams ? "Randomize Keyframe" : "Reroll Keyframe Seed")
    }

    /// Switch the layer to another generator, keeping the seed and carrying
    /// over parameter values whose keys exist in both generators.
    private func switchGenerator(to newType: GeneratorType) {
        guard newType != config.generator else { return }
        let oldDisplayName = config.generator.displayName
        document.update(undoManager, actionName: "Change Generator") { model in
            var topImageLayerID: UUID?
            if newType.generator.needsSourceImage {
                topImageLayerID = model.layers.last(where: { $0.kind.isImage })?.id
            }
            model.modifyLayer(id: layerID) { layer in
                layer.modifyPattern { pattern in
                    let newSpecs = newType.generator.specs
                    var migrated = ParamValues(defaults: newSpecs)
                    for spec in newSpecs {
                        if let existing = pattern.params.storage[spec.key] {
                            migrated.storage[spec.key] = existing
                        }
                    }
                    pattern.generator = newType
                    pattern.params = migrated
                    if newType.generator.needsSourceImage, pattern.sourceImageLayerID == nil {
                        pattern.sourceImageLayerID = topImageLayerID
                    }
                }
                // Auto-rename only if the user hadn't renamed the layer.
                if layer.name == oldDisplayName {
                    layer.name = newType.displayName
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

private struct VariationPreview: Identifiable {
    let id = UUID()
    let seed: UInt64
    let params: ParamValues
    let image: CGImage
}

private struct VariationsSheet: View {
    @ObservedObject var document: PixelDocument
    let layerID: UUID
    let baseConfig: PatternConfig
    let renderStore: RenderStore
    let keyframeID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var batchSeed = SeededRNG.randomSeed()
    @State private var previews: [VariationPreview] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Variations").font(.title2.weight(.semibold))
                    Text("Choose a preview to apply its seed and parameters.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Regenerate") { batchSeed = SeededRNG.randomSeed() }
                Button("Cancel") { dismiss() }
            }
            if previews.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(previews) { preview in
                            Button {
                                if let keyframeID {
                                    document.applyAnimationVariation(seed: preview.seed, params: preview.params,
                                                                     keyframeID: keyframeID,
                                                                     undoManager: undoManager)
                                } else {
                                    document.applyPatternVariation(seed: preview.seed, params: preview.params,
                                                                   layerID: layerID,
                                                                   undoManager: undoManager)
                                }
                                dismiss()
                            } label: {
                                VStack(spacing: 4) {
                                    Image(decorative: preview.image, scale: 1)
                                        .resizable().aspectRatio(contentMode: .fit)
                                    Text("Seed \(preview.seed % 100000)")
                                        .font(.caption.monospacedDigit())
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                }
                                .padding(5)
                                .background(Color.primary.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 760, maxWidth: 900,
               minHeight: 420, idealHeight: 700, maxHeight: 760)
        .task(id: batchSeed) { generate() }
    }

    private func generate() {
        previews = []
        var rng = SeededRNG(seed: batchSeed ^ baseConfig.seed)
        let seeds = (0..<9).map { _ in rng.next() }
        let canvas = document.model.canvasSize
        let maxDimension = 220.0
        let scale = min(1, maxDimension / Double(max(canvas.width, canvas.height)))
        let size = CGSize(width: max(16, (canvas.width * scale).rounded()),
                          height: max(16, (canvas.height * scale).rounded()))
        previews = seeds.compactMap { seed in
            var model = document.model
            let params = ParamValues.randomized(specs: baseConfig.generator.generator.specs,
                                                seed: seed, keeping: baseConfig.params)
            model.modifyLayer(id: layerID) {
                $0.modifyPattern {
                    $0.seed = seed
                    $0.params = params
                }
            }
            let items = renderStore.renderItems(model: model, quality: .preview)
            guard let image = PNGExporter.render(items: items, background: model.background,
                                                 canvasSize: canvas, targetPixelSize: size,
                                                 colorSettings: model.colorSettings.previewVariant) else { return nil }
            return VariationPreview(seed: seed, params: params, image: image)
        }
    }
}
