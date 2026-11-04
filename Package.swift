// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AirHUD",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "AirHUD",
            targets: ["AirHUD"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AirHUD",
            path: "Sources/AirHUD",
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
