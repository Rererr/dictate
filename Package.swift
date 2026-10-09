// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dictate",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "Packages/SpeechCore")],
    targets: [
        .target(name: "DictateKit", dependencies: ["SpeechCore"]),
        .executableTarget(name: "Dictate", dependencies: ["DictateKit", "SpeechCore"]),
        .testTarget(name: "DictateKitTests", dependencies: ["DictateKit"]),
    ]
)
