import SwiftUI

/// Options-bar controls for the Object Select tool.
struct ObjectSelectOptions: View {
    @Bindable var vision: VisionSelectionController
    let focus: EditorFocus

    var body: some View {
        HStack(spacing: 12) {
            Picker("", selection: $vision.mode) {
                ForEach(VisionSelectionController.Mode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: vision.mode) { _, _ in
                vision.cancel()
                vision.clearHover()
                vision.prefetch(focus: focus)
            }

            Picker("", selection: $vision.combineMode) {
                ForEach(SelectionCombineMode.allCases) { mode in
                    Image(systemName: mode.systemImage).help(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            BarDivider()

            switch vision.mode {
            case .object:
                HStack(spacing: 6) {
                    Text("Quality").foregroundStyle(Theme.textDim)
                    Picker("", selection: $vision.quality) {
                        ForEach(SegmentationQuality.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Button("Subject") { vision.selectSubject(inverted: false, focus: focus) }
                    .help("Select the main subject")
                modelControl
            case .person:
                Button("All People") { vision.selectPeople(focus: focus) }
            case .face:
                HStack(spacing: 2) {
                    ForEach(FaceFeatures.all, id: \.1) { feature, name, symbol in
                        Button { toggle(feature) } label: { Image(systemName: symbol) }
                            .buttonStyle(IconButtonStyle(size: 24, isActive: vision.faceFeatures.contains(feature)))
                            .help(name)
                    }
                }
            }

            if vision.candidate != nil {
                BarDivider()
                Button("Apply") { vision.commit(focus.editorState) }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { vision.cancel() }
            }
        }
        .help(vision.mode == .object ? "Click or drag a box · ⇧-click include · ⌥-click exclude · ↩ apply" : "")
    }

    @ViewBuilder
    private var modelControl: some View {
        switch vision.modelState {
        case .failed:
            Button("Retry Model") { vision.downloadModel() }
                .help("Click-to-select needs Apple's on-device segmentation model")
        case .downloading:
            if let progress = vision.downloadProgress {
                ProgressView(value: progress).frame(width: 80).controlSize(.small)
            }
        case .ready, .unknown, .needsDownload:
            EmptyView()
        }
    }

    private func toggle(_ feature: FaceFeatures) {
        if vision.faceFeatures.contains(feature) {
            vision.faceFeatures.remove(feature)
            if vision.faceFeatures.isEmpty { vision.faceFeatures = .face }
        } else {
            vision.faceFeatures.insert(feature)
        }
        vision.clearHover()
    }
}
