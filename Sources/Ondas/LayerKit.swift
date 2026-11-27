import AppKit
import QuartzCore

/// Utilidades para dibujar con capas a la escala de la Touch Bar.
enum LayerKit {
    static func add(_ child: CALayer, to parent: CALayer) {
        child.contentsScale = Theme.scale
        parent.addSublayer(child)
    }

    /// Coloca una capa sin tocar su `transform` (las que laten o se encogen al tocarlas).
    static func place(_ layer: CALayer, in rect: CGRect) {
        layer.bounds = CGRect(origin: .zero, size: rect.size)
        layer.position = CGPoint(x: rect.midX, y: rect.midY)
        layer.mask?.frame = layer.bounds
    }

    static func style(_ text: CATextLayer, font: NSFont, color: NSColor) {
        text.font = font
        text.fontSize = font.pointSize
        text.foregroundColor = color.cgColor
        text.isWrapped = false
        text.truncationMode = .none
        text.contentsScale = Theme.scale
    }

    /// Pinta un símbolo SF del color indicado usando la capa como máscara.
    static func paint(_ target: CALayer, symbol: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) {
        target.backgroundColor = color.cgColor
        target.mask = mask(image: symbolImage(symbol, pointSize: pointSize, weight: weight), size: target.bounds.size)
    }

    static func mask(image: CGImage?, size: CGSize) -> CALayer {
        let mask = CALayer()
        mask.frame = CGRect(origin: .zero, size: size)
        mask.contents = image
        mask.contentsGravity = .resizeAspect
        mask.contentsScale = Theme.scale
        return mask
    }

    static func symbolImage(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> CGImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let symbol = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) else { return nil }
        let size = symbol.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(ceil(size.width * Theme.scale)),
                                         pixelsHigh: Int(ceil(size.height * Theme.scale)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        symbol.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Marco de una línea de texto cuya línea base queda a `baseline` pt del borde de arriba.
    static func textFrame(font: NSFont, baseline: CGFloat, x: CGFloat, width: CGFloat) -> CGRect {
        let height = ceil(font.ascender - font.descender) + 1
        let top = baseline - font.ascender
        return CGRect(x: x, y: Theme.Size.barHeight - top - height, width: width, height: height)
    }
}
