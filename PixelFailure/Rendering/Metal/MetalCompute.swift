import CoreGraphics
import CoreImage
import Foundation
import Metal
import Synchronization

/// Shared Metal device, queue and compiled kernels for the app's compute
/// work (raster pattern generators, glitch effects). Thread-safe: every
/// method can run off the main actor.
nonisolated final class MetalCompute: @unchecked Sendable {
    /// nil on machines without a usable Metal device.
    static let shared: MetalCompute? = MetalCompute()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let library: MTLLibrary
    private let pipelines = Mutex<[String: MTLComputePipelineState]>([:])
    /// Why the kernels failed to compile, if they did (surfaced by tests).
    static let compileError = Mutex<String?>(nil)

    private init?() {
        // Kernels compile from source at first use; that keeps the build
        // free of Xcode's optional Metal Toolchain.
        let source = MetalShaderSource.generators + "\n" + MetalShaderSource.glitch
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            Self.compileError.withLock { $0 = String(describing: error) }
            return nil
        }
        self.device = device
        self.queue = queue
        self.library = library
    }

    func pipeline(_ name: String) -> MTLComputePipelineState? {
        if let cached = pipelines.withLock({ $0[name] }) { return cached }
        guard let function = library.makeFunction(name: name),
              let state = try? device.makeComputePipelineState(function: function) else { return nil }
        pipelines.withLock { $0[name] = state }
        return state
    }

    func makeTexture(width: Int, height: Int, format: MTLPixelFormat = .rgba16Float) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Dispatches `name` over `size`, binding textures in order, the float
    /// settings at buffer 0, the palette at buffer 1 and the seed at buffer 2.
    func dispatch(_ name: String, on encoder: MTLComputeCommandEncoder, textures: [MTLTexture],
                  params: [Float], palette: [SIMD4<Float>]? = nil, seed: UInt32? = nil,
                  width: Int, height: Int) -> Bool {
        guard let state = pipeline(name) else { return false }
        encoder.setComputePipelineState(state)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        if let palette {
            palette.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        }
        if var seed { encoder.setBytes(&seed, length: MemoryLayout<UInt32>.size, index: 2) }
        let threads = MTLSize(width: min(16, state.threadExecutionWidth), height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: threads)
        return true
    }

    /// Reads a texture of sRGB-encoded values back as a CGImage in the
    /// document's working space and bit depth.
    func image(from texture: MTLTexture, colorSettings: ColorSettings) -> CGImage? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ci = CIImage(mtlTexture: texture, options: [.colorSpace: srgb]) else { return nil }
        // Metal textures are top-down; Core Image is bottom-up.
        let flipped = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -CGFloat(texture.height)))
        let format: CIFormat = colorSettings.bitDepth == .sixteen ? .RGBA16 : .RGBA8
        return CoreImageContext.shared.createCGImage(flipped, from: flipped.extent, format: format,
                                                     colorSpace: colorSettings.workingSpace.cgColorSpace)
    }

    static func palette(_ palette: Palette) -> [SIMD4<Float>] {
        let colors = palette.colors.isEmpty ? [RGBAColor.black, .white] : Array(palette.colors.prefix(8))
        return colors.map { SIMD4<Float>(Float($0.r), Float($0.g), Float($0.b), Float($0.a)) }
    }
}
