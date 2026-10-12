// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BlitzKVM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BlitzKVM", targets: ["BlitzKVM"]),
    ],
    targets: [
        // Platform-independent logic (wire protocol, Annex-B handling, key
        // mapping, geometry); unit tested without a window server.
        .target(name: "JetKVMCore"),
        .executableTarget(
            name: "BlitzKVM",
            dependencies: ["JetKVMCore"]
        ),
        .testTarget(name: "JetKVMCoreTests", dependencies: ["JetKVMCore"]),
        // The renderer on the GPU (skipped without Metal).
        .testTarget(name: "BlitzKVMTests", dependencies: ["BlitzKVM"]),
    ],
    swiftLanguageModes: [.v5]
)
