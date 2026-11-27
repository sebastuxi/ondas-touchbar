import CoreGraphics
import Foundation

/// Una pose del bichito en un instante (los pasos se mezclan pose a pose).
struct CritterPose {
    var shiftX: CGFloat = 0
    var lift: CGFloat = 0
    var tilt: CGFloat = 0
    /// + aplastado, − estirado.
    var squash: CGFloat = 0
    /// 1 → −1 → 1 al dar una vuelta.
    var spin: CGFloat = 1
    /// Pies: x desde el centro; y = cuánto se levantan del suelo.
    var footL = CGPoint(x: -4.6, y: 0)
    var footR = CGPoint(x: 4.6, y: 0)
    /// Brazos: 0 colgando, π/2 de lado, π arriba (más de π: hacia dentro, por encima de la cabeza).
    var armL: CGFloat = 0.45
    var armR: CGFloat = 0.45
    var bend: CGFloat = 0.4
    /// Hacia dónde miran las pupilas (−1…1).
    var look = CGPoint.zero
    /// Ojos: 0 abiertos, 1 cerrados (contento).
    var closed: CGFloat = 0
    /// Boca abierta (canta).
    var open: CGFloat = 0
    /// Cara de pena: cejas, boca hacia abajo y antenas caídas (0…1).
    var sad: CGFloat = 0

    func mixed(with other: CritterPose, _ t: CGFloat) -> CritterPose {
        guard t > 0 else { return self }
        guard t < 1 else { return other }
        func m(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        func p(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: m(a.x, b.x), y: m(a.y, b.y)) }
        var r = CritterPose()
        r.shiftX = m(shiftX, other.shiftX)
        r.lift = m(lift, other.lift)
        r.tilt = m(tilt, other.tilt)
        r.squash = m(squash, other.squash)
        r.spin = m(spin, other.spin)
        r.footL = p(footL, other.footL)
        r.footR = p(footR, other.footR)
        r.armL = m(armL, other.armL)
        r.armR = m(armR, other.armR)
        r.bend = m(bend, other.bend)
        r.look = p(look, other.look)
        r.closed = m(closed, other.closed)
        r.open = m(open, other.open)
        r.sad = m(sad, other.sad)
        return r
    }
}

/// Los pasos de baile. Cada uno dura 1, 2 o 4 golpes y se repite hasta que el coreógrafo elige otro.
enum DanceMove: CaseIterable {
    case bounce, hop, bigJump, sideStep, disco, raiseRoof, waveArms, clap, headbang, twist
    case spin, robot, wiggle, kicks, shimmy, sway, sad, freeze, point, march

    var name: String {
        switch self {
        case .bounce: return "rebote"
        case .hop: return "saltitos"
        case .bigJump: return "salto grande"
        case .sideStep: return "paso al lado"
        case .disco: return "disco"
        case .raiseRoof: return "techo"
        case .waveArms: return "olas"
        case .clap: return "palmas"
        case .headbang: return "cabeceo"
        case .twist: return "twist"
        case .spin: return "giro"
        case .robot: return "robot"
        case .wiggle: return "meneo"
        case .kicks: return "patadas"
        case .shimmy: return "hombros"
        case .sway: return "vaivén"
        case .sad: return "triste"
        case .freeze: return "pose"
        case .point: return "apuntar"
        case .march: return "marcha"
        }
    }

    /// Golpes que dura el paso.
    var beats: Int {
        switch self {
        case .bigJump, .spin, .freeze, .sideStep, .waveArms, .clap, .point: return 2
        case .sway, .sad: return 4
        default: return 1
        }
    }

    /// Energía de canción a la que mejor le va (0 tranquila … 1 a tope).
    var energy: Double {
        switch self {
        case .sad: return 0.15
        case .sway: return 0.2
        case .waveArms: return 0.3
        case .sideStep: return 0.45
        case .march: return 0.5
        case .bounce: return 0.55
        case .point, .clap: return 0.6
        case .twist, .robot: return 0.62
        case .disco, .raiseRoof, .wiggle: return 0.7
        case .shimmy, .kicks: return 0.75
        case .headbang, .hop: return 0.82
        case .bigJump, .spin, .freeze: return 0.88
        }
    }

