import AppKit

/// Renders the Dock/Finder icon: the `AppGlyph` look on Apple's 824 pt icon grid.
package enum AppIcon {
    package enum Failure: Error, CustomStringConvertible {
        case bitmap(Int)
        case encode(Int)

        package var description: String {
            switch self {
            case .bitmap(let pixels): "Could not create a \(pixels)-pixel icon bitmap."
            case .encode(let pixels): "Could not encode the \(pixels)-pixel icon as PNG."
            }
        }
    }

    package static func png(pixels: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw Failure.bitmap(pixels)
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        let scale = CGFloat(pixels) / 1024
        context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        // Work in a 1024 canvas with y pointing down, like `Sailboat.path`.
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: scale, y: -scale)

        // Shadow offsets ignore the CTM flip, so negative heights point down.
        let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let tile = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale,
                          color: NSColor(calibratedWhite: 0, alpha: 0.35).cgColor)
        context.addPath(tile)
        context.setFillColor(NSColor(calibratedRed: 0.07, green: 0.26, blue: 0.62, alpha: 1).cgColor)
        context.fillPath()
        context.restoreGState()

        let colors = [
            NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.95, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.07, green: 0.26, blue: 0.62, alpha: 1).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
            context.saveGState()
            context.addPath(tile)
            context.clip()
            context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tileRect.minY),
                                       end: CGPoint(x: 512, y: tileRect.maxY), options: [])
            context.restoreGState()
        }

        if pixels >= 64 {
            context.addPath(tile)
            context.setLineWidth(4)
            context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.18).cgColor)
            context.strokePath()
        }

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 16 * scale,
                          color: NSColor(calibratedWhite: 0, alpha: 0.30).cgColor)
        context.addPath(Sailboat.path(in: tileRect.insetBy(dx: 824 * 0.2, dy: 824 * 0.2)))
        context.setFillColor(NSColor.white.cgColor)
        context.fillPath()
        context.restoreGState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.encode(pixels)
        }
        return png
    }

    /// Writes the `.iconset` folder that `iconutil` turns into `AppIcon.icns`.
    package static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            try png(pixels: points).write(to: directory.appendingPathComponent("icon_\(points)x\(points).png"))
            try png(pixels: points * 2).write(to: directory.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
        }
    }
}
