// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StudyMate",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(
            name: "StudyMate",
            targets: ["StudyMateApp"]
        ),
        .library(
            name: "StudyMateKit",
            targets: ["StudyMateKit"]
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
            name: "StudyMateKit",
            dependencies: [
                "CSpeechRuntime",
                .product(name: "SpeakerKit", package: "argmax-oss-swift")
            ],
            path: "Sources/StudyMate",
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
            name: "StudyMateApp",
            dependencies: ["StudyMateKit"],
            path: "Sources/StudyMateApp",
            exclude: [
                "Info.plist"
            ],
            resources: [
                .process("en.lproj"),
                .process("zh-Hans.lproj")
            ],
            cSettings: [
                .define("GL_SILENCE_DEPRECATION")
            ],
            swiftSettings: [
                .define("GL_SILENCE_DEPRECATION")
            ]
        ),
        .testTarget(
            name: "StudyMateTests",
            dependencies: ["StudyMateKit"],
            path: "Tests/StudyMateTests",
            cSettings: [
                .define("GL_SILENCE_DEPRECATION")
            ],
            swiftSettings: [
                .define("GL_SILENCE_DEPRECATION")
            ]
        )
    ]
)
