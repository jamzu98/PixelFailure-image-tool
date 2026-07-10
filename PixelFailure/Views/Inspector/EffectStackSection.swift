import SwiftUI
import ImageIO

/// Where an effect stack lives: on an image layer, or on the whole canvas.
enum EffectsTarget {
    case layer(UUID)
    case canvas

    /// Mutates the target's effects array inside the model.
    func withEffects(_ model: inout ProjectModel, _ change: (inout [Effect]) -> Void) {
        switch self {
        case .layer(let id):
            model.modifyLayer(id: id) { layer in
                if layer.kind.isImage {
                    layer.modifyImage { config in change(&config.effects) }
                } else if layer.kind.isAdjustment {
                    layer.modifyAdjustment { config in change(&config.effects) }
                }
            }
        case .canvas:
            change(&model.canvasEffects)
        }
    }
}

/// The non-destructive effect stack UI: reorder, toggle, tune, add, remove.
/// Shared between image layers and the canvas-level adjustment stack.
struct EffectStackSection: View {
    @ObservedObject var document: PixelDocument
    let title: String
    let target: EffectsTarget
    let effects: [Effect]
    var footnote: String?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Section {
            ForEach(Array(effects.enumerated()), id: \.element.id) { index, effect in
                effectRow(effect, index: index)
            }

            Menu("Add Effect") {
                ForEach(EffectType.allCases, id: \.self) { type in
                    Button(type.displayName) {
                        document.update(undoManager, actionName: "Add \(type.displayName)") { model in
                            target.withEffects(&model) { effects in
                                effects.append(Effect(type: type, params: type.defaultParams))
                            }
                        }
                    }
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let footnote, !effects.isEmpty || footnote.contains("PNG") {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if effects.isEmpty {
                Text("Effects stack non-destructively, in order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func effectRow(_ effect: Effect, index: Int) -> some View {
        DisclosureGroup {
            if effect.type == .levels {
                HistogramView(imageData: sourceImageData)
            }
            if effect.type == .curves {
                CurveEditor(document: document, target: target, effect: effect)
            } else {
                ParamControls(document: document,
                              specs: effect.type.specs,
                              values: effect.params) { model, key, value in
                    target.withEffects(&model) { effects in
                        guard let i = effects.firstIndex(where: { $0.id == effect.id }) else { return }
                        effects[i].params.set(key, value)
                    }
                }
            }
        } label: {
            HStack {
                Toggle("", isOn: Binding(
                    get: { effect.isEnabled },
                    set: { newValue in
                        document.update(undoManager, actionName: "Toggle Effect") { model in
                            target.withEffects(&model) { effects in
                                guard let i = effects.firstIndex(where: { $0.id == effect.id }) else { return }
                                effects[i].isEnabled = newValue
                            }
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()

                Text(effect.type.displayName)

                Spacer()

                Button {
                    moveEffect(effect.id, by: -1)
                } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)

                Button {
                    moveEffect(effect.id, by: 1)
                } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(index == effects.count - 1)

                Button {
                    document.update(undoManager, actionName: "Remove Effect") { model in
                        target.withEffects(&model) { effects in
                            effects.removeAll { $0.id == effect.id }
                        }
                    }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var sourceImageData: Data? {
        guard case .layer(let id) = target,
              let key = document.model.layer(id: id)?.imageConfig?.imageKey else { return nil }
        return document.imageData(for: key)
    }

    private func moveEffect(_ effectID: UUID, by delta: Int) {
        document.update(undoManager, actionName: "Reorder Effects") { model in
            target.withEffects(&model) { effects in
                guard let i = effects.firstIndex(where: { $0.id == effectID }) else { return }
                let j = i + delta
                guard effects.indices.contains(j) else { return }
                effects.swapAt(i, j)
            }
        }
    }
}

/// Five-point interactive tone curve. Endpoints keep their x coordinates;
/// interior points can move without crossing their neighbours.
private struct CurveEditor: View {
    @ObservedObject var document: PixelDocument
    let target: EffectsTarget
    let effect: Effect
    @Environment(\.undoManager) private var undoManager
    @State private var activePoint: Int?

    private var points: [Double] {
        effect.params.array("points", [0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1])
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Canvas { context, _ in
                    var grid = Path()
                    for i in 0...4 {
                        let x = size.width * CGFloat(i) / 4
                        let y = size.height * CGFloat(i) / 4
                        grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                        grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
                    var curve = Path()
                    for index in 0..<5 {
                        let point = displayPoint(index, size: size)
                        if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                    }
                    context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
                }
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(index == activePoint ? Color.accentColor : Color.white)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                        .position(displayPoint(index, size: size))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in updateCurve(value, size: size) }
                .onEnded { _ in
                    activePoint = nil
                    document.endGesture(undoManager, actionName: "Curves")
                })
        }
        .frame(height: 130)

        HStack {
            Text(activePoint.map { "Point \($0 + 1)" } ?? "Drag a curve point")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset") {
                write([0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1], gesture: false)
            }
        }
    }

    private func displayPoint(_ index: Int, size: CGSize) -> CGPoint {
        guard points.count >= 10 else { return .zero }
        return CGPoint(x: points[index * 2] * size.width,
                       y: (1 - points[index * 2 + 1]) * size.height)
    }

    private func updateCurve(_ value: DragGesture.Value, size: CGSize) {
        var updated = points
        guard updated.count >= 10 else { return }
        if activePoint == nil {
            activePoint = (0..<5).min { a, b in
                hypot(displayPoint(a, size: size).x - value.startLocation.x,
                      displayPoint(a, size: size).y - value.startLocation.y)
                < hypot(displayPoint(b, size: size).x - value.startLocation.x,
                        displayPoint(b, size: size).y - value.startLocation.y)
            }
            document.beginGesture()
        }
        guard let index = activePoint else { return }
        if index > 0 && index < 4 {
            let lower = updated[(index - 1) * 2] + 0.02
            let upper = updated[(index + 1) * 2] - 0.02
            updated[index * 2] = min(max(value.location.x / size.width, lower), upper)
        }
        updated[index * 2 + 1] = min(max(1 - value.location.y / size.height, 0), 1)
        write(updated, gesture: true)
    }

    private func write(_ points: [Double], gesture: Bool) {
        let change: (inout ProjectModel) -> Void = { model in
            target.withEffects(&model) { effects in
                guard let index = effects.firstIndex(where: { $0.id == effect.id }) else { return }
                effects[index].params.setArray("points", points)
            }
        }
        if gesture { document.updateDuringGesture(change) }
        else { document.update(undoManager, actionName: "Reset Curves", change) }
    }
}

private struct HistogramView: View {
    let imageData: Data?
    @State private var bins: [Double]

    init(imageData: Data?) {
        self.imageData = imageData
        _bins = State(initialValue: Self.compute(imageData))
    }

    var body: some View {
        Canvas { context, size in
            guard bins.count == 64 else { return }
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for index in bins.indices {
                let x = CGFloat(index) / CGFloat(bins.count - 1) * size.width
                area.addLine(to: CGPoint(x: x, y: size.height * (1 - bins[index])))
            }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(.secondary.opacity(0.45)))
        }
        .frame(height: 58)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
        .onChange(of: imageData) { _, data in bins = Self.compute(data) }
    }

    private static func compute(_ data: Data?) -> [Double] {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return Array(repeating: 0, count: 64)
        }
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Array(repeating: 0, count: 64)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var counts = [Double](repeating: 0, count: 64)
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 0 {
            let luminance = 0.2126 * Double(pixels[index])
                + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])
            counts[min(Int(luminance / 256 * 64), 63)] += 1
        }
        let peak = counts.max() ?? 1
        return peak > 0 ? counts.map { sqrt($0 / peak) } : counts
    }
}
