import AppKit
import CryptoKit
import Network
import Security

/// "Me gusta" de Spotify con su Web API. Inicio de sesión PKCE: no se guarda ninguna contraseña,
/// solo un token de renovación en el Llavero.
final class SpotifyLibrary {
    static let redirectURI = "http://127.0.0.1:8721/callback"
    private static let port: NWEndpoint.Port = 8721
    private static let scopes = "user-library-read user-library-modify"

    /// Se conectó o desconectó la cuenta.
    var onStateChange: (() -> Void)?

    var clientID: String? {
        get { UserDefaults.standard.string(forKey: "spotifyClientID") }
        set { UserDefaults.standard.set(newValue, forKey: "spotifyClientID") }
    }

    var isConnected: Bool { refreshToken != nil }

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var listener: NWListener?
    private var verifier = ""
    private var expectedState = ""
    private lazy var refreshToken: String? = Keychain.read()

    // MARK: - Conectar

    /// Abre el navegador para que aceptes en Spotify; la respuesta vuelve a Ondas por 127.0.0.1.
    func connect() {
        guard let clientID, !clientID.isEmpty else { return }
        verifier = Self.randomString(64)
        expectedState = Self.randomString(16)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        startListener()
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: expectedState)
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    func disconnect() {
        accessToken = nil
        refreshToken = nil
        Keychain.write(nil)
        onStateChange?()
    }

    // MARK: - Me gusta

    // Desde febrero de 2026 las apps en modo desarrollo usan /me/library (con URIs) en vez de /me/tracks.

