// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DWSAssistant",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DashboardCore", targets: ["DashboardCore"]),
        .executable(name: "DWSAssistant", targets: ["DWSAssistant"])
    ],
    targets: [
        .target(name: "DashboardCore"),
        .executableTarget(name: "DWSAssistant", dependencies: ["DashboardCore"], resources: [.process("Resources")]),
        .testTarget(name: "DashboardCoreTests", dependencies: ["DashboardCore"]),
        .testTarget(name: "DashboardAppTests", dependencies: ["DWSAssistant", "DashboardCore"])
    ],
    swiftLanguageModes: [.v5]
)
