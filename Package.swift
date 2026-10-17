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
        ),
        // Swift Testing 사용 (Xcode 없이 Command Line Tools만으로 실행 가능)
        .testTarget(
            name: "BWAutofillTests",
            dependencies: ["BWAutofill"],
            path: "Tests/BWAutofillTests"
        )
    ]
)
