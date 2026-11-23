import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

/// Parameter schemas for each effect type. Size-like parameters are expressed
/// as fractions of the image's min dimension so previews (rendered downscaled)
/// and full-resolution exports look identical.
nonisolated extension EffectType {
    var specs: [ParamSpec] {
        switch self {
        case .adjust:
            return [
                .slider("exposure", "Exposure", min: -2, max: 2, initial: 0),
                .slider("contrast", "Contrast", min: 0.5, max: 2, initial: 1),
                .slider("saturation", "Saturation", min: 0, max: 2, initial: 1),
            ]
        case .curves:
            return []
        case .levels:
            return [
                .slider("inputBlack", "Input Black", min: 0, max: 0.95, initial: 0),
                .slider("gamma", "Gamma", min: 0.2, max: 3, initial: 1),
                .slider("inputWhite", "Input White", min: 0.05, max: 1, initial: 1),
                .slider("outputBlack", "Output Black", min: 0, max: 0.95, initial: 0),
                .slider("outputWhite", "Output White", min: 0.05, max: 1, initial: 1),
            ]
        case .targetedHSL:
            return [
                .slider("targetHue", "Target Hue", min: 0, max: 360, initial: 0),
                .slider("range", "Hue Range", min: 5, max: 180, initial: 45),
                .slider("hueShift", "Hue Shift", min: -180, max: 180, initial: 0),
                .slider("saturation", "Saturation", min: 0, max: 2, initial: 1),
                .slider("lightness", "Lightness", min: -0.5, max: 0.5, initial: 0),
            ]
        case .whiteBalance:
            return [
                .slider("temperature", "Temperature", min: 2500, max: 10000, initial: 6500),
                .slider("tint", "Tint", min: -150, max: 150, initial: 0),
            ]
        case .vibrance:
            return [.slider("amount", "Amount", min: -1, max: 2, initial: 0)]
        case .shadowsHighlights:
            return [
                .slider("shadows", "Shadows", min: -1, max: 1, initial: 0),
                .slider("highlights", "Highlights", min: -1, max: 1, initial: 0),
                .slider("radius", "Radius", min: 0, max: 0.2, initial: 0.05),
            ]
        case .pixelate:
            return [.slider("size", "Block Size", min: 0.002, max: 0.15, initial: 0.02)]
        case .hexPixelate:
            return [.slider("size", "Cell Size", min: 0.002, max: 0.15, initial: 0.02)]
        case .halftone:
            return [
                .slider("size", "Dot Size", min: 0.002, max: 0.08, initial: 0.012),
                .slider("angle", "Angle", min: 0, max: 180, initial: 45),
                .slider("sharpness", "Sharpness", min: 0, max: 1, initial: 0.7),
            ]
        case .lineScreen:
            return [
                .slider("size", "Line Spacing", min: 0.002, max: 0.08, initial: 0.01),
                .slider("angle", "Angle", min: 0, max: 180, initial: 0),
                .slider("sharpness", "Sharpness", min: 0, max: 1, initial: 0.7),
            ]
        case .posterize:
            return [.intSlider("levels", "Levels", min: 2, max: 12, initial: 4)]
        case .threshold:
            return [.slider("threshold", "Threshold", min: 0.05, max: 0.95, initial: 0.5)]
        case .duotone:
            return [
                .intSlider("colors", "Palette Colors", min: 2, max: 8, initial: 4),
                .slider("mix", "Mix", min: 0, max: 1, initial: 1),
            ]
        case .grain:
            return [
                .slider("amount", "Amount", min: 0, max: 1, initial: 0.4),
                .slider("size", "Grain Size", min: 0.0005, max: 0.01, initial: 0.0015),
            ]
        case .blur:
            return [.slider("radius", "Radius", min: 0, max: 0.08, initial: 0.01)]
        case .sharpen:
            return [.slider("radius", "Radius", min: 0.0005, max: 0.05, initial: 0.004),
                    .slider("intensity", "Amount", min: 0, max: 3, initial: 0.8)]
        case .noiseReduction:
            return [.slider("noise", "Noise", min: 0, max: 0.1, initial: 0.02),
                    .slider("sharpness", "Detail", min: 0, max: 1, initial: 0.4)]
        case .lensCorrection:
            return [.slider("distortion", "Distortion", min: -1, max: 1, initial: 0),
                    .slider("vignette", "Vignette", min: 0, max: 2, initial: 0)]
        case .rawDevelop:
            return [.slider("exposure", "Exposure", min: -5, max: 5, initial: 0),
                    .slider("highlights", "Highlights", min: -1, max: 1, initial: 0),
                    .slider("temperature", "Temperature", min: 2500, max: 10000, initial: 6500),
                    .slider("tint", "Tint", min: -150, max: 150, initial: 0)]
        case .bloom:
            return [
                .slider("radius", "Radius", min: 0, max: 0.05, initial: 0.01),
                .slider("intensity", "Intensity", min: 0, max: 1.5, initial: 0.5),
            ]
        case .sliceGlitch:
            return [
                .intSlider("slices", "Slices", min: 2, max: 60, initial: 14),
                .slider("offset", "Max Offset", min: 0, max: 0.4, initial: 0.08),
                .intSlider("variant", "Variant", min: 0, max: 100, initial: 0),
                .slider("coverage", "Coverage", min: 0.1, max: 1, initial: 0.6),
                .choice("direction", "Direction", options: ["Horizontal", "Vertical"], initial: 0),
            ]
        case .chromaticAberration:
            return [
                .slider("offset", "Offset", min: 0, max: 0.04, initial: 0.006),
                .slider("angle", "Angle", min: 0, max: 360, initial: 0),
            ]
        case .scanlines:
            return [
                .slider("spacing", "Spacing", min: 0.002, max: 0.05, initial: 0.008),
                .slider("darkness", "Darkness", min: 0, max: 1, initial: 0.45),
                .choice("direction", "Direction", options: ["Horizontal", "Vertical"], initial: 0),
            ]
        case .pixelSort:
            return [
                .choice("direction", "Direction", options: ["Horizontal", "Vertical"], initial: 0),
                .choice("sortBy", "Sort By", options: ["Brightness", "Hue", "Saturation"], initial: 0),
                .slider("low", "Low Threshold", min: 0, max: 1, initial: 0.25),
                .slider("high", "High Threshold", min: 0, max: 1, initial: 0.8),
                .slider("maxSpan", "Max Span", min: 0.01, max: 1, initial: 0.3),
                .toggle("reverse", "Reverse", initial: false),
            ]
        case .datamosh:
            return [
                .slider("blockSize", "Block Size", min: 0.005, max: 0.12, initial: 0.03),
                .slider("amount", "Amount", min: 0, max: 1, initial: 0.35),
                .slider("shift", "Shift", min: 0, max: 0.3, initial: 0.08),
                .slider("smear", "Smear", min: 0, max: 1, initial: 0.4),
                .slider("bleed", "Chroma Bleed", min: 0, max: 1, initial: 0.3),
                .intSlider("variant", "Variant", min: 0, max: 100, initial: 0),
            ]
        case .noiseShift:
            return [
                .slider("amount", "Amount", min: 0, max: 0.1, initial: 0.03),
                .slider("frequency", "Frequency", min: 0.5, max: 40, initial: 6),
                .slider("jitter", "Jitter", min: 0, max: 1, initial: 0.2),
                .choice("channels", "Channels", options: ["Red / Blue", "Red / Green / Blue"], initial: 0),
                .intSlider("variant", "Variant", min: 0, max: 100, initial: 0),
            ]
        case .dither:
            return [
                .choice("method", "Method", options: ["Bayer 4×4", "Bayer 8×8", "Blue Noise", "Floyd–Steinberg"],
                        initial: 1),
                .choice("colors", "Colors", options: ["Palette", "Black & White", "Grays"], initial: 0),
                .slider("cellSize", "Pixel Size", min: 0.0005, max: 0.02, initial: 0.002),
                .slider("spread", "Spread", min: 0, max: 1.5, initial: 0.8),
            ]
        }
    }

    var defaultParams: ParamValues {
        var values = ParamValues(defaults: specs)
        if self == .curves {
            values.setArray("points", [0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1])
        }
        return values
    }
}

