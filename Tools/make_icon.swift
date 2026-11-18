import AppKit

// Draws the 1024x1024 master icon. Run via Tools/make_icon.sh.

let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: size,
                                 pixelsHigh: size,
                                 bitsPerSample: 8,
                                 samplesPerPixel: 4,
                                 hasAlpha: true,
                                 isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0,
                                 bitsPerPixel: 0) else {
    fputs("couldn't create bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let full = NSRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
NSColor.clear.setFill()
full.fill()

let rect = full.insetBy(dx: 62, dy: 62)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)

let background = NSGradient(colors: [
    NSColor(srgbRed: 0.26, green: 0.58, blue: 0.99, alpha: 1.0),
    NSColor(srgbRed: 0.04, green: 0.26, blue: 0.74, alpha: 1.0)
])!
background.draw(in: squircle, angle: -90)

// Soft top highlight.
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
let highlight = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.22),
    NSColor.white.withAlphaComponent(0.0)
])!
highlight.draw(in: NSRect(x: 0, y: 600, width: 1024, height: 450), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Cloud.
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 246, y: 320, width: 532, height: 230), xRadius: 115, yRadius: 115).fill()
NSBezierPath(ovalIn: NSRect(x: 238, y: 382, width: 268, height: 268)).fill()
NSBezierPath(ovalIn: NSRect(x: 400, y: 448, width: 306, height: 306)).fill()
NSBezierPath(ovalIn: NSRect(x: 552, y: 392, width: 238, height: 238)).fill()

// Arrow cut out of the cloud.
let arrowColor = NSColor(srgbRed: 0.05, green: 0.29, blue: 0.76, alpha: 1.0)
arrowColor.setFill()
NSBezierPath(roundedRect: NSRect(x: 481, y: 386, width: 62, height: 196), xRadius: 17, yRadius: 17).fill()
let head = NSBezierPath()
head.move(to: NSPoint(x: 512, y: 706))
head.line(to: NSPoint(x: 412, y: 548))
head.line(to: NSPoint(x: 612, y: 548))
head.close()
head.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("couldn't encode png\n", stderr)
    exit(1)
}
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
do {
    try png.write(to: URL(fileURLWithPath: output))
    print("wrote \(output)")
} catch {
    fputs("write failed: \(error)\n", stderr)
    exit(1)
}
