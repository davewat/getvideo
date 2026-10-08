// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GetVideo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GetVideo", path: "Sources/GetVideo", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "GetVideoTests", dependencies: ["GetVideo"], path: "Tests/GetVideoTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
