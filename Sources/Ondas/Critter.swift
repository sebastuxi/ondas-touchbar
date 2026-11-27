import AppKit
import QuartzCore

/// El bichito que baila sobre la barra de progreso: hace de cabezal y avanza con la canción.
/// - Improvisa con la música: en cada compás el coreógrafo elige uno de sus 20 pasos según cómo suena
///   (energía, bombo, platillos, ánimo y tempo); si la canción explota, salta o gira; si se calma, baja el ritmo;
///   con canciones tristes, se pone triste. Encima, reacciona a cada golpe real (bombo y platillos).
/// - Cada canción le da su color (el de la portada) y su propia coreografía.
/// - En pausa se sienta y mira el botón de play. Si lo arrastras, va colgado de tu dedo. Si lo tocas, se ríe.
/// Diseño propio: cuerpo ovalado, dos antenas con bolita, ojos grandes, mejillas, bracitos y patitas.
final class Critter {
    enum Mode { case dancing, waiting, carried }

    /// Su (0, 0) es el suelo bajo el bichito: se coloca con `position` donde va la canción.
    let root = CALayer()
    /// Dónde está ahora (sigue al cabezal con suavidad), en coordenadas del padre.
    private(set) var x: CGFloat = 0
    /// Solo para revisar el diseño: pasa por todos los pasos en orden, uno por compás.
    var previewMoves: Bool {
        get { choreographer.showAll }
        set { choreographer.showAll = newValue }
    }

    private typealias C = Theme.Critter

    /// Antena con muelle: la bolita llega tarde y rebota, así se nota que baila de verdad.
    private struct Feeler {
        var offset: CGPoint
        var velocity = CGPoint.zero
        var lastBase: CGPoint?
        var lastBaseVelocity = CGPoint.zero

        mutating func step(base: CGPoint, rest: CGPoint, dt: CGFloat) -> CGPoint {
            var baseVelocity = CGPoint.zero
            if let lastBase { baseVelocity = (base - lastBase) * (1 / dt) }
            var baseAcceleration = (baseVelocity - lastBaseVelocity) * (1 / dt)
            let limit: CGFloat = 3000
            if baseAcceleration.length > limit { baseAcceleration = baseAcceleration * (limit / baseAcceleration.length) }
            lastBase = base
            lastBaseVelocity = baseVelocity
            let acceleration = (rest - offset) * 260 - velocity * 13 - baseAcceleration * 0.9
            velocity = velocity + acceleration * dt
            offset = offset + velocity * dt
            let stretch = offset - rest
            if stretch.length > 4 { offset = rest + stretch * (4 / stretch.length) }   // que no se estire de más
            return offset
        }
    }

    // MARK: - Capas

    private let shadow = CAShapeLayer()
    private let antennaBorderL = CAShapeLayer(), antennaBorderR = CAShapeLayer()
    private let antennaL = CAShapeLayer(), antennaR = CAShapeLayer()
    private let tipL = CAShapeLayer(), tipR = CAShapeLayer()
    private let armBorderL = CAShapeLayer(), armBorderR = CAShapeLayer()
    private let armL = CAShapeLayer(), armR = CAShapeLayer()
    private let handL = CAShapeLayer(), handR = CAShapeLayer()
    private let legBorderL = CAShapeLayer(), legBorderR = CAShapeLayer()
    private let legL = CAShapeLayer(), legR = CAShapeLayer()
    private let shoeL = CAShapeLayer(), shoeR = CAShapeLayer()
    private let torso = CALayer()
    private let body = CAShapeLayer()
    private let belly = CAShapeLayer()
    private let gloss = CAShapeLayer()
    private let cheekL = CAShapeLayer(), cheekR = CAShapeLayer()
    private let eyeL = CAShapeLayer(), eyeR = CAShapeLayer()
    private let pupilL = CAShapeLayer(), pupilR = CAShapeLayer()
    private let smile = CAShapeLayer()
    private let mouth = CAShapeLayer()
    private let browL = CAShapeLayer(), browR = CAShapeLayer()
    private let tear = CAShapeLayer()

