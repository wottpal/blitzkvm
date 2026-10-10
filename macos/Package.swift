// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JetKVMDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JetKVMDesktop", targets: ["JetKVMDesktop"]),
    ],
    targets: [
        // Platform-independent logic (wire protocol, Annex-B handling, key
        // mapping, geometry); unit tested without a window server.
        .target(name: "JetKVMCore"),
        .executableTarget(
            name: "JetKVMDesktop",
            dependencies: ["JetKVMCore"]
        ),
        .testTarget(name: "JetKVMCoreTests", dependencies: ["JetKVMCore"]),
    ],
    swiftLanguageModes: [.v5]
)
