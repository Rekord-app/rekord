// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Rekord", platforms: [.macOS(.v14)],
    products: [.library(name: "RecorderCore", targets: ["RecorderCore"]), .executable(name: "Rekord", targets: ["Rekord"]), .executable(name: "rekord-mcp", targets: ["RekordMCP"])],
    targets: [.target(name: "RecorderCore"), .executableTarget(name: "Rekord", dependencies: ["RecorderCore"]), .executableTarget(name: "RekordMCP", dependencies: ["RecorderCore"]), .executableTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"], path: "Tests/RecorderCoreTests")])
