import Foundation

/// El «groove» de la canción en este instante, para que el bichito baile con ella.
struct Groove {
    /// Dentro del pulso: 0 justo en el golpe, sube hasta 1 en el siguiente.
    var phase: Double = 0
    /// Pulsos contados (para alternar izquierda y derecha y marcar los compases).
    var count = 0
    var bpm: Double = 96
    /// Qué tan claro es el pulso (0…1): cuántos golpes caen donde se esperaba.
    var confidence: Double = 0
    /// Fuerza ahora mismo (0…1): sube en los estribillos.
    var intensity: Double = 0.45
    /// Cuánto más fuerte suena ahora que de costumbre en esta canción (−1…1): el estribillo, el subidón.
    var surge: Double = 0
    /// Bombos por segundo en los últimos segundos (absoluto: ~2 en una canción de 128 BPM, poco en una balada).
    var kickRate: Double = 0
    /// Cuánto empuja la canción (golpes fuertes y seguidos), 0…1.
    var drive: Double = 0.35
    /// Peso de los graves y de los agudos (0…1).
    var bass: Double = 0.5
    var bright: Double = 0.4
    /// Golpe grande justo ahora (subidón): el bichito hace un paso especial.
    var drop = false
    /// Golpe de bombo en este instante (0…1, se apaga en ~0.15 s): el bichito rebota con cada uno.
    var kick: Double = 0
    /// Golpe agudo (caja, platillos, palmas) en este instante (0…1): le mueve los brazos.
    var snap: Double = 0
    /// Ánimo de la canción: 0 triste … 1 alegre (tono mayor o menor, brillo y tempo; o lo que diga Spotify).
    var valence: Double = 0.55
    /// Energía de la canción: 0 tranquila … 1 con mucha fuerza.
    var arousal: Double = 0.4
    /// La energía más alta que tuvo esta canción hasta ahora (se olvida muy despacio): si alguna vez fue movida,
    /// una parte tranquila es una pausa, no una canción triste.
    var songPeak: Double = 0
    /// Segundos de esta canción que ya escuchó (para no sacar conclusiones con la intro).
    var listened: Double = 0
    /// −1 suena en menor … +1 en mayor (lo que dicen las notas de la canción hasta ahora).
    var mode: Double = 0
}

/// Lo que se sabe de la canción antes de escucharla, sacado de Spotify: tempo, energía y ánimo
/// (si Spotify los da) o los géneros del artista. Sirve de punto de partida desde el primer segundo.
struct SongHints {
    var bpm: Double?
    var energy: Double?
    var valence: Double?
    var genres: [String] = []

    var isEmpty: Bool { bpm == nil && energy == nil && valence == nil && genres.isEmpty }

    /// Energía y ánimo de partida: los de Spotify si los da; si no, los que sugiere el género.
    var character: (energy: Double, valence: Double)? {
        if let energy, let valence { return (energy, valence) }
        let text = genres.joined(separator: " ").lowercased()
        guard !text.isEmpty else { return nil }
        // De lo más concreto a lo más general (gana la primera coincidencia).
        let rules: [(words: [String], energy: Double, valence: Double)] = [
            (["sad", "emo", "slowcore", "dream pop", "shoegaze", "bedroom", "lo-fi", "lofi"], 0.3, 0.25),
            (["metal", "hardcore", "punk", "grunge"], 0.9, 0.35),
            (["edm", "house", "dance", "electro", "techno", "trance", "dubstep", "big room"], 0.85, 0.72),
            (["reggaeton", "latin", "cumbia", "salsa", "bachata", "dembow", "funk"], 0.8, 0.8),
            (["hip hop", "rap", "trap", "drill"], 0.72, 0.5),
            (["rock", "alternative"], 0.72, 0.55),
            (["pop"], 0.65, 0.68),
            (["r&b", "soul"], 0.5, 0.55),
            (["indie", "folk", "acoustic", "singer-songwriter", "ballad"], 0.35, 0.45),
            (["ambient", "classical", "piano", "chill"], 0.2, 0.5),
        ]
        for rule in rules where rule.words.contains(where: { text.contains($0) }) {
            return (rule.energy, rule.valence)
        }
        return nil
    }
}

