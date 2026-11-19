// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DWSAssistant",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        .executable(name: "DWSAssistant", targets: ["DWSAssistant"])
    ],
    targets: [
        .target(name: "AssistantCore"),
        .executableTarget(name: "DWSAssistant", dependencies: ["AssistantCore"], resources: [.process("Resources")]),
        .testTarget(name: "AssistantCoreTests", dependencies: ["AssistantCore"]),
        .testTarget(name: "AssistantAppTests", dependencies: ["DWSAssistant", "AssistantCore"])
    ],
    swiftLanguageModes: [.v5]
)
