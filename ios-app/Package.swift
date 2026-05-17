// swift-tools-version:5.9
//
// NOTE: This Package.swift exists only to give IDEs a coarse view of the
// project. Actual iOS builds happen with `swiftc` directly via
// `ios-app/build.sh` or the GitHub Actions workflows; SwiftPM cannot build
// iOS executables / app bundles on its own.
import PackageDescription

let package = Package(
    name: "TgWsProxy",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .executable(name: "TgWsProxy", targets: ["TgWsProxy"]),
    ],
    targets: [
        .executableTarget(
            name: "TgWsProxy",
            path: "TgWsProxy/Sources",
            linkerSettings: [
                .linkedFramework("UIKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Network"),
                .linkedFramework("ActivityKit"),
                .linkedFramework("WidgetKit"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
