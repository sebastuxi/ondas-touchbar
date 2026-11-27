import AppKit

/// Tokens de diseño de Ondas (diseño «D · Ondas en barras», versión grande).
/// Medidas en puntos: la Touch Bar mide 30 pt de alto (60 px @2x).
/// Espaciados en múltiplos de 8 pt; 4 pt solo para ajustes finos dentro de un componente.
enum Theme {
    /// Escala de la Touch Bar (1 pt = 2 px).
    static let scale: CGFloat = 2

    enum Space {
        static let fine: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        /// Entre bloques de reposo (hora, clima, música): se leen como cosas separadas.
        static let large: CGFloat = 24
    }

    enum Size {
        static let barHeight: CGFloat = 30
        /// Ancho preferido: toda la Touch Bar menos la X (Ondas reemplaza la Control Strip).
        static let barWidth: CGFloat = 952
        /// Si macOS da menos sitio, el espectro se encoge hasta aquí.
        static let barMinWidth: CGFloat = 700
        /// Cuánto se sale el color por los lados para tapar las juntas entre botones.
        static let glowBleed: CGFloat = 16

        /// La X va en el sitio de la tecla Esc: cuadrada, como una tecla.
        static let closeWidth: CGFloat = 44
        static let closeSquare: CGFloat = 30
        static let closeIcon: CGFloat = 12

        /// La foto ocupa todo el alto de la Touch Bar.
        static let artwork: CGFloat = 30
        static let textWidth: CGFloat = 176
        /// Corazón de "Me gusta", junto al nombre de la canción.
        static let heartZone: CGFloat = 34
        static let heartIcon: CGFloat = 18
        static let timeWidth: CGFloat = 40

        /// Una barra cada 6 pt: el número de barras depende del ancho disponible.
        static let barPitch: CGFloat = 6
        /// Parte del hueco de cada barra que se pinta (el resto es separación).
        static let barFill: CGFloat = 0.66
        static let barMinHeight: CGFloat = 3
        static let barMaxHeight: CGFloat = 29

        static let transportButton: CGFloat = 50
        static let playButton: CGFloat = 54
        static let playDisc: CGFloat = 28
        static let transportIcon: CGFloat = 18
        static let playIcon: CGFloat = 14
        static let playheadHeight: CGFloat = 26
        static let knob: CGFloat = 12
        static let trayArtwork: CGFloat = 20

        /// Ancho total de la Touch Bar de tu Mac (2008 px): sirve para centrar la barra de música.
        static let touchBarWidth: CGFloat = 1004
        /// Teclas de brillo y volumen (y las del deslizador): más anchas y separadas entre sí.
        static let keyZone: CGFloat = 52
        static let keyWidth: CGFloat = 44
        static let keyHeight: CGFloat = 30
        static let keyGap: CGFloat = 12
        static let keyIcon: CGFloat = 18
        static let edgeMargin: CGFloat = 4
        static let sliderTrack: CGFloat = 8
        static let sliderKnob: CGFloat = 22
        static let sliderValueWidth: CGFloat = 56

        /// Reposo: hora, clima y pastilla de música centrados (cada bloque mide lo que su texto),
        /// batería a la derecha.
        static let resumeWidth: CGFloat = 230
        static let resumeArt: CGFloat = 22
        static let batteryWidth: CGFloat = 72
        static let weatherIcon: CGFloat = 24

        /// Flecha que aparece al deslizar la canción.
        static let swipeHint: CGFloat = 16
        /// Rayo junto al % al enchufar el cargador.
        static let chargeIcon: CGFloat = 16
    }

    /// Deslizar el dedo sobre la canción: izquierda = siguiente, derecha = anterior (como en el iPhone).
    enum Gesture {
        /// Hasta aquí un toque con temblor sigue siendo un toque (abre Spotify).
        static let slop: CGFloat = 6
        /// Recorrido del dedo para cambiar de canción al soltar.
        static let threshold: CGFloat = 40
        /// La canción sigue al dedo hasta aquí y se frena.
        static let maxOffset: CGFloat = 56
        /// Desde dónde entra la canción nueva.
        static let revealOffset: CGFloat = 40
        /// Bordes difuminados de la zona donde se desliza.
        static let edgeFade: CGFloat = 16
    }

