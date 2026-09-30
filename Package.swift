// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Tests use swift-testing. Under Command Line Tools (no Xcode) SwiftPM passes the swift-testing
// framework directory with -I instead of -F, so `import Testing` fails. The test target adds the
// framework search path and runtime paths itself. That is not enough for a bare `swift test`: it
// builds, but SwiftPM compiles its generated test runner with global flags only, the runner's
// `#if canImport(Testing)` is false, and it exits 0 without running a single test. Run the tests
// with:
//
//   swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
let commandLineTools = "/Library/Developer/CommandLineTools/Library/Developer"
let testingFlags: (swift: [String], linker: [String]) =
    FileManager.default.fileExists(atPath: "\(commandLineTools)/Frameworks/Testing.framework")
        ? (
            ["-F", "\(commandLineTools)/Frameworks"],
            [
                "-F", "\(commandLineTools)/Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "\(commandLineTools)/Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "\(commandLineTools)/usr/lib",
            ]
        )
        : ([], [])

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
        .testTarget(
            name: "NotchTheRockTests",
            dependencies: ["NotchTheRock"],
            path: "Tests/NotchTheRockTests",
            swiftSettings: [.unsafeFlags(testingFlags.swift)],
            linkerSettings: [.unsafeFlags(testingFlags.linker)]
        ),
    ]
)
