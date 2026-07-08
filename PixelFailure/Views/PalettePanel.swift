import SwiftUI

/// Palette strip at the bottom of the inspector: built-in palettes, editable
/// swatches, shuffle, and extraction from an image layer.
struct PalettePanel: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Palette")
                    .font(.headline)
                Spacer()
                Button {
                    // One gesture per browsing session: click through palettes
                    // with the popover open, get a single undo step at the end.
                    document.beginGesture()
                    showPicker = true
                } label: {
                    HStack(spacing: 3) {
                        Text(document.model.palette.name)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                    PalettePickerList(document: document)
                }
                .onChange(of: showPicker) { _, isOpen in
                    if !isOpen {
                        document.endGesture(undoManager, actionName: "Palette")
                    }
                }
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

/// Popover listing every built-in palette with its swatches. Clicking a row
/// applies it immediately while the popover stays open, so flipping through
/// palettes live-previews on the canvas.
private struct PalettePickerList: View {
    @ObservedObject var document: PixelDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(BuiltInPalettes.all, id: \.name) { palette in
                paletteRow(palette)
            }
            Divider()
                .padding(.vertical, 2)
            Text("Click to preview — the last one you pick stays.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
        .padding(8)
        .frame(width: 250)
    }

    private func paletteRow(_ palette: Palette) -> some View {
        let isCurrent = document.model.palette.name == palette.name
        return Button {
            document.updateDuringGesture { model in
                model.palette = palette
            }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(palette.colors.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(palette.colors[i].color)
                            .frame(width: 15, height: 15)
                    }
                }
                Text(palette.name)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