    // MARK: - Estado

    private let choreographer = Choreographer()
    private var vx: CGFloat = 0
    private var sitAmount: CGFloat = 1
    private var carryAmount: CGFloat = 0
    private var runAmount: CGFloat = 0
    private var curly = false
    private var bounce: CGFloat = 1
    private var reactStart = -100.0
    private var popStart = -100.0
    private var nextBlink = 0.0
    private var blinkUntil = 0.0
    private var nextGlance = 0.0
    private var glanceUntil = 0.0
    private var tearStart = -100.0
    private var nextTear = 0.0
    private var feelerL = Feeler(offset: CGPoint(x: -2.4, y: 4.6))
    private var feelerR = Feeler(offset: CGPoint(x: 2.4, y: 4.6))

    private static let eyeX: CGFloat = 3.7
    private static let eyeY: CGFloat = 1.8
    private static let tipRest = CGPoint(x: 2.4, y: 4.6)

    // MARK: - Construcción

    init() {
        root.bounds = CGRect(x: -16, y: 0, width: 32, height: Theme.Size.barHeight)
        root.anchorPoint = CGPoint(x: 0.5, y: 0)
        root.contentsScale = Theme.scale
        // Halo oscuro alrededor de la silueta: se ve sobre barras de cualquier color.
        root.shadowColor = NSColor.black.cgColor
        root.shadowOpacity = C.haloOpacity
        root.shadowRadius = C.haloRadius
        root.shadowOffset = .zero
        let w = C.bodyWidth, h = C.bodyHeight

        shadow.path = Self.ellipse(width: 15, height: 2.2)
        shadow.fillColor = NSColor.black.cgColor
        shadow.opacity = 0.35
        add(shadow, to: root)

        // Antenas, brazos y patas van detrás del cuerpo: trazo del color del cuerpo con borde oscuro.
        for antenna in [antennaL, antennaR] {
            antenna.fillColor = nil
            antenna.lineWidth = 1.1
            antenna.lineCap = .round
        }
        for border in [antennaBorderL, antennaBorderR] {
            border.fillColor = nil
            border.strokeColor = C.outline.withAlphaComponent(0.85).cgColor
            border.lineWidth = 2.5
            border.lineCap = .round
        }
        for border in [armBorderL, armBorderR, legBorderL, legBorderR] {
            border.fillColor = nil
            border.strokeColor = C.outline.withAlphaComponent(0.85).cgColor
            border.lineWidth = C.limbBorder
            border.lineCap = .round
        }
        for limb in [armL, armR, legL, legR] {
            limb.fillColor = nil
            limb.lineWidth = C.limbWidth
            limb.lineCap = .round
        }
        for tip in [tipL, tipR] { tip.path = Self.ellipse(width: 3.2, height: 3.2) }
        for hand in [handL, handR] { hand.path = Self.ellipse(width: 3.2, height: 3.2) }
        for shoe in [shoeL, shoeR] { shoe.path = Self.ellipse(width: 4, height: 2.2) }
        for part in [tipL, tipR, handL, handR, shoeL, shoeR] {
            part.strokeColor = C.outline.cgColor
            part.lineWidth = 0.8
        }
        for part in [antennaBorderL, antennaBorderR, antennaL, antennaR, tipL, tipR, armBorderL, armBorderR, armL, armR,
                     handL, handR, legBorderL, legBorderR, legL, legR, shoeL, shoeR] {
            add(part, to: root)
        }

        torso.bounds = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        add(torso, to: root)
        body.path = CGPath(ellipseIn: torso.bounds, transform: nil)
        body.strokeColor = C.outline.cgColor
        body.lineWidth = 1.2
        belly.path = CGPath(ellipseIn: CGRect(x: -5.6, y: -h / 2 + 0.9, width: 11.2, height: 6.6), transform: nil)
        gloss.path = CGPath(ellipseIn: CGRect(x: -6.8, y: 2.4, width: 4, height: 2.4), transform: nil)
        gloss.fillColor = NSColor(white: 1, alpha: 0.4).cgColor
        for (cheek, side) in [(cheekL, CGFloat(-1)), (cheekR, CGFloat(1))] {
            cheek.path = Self.ellipse(width: 3, height: 1.6)
            cheek.fillColor = C.cheek.cgColor
            cheek.position = CGPoint(x: side * 6, y: -1.4)
        }
        for (eye, side) in [(eyeL, CGFloat(-1)), (eyeR, CGFloat(1))] {
            eye.path = Self.ellipse(width: 5.6, height: 6.4)
            eye.fillColor = NSColor.white.cgColor
            eye.strokeColor = C.outline.cgColor
            eye.lineWidth = 0.7
            eye.position = CGPoint(x: side * Self.eyeX, y: Self.eyeY)
        }
        for pupil in [pupilL, pupilR] {
            pupil.path = Self.ellipse(width: 2.8, height: 2.8)
            pupil.fillColor = C.pupil.cgColor
        }
        smile.fillColor = nil
        smile.strokeColor = C.mouth.cgColor
        smile.lineWidth = 1
        smile.lineCap = .round
        mouth.path = Self.ellipse(width: 2.8, height: 2.6)
        mouth.fillColor = C.mouth.cgColor
        mouth.position = CGPoint(x: 0, y: -3.4)
        mouth.opacity = 0
        // Cejas de pena «/ \» (solo se ven cuando está triste).
        for (brow, side) in [(browL, CGFloat(-1)), (browR, CGFloat(1))] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: side * 5.6, y: 5.4))
            path.addLine(to: CGPoint(x: side * 2.4, y: 6.3))
            brow.path = path
            brow.fillColor = nil
            brow.strokeColor = C.mouth.cgColor
            brow.lineWidth = 0.9
            brow.lineCap = .round
            brow.opacity = 0
        }
        // Lagrimita que baja por la mejilla.
        let drop = CGMutablePath()
        drop.move(to: CGPoint(x: 0, y: 1.6))
        drop.addQuadCurve(to: CGPoint(x: 0.9, y: -0.4), control: CGPoint(x: 0.9, y: 0.6))
        drop.addArc(center: CGPoint(x: 0, y: -0.4), radius: 0.9, startAngle: 0, endAngle: .pi, clockwise: true)
        drop.addQuadCurve(to: CGPoint(x: 0, y: 1.6), control: CGPoint(x: -0.9, y: 0.6))
        tear.path = drop
        tear.fillColor = NSColor(hex: 0x8FD3FF).cgColor
        tear.strokeColor = C.outline.cgColor
        tear.lineWidth = 0.4
        tear.opacity = 0
        for part in [body, belly, gloss, cheekL, cheekR, eyeL, eyeR, pupilL, pupilR, smile, mouth, browL, browR, tear] {
            add(part, to: torso)
        }
        setColors(body: Palette.fallback.primary, accent: Palette.fallback.secondary)
    }

    private func add(_ layer: CALayer, to parent: CALayer) {
        layer.contentsScale = Theme.scale
        parent.addSublayer(layer)
    }

    // MARK: - API

    /// El color de la portada: cuerpo, bracitos y patitas del color principal (con borde oscuro),
    /// bolitas de las antenas del segundo.
    func setColors(body color: NSColor, accent: NSColor) {
        body.fillColor = color.cgColor
        belly.fillColor = color.mixed(with: .white, fraction: 0.38).cgColor
        for limb in [armL, armR, legL, legR, antennaL, antennaR] { limb.strokeColor = color.cgColor }
        for part in [handL, handR, shoeL, shoeR] { part.fillColor = color.cgColor }
        tipL.fillColor = accent.cgColor
        tipR.fillColor = accent.cgColor
    }

    /// Cada canción le da su coreografía (semilla), antenas rectas o rizadas y cuánto rebota.
    func setSong(_ id: String) {
        let hash = Choreographer.seed(for: id)
        choreographer.reset(seed: hash)
        curly = (hash >> 9) & 1 == 1
        bounce = 0.9 + CGFloat((hash >> 17) % 21) / 100
    }

    /// Sale del suelo con un saltito (al aparecer).
    func popIn(at target: CGFloat, now: Double) {
        x = target
        vx = 0
        popStart = now
        feelerL.lastBase = nil
        feelerR.lastBase = nil
    }

    /// Lo tocaste: se ríe y da un saltito.
    func react(now: Double) {
        reactStart = now
    }

    /// Un fotograma. `targetX`: dónde va la canción (en coordenadas del padre).
    func update(groove g: Groove, mode: Mode, targetX: CGFloat, dt rawDt: Double, now: Double, calm: Bool) {
        let dt = CGFloat(max(0.001, min(0.05, rawDt)))

        // Sigue al cabezal como un muelle (más ágil si lo llevas con el dedo).
        if calm {
            x = targetX
            vx = 0
        } else {
            let omega: CGFloat = mode == .carried ? 24 : 12
            vx += (omega * omega * (targetX - x) - 2 * omega * vx) * dt
            x += vx * dt
        }
        root.position = CGPoint(x: x, y: 0)

        // Qué está haciendo, con transiciones suaves.
        sitAmount = Self.approach(sitAmount, mode == .waiting ? 1 : 0, rate: 5, dt)
        carryAmount = Self.approach(carryAmount, mode == .carried ? 1 : 0, rate: 12, dt)
        runAmount = Self.approach(runAmount, abs(vx) > 70 && mode != .carried ? 1 : 0, rate: 10, dt)

        // El paso cae con el golpe que se oye (y a medio tiempo si el pulso va muy rápido para la canción).
        let (count, phase) = g.danceBeat
        // Lo fuerte de ahora pesa: en el estribillo se mueve más que en la estrofa.
        let amp = (0.6 + 0.55 * CGFloat(g.intensity)) * bounce * (calm ? 0.15 : 1)

        // El coreógrafo elige el paso de cada compás (y uno especial en los subidones).
        if mode == .dancing && !calm {
            if g.drop { choreographer.queueAccent() }
            if let next = choreographer.beat(count, groove: g) {
                Log.app.info("Bichito: \(next.name, privacy: .public)")
            }
        }
        var pose = choreographer.pose(count: count, phase: phase, amp: amp)

        // Encima del paso, reacciona a cada golpe que suena: el bombo lo hace rebotar, los platillos le mueven los brazos.
        if mode == .dancing && !calm {
            let soften = 1 - 0.7 * pose.sad   // triste, apenas se inmuta
            let kick = CGFloat(g.kick) * soften
            let snap = CGFloat(g.snap) * soften
            pose.squash += 0.16 * kick
            pose.lift -= 0.9 * kick
            pose.armL += 0.3 * snap
            pose.armR += 0.3 * snap
            pose.closed = min(1, pose.closed + 0.25 * snap)
        }

        if sitAmount > 0.001 { pose = pose.mixed(with: sitting(now: now), sitAmount) }
        if runAmount > 0.001 { pose = pose.mixed(with: running(from: pose, now: now), runAmount) }
        if carryAmount > 0.001 { pose = pose.mixed(with: carried(), carryAmount) }
        let reactT = (now - reactStart) / C.reactDuration
        if reactT >= 0 && reactT < 1 && mode != .carried {
            pose = pose.mixed(with: laughing(from: pose, t: reactT), min(1, CGFloat(sin(.pi * reactT)) * 1.6))
        }

        if now > nextBlink {
            blinkUntil = now + 0.12
            nextBlink = now + Double.random(in: 2.2...5)
        }
        if now < blinkUntil { pose.closed = 1 }

        apply(pose, dt: dt, now: now)
    }

    // MARK: - Poses fuera del baile

    /// En pausa: sentado, respirando, mirando el botón de play (y de vez en cuando a ti).
    private func sitting(now: Double) -> CritterPose {
        var sit = CritterPose()
        sit.lift = -2.8
        sit.footL = CGPoint(x: -7, y: 0)
        sit.footR = CGPoint(x: 7, y: 0)
        sit.armL = 0.3
        sit.armR = 0.3
        sit.bend = 0.6
        sit.squash = 0.03 * CGFloat(sin(2 * .pi * now / 3.5))
        sit.tilt = 0.03 * CGFloat(sin(now * 0.9))
        if now > nextGlance {
            glanceUntil = now + 1.4
            nextGlance = now + Double.random(in: 5...9)
        }
        sit.look = now < glanceUntil ? CGPoint(x: 0, y: -0.1) : CGPoint(x: 1, y: 0.25)
        return sit
    }

    /// Corriendo (cuando la canción salta lejos, por ejemplo al cambiar de canción).
    private func running(from base: CritterPose, now: Double) -> CritterPose {
        let r = now * 13
        let direction: CGFloat = vx >= 0 ? 1 : -1
        var run = base
        run.tilt = -0.22 * direction
        run.footL = CGPoint(x: -4.6 + 1.8 * CGFloat(cos(r)), y: CGFloat(max(0, sin(r))) * 2)
        run.footR = CGPoint(x: 4.6 - 1.8 * CGFloat(cos(r)), y: CGFloat(max(0, -sin(r))) * 2)
        run.armL = 0.7 + 0.5 * CGFloat(sin(r))
        run.armR = 0.7 - 0.5 * CGFloat(sin(r))
        run.lift = 0.8 * CGFloat(abs(sin(r)))
        run.squash = 0
        run.look = CGPoint(x: direction, y: 0)
        run.closed = 0
        return run
    }

    /// Colgado de tu dedo mientras lo arrastras por la canción.
    private func carried() -> CritterPose {
        var carry = CritterPose()
        carry.lift = 4
        carry.armL = 3
        carry.armR = 3
        carry.bend = 0.2
        let lag = max(-3, min(3, -vx * 0.008))
        carry.footL = CGPoint(x: -3 + lag, y: 3.2)
        carry.footR = CGPoint(x: 3 + lag, y: 3.2)
        carry.tilt = max(-0.3, min(0.3, -vx * 0.003))
        carry.look = CGPoint(x: 0, y: 1)
        carry.open = 0.7
        return carry
    }

    /// Le hiciste cosquillas: salta, se ríe con los ojos cerrados y se menea.
    private func laughing(from base: CritterPose, t: Double) -> CritterPose {
        var laugh = base
        laugh.lift = max(0, base.lift) + 2.6 * CGFloat(sin(.pi * t))
        laugh.tilt = 0.2 * CGFloat(sin(t * 28))
        laugh.armL = 2.6
        laugh.armR = 2.6
        laugh.closed = 1
        laugh.open = 1
        laugh.sad = 0
        return laugh
    }

    // MARK: - Dibujo

    private func apply(_ pose: CritterPose, dt: CGFloat, now: Double) {
        let w = C.bodyWidth, h = C.bodyHeight
        let lift = min(C.maxLift, pose.lift)
        let sy = 1 - pose.squash
        var sx = (1 + pose.squash * 0.6) * pose.spin
        let facing: CGFloat = sx < 0 ? -1 : 1
        if abs(sx) < 0.05 { sx = 0.05 * facing }   // de perfil a mitad del giro, sin desaparecer
        let center = CGPoint(x: pose.shiftX, y: C.groundY + C.legLength + h / 2 * sy + lift)
        let m = CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(rotationAngle: pose.tilt))
        torso.position = center
        torso.setAffineTransform(m)
        func world(_ local: CGPoint) -> CGPoint { center + local.applying(m) }

        // Patitas: de la cadera al pie; las rodillas se doblan más cuanto más se agacha.
        let hipL = world(CGPoint(x: -4, y: -h / 2 + 1))
        let hipR = world(CGPoint(x: 4, y: -h / 2 + 1))
        let footL = CGPoint(x: pose.shiftX * 0.4 + pose.footL.x, y: C.groundY + pose.footL.y)
        let footR = CGPoint(x: pose.shiftX * 0.4 + pose.footR.x, y: C.groundY + pose.footR.y)
        let legPathL = Self.limb(from: hipL, to: footL, bend: Self.knee(hipL, footL), toward: CGPoint(x: -1, y: 0))
        let legPathR = Self.limb(from: hipR, to: footR, bend: Self.knee(hipR, footR), toward: CGPoint(x: 1, y: 0))
        legBorderL.path = legPathL
        legL.path = legPathL
        legBorderR.path = legPathR
        legR.path = legPathR
        shoeL.position = CGPoint(x: footL.x - 0.6, y: footL.y + 0.4)
        shoeR.position = CGPoint(x: footR.x + 0.6, y: footR.y + 0.4)

        // Bracitos: salen de los hombros con el ángulo de la pose (giran con el cuerpo).
        let arms = [(armL, armBorderL, handL, CGFloat(-1), pose.armL), (armR, armBorderR, handR, CGFloat(1), pose.armR)]
        for (arm, border, hand, side, angle) in arms {
            let shoulder = world(CGPoint(x: side * (w / 2 - 1.4), y: -0.6))
            let direction = CGPoint(x: side * facing * sin(angle), y: -cos(angle)).rotated(by: pose.tilt)
            let end = shoulder + direction * C.armLength
            let path = Self.limb(from: shoulder, to: end, bend: pose.bend * 1.6, toward: CGPoint(x: side * facing, y: -1))
            border.path = path
            arm.path = path
            hand.position = end
        }

        // Antenas con muelle (triste, se le caen hacia los lados).
        let sad = max(0, min(1, pose.sad))
        let baseL = world(CGPoint(x: -2.8, y: h / 2 - 1.4))
        let baseR = world(CGPoint(x: 2.8, y: h / 2 - 1.4))
        let tipX = Self.tipRest.x + 1.4 * sad, tipY = Self.tipRest.y - 2.6 * sad
        let restL = CGPoint(x: -facing * tipX, y: tipY).rotated(by: pose.tilt)
        let restR = CGPoint(x: facing * tipX, y: tipY).rotated(by: pose.tilt)
        let tipPointL = baseL + feelerL.step(base: baseL, rest: restL, dt: dt)
        let tipPointR = baseR + feelerR.step(base: baseR, rest: restR, dt: dt)
        let curl: CGFloat = curly ? 1.6 : 0.5
        let antennaPathL = Self.limb(from: baseL, to: tipPointL, bend: curl, toward: CGPoint(x: -facing, y: 0.2))
        let antennaPathR = Self.limb(from: baseR, to: tipPointR, bend: curl, toward: CGPoint(x: facing, y: 0.2))
        antennaBorderL.path = antennaPathL
        antennaL.path = antennaPathL
        antennaBorderR.path = antennaPathR
        antennaR.path = antennaPathR
        tipL.position = tipPointL
        tipR.position = tipPointR

        // Cara. El párpado aplasta ojo y pupila juntos: entrecerrados se sigue viendo la mirada; cerrados, la línea.
        let closed = max(0, min(1, pose.closed))
        let lid = 1 - 0.85 * closed
        let eyeScale = CGAffineTransform(scaleX: 1, y: lid)
        eyeL.setAffineTransform(eyeScale)
        eyeR.setAffineTransform(eyeScale)
        pupilL.setAffineTransform(eyeScale)
        pupilR.setAffineTransform(eyeScale)
        let lookX = max(-1, min(1, pose.look.x)), lookY = max(-1, min(1, pose.look.y))
        pupilL.position = CGPoint(x: -Self.eyeX + lookX * 1.1, y: Self.eyeY - 0.2 + lookY * 1.2 * lid)
        pupilR.position = CGPoint(x: Self.eyeX + lookX * 1.1, y: Self.eyeY - 0.2 + lookY * 1.2 * lid)
        let pupilOpacity = Float(max(0, min(1, (0.85 - closed) / 0.3)))
        pupilL.opacity = pupilOpacity
        pupilR.opacity = pupilOpacity
        let open = max(0, min(1, pose.open))
        smile.opacity = Float(1 - open)
        mouth.opacity = open > 0.05 ? 1 : 0
        mouth.setAffineTransform(CGAffineTransform(scaleX: 0.4 + 0.6 * open, y: 0.3 + 0.7 * open))
        // La sonrisa se da vuelta cuando está triste; aparecen las cejas de pena.
        let corner: CGFloat = -2.8 - 0.7 * sad
        let mouthPath = CGMutablePath()
        mouthPath.move(to: CGPoint(x: -1.9 + 0.3 * sad, y: corner))
        mouthPath.addQuadCurve(to: CGPoint(x: 1.9 - 0.3 * sad, y: corner), control: CGPoint(x: 0, y: -4.4 + 3.2 * sad))
        smile.path = mouthPath
        browL.opacity = Float(sad)
        browR.opacity = Float(sad)
        // De vez en cuando, una lagrimita baja por la mejilla.
        if sad > 0.7 && now > nextTear {
            tearStart = now
            nextTear = now + Double.random(in: 6...10)
        }
        let tearT = (now - tearStart) / 1.3
        if tearT >= 0 && tearT < 1 {
            let t = CGFloat(tearT)
            let tearX: CGFloat = -Self.eyeX - 1.7 - 0.3 * t
            let tearY: CGFloat = Self.eyeY - 2.4 - 4 * t * t
            let fade: CGFloat = t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / 0.85
            tear.position = CGPoint(x: tearX, y: tearY)
            tear.opacity = Float(fade)
        } else if tear.opacity != 0 {
            tear.opacity = 0
        }

        // Sombra: se achica cuando está en el aire.
        let air = max(0, min(1, lift / 4))
        shadow.position = CGPoint(x: pose.shiftX * 0.5, y: C.groundY - 0.2)
        shadow.setAffineTransform(CGAffineTransform(scaleX: 1 - 0.35 * air, y: 1))
        shadow.opacity = Float(0.35 * (1 - 0.5 * air))

        // Al aparecer, sale del suelo con un rebote.
        let popT = (now - popStart) / C.popDuration
        let scale = popT < 1 ? Self.easeOutBack(CGFloat(max(0, popT))) : 1
        root.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: - Utilidades

    private static func ellipse(width: CGFloat, height: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), transform: nil)
    }

    /// Patita, bracito o antena: curva de `a` a `b` con la rodilla o el codo hacia `toward`.
    private static func limb(from a: CGPoint, to b: CGPoint, bend: CGFloat, toward: CGPoint) -> CGPath {
        let d = b - a
        let length = max(0.001, d.length)
        var normal = CGPoint(x: -d.y / length, y: d.x / length)
        if normal.x * toward.x + normal.y * toward.y < 0 { normal = normal * -1 }
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let path = CGMutablePath()
        path.move(to: a)
        path.addQuadCurve(to: b, control: middle + normal * bend)
        return path
    }

    /// Cuánto se dobla la rodilla: más cuanto más cerca quedan la cadera y el pie.
    private static func knee(_ hip: CGPoint, _ foot: CGPoint) -> CGFloat {
        0.6 + max(0, C.legLength + 0.8 - (hip - foot).length) * 0.9
    }

    private static func approach(_ value: CGFloat, _ target: CGFloat, rate: CGFloat, _ dt: CGFloat) -> CGFloat {
        value + (target - value) * min(1, rate * dt)
    }

    private static func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}

private extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    var length: CGFloat { hypot(x, y) }
    func rotated(by angle: CGFloat) -> CGPoint {
        CGPoint(x: x * cos(angle) - y * sin(angle), y: x * sin(angle) + y * cos(angle))
    }
}
