import SwiftUI

struct PatternInspector: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let layerID: UUID
    let config: PatternConfig
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager
    @State private var showVariations = false
    @State private var showSavePreset = false
    @State private var presetName = ""
    private var userPresets: UserPresetStore { .shared }

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
        VStack(alignment: .leading, spacing: 0) {
        InspectorSection("Pattern") {
            if editorState.animationLayerID == layerID {
                if let selectedKeyframe {
                    Label("Keyframe \(selectedKeyframe.time, specifier: "%.2f") s",
                          systemImage: "diamond.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("Preview — select a keyframe to edit")
                        .foregroundStyle(Theme.textDim)
                }
            }

            // Swap the algorithm in place — shared parameters carry over.
            PanelPicker("Generator", selection: Binding(
                get: { config.generator },
                set: { switchGenerator(to: $0) }
            )) {
                GeneratorMenuItems { type in
                    Text(type.displayName).tag(type)
                }
            }

            // Seed row: reroll or dial in a specific seed.
            LabeledContent("Seed") {
                HStack(spacing: 2) {
                    Text(String(displayedConfig.seed % 100000))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.text)
                        .frame(minWidth: 44, alignment: .leading)
                    Button {
                        reroll(randomizeParams: false)
                    } label: {
                        Image(systemName: "dice")
                    }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("Reroll Seed (⌘R)")

                    Button {
                        reroll(randomizeParams: true)
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("Randomize (⌥⌘R)")

                    seedHistoryMenu
                }
                .disabled(animationIsReadOnly)
            }

            HStack(spacing: 6) {
                Button("Variations…") { showVariations = true }
                    .disabled(animationIsReadOnly)
                Button(editorState.animationLayerID == layerID ? "Close Timeline" : "Animate…") {
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
            }

            if config.generator.generator.wantsSourceImage(displayedConfig.params) {
                sourceImagePicker
            }

            ParamControls(document: document,
                          specs: config.generator.generator.specs,
                          values: displayedConfig.params, write: writeParam,
                          locked: config.lockedParams, onToggleLock: toggleLock)
            .disabled(animationIsReadOnly)
        } accessory: {
            presetMenu
        }
        if !config.generator.isRaster {
            stageSections
        }
        }
        .sheet(isPresented: $showVariations) {
            VariationsSheet(document: document, layerID: layerID,
                            baseConfig: displayedConfig, renderStore: renderStore,
                            keyframeID: selectedKeyframe?.id)
        }
        .alert("Save Preset", isPresented: $showSavePreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                userPresets.save(GeneratorPreset.capture(config, name: presetName))
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: config.seed) { oldSeed, _ in
            editorState.recordSeed(oldSeed, for: layerID)
        }
    }

    // MARK: - Presets, locks and seed history

    private var presetMenu: some View {
        Menu {
            let builtIn = BuiltInGeneratorPresets.presets(for: config.generator)
            if !builtIn.isEmpty {
                Section("Presets") {
                    ForEach(builtIn) { preset in
                        Button(preset.name) { apply(preset) }
                    }
                }
            }
            let saved = userPresets.presets(for: config.generator)
            if !saved.isEmpty {
                Section("My Presets") {
                    ForEach(saved) { preset in
                        Button(preset.name) { apply(preset) }
                    }
                }
            }
            Divider()
            Button("Save Current…") {
                presetName = config.generator.displayName
                showSavePreset = true
            }
            if !saved.isEmpty {
                Menu("Delete") {
                    ForEach(saved) { preset in
                        Button(preset.name, role: .destructive) { userPresets.remove(preset) }
                    }
                }
            }
        } label: {
            Image(systemName: "square.stack")
                .font(.system(size: 10.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Presets")
        .disabled(animationIsReadOnly)
    }

    private func apply(_ preset: GeneratorPreset) {
        document.update(undoManager, actionName: "Apply Preset “\(preset.name)”") { model in
            model.modifyLayer(id: layerID) { layer in
                layer.modifyPattern { $0 = preset.applied(to: $0) }
            }
        }
    }

    private func toggleLock(_ key: String) {
        document.update(undoManager, actionName: "Lock Parameter") { model in
            model.modifyLayer(id: layerID) { layer in
                layer.modifyPattern { pattern in
                    if pattern.lockedParams.contains(key) {
                        pattern.lockedParams.remove(key)
                    } else {
                        pattern.lockedParams.insert(key)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var seedHistoryMenu: some View {
        let history = (editorState.seedHistory[layerID] ?? []).filter { $0 != config.seed }
        Menu {
            ForEach(history, id: \.self) { seed in
                Button("Seed \(seed % 100000)") {
                    document.update(undoManager, actionName: "Restore Seed") { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyPattern { $0.seed = seed }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(history.isEmpty || selectedKeyframe != nil)
        .help("Earlier Seeds")
    }

    /// Writes one parameter to the selected keyframe while animating, or to
    /// the layer's pattern otherwise.
    private func writeParam(_ model: inout ProjectModel, _ key: String, _ value: Double) {
        if let keyframeID = editorState.selectedAnimationKeyframeID,
           editorState.animationLayerID == layerID,
           let index = model.animation.keyframes.firstIndex(where: { $0.id == keyframeID }) {
            model.animation.keyframes[index].parameters[key] = value
        } else {
            // Turning a region on with nothing chosen picks the topmost
            // shape, text or path layer, so the change is visible at once.
            let candidate = model.allLayers.last { layer in
                guard layer.id != layerID else { return false }
                switch layer.kind {
                case .shape, .text, .path: return true
                default: return false
                }
            }?.id
            model.modifyLayer(id: layerID) { layer in
                layer.modifyPattern { pattern in
                    pattern.params.set(key, value)
                    if key == "stage.region", value != 0, pattern.regionLayerID == nil {
                        pattern.regionLayerID = candidate
                    }
                }
            }
        }
    }

    // MARK: - Shared stages

    @ViewBuilder
    private var stageSections: some View {
        let params = displayedConfig.params
        let symmetry = GenStages.symmetry(params)
        let repeats = GenStages.repeatCount(params) > 1
        InspectorSection("Symmetry") {
            ParamControls(document: document,
                          specs: GenStages.symmetrySpecs.filter { spec in
                              switch spec.key {
                              case "stage.segments": symmetry.usesSegments
                              case "stage.centerX", "stage.centerY": symmetry != .none
                              default: true
                              }
                          } + GenStages.repeatSpecs.filter { $0.key != "stage.brick" || repeats },
                          values: params, write: writeParam)
            .disabled(animationIsReadOnly)
        }
        InspectorSection("Region & Color") {
            ParamControls(document: document, specs: GenStages.regionSpecs,
                          values: params, write: writeParam)
            if GenStages.regionMode(params) != .off {
                regionPicker
            }
            ParamControls(document: document, specs: GenStages.colorSpecs,
                          values: params, write: writeParam)
            if GenStages.colorSource(params) == .image, !config.generator.generator.wantsSourceImage(params) {
                sourceImagePicker
            }
        }
        .disabled(animationIsReadOnly)
    }

    /// Shape, text and path layers can act as a region.
    @ViewBuilder
    private var regionPicker: some View {
        let candidates = document.model.allLayers.filter { layer in
            guard layer.id != layerID else { return false }
            switch layer.kind {
            case .shape, .text, .path: return true
            default: return false
            }
        }
        if candidates.isEmpty {
            Label("Needs a shape, text or path layer", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
        } else {
            PanelPicker("Layer", selection: Binding(
                get: { config.regionLayerID },
                set: { newValue in
                    document.update(undoManager, actionName: "Region Layer") { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyPattern { $0.regionLayerID = newValue }
                        }
                    }
                }
            )) {
                Text("None").tag(UUID?.none)
                ForEach(candidates) { layer in
                    Text(layer.name).tag(Optional(layer.id))
                }
            }
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
                                             seed: seed, keeping: params,
                                             locked: config.lockedParams)
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
                    // Symmetry, region and color stages belong to the layer,
                    // not the algorithm, so they survive the switch.
                    for key in GenStages.keys {
                        if let existing = pattern.params.storage[key] { migrated.storage[key] = existing }
                    }
                    pattern.lockedParams.formIntersection(Set(newSpecs.map(\.key)))
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
            Label("Needs an image layer", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
        } else {
            PanelPicker("Source Image", selection: Binding(
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
    let id: Int
    let seed: UInt64
    let params: ParamValues
    var image: CGImage?
    let isCurrent: Bool
}

/// Twelve takes on the current pattern, rendered off the main actor and
/// filled in as they finish. "Mutate" nudges unlocked parameters around the
/// current look; "Wild" randomizes them. The first cell is the current state.
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
    @State private var wild = false
    @State private var strength = 0.25
    @State private var keepSeed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Variations").font(.title2.weight(.semibold))
                Spacer()
                Picker("", selection: $wild) {
                    Text("Mutate").tag(false)
                    Text("Wild").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                if !wild {
                    Text("Strength").foregroundStyle(.secondary)
                    Slider(value: $strength, in: 0.05...0.8) { editing in
                        if !editing { batchSeed = SeededRNG.randomSeed() }
                    }
                    .frame(width: 110)
                }
                Toggle("Keep Seed", isOn: $keepSeed)
                Button {
                    batchSeed = SeededRNG.randomSeed()
                } label: { Image(systemName: "arrow.clockwise") }
                .help("New Batch")
                Button("Done") { dismiss() }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(previews) { preview in
                        Button {
                            choose(preview)
                        } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    Rectangle().fill(Color.primary.opacity(0.04))
                                    if let image = preview.image {
                                        Image(decorative: image, scale: 1)
                                            .resizable().aspectRatio(contentMode: .fit)
                                    } else {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                                .aspectRatio(document.model.canvasSize.width / max(document.model.canvasSize.height, 1),
                                             contentMode: .fit)
                                Text(preview.isCurrent ? "Current" : "Seed \(preview.seed % 100000)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(preview.isCurrent ? Theme.accent : .secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(5)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 720, idealWidth: 900, maxWidth: 1100, minHeight: 480, idealHeight: 720, maxHeight: 820)
        .task(id: TaskKey(seed: batchSeed, wild: wild, keepSeed: keepSeed)) { await generate() }
    }

    private struct TaskKey: Equatable { let seed: UInt64; let wild: Bool; let keepSeed: Bool }

    private func choose(_ preview: VariationPreview) {
        guard !preview.isCurrent else { dismiss(); return }
        if let keyframeID {
            document.applyAnimationVariation(seed: preview.seed, params: preview.params,
                                             keyframeID: keyframeID, undoManager: undoManager)
        } else {
            document.applyPatternVariation(seed: preview.seed, params: preview.params,
                                           layerID: layerID, undoManager: undoManager)
        }
        dismiss()
    }

    private func generate() async {
        let model = document.model
        guard let layer = model.layer(id: layerID) else { return }
        let specs = baseConfig.generator.generator.specs
        var rng = SeededRNG(seed: batchSeed ^ baseConfig.seed)
        var takes: [(UInt64, ParamValues)] = [(baseConfig.seed, baseConfig.params)]
        for _ in 0..<11 {
            let draw = rng.next()
            let seed = keepSeed ? baseConfig.seed : draw
            let params = wild
                ? ParamValues.randomized(specs: specs, seed: draw, keeping: baseConfig.params,
                                         locked: baseConfig.lockedParams)
                : ParamValues.mutated(specs: specs, seed: draw, from: baseConfig.params,
                                      strength: strength, locked: baseConfig.lockedParams)
            takes.append((seed, params))
        }
        previews = takes.enumerated().map { index, take in
            VariationPreview(id: index, seed: take.0, params: take.1, image: nil, isCurrent: index == 0)
        }

        // Everything else in the document comes from the cached scene; only
        // the pattern layer is regenerated per take.
        let items = renderStore.renderItems(model: model, quality: .preview)
        let context = renderStore.generatorContext(for: layer, config: baseConfig, model: model)
        let canvas = model.canvasSize
        let scale = min(1, 360 / Double(max(canvas.width, canvas.height)))
        let size = CGSize(width: max(16, (canvas.width * scale).rounded()),
                          height: max(16, (canvas.height * scale).rounded()))
        let job = VariationRenderJob(items: items, layerID: layerID, context: context, canvas: canvas,
                                     size: size, background: model.background,
                                     colorSettings: model.colorSettings.previewVariant)
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, take) in takes.enumerated() {
                var config = baseConfig
                config.seed = take.0
                config.params = take.1
                group.addTask(priority: .userInitiated) { (index, job.render(config)) }
            }
            for await (index, image) in group {
                guard !Task.isCancelled, previews.indices.contains(index) else { continue }
                previews[index].image = image
            }
        }
    }
}

/// Renders one variation: the cached scene with the pattern layer's content
/// swapped for the variation's. Runs on any thread.
private nonisolated struct VariationRenderJob: @unchecked Sendable {
    let items: [RenderItem]
    let layerID: UUID
    let context: GeneratorContext
    let canvas: CGSize
    let size: CGSize
    let background: RGBAColor
    let colorSettings: ColorSettings

    func render(_ config: PatternConfig) -> CGImage? {
        let content: RenderItem.Content
        if config.generator.isRaster {
            guard let image = RasterPatternJob(config: config, size: size, palette: context.palette,
                                               colorSettings: colorSettings).render() else { return nil }
            content = .raster(image)
        } else {
            content = .primitives(config.generate(context: context))
        }
        var scene = items
        if let index = scene.firstIndex(where: { $0.id == layerID }) {
            scene[index].content = content
        } else {
            // Nested in a group: show the pattern on its own.
            scene = [RenderItem(id: layerID, opacity: 1, blendMode: .normal, transform: .identity,
                                naturalSize: canvas, content: content, clipsToBounds: true, mask: nil)]
        }
        return PNGExporter.render(items: scene, background: background, canvasSize: canvas,
                                  targetPixelSize: size, colorSettings: colorSettings)
    }
}
