import AppKit
import TouchBarPrivate

extension NSTouchBarItem.Identifier {
    static let ondasBar = NSTouchBarItem.Identifier("com.ondas.touchbar.bar")
    static let ondasTray = NSTouchBarItem.Identifier("com.ondas.touchbar.tray")
    static let ondasClose = NSTouchBarItem.Identifier("com.ondas.touchbar.close")
}

/// Muestra la barra encima de cualquier app y deja un botón en la Control Strip para abrirla.
final class TouchBarController: NSObject, NSTouchBarDelegate {
    let barView = NowPlayingBarView(frame: .zero)

    /// Abrir la barra sola cuando Spotify pasa al frente (y recogerla al salir).
    var autoShowWithSpotify = true
    private(set) var isPresented = false
    /// Ondas debería verse (no la cerraste con la X). macOS la quita al dormir la Mac: al despertar vuelve.
    private(set) var wantsVisible = false

    private let touchBar = NSTouchBar()
    private let closeView = CloseButtonView(frame: .zero)
    private let trayItem = NSCustomTouchBarItem(identifier: .ondasTray)
    private let trayButton = NSButton(title: "", target: nil, action: nil)
    private var presentedAutomatically = false

    func install() {
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [.ondasBar]
        // Nuestra X ocupa el sitio de Esc: así macOS no dibuja la suya y queda pegada a la izquierda.
        touchBar.escapeKeyReplacementItemIdentifier = .ondasClose
        // La X: con música pasa a la pantalla de reposo; en reposo cierra Ondas.
        closeView.onTap = { [weak self] in
            guard let self else { return }
            if !self.barView.handleClose() { self.minimize() }
        }
        barView.onVisibilityChange = { [weak self] visible in
            self?.isPresented = visible
            if !visible { self?.presentedAutomatically = false }
        }

        trayButton.image = Self.trayImage(artwork: nil)
        trayButton.imagePosition = .imageOnly
        trayButton.target = self
        trayButton.action = #selector(trayTapped)
        trayButton.setAccessibilityLabel("Ondas")
        trayItem.view = trayButton

        OBAddSystemTrayItem(trayItem)
        OBSetControlStripPresence(.ondasTray, true)
    }

    func uninstall() {
        OBDismissSystemModal(touchBar)
        OBSetControlStripPresence(.ondasTray, false)
        OBRemoveSystemTrayItem(trayItem)
        isPresented = false
    }

    func present(automatic: Bool) {
        presentedAutomatically = automatic
        wantsVisible = true
        Log.app.notice("Mostrando la barra")
        // 1 = toda la Touch Bar: Ondas trae sus propias teclas de brillo y volumen.
        // Sin atarla al botón de la Control Strip: así ese botón no desaparece y siempre sirve para volver.
        OBPresentSystemModal(touchBar, 1, nil)
        barView.resetMode()
        isPresented = true
    }

    /// La X: quita la barra y deja visible el botón de Ondas en la Control Strip para volver a abrirla.
    func minimize() {
        OBDismissSystemModal(touchBar)
        OBSetControlStripPresence(.ondasTray, true)
        isPresented = false
        presentedAutomatically = false
        wantsVisible = false
    }

    /// macOS quita la barra al dormir la Mac, al bloquearla o al cambiar de usuario, sin avisar.
    /// Al volver: el botón de Ondas siempre queda en la Control Strip, y la barra vuelve si debía verse.
    func restoreAfterWake() {
        OBSetControlStripPresence(.ondasTray, true)
        guard wantsVisible else { return }
        Log.app.notice("La barra vuelve tras despertar")
        OBPresentSystemModal(touchBar, 1, nil)
        isPresented = true
    }

    func frontmostAppChanged(to bundleID: String?) {
        guard autoShowWithSpotify else { return }
        if bundleID == SpotifyClient.bundleID {
            if !isPresented { present(automatic: true) }
        } else if isPresented && presentedAutomatically {
            minimize()
        }
    }

    /// La X se ilumina con el mismo color y ritmo que el resto de la barra.
    func syncPulse() {
        closeView.setPulse(color: barView.pulseColor, opacity: barView.pulseOpacity)
    }

    func setTrayArtwork(_ image: CGImage?) {
        trayButton.image = Self.trayImage(artwork: image)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case .ondasClose: item.view = closeView
        case .ondasBar: item.view = barView
        default: return nil
        }
        return item
    }

    @objc private func trayTapped() {
        present(automatic: false)
    }

    private static func trayImage(artwork: CGImage?) -> NSImage {
        guard let artwork else {
            let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Ondas") ?? NSImage()
            return symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)) ?? symbol
        }
        let side = Theme.Size.trayArtwork
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            NSGraphicsContext.current?.cgContext.draw(artwork, in: rect)
            return true
        }
    }
}
