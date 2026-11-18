import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SizePreset: Identifiable, Hashable {
    let name: String
    let size: CGSize?

    var id: String { name }

    static let exportPresets: [SizePreset] = [
        SizePreset(name: "Canvas Size", size: nil),
        SizePreset(name: "Album Art — 3000 × 3000", size: CGSize(width: 3000, height: 3000)),
        SizePreset(name: "4K UHD — 3840 × 2160", size: CGSize(width: 3840, height: 2160)),
        SizePreset(name: "5K — 5120 × 2880", size: CGSize(width: 5120, height: 2880)),
        SizePreset(name: "Phone — 1290 × 2796", size: CGSize(width: 1290, height: 2796)),
        SizePreset(name: "Custom", size: .zero),
    ]
}

/// Export dialog: PNG at a chosen pixel size (scale-to-fill), or SVG.
struct ExportSheet: View {
    @ObservedObject var document: PixelDocument
    let renderStore: RenderStore
    @Environment(\.dismiss) private var dismiss

    private enum Format: String, CaseIterable {
        case png = "PNG", jpeg = "JPEG", tiff = "TIFF", heic = "HEIC", webp = "WebP"
        case pdf = "PDF", svg = "SVG", psd = "PSD"

        var raster: ImageEncoder.Format? {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .tiff: .tiff
            case .heic: .heic
            case .webp: .webp
            case .pdf, .svg, .psd: nil
            }
        }

        var isAvailable: Bool { raster?.isAvailable ?? true }

        var utType: UTType {
            if let raster { return raster.utType }
            if self == .pdf { return .pdf }
            if self == .psd { return UTType(filenameExtension: "psd") ?? .data }
            return .svg
        }
        var fileExtension: String { raster?.fileExtension ?? (self == .pdf ? "pdf" : self == .psd ? "psd" : "svg") }
    }

    @State private var format: Format = .png
    @State private var quality = 0.9
    @State private var presetIndex = 0
    @State private var customWidth = 3000
    @State private var customHeight = 3000
    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                PanelPicker("Format", selection: $format) {
                    ForEach(Format.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                            .disabled(!format.isAvailable)
                    }
                }

                if format != .svg && format != .psd {
                    PanelPicker("Size", selection: $presetIndex) {
                        ForEach(SizePreset.exportPresets.indices, id: \.self) { i in
                            Text(SizePreset.exportPresets[i].name).tag(i)
                        }
                    }

                    if SizePreset.exportPresets[presetIndex].size == .zero {
                        LabeledContent("Custom") {
                            HStack(spacing: 6) {
                                TextField("Width", value: $customWidth, format: .number)
                                Text("×")
                                TextField("Height", value: $customHeight, format: .number)
                                Text("px").foregroundStyle(.secondary)
                            }
                            .textFieldStyle(.roundedBorder)
                        }
                    }

                    if format.raster?.isLossy == true {
                        LabeledContent("Quality") {
                            HStack {
                                NumericSlider(value: $quality, range: 0.5...1,
                                              defaultValue: 0.9, percent: true)
                            }
                        }
                    }
                }
                formatHelpText
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
            .panelStyle()

            Divider()

            HStack {
                if !document.model.exportSlices.isEmpty {
                    Button("Export Slices…") { exportSlices() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isExporting ? "Exporting…" : "Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isExporting)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 440)
        .navigationTitle("Export")
    }

    @ViewBuilder
    private var formatHelpText: some View {
        switch format {
        case .jpeg:
            Text("No transparency — flattened onto the background.")
        case .pdf:
            Text("Flattened to a single page.")
        case .psd:
            Text("Layered, one raster per layer.")
        case .svg:
            Text(document.model.canvasEffects.isEmpty
                 ? "Vectors stay vector; images embed as PNG."
                 : "Vectors stay vector. Canvas effects are skipped.")
        default:
            if targetSize() != document.model.canvasSize {
                Text("Scaled to fill, center-cropped.")
            }
        }
    }

    private func targetSize() -> CGSize {
        guard format != .svg && format != .psd else { return document.model.canvasSize }
        let preset = SizePreset.exportPresets[presetIndex]
        if preset.size == .zero {
            return CGSize(width: max(16, customWidth), height: max(16, customHeight))
        }
        return preset.size ?? document.model.canvasSize
    }

    private func export() {
        let panel = NSSavePanel()
        let ext = format.fileExtension
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = "Artwork.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        errorMessage = nil
        defer { isExporting = false }

        // Full-quality render items (native-resolution effect chains).
        let items = renderStore.renderItems(model: document.model, quality: .full)
        let model = document.model

        do {
            if let rasterFormat = format.raster {
                guard var image = PNGExporter.render(items: items,
                                                     background: model.background,
                                                     canvasSize: model.canvasSize,
                                                     targetPixelSize: targetSize(),
                                                     colorSettings: model.colorSettings) else {
                    errorMessage = "Rendering failed."
                    return
                }
                if !model.canvasEffects.isEmpty {
                    image = EffectPipeline.shared.apply(effects: model.canvasEffects,
                                                        to: image,
                                                        palette: model.palette)
                }
                guard let data = ImageEncoder.encode(image, format: rasterFormat,
                                                     quality: quality,
                                                     background: model.background) else {
                    errorMessage = "Encoding failed."
                    return
                }
                try data.write(to: url)
            } else if format == .pdf {
                guard var image = PNGExporter.render(items: items,
                                                     background: model.background,
                                                     canvasSize: model.canvasSize,
                                                     targetPixelSize: targetSize(),
                                                     colorSettings: model.colorSettings) else {
                    errorMessage = "Rendering failed."
                    return
                }
                if !model.canvasEffects.isEmpty {
                    image = EffectPipeline.shared.apply(effects: model.canvasEffects,
                                                        to: image, palette: model.palette)
                }
                let inches = model.printSettings.physicalSize(for: targetSize())
                let page = CGSize(width: inches.width * 72, height: inches.height * 72)
                guard let data = PDFExporter.data(image: image, pageSize: page) else {
                    errorMessage = "PDF encoding failed."
                    return
                }
                try data.write(to: url)
            } else if format == .psd {
                guard let data = PSDExporter.data(model: model, renderStore: renderStore) else {
                    errorMessage = "PSD encoding failed."
                    return
                }
                try data.write(to: url)
            } else {
                let svg = SVGExporter.svg(items: items,
                                          background: model.background,
                                          canvasSize: model.canvasSize,
                                          skippedGlobalEffects: !model.canvasEffects.isEmpty,
                                          workingSpace: model.colorSettings.workingSpace)
                try svg.write(to: url, atomically: true, encoding: .utf8)
            }
            dismiss()
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func exportSlices() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url,
              let image = PNGExporter.render(items: renderStore.renderItems(model: document.model, quality: .full),
                                             background: document.model.background,
                                             canvasSize: document.model.canvasSize,
                                             targetPixelSize: document.model.canvasSize,
                                             colorSettings: document.model.colorSettings) else { return }
        do {
            for asset in AssetExporter.assets(from: image, slices: document.model.exportSlices) {
                try asset.data.write(to: directory.appendingPathComponent(asset.name), options: .atomic)
            }
        } catch { errorMessage = "Slice export failed: \(error.localizedDescription)" }
    }
}
