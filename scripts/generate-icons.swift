// Regenerates the app icon from the committed master.
//
//   swift scripts/generate-icons.swift
//
// Reads media-sources/icon.png (the image as generated; never edited by hand)
// and writes Resources/AppIcon.png (1024 x 1024) and Resources/AppIcon.icns.
// Both outputs are committed; rerun this after replacing the master.
//
// The image generator leaves stray specks of opaque pixels around the tile
// where it removed the background. Only the tile survives: the opaque region
// connected to the image centre, grown by a few pixels so the tile's own
// anti-aliased edge stays intact. Everything else becomes fully transparent.
// The tile's pixels are not changed.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let master = root.appendingPathComponent("media-sources/icon.png")
let rasterOut = root.appendingPathComponent("Resources/AppIcon.png")
let icnsOut = root.appendingPathComponent("Resources/AppIcon.icns")

/// Pixels at or above this alpha count as part of a shape when tracing the tile.
let opaqueThreshold: UInt8 = 16
/// How far outside the traced tile anti-aliased edge pixels are kept.
let edgeMargin = 3

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-icons: \(message)\n".utf8))
    exit(1)
}

guard let source = CGImageSourceCreateWithURL(master as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(master.path)") }
let width = image.width, height = image.height
guard width == height else { fail("master must be square, got \(width) x \(height)") }

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
var pixels = [UInt8](repeating: 0, count: width * height * 4)
pixels.withUnsafeMutableBytes { buffer in
    let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}
func alpha(_ index: Int) -> UInt8 { pixels[index * 4 + 3] }

// Trace the tile: 4-connected opaque pixels reachable from the centre.
var inTile = [Bool](repeating: false, count: width * height)
let centre = (height / 2) * width + width / 2
guard alpha(centre) >= opaqueThreshold else { fail("the image centre is transparent; is this an icon tile?") }
var stack = [centre]
inTile[centre] = true
while let index = stack.popLast() {
    let x = index % width, y = index / width
    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
    where nx >= 0 && ny >= 0 && nx < width && ny < height {
        let next = ny * width + nx
        if !inTile[next] && alpha(next) >= opaqueThreshold {
            inTile[next] = true
            stack.append(next)
        }
    }
}

// Keep the tile plus a small margin; clear everything else.
var keep = inTile
for _ in 0..<edgeMargin {
    var grown = keep
    for y in 0..<height {
        for x in 0..<width where keep[y * width + x] {
            if x > 0 { grown[y * width + x - 1] = true }
            if x < width - 1 { grown[y * width + x + 1] = true }
            if y > 0 { grown[(y - 1) * width + x] = true }
            if y < height - 1 { grown[(y + 1) * width + x] = true }
        }
    }
    keep = grown
}
var cleared = 0
for index in 0..<(width * height) where !keep[index] && alpha(index) > 0 {
    pixels.replaceSubrange(index * 4..<(index * 4 + 4), with: [0, 0, 0, 0])
    cleared += 1
}

func makeImage(_ data: inout [UInt8], _ side: Int) -> CGImage {
    data.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                  bytesPerRow: side * 4, space: colorSpace, bitmapInfo: bitmapInfo)!.makeImage()!
    }
}
let cleaned = makeImage(&pixels, width)

func scaled(_ image: CGImage, to side: Int) -> CGImage {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: bitmapInfo)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

writePNG(scaled(cleaned, to: 1024), to: rasterOut)

// iconutil wants an .iconset directory with these exact names.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Glims-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(scaled(cleaned, to: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(scaled(cleaned, to: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", icnsOut.path, iconset.path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }

print("Cleared \(cleared) stray pixels outside the tile.")
print("Wrote \(rasterOut.path)")
print("Wrote \(icnsOut.path)")
