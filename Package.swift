// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Boltbar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Boltbar", targets: ["BoltbarNative"])],
    targets: [
        .executableTarget(name: "BoltbarNative"),
        .testTarget(name: "BoltbarNativeTests", dependencies: ["BoltbarNative"]),
    ]
)
