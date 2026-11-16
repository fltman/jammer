// swift-tools-version: 6.2
import Foundation
import PackageDescription

// whisper.cpp is built from pinned source by scripts/build-whisper.sh; until then the
// package builds without the Whisper engine.
let hasWhisper = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Vendor/whisper.xcframework")
// DeepFilterNet's libDF likewise, from scripts/build-libdf.sh.
let hasDeepFilter = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Vendor/DeepFilter.xcframework")
// LAME (LGPL, dynamic only), from scripts/build-lame.sh.
let hasLAME = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Vendor/LAME.xcframework")
// FluidAudio (Apache-2.0) for diarisation, from scripts/fetch-fluidaudio.sh; only its Diarizer trait.
let hasFluidAudio = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Vendor/FluidAudio/Package.swift")

// Reverb reduction (WPE) can be left out of a release: Config/Features.xcconfig decides, for
// this package and for the app alike. Debug builds (and so the tests) always compile it.
let features = (try? String(contentsOfFile: Context.packageDirectory + "/../../Config/Features.xcconfig", encoding: .utf8)) ?? ""
let releaseHasDereverb = features.split(separator: "\n").contains { $0.replacingOccurrences(of: " ", with: "") == "JAMMER_DEREVERB=YES" }
let dereverbSettings: [SwiftSetting] = [.define("JAMMER_DEREVERB", .when(configuration: .debug))]
    + (releaseHasDereverb ? [.define("JAMMER_DEREVERB", .when(configuration: .release))] : [])

// The plugin-format SDKs (MIT), from scripts/fetch-plugin-sdks.sh.
let hasCLAP = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Vendor/clap/include/clap/clap.h")

let package = Package(
    name: "JammerKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "JammerEngine", targets: ["JammerEngine"]),
        .library(name: "JammerCore", targets: ["JammerCore"]),
        .library(name: "JammerStems", targets: ["JammerStems"]),
        .library(name: "JammerDereverb", targets: ["JammerDereverb"]),
        .library(name: "JammerAudio", targets: ["JammerAudio"]),
        .library(name: "JammerAgent", targets: ["JammerAgent"]),
        .library(name: "JammerSpeech", targets: ["JammerSpeech"]),
        .library(name: "JammerAssistant", targets: ["JammerAssistant"]),
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
        // Stem separation: Spleeter's U-Nets on MPSGraph, weights read from Deezer's own checkpoint.
        .target(name: "JammerStems", dependencies: ["JammerCore"]),
        // Reverb reduction (WPE). Apart, so a release can be built without it (docs/RELEASE.md).
        .target(name: "JammerDereverb", dependencies: ["JammerCore"], swiftSettings: dereverbSettings),
        .testTarget(name: "JammerDereverbTests", dependencies: ["JammerDereverb", "JammerCore"], swiftSettings: dereverbSettings),
        .testTarget(name: "JammerStemsTests", dependencies: ["JammerStems", "JammerCore"]),
        // The audio device: output unit feeding the engine.
        .target(
            name: "JammerAudio",
            dependencies: ["JammerEngine", "JammerCore"],
            linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio")]
        ),
        // Speech to text: engines that turn a source into words anchored in source frames.
        .target(
            name: "JammerSpeech",
            dependencies: ["JammerCore"],
            linkerSettings: [.linkedFramework("Speech"), .linkedFramework("AVFoundation")]
        ),
        // The built-in assistant: plans from the same operation registry, on-device by default.
        .target(name: "JammerAssistant", dependencies: ["JammerAgent", "JammerCore"],
                linkerSettings: [.linkedFramework("FoundationModels")]),
        // The local agent API: parsing, security rules, operations and the guide. Pure.
        .target(name: "JammerAgent", dependencies: ["JammerCore"]),
        .testTarget(name: "JammerEngineTests", dependencies: ["JammerEngine"]),
        .testTarget(name: "JammerCoreTests", dependencies: ["JammerCore", "JammerEngine"]),
        // Refuses every request from a test to anything but this Mac; loaded before the tests run (+load).
        .target(name: "TestNetGuard", path: "Tests/Support/TestNetGuard"),
        .testTarget(name: "JammerAgentTests", dependencies: ["JammerAgent", "JammerCore", "TestNetGuard"]),
        .testTarget(name: "JammerAssistantTests", dependencies: ["JammerAssistant", "JammerAgent", "JammerCore"]),
        .testTarget(name: "JammerSpeechTests", dependencies: ["JammerSpeech", "JammerCore"]),
        .testTarget(name: "JammerAudioTests", dependencies: ["JammerAudio", "JammerCore", "JammerEngine"]),
    ],
    cxxLanguageStandard: .cxx20
)

