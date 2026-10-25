import AppKit

// Native artwork for the Finder installer window. No external image or packaging dependency.
let size = NSSize(width: 720, height: 440)
let image = NSImage(size: size)
image.lockFocus()
NSGradient(starting: NSColor(calibratedWhite: 0.98, alpha: 1),
           ending: NSColor(calibratedRed: 0.88, green: 0.93, blue: 0.99, alpha: 1))!
    .draw(in: NSRect(origin: .zero, size: size), angle: -90)
func text(_ value: String, y: CGFloat, size: CGFloat, bold: Bool = false) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (value as NSString).draw(in: NSRect(x: 20, y: y, width: 680, height: 45), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 1),
        .paragraphStyle: paragraph
    ])
}
text("Codex Token Monitor", y: 355, size: 28, bold: true)
text("拖到「应用程序」即可安装", y: 307, size: 17)
text("Drag the app to Applications to install", y: 277, size: 13)
let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 320, y: 200))
arrow.line(to: NSPoint(x: 400, y: 200))
arrow.move(to: NSPoint(x: 386, y: 214))
arrow.line(to: NSPoint(x: 400, y: 200))
arrow.line(to: NSPoint(x: 386, y: 186))
NSColor(calibratedRed: 0.33, green: 0.49, blue: 0.71, alpha: 1).setStroke()
arrow.stroke()
text("安装后，请从「应用程序」启动，然后推出此磁盘。", y: 45, size: 12)
text("Open from Applications, then eject this disk.", y: 20, size: 11)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
