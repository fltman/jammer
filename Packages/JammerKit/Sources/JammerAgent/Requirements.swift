import Foundation
import JammerCore

/// What Jämmer may need installed (SIBLINGS, "Det som kan behöva installeras", 2026-11-19): every third-party model
/// and plugin kind a feature needs that doesn't come with the app. The same list as Settings › Models and
/// docs/LICENSES.md (a test keeps them together); the agent guide's section and `GET /api/v1/requirements` are made
/// from it. The API never starts a download or an installation: an `in_app` item is fetched only when the user clicks
/// in the app's window, and the app checks its checksum (or fetches it at a pinned commit).
public struct Requirement: Sendable, Equatable {
    public enum Kind: String, Sendable { case model, library, plugin, tool }
    public struct License: Sendable, Equatable { public var spdx: String; public var url: String }
    public struct Source: Sendable, Equatable {
        public var publisher: String
        public var url: String
        /// Exact version, or nil for something the user installs from its maker (`minVersion` then, or none).
        public var version: String?
        public var minVersion: String?
        public var sha256: String?
        public var commit: String?
        public var sha256Note: String?
        /// Where the source publishes the checksum or commit, and when it was read (never computed by downloading).
        public var checkedAt: String?
        public var checkedOn: String?
    }
    public enum Install: Sendable, Equatable {
        case inApp(where: String)
        case byUser(steps: [String])
    }
    /// For a program the user installs from its maker: the signature to look for, and the command that shows it.
    public struct Verify: Sendable, Equatable { public var teamID: String?; public var command: String }

    public var id: String
    public var name: String
    public var kind: Kind
    public var neededBy: [String]
    public var required: Bool
    public var sizeBytes: Int64?
    public var license: License?
    public var source: Source
    public var install: Install
    /// Where it ends up, and how it is removed.
    public var location: String
    public var remove: String
    public var verify: Verify?
    /// The command or call that shows the installation went right, and what it answers then.
    public var check: String
    /// A repository of many files: each file's published sum at the commit, checked before installing.
    public var manifest: ModelManifest? = nil
    public var modes: [String] = ["local"]
    /// Only in debug builds (a release doesn't list it).
    public var debugOnly = false
}

public enum Requirements {
    static let models = "Settings › Models"
    static let folder = "~/Library/Application Support/Jammer/Models"
    static let installedCheck = "GET /api/v1/requirements answers \"installed\": true for it, and Settings › Models says Installed"
    static let read = "2026-11-19"

