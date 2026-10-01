// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppMem",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AppMem",
            path: "Sources/AppMem",
            // Same as ~/projects/Search: the UI is main-thread by nature, and
            // Swift 6 strict isolation adds only ceremony here.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
