// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UpdatePls",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "UpdatePls", path: "Sources/UpdatePls", exclude: ["Resources"]),
        .testTarget(name: "UpdatePlsTests", dependencies: ["UpdatePls"], path: "Tests/UpdatePlsTests"),
    ]
)