    /// Ánimo que le va: alegre (1), triste (0) o cualquiera (nil).
    var mood: Double? {
        switch self {
        case .sad: return 0.1
        case .headbang: return 0.35
        case .hop, .disco, .clap, .point, .spin, .bigJump, .wiggle, .waveArms: return 0.8
        default: return nil
        }
    }

    var likesBass: Bool { [.bounce, .raiseRoof, .headbang, .twist, .march].contains(self) }
    var likesBright: Bool { [.disco, .robot, .shimmy, .clap, .point, .wiggle].contains(self) }
    var likesFast: Bool { [.hop, .kicks, .shimmy, .wiggle, .headbang].contains(self) }
    /// Pasos especiales: para los subidones (y alguna vez suelta).
    var isAccent: Bool { [.bigJump, .spin, .freeze].contains(self) }
    /// Sencillos: van bien mientras el pulso todavía no está claro.
    var isSimple: Bool { [.bounce, .sway, .sideStep, .waveArms, .march].contains(self) }

    /// La pose en este instante. `beat`: golpe dentro del paso (0…beats−1); `p`: 0…1 dentro del golpe
    /// (0 = justo en el golpe); `side`: ±1, cambia en cada golpe; `amp`: cuánto se mueve (sube en lo fuerte).
    func pose(beat: Int, p: Double, side: CGFloat, amp: CGFloat) -> CritterPose {
        let up: CGFloat = sn(.pi * p)                       // 0 en el golpe, 1 entre golpes
        let hit = CGFloat(exp(-p * 6))                      // 1 en el golpe y se apaga
        let q: Double = (Double(beat) + p) / Double(beats)  // 0…1 a lo largo del paso
        var pose = CritterPose()
        switch self {
        case .bounce:
            pose.lift = (-1.4 * hit + 1.0 * up) * amp
            pose.squash = 0.2 * hit * amp
            pose.armL = 0.8 + 0.35 * up * amp
            pose.armR = pose.armL
            pose.bend = 0.9
            if side > 0 { pose.footL.y = 1.2 * up * amp } else { pose.footR.y = 1.2 * up * amp }
            pose.closed = 0.3 * hit
        case .hop:
            pose.lift = 3.6 * up * amp
            pose.squash = (0.22 * hit - 0.1 * up) * amp
            pose.footL = CGPoint(x: -3.4, y: 2.8 * up * amp)
            pose.footR = CGPoint(x: 3.4, y: 2.8 * up * amp)
            pose.armL = 1.4 + 1.3 * up * amp
            pose.armR = pose.armL
            pose.open = 0.6 * up
            pose.tilt = 0.08 * side * amp
        case .bigJump:
            if q < 0.3 {
                // Se agacha para tomar impulso…
                let crouch = CGFloat(q / 0.3)
                pose.lift = -1.6 * crouch
                pose.squash = 0.25 * crouch
                pose.armL = 0.3
                pose.armR = 0.3
                pose.closed = 0.5 * crouch
            } else if q < 0.85 {
                // …vuela con los brazos al cielo…
                let air: CGFloat = sn(.pi * (q - 0.3) / 0.55)
                pose.lift = 4.4 * air
                pose.squash = -0.14 * air
                pose.armL = 2.9
                pose.armR = 2.9
                pose.footL = CGPoint(x: -3.2, y: 3.6 * air)
                pose.footR = CGPoint(x: 3.2, y: 3.6 * air)
                pose.open = 1
                pose.closed = 1
            } else {
                // …y aterriza aplastándose.
                let land = CGFloat((q - 0.85) / 0.15)
                pose.squash = 0.24 * (1 - land)
                pose.lift = -1 * (1 - land)
                pose.armL = 1.6
                pose.armR = 1.6
            }
        case .sideStep:
            let direction: CGFloat = beat == 0 ? -1 : 1
            let arrive = CGFloat(smooth(0, 0.35, p))
            let x: CGFloat = -direction + 2 * direction * arrive
            pose.shiftX = 2.8 * x * amp
            pose.tilt = -0.12 * x * amp
            pose.lift = (0.6 * up - 0.6 * hit) * amp
            pose.squash = 0.12 * hit * amp
            let lifted: CGFloat = 1.8 * sn(.pi * min(1, p / 0.35)) * amp
            if direction < 0 { pose.footL = CGPoint(x: -5.6, y: lifted) } else { pose.footR = CGPoint(x: 5.6, y: lifted) }
            pose.armL = 0.7 - 0.4 * x
            pose.armR = 0.7 + 0.4 * x
            pose.look = CGPoint(x: 0.6 * x, y: 0)
        case .disco:
            // Un brazo arriba y el otro abajo; en cada golpe cambian, y la cadera va hacia el de arriba.
            let snap = CGFloat(smooth(0, 0.22, p))
            let raised: CGFloat = 2.8, lowered: CGFloat = 0.5
            let rightUp = side > 0
            pose.armR = rightUp ? lowered + (raised - lowered) * snap : raised + (lowered - raised) * snap
            pose.armL = rightUp ? raised + (lowered - raised) * snap : lowered + (raised - lowered) * snap
            let hip: CGFloat = -side + 2 * side * snap
            pose.shiftX = 2.2 * hip * amp
            pose.tilt = -0.16 * hip * amp
            pose.lift = (1.0 * up - 0.8 * hit) * amp
            pose.squash = 0.14 * hit * amp
            if side > 0 { pose.footL.y = 1.4 * up * amp } else { pose.footR.y = 1.4 * up * amp }
            pose.look = CGPoint(x: 0.6 * hip, y: 0.4)
            pose.closed = 0.5 * hit
            pose.open = 0.4 * hit
        case .raiseRoof:
            pose.lift = (-1.2 * hit + 0.7 * up) * amp
            pose.squash = 0.18 * hit * amp
            pose.armL = 2.0 + 0.8 * hit * amp
            pose.armR = pose.armL
            pose.bend = 1.3
            pose.tilt = 0.06 * side * amp
            pose.closed = 0.4 * hit
            pose.open = 0.3 * hit
        case .waveArms:
            let wave: CGFloat = cs(.pi * (Double(beat % 2) + p))
            pose.shiftX = 2.0 * wave * amp
            pose.tilt = -0.2 * wave * amp
            pose.armL = 2.7 + 0.3 * wave
            pose.armR = 2.7 - 0.3 * wave
            pose.lift = 0.6 * up * amp
            pose.closed = 0.8
            pose.footL = CGPoint(x: -5, y: 0)
            pose.footR = CGPoint(x: 5, y: 0)
        case .clap:
            // Manos arriba; palmada en el segundo golpe.
            let clap: CGFloat = beat == 1 ? hit : 0
            pose.armL = 2.9 + 0.5 * clap
            pose.armR = pose.armL
            pose.bend = 0.6
            pose.lift = (0.6 * up - 0.8 * hit) * amp
            pose.squash = 0.12 * hit * amp
            pose.closed = 0.8 * clap
            pose.open = 0.6 * clap
            pose.tilt = 0.05 * side
        case .headbang:
            pose.lift = (-2.0 * hit + 0.4 * up) * amp
            pose.squash = 0.26 * hit * amp
            pose.look = CGPoint(x: 0, y: -hit)
            pose.closed = 0.7 * hit
            pose.armL = 0.5 + 0.4 * hit
            pose.armR = pose.armL
            pose.bend = 1.2
            pose.tilt = 0.12 * side * hit * amp
            pose.footL = CGPoint(x: -5.4, y: 0)
            pose.footR = CGPoint(x: 5.4, y: 0)
        case .twist:
            let twist: CGFloat = sn(2 * .pi * p)   // dos giros de cadera por golpe
            pose.tilt = 0.22 * twist * amp
            pose.shiftX = 0.8 * twist * amp
            pose.lift = (-0.8 + 0.4 * abs(twist)) * amp
            pose.footL = CGPoint(x: -4.6 + 1.2 * twist, y: 0)
            pose.footR = CGPoint(x: 4.6 + 1.2 * twist, y: 0)
            pose.armL = 1.3 - 0.4 * twist
            pose.armR = 1.3 + 0.4 * twist
            pose.bend = 1.4
        case .spin:
            let arc: CGFloat = sn(.pi * q)
            pose.spin = cs(2 * .pi * q)
            pose.lift = 2.4 * arc * amp
            pose.armL = 1.6
            pose.armR = 1.6
            pose.closed = 1
            pose.footL = CGPoint(x: -3.6, y: 1.2 * arc)
            pose.footR = CGPoint(x: 3.6, y: 1.2 * arc)
        case .robot:
            // Poses rígidas que cambian de golpe en cada pulso (sin suavizar).
            let snap = CGFloat(smooth(0, 0.08, p))
            let toL: CGFloat = side > 0 ? 1.57 : 3.0, toR: CGFloat = side > 0 ? 3.0 : 1.57
            pose.armL = toR + (toL - toR) * snap
            pose.armR = toL + (toR - toL) * snap
            pose.bend = 0
            pose.lift = 0.5 * up * amp
            pose.tilt = 0.1 * side * snap
            pose.look = CGPoint(x: 0.8 * side, y: 0)
        case .wiggle:
            let wiggle: CGFloat = sn(4 * .pi * p)   // dos meneos por golpe
            pose.shiftX = 1.6 * wiggle * amp
            pose.tilt = -0.1 * wiggle * amp
            pose.armL = 1.6 + 0.3 * wiggle
            pose.armR = 1.6 - 0.3 * wiggle
            pose.bend = 0.8
            pose.lift = (0.6 * up - 0.6 * hit) * amp
            pose.open = 0.3
        case .kicks:
            let kick: CGFloat = up * amp
            if side > 0 {
                pose.footR = CGPoint(x: 4.6 + 2.4 * kick, y: 3.2 * kick)
            } else {
                pose.footL = CGPoint(x: -4.6 - 2.4 * kick, y: 3.2 * kick)
            }
            pose.tilt = -0.12 * side * kick
            pose.armL = 1.3 + 0.4 * kick
            pose.armR = pose.armL
            pose.lift = 0.6 * up * amp
        case .shimmy:
            let shake: CGFloat = sn(8 * .pi * p)   // cuatro sacudidas por golpe
            pose.tilt = 0.07 * shake * amp
            pose.shiftX = 0.5 * shake * amp
            pose.armL = 1.5 + 0.25 * shake
            pose.armR = 1.5 - 0.25 * shake
            pose.bend = 1.0
            pose.lift = (-0.8 * hit + 0.5 * up) * amp
            pose.squash = 0.1 * hit * amp
            pose.closed = 0.5
            pose.open = 0.4
        case .sway:
            let swing: CGFloat = cs(2 * .pi * q)   // un vaivén en los cuatro golpes
            pose.shiftX = 2.2 * swing * amp
            pose.tilt = -0.16 * swing * amp
            pose.armL = 0.6 + 0.3 * swing
            pose.armR = 0.6 - 0.3 * swing
            pose.lift = 0.5 * up * amp
            pose.closed = 0.4
        case .sad:
            // Triste: se mece muy despacio, bracitos colgando, mirando al suelo.
            let slow: CGFloat = cs(2 * .pi * q)
            pose.shiftX = 1.4 * slow * amp
            pose.tilt = -0.12 * slow * amp
            pose.lift = -0.9
            pose.squash = 0.06
            pose.armL = 0.2 + 0.12 * slow
            pose.armR = 0.2 - 0.12 * slow
            pose.bend = 0.2
            pose.footL = CGPoint(x: -3.8, y: 0)
            pose.footR = CGPoint(x: 3.8, y: 0)
            pose.look = CGPoint(x: 0.3 * slow, y: -1)
            pose.closed = 0.4
            pose.sad = 1
        case .freeze:
            // Pose de estrella: brazo arriba, mano en la cintura, y la aguanta.
            let hold = CGFloat(smooth(0, 0.15, q))
            pose.armR = 0.45 + 2.45 * hold
            pose.armL = 0.45 + 0.45 * hold
            pose.bend = 1.6 * hold
            pose.tilt = -0.2 * hold
            pose.shiftX = 1.5 * hold
            pose.footR = CGPoint(x: 4.6 + 1.6 * hold, y: 0)
            pose.look = CGPoint(x: 0.4, y: 0.5)
            pose.open = 0.5 * hold
            pose.squash = 0.02 * sn(6 * .pi * q)
        case .point:
            // Apunta arriba a un lado y luego al otro.
            let direction: CGFloat = beat == 0 ? -1 : 1
            let reach = CGFloat(smooth(0, 0.2, p))
            if direction < 0 {
                pose.armL = 0.6 + 1.9 * reach
                pose.armR = 0.6
            } else {
                pose.armR = 0.6 + 1.9 * reach
                pose.armL = 0.6
            }
            pose.tilt = -0.14 * direction * reach
            pose.shiftX = 1.2 * direction * reach
            pose.look = CGPoint(x: 0.9 * direction, y: 0.6)
            pose.lift = (0.6 * up - 0.6 * hit) * amp
            pose.squash = 0.1 * hit * amp
        case .march:
            let knee: CGFloat = up * amp
            if side > 0 { pose.footL = CGPoint(x: -3.6, y: 3 * knee) } else { pose.footR = CGPoint(x: 3.6, y: 3 * knee) }
            pose.armL = side > 0 ? 0.4 : 0.4 + 0.6 * knee   // brazo contrario a la rodilla
            pose.armR = side > 0 ? 0.4 + 0.6 * knee : 0.4
            pose.lift = 0.5 * up * amp
            pose.tilt = 0.04 * side
            pose.look = CGPoint(x: 0, y: 0.2)
        }
        return pose
    }
}

