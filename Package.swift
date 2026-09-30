// swift-tools-version: 6.0
import PackageDescription

// The Rust search core is built by `make core` (cargo) into core/target/release.
let rustLibDir = Context.packageDirectory + "/core/target/release"

let package = Package(
    name: "CmdTab",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CCmdTabCore", path: "Sources/CCmdTabCore"),
        .executableTarget(
            name: "CmdTab",
            dependencies: ["CCmdTabCore"],
            path: "Sources/CmdTab",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibDir, "-Xlinker", "-dead_strip"]),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
