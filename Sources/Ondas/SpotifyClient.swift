import AppKit
import CoreServices

/// Lo que está sonando.
struct NowPlaying: Equatable {
    var trackID = ""
    var title = ""
    var artist = ""
    /// Segundos.
    var duration: Double = 0
    /// Segundos en el instante `positionDate`.
    var position: Double = 0
    var positionDate = Date.distantPast
    var isPlaying = false
    var artworkURL: URL?

    var hasTrack: Bool { !title.isEmpty }

    func position(at date: Date) -> Double {
        let base = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return min(max(0, base), max(0, duration))
    }
}

/// Lee Spotify (notificaciones + AppleScript) y le manda órdenes.
final class SpotifyClient {
    static let bundleID = "com.spotify.client"

    var onChange: ((NowPlaying) -> Void)?
    var onArtwork: ((String, CGImage) -> Void)?
    /// Cambió el permiso de Automatización (para avisar en el menú).
    var onAutomationChange: (() -> Void)?

    private(set) var state = NowPlaying()
    private(set) var automationDenied = false

    private var automationStatus: OSStatus?
    private var askingPermission = false
    private var pollTimer: Timer?
    private var scripts: [String: NSAppleScript] = [:]
    private var artworkCache: [String: CGImage] = [:]
    private var artworkOrder: [String] = []
    private var loadingArtworkFor: String?

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    private var automationAllowed: Bool { automationStatus == noErr }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playbackChanged(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, suspensionBehavior: .deliverImmediately)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(applicationsChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(applicationsChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Órdenes

    func playPause() {
        guard isRunning else { launch(); return }
        var next = state
        next.position = next.position(at: Date())
        next.positionDate = Date()
        next.isPlaying.toggle()
        publish(next)
        send("playpause")
    }

    func next() { send("next track") }

    func previous() { send("previous track") }

    func seek(to seconds: Double) {
        var next = state
        next.position = seconds
        next.positionDate = Date()
        publish(next)
        send(String(format: "set player position to %.2f", locale: Locale(identifier: "en_US_POSIX"), seconds), cache: false)
    }

    func activate() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first {
            app.activate()
        } else {
            launch()
        }
    }

    func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Lectura

    func refresh() {
        guard isRunning else {
            if state.hasTrack || state.isPlaying { publish(NowPlaying()) }
            return
        }
        guard automationAllowed else {
            ensureAutomationPermission()
            return
        }
        let body = """
        tell application id "com.spotify.client"
            set playerState to (player state as string)
            if playerState is "stopped" then return {playerState}
            set theTrack to current track
            return {playerState, player position, (id of theTrack), (name of theTrack), (artist of theTrack), (duration of theTrack), (artwork url of theTrack)}
        end tell
        """
        guard let list = run(body, cache: true), list.numberOfItems >= 1 else { return }
        let playerState = list.atIndex(1)?.stringValue ?? ""
        Log.spotify.notice("""
            Estado: \(playerState, privacy: .public) · posición \(list.atIndex(2)?.doubleValue ?? -1, privacy: .public) \
            · duración \(list.atIndex(6)?.int32Value ?? -1, privacy: .public) \
            · carátula \((list.atIndex(7)?.stringValue ?? "—").isEmpty ? "vacía" : "ok", privacy: .public)
            """)
        guard playerState != "stopped", list.numberOfItems >= 7 else {
            publish(NowPlaying())
            return
        }
        var next = state
        let trackID = list.atIndex(3)?.stringValue ?? ""
        if trackID != next.trackID { next.artworkURL = nil }
        next.trackID = trackID
        next.title = list.atIndex(4)?.stringValue ?? next.title
        next.artist = list.atIndex(5)?.stringValue ?? next.artist
        // Spotify devuelve la duración en milisegundos (su diccionario dice segundos).
        let rawDuration = Double(list.atIndex(6)?.int32Value ?? 0)
        if rawDuration > 0 { next.duration = rawDuration >= 10_000 ? rawDuration / 1000 : rawDuration }
        if let position = list.atIndex(2)?.doubleValue { next.position = position }
        next.positionDate = Date()
        next.isPlaying = playerState == "playing"
        if let text = list.atIndex(7)?.stringValue, let url = URL(string: text) { next.artworkURL = url }
        publish(next)
    }

    @objc private func playbackChanged(_ note: Notification) {
        guard let info = note.userInfo else { return }
        let playerState = info["Player State"] as? String ?? ""
        if playerState == "Stopped" {
            publish(NowPlaying())
            return
        }
        var next = state
        let trackID = info["Track ID"] as? String ?? next.trackID
        if trackID != next.trackID { next.artworkURL = nil }
        next.trackID = trackID
        next.title = info["Name"] as? String ?? next.title
        next.artist = info["Artist"] as? String ?? next.artist
        if let ms = (info["Duration"] as? NSNumber)?.doubleValue, ms > 0 { next.duration = ms / 1000 }
        if let position = (info["Playback Position"] as? NSNumber)?.doubleValue {
            next.position = position
            next.positionDate = Date()
        }
        next.isPlaying = playerState == "Playing"
        publish(next)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refresh() }
    }

