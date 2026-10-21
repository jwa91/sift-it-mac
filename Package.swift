// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sift-it-mac",
    platforms: [.macOS(.v14)],
    targets: [
        // What the app says to sift-it's engine, and how it reaches it: Foundation only, tested on its own.
        .target(name: "SiftItKit"),
        // The app: the search panel, the menu bar and the settings.
        .executableTarget(name: "SiftIt", dependencies: ["SiftItKit"]),
        .testTarget(name: "SiftItKitTests", dependencies: ["SiftItKit"]),
    ]
)
