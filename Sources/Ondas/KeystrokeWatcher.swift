import AppKit
import CoreGraphics

/// Avisa de cada tecla que pulsas y dónde cae sobre la Touch Bar (0 = izquierda, 1 = derecha).
/// Solo usa el código físico de la tecla para saber su posición: no lee lo que escribes,
/// no lo guarda y no lo envía. Necesita el permiso «Monitorización de entrada».
final class KeystrokeWatcher {
    var onKey: ((CGFloat) -> Void)?
    /// Ya hay permiso y está escuchando.
    var onReady: (() -> Void)?
    private(set) var isRunning = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?

    func start() {
        guard !isRunning else { return }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        guard !createTap() else { return }
        // Sin permiso todavía: se reintenta hasta que lo des en Ajustes.
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
            if self?.createTap() == true { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isRunning = false
    }

    private func createTap() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: keystrokeCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = runLoopSource
        isRunning = true
        retryTimer?.invalidate()
        retryTimer = nil
        Log.app.notice("Ondas al escribir: listo (solo la posición de cada tecla)")
        onReady?()
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .keyDown:
            // Mantener una tecla pulsada no manda ondas en cadena.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            onKey?(KeyboardMap.touchBarPosition(of: code))
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }
}

private func keystrokeCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<KeystrokeWatcher>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}

/// Dónde está cada tecla del MacBook, medido en "teclas" desde el borde izquierdo (el teclado mide 14.5).
/// Los códigos son físicos: valen igual con distribución española o inglesa.
enum KeyboardMap {
    private static let keyboardWidth: CGFloat = 14.5
    /// La Touch Bar cubre más o menos desde la tecla 1 hasta la de borrar.
    private static let touchBarStart: CGFloat = 1
    private static let touchBarSpan: CGFloat = 12.5

    private static let centers: [Int: CGFloat] = [
        // º 1 2 3 4 5 6 7 8 9 0 ' ¡ ⌫
        50: 0.5, 18: 1.5, 19: 2.5, 20: 3.5, 21: 4.5, 23: 5.5, 22: 6.5, 26: 7.5, 28: 8.5, 25: 9.5,
        29: 10.5, 27: 11.5, 24: 12.5, 51: 13.75,
        // ⇥ Q W E R T Y U I O P ` +
        48: 0.75, 12: 2.0, 13: 3.0, 14: 4.0, 15: 5.0, 17: 6.0, 16: 7.0, 32: 8.0, 34: 9.0, 31: 10.0,
        35: 11.0, 33: 12.0, 30: 13.0, 42: 14.0,
        // ⇪ A S D F G H J K L Ñ ´ ↩
        57: 0.875, 0: 2.25, 1: 3.25, 2: 4.25, 3: 5.25, 5: 6.25, 4: 7.25, 38: 8.25, 40: 9.25, 37: 10.25,
        41: 11.25, 39: 12.25, 36: 13.625,
        // ⇧ < Z X C V B N M , . - ⇧
        56: 0.6, 10: 1.75, 6: 2.75, 7: 3.75, 8: 4.75, 9: 5.75, 11: 6.75, 45: 7.75, 46: 8.75, 43: 9.75,
        47: 10.75, 44: 11.75, 60: 13.375,
        // fn ⌃ ⌥ ⌘ espacio ⌘ ⌥ ← ↑↓ →
        63: 0.5, 59: 1.5, 58: 2.5, 55: 3.75, 49: 7.25, 54: 10.25, 61: 11.5, 123: 12.5, 126: 13.5, 125: 13.5, 124: 14.0,
        // esc
        53: 0.4
    ]

    /// 0 = borde izquierdo de la Touch Bar · 1 = borde derecho.
    static func touchBarPosition(of keyCode: Int) -> CGFloat {
        let center = centers[keyCode] ?? keyboardWidth / 2
        return max(0, min(1, (center - touchBarStart) / touchBarSpan))
    }
}
