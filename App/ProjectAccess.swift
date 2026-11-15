import AppKit
import JammerCore

/// Where a document that was opened from a project file may read audio. A project is shared
/// between people and opened with a double-click, and it names the files it plays from, so
/// those names are not followed blindly: the package itself, Jämmer's own media folder, and
/// the files the user has opened here or said yes to. Anything else is asked about first.
@MainActor
enum ProjectAccess {
    private static let key = "project.approvedFiles"
    private static let most = 5_000

    /// Real paths of audio files the user has opened in Jämmer or approved for a project.
    static var approved: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(most)), forKey: key) }
    }

    /// The user opened or imported these themselves, or allowed a project to use them.
    static func approve(_ urls: [URL]) {
        let add = urls.map { SourcePool.real($0).path }
        guard !add.isEmpty else { return }
        var list = approved.filter { !add.contains($0) }
        list += add
        approved = list
    }

    /// What a document at `package` may read, as a rule a pool can apply off the main thread.
    static func rule(package: URL?, also extra: [URL] = []) -> @Sendable (URL) -> Bool {
        let roots = ([package, MediaStore.folder].compactMap { $0 }).map { SourcePool.real($0).path }
        let files = Set(approved + extra.map { SourcePool.real($0).path })
        return { url in
            let p = url.path
            return files.contains(p) || roots.contains { p == $0 || p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
    }
}

extension EditorSession {
    /// Called for a document read from a project file: from now on its audio comes only from
    /// where `ProjectAccess` allows.
    func restrictReading(package: URL?) {
        readsFromPackage = package
        isRestricted = true
        pool.restrict(ProjectAccess.rule(package: package))
        reloadAudio()
    }

    /// The files this document names that exist but lie outside what it may read.
    var filesOutside: [URL] {
        pool.refused.values.compactMap { if case .notAllowed(let u) = $0 { return u } else { return nil } }.sorted { $0.path < $1.path }
    }

    /// Files that are where the project says but aren't the audio it says they are.
    var filesNotAsDescribed: [URL] {
        pool.refused.values.compactMap { if case .notAsDescribed(let u) = $0 { return u } else { return nil } }
    }

    /// The user said yes: these files may be read, by this project and from now on.
    func allowOutside(_ urls: [URL]) {
        ProjectAccess.approve(urls)
        pool.restrict(ProjectAccess.rule(package: readsFromPackage))
        reloadAudio()
    }

    /// Asks once, when a project that came from somewhere else wants audio from outside itself.
    func askAboutFilesOutside(in window: NSWindow) {
        let outside = filesOutside
        guard !outside.isEmpty, !askedAboutOutside else {
            if !filesNotAsDescribed.isEmpty, status == nil || status?.isEmpty == true {
                let n = filesNotAsDescribed.count
                status = "\(n) file\(n == 1 ? " isn't" : "s aren't") the audio this project says \(n == 1 ? "it is" : "they are") and \(n == 1 ? "was" : "were") left out."
            }
            return
        }
        askedAboutOutside = true
        let alert = NSAlert()
        alert.messageText = "This project uses audio from outside itself"
        let folders = Array(Set(outside.map { $0.deletingLastPathComponent().path })).sorted()
        let shown = outside.prefix(6).map { "• " + ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
        alert.informativeText = "“\(name)” wants to play \(outside.count) audio file\(outside.count == 1 ? "" : "s") from \(folders.count == 1 ? "another folder" : "\(folders.count) other folders") on this Mac:\n\n\(shown)\(outside.count > 6 ? "\n… and \(outside.count - 6) more" : "")\n\nIf the project is your own, or you trust where it came from, use them. Otherwise open it without: those clips stay silent, and nothing outside the project is read."
        alert.addButton(withTitle: "Open Without Them")
        alert.addButton(withTitle: "Use These Files")
        alert.beginSheetModal(for: window) { [weak self] answer in
            MainActor.assumeIsolated {
                guard let self else { return }
                if answer == .alertSecondButtonReturn {
                    self.allowOutside(outside)
                    self.status = "Using \(outside.count) file\(outside.count == 1 ? "" : "s") from outside the project."
                } else {
                    self.status = "\(outside.count) file\(outside.count == 1 ? "" : "s") outside the project \(outside.count == 1 ? "wasn't" : "weren't") read. Their clips are silent."
                }
            }
        }
    }
}