/// Renders an image layer's effect stack with Core Image.
nonisolated final class EffectPipeline: @unchecked Sendable {
    static let shared = EffectPipeline()

    private var context: CIContext { CoreImageContext.shared }

    /// Applies enabled effects in order and returns a CGImage the same size as
    /// the input. `palette` feeds the Palette Map effect.
    func apply(effects: [Effect], to input: CGImage, palette: Palette) -> CGImage {
        let active = effects.filter(\.isEnabled)
        guard !active.isEmpty else { return input }

        let extent = CGRect(x: 0, y: 0, width: input.width, height: input.height)
        let minDim = Double(min(input.width, input.height))
        var image = CIImage(cgImage: input)

        for effect in active {
            image = apply(effect, to: image, extent: extent, minDim: minDim, palette: palette)
                .cropped(to: extent)
        }

        // Preserve the input's tagging: a P3 or 16-bit composite keeps its
        // gamut and depth through the effect stack instead of collapsing to
        // the CIContext default (sRGB 8-bit).
        let space = input.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let format: CIFormat = input.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let output = context.createCGImage(image, from: extent,
                                                 format: format, colorSpace: space) else { return input }
        return output
    }

    /// Converts a stored grayscale mask into the two forms renderers need:
    /// luminance (for SVG masks) and alpha (for CG/Canvas clipping).
    func maskImages(from grayscale: CGImage, inverted: Bool) -> (luminance: CGImage, alpha: CGImage)? {
        let extent = CGRect(x: 0, y: 0, width: grayscale.width, height: grayscale.height)
        var image = CIImage(cgImage: grayscale)
        if inverted {
            image = image.applyingFilter("CIColorInvert").cropped(to: extent)
        }
        guard let luminance = context.createCGImage(image, from: extent) else { return nil }
        let alphaImage = image.applyingFilter("CIMaskToAlpha")
        guard let alpha = context.createCGImage(alphaImage, from: extent) else { return nil }
        return (luminance, alpha)
    }

    private func apply(_ effect: Effect, to image: CIImage, extent: CGRect, minDim: Double, palette: Palette) -> CIImage {
        let p = effect.params
        switch effect.type {
        case .adjust:
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = image
            exposure.ev = Float(p.double("exposure", 0))
            let controls = CIFilter.colorControls()
            controls.inputImage = exposure.outputImage
            controls.contrast = Float(p.double("contrast", 1))
            controls.saturation = Float(p.double("saturation", 1))
            return controls.outputImage ?? image

        case .curves:
            let raw = p.array("points", [0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1])
            let points = stride(from: 0, to: min(raw.count, 10), by: 2).map {
                CIVector(x: raw[$0], y: raw[$0 + 1])
            }
            guard points.count == 5 else { return image }
            return image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": points[0], "inputPoint1": points[1],
                "inputPoint2": points[2], "inputPoint3": points[3],
                "inputPoint4": points[4],
            ])

        case .levels:
            let black = min(p.double("inputBlack", 0), p.double("inputWhite", 1) - 0.001)
            let white = max(p.double("inputWhite", 1), black + 0.001)
            let scale = 1 / (white - black)
            var output = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputBiasVector": CIVector(x: -black * scale, y: -black * scale,
                                              z: -black * scale, w: 0),
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
            output = output.applyingFilter("CIGammaAdjust",
                                           parameters: ["inputPower": 1 / max(0.01, p.double("gamma", 1))])
            let outBlack = p.double("outputBlack", 0)
            let outWhite = max(outBlack, p.double("outputWhite", 1))
            let outScale = outWhite - outBlack
            return output.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: outScale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: outScale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: outScale, w: 0),
                "inputBiasVector": CIVector(x: outBlack, y: outBlack, z: outBlack, w: 0),
            ])

        case .targetedHSL:
            return targetedHSL(image, params: p)

        case .whiteBalance:
            let temperature = p.double("temperature", 6500)
            let tint = p.double("tint", 0)
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: temperature, y: tint),
            ])

        case .vibrance:
            return image.applyingFilter("CIVibrance",
                                        parameters: ["inputAmount": p.double("amount", 0)])

        case .shadowsHighlights:
            return image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": p.double("shadows", 0),
                "inputHighlightAmount": p.double("highlights", 0),
                "inputRadius": p.double("radius", 0.05) * minDim,
            ])

        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = image.clampedToExtent()
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            filter.scale = Float(max(1, p.double("size", 0.02) * minDim))
            return filter.outputImage ?? image

        case .hexPixelate:
            let filter = CIFilter.hexagonalPixellate()
            filter.inputImage = image.clampedToExtent()
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            filter.scale = Float(max(1, p.double("size", 0.02) * minDim))
            return filter.outputImage ?? image

        case .halftone:
            let filter = CIFilter.dotScreen()
            filter.inputImage = image.clampedToExtent()
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            filter.width = Float(max(1, p.double("size", 0.012) * minDim))
            filter.angle = Float(p.double("angle", 45) * .pi / 180)
            filter.sharpness = Float(p.double("sharpness", 0.7))
            return filter.outputImage ?? image

        case .lineScreen:
            let filter = CIFilter.lineScreen()
            filter.inputImage = image.clampedToExtent()
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            filter.width = Float(max(1, p.double("size", 0.01) * minDim))
            filter.angle = Float(p.double("angle", 0) * .pi / 180)
            filter.sharpness = Float(p.double("sharpness", 0.7))
            return filter.outputImage ?? image

        case .posterize:
            let filter = CIFilter.colorPosterize()
            filter.inputImage = image
            filter.levels = Float(p.int("levels", 4))
            return filter.outputImage ?? image

        case .threshold:
            let filter = CIFilter.colorThreshold()
            filter.inputImage = image
            filter.threshold = Float(p.double("threshold", 0.5))
            return filter.outputImage ?? image

        case .duotone:
            return paletteMap(image, extent: extent, palette: palette,
                              colorCount: p.int("colors", 4), mix: p.double("mix", 1))

        case .grain:
            return grain(image, extent: extent, minDim: minDim,
                         amount: p.double("amount", 0.4), size: p.double("size", 0.0015))

        case .blur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(p.double("radius", 0.01) * minDim)
            return filter.outputImage ?? image

        case .sharpen:
            return image.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: p.double("radius", 0.004) * minDim,
                kCIInputIntensityKey: p.double("intensity", 0.8),
            ])

        case .noiseReduction:
            return image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": p.double("noise", 0.02),
                "inputSharpness": p.double("sharpness", 0.4),
            ])

        case .lensCorrection:
            var result = image
            let distortion = p.double("distortion", 0)
            if abs(distortion) > 0.0001 {
                result = result.applyingFilter("CIBumpDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    kCIInputRadiusKey: hypot(extent.width, extent.height),
                    kCIInputScaleKey: distortion * -0.35,
                ])
            }
            let vignette = p.double("vignette", 0)
            if vignette > 0.0001 {
                result = result.applyingFilter("CIVignette", parameters: [
                    kCIInputIntensityKey: vignette, kCIInputRadiusKey: minDim,
                ])
            }
            return result

        case .rawDevelop:
            var linear = image.applyingFilter("CISRGBToneCurveToLinear")
            linear = linear.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: p.double("exposure", 0),
            ])
            linear = linear.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": p.double("highlights", 0),
            ])
            linear = linear.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: p.double("temperature", 6500),
                                                y: p.double("tint", 0)),
            ])
            return linear.applyingFilter("CILinearToSRGBToneCurve")

        case .bloom:
            let filter = CIFilter.bloom()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(p.double("radius", 0.01) * minDim)
            filter.intensity = Float(p.double("intensity", 0.5))
            return filter.outputImage ?? image

        case .sliceGlitch:
            return sliceGlitch(image, extent: extent, params: p)

        case .chromaticAberration:
            return chromaticAberration(image, extent: extent, minDim: minDim, params: p)

        case .scanlines:
            return scanlines(image, extent: extent, minDim: minDim, params: p)

        case .pixelSort:
            return GlitchEffects.pixelSort(image, extent: extent, params: p)

        case .datamosh:
            return GlitchEffects.datamosh(image, extent: extent, minDim: minDim, params: p)

        case .noiseShift:
            return GlitchEffects.noiseShift(image, extent: extent, params: p)

        case .dither:
            return GlitchEffects.dither(image, extent: extent, minDim: minDim, palette: palette, params: p)
        }
    }

    // MARK: - Custom passes

    private func targetedHSL(_ image: CIImage, params: ParamValues) -> CIImage {
        let dimension = 24
        let target = params.double("targetHue", 0) / 360
        let range = max(params.double("range", 45) / 360, 0.001)
        let shift = params.double("hueShift", 0) / 360
        let saturation = params.double("saturation", 1)
        let lightness = params.double("lightness", 0)
        var cube = [Float]()
        cube.reserveCapacity(dimension * dimension * dimension * 4)
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let rgb = (Double(r) / Double(dimension - 1),
                               Double(g) / Double(dimension - 1),
                               Double(b) / Double(dimension - 1))
                    var hsv = rgbToHSV(rgb)
                    let rawDistance = abs(hsv.h - target)
                    let distance = min(rawDistance, 1 - rawDistance)
                    let weight = max(0, 1 - distance / range)
                    hsv.h = (hsv.h + shift * weight).truncatingRemainder(dividingBy: 1)
                    if hsv.h < 0 { hsv.h += 1 }
                    hsv.s = min(max(hsv.s * (1 + (saturation - 1) * weight), 0), 1)
                    hsv.v = min(max(hsv.v + lightness * weight, 0), 1)
                    let out = hsvToRGB(hsv)
                    cube += [Float(out.r), Float(out.g), Float(out.b), 1]
                }
            }
        }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data,
        ])
    }

    private func rgbToHSV(_ rgb: (r: Double, g: Double, b: Double))
        -> (h: Double, s: Double, v: Double) {
        let maximum = max(rgb.r, rgb.g, rgb.b)
        let minimum = min(rgb.r, rgb.g, rgb.b)
        let delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == rgb.r { hue = ((rgb.g - rgb.b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == rgb.g { hue = (rgb.b - rgb.r) / delta + 2 }
            else { hue = (rgb.r - rgb.g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maximum == 0 ? 0 : delta / maximum, maximum)
    }

    private func hsvToRGB(_ hsv: (h: Double, s: Double, v: Double))
        -> (r: Double, g: Double, b: Double) {
        let scaled = hsv.h * 6
        let sector = Int(floor(scaled)) % 6
        let fraction = scaled - floor(scaled)
        let p = hsv.v * (1 - hsv.s)
        let q = hsv.v * (1 - fraction * hsv.s)
        let t = hsv.v * (1 - (1 - fraction) * hsv.s)
        switch sector {
        case 0: return (hsv.v, t, p)
        case 1: return (q, hsv.v, p)
        case 2: return (p, hsv.v, t)
        case 3: return (p, q, hsv.v)
        case 4: return (t, p, hsv.v)
        default: return (hsv.v, p, q)
        }
    }

    /// Remaps image tones onto the document palette via a gradient color map.
    private func paletteMap(_ image: CIImage, extent: CGRect, palette: Palette, colorCount: Int, mix: Double) -> CIImage {
        let colors = Array(palette.sortedByLuminance.colors.prefix(max(2, colorCount)))
        guard colors.count >= 2 else { return image }

        // Build a 256x1 gradient strip through the palette stops.
        let width = 256
        var pixels = [UInt8](repeating: 0, count: width * 4)
        for x in 0..<width {
            let t = Double(x) / Double(width - 1)
            let scaled = t * Double(colors.count - 1)
            let i = min(Int(scaled), colors.count - 2)
            let c = colors[i].lerp(to: colors[i + 1], t: scaled - Double(i))
            pixels[x * 4] = UInt8(min(255, c.r * 255))
            pixels[x * 4 + 1] = UInt8(min(255, c.g * 255))
            pixels[x * 4 + 2] = UInt8(min(255, c.b * 255))
            pixels[x * 4 + 3] = 255
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let gradient = CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: true,
                                     intent: .defaultIntent) else { return image }

        let desaturate = CIFilter.colorControls()
        desaturate.inputImage = image
        desaturate.saturation = 0
        guard let gray = desaturate.outputImage else { return image }

        let map = CIFilter.colorMap()
        map.inputImage = gray
        map.gradientImage = CIImage(cgImage: gradient)
        guard let mapped = map.outputImage else { return image }

        guard mix < 0.999 else { return mapped }
        // Blend mapped over original by alpha.
        let faded = mapped.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(mix)),
        ])
        return faded.composited(over: image)
    }

    private func grain(_ image: CIImage, extent: CGRect, minDim: Double, amount: Double, size: Double) -> CIImage {
        guard amount > 0.001 else { return image }
        let noise = CIFilter.randomGenerator().outputImage ?? CIImage.empty()
        let scale = max(0.5, size * minDim)
        let scaled = noise.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let mono = scaled.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1.5,
        ])
        let faded = mono.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount * 0.55)),
        ]).cropped(to: extent)
        let blend = CIFilter.overlayBlendMode()
        blend.inputImage = faded
        blend.backgroundImage = image
        return blend.outputImage ?? image
    }

    /// Displaces random horizontal (or vertical) bands — the classic glitch.
    private func sliceGlitch(_ image: CIImage, extent: CGRect, params p: ParamValues) -> CIImage {
        let slices = max(2, p.int("slices", 14))
        let maxOffset = p.double("offset", 0.08)
        let variant = UInt64(p.int("variant", 0))
        let coverage = p.double("coverage", 0.6)
        let vertical = p.int("direction", 0) == 1

        var rng = SeededRNG(seed: 0xC0FFEE &+ variant &* 7919)
        var result = image
        let length = vertical ? extent.width : extent.height
        let sliceThickness = length / CGFloat(slices)

        for i in 0..<slices {
            guard rng.chance(coverage) else { _ = rng.unit(); continue }
            let offset = rng.jitter(maxOffset) * (vertical ? Double(extent.height) : Double(extent.width))
            let band: CGRect = vertical
                ? CGRect(x: extent.minX + CGFloat(i) * sliceThickness, y: extent.minY,
                         width: sliceThickness, height: extent.height)
                : CGRect(x: extent.minX, y: extent.minY + CGFloat(i) * sliceThickness,
                         width: extent.width, height: sliceThickness)
            let translation = vertical
                ? CGAffineTransform(translationX: 0, y: CGFloat(offset))
                : CGAffineTransform(translationX: CGFloat(offset), y: 0)
            let shifted = image.cropped(to: band).transformed(by: translation)
            result = shifted.composited(over: result)
        }
        return result
    }

    /// Offsets the red and blue channels in opposite directions.
    private func chromaticAberration(_ image: CIImage, extent: CGRect, minDim: Double, params p: ParamValues) -> CIImage {
        let offset = p.double("offset", 0.006) * minDim
        guard offset > 0.01 else { return image }
        let angle = p.double("angle", 0) * .pi / 180
        let dx = CGFloat(cos(angle) * offset)
        let dy = CGFloat(sin(angle) * offset)

        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            ])
        }

        let red = channel(1, 0, 0).transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let green = channel(0, 1, 0)
        let blue = channel(0, 0, 1).transformed(by: CGAffineTransform(translationX: -dx, y: -dy))

        let redPlusGreen = red.clampedToExtent().applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: green.clampedToExtent(),
        ])
        return blue.clampedToExtent().applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: redPlusGreen,
        ])
    }

    private func scanlines(_ image: CIImage, extent: CGRect, minDim: Double, params p: ParamValues) -> CIImage {
        let spacing = max(1, p.double("spacing", 0.008) * minDim)
        let darkness = p.double("darkness", 0.45)
        guard darkness > 0.001 else { return image }
        let vertical = p.int("direction", 0) == 1

        let stripes = CIFilter.stripesGenerator()
        stripes.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(darkness))
        stripes.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        stripes.width = Float(spacing / 2)
        stripes.sharpness = 0.9
        guard var stripeImage = stripes.outputImage else { return image }
        // Stripes come out vertical; rotate for horizontal scanlines.
        if !vertical {
            stripeImage = stripeImage.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
        }
        let overlay = stripeImage.cropped(to: extent)
        return overlay.composited(over: image)
    }
}
