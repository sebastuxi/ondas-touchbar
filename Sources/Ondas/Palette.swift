import AppKit
import CoreImage

/// Tres colores vivos sacados de la carátula; siempre con contraste ≥ 4.5:1 sobre negro.
struct Palette: Equatable {
    var primary: NSColor
    var secondary: NSColor
    var tertiary: NSColor

    /// Cuando todavía no hay carátula.
    static let fallback = Palette(primary: NSColor(hex: 0x6CB6FF), secondary: NSColor(hex: 0xB18CFF), tertiary: NSColor(hex: 0x7EF0FF))
    /// Carátulas en blanco y negro.
    static let neutral = Palette(primary: NSColor(white: 0.94, alpha: 1), secondary: NSColor(white: 0.80, alpha: 1), tertiary: NSColor(white: 0.68, alpha: 1))

    /// 0 = primary · 0.5 = secondary · 1 = tertiary.
    func color(at t: CGFloat) -> NSColor {
        let t = max(0, min(1, t))
        if t < 0.5 { return primary.mixed(with: secondary, fraction: t * 2) }
        return secondary.mixed(with: tertiary, fraction: (t - 0.5) * 2)
    }

    static func extract(from image: CGImage) -> Palette {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return .fallback }

        // Histograma de tonos ponderado por saturación y brillo.
        let bins = 24
        var weight = [CGFloat](repeating: 0, count: bins)
        var saturation = [CGFloat](repeating: 0, count: bins)
        var brightness = [CGFloat](repeating: 0, count: bins)
        var hueX = [CGFloat](repeating: 0, count: bins)
        var hueY = [CGFloat](repeating: 0, count: bins)
        var vividPixels = 0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255, g = CGFloat(pixels[i + 1]) / 255, b = CGFloat(pixels[i + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
            let s = maxC > 0 ? delta / maxC : 0
            // Umbral bajo: aunque la portada tenga poco color, se aprovecha (luego se aviva).
            guard s > 0.12, maxC > 0.15, delta > 0 else { continue }
            var h: CGFloat
            if maxC == r { h = (g - b) / delta } else if maxC == g { h = 2 + (b - r) / delta } else { h = 4 + (r - g) / delta }
            h /= 6
            if h < 0 { h += 1 }
            let w = s * maxC * maxC
            let bin = min(bins - 1, Int(h * CGFloat(bins)))
            weight[bin] += w
            saturation[bin] += s * w
            brightness[bin] += maxC * w
            hueX[bin] += cos(h * 2 * .pi) * w
            hueY[bin] += sin(h * 2 * .pi) * w
            vividPixels += 1
        }
        guard vividPixels >= 6 else { return .neutral }

        let ranked = (0..<bins).filter { weight[$0] > 0 }.sorted { weight[$0] > weight[$1] }
        guard let top = ranked.first else { return .neutral }
        var chosen = [top]
        for bin in ranked.dropFirst() where chosen.count < 3 {
            if weight[bin] < weight[top] * 0.08 { break }
            let farEnough = chosen.allSatisfy { other in
                let d = abs(bin - other)
                return min(d, bins - d) >= 3   // al menos 45° de diferencia
            }
            if farEnough { chosen.append(bin) }
        }

        var colors = chosen.map { bin -> NSColor in
            var hue = atan2(hueY[bin], hueX[bin]) / (2 * .pi)
            if hue < 0 { hue += 1 }
            return vivid(hue: hue, saturation: saturation[bin] / weight[bin], brightness: brightness[bin] / weight[bin])
        }
        // Carátulas de un solo color: se completa con tonos vecinos.
        while colors.count < 3 {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            colors[0].srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let shift: CGFloat = colors.count == 1 ? 0.08 : -0.08
            colors.append(vivid(hue: (h + shift + 1).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b))
        }
        return Palette(primary: colors[0], secondary: colors[1], tertiary: colors[2])
    }

    /// Versión luminosa del color con contraste ≥ 4.5:1 sobre negro (luminancia ≥ 0.18).
    private static func vivid(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> NSColor {
        var s = min(0.85, max(0.45, saturation))
        let b = max(0.9, brightness)
        var color = NSColor(colorSpace: .sRGB, hue: hue, saturation: s, brightness: b, alpha: 1)
        while color.luminance < 0.18 && s > 0.2 {
            s -= 0.05
            color = NSColor(colorSpace: .sRGB, hue: hue, saturation: s, brightness: b, alpha: 1)
        }
        return color
    }
}

enum ImageEffects {
    private static let context = CIContext()

    /// Carátula muy desenfocada y saturada para la luz de fondo.
    static func glow(from image: CGImage) -> CGImage? {
        let side: CGFloat = 64
        let input = CIImage(cgImage: image)
        guard input.extent.width > 0, input.extent.height > 0 else { return nil }
        let scaled = input.transformed(by: CGAffineTransform(scaleX: side / input.extent.width, y: side / input.extent.height))
        let blurred = scaled.clampedToExtent().applyingGaussianBlur(sigma: 8)
        let vivid = blurred.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.8])
        return context.createCGImage(vivid, from: CGRect(x: 0, y: 0, width: side, height: side))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    var srgb: NSColor { usingColorSpace(.sRGB) ?? self }

    func mixed(with other: NSColor, fraction: CGFloat) -> NSColor {
        let a = srgb, b = other.srgb
        let f = max(0, min(1, fraction))
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * f,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f,
                       alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * f)
    }

    /// Luminancia relativa (WCAG).
    var luminance: CGFloat {
        let c = srgb
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }
}
