import AppKit
import Foundation

// Draw with native shapes; no external images or build-time downloads.
let destination = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 55, y: 55, width: 914, height: 914), xRadius: 208, yRadius: 208)
NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.45, blue: 0.97, alpha: 1),
           ending: NSColor(srgbRed: 0.25, green: 0.24, blue: 0.76, alpha: 1))!.draw(in: background, angle: -45)
let keyboard = NSBezierPath(roundedRect: NSRect(x: 170, y: 310, width: 684, height: 404), xRadius: 56, yRadius: 56)
NSColor.white.withAlphaComponent(0.16).setFill(); keyboard.fill()
NSColor.white.setStroke(); keyboard.lineWidth = 15; keyboard.stroke()
NSColor.white.setFill()
for row in 0..<3 {
    for column in 0..<8 {
        NSBezierPath(roundedRect: NSRect(x: 218 + column * 77, y: 540 - row * 80, width: 48, height: 40),
                     xRadius: 9, yRadius: 9).fill()
    }
}
NSBezierPath(roundedRect: NSRect(x: 348, y: 354, width: 328, height: 37), xRadius: 10, yRadius: 10).fill()
image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
let fullImage = NSImage(cgImage: representation.cgImage!, size: size)
var chunks = Data()
func uint32(_ value: Int) -> Data {
    var bigEndian = UInt32(value).bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
for (type, pixels) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                       ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    fullImage.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    chunks.append(type.data(using: .ascii)!)
    chunks.append(uint32(png.count + 8))
    chunks.append(png)
}
var icns = "icns".data(using: .ascii)!
icns.append(uint32(chunks.count + 8))
icns.append(chunks)
try icns.write(to: URL(fileURLWithPath: destination))