    /// Everything, release and debug.
    public static let all: [Requirement] = [
        Requirement(id: "kb-whisper-small", name: "KB-Whisper small (Swedish)", kind: .model, neededBy: ["transcribe"], required: false,
                    sizeBytes: 175_209_680, license: .init(spdx: "Apache-2.0", url: "https://huggingface.co/KBLab/kb-whisper-small"),
                    source: .init(publisher: "KBLab, National Library of Sweden", url: "https://huggingface.co/KBLab/kb-whisper-small/resolve/3564d61a42fc210ceaa55a22a96dd64478959c78/ggml-model-q5_0.bin",
                                  version: "ggml-model-q5_0.bin at commit 3564d61a42fc210ceaa55a22a96dd64478959c78", sha256: "6768836a51abc902e420c613153e6d418c90ea2774e913274d02ab23170225b7",
                                  commit: "3564d61a42fc210ceaa55a22a96dd64478959c78",
                                  checkedAt: "https://huggingface.co/api/models/KBLab/kb-whisper-small/tree/3564d61a42fc210ceaa55a22a96dd64478959c78 (lfs.oid)", checkedOn: read),
                    install: .inApp(where: models), location: folder, remove: "Remove in \(models)", check: installedCheck),
        Requirement(id: "kb-whisper-medium", name: "KB-Whisper medium (Swedish)", kind: .model, neededBy: ["transcribe"], required: false,
                    sizeBytes: 539_212_484, license: .init(spdx: "Apache-2.0", url: "https://huggingface.co/KBLab/kb-whisper-medium"),
                    source: .init(publisher: "KBLab, National Library of Sweden", url: "https://huggingface.co/KBLab/kb-whisper-medium/resolve/0abe10b9d7f75d0902656e5c06c5c4d549604dc5/ggml-model-q5_0.bin",
                                  version: "ggml-model-q5_0.bin at commit 0abe10b9d7f75d0902656e5c06c5c4d549604dc5", sha256: "7f8762e0ade9e0073674c0d5acae942a0b1ea98add9baa008ee89c94eaba43d0",
                                  commit: "0abe10b9d7f75d0902656e5c06c5c4d549604dc5",
                                  checkedAt: "https://huggingface.co/api/models/KBLab/kb-whisper-medium/tree/0abe10b9d7f75d0902656e5c06c5c4d549604dc5 (lfs.oid)", checkedOn: read),
                    install: .inApp(where: models), location: folder, remove: "Remove in \(models)", check: installedCheck),
        Requirement(id: "parakeet-tdt-0.6b-v3", name: "Parakeet TDT 0.6B v3 (25 languages)", kind: .model, neededBy: ["transcribe"], required: false,
                    sizeBytes: 632_169_729, license: .init(spdx: "CC-BY-4.0", url: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3"),
                    source: .init(publisher: "NVIDIA (Core ML conversion by Fluid Inference)", url: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml",
                                  version: "Core ML int8 v2", commit: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
                                  checkedAt: "https://huggingface.co/api/models/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/7dd20fe6b1797d35f5e3307e8b1732d9a178edfe?recursive=true (lfs.oid per LFS file, oid as git blob id for the rest)", checkedOn: read),
                    install: .inApp(where: models), location: folder, remove: "Remove in \(models)", check: installedCheck, manifest: .parakeetV3),
        Requirement(id: "diarisation", name: "Speaker diarisation (pyannote Community-1)", kind: .model, neededBy: ["diarize", "request_voice_profile", "split_speakers"], required: false,
                    sizeBytes: 21_599_417, license: .init(spdx: "CC-BY-4.0", url: "https://huggingface.co/pyannote/speaker-diarization-community-1"),
                    source: .init(publisher: "pyannote (Core ML conversion by Fluid Inference)", url: "https://huggingface.co/FluidInference/speaker-diarization-coreml",
                                  version: "Community-1", commit: "df2625ac79a7ac6b65ad868fee6d80f320da4232",
                                  checkedAt: "https://huggingface.co/api/models/FluidInference/speaker-diarization-coreml/tree/df2625ac79a7ac6b65ad868fee6d80f320da4232?recursive=true (lfs.oid per LFS file, oid as git blob id for the rest)", checkedOn: read),
                    install: .inApp(where: models), location: folder, remove: "Remove in \(models)", check: installedCheck, manifest: .diarisation),
        Requirement(id: "spleeter-4stems", name: "Stem separation (Spleeter 4stems)", kind: .model, neededBy: ["separate"], required: false,
                    sizeBytes: 146_308_147, license: .init(spdx: "MIT", url: "https://github.com/deezer/spleeter/blob/master/LICENSE"),
                    source: .init(publisher: "Deezer", url: "https://github.com/deezer/spleeter/releases/download/v1.4.0/4stems.tar.gz",
                                  version: "v1.4.0",
                                  sha256Note: "not published by the source (GitHub's release API gives no digest for this 2019 asset); Jämmer checks its download against the sum it was built with, 3adb4a50ad4eb18c7c4d65fcf4cf2367a07d48408a5eb7d03cd20067429dfaa8",
                                  checkedAt: "https://api.github.com/repos/deezer/spleeter/releases/tags/v1.4.0 (assets[].digest: none)", checkedOn: read),
                    install: .inApp(where: models), location: folder, remove: "Remove in \(models)", check: installedCheck),
        Requirement(id: "mrx", name: "Soundtrack separation (MRX)", kind: .model, neededBy: ["separate"], required: false,
                    sizeBytes: 122_317_463, license: .init(spdx: "MIT", url: "https://github.com/merlresearch/cocktail-fork-separation/blob/main/LICENSE.md"),
                    source: .init(publisher: "MERL", url: "https://media.githubusercontent.com/media/merlresearch/cocktail-fork-separation/19b3de827ebc4bfb014570cf92dd32b4ee3b6921/checkpoints/default_mrx_pre_trained_weights.pth",
                                  version: "default_mrx_pre_trained_weights.pth at commit 19b3de827ebc4bfb014570cf92dd32b4ee3b6921", sha256: "9cecc071c9e58afda34d1a98609a1540f61320e718bafecc4c9c1c5e3ed20a0c",
                                  commit: "19b3de827ebc4bfb014570cf92dd32b4ee3b6921",
                                  checkedAt: "https://raw.githubusercontent.com/merlresearch/cocktail-fork-separation/19b3de827ebc4bfb014570cf92dd32b4ee3b6921/checkpoints/default_mrx_pre_trained_weights.pth (the git LFS pointer's oid)", checkedOn: read),
                    install: .inApp(where: models), location: folder, remove: "Remove in \(models)", check: installedCheck),
        Requirement(id: "audio-units", name: "Audio Unit effects", kind: .plugin, neededBy: ["add_insert"], required: false,
                    sizeBytes: nil, license: nil,
                    source: .init(publisher: "The plugin's maker", url: "The maker's own site", version: nil),
                    install: .byUser(steps: ["Install the plugin with its maker's installer (it puts the .component in /Library/Audio/Plug-Ins/Components or ~/Library/Audio/Plug-Ins/Components).",
                                             "In Jämmer, Audio › Plugins… lists it. Plugin settings from elsewhere run in a process of their own."]),
                    location: "/Library/Audio/Plug-Ins/Components or ~/Library/Audio/Plug-Ins/Components", remove: "With the maker's uninstaller, or by moving the .component to the Trash",
                    verify: .init(teamID: nil, command: "codesign -dv --verbose=2 <path to the .component>"),
                    check: "auval -a lists it, and GET /api/v1/plugins finds it"),
        Requirement(id: "clap-plugins", name: "CLAP effects", kind: .plugin, neededBy: ["add_insert"], required: false,
                    sizeBytes: nil, license: nil,
                    source: .init(publisher: "The plugin's maker", url: "The maker's own site", version: nil),
                    install: .byUser(steps: ["Install the plugin with its maker's installer (it puts the .clap in /Library/Audio/Plug-Ins/CLAP or ~/Library/Audio/Plug-Ins/CLAP)."]),
                    location: "/Library/Audio/Plug-Ins/CLAP or ~/Library/Audio/Plug-Ins/CLAP", remove: "With the maker's uninstaller, or by moving the .clap to the Trash",
                    verify: .init(teamID: nil, command: "codesign -dv --verbose=2 <path to the .clap>"),
                    check: "GET /api/v1/plugins?format=clap finds it", debugOnly: true),
    ]

    /// What this build can use: a release lists nothing that only debug builds have (the features' switches).
    public static func listed(clap: Bool) -> [Requirement] { all.filter { !$0.debugOnly || clap } }

    /// The faults a test fails on: an item without a source, an exact version, a checksum or commit (or a note that
    /// none is published), or a license; one the user installs needs a way to verify it instead.
    public static func faults(_ r: Requirement) -> [String] {
        var out: [String] = []
        if r.source.publisher.isEmpty || r.source.url.isEmpty { out.append("\(r.id): no source") }
        switch r.install {
        case .inApp:
            if r.source.version == nil { out.append("\(r.id): no exact version") }
            if r.source.sha256 == nil && r.source.commit == nil && r.source.sha256Note == nil { out.append("\(r.id): no checksum or commit") }
            if r.license == nil { out.append("\(r.id): no license") }
            if r.source.checkedAt == nil || r.source.checkedOn == nil { out.append("\(r.id): no address and date for where the checksum was read") }
            if r.source.sha256 == nil && r.source.sha256Note == nil && r.manifest == nil { out.append("\(r.id): a commit without a sum for each file") }
            if let m = r.manifest, m.commit != r.source.commit { out.append("\(r.id): the file sums are from another commit") }
            if r.source.sha256 != nil && r.source.sha256Note != nil { out.append("\(r.id): a sha256 and a note that none is published") }
            if let spdx = r.license?.spdx, spdx.uppercased().contains("GPL") || spdx.uppercased().contains("NC") { out.append("\(r.id): the app fetches nothing GPL or non-commercial") }
        case .byUser(let steps):
            if steps.isEmpty { out.append("\(r.id): no steps") }
            if r.verify == nil && r.source.minVersion == nil && r.license == nil { out.append("\(r.id): no way to verify it") }
        }
        if r.neededBy.isEmpty { out.append("\(r.id): needed by nothing") }
        if r.check.isEmpty { out.append("\(r.id): no install check") }
        if r.source.version != nil && r.source.minVersion != nil { out.append("\(r.id): both version and minVersion") }
        return out
    }

    /// As `GET /api/v1/requirements` says it (with `installed` filled in by the app).
    public static func json(_ r: Requirement, installed: Bool?) -> [String: Any] {
        var source: [String: Any] = ["publisher": r.source.publisher, "url": r.source.url]
        if let v = r.source.version { source["version"] = v }
        if let v = r.source.minVersion { source["minVersion"] = v }
        if let s = r.source.sha256 { source["sha256"] = s }
        if let c = r.source.commit { source["commit"] = c }
        if let n = r.source.sha256Note { source["sha256"] = NSNull(); source["sha256Note"] = n }
        if let a = r.source.checkedAt { source["checkedAt"] = a }
        if let d = r.source.checkedOn { source["checkedOn"] = d }
        if let m = r.manifest {
            source["files"] = m.entries.keys.sorted().map { k -> [String: Any] in
                let e = m.entries[k]!
                var f: [String: Any] = ["path": k, "size": e.size]
                if let s = e.sha256 { f["sha256"] = s }
                if let b = e.gitBlob { f["gitBlob"] = b }
                return f
            }
        }
        var d: [String: Any] = ["id": r.id, "name": r.name, "kind": r.kind.rawValue, "neededBy": r.neededBy, "required": r.required,
                                "installed": installed.map { $0 as Any } ?? NSNull(), "sizeBytes": r.sizeBytes.map { $0 as Any } ?? NSNull(),
                                "license": r.license.map { ["spdx": $0.spdx, "url": $0.url] as Any } ?? NSNull(), "source": source,
                                "where": r.location, "remove": r.remove, "modes": r.modes, "debugOnly": r.debugOnly]
        switch r.install {
        case .inApp(let w): d["install"] = ["how": "in_app", "where": w, "check": r.check]
        case .byUser(let steps): d["install"] = ["how": "by_user", "steps": steps, "check": r.check]
        }
        if let v = r.verify { d["verify"] = ["teamID": v.teamID.map { $0 as Any } ?? NSNull(), "command": v.command] }
        return d
    }

    /// The agent guide's section.
    public static func guideSection(clap: Bool) -> String {
        var s = "## What Jämmer may need installed\n\nNothing here comes with the app. The API never starts a download or an installation: ask the user, and `POST /api/v1/settings/open` with `{\"pane\": \"models\"}` opens the pane (it changes nothing). A call that needs one of these and finds it missing answers `422 model_missing` with `\"requirement\": \"<id>\"`. `GET /api/v1/requirements` lists them with `installed`.\n\n"
        s += "| id | What | Needed by | License | Source and version | Install |\n|---|---|---|---|---|---|\n"
        for r in listed(clap: clap) {
            let ver = [r.source.version, r.source.sha256.map { "sha256 \($0)" }, r.source.commit.map { "commit \($0)" }, r.manifest.map { "sha256 or git blob id of each of its \($0.entries.count) files" }, r.source.sha256Note.map { "sha256: \($0)" }].compactMap { $0 }.joined(separator: ", ")
            let how: String
            switch r.install {
            case .inApp(let w): how = "In the app: \(w)"
            case .byUser(let steps): how = "By the user: " + steps.joined(separator: " ") + (r.verify.map { " Check: `\($0.command)`." } ?? "")
            }
            s += "| `\(r.id)` | \(r.name) | \(r.neededBy.map { "`\($0)`" }.joined(separator: ", ")) | \(r.license.map { "[\($0.spdx)](\($0.url))" } ?? "the maker's") | \(r.source.publisher), \(r.source.url)\(ver.isEmpty ? "" : " (\(ver))") | \(how) |\n"
        }
        return s
    }
}
