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
    dependencies: [
        // SpeakerKit provides the on-device Pyannote diarization pipeline used to
        // keep sentence boundaries aligned with real speaker changes.
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.1.0"
        )
    ],
    targets: [
        .binaryTarget(
            name: "WhisperFramework",
            path: "Vendor/Whisper/whisper.xcframework"
        ),
        .target(
            name: "CSpeechRuntime",
            dependencies: ["WhisperFramework"],
            path: "Sources/CSpeechRuntime",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MacAbobooKit",
            dependencies: [
                "CSpeechRuntime",
                .product(name: "SpeakerKit", package: "argmax-oss-swift")
            ],
            path: "Sources/MacAboboo",
            exclude: [
                "Resources/Helpers"
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/Models"),
                // Keep the nested Core ML directory layout intact. SpeakerKit's
                // model loader resolves segmenter/embedder/PLDA by this layout.
                .copy("Resources/SpeakerKitModels"),
                .process("Resources/ThirdPartyNotices")
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
