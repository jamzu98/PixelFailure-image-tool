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
        case pdf = "PDF", svg = "SVG"

        var raster: ImageEncoder.Format? {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .tiff: .tiff
            case .heic: .heic
            case .webp: .webp
            case .pdf, .svg: nil
            }
        }

        var isAvailable: Bool { raster?.isAvailable ?? true }

        var utType: UTType { raster?.utType ?? (self == .pdf ? .pdf : .svg) }
        var fileExtension: String { raster?.fileExtension ?? (self == .pdf ? "pdf" : "svg") }
    }

    @State private var format: Format = .png
    @State private var quality = 0.9
    @State private var presetIndex = 0
    @State private var customWidth = 3000
    @State private var customHeight = 3000
    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(.title2.bold())

            Picker("Format", selection: $format) {
                ForEach(Format.allCases, id: \.self) { format in
                    Text(format.rawValue).tag(format)
                        .disabled(!format.isAvailable)
                }
            }
            .pickerStyle(.segmented)

            if format != .svg {
                Picker("Size", selection: $presetIndex) {
                    ForEach(SizePreset.exportPresets.indices, id: \.self) { i in
                        Text(SizePreset.exportPresets[i].name).tag(i)
                    }
                }

                if SizePreset.exportPresets[presetIndex].size == .zero {
                    HStack {
                        TextField("Width", value: $customWidth, format: .number)
                        Text("×")
                        TextField("Height", value: $customHeight, format: .number)
                        Text("px")
                    }
                    .textFieldStyle(.roundedBorder)
                }

                if format.raster?.isLossy == true {
                    LabeledContent("Quality") {
                        HStack {
                            NumericSlider(value: $quality, range: 0.5...1,
                                          defaultValue: 0.9)
                            Text("\(Int((quality * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
                if format == .jpeg {
                    Text("JPEG has no transparency — the artwork is flattened onto the background color.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if format == .pdf {
                    Text("PDF preserves the rendered appearance as a single composited page. Layers and raster-only effects are explicitly flattened.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if targetSize() != document.model.canvasSize {
                    Text("The artwork scales to fill and center-crops if the aspect ratio differs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Patterns, shapes, and text export as true vectors; image layers are embedded as PNG.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !document.model.canvasEffects.isEmpty {
                    Text("Canvas effects are raster-only and will be skipped in SVG.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isExporting ? "Exporting…" : "Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isExporting)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func targetSize() -> CGSize {
        guard format != .svg else { return document.model.canvasSize }
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
                guard let data = PDFExporter.data(image: image, pageSize: targetSize()) else {
                    errorMessage = "PDF encoding failed."
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
}
