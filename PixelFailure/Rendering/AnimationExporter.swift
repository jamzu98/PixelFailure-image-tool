import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum AnimationExportFormat: String, CaseIterable {
    case gif = "GIF"
    case mp4 = "MP4"

    var fileExtension: String { rawValue.lowercased() }
    var utType: UTType { self == .gif ? .gif : .mpeg4Movie }
}

enum AnimationExportError: LocalizedError {
    case renderingFailed, destinationFailed, cancelled

    var errorDescription: String? {
        switch self {
        case .renderingFailed: "A frame could not be rendered."
        case .destinationFailed: "The animation encoder could not create the destination."
        case .cancelled: "Export cancelled."
        }
    }
}

@MainActor
enum AnimationExporter {
    static func export(format: AnimationExportFormat, to url: URL,
                       model: ProjectModel, size: CGSize,
                       render: (ProjectModel, CGSize) -> CGImage?,
                       progress: (Double) -> Void) async throws {
        switch format {
        case .gif:
            try await exportGIF(to: url, model: model, size: size,
                                render: render, progress: progress)
        case .mp4:
            try await exportMP4(to: url, model: model, size: size,
                                render: render, progress: progress)
        }
    }

    private static func exportGIF(to url: URL, model: ProjectModel, size: CGSize,
                                  render: (ProjectModel, CGSize) -> CGImage?,
                                  progress: (Double) -> Void) async throws {
        let count = model.animation.frameCount
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw AnimationExportError.destinationFailed
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let delay = 1 / Double(model.animation.framesPerSecond)
        for frame in 0..<count {
            guard !Task.isCancelled else { throw AnimationExportError.cancelled }
            let time = count > 1 ? Double(frame) / Double(count - 1) * model.animation.duration : 0
            guard let image = render(model.model(at: time), size) else {
                throw AnimationExportError.renderingFailed
            }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay],
            ] as CFDictionary)
            progress(Double(frame + 1) / Double(count))
            await Task.yield()
        }
        guard CGImageDestinationFinalize(destination) else {
            throw AnimationExportError.destinationFailed
        }
    }

    private static func exportMP4(to url: URL, model: ProjectModel, size: CGSize,
                                  render: (ProjectModel, CGSize) -> CGImage?,
                                  progress: (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let width = max(2, Int(size.width) / 2 * 2)
        let height = max(2, Int(size.height) / 2 * 2)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 6],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw AnimationExportError.destinationFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AnimationExportError.destinationFailed }
        writer.startSession(atSourceTime: .zero)
        let count = model.animation.frameCount
        for frame in 0..<count {
            guard !Task.isCancelled else {
                writer.cancelWriting()
                throw AnimationExportError.cancelled
            }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(8))
            }
            let time = count > 1 ? Double(frame) / Double(count - 1) * model.animation.duration : 0
            guard let image = render(model.model(at: time), CGSize(width: width, height: height)),
                  let buffer = pixelBuffer(image: image, width: width, height: height),
                  adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                                       timescale: CMTimeScale(model.animation.framesPerSecond))) else {
                writer.cancelWriting()
                throw writer.error ?? AnimationExportError.renderingFailed
            }
            progress(Double(frame + 1) / Double(count))
            await Task.yield()
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? AnimationExportError.destinationFailed
        }
    }

    private static func pixelBuffer(image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferCGImageCompatibilityKey: true,
                                   kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
