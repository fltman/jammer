// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JammerKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "JammerEngine", targets: ["JammerEngine"]),
        .library(name: "JammerCore", targets: ["JammerCore"]),
        .library(name: "JammerAudio", targets: ["JammerAudio"]),
        .library(name: "JammerAgent", targets: ["JammerAgent"]),
    ],
    targets: [
        // The realtime core. C++20 behind a C API; the compiler proves the
        // audio-thread entry points never allocate, lock or block.
        .target(
            name: "JammerEngine",
            cxxSettings: [
                .unsafeFlags(["-Wall", "-Wextra", "-Werror=function-effects", "-Wfunction-effects"]),
            ],
            linkerSettings: [.linkedFramework("AudioToolbox")]
        ),
        // Document model, edits, file formats, peaks and loudness. No UI, no device.
        .target(name: "JammerCore", dependencies: ["JammerEngine"]),
        // The audio device: output unit feeding the engine.
        .target(
            name: "JammerAudio",
            dependencies: ["JammerEngine", "JammerCore"],
            linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio")]
        ),
        // The local agent API: parsing, security rules, operations and the guide. Pure.
        .target(name: "JammerAgent", dependencies: ["JammerCore"]),
        .testTarget(name: "JammerEngineTests", dependencies: ["JammerEngine"]),
        .testTarget(name: "JammerCoreTests", dependencies: ["JammerCore", "JammerEngine"]),
        .testTarget(name: "JammerAgentTests", dependencies: ["JammerAgent", "JammerCore"]),
    ],
    cxxLanguageStandard: .cxx20
)
