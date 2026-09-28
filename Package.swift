// swift-tools-version: 6.4.0
import PackageDescription

let package = Package(
    name: "Amanuensis",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/johnno1962/InjectionLite.git", from: "2.1.3")
    ],
    targets: [
        .executableTarget(
            name: "Amanuensis",
            dependencies: ["InjectionLite"],
            path: "Amanuensis",
            exclude: [
                "Assets.xcassets",
                "Info.entitlements",
                "Info-Debug.entitlements",
                "Info.plist",
                "Screen Capture.aif",
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
