// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ondas",
    platforms: [.macOS("14.2")],
    targets: [
        // Envoltorio en Objective-C de la API privada de la Touch Bar
        // (la misma que usan MTMR y Pock para mostrar barras encima de cualquier app).
        .target(
            name: "TouchBarPrivate",
            path: "Sources/TouchBarPrivate",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "Ondas",
            dependencies: ["TouchBarPrivate"],
            path: "Sources/Ondas",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreLocation")
            ]
        )
    ]
)
