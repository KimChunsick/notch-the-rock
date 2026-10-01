// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "__NAME__",
    platforms: [.macOS(.v14)],
    products: [
        // scripts/build-plugin.sh wraps this dylib as __NAME__.notchplugin. Keep the product name
        // equal to the package folder name.
        .library(name: "__NAME__", type: .dynamic, targets: ["__NAME__"]),
        // Helpers (docs/plugins.md): every other executable or dynamic library product is built into
        // __NAME__.notchplugin/Contents/Helpers. Helpers run outside the app and must not depend on
        // NotchKit. For example, with the matching target below:
        // .executable(name: "__NAME__-helper", targets: ["__NAME__Helper"]),
    ],
    dependencies: [
        // The shared SDK. Depend on NotchKit only: the app provides it at run time.
        .package(path: "__NOTCHKIT_PATH__"),
    ],
    targets: [
        .target(name: "__NAME__", dependencies: [.product(name: "NotchKit", package: "NotchKit")]),
        // .executableTarget(name: "__NAME__Helper"),
    ]
)
