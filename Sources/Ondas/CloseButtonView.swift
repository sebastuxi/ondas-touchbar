import AppKit
import QuartzCore

/// La X para recoger la barra: una tecla cuadrada en el sitio de Esc, pegada a la izquierda.
/// Al ocupar ese sitio, macOS no dibuja su propia X.
final class CloseButtonView: NSView {
    var onTap: (() -> Void)?

    /// Se ilumina igual que el resto de la barra.
    private let glow = CALayer()
    private let key = CALayer()
    private let icon = CALayer()
    private var activeTouch: (NSObjectProtocol & NSCopying)?

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.Size.closeWidth, height: Theme.Size.barHeight))
        let root = CALayer()
        root.contentsScale = Theme.scale
        layer = root
        wantsLayer = true
        allowedTouchTypes = [.direct]
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Theme.Size.closeWidth).isActive = true
        heightAnchor.constraint(equalToConstant: Theme.Size.barHeight).isActive = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Cerrar Ondas")

        glow.frame = CGRect(x: 0, y: 0, width: Theme.Size.closeWidth, height: Theme.Size.barHeight)
        glow.opacity = 0
        LayerKit.add(glow, to: root)

        let side = Theme.Size.closeSquare
        LayerKit.place(key, in: CGRect(x: 0, y: (Theme.Size.barHeight - side) / 2, width: side, height: side))
        key.cornerRadius = Theme.Radius.close
        key.backgroundColor = Theme.Colors.closeFill.cgColor
        LayerKit.add(key, to: root)

        let iconSide = Theme.Size.closeIcon
        icon.frame = CGRect(x: (side - iconSide) / 2, y: (side - iconSide) / 2, width: iconSide, height: iconSide)
        LayerKit.paint(icon, symbol: "xmark", pointSize: iconSide - 1, weight: .bold, color: Theme.Colors.closeIcon)
        LayerKit.add(icon, to: key)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Theme.Size.closeWidth, height: Theme.Size.barHeight)
    }

    func setPulse(color: CGColor, opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Se sale un poco a la derecha para tapar la junta con el resto de la barra.
        glow.frame = CGRect(x: 0, y: 0, width: bounds.width + Theme.Size.glowBleed, height: bounds.height)
        glow.backgroundColor = color
        glow.opacity = opacity
        CATransaction.commit()
    }

    override func touchesBegan(with event: NSEvent) {
        guard activeTouch == nil, let touch = event.touches(matching: .began, in: self).first else { return }
        activeTouch = touch.identity
        setPressed(true)
    }

    override func touchesMoved(with event: NSEvent) {
        guard let touch = trackedTouch(in: event, phase: .moved) else { return }
        setPressed(isInside(touch))
    }

    override func touchesEnded(with event: NSEvent) {
        guard let touch = trackedTouch(in: event, phase: .ended) else { return }
        setPressed(false)
        activeTouch = nil
        if isInside(touch) { onTap?() }
    }

    override func touchesCancelled(with event: NSEvent) {
        setPressed(false)
        activeTouch = nil
    }

    private func isInside(_ touch: NSTouch) -> Bool {
        let x = touch.location(in: self).x
        return x >= -Theme.Space.small && x <= bounds.width + Theme.Space.small
    }

    private func trackedTouch(in event: NSEvent, phase: NSTouch.Phase) -> NSTouch? {
        guard let active = activeTouch else { return nil }
        return event.touches(matching: phase, in: self).first { $0.identity.isEqual(active) }
    }

    private func setPressed(_ down: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Motion.press)
        key.transform = down ? CATransform3DMakeScale(0.86, 0.86, 1) : CATransform3DIdentity
        key.backgroundColor = (down ? NSColor(white: 1, alpha: 0.3) : Theme.Colors.closeFill).cgColor
        CATransaction.commit()
    }
}
