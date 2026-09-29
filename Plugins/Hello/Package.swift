// swift-tools-version: 6.0
import PackageDescription

// Tests use swift-testing. Under Command Line Tools (no Xcode) a plain `swift test` fails with
// "no such module 'Testing'" (see SDK/NotchKit/Package.swift). Run the tests with:
//
//   CLT=/Library/Developer/CommandLineTools/Library/Developer
//   swift test -Xswiftc -F -Xswiftc $CLT/Frameworks \
//     -Xlinker -rpath -Xlinker $CLT/Frameworks -Xlinker -rpath -Xlinker $CLT/usr/lib

let package = Package(
    name: "Hello",
    platforms: [.macOS(.v14)],
    products: [
        // scripts/build-plugin.sh wraps this dylib as Hello.notchplugin. Keep the product name
        // equal to the package folder name.
        .library(name: "Hello", type: .dynamic, targets: ["Hello"]),
    ],
    dependencies: [
        // The shared SDK. Depend on NotchKit only: the app provides it at run time.
        .package(path: "../../SDK/NotchKit"),
    ],
    targets: [
        .target(name: "Hello", dependencies: [.product(name: "NotchKit", package: "NotchKit")]),
        .testTarget(
            name: "HelloTests",
            dependencies: ["Hello", .product(name: "NotchKit", package: "NotchKit")]
        ),
    ]
)
