// swift-tools-version: 5.9
import PackageDescription

// The protocol Maggie on the Mac and Maggie Mobile speak to each other. No UI;
// both apps depend on it so every message is typed in one place.
let package = Package(
    name: "MaggieRemote",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MaggieRemote", targets: ["MaggieRemote"]),
    ],
    targets: [
        .target(name: "MaggieRemote"),
        .testTarget(name: "MaggieRemoteTests", dependencies: ["MaggieRemote"]),
    ]
)
