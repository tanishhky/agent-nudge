// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentNudge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentNudge", targets: ["AgentNudge"])
    ],
    targets: [
        .executableTarget(
            name: "AgentNudge",
            path: "Sources/AgentNudge",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
