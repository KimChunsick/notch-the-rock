// swift-tools-version: 6.0
import PackageDescription

// Tests use swift-testing. Under Command Line Tools (no Xcode) SwiftPM passes the swift-testing
// framework directory with -I instead of -F, so the generated test runner cannot import Testing
// and a plain `swift test` fails with "no such module 'Testing'". Run the tests with:
//
//   CLT=/Library/Developer/CommandLineTools/Library/Developer
//   swift test -Xswiftc -F -Xswiftc $CLT/Frameworks \
//     -Xlinker -rpath -Xlinker $CLT/Frameworks -Xlinker -rpath -Xlinker $CLT/usr/lib

let package = Package(
    name: "Volume",
    platforms: [.macOS(.v14)],
    products: [
        // scripts/build-plugin.sh wraps this dylib as Volume.notchplugin. Keep the product name
        // equal to the package folder name.
        .library(name: "Volume", type: .dynamic, targets: ["Volume"]),
    ],
    dependencies: [
        // The shared SDK. Depend on NotchKit only: the app provides it at run time.
        .package(path: "../../SDK/NotchKit"),
    ],
    targets: [
        .target(name: "Volume", dependencies: [.product(name: "NotchKit", package: "NotchKit")]),
        .testTarget(name: "VolumeTests", dependencies: ["Volume"]),
    ]
)