    func fetchSaved(trackID: String, completion: @escaping (Bool?) -> Void) {
        guard let uris = Self.urisParameter(for: trackID) else { return completion(nil) }
        withToken { token in
            guard let token, let url = URL(string: "https://api.spotify.com/v1/me/library/contains?uris=\(uris)") else { return completion(nil) }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request) { data, response, error in
                let saved = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Bool] })?.first
                if saved == nil {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let body = data.flatMap { String(data: $0.prefix(300), encoding: .utf8) } ?? error?.localizedDescription ?? "sin respuesta"
                    Log.spotify.error("¿Me gusta? falló: HTTP \(status, privacy: .public) \(body, privacy: .public)")
                }
                DispatchQueue.main.async { completion(saved) }
            }.resume()
        }
    }

    func setSaved(_ saved: Bool, trackID: String, completion: @escaping (Bool) -> Void) {
        guard let uris = Self.urisParameter(for: trackID) else { return completion(false) }
        withToken { token in
            guard let token, let url = URL(string: "https://api.spotify.com/v1/me/library?uris=\(uris)") else { return completion(false) }
            var request = URLRequest(url: url)
            request.httpMethod = saved ? "PUT" : "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                if status >= 300 {
                    let body = data.flatMap { String(data: $0.prefix(300), encoding: .utf8) } ?? ""
                    Log.spotify.error("Me gusta falló: HTTP \(status, privacy: .public) \(body, privacy: .public)")
                }
                DispatchQueue.main.async { completion(status < 300) }
            }.resume()
        }
    }

    // MARK: - Cómo es la canción (para el baile del bichito)

    /// Spotify cerró los datos de audio a las apps nuevas en 2024: se pregunta una vez y, si dice que no, no se insiste.
    private var audioFeaturesClosed = false
    private var artistGenres: [String: [String]] = [:]
    private var songHints: [String: SongHints] = [:]

    /// Lo que Spotify sabe de la canción: tempo, energía y ánimo (si da sus datos de audio) y los géneros del artista.
    func fetchSongHints(trackID: String, completion: @escaping (SongHints?) -> Void) {
        let id = trackID.split(separator: ":").last.map(String.init) ?? trackID
        if let cached = songHints[id] { return completion(cached) }
        withToken { [weak self] token in
            DispatchQueue.main.async {
                guard let self, let token else { return completion(nil) }
                var hints = SongHints()
                let group = DispatchGroup()
                if !self.audioFeaturesClosed {
                    group.enter()
                    self.getJSON("https://api.spotify.com/v1/audio-features/\(id)", token: token) { json, status in
                        if let json {
                            hints.bpm = json["tempo"] as? Double
                            hints.energy = json["energy"] as? Double
                            hints.valence = json["valence"] as? Double
                            Log.spotify.notice("Datos de audio de Spotify: sí (\(Int(hints.bpm ?? 0), privacy: .public) BPM)")
                        } else {
                            self.audioFeaturesClosed = status == 403 || status == 404
                            Log.spotify.notice("Datos de audio de Spotify: no (HTTP \(status, privacy: .public))")
                        }
                        group.leave()
                    }
                }
                group.enter()
                self.fetchGenres(trackID: id, token: token) { genres in
                    hints.genres = genres
                    group.leave()
                }
                group.notify(queue: .main) {
                    let result: SongHints? = hints.isEmpty ? nil : hints
                    if let result { self.songHints[id] = result }
                    completion(result)
                }
            }
        }
    }

    /// Géneros del primer artista de la canción (se guardan por artista).
    private func fetchGenres(trackID: String, token: String, completion: @escaping ([String]) -> Void) {
        getJSON("https://api.spotify.com/v1/tracks/\(trackID)", token: token) { [weak self] json, status in
            guard let self, let artists = json?["artists"] as? [[String: Any]],
                  let artistID = artists.first?["id"] as? String else {
                Log.spotify.notice("Géneros: sin artista (HTTP \(status, privacy: .public))")
                return completion([])
            }
            if let cached = self.artistGenres[artistID] { return completion(cached) }
            self.getJSON("https://api.spotify.com/v1/artists/\(artistID)", token: token) { json, status in
                let genres = json?["genres"] as? [String] ?? []
                self.artistGenres[artistID] = genres
                let list = genres.isEmpty ? "ninguno (HTTP \(status))" : genres.joined(separator: ", ")
                Log.spotify.notice("Géneros del artista: \(list, privacy: .public)")
                completion(genres)
            }
        }
    }

    /// GET a la Web API de Spotify; responde en el hilo principal con el JSON (si fue 200) y el código HTTP.
    private func getJSON(_ address: String, token: String, completion: @escaping ([String: Any]?, Int) -> Void) {
        guard let url = URL(string: address) else { return completion(nil, 0) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = status == 200 ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
            DispatchQueue.main.async { completion(json, status) }
        }.resume()
    }

    // MARK: - Tokens

    private func withToken(_ action: @escaping (String?) -> Void) {
        if let accessToken, Date() < accessExpiry { return action(accessToken) }
        guard let refreshToken, let clientID else { return action(nil) }
        tokenRequest(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]) { [weak self] ok in
            action(ok ? self?.accessToken : nil)
        }
    }

    private func tokenRequest(_ form: [String: String], completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard let self, let token = json?["access_token"] as? String else {
                    Log.spotify.error("Spotify no dio token: \((json?["error_description"] as? String) ?? "sin respuesta", privacy: .public)")
                    completion?(false)
                    return
                }
                let wasConnected = self.isConnected
                self.accessToken = token
                self.accessExpiry = Date().addingTimeInterval(TimeInterval((json?["expires_in"] as? Int) ?? 3600) - 60)
                if let refresh = json?["refresh_token"] as? String {
                    self.refreshToken = refresh
                    Keychain.write(refresh)
                }
                if !wasConnected { self.onStateChange?() }
                completion?(true)
            }
        }.resume()
    }

    // MARK: - Respuesta del navegador (solo escucha en 127.0.0.1)

    private func startListener() {
        listener?.cancel()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: Self.port)
        guard let listener = try? NWListener(using: parameters) else {
            Log.spotify.error("No se pudo escuchar en 127.0.0.1:8721")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let handled = self?.handleCallback(request)
                let page: String
                switch handled {
                case .some(true): page = "<h1>Listo ✓</h1><p>Ondas ya está conectada a tu Spotify. Puedes cerrar esta pestaña.</p>"
                case .some(false): page = "<h1>No se pudo conectar</h1><p>Vuelve a intentarlo desde el menú de Ondas.</p>"
                case .none: page = ""
                }
                let html = "<!doctype html><meta charset=utf-8><title>Ondas</title><body style=\"font-family:-apple-system;background:#000;color:#fff;text-align:center;padding-top:20vh\">\(page)</body>"
                let status = handled == nil ? "404 Not Found" : "200 OK"
                let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        // Si no vuelves en 5 minutos, deja de escuchar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self, weak listener] in
            if let listener, self?.listener === listener {
                listener.cancel()
                self?.listener = nil
            }
        }
    }

    /// true = conectado · false = error · nil = no era la respuesta de Spotify (p. ej. favicon).
    private func handleCallback(_ request: String) -> Bool? {
        guard let line = request.components(separatedBy: "\r\n").first,
              line.hasPrefix("GET /callback"),
              let target = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(target)") else { return nil }
        let items = components.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == expectedState,
              let code = items.first(where: { $0.name == "code" })?.value,
              let clientID else { return false }
        listener?.cancel()
        listener = nil
        tokenRequest(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
                      "client_id": clientID, "code_verifier": verifier])
        return true
    }

    // MARK: - Utilidades

    /// "spotify:track:ID" → "spotify%3Atrack%3AID" para el parámetro `uris`
    /// (las canciones locales no se pueden marcar).
    private static func urisParameter(for uri: String) -> String? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track" else { return nil }
        return formEncode(uri)
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Token de renovación de Spotify en el Llavero de macOS.
private enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.ondas.touchbar.spotify",
        kSecAttrAccount as String: "refresh-token"
    ]

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?) {
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