/// Elige el siguiente paso en cada compás según cómo suena la canción en ese momento (energía, bombo,
/// platillos, ánimo y tempo), sin repetir el mismo dos veces seguidas. Si la canción explota, salta o gira
/// en el siguiente golpe; si se calma de golpe, baja el ritmo enseguida. Cada canción tiene su semilla,
/// así que cada una tiene su propia coreografía (y cambia con lo que va pasando en ella).
final class Choreographer {
    private(set) var move: DanceMove = .sway
    private(set) var previousMove: DanceMove = .sway
    /// Golpe en el que empezó el paso actual.
    private(set) var moveStart = 0
    /// Solo para revisar el diseño: pasa por todos los pasos en orden, uno por compás.
    var showAll = false
    private var recent: [DanceMove] = []
    private var random = SeededRandom(seed: 1)
    private var lastBeat = Int.min
    private var loudAverage = 0.5
    private var accentQueued = false
    private var showIndex = 0

    func reset(seed: UInt64) {
        random = SeededRandom(seed: seed)
        recent.removeAll()
        lastBeat = Int.min
        accentQueued = false
    }

    /// La pose del paso actual en este instante, con un fundido corto desde el anterior al cambiar.
    func pose(count: Int, phase: Double, amp: CGFloat) -> CritterPose {
        let side: CGFloat = count % 2 == 0 ? 1 : -1
        let inMove = max(0, count - moveStart)
        var current = move.pose(beat: inMove % move.beats, p: phase, side: side, amp: amp)
        let sinceChange = Double(inMove) + phase
        if sinceChange < 0.3 {
            let before = previousMove.pose(beat: count % previousMove.beats, p: phase, side: side, amp: amp)
            current = before.mixed(with: current, CGFloat(sinceChange / 0.3))
        }
        return current
    }

