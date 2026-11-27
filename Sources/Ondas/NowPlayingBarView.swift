import AppKit
import QuartzCore

private typealias S = Theme.Size

/// Diseño «D · Ondas en barras», a toda la Touch Bar.
/// - Con música: foto, canción y grupo con «Me gusta», un espectro que también es la barra de progreso,
///   controles con efecto y un fondo que se ilumina con los colores de la portada al ritmo de la canción.
///   Deslizar el dedo sobre la canción cambia a la siguiente (izquierda) o a la anterior (derecha).
///   Un bichito hace de cabezal y baila según la canción (ver `Critter`).
/// - En reposo (con la X, sin música o en pausa un rato): hora y fecha, clima, «Sonando ahora» y batería.
/// - Siempre: teclas propias de brillo y volumen (el silencio va dentro del volumen), ondas al escribir
///   y una ola verde al enchufar el cargador.
/// Medidas en puntos (la Touch Bar es @2x: 1 pt = 2 px).
final class NowPlayingBarView: NSView {

    // MARK: - Acciones

    /// La barra aparece o desaparece de la Touch Bar.
    var onVisibilityChange: ((Bool) -> Void)?
    var onOpenSpotify: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onTogglePlay: (() -> Void)?
    var onNext: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onToggleLike: (() -> Void)?
    var onOpenCalendar: (() -> Void)?
    var onOpenWeather: (() -> Void)?
    /// Brillo y volumen del Mac.
    var system: SystemControls? {
        didSet { systemChanged() }
    }

    /// Estado del corazón de "Me gusta".
    enum LikeState { case unavailable, unknown, liked, notLiked }

    // MARK: - Estado

