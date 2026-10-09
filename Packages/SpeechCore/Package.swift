// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpeechCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SpeechCore", targets: ["SpeechCore"])],
    targets: [
        .target(name: "SpeechCore"),
        .testTarget(name: "SpeechCoreTests", dependencies: ["SpeechCore"]),
    ]
)
