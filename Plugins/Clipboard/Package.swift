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
// The tests use private named pasteboards, never the general one, and one throwaway keychain item
// they delete again.

let package = Package(
    name: "Clipboard",
    platforms: [.macOS(.v14)],
    products: [
        // scripts/build-plugin.sh wraps this dylib as Clipboard.notchplugin. Keep the product name
        // equal to the package folder name.
        .library(name: "Clipboard", type: .dynamic, targets: ["Clipboard"]),
    ],
    dependencies: [
        // The shared SDK. Depend on NotchKit only: the app provides it at run time.
        .package(path: "../../SDK/NotchKit"),
    ],
    targets: [
        .target(name: "Clipboard", dependencies: [.product(name: "NotchKit", package: "NotchKit")]),
        .testTarget(
            name: "ClipboardTests",
            dependencies: ["Clipboard", .product(name: "NotchKit", package: "NotchKit")]
        ),
    ]
)
