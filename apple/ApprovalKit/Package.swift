// swift-tools-version:6.0
import PackageDescription

// Approval protocol v1 (approval/PROTOCOL.md) for the Apple platforms: the
// BlitzKVM app, the iOS app and blitzkvm-remote on the target.
let package = Package(
    name: "ApprovalKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ApprovalKit", targets: ["ApprovalKit"])],
    targets: [
        .target(name: "ApprovalKit"),
        .testTarget(name: "ApprovalKitTests", dependencies: ["ApprovalKit"]),
    ],
    swiftLanguageModes: [.v5]
)
