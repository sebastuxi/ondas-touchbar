import AppKit
import IOKit.ps
import QuartzCore
import ServiceManagement
import TouchBarPrivate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spotify = SpotifyClient()
    private let analyzer = SpectrumAnalyzer()
    private let system = SystemControls()
    private let pulse = MusicPulse()
    private let groove = GrooveTracker()
    private let keyboard = KeyboardLight()
    private let keystrokes = KeystrokeWatcher()
    private let library = SpotifyLibrary()
    private let weather = WeatherService()
    private let bar = TouchBarController()
    private var statusItem: NSStatusItem?
    private var frameTimer: Timer?
    private var audioTimer: Timer?
    private var idleInfoTimer: Timer?
    private var lastFrame: CFTimeInterval = 0
    private var nextAudioAttempt: TimeInterval = 0
    private var audioBackoff: TimeInterval = 3
    private var hadRealAudio = false
    private var shownArtworkFor = ""
    private var likeTrackID = ""
    private var currentLiked: Bool?
    private var wasPlaying = false
    private var hintsTrackID = ""
    private var terminationSignal: DispatchSourceSignal?
    private var powerSource: CFRunLoopSource?
    /// nil hasta la primera lectura: así abrir Ondas enchufada no cuenta como «enchufar».
    private var wasOnAC: Bool?

    private let defaults = UserDefaults.standard

    private var autoShow: Bool {
        get { defaults.object(forKey: "autoShow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoShow") }
    }

    private var realAudio: Bool {
        get { defaults.object(forKey: "realAudio") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "realAudio") }
    }

    /// El bichito que baila sobre la barra de progreso.
    private var critterOn: Bool {
        get { defaults.object(forKey: "critter") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "critter") }
    }

    /// Ondas al escribir: luz del teclado y ondas en la Touch Bar con cada tecla.
    private var typingWaves: Bool {
        get { defaults.object(forKey: "typingWaves") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "typingWaves") }
    }

    /// Luz del teclado cuando no escribes.
    private var keyboardRest: Float {
        get { defaults.object(forKey: "keyboardRest") as? Float ?? Theme.Keyboard.restLevel }
        set { defaults.set(newValue, forKey: "keyboardRest") }
    }

    private var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// Quieres que se abra al encender la Mac (sí, salvo que lo quites en el menú).
    private var wantsOpenAtLogin: Bool {
        get { defaults.object(forKey: "wantsOpenAtLogin") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wantsOpenAtLogin") }
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "activado"
        case .requiresApproval: return "falta tu permiso en Ajustes"
        case .notRegistered: return "sin registrar"
        case .notFound: return "no encontrado"
        @unknown default: return "desconocido"
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard OBSystemModalAvailable() else {
            let alert = NSAlert()
            alert.messageText = "Esta versión de macOS no deja mostrar barras propias en la Touch Bar."
            alert.informativeText = "Ondas necesita una función del sistema que aquí no está disponible."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Si se cerró de golpe mientras el teclado latía, primero lo deja como estaba.
        keyboard.recoverIfNeeded()
        // Al cerrar sesión o con `kill`, sale ordenadamente (y devuelve el teclado a su brillo).
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        terminationSignal = termination

        buildStatusItem()
        bar.autoShowWithSpotify = autoShow
        bar.install()
        bar.barView.system = system
        bar.barView.critterEnabled = critterOn
        system.onChange = { [weak self] in self?.bar.barView.systemChanged() }
        library.onStateChange = { [weak self] in
            self?.refreshLike(force: true)
            self?.rebuildMenu()
        }
        wireBar()
        wireSpotify()
        spotify.start()

        keyboard.restLevel = keyboardRest
        keystrokes.onKey = { [weak self] position in self?.keyPressed(at: position) }
        keystrokes.onReady = { [weak self] in self?.rebuildMenu() }
        if typingWaves {
            keystrokes.start()
            keyboard.activate(now: CACurrentMediaTime())   // media luz desde que abre
        }
        // Al despertar la Mac, macOS reinicia la luz del teclado y quita la barra de la Touch Bar:
        // Ondas retoma la luz con la primera tecla y vuelve a poner la barra.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(macWoke(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensWoke(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensWoke(_:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screensWoke(_:)), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        // Abrir al encender la Mac: si lo quieres y macOS perdió el registro (p. ej. al reinstalar), se registra de nuevo.
        let loginStatus = SMAppService.mainApp.status
        Log.app.notice("Abrir al encender: \(Self.describe(loginStatus), privacy: .public)")
        if wantsOpenAtLogin && loginStatus != .enabled && loginStatus != .requiresApproval {
            setOpenAtLogin(true)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        let frames = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.renderFrame() }
        RunLoop.main.add(frames, forMode: .common)
        frameTimer = frames

        let audio = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.manageAudio() }
        RunLoop.main.add(audio, forMode: .common)
        audioTimer = audio

        // Reposo: la batería se actualiza cada 30 s y al instante cuando enchufas o desenchufas.
        readBattery()
        let idleInfo = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.readBattery() }
        RunLoop.main.add(idleInfo, forMode: .common)
        idleInfoTimer = idleInfo
        watchPower()

        // Clima de la pantalla de reposo (pide permiso de ubicación la primera vez).
        weather.onChange = { [weak self] report in self?.bar.barView.setWeather(report) }
        weather.onAccessChange = { [weak self] in self?.rebuildMenu() }
        let preview = previewFlags
        if !preview.contains("weather") { weather.start() }   // con el clima de ejemplo no se pide el real

        // Al abrir la app se muestra la barra para que se vea que funciona.
        bar.present(automatic: false)
        if !preview.isEmpty { applyPreview(preview) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboard.restore()
        analyzer.stop()
        bar.uninstall()
    }

    // MARK: - Conexiones

    private func wireBar() {
        let view = bar.barView
        view.onOpenSpotify = { [weak self] in self?.spotify.activate() }
        view.onPrevious = { [weak self] in self?.spotify.previous() }
        view.onNext = { [weak self] in self?.spotify.next() }
        view.onTogglePlay = { [weak self] in self?.spotify.playPause() }
        view.onSeek = { [weak self] seconds in self?.spotify.seek(to: seconds) }
        view.onToggleLike = { [weak self] in self?.toggleLike() }
        view.onOpenCalendar = { Self.openApp("com.apple.iCal") }
        view.onOpenWeather = { Self.openApp("com.apple.weather") }
    }

    private static func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Reposo: batería y carga

    private func readBattery() {
        guard let reading = Self.batteryReading() else {
            bar.barView.setBattery(level: nil, charging: false)
            return
        }
        bar.barView.setBattery(level: reading.level, charging: reading.charging)
        // Acabas de enchufar el cargador: ola verde en la Touch Bar.
        if wasOnAC == false && reading.onAC && bar.isPresented {
            Log.app.notice("Cargador enchufado: \(reading.level, privacy: .public) %")
            bar.barView.showCharging(level: reading.level)
        }
        wasOnAC = reading.onAC
    }

    private static func batteryReading() -> (level: Int, charging: Bool, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (current * 100 / maximum, charging, onAC)
        }
        return nil
    }

    /// macOS avisa al instante cuando cambia la fuente de energía (enchufar, desenchufar, cada % de batería).
    private func watchPower() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().readBattery()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    // MARK: - Vista previa (para revisar el diseño)

    /// Solo al abrir así: `open ~/Applications/Ondas.app --args -OndasPreview idle,weather,swipe,charging,dance`.
    /// En uso normal está vacío y no hace nada.
    private var previewFlags: Set<String> {
        let value = defaults.string(forKey: "OndasPreview") ?? ""
        return Set(value.split(separator: ",").map { String($0) })
    }

    /// Canciones de ejemplo para ver cada baile: tranquila, con graves, rápida, brillante y triste.
    private static let previewGrooves: [String: Groove] = {
        func groove(bpm: Double, clear: Double, intensity: Double, drive: Double, bass: Double, bright: Double,
                    happy: Double, energy: Double) -> Groove {
            var g = Groove()
            g.bpm = bpm
            g.confidence = clear
            g.intensity = intensity
            g.drive = drive
            g.bass = bass
            g.bright = bright
            g.valence = happy
            g.arousal = energy
            return g
        }
        return [
            "calm": groove(bpm: 76, clear: 0.2, intensity: 0.4, drive: 0.15, bass: 0.4, bright: 0.3, happy: 0.75, energy: 0.2),
            "bass": groove(bpm: 92, clear: 0.9, intensity: 0.7, drive: 0.6, bass: 0.9, bright: 0.2, happy: 0.45, energy: 0.75),
            "fast": groove(bpm: 128, clear: 0.9, intensity: 0.85, drive: 0.9, bass: 0.5, bright: 0.3, happy: 0.8, energy: 0.9),
            "bright": groove(bpm: 118, clear: 0.85, intensity: 0.8, drive: 0.8, bass: 0.3, bright: 0.9, happy: 0.85, energy: 0.8),
            "sad": groove(bpm: 72, clear: 0.5, intensity: 0.35, drive: 0.25, bass: 0.4, bright: 0.15, happy: 0.15, energy: 0.15),
        ]
    }()

    private func applyPreview(_ flags: Set<String>) {
        Log.app.notice("Vista previa: \(flags.sorted().joined(separator: ","), privacy: .public)")
        // Bichito: bailar aunque esté en pausa, con un carácter de canción fijo, sentado, colgado o sus pasos especiales.
        let view = bar.barView
        if flags.contains("dance") { view.critterPreviewMode = .dancing }
        if let name = flags.first(where: { Self.previewGrooves[$0] != nil }) {
            groove.preset = Self.previewGrooves[name]
            view.critterPreviewMode = .dancing
        }
        if flags.contains("sit") { view.critterPreviewMode = .waiting }
        if flags.contains("carry") { view.critterPreviewMode = .carried }
        if flags.contains("moves") {
            view.critterPreviewMode = .dancing
            view.critterPreviewMoves = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let view = self.bar.barView
            if flags.contains("weather") {
                view.setWeather(WeatherService.Report(temperature: 18, code: 2, isDay: true, date: Date()))
            }
            if flags.contains("idle") { _ = view.handleClose() }
            if flags.contains("swipe") { view.previewSwipe() }
            if flags.contains("charging") { view.showCharging(level: Self.batteryReading()?.level ?? 76, hold: true) }
        }
    }

    private func wireSpotify() {
        spotify.onChange = { [weak self] state in
            guard let self else { return }
            // Al darle play, la barra vuelve aunque la hubieras cerrado con la X o macOS la hubiera quitado
            // (no se fía de `isPresented`: tras dormir la Mac puede estar desactualizado). Y se queda al cambiar de app.
            if state.isPlaying && !self.wasPlaying && self.autoShow {
                self.bar.present(automatic: false)
            }
            self.wasPlaying = state.isPlaying
            self.bar.barView.update(nowPlaying: state)
            self.askSpotifyAboutSong(state)
            if !state.hasTrack && !self.shownArtworkFor.isEmpty {
                self.shownArtworkFor = ""
                self.bar.barView.setArtwork(nil, palette: .fallback, glow: nil)
                self.bar.setTrayArtwork(nil)
            }
            self.refreshLike()
        }
        spotify.onArtwork = { [weak self] trackID, image in
            guard let self, trackID == self.spotify.state.trackID, trackID != self.shownArtworkFor else { return }
            self.shownArtworkFor = trackID
            DispatchQueue.global(qos: .userInitiated).async {
                let palette = Palette.extract(from: image)
                let glow = ImageEffects.glow(from: image)
                DispatchQueue.main.async {
                    guard trackID == self.spotify.state.trackID else { return }
                    self.bar.barView.setArtwork(image, palette: palette, glow: glow)
                    self.bar.setTrayArtwork(image)
                }
            }
        }
        spotify.onAutomationChange = { [weak self] in self?.rebuildMenu() }
    }

    /// Al cambiar de canción, el bichito le pregunta a Spotify cómo es (tempo, energía, ánimo o género)
    /// para bailar bien desde el primer segundo; después afina con lo que oye.
    private func askSpotifyAboutSong(_ state: NowPlaying) {
        guard state.hasTrack, state.trackID != hintsTrackID else { return }
        hintsTrackID = state.trackID
        groove.setHints(nil, for: state.trackID)
        guard library.isConnected else { return }
        let id = state.trackID
        library.fetchSongHints(trackID: id) { [weak self] hints in
            guard let self, id == self.spotify.state.trackID else { return }
            self.groove.setHints(hints, for: id)
        }
    }

    @objc private func applicationActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        bar.frontmostAppChanged(to: app?.bundleIdentifier)
    }

    // MARK: - Me gusta

    private func refreshLike(force: Bool = false) {
        let state = spotify.state
        guard state.hasTrack, library.isConnected else {
            likeTrackID = ""
            currentLiked = nil
            bar.barView.setLike(.unavailable)
            return
        }
        guard force || state.trackID != likeTrackID else { return }
        likeTrackID = state.trackID
        currentLiked = nil
        bar.barView.setLike(.unknown)
        let id = state.trackID
        library.fetchSaved(trackID: id) { [weak self] saved in
            guard let self, id == self.spotify.state.trackID else { return }
            self.currentLiked = saved
            self.bar.barView.setLike(saved.map { $0 ? .liked : .notLiked } ?? .unknown)
        }
    }

    private func toggleLike() {
        guard library.isConnected else {
            showLikeSetup()
            return
        }
        let id = spotify.state.trackID
        guard !id.isEmpty, let liked = currentLiked else { return }
        let wanted = !liked
        currentLiked = wanted
        bar.barView.setLike(wanted ? .liked : .notLiked)   // respuesta inmediata
        library.setSaved(wanted, trackID: id) { [weak self] ok in
            guard let self, !ok, id == self.spotify.state.trackID else { return }
            self.currentLiked = liked                          // si falló, vuelve como estaba
            self.bar.barView.setLike(liked ? .liked : .notLiked)
        }
    }

    @objc private func showLikeSetup() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Conecta tu Spotify para usar «Me gusta»"
        alert.informativeText = """
        Solo se hace una vez:
        1. Abre el panel de desarrolladores de Spotify y crea una app llamada «Ondas».
        2. En «Redirect URIs» pon \(SpotifyLibrary.redirectURI) y marca «Web API».
        3. Copia su «Client ID», pégalo aquí y pulsa Conectar.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Client ID"
        field.stringValue = library.clientID ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Conectar")
        alert.addButton(withTitle: "Abrir el panel de Spotify")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let clientID = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clientID.isEmpty else { return }
            library.clientID = clientID
            library.connect()
        case .alertSecondButtonReturn:
            if let url = URL(string: "https://developer.spotify.com/dashboard") { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    @objc private func disconnectSpotify() {
        library.disconnect()
    }

    // MARK: - Animación, audio y teclado

    @objc private func macWoke(_ note: Notification) {
        keyboard.restore()
        weather.refresh()
        bringBarBack()
    }

    @objc private func screensWoke(_ note: Notification) {
        bringBarBack()
    }

    /// Tras dormir, bloquear o cambiar de usuario, la barra vuelve (salvo que la hubieras cerrado con la X).
    /// Dos intentos: la Touch Bar tarda un poco en estar lista al despertar.
    private func bringBarBack() {
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.bar.restoreAfterWake() }
        }
    }

    private func keyPressed(at position: CGFloat) {
        keyboard.keyPressed(now: CACurrentMediaTime())
        if bar.isPresented { bar.barView.keyWave(at: position) }
    }

    private func renderFrame() {
        let now = CACurrentMediaTime()
        let dt = lastFrame == 0 ? 1.0 / 60 : min(0.05, now - lastFrame)
        lastFrame = now

        var audio: AudioSnapshot?
        if realAudio && analyzer.isRunning {
            let snapshot = analyzer.snapshot()
            if snapshot.hasSound { audio = snapshot }
        }
        let playing = spotify.state.isPlaying
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        pulse.update(audio: audio, playing: playing, calm: calm, dt: dt)
        keyboard.update(now: now, dt: dt)

        guard bar.isPresented else { return }
        let dancing = playing || bar.barView.critterPreviewMode == .dancing
        let beat = groove.update(audio: audio, playing: dancing, trackID: spotify.state.trackID, now: now, dt: dt)
        bar.barView.tick(levels: audio?.bands, pulse: pulse.value, groove: beat, now: now)
        bar.syncPulse()
    }

    /// Escucha el audio de Spotify solo cuando hace falta (con la barra a la vista).
    private func manageAudio() {
        guard realAudio, spotify.isRunning, bar.isPresented else {
            if analyzer.isRunning { analyzer.stop() }
            return
        }
        guard spotify.state.isPlaying else { return }
        let hasSound = analyzer.isRunning && analyzer.snapshot().hasSound
        if hasSound != hadRealAudio {
            hadRealAudio = hasSound
            Log.audio.notice("\(hasSound ? "Llega el audio real de Spotify" : "Sin audio real: brillo quieto", privacy: .public)")
        }
        if hasSound {
            audioBackoff = 3
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextAudioAttempt else { return }
        let started = analyzer.start()
        Log.audio.notice("Escucha de audio: \(started ? "en marcha" : (self.analyzer.lastError ?? "falló"), privacy: .public)")
        nextAudioAttempt = now + audioBackoff
        audioBackoff = min(60, audioBackoff * 2)
    }

    // MARK: - Abrir al encender la Mac

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.notice("Abrir al encender: \(enabled ? "sí" : "no", privacy: .public)")
        } catch {
            Log.app.error("Abrir al encender falló: \(error.localizedDescription, privacy: .public)")
        }
        rebuildMenu()
    }

    // MARK: - Menú de la barra de menús

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Ondas")
        item.menu = NSMenu()
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        menu.addItem(withTitle: "Mostrar en la Touch Bar", action: #selector(showBar), keyEquivalent: "").target = self
        addToggle(to: menu, title: "Abrir sola al usar Spotify", on: autoShow, action: #selector(toggleAutoShow))
        addToggle(to: menu, title: "Barras con la música real", on: realAudio, action: #selector(toggleRealAudio))
        addToggle(to: menu, title: "Bichito bailando", on: critterOn, action: #selector(toggleCritter))
        // Ondas al escribir: activar y elegir cuánta luz queda en el teclado sin escribir.
        let typing = NSMenu()
        addToggle(to: typing, title: "Activadas (teclado y Touch Bar)", on: typingWaves, action: #selector(toggleTypingWaves))
        typing.addItem(.separator())
        typing.addItem(withTitle: "Luz del teclado sin escribir", action: nil, keyEquivalent: "").isEnabled = false
        for option in Theme.Keyboard.restOptions {
            let item = typing.addItem(withTitle: option.title, action: #selector(chooseKeyboardRest(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.level
            item.indentationLevel = 1
            item.state = abs(keyboardRest - option.level) < 0.01 ? .on : .off
        }
        let typingItem = menu.addItem(withTitle: "Ondas al escribir", action: nil, keyEquivalent: "")
        typingItem.submenu = typing
        addToggle(to: menu, title: "Abrir al encender la Mac", on: openAtLogin, action: #selector(toggleOpenAtLogin))

        menu.addItem(.separator())
        if library.isConnected {
            menu.addItem(withTitle: "Desconectar «Me gusta» de Spotify", action: #selector(disconnectSpotify), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Conectar «Me gusta» de Spotify…", action: #selector(showLikeSetup), keyEquivalent: "").target = self
        }
        if spotify.automationDenied {
            menu.addItem(withTitle: "Dar permiso para controlar Spotify…", action: #selector(openAutomationSettings), keyEquivalent: "").target = self
        }
        if typingWaves && !keystrokes.isRunning {
            menu.addItem(withTitle: "Dar permiso de Monitorización de entrada…", action: #selector(openInputMonitoringSettings), keyEquivalent: "").target = self
        }
        if weather.access == .denied {
            menu.addItem(withTitle: "Dar permiso de ubicación para el clima…", action: #selector(openLocationSettings), keyEquivalent: "").target = self
        }
        if wantsOpenAtLogin && SMAppService.mainApp.status == .requiresApproval {
            menu.addItem(withTitle: "Permitir que se abra al encender la Mac…", action: #selector(openLoginItemsSettings), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Salir de Ondas", action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func addToggle(to menu: NSMenu, title: String, on: Bool, action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
    }

    @objc private func showBar() {
        bar.present(automatic: false)
    }

    @objc private func toggleAutoShow() {
        autoShow.toggle()
        bar.autoShowWithSpotify = autoShow
        rebuildMenu()
    }

    @objc private func toggleRealAudio() {
        realAudio.toggle()
        if !realAudio { analyzer.stop() }
        audioBackoff = 3
        nextAudioAttempt = 0
        rebuildMenu()
    }

    @objc private func toggleCritter() {
        critterOn.toggle()
        bar.barView.critterEnabled = critterOn
        rebuildMenu()
    }

    @objc private func toggleTypingWaves() {
        typingWaves.toggle()
        if typingWaves {
            keystrokes.start()
            keyboard.activate(now: CACurrentMediaTime())
        } else {
            keystrokes.stop()
            keyboard.restore()
        }
        rebuildMenu()
    }

    @objc private func chooseKeyboardRest(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? Float else { return }
        keyboardRest = level
        keyboard.restLevel = level
        rebuildMenu()
    }

    @objc private func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleOpenAtLogin() {
        wantsOpenAtLogin = !openAtLogin
        setOpenAtLogin(wantsOpenAtLogin)
    }

    @objc private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