    /// El clima de la pantalla de reposo (Open-Meteo, sin cuenta).
    enum Weather {
        /// Cada cuánto se actualiza.
        static let refresh: TimeInterval = 30 * 60
        /// Si falló (sin internet), se reintenta a los 2 min.
        static let retry: TimeInterval = 2 * 60
        /// Al despertar la Mac no se vuelve a pedir si es más reciente que esto.
        static let minInterval: TimeInterval = 10 * 60
        /// La ubicación se renueva cada 2 h (para el clima basta).
        static let locationMaxAge: TimeInterval = 2 * 3600
        /// Un clima de hace más de 3 h ya no se muestra.
        static let staleAfter: TimeInterval = 3 * 3600
    }

    /// Ola verde al enchufar el cargador: corta y suave, sin destellos.
    enum Charging {
        static let fill: CFTimeInterval = 0.9
        static let hold: CFTimeInterval = 1.3
        static let fade: CFTimeInterval = 0.35
        static let waveAmplitude: CGFloat = 3
        static let wavelength: CGFloat = 20
        /// Velocidad de la ola del borde (radianes por segundo).
        static let waveSpeed: Double = 5
    }

    /// El bichito que baila sobre la barra de progreso (hace de cabezal).
    /// Medidas en pt: cuerpo ovalado, dos antenas, ojos grandes, bracitos y patitas; cabe con sus saltos en 30 pt.
    enum Critter {
        static let bodyWidth: CGFloat = 19
        static let bodyHeight: CGFloat = 14
        static let legLength: CGFloat = 4
        static let armLength: CGFloat = 7.5
        /// Bracitos y patitas: trazo del color del cuerpo con borde oscuro (se ven sobre barras claras y oscuras).
        static let limbWidth: CGFloat = 1.8
        static let limbBorder: CGFloat = 3.4
        /// Halo oscuro alrededor de la silueta: lo separa de las barras de cualquier color.
        static let haloRadius: CGFloat = 2.2
        static let haloOpacity: Float = 0.75
        /// Lo más alto que salta (pt): con las antenas sigue cabiendo en los 30 pt de la Touch Bar.
        static let maxLift: CGFloat = 4.4
        /// Altura del suelo (los pies), desde el borde de abajo de la Touch Bar.
        static let groundY: CGFloat = 1
        /// Zona para tocarlo (pt a cada lado): un toque lo hace reír; arrastrarlo, llevarlo por la canción.
        static let hitRadius: CGFloat = 12
        /// Se queda dentro del espectro para no pisar los tiempos.
        static let edgeInset: CGFloat = 8
        /// Las barras de debajo se atenúan: baila en su propio «escenario» oscuro.
        static let dimRadius: CGFloat = 18
        static let dimAmount: Float = 0.85
        /// Adelanto para que el paso caiga con el golpe que se oye, no con el que se detecta (s).
        static let beatLead: Double = 0.06
        /// Su paso especial: como mucho uno cada 5 s.
        static let moveCooldown: Double = 5
        static let moveDuration: Double = 0.7
        static let reactDuration: Double = 0.7
        static let popDuration: Double = 0.4
        /// Colores fijos (el cuerpo y las antenas salen de la portada de cada canción).
        static let outline = NSColor(white: 0, alpha: 0.6)
        static let pupil = NSColor(hex: 0x141018)
        static let mouth = NSColor(hex: 0x2A0F14)
        static let cheek = NSColor(hex: 0xFF8FB3, alpha: 0.55)
    }

    /// Cuándo la Touch Bar pasa a reposo (hora, clima…).
    enum Idle {
        /// Segundos en pausa antes de pasar a reposo.
        static let after: TimeInterval = 60
        /// Respiración lenta del color de fondo en reposo (s por ciclo).
        static let breathPeriod: Double = 6
        static let crossfade: CFTimeInterval = 0.4
    }

    /// Líneas base del texto, medidas desde arriba.
    enum Baseline {
        static let title: CGFloat = 15.5
        static let artist: CGFloat = 27.5
        static let time: CGFloat = 19.5
        static let clock: CGFloat = 16
        static let date: CGFloat = 27.5
        static let resumeCaption: CGFloat = 12.5
        static let resumeTitle: CGFloat = 25.5
        /// Una sola línea de 18 pt centrada en la barra (el % de la carga).
        static let single: CGFloat = 21.5
    }

    enum Radius {
        static let artwork: CGFloat = 7
        static let close: CGFloat = 8
    }

