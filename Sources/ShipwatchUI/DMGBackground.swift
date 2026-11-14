import AppKit

/// Draws the installer window background: a title and an arrow from the app to Applications.
/// Geometry must match `scripts/dmg-layout.py` (window size and icon centers, y measured from the top).
package enum DMGBackground {
    package static let width: CGFloat = 720
    package static let height: CGFloat = 520
    static let iconRowY: CGFloat = 210
    static let appX: CGFloat = 180
    static let applicationsX: CGFloat = 540
    static let iconSize: CGFloat = 128

    package enum Failure: Error, CustomStringConvertible {
        case bitmap(Int)
        case encode(Int)

        package var description: String {
            switch self {
            case .bitmap(let scale): "Could not create the @\(scale)x installer background bitmap."
            case .encode(let scale): "Could not encode the @\(scale)x installer background as PNG."
            }
        }
    }

    package static func png(scale: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw Failure.bitmap(scale)
        }
        // Points, not pixels, so the @2x image carries 144 dpi and Finder shows both at the same size.
        bitmap.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        let colors = [
            NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.89, green: 0.93, blue: 0.98, alpha: 1).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
        }

        drawCentered("Install Shipwatch", top: 44, font: .systemFont(ofSize: 24, weight: .bold),
                     color: NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.27, alpha: 1))
        drawCentered("Drag Shipwatch onto the Applications folder", top: 80, font: .systemFont(ofSize: 15),
                     color: NSColor(calibratedRed: 0.25, green: 0.32, blue: 0.42, alpha: 1))
        drawArrow(in: context)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.encode(scale)
        }
        return png
    }

    /// Writes `background.png` and `background@2x.png`, which dmgbuild combines into one HiDPI TIFF.
    package static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png(scale: 1).write(to: directory.appendingPathComponent("background.png"))
        try png(scale: 2).write(to: directory.appendingPathComponent("background@2x.png"))
    }

    private static func drawCentered(_ text: String, top: CGFloat, font: NSFont, color: NSColor) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: NSPoint(x: (width - size.width) / 2, y: height - top - size.height))
    }

    private static func drawArrow(in context: CGContext) {
        let gap: CGFloat = 26
        let startX = appX + iconSize / 2 + gap
        let tipX = applicationsX - iconSize / 2 - gap
        let y = height - iconRowY
        let head: CGFloat = 22

        context.saveGState()
        context.setStrokeColor(NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.95, alpha: 1).cgColor)
        context.setLineWidth(8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: startX, y: y))
        context.addLine(to: CGPoint(x: tipX - 3, y: y))
        context.strokePath()
        context.move(to: CGPoint(x: tipX - head, y: y + head))
        context.addLine(to: CGPoint(x: tipX, y: y))
        context.addLine(to: CGPoint(x: tipX - head, y: y - head))
        context.strokePath()
        context.restoreGState()
    }
}