/// Saca el pulso y el carácter de la canción del audio real: el tempo (por cómo se repiten los golpes,
/// sobre todo el bombo), si empuja o es tranquila, si tira a graves o a agudos y si suena en mayor o menor.
/// Sin audio real, se inventa un pulso tranquilo.
final class GrooveTracker {
    private(set) var groove = Groove()
    /// Solo para revisar el diseño: un carácter de canción fijo (se ignora el audio).
    var preset: Groove?
    private var period = 60.0 / 96
    private var beats: [Double] = []
    private var lastBeat = -10.0
    private var lastDrop = -10.0
    private var lastBoundary = -10.0
    private var boundaryChecked = true
    private var punch = 0.0
    private var calmIntensity = 0.45
    private var trackID = ""
    /// Notas de toda la canción (para mayor o menor): se suman, así no cambia de opinión a mitad.
    private var chromaSum = [Double](repeating: 0, count: 12)
    private var heard = 0.0
    private var sinceKey = 0.0
    private var kickLevel = 0.0
    private var kicks: [Double] = []
    private var lastKick = -10.0
    private var lastReport = 0.0
    /// El tempo de cuando el pulso estaba claro: en los puentes sin batería se queda con ese.
    private var steadyPeriod: Double?
    private var hints: SongHints?
    private var hintsTrackID = ""

    /// Un golpe cuenta si el bombo sube de golpe (o todo el sonido, en canciones sin batería)…
    private static let kickThreshold: Float = 0.55
    private static let onsetThreshold: Float = 0.8
    /// …y no está pegado al anterior (máx. ~220 golpes por minuto).
    private static let refractory = 0.27
    /// Golpes que se miran para el tempo (s).
    private static let window = 6.0
    /// El tempo se busca en una sola octava, 75–150 BPM: así no duda entre el doble y la mitad.
    private static let periods = Array(stride(from: 0.4, through: 0.8, by: 0.005))
    /// Pulso inventado cuando no llega audio real.
    private static let restingBPM = 96.0
    /// Perfiles de tono de Krumhansl-Kessler: cuánto «pesa» cada nota en una canción en mayor y en menor.
    private static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Lo que Spotify sabe de la canción (llega unos instantes después de empezar).
    func setHints(_ newHints: SongHints?, for id: String) {
        hints = newHints
        hintsTrackID = id
        guard id == trackID, let newHints else { return }
        if let bpm = newHints.bpm, bpm > 0 { period = Self.fold(60 / bpm) }
        // Al principio de la canción, el carácter de Spotify manda; después se mezcla con lo que se oye.
        if heard < 5, let character = newHints.character {
            groove.arousal = character.energy
            groove.valence = character.valence
        }
    }

    func update(audio: AudioSnapshot?, playing: Bool, trackID: String, now: Double, dt: Double) -> Groove {
        var g = groove
        g.drop = false
        if trackID != self.trackID {
            // Canción nueva: el pulso y el ánimo se vuelven a escuchar, empezando por lo que diga Spotify.
            self.trackID = trackID
            beats.removeAll()
            kicks.removeAll()
            steadyPeriod = nil
            chromaSum = [Double](repeating: 0, count: 12)
            heard = 0
            g.listened = 0
            g.songPeak = 0
            g.confidence = 0
            g.mode = 0
            if hintsTrackID != trackID { hints = nil }
            if let bpm = hints?.bpm, bpm > 0 { period = Self.fold(60 / bpm) }
            let character = hints?.character
            g.valence = character?.valence ?? 0.55
            g.arousal = character?.energy ?? 0.45
        }
        guard playing, dt > 0 else {
            groove = g
            return g
        }
        let step = min(1, dt)
        g.kick *= exp(-dt * 9)
        g.snap *= exp(-dt * 10)
        var live = false
        if let preset {
            g.confidence = preset.confidence
            g.intensity = preset.intensity
            g.drive = preset.drive
            g.bass = preset.bass
            g.bright = preset.bright
            g.valence = preset.valence
            g.arousal = preset.arousal
            period = 60 / preset.bpm
        } else if let audio, audio.hasSound {
            live = true
            heard += dt
            g.listened = heard
            listen(to: audio, groove: &g, now: now, dt: dt, step: step)
            g.songPeak = max(g.arousal, g.songPeak - dt * 0.004)
        } else {
            period += (60 / Self.restingBPM - period) * step
            g.confidence += (0.35 - g.confidence) * step
            g.intensity += (0.45 - g.intensity) * step * 2
            g.drive += (0.35 - g.drive) * step * 0.5
            g.bass += (0.5 - g.bass) * step * 0.5
            g.bright += (0.4 - g.bright) * step * 0.5
            g.valence += (0.6 - g.valence) * step * 0.5
            g.arousal += (0.35 - g.arousal) * step * 0.5
        }

        let previousCount = g.count
        g.phase += dt / period
        while g.phase >= 1 {
            g.phase -= 1
            g.count += 1
        }
        if g.count != previousCount {
            lastBoundary = now - g.phase * period
            boundaryChecked = false
            // Sin audio real (o en vista previa), cada pulso inventado también es un golpe.
            if !live { g.kick = max(g.kick, 0.75) }
        }
        // ¿Cayó un golpe cerca de donde se esperaba? Así se mide lo claro del pulso
        // (los platillos entre golpe y golpe no restan, solo cuentan los golpes que faltan o llegan tarde).
        if live && !boundaryChecked && g.phase >= 0.15 {
            boundaryChecked = true
            let onTime = abs(lastBeat - lastBoundary) <= 0.15 * period
            g.confidence += ((onTime ? 1 : 0) - g.confidence) * 0.2
            if g.confidence >= 0.65 { steadyPeriod = period }
        }
        g.bpm = 60 / period
        groove = g
        return g
    }

