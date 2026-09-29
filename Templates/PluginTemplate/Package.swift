// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "__NAME__",
    platforms: [.macOS(.v14)],
    products: [
        // scripts/build-plugin.sh wraps this dylib as __NAME__.notchplugin. Keep the product name
        // equal to the package folder name.
        .library(name: "__NAME__", type: .dynamic, targets: ["__NAME__"]),
    ],
    dependencies: [
        // The shared SDK. Depend on NotchKit only: the app provides it at run time.
        .package(path: "__NOTCHKIT_PATH__"),
    ],
    targets: [
        .target(name: "__NAME__", dependencies: [.product(name: "NotchKit", package: "NotchKit")]),
    ]
)