    /// Semilla de una canción (la misma para el bichito y el gato: así bailan la misma coreografía).
    static func seed(for songID: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in songID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }

    /// Subidón: en el próximo golpe hace un paso especial.
    func queueAccent() {
        accentQueued = true
    }

    /// En cada golpe nuevo decide si cambia de paso. Devuelve el paso nuevo si cambió.
    func beat(_ count: Int, groove g: Groove) -> DanceMove? {
        guard count != lastBeat else { return nil }
        lastBeat = count
        // La energía de la canción, más un empujón cuando ahora suena más fuerte que de costumbre (estribillo).
        let energy = max(0, min(1, g.arousal + 0.3 * g.surge))
        let calmedDown = g.intensity < loudAverage - 0.25 && move.energy > 0.5
        loudAverage += (g.intensity - loudAverage) * 0.08
        let inMove = count - moveStart
        if showAll {
            guard count % 4 == 0 else { return nil }
            showIndex += 1
            return switchTo(DanceMove.allCases[showIndex % DanceMove.allCases.count], at: count)
        }
        if accentQueued {
            accentQueued = false
            return switchTo(pick(energy: max(energy, 0.85), groove: g, accent: true), at: count)
        }
        if calmedDown {
            return switchTo(pick(energy: min(energy, 0.35), groove: g, accent: false), at: count)
        }
        // Un paso nuevo al empezar cada compás (cuando el paso actual ya terminó su vuelta).
        guard count % 4 == 0, inMove >= move.beats else { return nil }
        return switchTo(pick(energy: energy, groove: g, accent: false), at: count)
    }

