// Deterministic LidCode artwork. Native canvas includes optical macOS margins;
// web canvas is full bleed so the platform can apply its own mask.
import AppKit

func color(_ hex: UInt32) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1).cgColor
}
func render(native: Bool, output: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let c = NSGraphicsContext.current!.cgContext
    let inset: CGFloat = native ? 100 : 0
    let side = 1024 - inset * 2
    let tile = CGRect(x: inset, y: inset, width: side, height: side)
    let plate = CGPath(roundedRect: tile, cornerWidth: native ? 185 : 0,
                       cornerHeight: native ? 185 : 0, transform: nil)
    if native {
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -8), blur: 18,
                    color: NSColor.black.withAlphaComponent(0.20).cgColor)
        c.addPath(plate); c.setFillColor(color(0x4A7DC9)); c.fillPath()
        c.restoreGState()
    }
    c.saveGState(); c.addPath(plate); c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0x6A98DA), color(0x4A7DC9), color(0x335F9F)] as CFArray,
        locations: [0, 0.5, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 220, y: 1024),
                         end: CGPoint(x: 780, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
    if native {
        c.addPath(plate); c.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        c.setLineWidth(2); c.strokePath()
    }
    // Rear view of a MacBook lid: a broad aluminium panel and a slim hinge.
    // Custom geometry keeps the silhouette clear at small Dock sizes.
    c.saveGState()
    c.translateBy(x: inset, y: inset); c.scaleBy(x: side / 824, y: side / 824)
    let lid = CGMutablePath()
    lid.move(to: CGPoint(x: 190, y: 616))
    lid.addLine(to: CGPoint(x: 634, y: 616))
    lid.addQuadCurve(to: CGPoint(x: 662, y: 589), control: CGPoint(x: 661, y: 616))
    lid.addLine(to: CGPoint(x: 685, y: 263))
    lid.addQuadCurve(to: CGPoint(x: 660, y: 237), control: CGPoint(x: 687, y: 237))
    lid.addLine(to: CGPoint(x: 164, y: 237))
    lid.addQuadCurve(to: CGPoint(x: 139, y: 263), control: CGPoint(x: 137, y: 237))
    lid.addLine(to: CGPoint(x: 162, y: 589))
    lid.addQuadCurve(to: CGPoint(x: 190, y: 616), control: CGPoint(x: 163, y: 616))
    lid.closeSubpath()
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 20,
                color: NSColor(calibratedWhite: 0, alpha: 0.28).cgColor)
    c.addPath(lid); c.setFillColor(color(0xDCE4ED)); c.fillPath()
    c.restoreGState()
    c.saveGState(); c.addPath(lid); c.clip()
    let aluminium = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0xFAFCFF), color(0xDAE3EE), color(0xB8C8DB)] as CFArray,
        locations: [0, 0.55, 1])!
    c.drawLinearGradient(aluminium, start: CGPoint(x: 240, y: 616),
                         end: CGPoint(x: 590, y: 237),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
    c.addPath(lid); c.setLineWidth(3)
    c.setStrokeColor(NSColor.white.withAlphaComponent(0.75).cgColor); c.strokePath()

    // The base lip makes this read as a laptop lid rather than a display.
    let hinge = CGMutablePath()
    hinge.move(to: CGPoint(x: 124, y: 241))
    hinge.addLine(to: CGPoint(x: 700, y: 241))
    hinge.addQuadCurve(to: CGPoint(x: 668, y: 208), control: CGPoint(x: 700, y: 208))
    hinge.addLine(to: CGPoint(x: 156, y: 208))
    hinge.addQuadCurve(to: CGPoint(x: 124, y: 241), control: CGPoint(x: 124, y: 208))
    hinge.closeSubpath()
    c.addPath(hinge); c.setFillColor(color(0xE6EDF5)); c.fillPath()
    c.move(to: CGPoint(x: 149, y: 240)); c.addLine(to: CGPoint(x: 675, y: 240))
    c.setStrokeColor(color(0x8EA4BF)); c.setLineWidth(3); c.strokePath()
    let notch = CGPath(roundedRect: CGRect(x: 367, y: 228, width: 90, height: 13),
                       cornerWidth: 6, cornerHeight: 6, transform: nil)
    c.addPath(notch); c.setFillColor(color(0xA4B6CB)); c.fillPath()
    c.restoreGState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
}
try render(native: true, output: "Asset/app-icon.png")
try render(native: false, output: ".build/icon/web-master.png")
