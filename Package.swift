// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TopNotch",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "TopNotch", path: "Sources/TopNotch")]
)
