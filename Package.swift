// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Hop",
            path: "Sources/Hop",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