    // MARK: - Escuchar

    private func listen(to audio: AudioSnapshot, groove g: inout Groove, now: Double, dt: Double, step: Double) {
        let onset = Double(audio.onset)
        let kick = Double(audio.kick)
        if kick >= 0.45 { g.kick = max(g.kick, kick) }
        if onset >= 0.5 && kick < 0.3 { g.snap = max(g.snap, onset) }
        punch += (onset - punch) * step * 0.8
        kickLevel += (kick - kickLevel) * step * 0.8
        g.intensity += (Double(audio.loudness) - g.intensity) * min(1, dt * 6)
        calmIntensity += (g.intensity - calmIntensity) * step * 0.2
        g.surge = g.intensity - calmIntensity
        // Bombos por segundo: separa una canción de fiesta de una balada (que también tiene golpes, pero pocos).
        if audio.kick >= Self.kickThreshold && now - lastKick >= 0.25 {
            lastKick = now
            kicks.append(now)
        }
        kicks.removeAll { now - $0 > Self.window }
        g.kickRate = Double(kicks.count) / min(Self.window, max(1, heard))

        let isBeat = audio.kick >= Self.kickThreshold || audio.onset >= Self.onsetThreshold
        if isBeat && now - lastBeat >= Self.refractory {
            registerBeat(at: now, strength: max(onset, kick), groove: &g)
        }
        let recent = beats.filter { now - $0 <= Self.window }.count
        let density = Double(recent) / Self.window   // golpes por segundo
        let driveTarget = min(1, density / 2.4) * 0.55 + min(1, punch * 3) * 0.25 + g.confidence * 0.2
        g.drive += (driveTarget - g.drive) * step * 0.8

        let bands = audio.bands
        if bands.count >= SpectrumAnalyzer.bandCount {
            let low = Self.mean(bands[0..<5]), mid = Self.mean(bands[5..<13]), high = Self.mean(bands[13..<20])
            let total: Double = low + mid + high + 0.001
            let bassTarget: Double = max(0, min(1, (low / total - 0.25) / 0.3))
            let brightTarget: Double = max(0, min(1, (high / total - 0.12) / 0.3))
            g.bass += (bassTarget - g.bass) * step * 0.8
            g.bright += (brightTarget - g.bright) * step * 0.8
        }
        // Un buen rato sin golpes (parte tranquila): el pulso pierde seguridad.
        if now - lastBeat > period * 3 { g.confidence = max(0, g.confidence - dt * 0.3) }

        // ¿Mayor (alegre) o menor (triste)? Las notas de toda la canción, comparadas una vez por segundo.
        if audio.chroma.count == 12 {
            for note in 0..<12 { chromaSum[note] += Double(audio.chroma[note]) * dt }
            sinceKey += dt
            if sinceKey >= 1 && heard > 3 {
                sinceKey = 0
                g.mode += (Self.modeScore(chromaSum) - g.mode) * 0.5
            }
        }

        // Energía, con señales que no dependen del volumen (cada canción llega a su propio máximo):
        // cuántos bombos por segundo, cuánto brillo (platillos, distorsión) y qué tan marcado está el pulso.
        let kicksFactor: Double = Self.smoothstep(0.8, 2.0, g.kickRate)
        let brightFactor: Double = Self.smoothstep(0.15, 0.5, g.bright)
        let heardEnergy: Double = 0.45 * kicksFactor + 0.3 * brightFactor + 0.25 * g.confidence
        // Ánimo: tono mayor o menor, brillo y bombos (las canciones rápidas suelen ser más alegres).
        // Con bombo, el tono menor pesa poco: mucha música de fiesta está en menor y no es triste.
        let tone: Double = 0.3 * g.mode * (1 - 0.6 * kicksFactor) + 0.3 * (g.bright - 0.35)
        let heardValence: Double = max(0, min(1, 0.5 + tone + 0.15 * (kicksFactor - 0.5)))
        // Lo que dice Spotify (si lo dice) pesa la mitad.
        var energyTarget = heardEnergy, valenceTarget = heardValence
        if let character = hints?.character {
            energyTarget = 0.5 * heardEnergy + 0.5 * character.energy
            valenceTarget = 0.5 * heardValence + 0.5 * character.valence
        }
        g.arousal += (energyTarget - g.arousal) * step * 0.7
        g.valence += (valenceTarget - g.valence) * step * 0.7

        // Cada 8 s, lo que oye (para afinar con tus canciones; solo en el registro del Mac).
        if now - lastReport >= 8 {
            lastReport = now
            let report = String(format: "%.0f BPM · bombos %.1f/s · energía %.2f · ánimo %.2f · tono %+.2f · brillo %.2f · pulso %.2f",
                                60 / period, g.kickRate, g.arousal, g.valence, g.mode, g.bright, g.confidence)
            Log.app.info("Bichito oye: \(report, privacy: .public)")
        }
    }

