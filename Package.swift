// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DWSDashboard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DashboardCore", targets: ["DashboardCore"]),
        .executable(name: "DWSDashboard", targets: ["DWSDashboard"])
    ],
    targets: [
        .target(name: "DashboardCore"),
        .executableTarget(name: "DWSDashboard", dependencies: ["DashboardCore"]),
        .testTarget(name: "DashboardCoreTests", dependencies: ["DashboardCore"]),
        .testTarget(name: "DashboardAppTests", dependencies: ["DWSDashboard", "DashboardCore"])
    ],
    swiftLanguageModes: [.v5]
)