// Scanning VST 3 and CLAP plugins in a helper process, so a plugin that crashes or hangs
// while it is loaded can't touch the app.
package.products.append(.library(name: "JammerPlugins", targets: ["JammerPlugins"]))
package.targets.append(.target(name: "JammerPlugins", dependencies: ["JammerCore", "JammerEngine"]))
if hasCLAP {
    package.products.append(.executable(name: "jammer-plugin-probe", targets: ["PluginProbe"]))
    package.products.append(.executable(name: "jammer-plugin-host", targets: ["PluginHostHelper"]))
    package.targets += [
        .executableTarget(name: "PluginProbe", path: "Sources/PluginProbe",
                          // The VST 3 interface headers too when the SDK is there (the probe says so when it isn't).
                          cxxSettings: [.headerSearchPath("../../Vendor/clap/include"), .headerSearchPath("../../Vendor/vst3sdk")],
                          linkerSettings: [.linkedFramework("CoreFoundation")]),
        .testTarget(name: "JammerPluginsTests", dependencies: ["JammerPlugins", "JammerCore", "PluginProbe"]),
        // Hosting a plugin: load, activate, process, parameters, state, latency. Only ever linked
        // into helper processes (and their tests), never into the app.
        .target(name: "JammerPluginHost", cxxSettings: [.headerSearchPath("../../Vendor/clap/include"), .headerSearchPath("../../Vendor/vst3sdk")],
                linkerSettings: [.linkedFramework("CoreFoundation")]),
        // The process that holds one plugin while it works (one per plugin).
        .executableTarget(name: "PluginHostHelper", dependencies: ["JammerPluginHost"], path: "Sources/PluginHostHelper"),
        .testTarget(name: "JammerPluginHostTests", dependencies: ["JammerPluginHost", "JammerPlugins", "PluginHostHelper", "PluginProbe", "JammerCore", "JammerEngine", "JammerAgent"]),
    ]
}

if hasWhisper {
    package.products.append(.library(name: "JammerWhisper", targets: ["JammerWhisper"]))
    package.targets += [
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        .target(name: "JammerWhisper", dependencies: ["whisper", "JammerSpeech", "JammerCore"],
                linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedLibrary("c++")]),
        .testTarget(name: "JammerWhisperTests", dependencies: ["JammerWhisper", "JammerSpeech", "JammerCore"]),
    ]
}

if hasDeepFilter {
    package.products.append(.library(name: "JammerDenoise", targets: ["JammerDenoise"]))
    package.targets += [
        .binaryTarget(name: "DeepFilter", path: "Vendor/DeepFilter.xcframework"),
        .target(name: "JammerDenoise", dependencies: ["DeepFilter", "JammerCore"],
                linkerSettings: [.linkedFramework("AVFoundation")]),
        .testTarget(name: "JammerDenoiseTests", dependencies: ["JammerDenoise", "JammerCore"]),
    ]
}

if hasLAME {
    package.products.append(.library(name: "JammerMP3", targets: ["JammerMP3"]))
    package.targets += [
        .binaryTarget(name: "LAME", path: "Vendor/LAME.xcframework"),
        .target(name: "JammerMP3", dependencies: ["LAME", "JammerCore"]),
        .testTarget(name: "JammerMP3Tests", dependencies: ["JammerMP3", "JammerCore"]),
    ]
}

if hasFluidAudio {
    // FluidAudio's own sources, built here rather than through its manifest: the manifest
    // declares a prebuilt binary (NemoTextProcessing) that SwiftPM fetches even with its
    // trait off. We want none of it: only the diarisation code, with no TTS.
    let fa = "Vendor/FluidAudio/Sources"
    package.products.append(.library(name: "JammerDiarize", targets: ["JammerDiarize"]))
    package.products.append(.library(name: "JammerParakeet", targets: ["JammerParakeet"]))
    package.targets += [
        .target(name: "FastClusterWrapper", path: fa + "/FastClusterWrapper", publicHeadersPath: "include"),
        .target(name: "MachTaskSelfWrapper", path: fa + "/MachTaskSelfWrapper", publicHeadersPath: "include"),
        .target(name: "FluidAudio", dependencies: ["FastClusterWrapper", "MachTaskSelfWrapper"], path: fa + "/FluidAudio",
                exclude: ["ASR/Parakeet/Unified/benchmark.md"],
                swiftSettings: [.define("Diarizer")]),
        .target(name: "JammerDiarize", dependencies: ["FluidAudio", "JammerCore"]),
        .target(name: "JammerParakeet", dependencies: ["FluidAudio", "JammerSpeech", "JammerCore"]),
        .testTarget(name: "JammerParakeetTests", dependencies: ["JammerParakeet", "JammerSpeech", "JammerCore"]),
        .testTarget(name: "JammerDiarizeTests", dependencies: ["JammerDiarize", "JammerCore"]),
    ]
}