    private func registerBeat(at now: Double, strength: Double, groove g: inout Groove) {
        lastBeat = now
        beats.append(now)
        beats.removeAll { now - $0 > Self.window }
        // Si Spotify dio el tempo, no hace falta adivinarlo: solo se ajusta dónde cae el golpe.
        // En un puente sin pulso claro, se queda con el tempo que ya conocía de la canción.
        if beats.count >= 3 && hints?.bpm == nil {
            if let steadyPeriod, g.confidence < 0.4 {
                period = steadyPeriod
            } else {
                estimatePeriod()
            }
        }

        // Engancha la fase al golpe: si cae cerca de donde se esperaba, corrige un poco; si no, se resincroniza.
        let error = g.phase < 0.5 ? -g.phase : 1 - g.phase
        if abs(error) < 0.3 {
            g.phase += error * 0.4
        } else if g.confidence < 0.3 {
            if g.phase > 0.5 { g.count += 1 }
            g.phase = 0
        }

        // Subidón: un golpe muy fuerte justo cuando la canción sube (no al empezar: ahí todo «sube»).
        if heard > 10, strength >= 0.9, g.intensity - calmIntensity > 0.15, now - lastDrop > 6 {
            g.drop = true
            lastDrop = now
        }
    }

    /// El periodo que mejor explica los golpes recientes: el que deja más distancias entre golpes
    /// cerca de un múltiplo suyo (los vecinos pesan más que los lejanos).
    private func estimatePeriod() {
        var best = period
        var bestScore = 0.0
        for candidate in Self.periods {
            var score = 0.0
            for i in 0..<beats.count {
                for j in (i + 1)..<beats.count {
                    let distance = beats[j] - beats[i]
                    if distance > 3.2 { break }
                    let multiple = (distance / candidate).rounded()
                    guard multiple >= 1 else { continue }
                    let off = abs(distance - multiple * candidate)
                    score += max(0, 1 - off / 0.025) / multiple
                }
            }
            score *= 1 - 0.15 * abs(log2(candidate / 0.5))   // leve preferencia por ~120 BPM
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        let change = abs(best - period) / period
        period += (best - period) * (change > 0.15 ? 0.6 : 0.3)
    }

    /// Lleva un periodo a la octava 0.4–0.8 s (75–150 BPM).
    private static func fold(_ value: Double) -> Double {
        var result = value
        while result < 0.4 { result *= 2 }
        while result >= 0.8 { result /= 2 }
        return result
    }

    /// +1 si las notas encajan mejor con un tono mayor (alegre), −1 si con uno menor (triste).
    private static func modeScore(_ chroma: [Double]) -> Double {
        var bestMajor = -1.0, bestMinor = -1.0
        for tonic in 0..<12 {
            let rotated = (0..<12).map { chroma[($0 + tonic) % 12] }
            bestMajor = max(bestMajor, correlation(rotated, majorProfile))
            bestMinor = max(bestMinor, correlation(rotated, minorProfile))
        }
        return max(-1, min(1, (bestMajor - bestMinor) * 5))
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let meanA: Double = a.reduce(0, +) / Double(a.count)
        let meanB: Double = b.reduce(0, +) / Double(b.count)
        var product = 0.0, squareA = 0.0, squareB = 0.0
        for index in a.indices {
            let x = a[index] - meanA, y = b[index] - meanB
            product += x * y
            squareA += x * x
            squareB += y * y
        }
        return squareA > 0 && squareB > 0 ? product / (squareA * squareB).squareRoot() : 0
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private static func mean(_ values: ArraySlice<Float>) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, +)) / Double(values.count)
    }
}
