// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Boltbar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Boltbar", targets: ["BoltbarNative"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0")],
    targets: [
        .executableTarget(name: "BoltbarNative", dependencies: [.product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "BoltbarNativeTests", dependencies: ["BoltbarNative"]),
    ]
)
