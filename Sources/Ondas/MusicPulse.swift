import Foundation

/// El pulso de la canción (0…1) para la Touch Bar: sigue lo fuerte o suave que suena y
/// destella con los golpes, como mucho 3 veces por segundo para no cansar la vista.
final class MusicPulse {
    private(set) var value: CGFloat = 0
    private var flash: CGFloat = 0
    private var sinceFlash: Double = 1

    /// `audio` es nil cuando no llega sonido real: entonces no se inventa ritmo, el brillo queda quieto.
    func update(audio: AudioSnapshot?, playing: Bool, calm: Bool, dt: Double) {
        sinceFlash += dt
        var target: CGFloat = 0
        if playing, let audio {
            let onset = CGFloat(audio.onset)
            if onset > flash + 0.2, sinceFlash >= Theme.Motion.minFlashInterval {
                flash = onset
                sinceFlash = 0
            } else {
                flash = max(0, flash - CGFloat(dt) * 3)   // el destello se apaga en ~0.3 s
            }
            // Base: lo fuerte que suena ahora respecto a lo que lleva la canción (baja en lo suave).
            let body = pow(CGFloat(audio.loudness), 1.6)
            target = calm ? body * 0.5 : min(1, 0.12 + 0.38 * body + 0.6 * flash)
        } else {
            flash = 0
            target = playing ? 0.3 : 0
        }
        let speed: Double = target > value ? 16 : 6   // sube ágil pero sin golpe, baja suave
        value += (target - value) * CGFloat(min(1, dt * speed))
    }
}
