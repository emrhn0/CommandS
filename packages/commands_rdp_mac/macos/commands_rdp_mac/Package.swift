// swift-tools-version: 5.9
import PackageDescription

// FreeRDP.xcframework is built by ../../tool/build_freerdp.sh (static FreeRDP,
// WinPR and OpenSSL for arm64 and x86_64). It is not in git.
let package = Package(
    name: "commands_rdp_mac",
    platforms: [
        .macOS("12.0")
    ],
    products: [
        .library(name: "commands-rdp-mac", targets: ["commands_rdp_mac"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .binaryTarget(name: "FreeRDP", path: "FreeRDP.xcframework"),
        .target(
            name: "CRdpMac",
            dependencies: ["FreeRDP"],
            path: "Sources/CRdpMac",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Carbon"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedLibrary("z"),
            ]
        ),
        .target(
            name: "commands_rdp_mac",
            dependencies: [
                "CRdpMac",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/commands_rdp_mac"
        ),
    ]
)
