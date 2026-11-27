import Foundation
import QuartzCore
import TouchBarPrivate

/// La luz del teclado se queda a media intensidad para que veas las teclas, y sube más o menos
/// según cuánto escribas (suave, sin parpadeos). Si te alejas un rato, devuelve el control a macOS.
final class KeyboardLight {
    let isAvailable = OBKeyboardLightAvailable()
    /// Luz cuando no escribes (0…1). Se elige en el menú: baja, media o alta.
    var restLevel: Float = Theme.Keyboard.restLevel

    private var savedLevel: Float?
    private var savedAutoBrightness = false
    private var energy: Float = 0
    private var shown: Float = 0
    private var lastKeyTime: CFTimeInterval = 0
    private var lastSent: Float = -1
    private var lastSentTime: CFTimeInterval = 0
    /// El nivel de reposo ya quedó guardado como brillo del sistema.
    private var restCommitted = false
    private let defaults = UserDefaults.standard

    /// El brillo original también se guarda en disco: si Ondas se cierra de golpe, se recupera al abrir.
    private enum Key {
        static let level = "keyboardSavedLevel"
        static let auto = "keyboardSavedAuto"
    }

    /// Si Ondas se cerró mientras controlaba la luz, la deja como estaba antes.
    func recoverIfNeeded() {
        guard isAvailable, defaults.object(forKey: Key.level) != nil else { return }
        let level = defaults.float(forKey: Key.level)
        OBKeyboardLightSet(level, true)
        if defaults.bool(forKey: Key.auto) { OBKeyboardSetAutoBrightness(true) }
        OBKeyboardSuspendIdleDimming(false)
        defaults.removeObject(forKey: Key.level)
        defaults.removeObject(forKey: Key.auto)
        Log.app.notice("Teclado: recuperado a \(level, privacy: .public)")
    }

    /// Enciende la luz a media intensidad y la mantiene así (al abrir Ondas y con la primera tecla).
    func activate(now: CFTimeInterval) {
        guard isAvailable, savedLevel == nil else { return }
        let level = OBKeyboardLightGet()
        let auto = OBKeyboardAutoBrightnessEnabled()
        savedLevel = level
        savedAutoBrightness = auto
        shown = level
        lastKeyTime = now
        defaults.set(level, forKey: Key.level)
        defaults.set(auto, forKey: Key.auto)
        if auto { OBKeyboardSetAutoBrightness(false) }   // que el sensor de luz no la apague
        OBKeyboardSuspendIdleDimming(true)                // ni la inactividad
        // Se guarda como brillo del sistema: si macOS "vuelve a lo guardado", vuelve a la media luz.
        OBKeyboardLightSet(restLevel, true)
        shown = restLevel
        lastSent = restLevel
        lastSentTime = now
        restCommitted = true
        Log.app.notice("Teclado: a media luz (antes \(level, privacy: .public), automático \(auto, privacy: .public))")
    }

    /// Cada tecla suma un poco de luz: escribir rápido la sube más, escribir poco apenas la mueve.
    func keyPressed(now: CFTimeInterval) {
        guard isAvailable else { return }
        activate(now: now)
        energy = min(1, energy + Theme.Keyboard.typingStep)
        lastKeyTime = now
    }

    /// Se llama en cada fotograma: la luz sigue a lo que escribes con suavidad (nunca de golpe).
    func update(now: CFTimeInterval, dt: Double) {
        guard isAvailable, savedLevel != nil else { return }
        // Te fuiste un buen rato: macOS vuelve a mandar (y ahorra batería). La próxima tecla la enciende.
        if now - lastKeyTime > Theme.Keyboard.awayAfter {
            restore()
            return
        }
        energy = max(0, energy - Float(dt) * Theme.Keyboard.typingDecay)
        let eased = 1 - (1 - energy) * (1 - energy)   // una tecla ya se nota; escribir seguido la sube más
        let target = restLevel + (1 - restLevel) * eased
        shown += (target - shown) * Float(min(1, dt * Theme.Keyboard.smoothing))

        // Sin escribir: la media luz queda guardada como brillo del sistema. (Si macOS la apaga por
        // inactividad, eso se cambia en Ajustes → Teclado; aquí no se fuerza para no encenderla de la nada.)
        if energy == 0, abs(shown - restLevel) < 0.005 {
            if !restCommitted {
                OBKeyboardLightSet(restLevel, true)
                restCommitted = true
                lastSent = restLevel
                lastSentTime = now
            }
            return
        }
        restCommitted = false
        if now - lastSentTime >= 1 / Theme.Keyboard.refreshRate, abs(shown - lastSent) >= 0.01 {
            OBKeyboardLightSet(shown, false)
            lastSent = shown
            lastSentTime = now
        }
    }

    /// Vuelve al brillo y a los ajustes automáticos que tenías.
    func restore() {
        guard let savedLevel else { return }
        OBKeyboardLightSet(savedLevel, true)
        if savedAutoBrightness { OBKeyboardSetAutoBrightness(true) }
        OBKeyboardSuspendIdleDimming(false)
        defaults.removeObject(forKey: Key.level)
        defaults.removeObject(forKey: Key.auto)
        Log.app.notice("Teclado: vuelve a \(savedLevel, privacy: .public)")
        self.savedLevel = nil
        energy = 0
        lastSent = -1
        restCommitted = false
    }
}
