import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Swatches panel: palette picker (built-in + user-saved), editable
/// swatches, cycle, harmony, extraction, and save.
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
        VStack(spacing: 0) {
            PanelHeader(title: "Swatches") {
                Button {
                    // One gesture per browsing session: click through palettes
                    // with the popover open, get a single undo step at the end.
                    document.beginGesture()
                    showPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(document.model.palette.name)
                            .foregroundStyle(Theme.textDim)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .font(.system(size: 10.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose Palette")
                .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                    PalettePickerList(document: document)
                }
                .onChange(of: showPicker) { _, isOpen in
                    if !isOpen {
                        document.endGesture(undoManager, actionName: "Palette")
                    }
                }
            }

            HStack(spacing: 4) {
                // Snapshot values, not live indices: AppKit can call back
                // after the palette has shrunk (e.g. eyedropper grew it, then
                // a palette switch removed rows).
                ForEach(Array(document.model.palette.colors.enumerated()), id: \.offset) { i, swatch in
                    SwatchWell(color: swatch.color) { newValue in
                        document.update(undoManager, actionName: "Edit Swatch") { model in
                            guard model.palette.colors.indices.contains(i) else { return }
                            model.palette.colors[i] = RGBAColor(colorValue: newValue,
                                                                in: model.colorSettings.workingSpace)
                            model.palette.name = "Custom"
                        }
                    }
                }

                Spacer(minLength: 6)

                Button {
                    document.update(undoManager, actionName: "Shuffle Palette") { model in
                        guard model.palette.colors.count > 1 else { return }
                        let first = model.palette.colors.removeFirst()
                        model.palette.colors.append(first)
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("Cycle Order")

                Menu {
                    Section("Harmony") {
                        ForEach(PaletteHarmony.allCases, id: \.self) { harmony in
                            Button(harmony.displayName) {
                                document.update(undoManager, actionName: "Palette Harmony") {
                                    $0.palette = $0.palette.harmony(harmony)
                                }
                            }
                        }
                    }
                    Section("Extract") {
                        Button("From Image Layer") { extractFromLayer() }
                            .disabled(extractionSourceLayer == nil)
                        Button("From File…") { showFileExtractor = true }
                    }
                    Divider()
                    Button("Save Palette…") {
                        saveName = suggestedSaveName
                        showSaveDialog = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.icon)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24, height: 24)
                .help("Palette Actions")
            }
            .buttonStyle(IconButtonStyle())
            .padding(.horizontal, 8)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .background(Theme.panel)
        .panelStyle()
        .alert("Save Palette", isPresented: $showSaveDialog) {
            TextField("Name", text: $saveName)
            Button("Save") {
                UserPaletteStore.shared.save(document.model.palette, named: saveName)
            }
            Button("Cancel", role: .cancel) {}
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
                            RoundedRectangle(cornerRadius: 2)
                                .fill(palette.colors[i].color)
                                .frame(width: 14, height: 14)
                        }
                    }
                    Text(palette.name)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(isCurrent ? Theme.rowSelected : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4))
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

/// A flat color chip that edits its color in the shared system color panel.
struct SwatchWell: View {
    let color: Color
    var size = CGSize(width: 26, height: 22)
    var help = "Edit Swatch"
    let onChange: (Color) -> Void
    @State private var isHovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(isHovering ? Theme.textDim : Color.white.opacity(0.12), lineWidth: 1))
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture {
                ColorPanelBridge.shared.open(color: NSColor(color)) { onChange(Color(nsColor: $0)) }
            }
            .help(help)
    }
}

/// Routes NSColorPanel changes to whichever swatch opened it last.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func open(color: NSColor, onChange: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        self.onChange = nil
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = true
        panel.color = color
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}
