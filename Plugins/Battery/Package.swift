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
    name: "Battery",
    platforms: [.macOS(.v14)],
    products: [
        // scripts/build-plugin.sh wraps this dylib as Battery.notchplugin. Keep the product name
        // equal to the package folder name.
        .library(name: "Battery", type: .dynamic, targets: ["Battery"]),
    ],
    dependencies: [
        // The shared SDK. Depend on NotchKit only: the app provides it at run time.
        .package(path: "../../SDK/NotchKit"),
    ],
    targets: [
        .target(name: "Battery", dependencies: [.product(name: "NotchKit", package: "NotchKit")]),
        .testTarget(name: "BatteryTests", dependencies: ["Battery"]),
    ]
)
