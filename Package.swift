// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacAboboo",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "MacAboboo",
            targets: ["MacAbobooApp"]
        ),
        .library(
            name: "MacAbobooKit",
            targets: ["MacAbobooKit"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MacAbobooKit",
            dependencies: [],
            path: "Sources/MacAboboo",
            resources: [
                .process("Resources")
            ],
            cSettings: [
                .define("GL_SILENCE_DEPRECATION")
            ],
            swiftSettings: [
                .define("GL_SILENCE_DEPRECATION")
            ]
        ),
        .executableTarget(
            name: "MacAbobooApp",
            dependencies: ["MacAbobooKit"],
            path: "Sources/MacAbobooApp",
            exclude: [
                "Info.plist"
            ],
            cSettings: [
                .define("GL_SILENCE_DEPRECATION")
            ],
            swiftSettings: [
                .define("GL_SILENCE_DEPRECATION")
            ]
        ),
        .testTarget(
            name: "MacAbobooTests",
            dependencies: ["MacAbobooKit"],
            path: "Tests/MacAbobooTests",
            cSettings: [
                .define("GL_SILENCE_DEPRECATION")
            ],
            swiftSettings: [
                .define("GL_SILENCE_DEPRECATION")
            ]
        )
    ]
)