    private var nowPlaying = NowPlaying()
    private var palette = Palette.fallback
    private var playedColors: [CGColor] = []
    private var upcomingColors: [CGColor] = []
    private var hasArtwork = false
    private var currentArtwork: CGImage?
    private var pressed: Zone?
    private var activeTouch: (NSObjectProtocol & NSCopying)?
    private var scrubRatio: CGFloat?
    private var lastFrameTime: CFTimeInterval = 0
    private var phase: Double = 0
    private var beat: CGFloat = 0
    private var energy: CGFloat = 0.06
    private var likeState: LikeState = .unavailable
    private var heights: [CGFloat] = []
    private var shownElapsed = ""
    private var shownRemaining = ""
    private var shownScrubbing = false
    private var shownClock = ""
    private var shownDate = ""
    private var shownIdle: Bool?
    private var pausedSince: Date?
    /// Tocaste la X con música: se ve el reposo aunque siga sonando.
    private var forcedIdle = false
    private var weatherReport: WeatherService.Report?
    private var idleLayout = IdleLayout()
    private var swipe: Swipe?
    /// Tras cambiar de canción deslizando: la nueva entra por el lado contrario cuando llega (o al rato).
    private var swipeReveal: (from: CGFloat, trackID: String, deadline: CFTimeInterval)?
    private var charge: Charge?
    /// El bichito que baila sobre la barra de progreso (menú ≋ → «Bichito bailando»).
    var critterEnabled = true
    /// Solo para revisar el diseño: fija lo que hace el bichito (bailar, sentado o colgado) diga lo que diga la música.
    var critterPreviewMode: Critter.Mode?
    /// Solo para revisar el diseño: hace sus pasos especiales seguidos.
    var critterPreviewMoves: Bool {
        get { critter.previewMoves }
        set { critter.previewMoves = newValue }
    }
    private let critter = Critter()
    private var critterShown = false
    /// El dedo empezó sobre el bichito: si no lo mueves es un toque (se ríe); si lo arrastras, te lo llevas.
    private var critterTap: CGFloat?
    private var geometry = Geometry(width: S.barWidth, barCenter: NowPlayingBarView.estimatedBarCenter)
    /// Antes de mostrarse: la vista empieza después de la X y su separación.
    private static let estimatedBarCenter = S.touchBarWidth / 2 - S.closeWidth - Theme.Space.small
    private var adjusting: Adjust?
    private var adjustDrag: AdjustDrag?
    private var closeSliderWork: DispatchWorkItem?
    private var symbols: [String: CGImage] = [:]
    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMM")
        return formatter
    }()
    /// «18°» en la unidad de tu Mac (°C o °F).
    private let temperatureFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.locale = .current
        formatter.unitOptions = .temperatureWithoutUnit
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()

    /// Color y brillo actuales del fondo, para que la X se ilumine igual (verde durante la ola de carga).
    var pulseColor: CGColor { charge != nil ? Theme.Colors.chargeDeep.cgColor : palettePulse }
    private var palettePulse: CGColor = Palette.fallback.primary.cgColor
    private(set) var pulseOpacity: Float = 0
    /// Ancho de la ventana de la canción (para mover su borde difuminado).
    private var infoClipWidth: CGFloat = 1

    private enum Zone {
        case info, heart, scrub, previous, play, next, brightness, volume, sliderIcon, sliderTrack, sliderDone
        case clock, weather, resume
    }
    private enum Adjust { case brightness, volume }
    private struct AdjustDrag {
        let startX: CGFloat
        let startValue: Float
        var moved: Bool
    }
    /// Dedo sobre la canción: es un toque hasta que se mueve más de `Gesture.slop`.
    private struct Swipe {
        let startX: CGFloat
        var dx: CGFloat = 0
        var active = false
        /// Pasó el umbral: al soltar cambia de canción.
        var armed = false
    }
    /// Ola verde al enchufar el cargador.
    private struct Charge {
        let start: CFTimeInterval
        let level: Int
        /// Solo para revisar el diseño: se queda hasta tocar la barra.
        let hold: Bool
        var shownPercent = -1
    }
    /// Reposo: dónde quedan la hora, el clima y la pastilla (cambia con lo que miden sus textos).
    private struct IdleLayout {
        var clock = CGRect.zero
        /// Vacío mientras no hay clima.
        var weather = CGRect.zero
        var resume = CGRect.zero
    }

    /// Posiciones según el ancho que da macOS. La barra de música queda centrada en la Touch Bar;
    /// las teclas de brillo y volumen van pegadas a la derecha.
    private struct Geometry {
        let width: CGFloat
        /// Centro de la Touch Bar medido desde el borde izquierdo de esta vista.
        let barCenter: CGFloat
        var textX: CGFloat { S.artwork + Theme.Space.small }
        var textEnd: CGFloat { textX + S.textWidth }
        var heart: CGRect { CGRect(x: textEnd, y: 0, width: S.heartZone, height: S.barHeight) }
        var elapsedX: CGFloat { heart.maxX + Theme.Space.medium }
        var spectrumX: CGFloat { elapsedX + S.timeWidth + Theme.Space.small }
        var volumeKey: CGRect { CGRect(x: width - S.edgeMargin - S.keyZone, y: 0, width: S.keyZone, height: S.barHeight) }
        var brightnessKey: CGRect { CGRect(x: volumeKey.minX - S.keyGap - S.keyZone, y: 0, width: S.keyZone, height: S.barHeight) }
        /// Tiempo restante + controles + separación mínima con las teclas.
        private var rightBlock: CGFloat {
            Theme.Space.small + S.timeWidth + Theme.Space.medium + S.transportButton * 2 + S.playButton + Theme.Space.medium
        }
        var spectrumWidth: CGFloat {
            let centered = 2 * (barCenter - spectrumX)
            let available = brightnessKey.minX - rightBlock - spectrumX
            return max(120, min(centered, available))
        }
        var remainingX: CGFloat { spectrumX + spectrumWidth + Theme.Space.small }
        var controlsX: CGFloat { remainingX + S.timeWidth + Theme.Space.medium }
        var previous: CGRect { CGRect(x: controlsX, y: 0, width: S.transportButton, height: S.barHeight) }
        var play: CGRect { CGRect(x: previous.maxX, y: 0, width: S.playButton, height: S.barHeight) }
        var next: CGRect { CGRect(x: play.maxX, y: 0, width: S.transportButton, height: S.barHeight) }
        // Deslizador de brillo o volumen (ocupa toda la barra).
        var sliderIcon: CGRect { CGRect(x: 0, y: 0, width: S.keyZone, height: S.barHeight) }
        var sliderDone: CGRect { volumeKey }
        var sliderValue: CGRect {
            CGRect(x: sliderDone.minX - Theme.Space.small - S.sliderValueWidth, y: 0, width: S.sliderValueWidth, height: S.barHeight)
        }
        var sliderTrack: CGRect {
            let x = sliderIcon.maxX + Theme.Space.medium
            return CGRect(x: x, y: (S.barHeight - S.sliderTrack) / 2, width: sliderValue.minX - Theme.Space.medium - x, height: S.sliderTrack)
        }
        // Reposo: la batería va junto a las teclas; el resto se centra en `layoutIdle()`.
        var battery: CGRect {
            CGRect(x: brightnessKey.minX - Theme.Space.medium - S.batteryWidth, y: 0, width: S.batteryWidth, height: S.barHeight)
        }
    }

    // MARK: - Capas

    private let pulse = CAGradientLayer()
    private let playerGroup = CALayer()
    private let idleGroup = CALayer()
    private let keysGroup = CALayer()
    private let sliderGroup = CALayer()
    // Con música.
    private let glow = CALayer()
    private let glowFade = CAGradientLayer()
    /// Ventana con bordes difuminados donde se desliza la canción (foto, nombre y corazón).
    private let infoClip = CALayer()
    private let infoClipMask = CAGradientLayer()
    private let infoGroup = CALayer()
    private let swipeHint = CALayer()
    private let halo = CALayer()
    private let art = CALayer()
    private let artPlaceholder = CALayer()
    /// Lleva la sombra oscura que hace legible el texto sobre el color.
    private let textBlock = CALayer()
    /// Recorta con desvanecido los nombres largos.
    private let textInner = CALayer()
    private let textFade = CAGradientLayer()
    private let titleBox = CALayer()
    private let titleGradient = CAGradientLayer()
    private let titleText = CATextLayer()
    private let artistText = CATextLayer()
    private let heartIcon = CALayer()
    private let elapsedText = CATextLayer()
    private let remainingText = CATextLayer()
    private let spectrum = CALayer()
    private var bars: [CALayer] = []
    private let playhead = CALayer()
    private let knob = CALayer()
    private let previousIcon = CALayer()
    private let nextIcon = CALayer()
    private let playRing = CALayer()
    private let playDisc = CALayer()
    private let playIcon = CALayer()
    private var playImage: CGImage?
    private var pauseImage: CGImage?
    // Reposo.
    private let clockText = CATextLayer()
    private let dateText = CATextLayer()
    private let weatherIcon = CALayer()
    private let weatherTemp = CATextLayer()
    private let weatherSummary = CATextLayer()
    private let resumePill = CALayer()
    private let resumeArt = CALayer()
    private let resumeCaption = CATextLayer()
    private let resumeTitle = CATextLayer()
    private let resumeIcon = CALayer()
    private let batteryIcon = CALayer()
    private let batteryText = CATextLayer()
    // Teclas de brillo y volumen.
    private let brightnessKey = CALayer()
    private let brightnessLevel = CALayer()
    private let brightnessIcon = CALayer()
    private let volumeKey = CALayer()
    private let volumeLevel = CALayer()
    private let volumeIcon = CALayer()
    // Deslizador.
    private let sliderIconKey = CALayer()
    private let sliderIcon = CALayer()
    private let sliderTrackLayer = CALayer()
    private let sliderFill = CAGradientLayer()
    private let sliderKnob = CALayer()
    private let sliderValueText = CATextLayer()
    private let sliderDoneKey = CALayer()
    private let sliderDoneIcon = CALayer()
    // Carga: ola verde con borde brillante, rayo y %.
    private let chargeGroup = CALayer()
    private let chargeFill = CAGradientLayer()
    private let chargeShape = CAShapeLayer()
    private let chargeEdge = CAShapeLayer()
    private let chargeIcon = CALayer()
    private let chargeText = CATextLayer()

    // MARK: - Ciclo de vida

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: S.barWidth, height: S.barHeight))
        let root = CALayer()
        root.backgroundColor = Theme.Colors.background.cgColor
        root.masksToBounds = false   // el color se sale un poco para tapar las juntas
        root.contentsScale = Theme.scale
        layer = root
        wantsLayer = true
        allowedTouchTypes = [.direct]
        translatesAutoresizingMaskIntoConstraints = false
        let preferred = widthAnchor.constraint(equalToConstant: S.barWidth)
        preferred.priority = .defaultHigh
        preferred.isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: S.barMinWidth).isActive = true
        heightAnchor.constraint(equalToConstant: S.barHeight).isActive = true
        setAccessibilityRole(.group)
        buildLayers(in: root)
        layoutLayers()
        applyNowPlaying(animated: false)
        applyPalette(animated: false)
        applyMode(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: S.barWidth, height: S.barHeight)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        let center = currentBarCenter()
        if abs(bounds.width - geometry.width) > 0.5 || abs(center - geometry.barCenter) > 0.5 {
            let width = bounds.width
            geometry = Geometry(width: width, barCenter: center)
            Log.app.notice("Barra: ancho \(Int(width), privacy: .public) pt · centro \(Int(center), privacy: .public) pt")
            layoutLayers()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onVisibilityChange?(window != nil)
        needsLayout = true
    }

    /// Centro de la Touch Bar en coordenadas de esta vista.
    private func currentBarCenter() -> CGFloat {
        guard window != nil else { return Self.estimatedBarCenter }
        let origin = convert(NSPoint.zero, to: nil).x
        return S.touchBarWidth / 2 - origin
    }

    // MARK: - API

    func update(nowPlaying next: NowPlaying) {
        let hadTrack = nowPlaying.hasTrack
        // Cada canción le da al bichito su personalidad (paso especial, antenas, cuánto rebota).
        if next.trackID != nowPlaying.trackID { critter.setSong(next.trackID) }
        if next.isPlaying {
            pausedSince = nil
        } else if pausedSince == nil || next.trackID != nowPlaying.trackID {
            pausedSince = Date()
        }
        nowPlaying = next
        applyNowPlaying(animated: true)
        if hadTrack != next.hasTrack { applyPalette(animated: true) }
        // Cambiaste de canción deslizando: la nueva entra en cuanto llega.
        if let reveal = swipeReveal, next.trackID != reveal.trackID { revealInfo() }
    }

    func setArtwork(_ image: CGImage?, palette newPalette: Palette, glow glowImage: CGImage?) {
        hasArtwork = image != nil
        currentArtwork = image
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Motion.colorChange)
        art.contents = image
        art.backgroundColor = (image == nil ? Theme.Colors.placeholder : NSColor.clear).cgColor
        artPlaceholder.opacity = image == nil ? 1 : 0
        resumeArt.contents = image
        glow.contents = glowImage
        CATransaction.commit()
        palette = newPalette
        rebuildBarColors()
        applyPalette(animated: true)
    }

    /// La X: con música pasa a reposo (true); en reposo deja que se cierre Ondas (false).
    func handleClose() -> Bool {
        guard !isIdle else { return false }
        forcedIdle = true
        applyResume()
        applyMode(animated: true)
        return true
    }

    /// Al volver a mostrar la barra, empieza por la canción si está sonando.
    func resetMode() {
        forcedIdle = false
        swipe = nil
        swipeReveal = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        infoGroup.transform = CATransform3DIdentity
        infoGroup.opacity = 1
        setInfoEdge(0)
        swipeHint.opacity = 0
        CATransaction.commit()
        applyResume()
        applyMode(animated: false)
    }

    /// El clima de la pantalla de reposo (nil = no se muestra y la hora y la música se vuelven a centrar).
    func setWeather(_ report: WeatherService.Report?) {
        let changed = report?.symbol != weatherReport?.symbol || report?.summary != weatherReport?.summary
            || report.map(temperatureText) != weatherReport.map(temperatureText)
        weatherReport = report
        guard changed else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let report {
            weatherTemp.string = temperatureText(report)
            weatherSummary.string = report.summary
            LayerKit.paint(weatherIcon, symbol: report.symbol, pointSize: 19, weight: .semibold, color: Theme.Colors.icon)
        }
        CATransaction.commit()
        layoutIdle(animated: shownIdle == true && window != nil)
    }

    private func temperatureText(_ report: WeatherService.Report) -> String {
        // Sin «-0°» cuando ronda el cero.
        let celsius = abs(report.temperature) < 0.5 ? 0 : report.temperature
        return temperatureFormatter.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
    }

    /// Al enchufar el cargador: una ola verde llena la barra hasta tu % de batería y vuelve sola a lo de antes.
    /// No sale si estás tocando la barra o con el deslizador abierto.
    func showCharging(level: Int, hold: Bool = false) {
        guard window != nil, adjusting == nil, activeTouch == nil else { return }
        charge = Charge(start: CACurrentMediaTime(), level: max(0, min(100, level)), hold: hold)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateCharge(now: CACurrentMediaTime())
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        CATransaction.setAnimationDuration(Theme.Motion.sliderFade)
        playerGroup.opacity = 0
        idleGroup.opacity = 0
        keysGroup.opacity = 0
        chargeGroup.opacity = 1
        CATransaction.commit()
    }

    /// Solo para revisar el diseño: deja la canción a medio deslizar hacia la siguiente.
    func previewSwipe() {
        guard nowPlaying.hasTrack, !isIdle else { return }
        showSwipe(dx: -(Theme.Gesture.threshold + 8), armedNow: false)
    }

    func setBattery(level: Int?, charging: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard let level else {
            batteryIcon.opacity = 0
            batteryText.string = ""
            CATransaction.commit()
            return
        }
        let symbol: String
        switch level {
        case _ where charging: symbol = "battery.100.bolt"
        case 88...: symbol = "battery.100"
        case 63..<88: symbol = "battery.75"
        case 38..<63: symbol = "battery.50"
        case 13..<38: symbol = "battery.25"
        default: symbol = "battery.0"
        }
        batteryIcon.opacity = 1
        batteryIcon.backgroundColor = (level < 20 && !charging ? NSColor(hex: 0xFF8A7A) : Theme.Colors.icon).cgColor
        setSymbol(batteryIcon, symbol)
        batteryText.string = "\(level) %"
        CATransaction.commit()
    }

    /// Brillo o volumen cambiaron (desde Ondas o desde el teclado).
    func systemChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let brightness = CGFloat(system?.brightness ?? 0)
        brightnessLevel.frame = CGRect(x: 0, y: 0, width: S.keyWidth, height: S.keyHeight * brightness)
        setSymbol(brightnessIcon, brightness < 0.5 ? "sun.min.fill" : "sun.max.fill")
        brightnessKey.opacity = (system?.canChangeBrightness ?? false) ? 1 : 0.32
        let muted = system?.isMuted ?? false
        let volume = muted ? 0 : CGFloat(system?.volume ?? 0)
        volumeLevel.frame = CGRect(x: 0, y: 0, width: S.keyWidth, height: S.keyHeight * volume)
        setSymbol(volumeIcon, volumeSymbol())
        CATransaction.commit()
        updateSlider()
    }

    /// Avanza un fotograma. `levels`: bandas reales (0…1) o nil si no llega audio.
    /// `pulse`: el pulso de la canción (lo fuerte que suena y sus golpes), 0…1.
    /// `groove`: tempo y carácter de la canción, para el baile del bichito.
    func tick(levels: [Float]?, pulse level: CGFloat, groove: Groove, now: CFTimeInterval) {
        let dt = lastFrameTime == 0 ? 1.0 / 60 : min(0.05, max(0, now - lastFrameTime))
        lastFrameTime = now
        let playing = nowPlaying.isPlaying && nowPlaying.hasTrack
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        phase += dt * (playing ? 1 : 0.25)
        beat = playing ? level : 0
        let energyTarget: CGFloat = playing ? 0.35 + 0.55 * beat + 0.10 * CGFloat(sin(phase * 1.3)) : 0.06
        energy += (energyTarget - energy) * CGFloat(min(1, dt * 12))

        let idle = isIdle
        if idle != shownIdle { applyMode(animated: true) }
        if let reveal = swipeReveal, now > reveal.deadline { revealInfo() }

        let ratio: CGFloat
        if let scrubRatio {
            ratio = scrubRatio
        } else if nowPlaying.duration > 0 {
            ratio = CGFloat(nowPlaying.position(at: Date()) / nowPlaying.duration)
        } else {
            ratio = 0
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // El fondo: late con la canción; en reposo respira despacio.
        if idle {
            let breath = calm ? 0 : sin(now * 2 * .pi / Theme.Idle.breathPeriod)
            pulseOpacity = 0.11 + 0.05 * Float(breath)
        } else if nowPlaying.hasTrack {
            pulseOpacity = playing ? Theme.Pulse.resting + (Theme.Pulse.peak - Theme.Pulse.resting) * Float(beat) : Theme.Pulse.paused
        } else {
            pulseOpacity = 0
        }
        // Durante la ola verde, la X y su junta con la barra se pintan del mismo verde (la barra no se sale de su sitio).
        if charge != nil { pulseOpacity = 1 }
        let drift = calm ? 0 : 0.12 * sin(phase * 0.5)
        pulse.locations = [0, 0.25 + drift, 0.5 + drift, 0.75 + drift, 1].map { NSNumber(value: $0) }
        pulse.opacity = pulseOpacity

        if idle {
            updateClock()
        } else {
            updatePlayer(levels: playing ? levels : nil, ratio: ratio, dt: dt, playing: playing, calm: calm,
                         groove: groove, now: now)
        }
        if charge != nil { updateCharge(now: now) }
        sliderKnob.shadowOpacity = Float(0.5 + 0.4 * beat)
        CATransaction.commit()
    }

    private func updatePlayer(levels: [Float]?, ratio: CGFloat, dt: Double, playing: Bool, calm: Bool,
                              groove: Groove, now: CFTimeInterval) {
        updateBars(levels: levels, ratio: ratio, dt: dt, calm: calm)

        let x = ratio * spectrum.bounds.width
        playhead.position = CGPoint(x: x, y: S.barHeight / 2)
        knob.position = CGPoint(x: x, y: S.barHeight / 2)

        // El bichito hace de cabezal: baila donde va la canción (se queda dentro del espectro).
        let inset = Theme.Critter.edgeInset
        let target = max(inset, min(spectrum.bounds.width - inset, x))
        let showCritter = critterEnabled && nowPlaying.hasTrack
        if showCritter != critterShown {
            critterShown = showCritter
            critter.root.opacity = showCritter ? 1 : 0
            if showCritter { critter.popIn(at: target, now: now) }
        }
        playhead.opacity = nowPlaying.hasTrack && !showCritter ? 1 : 0
        knob.opacity = scrubRatio == nil || showCritter ? 0 : 1
        if showCritter {
            let mode = critterPreviewMode ?? (scrubRatio != nil ? .carried : (playing ? .dancing : .waiting))
            critter.update(groove: groove, mode: mode, targetX: target, dt: dt, now: now, calm: calm)
        }

        glow.opacity = Float(hasArtwork ? (playing ? 0.25 + 0.3 * beat : 0.15) : 0)
        halo.shadowOpacity = Float(playing && hasArtwork ? 0.6 : 0)
        halo.shadowRadius = 5 + 8 * beat
        let spread = 0.5 + 4 * beat
        let corner = Theme.Radius.artwork + spread
        halo.shadowPath = CGPath(roundedRect: halo.bounds.insetBy(dx: -spread, dy: -spread),
                                 cornerWidth: corner, cornerHeight: corner, transform: nil)
        let pressingArt = pressed == .info && swipe?.active != true
        let artScale: CGFloat = pressingArt ? 0.9 : 1 - 0.03 + 0.06 * beat
        art.transform = CATransform3DMakeScale(artScale, artScale, 1)
        halo.transform = art.transform
        let ring: CGFloat = 1 + 0.3 * beat
        playRing.transform = CATransform3DMakeScale(ring, ring, 1)
        playRing.opacity = playing ? 1 : 0

        if !calm {
            let shift = CGFloat((phase * Theme.Motion.shimmerSpeed).truncatingRemainder(dividingBy: 240))
            titleGradient.frame.origin.x = -shift
        }

        guard nowPlaying.hasTrack else { return }
        let position = Double(ratio) * nowPlaying.duration
        let elapsed = Self.clock(position)
        let remaining = "−" + Self.clock(max(0, nowPlaying.duration - position))
        if elapsed != shownElapsed {
            elapsedText.string = elapsed
            shownElapsed = elapsed
        }
        if remaining != shownRemaining {
            remainingText.string = remaining
            shownRemaining = remaining
        }
        let scrubbing = scrubRatio != nil
        if scrubbing != shownScrubbing {
            elapsedText.foregroundColor = (scrubbing ? Theme.Colors.title : Theme.Colors.time).cgColor
            shownScrubbing = scrubbing
        }
    }

    /// Hora y fecha; si cambian, el grupo del reposo se vuelve a centrar (cada bloque mide lo que su texto).
    private func updateClock() {
        let now = Date()
        let time = clockFormatter.string(from: now)
        let date = dateFormatter.string(from: now)
        guard time != shownClock || date != shownDate else { return }
        clockText.string = time
        dateText.string = date
        shownClock = time
        shownDate = date
        layoutIdle(animated: false)
    }

    /// En reposo cuando tocaste la X, cuando no hay canción o cuando lleva un rato en pausa.
    private var isIdle: Bool {
        if forcedIdle || !nowPlaying.hasTrack { return true }
        if !nowPlaying.isPlaying, let pausedSince, Date().timeIntervalSince(pausedSince) > Theme.Idle.after { return true }
        return false
    }

    private func applyMode(animated: Bool) {
        let idle = isIdle
        shownIdle = idle
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? Theme.Idle.crossfade : 0)
        CATransaction.setDisableActions(!animated)
        if adjusting == nil && charge == nil {
            playerGroup.opacity = idle ? 0 : 1
            idleGroup.opacity = idle ? 1 : 0
            keysGroup.opacity = 1
        }
        CATransaction.commit()
        setAccessibilityLabel(idle ? "Ondas: hora, clima y batería" : accessibilityTrackLabel())
    }

    // MARK: - Construcción

    private func buildLayers(in root: CALayer) {
        // Fondo de color que ocupa toda la barra (detrás de todo).
        pulse.startPoint = CGPoint(x: 0, y: 0.5)
        pulse.endPoint = CGPoint(x: 1, y: 0.5)
        pulse.opacity = 0
        LayerKit.add(pulse, to: root)
        LayerKit.add(playerGroup, to: root)
        LayerKit.add(idleGroup, to: root)
        LayerKit.add(keysGroup, to: root)
        sliderGroup.opacity = 0
        LayerKit.add(sliderGroup, to: root)

        buildPlayer()
        buildIdle()

        // Teclas propias de brillo y volumen (reemplazan la Control Strip).
        buildKey(brightnessKey, level: brightnessLevel, icon: brightnessIcon, in: keysGroup)
        buildKey(volumeKey, level: volumeLevel, icon: volumeIcon, in: keysGroup)

        // Deslizador de brillo o volumen.
        buildKey(sliderIconKey, level: nil, icon: sliderIcon, in: sliderGroup)
        sliderTrackLayer.backgroundColor = Theme.Colors.sliderTrack.cgColor
        sliderTrackLayer.cornerRadius = S.sliderTrack / 2
        sliderTrackLayer.masksToBounds = true
        LayerKit.add(sliderTrackLayer, to: sliderGroup)
        sliderFill.startPoint = CGPoint(x: 0, y: 0.5)
        sliderFill.endPoint = CGPoint(x: 1, y: 0.5)
        LayerKit.add(sliderFill, to: sliderTrackLayer)
        sliderKnob.bounds = CGRect(x: 0, y: 0, width: S.sliderKnob, height: S.sliderKnob)
        sliderKnob.cornerRadius = S.sliderKnob / 2
        sliderKnob.backgroundColor = NSColor.white.cgColor
        sliderKnob.shadowOffset = .zero
        sliderKnob.shadowRadius = 6
        sliderKnob.shadowOpacity = 0.5
        LayerKit.add(sliderKnob, to: sliderGroup)
        LayerKit.style(sliderValueText, font: Theme.Fonts.sliderValue, color: .white)
        sliderValueText.alignmentMode = .right
        applyTextShadow(to: sliderValueText)
        LayerKit.add(sliderValueText, to: sliderGroup)
        buildKey(sliderDoneKey, level: nil, icon: sliderDoneIcon, in: sliderGroup)

        buildCharge(in: root)
    }

    /// Ola verde de la carga: por encima de todo, con fondo negro para que el % se lea siempre.
    private func buildCharge(in root: CALayer) {
        chargeGroup.opacity = 0
        chargeGroup.backgroundColor = Theme.Colors.background.cgColor
        LayerKit.add(chargeGroup, to: root)
        chargeFill.startPoint = CGPoint(x: 0, y: 0.5)
        chargeFill.endPoint = CGPoint(x: 1, y: 0.5)
        chargeFill.colors = [Theme.Colors.chargeDeep, Theme.Colors.chargeMid].map { $0.cgColor }
        chargeShape.fillColor = NSColor.black.cgColor
        chargeFill.mask = chargeShape
        LayerKit.add(chargeFill, to: chargeGroup)
        chargeEdge.fillColor = nil
        chargeEdge.strokeColor = Theme.Colors.chargeEdge.cgColor
        chargeEdge.lineWidth = 2
        chargeEdge.lineCap = .round
        chargeEdge.lineJoin = .round
        chargeEdge.shadowColor = Theme.Colors.chargeEdge.cgColor
        chargeEdge.shadowOpacity = 0.9
        chargeEdge.shadowRadius = 6
        chargeEdge.shadowOffset = .zero
        LayerKit.add(chargeEdge, to: chargeGroup)
        chargeIcon.backgroundColor = NSColor.white.cgColor
        LayerKit.add(chargeIcon, to: chargeGroup)
        LayerKit.style(chargeText, font: Theme.Fonts.clock, color: .white)
        applyTextShadow(to: chargeText)
        LayerKit.add(chargeText, to: chargeGroup)
    }

    private func buildPlayer() {
        // Luz de la portada.
        glow.contentsGravity = .resizeAspectFill
        glow.opacity = 0
        glowFade.startPoint = CGPoint(x: 0, y: 0.5)
        glowFade.endPoint = CGPoint(x: 1, y: 0.5)
        glowFade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        glowFade.locations = [0, 0.25, 1]
        glow.mask = glowFade
        LayerKit.add(glow, to: playerGroup)

        // La canción (foto, nombre y corazón) va en una ventana con bordes difuminados:
        // al deslizarla con el dedo sale y entra por ahí, sin pisar la X ni los tiempos.
        infoClipMask.startPoint = CGPoint(x: 0, y: 0.5)
        infoClipMask.endPoint = CGPoint(x: 1, y: 0.5)
        infoClipMask.colors = [NSColor.clear, NSColor.black, NSColor.black, NSColor.clear].map { $0.cgColor }
        infoClip.mask = infoClipMask
        LayerKit.add(infoClip, to: playerGroup)
        LayerKit.add(infoGroup, to: infoClip)
        swipeHint.backgroundColor = Theme.Colors.icon.cgColor
        swipeHint.opacity = 0
        LayerKit.add(swipeHint, to: playerGroup)

        // Foto con halo.
        halo.cornerRadius = Theme.Radius.artwork
        halo.backgroundColor = NSColor.black.cgColor
        halo.shadowOffset = .zero
        halo.shadowOpacity = 0
        LayerKit.add(halo, to: infoGroup)
        art.cornerRadius = Theme.Radius.artwork
        art.masksToBounds = true
        art.contentsGravity = .resizeAspectFill
        art.borderWidth = 0.5
        art.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        art.backgroundColor = Theme.Colors.placeholder.cgColor
        LayerKit.add(art, to: infoGroup)
        artPlaceholder.frame = CGRect(x: 7.5, y: 7.5, width: 15, height: 15)
        LayerKit.paint(artPlaceholder, symbol: "music.note", pointSize: 13, weight: .semibold, color: Theme.Colors.artist)
        LayerKit.add(artPlaceholder, to: art)

        // Canción (degradado con los colores de la portada) y grupo.
        textFade.startPoint = CGPoint(x: 0, y: 0.5)
        textFade.endPoint = CGPoint(x: 1, y: 0.5)
        textFade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        textFade.locations = [0, 0.86, 1]
        textInner.mask = textFade
        applyTextShadow(to: textBlock)
        LayerKit.add(textBlock, to: infoGroup)
        LayerKit.add(textInner, to: textBlock)
        titleBox.masksToBounds = true
        LayerKit.add(titleBox, to: textInner)
        titleGradient.startPoint = CGPoint(x: 0, y: 0.5)
        titleGradient.endPoint = CGPoint(x: 1, y: 0.5)
        LayerKit.add(titleGradient, to: titleBox)
        LayerKit.style(titleText, font: Theme.Fonts.title, color: .white)
        titleBox.mask = titleText
        LayerKit.style(artistText, font: Theme.Fonts.artist, color: Theme.Colors.artist)
        LayerKit.add(artistText, to: textInner)

        // Corazón de "Me gusta".
        heartIcon.backgroundColor = NSColor.white.cgColor
        heartIcon.opacity = 0
        LayerKit.add(heartIcon, to: infoGroup)

        // Tiempos.
        LayerKit.style(elapsedText, font: Theme.Fonts.time, color: Theme.Colors.time)
        elapsedText.alignmentMode = .right
        applyTextShadow(to: elapsedText)
        LayerKit.add(elapsedText, to: playerGroup)
        LayerKit.style(remainingText, font: Theme.Fonts.time, color: Theme.Colors.time)
        remainingText.alignmentMode = .left
        applyTextShadow(to: remainingText)
        LayerKit.add(remainingText, to: playerGroup)

        // Espectro: también es la barra de progreso (las barras se crean al conocer el ancho).
        LayerKit.add(spectrum, to: playerGroup)
        playhead.bounds = CGRect(x: 0, y: 0, width: 1.5, height: S.playheadHeight)
        playhead.cornerRadius = 0.75
        playhead.backgroundColor = NSColor.white.cgColor
        playhead.shadowColor = NSColor.white.cgColor
        playhead.shadowOpacity = 0.9
        playhead.shadowRadius = 4
        playhead.shadowOffset = .zero
        LayerKit.add(playhead, to: spectrum)
        knob.bounds = CGRect(x: 0, y: 0, width: S.knob, height: S.knob)
        knob.cornerRadius = S.knob / 2
        knob.backgroundColor = NSColor.white.cgColor
        knob.borderWidth = 2
        knob.borderColor = NSColor(white: 0, alpha: 0.55).cgColor
        knob.opacity = 0
        LayerKit.add(knob, to: spectrum)
        // El bichito hace de cabezal (encima de las barras).
        critter.root.opacity = 0
        LayerKit.add(critter.root, to: spectrum)

        // Controles de la canción.
        LayerKit.add(previousIcon, to: playerGroup)
        LayerKit.add(nextIcon, to: playerGroup)
        playRing.opacity = 0
        LayerKit.add(playRing, to: playerGroup)
        LayerKit.add(playDisc, to: playerGroup)
        playImage = LayerKit.symbolImage("play.fill", pointSize: 13, weight: .bold)
        pauseImage = LayerKit.symbolImage("pause.fill", pointSize: 13, weight: .bold)
        playIcon.backgroundColor = Theme.Colors.onAccent.cgColor
        LayerKit.add(playIcon, to: playDisc)
    }

    private func buildIdle() {
        idleGroup.opacity = 0
        // Hora y fecha.
        LayerKit.style(clockText, font: Theme.Fonts.clock, color: .white)
        applyTextShadow(to: clockText)
        LayerKit.add(clockText, to: idleGroup)
        LayerKit.style(dateText, font: Theme.Fonts.date, color: Theme.Colors.artist)
        applyTextShadow(to: dateText)
        LayerKit.add(dateText, to: idleGroup)

        // Clima: mismo par de líneas que la hora (grande arriba, pequeña abajo).
        weatherIcon.bounds = CGRect(x: 0, y: 0, width: S.weatherIcon, height: S.weatherIcon)
        weatherIcon.opacity = 0
        LayerKit.add(weatherIcon, to: idleGroup)
        LayerKit.style(weatherTemp, font: Theme.Fonts.clock, color: .white)
        applyTextShadow(to: weatherTemp)
        weatherTemp.opacity = 0
        LayerKit.add(weatherTemp, to: idleGroup)
        LayerKit.style(weatherSummary, font: Theme.Fonts.date, color: Theme.Colors.artist)
        applyTextShadow(to: weatherSummary)
        weatherSummary.opacity = 0
        LayerKit.add(weatherSummary, to: idleGroup)

        // «Seguir escuchando» / «Abrir Spotify».
        resumePill.cornerRadius = Theme.Radius.close
        resumePill.backgroundColor = Theme.Colors.keyFill.cgColor
        resumePill.masksToBounds = true
        LayerKit.add(resumePill, to: idleGroup)
        resumeArt.cornerRadius = 5
        resumeArt.masksToBounds = true
        resumeArt.contentsGravity = .resizeAspectFill
        resumeArt.backgroundColor = Theme.Colors.placeholder.cgColor
        LayerKit.add(resumeArt, to: resumePill)
        LayerKit.style(resumeCaption, font: Theme.Fonts.resumeCaption, color: Theme.Colors.artist)
        LayerKit.add(resumeCaption, to: resumePill)
        LayerKit.style(resumeTitle, font: Theme.Fonts.resumeTitle, color: .white)
        LayerKit.add(resumeTitle, to: resumePill)
        resumeIcon.backgroundColor = Theme.Colors.icon.cgColor
        LayerKit.add(resumeIcon, to: resumePill)

        // Batería.
        batteryIcon.backgroundColor = Theme.Colors.icon.cgColor
        batteryIcon.opacity = 0
        LayerKit.add(batteryIcon, to: idleGroup)
        LayerKit.style(batteryText, font: Theme.Fonts.battery, color: Theme.Colors.artist)
        applyTextShadow(to: batteryText)
        LayerKit.add(batteryText, to: idleGroup)
    }

    private func buildKey(_ key: CALayer, level: CALayer?, icon: CALayer, in parent: CALayer) {
        key.cornerRadius = Theme.Radius.close
        key.backgroundColor = Theme.Colors.keyFill.cgColor
        key.masksToBounds = true
        LayerKit.add(key, to: parent)
        if let level { LayerKit.add(level, to: key) }
        icon.backgroundColor = Theme.Colors.icon.cgColor
        LayerKit.add(icon, to: key)
    }

    /// Coloca todo según `geometry` (cambia si macOS da otro ancho).
    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let g = geometry
        let bleed = S.glowBleed
        let full = CGRect(x: 0, y: 0, width: g.width, height: S.barHeight)

        pulse.frame = CGRect(x: -bleed, y: 0, width: g.width + bleed * 2, height: S.barHeight)
        playerGroup.frame = full
        idleGroup.frame = full
        keysGroup.frame = full
        sliderGroup.frame = full

        // Con música.
        glow.frame = CGRect(x: -16 - bleed, y: -32, width: 190 + bleed, height: 94)
        glowFade.frame = glow.bounds
        // Ventana de la canción: desde el borde izquierdo (con su sombra) hasta los tiempos, con bordes difuminados.
        let fade = Theme.Gesture.edgeFade
        let clipWidth = bleed + g.elapsedX + fade
        infoClip.frame = CGRect(x: -bleed, y: -S.barHeight, width: clipWidth, height: S.barHeight * 3)
        infoClipMask.frame = infoClip.bounds
        infoClipWidth = clipWidth
        setInfoEdge(0)
        LayerKit.place(infoGroup, in: CGRect(x: bleed, y: S.barHeight, width: g.elapsedX, height: S.barHeight))
        let artRect = CGRect(x: 0, y: 0, width: S.artwork, height: S.artwork)
        LayerKit.place(halo, in: artRect)
        LayerKit.place(art, in: artRect)
        textBlock.frame = CGRect(x: g.textX, y: 0, width: S.textWidth, height: S.barHeight)
        textInner.frame = textBlock.bounds
        textFade.frame = textInner.bounds
        titleBox.frame = LayerKit.textFrame(font: Theme.Fonts.title, baseline: Theme.Baseline.title, x: 0, width: S.textWidth)
        titleGradient.frame = CGRect(x: 0, y: 0, width: 480, height: titleBox.bounds.height)
        artistText.frame = LayerKit.textFrame(font: Theme.Fonts.artist, baseline: Theme.Baseline.artist, x: 0, width: 400)
        LayerKit.place(heartIcon, in: centered(S.heartIcon, in: g.heart))
        applyLike(animated: false)
        elapsedText.frame = LayerKit.textFrame(font: Theme.Fonts.time, baseline: Theme.Baseline.time, x: g.elapsedX, width: S.timeWidth)
        remainingText.frame = LayerKit.textFrame(font: Theme.Fonts.time, baseline: Theme.Baseline.time, x: g.remainingX, width: S.timeWidth)
        spectrum.frame = CGRect(x: g.spectrumX, y: 0, width: g.spectrumWidth, height: S.barHeight)
        rebuildBarsIfNeeded()
        for index in bars.indices {
            bars[index].frame = barFrame(index: index, height: heights[index])
        }
        let icon = S.transportIcon
        LayerKit.place(previousIcon, in: centered(icon, in: g.previous))
        LayerKit.paint(previousIcon, symbol: "backward.end.fill", pointSize: 16, weight: .semibold, color: Theme.Colors.icon)
        LayerKit.place(nextIcon, in: centered(icon, in: g.next))
        LayerKit.paint(nextIcon, symbol: "forward.end.fill", pointSize: 16, weight: .semibold, color: Theme.Colors.icon)
        let disc = centered(S.playDisc, in: g.play)
        LayerKit.place(playRing, in: disc)
        playRing.cornerRadius = S.playDisc / 2
        LayerKit.place(playDisc, in: disc)
        playDisc.cornerRadius = S.playDisc / 2
        placePlayIcon()

        // Reposo: el interior de la pastilla y la batería (hora, clima y pastilla se centran en layoutIdle()).
        let artSide = S.resumeArt
        resumeArt.frame = CGRect(x: Theme.Space.fine, y: (S.barHeight - artSide) / 2, width: artSide, height: artSide)
        let textX = Theme.Space.fine + artSide + Theme.Space.small
        let textWidth = S.resumeWidth - textX - 28
        resumeCaption.frame = LayerKit.textFrame(font: Theme.Fonts.resumeCaption, baseline: Theme.Baseline.resumeCaption, x: textX, width: textWidth)
        resumeTitle.frame = LayerKit.textFrame(font: Theme.Fonts.resumeTitle, baseline: Theme.Baseline.resumeTitle, x: textX, width: textWidth)
        resumeIcon.frame = CGRect(x: S.resumeWidth - 22, y: (S.barHeight - 12) / 2, width: 12, height: 12)
        batteryIcon.frame = CGRect(x: g.battery.minX, y: (S.barHeight - 13) / 2, width: 27, height: 13)
        batteryText.frame = LayerKit.textFrame(font: Theme.Fonts.battery, baseline: Theme.Baseline.time, x: g.battery.minX + 32, width: g.battery.width - 32)

        // Teclas y deslizador.
        layoutKey(brightnessKey, icon: brightnessIcon, in: g.brightnessKey)
        layoutKey(volumeKey, icon: volumeIcon, in: g.volumeKey)
        layoutKey(sliderIconKey, icon: sliderIcon, in: g.sliderIcon)
        layoutKey(sliderDoneKey, icon: sliderDoneIcon, in: g.sliderDone)
        setSymbol(sliderDoneIcon, "checkmark")
        sliderTrackLayer.frame = g.sliderTrack
        sliderValueText.frame = LayerKit.textFrame(font: Theme.Fonts.sliderValue, baseline: 20, x: g.sliderValue.minX, width: g.sliderValue.width)
        updateClock()
        layoutIdle(animated: false)
        layoutCharge()
        CATransaction.commit()
        applyResume()
        systemChanged()
    }

    /// Reposo: hora, clima y «Sonando ahora» quedan juntos y centrados en la Touch Bar,
    /// cada bloque tan ancho como su texto y separados por el mismo espacio.
    private func layoutIdle(animated: Bool) {
        let g = geometry
        let gap = Theme.Space.large
        let clockWidth = max(Self.width(of: shownClock, font: Theme.Fonts.clock), Self.width(of: shownDate, font: Theme.Fonts.date))
        var weatherWidth: CGFloat = 0
        if weatherReport != nil {
            let text = max(Self.width(of: weatherTemp.string as? String ?? "", font: Theme.Fonts.clock),
                           Self.width(of: weatherSummary.string as? String ?? "", font: Theme.Fonts.date))
            weatherWidth = S.weatherIcon + Theme.Space.small + text
        }
        let total = clockWidth + (weatherWidth > 0 ? gap + weatherWidth : 0) + gap + S.resumeWidth
        let rightLimit = g.battery.minX - Theme.Space.medium
        let startX = max(Theme.Space.fine, min(g.barCenter - total / 2, rightLimit - total))

        var layout = IdleLayout()
        layout.clock = CGRect(x: startX, y: 0, width: clockWidth, height: S.barHeight)
        var x = layout.clock.maxX + gap
        if weatherWidth > 0 {
            layout.weather = CGRect(x: x, y: 0, width: weatherWidth, height: S.barHeight)
            x = layout.weather.maxX + gap
        }
        layout.resume = CGRect(x: x, y: 0, width: S.resumeWidth, height: S.barHeight)
        idleLayout = layout

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Theme.Idle.crossfade)
        // +2 pt para que el redondeo no corte la última letra.
        clockText.frame = LayerKit.textFrame(font: Theme.Fonts.clock, baseline: Theme.Baseline.clock, x: layout.clock.minX, width: clockWidth + 2)
        dateText.frame = LayerKit.textFrame(font: Theme.Fonts.date, baseline: Theme.Baseline.date, x: layout.clock.minX, width: clockWidth + 2)
        if weatherWidth > 0 {
            let icon = CGRect(x: layout.weather.minX, y: (S.barHeight - S.weatherIcon) / 2, width: S.weatherIcon, height: S.weatherIcon)
            LayerKit.place(weatherIcon, in: icon)
            let textX = icon.maxX + Theme.Space.small
            let textWidth = layout.weather.maxX - textX + 2
            weatherTemp.frame = LayerKit.textFrame(font: Theme.Fonts.clock, baseline: Theme.Baseline.clock, x: textX, width: textWidth)
            weatherSummary.frame = LayerKit.textFrame(font: Theme.Fonts.date, baseline: Theme.Baseline.date, x: textX, width: textWidth)
        }
        let weatherOpacity: Float = weatherWidth > 0 ? 1 : 0
        weatherIcon.opacity = weatherOpacity
        weatherTemp.opacity = weatherOpacity
        weatherSummary.opacity = weatherOpacity
        LayerKit.place(resumePill, in: layout.resume)
        CATransaction.commit()
    }

    /// La ola de carga ocupa toda la barra (y el borde que se sale); el rayo y el % van al centro de la Touch Bar.
    private func layoutCharge() {
        let g = geometry
        let bleed = S.glowBleed
        chargeGroup.frame = CGRect(x: -bleed, y: 0, width: g.width + bleed * 2, height: S.barHeight)
        chargeFill.frame = chargeGroup.bounds
        chargeShape.frame = chargeFill.bounds
        chargeEdge.frame = chargeGroup.bounds
        let textWidth = Self.width(of: "100 %", font: Theme.Fonts.clock)
        let side = S.chargeIcon
        let groupWidth = side + Theme.Space.fine + textWidth
        let startX = g.barCenter + bleed - groupWidth / 2
        LayerKit.place(chargeIcon, in: CGRect(x: startX, y: (S.barHeight - side) / 2, width: side, height: side))
        setSymbol(chargeIcon, "bolt.fill")
        chargeText.frame = LayerKit.textFrame(font: Theme.Fonts.clock, baseline: Theme.Baseline.single,
                                              x: startX + side + Theme.Space.fine, width: textWidth + 2)
    }

    /// Un fotograma de la ola: se llena hasta tu % (el número sube con ella) y el borde se mueve como agua.
    private func updateCharge(now: CFTimeInterval) {
        guard var current = charge else { return }
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let elapsed = now - current.start
        let t = calm ? 1 : min(1, elapsed / Theme.Charging.fill)
        let eased = 1 - pow(1 - t, 3)
        let fraction = CGFloat(current.level) / 100 * CGFloat(eased)
        let width = chargeGroup.bounds.width
        let edgeX = width * fraction
        let amplitude = fraction > 0 ? Theme.Charging.waveAmplitude : 0
        let phase = calm ? 0 : now * Theme.Charging.waveSpeed
        let steps = 15
        let edge: [CGPoint] = (0...steps).map { step in
            let y = S.barHeight * CGFloat(step) / CGFloat(steps)
            let wave = sin(Double(y / Theme.Charging.wavelength) * 2 * .pi + phase)
            return CGPoint(x: max(0, edgeX + amplitude * CGFloat(wave)), y: y)
        }
        let fill = CGMutablePath()
        fill.addLines(between: [.zero] + edge + [CGPoint(x: 0, y: S.barHeight)])
        fill.closeSubpath()
        chargeShape.path = fill
        let line = CGMutablePath()
        line.addLines(between: edge)
        chargeEdge.path = line
        chargeEdge.opacity = fraction > 0 ? 1 : 0

        let percent = Int((Double(current.level) * eased).rounded())
        if percent != current.shownPercent {
            chargeText.string = "\(percent) %"
            current.shownPercent = percent
        }
        charge = current
        if !current.hold && elapsed > Theme.Charging.fill + Theme.Charging.hold { endCharging() }
    }

    private func endCharging() {
        guard charge != nil else { return }
        charge = nil
        CATransaction.begin()
        CATransaction.setDisableActions(false)   // también cuando se llama desde tick()
        CATransaction.setAnimationDuration(Theme.Charging.fade)
        chargeGroup.opacity = 0
        CATransaction.commit()
        applyMode(animated: true)
    }

    private func layoutKey(_ key: CALayer, icon: CALayer, in zone: CGRect) {
        LayerKit.place(key, in: CGRect(x: zone.midX - S.keyWidth / 2, y: (S.barHeight - S.keyHeight) / 2,
                                       width: S.keyWidth, height: S.keyHeight))
        let side = S.keyIcon
        icon.frame = CGRect(x: (S.keyWidth - side) / 2, y: (S.keyHeight - side) / 2, width: side, height: side)
        icon.mask?.frame = icon.bounds
    }

    private func rebuildBarsIfNeeded() {
        let count = max(16, Int(geometry.spectrumWidth / S.barPitch))
        guard count != bars.count else { return }
        bars.forEach { $0.removeFromSuperlayer() }
        bars = (0..<count).map { _ in
            let bar = CALayer()
            bar.contentsScale = Theme.scale
            bar.shadowOffset = .zero
            bar.shadowRadius = 3
            bar.shadowOpacity = 0
            spectrum.insertSublayer(bar, at: 0)   // debajo de la línea de progreso
            return bar
        }
        heights = Array(repeating: S.barMinHeight, count: count)
        rebuildBarColors()
    }

    private func applyNowPlaying(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        let hasTrack = nowPlaying.hasTrack
        let title = hasTrack ? nowPlaying.title : "Nada sonando"
        let artist = hasTrack ? nowPlaying.artist : "Abre Spotify y dale play"
        titleText.string = title
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: Theme.Fonts.title]).width) + 2
        titleText.frame = CGRect(x: 0, y: 0, width: max(S.textWidth, titleWidth), height: titleBox.bounds.height)
        artistText.string = artist

        let controls: Float = hasTrack ? 1 : 0.32
        previousIcon.opacity = controls
        nextIcon.opacity = controls
        elapsedText.opacity = hasTrack ? 1 : 0
        remainingText.opacity = hasTrack ? 1 : 0
        // La línea del cabezal (o el bichito) se decide en cada fotograma, en updatePlayer().
        placePlayIcon()
        CATransaction.commit()
        applyLike(animated: animated)
        applyResume()
        if shownIdle == false { setAccessibilityLabel(accessibilityTrackLabel()) }
    }

    /// La pastilla de reposo: «Sonando ahora» (vuelve a la canción), «Seguir escuchando» (le da play)
    /// o «Abrir Spotify» si no hay nada.
    private func applyResume() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let hasTrack = nowPlaying.hasTrack
        let playing = hasTrack && nowPlaying.isPlaying
        resumeCaption.string = playing ? "Sonando ahora" : (hasTrack ? "Seguir escuchando" : "Nada sonando")
        resumeTitle.string = hasTrack ? nowPlaying.title : "Abrir Spotify"
        resumeArt.contents = hasTrack ? currentArtwork : nil
        setSymbol(resumeIcon, playing ? "waveform" : (hasTrack ? "play.fill" : "arrow.up.forward.app.fill"))
        CATransaction.commit()
    }

    private func accessibilityTrackLabel() -> String {
        nowPlaying.hasTrack ? "\(nowPlaying.title), \(nowPlaying.artist)" : "Nada sonando"
    }

    private func placePlayIcon() {
        let side = S.playIcon, disc = S.playDisc
        // El triángulo de "play" se ve centrado si se corre un poco a la derecha.
        let nudge: CGFloat = nowPlaying.isPlaying ? 0 : 1
        playIcon.frame = CGRect(x: (disc - side) / 2 + nudge, y: (disc - side) / 2, width: side, height: side)
        playIcon.mask = LayerKit.mask(image: nowPlaying.isPlaying ? pauseImage : playImage, size: playIcon.bounds.size)
    }

    private func applyPalette(animated: Bool) {
        let colors = nowPlaying.hasTrack ? palette : Palette.neutral
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? Theme.Motion.colorChange : 0)
        CATransaction.setDisableActions(!animated)
        let titleStops = [colors.primary, colors.secondary, colors.tertiary, colors.secondary, colors.primary,
                          colors.secondary, colors.tertiary, colors.secondary, colors.primary]
        titleGradient.colors = titleStops.map { $0.cgColor }
        pulse.colors = [colors.primary, colors.secondary, colors.tertiary, colors.secondary, colors.primary].map { $0.cgColor }
        palettePulse = colors.primary.cgColor
        playDisc.backgroundColor = colors.primary.cgColor
        playRing.backgroundColor = colors.primary.withAlphaComponent(0.35).cgColor
        halo.shadowColor = colors.primary.cgColor
        let level = colors.primary.withAlphaComponent(Theme.Colors.keyLevelAlpha).cgColor
        brightnessLevel.backgroundColor = level
        volumeLevel.backgroundColor = level
        sliderFill.colors = [colors.primary, colors.secondary, colors.tertiary].map { $0.cgColor }
        sliderKnob.shadowColor = colors.primary.cgColor
        critter.setColors(body: colors.primary, accent: colors.secondary)
        CATransaction.commit()
        applyLike(animated: animated)
    }

    private func rebuildBarColors() {
        let count = max(2, bars.count)
        let colors = (0..<count).map { palette.color(at: CGFloat($0) / CGFloat(count - 1)) }
        playedColors = colors.map { $0.cgColor }
        upcomingColors = colors.map { $0.withAlphaComponent(Theme.Colors.upcomingBarAlpha).cgColor }
    }

    private func updateBars(levels: [Float]?, ratio: CGFloat, dt: Double, calm: Bool) {
        let count = bars.count
        guard count > 1, playedColors.count == count else { return }
        let width = spectrum.bounds.width
        let middle = Double(count - 1) / 2
        let hasTrack = nowPlaying.hasTrack
        for index in 0..<count {
            let window = CGFloat(pow(sin(Double.pi * (Double(index) + 0.5) / Double(count)), 0.5))
            var target: CGFloat
            if let levels, !levels.isEmpty {
                // Espectro en espejo: graves al centro, agudos hacia los bordes.
                let distance = abs(Double(index) - middle) / middle
                let band = min(levels.count - 1, Int((distance * Double(levels.count - 1)).rounded()))
                target = S.barMinHeight + (S.barMaxHeight - S.barMinHeight) * CGFloat(levels[band]) * (0.35 + 0.65 * window)
            } else {
                let wave = 0.30 + 0.70 * abs(sin(Double(index) * 0.53 + phase * 3.1) * cos(Double(index) * 0.21 - phase * 1.9))
                target = 28 * energy * window * CGFloat(wave)
            }
            if !hasTrack { target = S.barMinHeight }
            target = max(S.barMinHeight, min(S.barMaxHeight, target))
            let speed: Double = calm ? 6 : (target > heights[index] ? 30 : 12)
            heights[index] += (target - heights[index]) * CGFloat(min(1, dt * speed))

            let bar = bars[index]
            bar.frame = barFrame(index: index, height: heights[index])
            bar.cornerRadius = bar.bounds.width / 2
            let played = hasTrack && bar.frame.midX / width <= ratio
            if !hasTrack {
                bar.backgroundColor = Theme.Colors.idleBar.cgColor
            } else {
                bar.backgroundColor = played ? playedColors[index] : upcomingColors[index]
            }
            bar.shadowColor = playedColors[index]
            bar.shadowOpacity = played ? Float(0.45 + 0.45 * beat) : 0
            // Debajo del bichito las barras se atenúan para que se lea bien.
            if critterShown {
                let near = max(0, 1 - abs(bar.frame.midX - critter.x) / Theme.Critter.dimRadius)
                bar.opacity = 1 - Theme.Critter.dimAmount * Float(near)
            } else if bar.opacity != 1 {
                bar.opacity = 1
            }
            if played {
                let radius = min(bar.bounds.width / 2, bar.bounds.height / 2)
                bar.shadowPath = CGPath(roundedRect: bar.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            } else {
                bar.shadowPath = nil
            }
        }
    }

    // MARK: - Me gusta

    func setLike(_ state: LikeState) {
        likeState = state
        applyLike(animated: true)
    }

    /// Lleno y con el color de la portada si te gusta; vacío si no; tenue si aún no se sabe o falta conectar.
    private func applyLike(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        let liked = likeState == .liked
        setSymbol(heartIcon, liked ? "heart.fill" : "heart")
        heartIcon.backgroundColor = (liked ? palette.primary : NSColor.white).cgColor
        let known = likeState == .liked || likeState == .notLiked
        heartIcon.opacity = nowPlaying.hasTrack ? (known ? (liked ? 1 : 0.85) : 0.4) : 0
        CATransaction.commit()
    }

    // MARK: - Brillo y volumen

    private func currentValue(_ kind: Adjust) -> Float {
        guard let system else { return 0 }
        switch kind {
        case .brightness: return system.brightness
        case .volume: return system.isMuted ? 0 : system.volume
        }
    }

    private func setValue(_ value: Float, for kind: Adjust) {
        let clamped = max(0, min(1, value))
        switch kind {
        case .brightness: system?.setBrightness(clamped)
        case .volume: system?.setVolume(clamped)
        }
    }

    private func volumeSymbol() -> String {
        guard let system else { return "speaker.wave.2.fill" }
        if system.isMuted || system.volume < 0.01 { return "speaker.slash.fill" }
        if system.volume < 0.34 { return "speaker.wave.1.fill" }
        if system.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func openSlider(_ kind: Adjust) {
        adjusting = kind
        updateSlider()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Motion.sliderFade)
        playerGroup.opacity = 0
        idleGroup.opacity = 0
        keysGroup.opacity = 0
        sliderGroup.opacity = 1
        CATransaction.commit()
        scheduleSliderClose()
    }

    private func closeSlider() {
        closeSliderWork?.cancel()
        adjusting = nil
        adjustDrag = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Motion.sliderFade)
        sliderGroup.opacity = 0
        CATransaction.commit()
        applyMode(animated: true)
    }

    private func scheduleSliderClose() {
        closeSliderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activeTouch == nil else { return }
            self.closeSlider()
        }
        closeSliderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.sliderAutoClose, execute: work)
    }

    private func updateSlider() {
        guard let kind = adjusting else { return }
        let value = CGFloat(currentValue(kind))
        let track = geometry.sliderTrack
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sliderFill.frame = CGRect(x: 0, y: 0, width: max(S.sliderTrack, track.width * value), height: S.sliderTrack)
        sliderKnob.position = CGPoint(x: track.minX + track.width * value, y: S.barHeight / 2)
        let muted = kind == .volume && (system?.isMuted ?? false)
        sliderFill.opacity = muted ? 0.3 : 1
        sliderValueText.string = muted ? "Silencio" : "\(Int((value * 100).rounded())) %"
        switch kind {
        case .brightness: setSymbol(sliderIcon, value < 0.5 ? "sun.min.fill" : "sun.max.fill")
        case .volume: setSymbol(sliderIcon, volumeSymbol())
        }
        CATransaction.commit()
    }

    // MARK: - Toques

    private func zone(at x: CGFloat) -> Zone? {
        let g = geometry
        if adjusting != nil {
            if x < g.sliderIcon.maxX { return .sliderIcon }
            if x >= g.sliderDone.minX { return .sliderDone }
            if x >= g.sliderTrack.minX - Theme.Space.medium && x <= g.sliderTrack.maxX + Theme.Space.medium { return .sliderTrack }
            return nil
        }
        if x >= g.volumeKey.minX { return .volume }
        if x >= g.brightnessKey.minX { return (system?.canChangeBrightness ?? false) ? .brightness : nil }
        if isIdle {
            // Cada bloque se toca también en la mitad del hueco que lo separa del siguiente.
            let reach = Theme.Space.large / 2
            let layout = idleLayout
            if Self.spans(layout.clock, x, reach: reach) { return .clock }
            if Self.spans(layout.weather, x, reach: reach) { return .weather }
            if Self.spans(layout.resume, x, reach: reach) { return .resume }
            return nil
        }
        switch x {
        case ..<g.heart.minX: return .info
        case ..<(g.heart.maxX + Theme.Space.small): return nowPlaying.hasTrack ? .heart : .info
        case ..<g.previous.minX: return nowPlaying.hasTrack ? .scrub : nil
        case ..<g.play.minX: return .previous
        case ..<g.next.minX: return .play
        default: return .next
        }
    }

    private func ratio(at x: CGFloat) -> CGFloat {
        max(0, min(1, (x - spectrum.frame.minX) / spectrum.frame.width))
    }

    private func sliderRatio(at x: CGFloat) -> Float {
        let track = geometry.sliderTrack
        return Float(max(0, min(1, (x - track.minX) / track.width)))
    }

    override func touchesBegan(with event: NSEvent) {
        guard activeTouch == nil, let touch = event.touches(matching: .began, in: self).first else { return }
        // Si tocas durante la ola de carga, solo se quita: no se pulsa lo que había debajo sin verlo.
        if charge != nil {
            endCharging()
            return
        }
        let x = touch.location(in: self).x
        guard let hit = zone(at: x) else { return }
        activeTouch = touch.identity
        pressed = hit
        switch hit {
        case .info:
            swipe = Swipe(startX: x)
        case .scrub:
            // Empezó sobre el bichito: si no lo mueves es un toque (se ríe) y la canción no salta.
            if critterShown, abs(x - (spectrum.frame.minX + critter.x)) <= Theme.Critter.hitRadius {
                critterTap = x
            } else {
                scrubRatio = ratio(at: x)
            }
        case .brightness, .volume:
            // Abre el deslizador al instante; si arrastras, ajusta desde donde estaba.
            let kind: Adjust = hit == .brightness ? .brightness : .volume
            adjustDrag = AdjustDrag(startX: x, startValue: currentValue(kind), moved: false)
            openSlider(kind)
        case .sliderTrack:
            if let kind = adjusting { setValue(sliderRatio(at: x), for: kind) }
            closeSliderWork?.cancel()
        default:
            break
        }
        setPressed(hit, true)
    }

    override func touchesMoved(with event: NSEvent) {
        guard let touch = trackedTouch(in: event, phase: .moved), let hit = pressed else { return }
        let x = touch.location(in: self).x
        switch hit {
        case .info:
            moveSwipe(to: x)
        case .scrub:
            if let start = critterTap {
                guard abs(x - start) > Theme.Gesture.slop else { return }
                critterTap = nil   // lo arrastras: va colgado de tu dedo por la canción
            }
            scrubRatio = ratio(at: x)
        case .brightness, .volume:
            guard var drag = adjustDrag, let kind = adjusting else { return }
            let delta = x - drag.startX
            if abs(delta) > Theme.Space.fine { drag.moved = true }
            adjustDrag = drag
            if drag.moved {
                setValue(drag.startValue + Float(delta / geometry.sliderTrack.width), for: kind)
            }
        case .sliderTrack:
            if let kind = adjusting { setValue(sliderRatio(at: x), for: kind) }
        default:
            setPressed(hit, zone(at: x) == hit)
        }
    }

    override func touchesEnded(with event: NSEvent) {
        guard let touch = trackedTouch(in: event, phase: .ended), let hit = pressed else { return }
        let x = touch.location(in: self).x
        setPressed(hit, false)
        switch hit {
        case .info:
            if swipe?.active == true {
                endSwipe(commit: true)
            } else {
                swipe = nil
                if zone(at: x) == .info { perform(.info) }   // fue un toque: abre Spotify
            }
        case .scrub:
            if critterTap != nil {
                critterTap = nil
                critter.react(now: CACurrentMediaTime())
            } else if let scrubRatio, nowPlaying.duration > 0 {
                let seconds = Double(scrubRatio) * nowPlaying.duration
                nowPlaying.position = seconds
                nowPlaying.positionDate = Date()
                ripple(at: CGPoint(x: spectrum.frame.minX + scrubRatio * spectrum.frame.width, y: S.barHeight / 2), size: 24)
                onSeek?(seconds)
            }
        case .brightness, .volume, .sliderTrack:
            adjustDrag = nil
            endTouch()
            scheduleSliderClose()
            return
        default:
            if zone(at: x) == hit { perform(hit) }
        }
        endTouch()
        if adjusting != nil { scheduleSliderClose() }
    }

    override func touchesCancelled(with event: NSEvent) {
        if let hit = pressed { setPressed(hit, false) }
        if swipe != nil { endSwipe(commit: false) }
        adjustDrag = nil
        endTouch()
        if adjusting != nil { scheduleSliderClose() }
    }

    private func trackedTouch(in event: NSEvent, phase: NSTouch.Phase) -> NSTouch? {
        guard let active = activeTouch else { return nil }
        return event.touches(matching: phase, in: self).first { $0.identity.isEqual(active) }
    }

    private func endTouch() {
        activeTouch = nil
        pressed = nil
        scrubRatio = nil
        critterTap = nil
    }

    private func perform(_ hit: Zone) {
        let g = geometry
        let middle = S.barHeight / 2
        switch hit {
        case .info:
            ripple(at: CGPoint(x: S.artwork / 2, y: middle), size: S.artwork)
            onOpenSpotify?()
        case .heart:
            ripple(at: CGPoint(x: g.heart.midX, y: middle), size: S.heartZone)
            pop(heartIcon)
            onToggleLike?()
        case .previous:
            guard nowPlaying.hasTrack else { return }
            ripple(at: CGPoint(x: g.previous.midX, y: middle), size: 26)
            nudge(previousIcon, by: -6)
            onPrevious?()
        case .next:
            guard nowPlaying.hasTrack else { return }
            ripple(at: CGPoint(x: g.next.midX, y: middle), size: 26)
            nudge(nextIcon, by: 6)
            onNext?()
        case .play:
            ripple(at: CGPoint(x: g.play.midX, y: middle), size: S.playDisc)
            pop(playDisc)
            togglePlayback()
        case .clock:
            ripple(at: CGPoint(x: idleLayout.clock.midX, y: middle), size: 40)
            onOpenCalendar?()
        case .weather:
            ripple(at: CGPoint(x: idleLayout.weather.midX, y: middle), size: 40)
            onOpenWeather?()
        case .resume:
            ripple(at: CGPoint(x: idleLayout.resume.midX, y: middle), size: 60)
            pop(resumePill)
            if !nowPlaying.hasTrack {
                onOpenSpotify?()
            } else {
                if !nowPlaying.isPlaying { togglePlayback() }   // en pausa: le da play
                forcedIdle = false                              // y vuelve a la canción
                pausedSince = nil
                applyResume()
                applyMode(animated: true)
            }
        case .sliderIcon:
            // El silencio vive dentro del volumen: se activa tocando el altavoz.
            if adjusting == .volume, let system {
                system.setMuted(!system.isMuted)
                ripple(at: CGPoint(x: g.sliderIcon.midX, y: middle), size: S.keyHeight)
                pop(sliderIconKey)
            }
        case .sliderDone:
            closeSlider()
        case .scrub, .brightness, .volume, .sliderTrack:
            break
        }
    }

    private func togglePlayback() {
        if nowPlaying.hasTrack {
            // Respuesta inmediata; Spotify confirma después.
            nowPlaying.position = nowPlaying.position(at: Date())
            nowPlaying.positionDate = Date()
            nowPlaying.isPlaying.toggle()
            if nowPlaying.isPlaying { pausedSince = nil }
            applyNowPlaying(animated: true)
        }
        onTogglePlay?()
    }

    // MARK: - Deslizar la canción

    private func moveSwipe(to x: CGFloat) {
        guard var current = swipe else { return }
        current.dx = x - current.startX
        if !current.active, nowPlaying.hasTrack, abs(current.dx) > Theme.Gesture.slop {
            current.active = true
            swipeReveal = nil
            infoGroup.removeAllAnimations()
        }
        let wasArmed = current.armed
        current.armed = current.active && abs(current.dx) >= Theme.Gesture.threshold
        swipe = current
        guard current.active else { return }
        showSwipe(dx: current.dx, armedNow: current.armed && !wasArmed)
    }

    /// La canción sigue al dedo (frenándose cerca del límite) y aparece la flecha de lo que va a pasar.
    private func showSwipe(dx: CGFloat, armedNow: Bool) {
        let limit = Theme.Gesture.maxOffset
        let offset = limit * tanh(dx / limit)
        let progress = min(1, abs(dx) / Theme.Gesture.threshold)
        let toNext = dx < 0
        let side = S.swipeHint
        // La flecha sale en el hueco que deja la canción: a la derecha si va a la siguiente, a la izquierda si vuelve.
        let hintX = toNext ? geometry.heart.midX : S.artwork / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        infoGroup.transform = CATransform3DMakeTranslation(offset, 0, 0)
        infoGroup.opacity = Float(1 - 0.45 * abs(offset) / limit)
        setInfoEdge(min(Theme.Gesture.edgeFade, max(0, -offset)))
        swipeHint.frame = CGRect(x: hintX - side / 2, y: (S.barHeight - side) / 2, width: side, height: side)
        setSymbol(swipeHint, toNext ? "forward.fill" : "backward.fill")
        // Tenue mientras no llega al umbral; entera cuando al soltar ya cambia de canción.
        swipeHint.opacity = progress >= 1 ? 1 : Float(progress * progress) * 0.6
        CATransaction.commit()
        if armedNow { pop(swipeHint) }
    }

    /// Al soltar: si pasó el umbral cambia de canción; si no, vuelve a su sitio.
    private func endSwipe(commit: Bool) {
        guard let current = swipe else { return }
        swipe = nil
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        CATransaction.setAnimationDuration(Theme.Motion.sliderFade)
        swipeHint.opacity = 0
        CATransaction.commit()
        guard current.active else { return }
        guard commit, current.armed, nowPlaying.hasTrack else {
            settleInfo()
            return
        }
        let toNext = current.dx < 0
        if toNext {
            nudge(nextIcon, by: 6)
            onNext?()
        } else {
            nudge(previousIcon, by: -6)
            onPrevious?()
        }
        slideInfoOut(direction: toNext ? -1 : 1)
    }

    /// La canción sale por donde la empujaste…
    private func slideInfoOut(direction: CGFloat) {
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        CATransaction.setAnimationDuration(Theme.Motion.swipeOut)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        let distance = calm ? 0 : direction * (Theme.Gesture.maxOffset + Theme.Gesture.revealOffset)
        infoGroup.transform = CATransform3DMakeTranslation(distance, 0, 0)
        infoGroup.opacity = 0
        setInfoEdge(direction < 0 ? Theme.Gesture.edgeFade : 0)
        CATransaction.commit()
        swipeReveal = (from: calm ? 0 : -direction * Theme.Gesture.revealOffset,
                       trackID: nowPlaying.trackID,
                       deadline: CACurrentMediaTime() + Theme.Motion.swipeRevealTimeout)
    }

    /// …y la nueva entra por el lado contrario.
    private func revealInfo() {
        guard let reveal = swipeReveal else { return }
        swipeReveal = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        infoGroup.transform = CATransform3DMakeTranslation(reveal.from, 0, 0)
        setInfoEdge(reveal.from < 0 ? Theme.Gesture.edgeFade : 0)   // la anterior entra por la izquierda, suave
        CATransaction.commit()
        settleInfo()
    }

    /// Vuelve a su sitio con un rebote suave.
    private func settleInfo() {
        CATransaction.begin()
        CATransaction.setDisableActions(false)   // también cuando se llama desde tick()
        CATransaction.setAnimationDuration(Theme.Motion.swipeIn)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.4, 1))
        infoGroup.transform = CATransform3DIdentity
        infoGroup.opacity = 1
        setInfoEdge(0)
        CATransaction.commit()
    }

    /// Borde izquierdo difuminado de la ventana de la canción. Quieta, queda fuera de la barra (no toca la foto);
    /// al deslizar hacia la izquierda entra hasta `edgeFade` pt para que la canción se desvanezca en vez de cortarse.
    private func setInfoEdge(_ shift: CGFloat) {
        let fade = Theme.Gesture.edgeFade
        let width = max(1, infoClipWidth)
        infoClipMask.locations = [shift / width, (shift + fade) / width, 1 - fade / width, 1].map { NSNumber(value: Double($0)) }
    }

    // MARK: - Efectos

    private func setPressed(_ hit: Zone, _ down: Bool) {
        let transform = down ? CATransform3DMakeScale(0.82, 0.82, 1) : CATransform3DIdentity
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Motion.press)
        switch hit {
        case .heart: heartIcon.transform = transform
        case .previous: previousIcon.transform = transform
        case .play: playDisc.transform = transform
        case .next: nextIcon.transform = transform
        case .brightness: brightnessKey.transform = transform
        case .volume: volumeKey.transform = transform
        case .sliderIcon: sliderIconKey.transform = transform
        case .sliderDone: sliderDoneKey.transform = transform
        case .sliderTrack: sliderKnob.transform = down ? CATransform3DMakeScale(1.2, 1.2, 1) : CATransform3DIdentity
        case .resume: resumePill.transform = down ? CATransform3DMakeScale(0.94, 0.94, 1) : CATransform3DIdentity
        case .info, .scrub, .clock, .weather: break   // la foto se encoge en tick(), el scrub enseña la bolita; hora y clima, onda
        }
        CATransaction.commit()
    }

    /// Onda de color que sale del botón al tocarlo.
    private func ripple(at center: CGPoint, size: CGFloat) {
        guard let root = layer else { return }
        let wave = CALayer()
        wave.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        wave.position = center
        wave.cornerRadius = size / 2
        wave.backgroundColor = (nowPlaying.hasTrack ? palette.primary : NSColor.white).withAlphaComponent(0.6).cgColor
        wave.opacity = 0
        wave.contentsScale = Theme.scale
        root.insertSublayer(wave, above: pulse)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = Theme.Motion.ripple
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { wave.removeFromSuperlayer() }
        wave.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    /// Onda que sube desde el borde de abajo, justo encima de la tecla que pulsaste.
    /// `position`: 0 = borde izquierdo de la Touch Bar · 1 = borde derecho.
    func keyWave(at position: CGFloat) {
        guard let root = layer, window != nil else { return }
        let viewStart = S.touchBarWidth / 2 - geometry.barCenter   // dónde empieza esta vista en la Touch Bar
        let x = position * S.touchBarWidth - viewStart
        let size: CGFloat = 26
        let tint = nowPlaying.hasTrack ? palette.color(at: max(0, min(1, x / max(1, geometry.width)))) : NSColor.white
        let wave = CALayer()
        wave.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        wave.position = CGPoint(x: x, y: -2)   // nace pegada al teclado
        wave.cornerRadius = size / 2
        wave.backgroundColor = tint.withAlphaComponent(0.25).cgColor
        wave.borderColor = tint.withAlphaComponent(0.9).cgColor
        wave.borderWidth = 1.5
        wave.opacity = 0
        wave.contentsScale = Theme.scale
        root.insertSublayer(wave, above: pulse)   // por detrás del texto y los botones

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 3.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = Theme.Motion.keyWave
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { wave.removeFromSuperlayer() }
        wave.add(group, forKey: "keyWave")
        CATransaction.commit()
    }

    /// Rebote del botón.
    private func pop(_ target: CALayer) {
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 1.25
        spring.toValue = 1
        spring.damping = 9
        spring.stiffness = 320
        spring.mass = 1
        spring.duration = spring.settlingDuration
        target.add(spring, forKey: "pop")
    }

    /// Pequeño empujón del icono hacia donde va la canción.
    private func nudge(_ target: CALayer, by offset: CGFloat) {
        let move = CAKeyframeAnimation(keyPath: "transform.translation.x")
        move.values = [0, offset, 0]
        move.keyTimes = [0, 0.35, 1]
        move.duration = 0.3
        move.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        target.add(move, forKey: "nudge")
    }

    // MARK: - Utilidades

    /// Sombra oscura alrededor de las letras: se leen aunque la barra esté iluminada.
    private func applyTextShadow(to target: CALayer) {
        target.shadowColor = Theme.Colors.textShadow.cgColor
        target.shadowOpacity = 0.9
        target.shadowRadius = 2.5
        target.shadowOffset = .zero
    }

    private func setSymbol(_ icon: CALayer, _ name: String) {
        let image: CGImage?
        if let cached = symbols[name] {
            image = cached
        } else {
            image = LayerKit.symbolImage(name, pointSize: 17, weight: .semibold)
            symbols[name] = image
        }
        if let mask = icon.mask {
            mask.contents = image
            mask.frame = icon.bounds
        } else {
            icon.mask = LayerKit.mask(image: image, size: icon.bounds.size)
        }
    }

    private func barFrame(index: Int, height: CGFloat) -> CGRect {
        let pitch = geometry.spectrumWidth / CGFloat(max(1, bars.count))
        let thickness = max(2, pitch * S.barFill)
        return CGRect(x: CGFloat(index) * pitch + (pitch - thickness) / 2,
                      y: (S.barHeight - height) / 2, width: thickness, height: height)
    }

    private func centered(_ side: CGFloat, in rect: CGRect) -> CGRect {
        CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    private static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// `x` cae dentro del bloque o a menos de `reach` de sus bordes (un bloque vacío no cuenta).
    private static func spans(_ rect: CGRect, _ x: CGFloat, reach: CGFloat) -> Bool {
        rect.width > 0 && x >= rect.minX - reach && x < rect.maxX + reach
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
