import SwiftUI

struct ImageInspector: View {
    @ObservedObject var document: PixelDocument
    let layerID: UUID
    let config: ImageConfig
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        if let source = document.model.layer(id: layerID)?.source {
            InspectorSection("Original") {
                Button("Revert to Original") {
                    document.revertLayerToSource(id: layerID, undoManager: undoManager)
                }
                .help("Restore \(source.displayName), discarding baked edits")
            }
        }
        cropSection
        EffectStackSection(document: document,
                           title: "Effects",
                           target: .layer(layerID),
                           effects: config.effects)
    }

    // MARK: - Crop

    private var cropSection: some View {
        InspectorSection("Crop") {
            cropSlider("Left", key: \.minX)
            cropSlider("Top", key: \.minY)
            cropSlider("Width", key: \.width)
            cropSlider("Height", key: \.height)
            if config.crop != nil {
                Button("Reset Crop") {
                    document.update(undoManager, actionName: "Reset Crop") { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyImage { $0.crop = nil }
                        }
                    }
                }
            }
        }
    }

    private enum CropKey { case minX, minY, width, height }

    private func cropSlider(_ label: String, key: KeyPath<CGRect, CGFloat>) -> some View {
        let crop = config.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return LabeledContent(label) {
            NumericSlider(value: Binding(
                get: { Double(crop[keyPath: key]) },
                set: { newValue in
                    document.updateDuringGesture { model in
                        model.modifyLayer(id: layerID) { layer in
                            layer.modifyImage { imageConfig in
                                var rect = imageConfig.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                                switch key {
                                case \.minX: rect.origin.x = min(newValue, 0.95)
                                case \.minY: rect.origin.y = min(newValue, 0.95)
                                case \.width: rect.size.width = max(newValue, 0.05)
                                case \.height: rect.size.height = max(newValue, 0.05)
                                default: break
                                }
                                // Keep the crop inside the image.
                                rect.size.width = min(rect.width, 1 - rect.minX)
                                rect.size.height = min(rect.height, 1 - rect.minY)
                                imageConfig.crop = rect
                            }
                        }
                    }
                }
            ), range: 0...1,
               defaultValue: (key == \.width || key == \.height) ? 1 : 0) { editing in
                if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: "Crop") }
            }
        }
    }

}
