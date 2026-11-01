// swift-tools-version:6.0
import PackageDescription

// blitzkvm-remote: the target side of remote approvals (approval/PROTOCOL.md)
// on the Mac a JetKVM controls. One binary: the root daemon, the per-user
// agent, and the `confirm` and `pam` clients.
let package = Package(
    name: "blitzkvm-remote",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "blitzkvm-remote", targets: ["blitzkvm-remote"])],
    dependencies: [.package(path: "../../apple/ApprovalKit")],
    targets: [
        // Everything testable: the link, the local socket, processes and
        // signatures, asks and grants, screen evidence, the step driver and
        // the key map.
        .target(name: "RemoteCore", dependencies: [.product(name: "ApprovalKit", package: "ApprovalKit")],
                linkerSettings: [.linkedLibrary("bsm")]), // audit_token_to_asid
        .executableTarget(name: "blitzkvm-remote",
                          dependencies: ["RemoteCore", .product(name: "ApprovalKit", package: "ApprovalKit")]),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"]),
    ],
    swiftLanguageModes: [.v5]
)
