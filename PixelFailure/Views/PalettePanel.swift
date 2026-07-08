import SwiftUI

/// Palette strip at the bottom of the inspector: built-in palettes, editable
/// swatches, shuffle, and extraction from an image layer.
struct PalettePanel: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Palette")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(BuiltInPalettes.all, id: \.name) { palette in
                        Button {
                            document.update(undoManager, actionName: "Palette") { model in
                                model.palette = palette
                            }
                        } label: {
                            Text(palette.name)
                        }
                    }
                } label: {
                    Text(document.model.palette.name)
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: 6) {
                ForEach(document.model.palette.colors.indices, id: \.self) { i in
                    ColorPicker("", selection: Binding(
                        get: { document.model.palette.colors[i].color },
                        set: { newValue in
                            document.update(undoManager, actionName: "Edit Swatch") { model in
                                guard model.palette.colors.indices.contains(i) else { return }
                                model.palette.colors[i] = RGBAColor(colorValue: newValue)
                                model.palette.name = "Custom"
                            }
                        }
                    ))
                    .labelsHidden()
                    .frame(width: 28)
                }

                Spacer()

                Button {
                    document.update(undoManager, actionName: "Shuffle Palette") { model in
                        guard model.palette.colors.count > 1 else { return }
                        let first = model.palette.colors.removeFirst()
                        model.palette.colors.append(first)
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Cycle swatch order")
            }

            Button {
                extractPalette()
            } label: {
                Label("Extract from Image", systemImage: "eyedropper.halffull")
                    .font(.caption)
            }
            .disabled(extractionSourceLayer == nil)
            .help("Build a palette from an image layer (uses the selected image layer, or the topmost one)")
        }
        .padding(12)
    }

    /// Selected image layer if any, else the topmost image layer.
    private var extractionSourceLayer: Layer? {
        if let selected = document.model.layer(id: editorState.selectedLayerID), selected.kind.isImage {
            return selected
        }
        return document.model.layers.last(where: { $0.kind.isImage })
    }

    private func extractPalette() {
        guard let layer = extractionSourceLayer,
              let config = layer.imageConfig,
              let image = renderStore.originalImage(key: config.imageKey),
              let palette = PaletteExtractor.extract(from: image, colorCount: 5) else { return }
        document.update(undoManager, actionName: "Extract Palette") { model in
            model.palette = palette
        }
    }
}
