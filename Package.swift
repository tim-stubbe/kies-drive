// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KiesDrive",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "KiesDriveCore", targets: ["KiesDriveCore"])],
    targets: [
        .target(name: "KiesDriveCore", path: "Sources/KiesDriveCore"),
    ]
)
