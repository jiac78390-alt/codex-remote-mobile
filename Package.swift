// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexRemote",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexRemoteMac", targets: ["CodexRemoteMac"])
    ],
    targets: [
        .target(name: "CodexRemoteShared"),
        .executableTarget(name: "CodexRemoteMac", dependencies: ["CodexRemoteShared"])
    ]
)
