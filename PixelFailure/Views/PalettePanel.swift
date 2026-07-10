import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Palette strip at the bottom of the inspector: palette picker (built-in +
/// user-saved), editable swatches, shuffle, save, and extraction from an
/// image layer or straight from an image file on disk.
struct PalettePanel: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager
    @State private var showPicker = false
    @State private var showSaveDialog = false
    @State private var saveName = ""
    @State private var showFileExtractor = false

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
                    // The getter guards the index: AppKit can re-query a
                    // swatch's binding after the palette has shrunk (e.g.
                    // eyedropper grew it, then a palette switch removed rows).
                    ColorPicker("", selection: Binding(
                        get: {
                            let colors = document.model.palette.colors
                            return colors.indices.contains(i) ? colors[i].color : Color.clear
                        },
                        set: { newValue in
                            document.update(undoManager, actionName: "Edit Swatch") { model in
                                guard model.palette.colors.indices.contains(i) else { return }
                                model.palette.colors[i] = RGBAColor(colorValue: newValue,
                                                                    in: model.colorSettings.workingSpace)
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

                Button {
                    saveName = suggestedSaveName
                    showSaveDialog = true
                } label: {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(.borderless)
                .help("Save current palette for reuse in any document")
            }

            HStack(spacing: 4) {
                Menu {
                    ForEach(PaletteHarmony.allCases, id: \.self) { harmony in
                        Button(harmony.displayName) {
                            document.update(undoManager, actionName: "Palette Harmony") {
                                $0.palette = $0.palette.harmony(harmony)
                            }
                        }
                    }
                } label: {
                    Label("Harmony", systemImage: "circle.hexagongrid")
                        .font(.caption)
                }

                Button {
                    extractFromLayer()
                } label: {
                    Label("Extract from Image", systemImage: "eyedropper.halffull")
                        .font(.caption)
                }
                .disabled(extractionSourceLayer == nil)
                .help("Build a palette from an image layer (uses the selected image layer, or the topmost one)")

                Button {
                    showFileExtractor = true
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                }
                .help("Extract a palette from an image file without importing it")
            }
        }
        .padding(12)
        .alert("Save Palette", isPresented: $showSaveDialog) {
            TextField("Name", text: $saveName)
            Button("Save") {
                UserPaletteStore.shared.save(document.model.palette, named: saveName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved palettes are available in every document from the palette menu.")
        }
        .fileImporter(isPresented: $showFileExtractor, allowedContentTypes: [.image]) { result in
            extractFromFile(result)
        }
    }

    private var suggestedSaveName: String {
        let name = document.model.palette.name
        return (name == "Custom" || name == "Extracted") ? "" : name
    }

    /// Selected image layer if any, else the topmost image layer.
    private var extractionSourceLayer: Layer? {
        if let selected = document.model.layer(id: editorState.selectedLayerID), selected.kind.isImage {
            return selected
        }
        return document.model.layers.last(where: { $0.kind.isImage })
    }

    private func extractFromLayer() {
        guard let layer = extractionSourceLayer,
              let config = layer.imageConfig,
              let image = renderStore.originalImage(key: config.imageKey) else { return }
        apply(extractedFrom: image)
    }

    private func extractFromFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        apply(extractedFrom: image)
    }

    private func apply(extractedFrom image: CGImage) {
        guard let palette = PaletteExtractor.extract(from: image, colorCount: Palette.swatchCount) else { return }
        document.update(undoManager, actionName: "Extract Palette") { model in
            model.palette = palette.normalized
        }
    }
}

/// Popover listing built-in and user-saved palettes with their swatches.
/// Clicking a row applies it immediately while the popover stays open, so
/// flipping through palettes live-previews on the canvas.
private struct PalettePickerList: View {
    @ObservedObject var document: PixelDocument
    @State private var store = UserPaletteStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Built-in")
                ForEach(BuiltInPalettes.all, id: \.name) { palette in
                    paletteRow(palette, deletable: false)
                }

                if !store.palettes.isEmpty {
                    Divider()
                        .padding(.vertical, 3)
                    sectionHeader("My Palettes")
                    ForEach(store.palettes, id: \.name) { palette in
                        paletteRow(palette, deletable: true)
                    }
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
        }
        .frame(width: 270)
        .frame(maxHeight: 480)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 2)
    }

    private func paletteRow(_ palette: Palette, deletable: Bool) -> some View {
        let isCurrent = document.model.palette.name == palette.name
        return HStack(spacing: 2) {
            Button {
                document.updateDuringGesture { model in
                    model.palette = palette.normalized
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

            if deletable {
                Button {
                    store.remove(named: palette.name)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove this saved palette")
            }
        }
    }
}
