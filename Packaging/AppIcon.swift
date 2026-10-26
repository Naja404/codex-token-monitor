import AppKit

// Keep the source artwork unchanged. Compose the shipped icon on the macOS
// 1024-point grid: an opaque 824-point rounded body with transparent margins.
// Stray alpha outside the original tile makes IconServices treat it as an
// irregular glyph and shrink it onto a separate gray enclosure.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: AppIcon <source.png> <output.png>\n", stderr)
    exit(1)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destinationURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: sourceURL), source.size.width == source.size.height else {
    fputs("App icon source must be a readable square image.\n", stderr)
    exit(1)
}

let canvasSize = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to create app icon canvas.\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let outline = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.height * 0.225)
outline.addClip()

// Fill transparent pixels inside the mask so IconServices can recognize a
// single opaque tile. Crop only the source's existing outer gutter/glow.
NSColor(srgbRed: 0.025, green: 0.045, blue: 0.10, alpha: 1).setFill()
outline.fill()
let crop = NSRect(
    x: source.size.width * 0.035,
    y: source.size.height * 0.035,
    width: source.size.width * 0.93,
    height: source.size.height * 0.93
)
source.draw(in: body, from: crop, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode app icon.\n", stderr)
    exit(1)
}
try png.write(to: destinationURL)
