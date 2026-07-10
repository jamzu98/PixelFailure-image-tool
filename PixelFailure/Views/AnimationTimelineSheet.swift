import AppKit
import SwiftUI

/// Non-modal animation authoring dock. The editor's main canvas is the
/// animation preview, leaving the layer inspector available for keyframe edits.
struct AnimationTimelineDock: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let layerID: UUID
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager
    @State private var format = AnimationExportFormat.gif
    @State private var outputWidth = 1280
    @State private var exportProgress: Double?
    @State private var exportTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showResetConfirmation = false

    private var settings: AnimationSettings { document.model.animation }
    private var keyframes: [AnimationKeyframe] {
        settings.keyframes.filter { $0.layerID == layerID }.sorted { $0.time < $1.time }
    }
    private var keyframeAtPlayhead: AnimationKeyframe? {
        keyframes.first { abs($0.time - editorState.animationPlayhead) < 0.0001 }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Generator Timeline", systemImage: "diamond.fill")
                    .font(.headline)
                if let layer = document.model.layer(id: layerID) {
                    Text(layer.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") {
                    showResetConfirmation = true
                }
                .disabled(keyframes.isEmpty)
                .help("Remove all keyframes for this layer")
                .confirmationDialog("Reset the timeline?",
                                    isPresented: $showResetConfirmation) {
                    Button("Reset Timeline", role: .destructive) { resetTimeline() }
                } message: {
                    Text("This removes every keyframe for this layer. This can be undone.")
                }
                Button {
                    editorState.isAnimationPlaying = false
                    editorState.selectedAnimationKeyframeID = nil
                    editorState.animationLayerID = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close timeline")
            }

            HStack(spacing: 10) {
                Button {
                    editorState.selectedAnimationKeyframeID = nil
                    editorState.isAnimationPlaying.toggle()
                } label: {
                    Image(systemName: editorState.isAnimationPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }

                timelineTrack

                Text(String(format: "%.2f s", editorState.animationPlayhead))
                    .font(.caption.monospacedDigit())
                    .frame(width: 62)

                Button {
                    document.captureAnimationKeyframe(layerID: layerID,
                                                      time: editorState.animationPlayhead,
                                                      undoManager: undoManager)
                    editorState.selectedAnimationKeyframeID = document.model.animation.keyframes.first {
                        $0.layerID == layerID && abs($0.time - editorState.animationPlayhead) < 0.0001
                    }?.id
                } label: {
                    // Reserve the widest title so toggling Add/Update never
                    // resizes the button and shifts the timeline track.
                    ZStack {
                        Text("Update Keyframe").hidden()
                        Text(keyframeAtPlayhead == nil ? "Add Keyframe" : "Update Keyframe")
                    }
                }
            }

            HStack(spacing: 14) {
                Stepper("Duration \(settings.duration, specifier: "%.1f") s",
                        value: Binding(get: { settings.duration }, set: { value in
                            document.update(undoManager, actionName: "Animation Duration") {
                                $0.animation.duration = min(max(value, 0.5), 30)
                            }
                            editorState.animationPlayhead = min(editorState.animationPlayhead, value)
                        }), in: 0.5...30, step: 0.5)

                Picker("FPS", selection: Binding(get: { settings.framesPerSecond }, set: { value in
                    document.update(undoManager, actionName: "Animation Frame Rate") {
                        $0.animation.framesPerSecond = value
                    }
                })) {
                    ForEach([12, 24, 30, 60], id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 105)

                Spacer()

                Picker("Format", selection: $format) {
                    ForEach(AnimationExportFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 115)
                TextField("Width", value: $outputWidth, format: .number)
                    .frame(width: 76)
                    .textFieldStyle(.roundedBorder)
                Text("px").font(.caption)
                if let progress = exportProgress {
                    ProgressView(value: progress).frame(width: 90)
                    Button("Cancel") { exportTask?.cancel() }
                } else {
                    Button("Export Animation…") { exportAnimation() }
                        .disabled(keyframes.isEmpty)
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.bar)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: editorState.isAnimationPlaying) {
            guard editorState.isAnimationPlaying else { return }
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled, editorState.isAnimationPlaying {
                try? await Task.sleep(for: .milliseconds(16))
                let now = clock.now
                let delta = last.duration(to: now)
                last = now
                editorState.animationPlayhead += delta.seconds
                if editorState.animationPlayhead >= settings.duration {
                    editorState.animationPlayhead = 0
                }
            }
        }
        .onDisappear {
            editorState.isAnimationScrubbing = false
            exportTask?.cancel()
        }
    }

    private var timelineTrack: some View {
        GeometryReader { geometry in
            ZStack {
                Slider(value: Binding(
                    get: { editorState.animationPlayhead },
                    set: { value in
                        editorState.animationPlayhead = value
                        editorState.selectedAnimationKeyframeID = nil
                    }), in: 0...max(settings.duration, 0.1), onEditingChanged: { editing in
                        editorState.isAnimationScrubbing = editing
                    })

                ForEach(keyframes) { frame in
                    Button {
                        editorState.isAnimationPlaying = false
                        editorState.animationPlayhead = frame.time
                        editorState.selectedAnimationKeyframeID = frame.id
                    } label: {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(editorState.selectedAnimationKeyframeID == frame.id
                                             ? Color.accentColor : Color.primary)
                            .shadow(radius: 1)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete Keyframe", role: .destructive) {
                            document.removeAnimationKeyframe(frame.id, undoManager: undoManager)
                            if editorState.selectedAnimationKeyframeID == frame.id {
                                editorState.selectedAnimationKeyframeID = nil
                            }
                        }
                    }
                    .position(x: max(8, min(geometry.size.width - 8,
                                            geometry.size.width * frame.time / max(settings.duration, 0.1))),
                              y: geometry.size.height / 2)
                    .help("Keyframe at \(frame.time, specifier: "%.2f") s")
                }
            }
        }
        .frame(height: 28)
    }

    private func resetTimeline() {
        editorState.isAnimationPlaying = false
        editorState.selectedAnimationKeyframeID = nil
        editorState.animationPlayhead = 0
        document.update(undoManager, actionName: "Reset Timeline") { model in
            model.animation.keyframes.removeAll { $0.layerID == layerID }
        }
    }

    private func exportAnimation() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = "PixelFailure-Animation.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let model = document.model
        let width = CGFloat(min(max(outputWidth, 64), 4096))
        let size = CGSize(width: width, height: width * model.canvasSize.height / model.canvasSize.width)
        exportProgress = 0
        errorMessage = nil
        exportTask = Task {
            do {
                try await AnimationExporter.export(format: format, to: url, model: model,
                                                   size: size, render: render) {
                    exportProgress = $0
                }
            } catch AnimationExportError.cancelled {
                try? FileManager.default.removeItem(at: url)
            } catch {
                errorMessage = error.localizedDescription
            }
            exportProgress = nil
            exportTask = nil
        }
    }

    private func render(_ model: ProjectModel, size: CGSize) -> CGImage? {
        var image = PNGExporter.render(items: renderStore.renderItems(model: model, quality: .full),
                                       background: model.background, canvasSize: model.canvasSize,
                                       targetPixelSize: size,
                                       colorSettings: model.colorSettings.previewVariant)
        if let current = image, !model.canvasEffects.isEmpty {
            image = EffectPipeline.shared.apply(effects: model.canvasEffects, to: current,
                                                palette: model.palette)
        }
        return image
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
