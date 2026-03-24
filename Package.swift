// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BWAutofill",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "BWAutofill",
            path: "Sources/BWAutofill",
            linkerSettings: [
                .unsafeFlags(["-framework", "Carbon"])
            ]
        )
    ]
)
