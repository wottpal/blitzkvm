// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BlitzKVM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BlitzKVM", targets: ["BlitzKVM"]),
    ],
    dependencies: [
        // Updates from GitHub releases (EdDSA-signed appcast and archives).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Platform-independent logic (wire protocol, Annex-B handling, key
        // mapping, geometry); unit tested without a window server.
        .target(name: "JetKVMCore", linkerSettings: [.linkedLibrary("z")]),
        .executableTarget(
            name: "BlitzKVM",
            dependencies: ["JetKVMCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "JetKVMCoreTests", dependencies: ["JetKVMCore"]),
        // The renderer on the GPU (skipped without Metal).
        .testTarget(name: "BlitzKVMTests", dependencies: ["BlitzKVM"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
