// swift-tools-version: 6.0
import PackageDescription

// notchkit-probe lives in its own package on purpose: an executable in the NotchKit package would
// link the NotchKit target statically, and a plugin loaded next to that copy would bind to the
// shared dylib instead, so the entry type check would fail. Depending on the dynamic product keeps
// exactly one NotchKit in the process, as in the app.
let package = Package(
    name: "NotchKitProbe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "notchkit-probe", targets: ["NotchKitProbe"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "NotchKitProbe",
            dependencies: [.product(name: "NotchKit", package: "NotchKit")]
        ),
    ]
)
