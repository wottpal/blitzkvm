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
        // Remote approvals (approval/PROTOCOL.md): keys, rosters, requests.
        .package(path: "../apple/ApprovalKit"),
    ],
    targets: [
        // Platform-independent logic (wire protocol, Annex-B handling, key
        // mapping, geometry, the app's side of approvals); unit tested
        // without a window server.
        .target(name: "JetKVMCore", dependencies: [.product(name: "ApprovalKit", package: "ApprovalKit")],
                linkerSettings: [.linkedLibrary("z")]),
        .executableTarget(
            name: "BlitzKVM",
            dependencies: ["JetKVMCore", .product(name: "Sparkle", package: "Sparkle"),
                           .product(name: "ApprovalKit", package: "ApprovalKit")]
        ),
        .testTarget(name: "JetKVMCoreTests",
                    dependencies: ["JetKVMCore", .product(name: "ApprovalKit", package: "ApprovalKit")]),
        // The renderer on the GPU (skipped without Metal).
        .testTarget(name: "BlitzKVMTests", dependencies: ["BlitzKVM"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
