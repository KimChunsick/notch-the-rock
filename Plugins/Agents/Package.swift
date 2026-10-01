// swift-tools-version: 6.0
import PackageDescription

// Tests use swift-testing. Under Command Line Tools (no Xcode) SwiftPM passes the swift-testing
// framework directory with -I instead of -F, so the generated test runner cannot import Testing
// and a plain `swift test` fails with "no such module 'Testing'". Run the tests with:
//
//   CLT=/Library/Developer/CommandLineTools/Library/Developer
//   swift test -Xswiftc -F -Xswiftc $CLT/Frameworks \
//     -Xlinker -rpath -Xlinker $CLT/Frameworks -Xlinker -rpath -Xlinker $CLT/usr/lib
//
// The tests never touch ~/.claude or the app's socket folder: the installer works on a settings
// file in a temporary folder and the socket lives in a short temporary path.

let package = Package(
    name: "Agents",
    platforms: [.macOS(.v14)],
    products: [
        // scripts/build-plugin.sh wraps this dylib as Agents.notchplugin. Keep the product name
        // equal to the package folder name.
        .library(name: "Agents", type: .dynamic, targets: ["Agents"]),
        // The command Claude Code hooks run; build-plugin.sh puts it in Contents/Helpers.
        .executable(name: "notch-hook", targets: ["NotchHook"]),
    ],
    dependencies: [
        // The shared SDK. Depend on NotchKit only: the app provides it at run time.
        .package(path: "../../SDK/NotchKit"),
    ],
    targets: [
        .target(name: "Agents", dependencies: ["HookBridge", .product(name: "NotchKit", package: "NotchKit")]),
        // What the plugin and the hook helper share. Foundation and Darwin only: the helper runs in
        // its own process, where NotchKit is not available.
        .target(name: "HookBridge"),
        .executableTarget(name: "NotchHook", dependencies: ["HookBridge"]),
        .testTarget(
            name: "AgentsTests",
            dependencies: ["Agents", "HookBridge", .product(name: "NotchKit", package: "NotchKit")]
        ),
    ]
)
