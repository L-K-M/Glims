import AppKit
import ImageIO

/// Portable straight-alpha sRGB pixels for the system clipboard. The custom
/// origin is optional; other applications only need the standard PNG/TIFF.
struct ClipboardImage {
    let width: Int
    let height: Int
    let pixels: Data
    let origin: CGPoint

    private static let originType = NSPasteboard.PasteboardType("ch.lkmc.Glims.pixel-origin")
    private static let nativeType = NSPasteboard.PasteboardType("ch.lkmc.Glims.rgba8-v1")
    private static let maximumBytes = 512 * 1024 * 1024

    enum TransferError: LocalizedError {
        case invalidImage, tooLarge, clipboardUnavailable
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "The clipboard does not contain a readable image."
            case .tooLarge: return "This image is too large for the clipboard. Copy a smaller selection instead."
            case .clipboardUnavailable: return "The image could not be written to the clipboard."
            }
        }
    }

    static func byteCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else { throw TransferError.invalidImage }
        guard width <= 524_288, height <= 524_288 else { throw TransferError.tooLarge }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = count.multipliedReportingOverflow(by: 4)
        guard !overflow, !byteOverflow, bytes <= maximumBytes else { throw TransferError.tooLarge }
        return bytes
    }

    func pngData() throws -> Data {
        let expected = try Self.byteCount(width: width, height: height)
        guard pixels.count == expected,
              let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw TransferError.invalidImage
        }
        return data
    }

    static func decode(_ data: Data, origin: CGPoint = .zero) throws -> ClipboardImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw TransferError.invalidImage }
        let size = try byteCount(width: width, height: height)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw TransferError.invalidImage }
        var pixels = Data(count: size)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw TransferError.invalidImage
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // The facade uses straight alpha, while Core Graphics draws
            // premultiplied components. Recover color in partially clear pixels.
            let values = bytes.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: size, by: 4) {
                let alpha = Int(values[i + 3])
                guard alpha > 0, alpha < 255 else { continue }
                for c in 0..<3 { values[i + c] = UInt8(min(255, (Int(values[i + c]) * 255 + alpha / 2) / alpha)) }
            }
        }
        return ClipboardImage(width: width, height: height, pixels: pixels, origin: origin)
    }

    private struct NativePixels: Codable {
        let width: Int
        let height: Int
        let x: Double
        let y: Double
        let pixels: Data
    }

    struct Payload {
        let standard: Data?
        let native: Data?
        let origin: CGPoint

        func decoded() throws -> ClipboardImage {
            // Keep the exact straight-alpha bytes within Glims. Drawing a
            // PNG into a premultiplied CGContext otherwise loses low color
            // bits in nearly transparent pixels. Other apps use PNG/TIFF.
            if let native, native.count <= ClipboardImage.maximumBytes + 65_536,
               let wire = try? PropertyListDecoder().decode(NativePixels.self, from: native),
               let count = try? ClipboardImage.byteCount(width: wire.width, height: wire.height),
               count == wire.pixels.count, wire.x.isFinite, wire.y.isFinite,
               abs(wire.x) <= 524_288, abs(wire.y) <= 524_288 {
                return ClipboardImage(width: wire.width, height: wire.height, pixels: wire.pixels,
                                      origin: CGPoint(x: wire.x, y: wire.y))
            }
            guard let standard else { throw TransferError.invalidImage }
            return try ClipboardImage.decode(standard, origin: origin)
        }
    }

    struct Encoded {
        let native: Data
        let png: Data
        let tiff: Data?
        let origin: Data?

        @MainActor
        func write(to pasteboard: NSPasteboard) throws {
            let item = NSPasteboardItem()
            item.setData(native, forType: ClipboardImage.nativeType)
            item.setData(png, forType: .png)
            if let tiff { item.setData(tiff, forType: .tiff) }
            if let origin { item.setData(origin, forType: ClipboardImage.originType) }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else { throw TransferError.clipboardUnavailable }
        }
    }

    /// Encoding runs with the pixel work, before the short main-thread
    /// pasteboard transaction. Large copies must not stall AppKit.
    func encoded() throws -> Encoded {
        let png = try pngData()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let native = try encoder.encode(NativePixels(width: width, height: height,
                                                     x: Double(origin.x), y: Double(origin.y), pixels: pixels))
        return Encoded(native: native, png: png, tiff: NSBitmapImageRep(data: png)?.tiffRepresentation,
                       origin: try JSONSerialization.data(withJSONObject: ["x": origin.x, "y": origin.y]))
    }

    @MainActor
    func write(to pasteboard: NSPasteboard) throws { try encoded().write(to: pasteboard) }

    @MainActor
    static func readPayload(from pasteboard: NSPasteboard) throws -> Payload {
        let native = pasteboard.data(forType: nativeType)
        let standard = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        guard native != nil || standard != nil else {
            throw TransferError.invalidImage
        }
        var origin = CGPoint.zero
        if let metadata = pasteboard.data(forType: originType),
           let values = (try? JSONSerialization.jsonObject(with: metadata)) as? [String: Double],
           let x = values["x"], let y = values["y"], x.isFinite, y.isFinite,
           abs(x) <= 524_288, abs(y) <= 524_288 {
            origin = CGPoint(x: x, y: y)
        }
        return Payload(standard: standard, native: native, origin: origin)
    }

    @MainActor
    static func read(from pasteboard: NSPasteboard) throws -> ClipboardImage {
        let payload = try readPayload(from: pasteboard)
        return try payload.decoded()
    }
}
