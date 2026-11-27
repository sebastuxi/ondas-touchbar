import os

/// Registros de diagnóstico. Para verlos:
/// log show --last 5m --predicate 'subsystem == "com.ondas.touchbar"'
enum Log {
    static let app = Logger(subsystem: "com.ondas.touchbar", category: "app")
    static let spotify = Logger(subsystem: "com.ondas.touchbar", category: "spotify")
    static let audio = Logger(subsystem: "com.ondas.touchbar", category: "audio")
}
