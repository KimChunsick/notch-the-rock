// swift-tools-version: 6.0
import PackageDescription

// The app only. Built-in plugins are separate packages under Plugins/ that scripts/build-plugin.sh
// packages as .notchplugin bundles; the app never references a plugin module at compile time.
let package = Package(
    name: "NotchTheRock",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "SDK/NotchKit"),
    ],
    targets: [
        .executableTarget(
            name: "NotchTheRock",
            dependencies: [.product(name: "NotchKit", package: "NotchKit")],
            path: "Sources/NotchTheRock",
            linkerSettings: [
                // scripts/build-app.sh ships the single NotchKit copy in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