    private func switchTo(_ next: DanceMove, at count: Int) -> DanceMove? {
        guard next != move else { return nil }   // sigue con el mismo: no hace falta empezarlo de nuevo
        previousMove = move
        move = next
        moveStart = count
        recent.append(next)
        if recent.count > 3 { recent.removeFirst() }
        return next
    }

    private func pick(energy: Double, groove g: Groove, accent: Bool) -> DanceMove {
        // Triste solo con pruebas: tras 15 s escuchando y si la canción nunca fue movida
        // (la intro o la parte calmada de una canción de fiesta se bailan tranquilas, no tristes).
        let canBeSad = g.listened >= 15 && g.songPeak < 0.5
        // Muy triste y tranquila: casi siempre el baile triste; a veces, un compás de vaivén lento y vuelve.
        if canBeSad && g.valence < 0.3 && energy < 0.35 {
            guard move == .sad else { return .sad }
            let roll = random.next()
            return roll < 0.7 ? .sad : (roll < 0.88 ? .sway : .waveArms)
        }
        let fast = smooth(110, 135, g.bpm)
        var best = DanceMove.bounce
        var bestScore = -1.0
        for candidate in DanceMove.allCases {
            let distance = energy - candidate.energy
            var weight = exp(-distance * distance / 0.12)
            if let mood = candidate.mood { weight *= max(0.1, 1 - abs(g.valence - mood) * 1.1) }
            if candidate == .sad { weight *= canBeSad && g.valence < 0.42 && energy < 0.45 ? 3 : 0 }
            if candidate.likesBass { weight *= 0.8 + g.bass * 0.9 }
            if candidate.likesBright { weight *= 0.8 + g.bright * 0.9 }
            if candidate.likesFast { weight *= 0.6 + fast * 0.9 }
            if candidate.isAccent { weight *= accent ? 5 : 0.3 }
            if g.confidence < 0.3 { weight *= candidate.isSimple ? 1.6 : 0.5 }
            if candidate == move {
                weight *= 0.08
            } else if recent.contains(candidate) {
                weight *= 0.35
            }
            let score = weight * (0.35 + 1.3 * random.next())   // azar con la semilla de la canción: más variedad
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }
}

extension Groove {
    /// El pulso para bailar: un poco adelantado (para caer con el golpe que se oye, no con el que se detecta)
    /// y a medio tiempo si el pulso detectado va muy rápido para lo que es la canción (el piano de una balada).
    var danceBeat: (count: Int, phase: Double) {
        var beatPhase = phase + Theme.Critter.beatLead * bpm / 60
        var beatCount = count
        if beatPhase >= 1 {
            beatPhase -= 1
            beatCount += 1
        }
        if bpm > 140 && arousal < 0.8 {
            beatPhase = (Double(beatCount % 2) + beatPhase) / 2
            beatCount /= 2
        }
        return (beatCount, beatPhase)
    }
}

/// Números al azar con semilla (cada canción tiene su propio «sabor», pero no es una secuencia fija).
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    /// 0…1
    mutating func next() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 0x2545_F491_4F6C_DD1D
        return Double(value >> 11) / Double(UInt64(1) << 53)
    }
}

private func sn(_ x: Double) -> CGFloat { CGFloat(sin(x)) }
private func cs(_ x: Double) -> CGFloat { CGFloat(cos(x)) }

private func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}