    enum Colors {
        static let background = NSColor.black
        static let title = NSColor.white
        /// Más claros que antes porque ahora van sobre color (llevan sombra oscura).
        static let artist = NSColor(white: 1, alpha: 0.86)
        static let time = NSColor(white: 1, alpha: 0.8)
        static let textShadow = NSColor.black
        /// Barras sin canción: 3.1:1 (componente de interfaz).
        static let idleBar = NSColor(white: 1, alpha: 0.36)
        /// Lo que falta por sonar: el color de la portada atenuado.
        static let upcomingBarAlpha: CGFloat = 0.5
        static let closeFill = NSColor(white: 1, alpha: 0.16)
        static let closeIcon = NSColor(white: 1, alpha: 0.9)
        static let keyFill = NSColor(white: 1, alpha: 0.16)
        /// Relleno de nivel dentro de las teclas de brillo y volumen (color de la portada).
        static let keyLevelAlpha: CGFloat = 0.55
        static let sliderTrack = NSColor(white: 1, alpha: 0.22)
        static let icon = NSColor(white: 1, alpha: 0.92)
        static let onAccent = NSColor(white: 0.04, alpha: 1)
        static let placeholder = NSColor(white: 1, alpha: 0.10)
        /// Carga: verde oscuro a medio (texto blanco encima con 5.4:1 o más) y el borde de la ola brillante.
        static let chargeDeep = NSColor(hex: 0x0B3B1C)
        static let chargeMid = NSColor(hex: 0x1E7A3C)
        static let chargeEdge = NSColor(hex: 0x30D158)
    }

    enum Fonts {
        static let title = NSFont.systemFont(ofSize: 15, weight: .bold)
        static let artist = NSFont.systemFont(ofSize: 11, weight: .medium)
        static let time = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        static let sliderValue = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        static let clock = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        static let date = NSFont.systemFont(ofSize: 11, weight: .medium)
        static let resumeCaption = NSFont.systemFont(ofSize: 10, weight: .medium)
        static let resumeTitle = NSFont.systemFont(ofSize: 12, weight: .semibold)
        static let battery = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }

    /// Toda la barra se ilumina con los colores de la portada al ritmo de la canción.
    enum Pulse {
        /// En el pico los iconos blancos aún tienen 3.3:1 sobre el color.
        static let resting: Float = 0.2
        static let peak: Float = 0.6
        static let paused: Float = 0.08
    }

    /// Luz del teclado: media luz fija y sube según cuánto escribas.
    enum Keyboard {
        /// Media luz para ver las teclas cuando no escribes. La escala del teclado no es lineal:
        /// al 40 % la luz real casi no se ve, por eso la base es más alta.
        static let restLevel: Float = 0.65
        /// Opciones del menú para la luz sin escribir.
        static let restOptions: [(title: String, level: Float)] = [("Baja (40 %)", 0.4), ("Media (65 %)", 0.65), ("Alta (85 %)", 0.85)]
        /// Cuánta luz suma cada tecla (0…1): a 2 teclas/s queda ~75 %, a 4 teclas/s casi al 100 %.
        static let typingStep: Float = 0.12
        /// Cuánto baja por segundo cuando dejas de escribir.
        static let typingDecay: Float = 0.7
        /// Suavizado: la luz nunca salta de golpe.
        static let smoothing: Double = 6
        /// Sin escribir durante este tiempo (s), la luz vuelve a manos de macOS.
        static let awayAfter: CFTimeInterval = 300
        /// Cambios por segundo (más sería trabajo de sobra para el sistema).
        static let refreshRate: Double = 30
    }

    enum Motion {
        static let press: CFTimeInterval = 0.1
        static let ripple: CFTimeInterval = 0.45
        /// Onda en la Touch Bar con cada tecla.
        static let keyWave: CFTimeInterval = 0.9
        /// Como mucho 3 destellos por segundo con la música (umbral seguro para la vista).
        static let minFlashInterval: Double = 0.34
        /// El deslizador de brillo o volumen vuelve solo a la canción tras este tiempo sin tocarlo.
        static let sliderAutoClose: TimeInterval = 2.5
        static let sliderFade: CFTimeInterval = 0.2
        static let colorChange: CFTimeInterval = 0.6
        /// Velocidad del brillo que recorre el nombre de la canción (pt/s).
        static let shimmerSpeed: Double = 30
        /// Deslizar la canción: sale rápido, la nueva entra con un rebote suave.
        static let swipeOut: CFTimeInterval = 0.16
        static let swipeIn: CFTimeInterval = 0.32
        /// Si la canción nueva tarda, se muestra igual pasado este tiempo.
        static let swipeRevealTimeout: CFTimeInterval = 1.2
    }
}
