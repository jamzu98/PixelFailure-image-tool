import CoreGraphics
import SwiftUI

nonisolated struct WavesGenerator: PatternGenerator {
    var displayName: String { "Interference Waves" }

    var specs: [ParamSpec] {
        [
            .intSlider("lineCount", "Lines", min: 10, max: 240, initial: 70),
            .slider("amplitude", "Amplitude", min: 0, max: 0.4, initial: 0.06),
            .slider("frequency", "Frequency", min: 0.5, max: 10, initial: 2.5),
            .slider("phaseShift", "Phase Drift", min: 0, max: 2, initial: 0.35),
            .slider("noiseAmount", "Noise", min: 0, max: 1, initial: 0.25),
            .slider("noiseScale", "Noise Scale", min: 0.5, max: 6, initial: 2),
            .slider("lineWidth", "Line Width", min: 0.0008, max: 0.015, initial: 0.003),
            .choice("direction", "Direction", options: ["Horizontal", "Vertical"], initial: 0),
            .slider("ampRamp", "Amplitude Ramp", min: -1, max: 1, initial: 0),
        ] + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let noise = PerlinNoise(seed: seed)
        let size = context.size
        let minDim = context.minDimension

        let lineCount = max(2, params.int("lineCount", 70))
        let amplitude = params.double("amplitude", 0.06) * minDim
        let frequency = params.double("frequency", 2.5)
        let phaseShift = params.double("phaseShift", 0.35)
        let noiseAmount = params.double("noiseAmount", 0.25)
        let noiseScale = params.double("noiseScale", 2)
        let lineWidth = max(0.3, params.double("lineWidth", 0.003) * minDim)
        let vertical = params.int("direction", 0) == 1
        let ampRamp = params.double("ampRamp", 0)

        let along = vertical ? Double(size.height) : Double(size.width)
        let across = vertical ? Double(size.width) : Double(size.height)
        let sampleCount = 160

        var out: [VectorPrimitive] = []
        out.reserveCapacity(lineCount)

        for lineIndex in 0..<lineCount {
            let t = Double(lineIndex) / Double(lineCount - 1)
            let base = (t * 1.1 - 0.05) * across
            let phase = Double(lineIndex) * phaseShift
            let lineAmp = amplitude * (1 + ampRamp * (t * 2 - 1))

            var path = Path()
            for s in 0...sampleCount {
                let u = Double(s) / Double(sampleCount)
                let pos = u * along
                var offset = sin(u * frequency * 2 * .pi + phase) * lineAmp
                offset += noise.value(u * noiseScale * 4, t * noiseScale * 4) * lineAmp * noiseAmount * 2
                let point = vertical
                    ? CGPoint(x: base + offset, y: pos)
                    : CGPoint(x: pos, y: base + offset)
                if s == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let color = GenColor.pick(params, palette: context.palette, t: t, rng: &rng)
            out.append(VectorPrimitive(path: path, stroke: color, lineWidth: lineWidth, lineCap: .butt))
        }
        return out
    }
}