    @objc private func applicationsChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.bundleID else { return }
        if note.name == NSWorkspace.didTerminateApplicationNotification {
            automationStatus = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    private func publish(_ next: NowPlaying) {
        let previous = state
        state = next
        if next != previous { onChange?(next) }
        if !next.trackID.isEmpty { loadArtwork(for: next) }
    }

    // MARK: - Permiso de Automatización

    /// Pregunta el permiso en segundo plano para no congelar la barra mientras macOS muestra el aviso.
    private func ensureAutomationPermission() {
        guard !automationAllowed, !askingPermission, isRunning else { return }
        askingPermission = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let target = NSAppleEventDescriptor(bundleIdentifier: SpotifyClient.bundleID)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
            DispatchQueue.main.async {
                guard let self else { return }
                Log.spotify.notice("Permiso de Automatización: \(status, privacy: .public)")
                self.askingPermission = false
                self.automationStatus = status
                let denied = status == OSStatus(errAEEventNotPermitted)
                if denied != self.automationDenied {
                    self.automationDenied = denied
                    self.onAutomationChange?()
                }
                if status == noErr { self.refresh() }
            }
        }
    }

    // MARK: - AppleScript

    private func send(_ command: String, cache: Bool = true) {
        guard isRunning, automationAllowed else {
            ensureAutomationPermission()
            return
        }
        run("tell application id \"com.spotify.client\" to \(command)", cache: cache)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
    }

    @discardableResult
    private func run(_ body: String, cache: Bool) -> NSAppleEventDescriptor? {
        let source = "with timeout of 1 second\n\(body)\nend timeout"
        let script: NSAppleScript
        if let cached = scripts[source] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else { return nil }
            if cache { scripts[source] = created }
            script = created
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            Log.spotify.error("AppleScript falló: \(error[NSAppleScript.errorNumber] as? Int ?? 0, privacy: .public) \(error[NSAppleScript.errorMessage] as? String ?? "", privacy: .public)")
            if (error[NSAppleScript.errorNumber] as? Int) == Int(errAEEventNotPermitted) {
                automationStatus = OSStatus(errAEEventNotPermitted)
                if !automationDenied {
                    automationDenied = true
                    onAutomationChange?()
                }
            }
            return nil
        }
        return result
    }

    // MARK: - Carátula

    private func loadArtwork(for track: NowPlaying) {
        let id = track.trackID
        if let cached = artworkCache[id] {
            onArtwork?(id, cached)
            return
        }
        guard loadingArtworkFor != id else { return }
        if let url = track.artworkURL {
            loadingArtworkFor = id
            Log.spotify.notice("Descargando carátula")
            download(url, for: id)
        } else if let oEmbed = oEmbedURL(for: id) {
            // Sin URL de AppleScript: la carátula sale del enlace público de la canción.
            loadingArtworkFor = id
            Log.spotify.notice("Buscando carátula por el enlace público")
            URLSession.shared.dataTask(with: oEmbed) { [weak self] data, _, _ in
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let thumbnail = json["thumbnail_url"] as? String,
                      let url = URL(string: thumbnail) else {
                    DispatchQueue.main.async { if self?.loadingArtworkFor == id { self?.loadingArtworkFor = nil } }
                    return
                }
                self?.download(url, for: id)
            }.resume()
        }
    }

    private func download(_ url: URL, for id: String) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            let image = data.flatMap { NSImage(data: $0) }?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.loadingArtworkFor == id { self.loadingArtworkFor = nil }
                guard let image else {
                    Log.spotify.error("No se pudo bajar la carátula: \(error?.localizedDescription ?? "imagen vacía", privacy: .public)")
                    return
                }
                Log.spotify.notice("Carátula lista (\(image.width, privacy: .public) px)")
                self.artworkCache[id] = image
                self.artworkOrder.append(id)
                if self.artworkOrder.count > 12 {
                    self.artworkCache[self.artworkOrder.removeFirst()] = nil
                }
                self.onArtwork?(id, image)
            }
        }.resume()
    }

    /// "spotify:track:ID" → https://open.spotify.com/oembed?url=https://open.spotify.com/track/ID
    private func oEmbedURL(for trackID: String) -> URL? {
        let parts = trackID.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify" else { return nil }
        var components = URLComponents(string: "https://open.spotify.com/oembed")
        components?.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/\(parts[1])/\(parts[2])")]
        return components?.url
    }
}
