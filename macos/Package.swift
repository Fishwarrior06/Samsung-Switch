// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SamsungSwitch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SamsungSwitchCore",
            targets: ["SamsungSwitchCore"]
        ),
        .executable(
            name: "SamsungSwitch",
            targets: ["SamsungSwitch"]
        )
    ],
    targets: [
        .target(
            name: "SamsungSwitchCore",
            path: "Sources",
            exclude: ["App"],
            sources: ["Protocol", "BLE", "Audio", "Bluetooth", "Media", "StateMachine"]
        ),
        .executableTarget(
            name: "SamsungSwitch",
            dependencies: ["SamsungSwitchCore"],
            path: "Sources/App",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/App/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "SamsungSwitchTests",
            dependencies: ["SamsungSwitchCore"],
            path: "Tests"
        )
    ]
)
