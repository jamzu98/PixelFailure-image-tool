import CoreImage
import Metal

/// The app's one Core Image context. Sharing it lets every effect, mask and
/// selection operation reuse the same Metal command queue, compiled kernels
/// and texture pool instead of each subsystem warming up its own.
///
/// Work happens in half-float extended linear sRGB, so P3 and 16-bit
/// documents keep their gamut and precision through filter chains; callers
/// choose the output format and color space when they render.
nonisolated enum CoreImageContext {
    static let shared: CIContext = {
        var options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingFormat: CIFormat.RGBAh,
            .name: "PixelFailure",
        ]
        if let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
            options[.workingColorSpace] = linear
        }
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()
}
