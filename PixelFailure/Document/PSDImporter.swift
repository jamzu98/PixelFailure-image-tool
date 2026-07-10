import CoreGraphics
import Foundation

enum PSDImportError: LocalizedError {
    case corrupt, unsupported(String), noLayers

    var errorDescription: String? {
        switch self {
        case .corrupt: "The PSD layer data is corrupt or truncated."
        case .unsupported(let detail): "Unsupported PSD construct: \(detail)."
        case .noLayers: "The PSD contains no decodable layer records."
        }
    }
}

struct PSDDecodedLayer {
    var name: String
    var rect: CGRect
    var opacity: Double
    var blendMode: LayerBlendMode
    var image: CGImage
}

struct PSDDecodedDocument {
    var size: CGSize
    /// PSD records are top-to-bottom.
    var layers: [PSDDecodedLayer]
}

/// Focused PSD reader for the most interoperable layered subset: standard
/// PSD (not PSB), 8-bit RGB, raw or PackBits/RLE channels. Unsupported files
/// deliberately fall back to ImageIO's composite in DocumentOperations.
nonisolated enum PSDImporter {
    private struct ChannelRecord {
        var id: Int16
        var length: Int
    }

    private struct LayerRecord {
        var name: String
        var rect: CGRect
        var opacity: Double
        var blend: LayerBlendMode
        var channels: [ChannelRecord]
    }

    static func decode(_ data: Data) throws -> PSDDecodedDocument {
        var reader = Reader(data)
        guard try reader.ascii(4) == "8BPS", try reader.u16() == 1 else {
            throw PSDImportError.unsupported("PSB or unknown signature")
        }
        try reader.skip(6)
        _ = try reader.u16() // composite channel count
        let canvasHeight = Int(try reader.u32())
        let canvasWidth = Int(try reader.u32())
        let depth = try reader.u16()
        let colorMode = try reader.u16()
        guard depth == 8, colorMode == 3 else {
            throw PSDImportError.unsupported("only 8-bit RGB documents are currently layered")
        }
        try reader.skipSection32() // color mode data
        try reader.skipSection32() // image resources

        let layerMaskLength = Int(try reader.u32())
        guard layerMaskLength > 0 else { throw PSDImportError.noLayers }
        let layerMaskEnd = try reader.checkedEnd(length: layerMaskLength)
        let layerInfoLength = Int(try reader.u32())
        guard layerInfoLength > 2 else { throw PSDImportError.noLayers }
        let layerInfoEnd = try reader.checkedEnd(length: layerInfoLength)
        let signedCount = try reader.i16()
        let layerCount = abs(Int(signedCount))
        guard layerCount > 0, layerCount < 20_000 else { throw PSDImportError.corrupt }

        var records: [LayerRecord] = []
        records.reserveCapacity(layerCount)
        for index in 0..<layerCount {
            let top = Int(try reader.i32()), left = Int(try reader.i32())
            let bottom = Int(try reader.i32()), right = Int(try reader.i32())
            let channelCount = Int(try reader.u16())
            guard channelCount < 64 else { throw PSDImportError.corrupt }
            var channels: [ChannelRecord] = []
            for _ in 0..<channelCount {
                channels.append(ChannelRecord(id: try reader.i16(),
                                              length: Int(try reader.u32())))
            }
            guard try reader.ascii(4) == "8BIM" else { throw PSDImportError.corrupt }
            let blendKey = try reader.ascii(4)
            let opacity = Double(try reader.u8()) / 255
            try reader.skip(3) // clipping, flags, filler
            let extraLength = Int(try reader.u32())
            let extraEnd = try reader.checkedEnd(length: extraLength)
            try reader.skipSection32() // layer mask/adjustment data
            try reader.skipSection32() // blending ranges

            let pascalLength = Int(try reader.u8())
            let pascalName = String(data: try reader.bytes(pascalLength), encoding: .macOSRoman)
                ?? "Layer \(index + 1)"
            let pascalEntryLength = 1 + pascalLength
            try reader.skip((4 - pascalEntryLength % 4) % 4)
            var name = pascalName
            while reader.offset + 12 <= extraEnd {
                let signature = try reader.ascii(4)
                guard signature == "8BIM" || signature == "8B64" else { break }
                let key = try reader.ascii(4)
                let blockLength = Int(try reader.u32())
                let blockEnd = try reader.checkedEnd(length: blockLength)
                if key == "luni", blockLength >= 4 {
                    let count = Int(try reader.u32())
                    let stringBytes = min(count * 2, blockEnd - reader.offset)
                    let unicode = try reader.bytes(stringBytes)
                    if let decoded = String(data: unicode, encoding: .utf16BigEndian), !decoded.isEmpty {
                        name = decoded
                    }
                }
                reader.offset = blockEnd + (blockLength.isMultiple(of: 2) ? 0 : 1)
            }
            reader.offset = extraEnd
            let rect = CGRect(x: left, y: top, width: max(0, right - left),
                              height: max(0, bottom - top))
            records.append(LayerRecord(name: name, rect: rect, opacity: opacity,
                                       blend: blendMode(blendKey), channels: channels))
        }

        var decoded: [PSDDecodedLayer] = []
        decoded.reserveCapacity(records.count)
        for record in records {
            let width = Int(record.rect.width), height = Int(record.rect.height)
            var planes: [Int16: [UInt8]] = [:]
            for channel in record.channels {
                let channelStart = reader.offset
                let channelEnd = try reader.checkedEnd(length: channel.length)
                if width > 0, height > 0, [Int16(-1), 0, 1, 2].contains(channel.id) {
                    let compression = try reader.u16()
                    switch compression {
                    case 0:
                        planes[channel.id] = Array(try reader.bytes(width * height))
                    case 1:
                        var rowLengths: [Int] = []
                        rowLengths.reserveCapacity(height)
                        for _ in 0..<height { rowLengths.append(Int(try reader.u16())) }
                        var plane: [UInt8] = []
                        plane.reserveCapacity(width * height)
                        for length in rowLengths {
                            let row = try unpackBits(Array(try reader.bytes(length)), expected: width)
                            plane.append(contentsOf: row)
                        }
                        planes[channel.id] = plane
                    default:
                        throw PSDImportError.unsupported("ZIP-compressed layer channels")
                    }
                }
                reader.offset = max(channelStart, channelEnd)
            }
            guard width > 0, height > 0,
                  let red = planes[0], let green = planes[1], let blue = planes[2],
                  red.count == width * height, green.count == red.count, blue.count == red.count,
                  let image = makeImage(width: width, height: height, red: red, green: green,
                                        blue: blue, alpha: planes[-1]) else { continue }
            decoded.append(PSDDecodedLayer(name: record.name, rect: record.rect,
                                           opacity: record.opacity, blendMode: record.blend,
                                           image: image))
        }
        reader.offset = min(max(reader.offset, layerInfoEnd), layerMaskEnd)
        guard !decoded.isEmpty else { throw PSDImportError.noLayers }
        return PSDDecodedDocument(size: CGSize(width: canvasWidth, height: canvasHeight),
                                  layers: decoded)
    }

    private static func unpackBits(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        var output: [UInt8] = []
        var index = 0
        while index < input.count, output.count < expected {
            let control = Int(Int8(bitPattern: input[index]))
            index += 1
            if control >= 0 {
                let count = control + 1
                guard index + count <= input.count else { throw PSDImportError.corrupt }
                output.append(contentsOf: input[index..<(index + count)])
                index += count
            } else if control >= -127 {
                guard index < input.count else { throw PSDImportError.corrupt }
                output.append(contentsOf: repeatElement(input[index], count: 1 - control))
                index += 1
            }
        }
        guard output.count >= expected else { throw PSDImportError.corrupt }
        return Array(output.prefix(expected))
    }

    private static func makeImage(width: Int, height: Int, red: [UInt8], green: [UInt8],
                                  blue: [UInt8], alpha: [UInt8]?) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let a = alpha.flatMap { index < $0.count ? $0[index] : nil } ?? 255
            let scale = Int(a)
            rgba[index * 4] = UInt8(Int(red[index]) * scale / 255)
            rgba[index * 4 + 1] = UInt8(Int(green[index]) * scale / 255)
            rgba[index * 4 + 2] = UInt8(Int(blue[index]) * scale / 255)
            rgba[index * 4 + 3] = a
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    private static func blendMode(_ key: String) -> LayerBlendMode {
        ["norm": .normal, "mul ": .multiply, "scrn": .screen, "over": .overlay,
         "dark": .darken, "lite": .lighten, "div ": .colorDodge, "idiv": .colorBurn,
         "sLit": .softLight, "hLit": .hardLight, "diff": .difference, "smud": .exclusion,
         "hue ": .hue, "sat ": .saturation, "colr": .color, "lum ": .luminosity][key] ?? .normal
    }

    private struct Reader {
        let data: Data
        var offset = 0

        init(_ data: Data) { self.data = data }
        mutating func require(_ count: Int) throws {
            guard count >= 0, offset >= 0, offset + count <= data.count else {
                throw PSDImportError.corrupt
            }
        }
        mutating func checkedEnd(length: Int) throws -> Int {
            try require(length)
            return offset + length
        }
        mutating func bytes(_ count: Int) throws -> Data {
            try require(count)
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func skip(_ count: Int) throws { _ = try bytes(count) }
        mutating func skipSection32() throws { try skip(Int(try u32())) }
        mutating func ascii(_ count: Int) throws -> String {
            String(data: try bytes(count), encoding: .ascii) ?? ""
        }
        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func u16() throws -> UInt16 {
            let value = try bytes(2)
            return value.reduce(0) { ($0 << 8) | UInt16($1) }
        }
        mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
        mutating func u32() throws -> UInt32 {
            let value = try bytes(4)
            return value.reduce(0) { ($0 << 8) | UInt32($1) }
        }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    }
}
