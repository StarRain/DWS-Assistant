import AppKit

/// D-shaped conversation + AI sparkle. The vector source is in Assets/Brand;
/// the same native paths are drawn for the app icon, sidebar and menu bar.
enum AssistantBrand {
    static let appIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 512, height: 512))
        image.addRepresentation(bitmap(pixels: 1024))
        return image
    }()

    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = mark()
            let bounds = path.bounds
            let scale = min(16 / bounds.width, 16 / bounds.height)
            let transform = AffineTransform(m11: scale, m12: 0, m21: 0, m22: -scale,
                                            tX: rect.midX - bounds.midX * scale, tY: rect.midY + bounds.midY * scale)
            path.transform(using: transform)
            NSColor.black.setFill(); path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static func mark() -> NSBezierPath {
        let path = NSBezierPath(); path.windingRule = .evenOdd
        path.move(to: NSPoint(x: 110, y: 94)); path.line(to: NSPoint(x: 244, y: 94))
        path.curve(to: NSPoint(x: 402, y: 231), controlPoint1: NSPoint(x: 334, y: 94), controlPoint2: NSPoint(x: 402, y: 152))
        path.curve(to: NSPoint(x: 244, y: 368), controlPoint1: NSPoint(x: 402, y: 310), controlPoint2: NSPoint(x: 334, y: 368))
        path.line(to: NSPoint(x: 110, y: 368)); path.close()
        path.move(to: NSPoint(x: 166, y: 150)); path.line(to: NSPoint(x: 166, y: 286)); path.line(to: NSPoint(x: 146, y: 332)); path.line(to: NSPoint(x: 200, y: 312)); path.line(to: NSPoint(x: 244, y: 312))
        path.curve(to: NSPoint(x: 346, y: 231), controlPoint1: NSPoint(x: 302, y: 312), controlPoint2: NSPoint(x: 346, y: 278))
        path.curve(to: NSPoint(x: 244, y: 150), controlPoint1: NSPoint(x: 346, y: 185), controlPoint2: NSPoint(x: 302, y: 150)); path.close()
        path.move(to: NSPoint(x: 248, y: 174))
        path.curve(to: NSPoint(x: 299, y: 225), controlPoint1: NSPoint(x: 255, y: 208), controlPoint2: NSPoint(x: 265, y: 218))
        path.curve(to: NSPoint(x: 248, y: 276), controlPoint1: NSPoint(x: 265, y: 232), controlPoint2: NSPoint(x: 255, y: 242))
        path.curve(to: NSPoint(x: 197, y: 225), controlPoint1: NSPoint(x: 241, y: 242), controlPoint2: NSPoint(x: 231, y: 232))
        path.curve(to: NSPoint(x: 248, y: 174), controlPoint1: NSPoint(x: 231, y: 218), controlPoint2: NSPoint(x: 241, y: 208)); path.close()
        path.transform(using: AffineTransform(translationByX: 0, byY: 25))
        return path
    }

    static func bitmap(pixels: Int) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let size = CGFloat(pixels), scale = size / 512
        let tile = NSBezierPath(roundedRect: NSRect(x: 26 * scale, y: 26 * scale, width: 460 * scale, height: 460 * scale), xRadius: 108 * scale, yRadius: 108 * scale)
        NSGradient(colors: [NSColor(srgbRed: 0.475, green: 0.259, blue: 0.957, alpha: 1),
                            NSColor(srgbRed: 0.212, green: 0.357, blue: 0.949, alpha: 1),
                            NSColor(srgbRed: 0.141, green: 0.710, blue: 0.929, alpha: 1)])!.draw(in: tile, angle: -45)
        let path = mark()
        path.transform(using: AffineTransform(m11: scale, m12: 0, m21: 0, m22: -scale, tX: 0, tY: size))
        NSColor.white.setFill(); path.fill()
        return bitmap
    }
}
