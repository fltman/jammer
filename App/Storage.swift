import AppKit
import JammerCore
import SwiftUI

/// What takes room in Jämmer's media folder, and what of it could be let go (File › Storage…).
/// Looking never changes anything, and nothing is ever removed by itself: the user chooses, is told
/// what will be moved, and it goes to the Trash.
@MainActor
enum StorageScanner {
    static var autosaveFolder: URL { FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Autosave Information") }

    /// A project on disk, read without changing anything: as it is now and every step of its history.
    nonisolated static func read(_ package: URL) -> MediaStorage.Known? {
        guard let wrapper = try? FileWrapper(url: package), let project = try? ProjectPackage.read(wrapper, packageURL: package) else { return nil }
        var states = [project]
        if let data = wrapper.fileWrappers?[JammerDocument.historyFile]?.regularFileContents, let h = try? JSONDecoder().decode(History.self, from: data) {
            states += h.nodes.compactMap { try? h.project(of: $0.id) }
        }
        return .init(name: package.deletingPathExtension().lastPathComponent, location: package.path, states: states)
    }

    /// Every project that can be read now: the open ones (with their history, every branch), the recent
    /// ones, the autosaved ones, and those the register has seen use a file, where they can be read.
    /// Also tidies the register of projects that are gone for certain: an untitled document that is no
    /// longer open, and an autosaved one whose file is no longer there. A project somewhere else that
    /// can't be read is NOT gone: it stays in the register, and its files stay "unknown".
    static func known() -> [MediaStorage.Known] {
        let media = MediaStore.folder
        var out: [MediaStorage.Known] = []
        var locations = Set<String>()
        for s in AgentRegistry.shared.sessions {
            let location = s.document?.fileURL?.path ?? s.document?.autosavedContentsFileURL?.path ?? "untitled:\(s.agentID)"
            var states = [s.project]
            if let h = s.history { states += h.nodes.compactMap { try? h.project(of: $0.id) } }
            out.append(.init(name: s.name, location: location, states: states))
            locations.insert(location)
        }
        var packages = NSDocumentController.shared.recentDocumentURLs
        packages += (try? FileManager.default.contentsOfDirectory(at: autosaveFolder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "jammer" } ?? []
        var listed: [String] = []
        if case .read(let r) = MediaRegister.state(media) { listed = Array(Set(r.files.values.flatMap { $0.projects.keys })) }
        packages += listed.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        for url in packages where !locations.contains(url.path) {
            guard let k = read(url) else { continue }
            out.append(k)
            locations.insert(url.path)
        }
        // Gone for certain: only these two cases.
        let autosave = autosaveFolder.standardizedFileURL.path
        for location in listed where !locations.contains(location) {
            let untitledClosed = location.hasPrefix("untitled:")
            let autosavedGone = location.hasPrefix(autosave + "/") && !FileManager.default.fileExists(atPath: location)
            if untitledClosed || autosavedGone { MediaRegister.forget(project: location, in: media) }
        }
        // What each readable project uses now is noted, so that it is remembered when the project is away.
        for k in out {
            var names = Set<String>()
            for s in k.states { names.formUnion(MediaStorage.names(usedBy: s, in: media)) }
            MediaRegister.seen(names, usedBy: k.location, in: media)
        }
        return out
    }

    static func report() -> MediaStorage.Report { MediaStorage.report(media: MediaStore.folder, known: known()) }

    static func location(_ s: EditorSession) -> String {
        s.document?.fileURL?.path ?? s.document?.autosavedContentsFileURL?.path ?? "untitled:\(s.agentID)"
    }

    /// Notes which of Jämmer's own files this document uses, under where the document is kept. Done when
    /// a document opens, when it is saved, and whenever a step gives it a new file: a project must be
    /// known to use a file from the moment it does, not from the next time someone looks at Storage,
    /// or a project that is then put away on another disk would leave its files looking unused.
    static func note(_ s: EditorSession) {
        let media = MediaStore.folder
        var names = MediaStorage.names(usedBy: s.project, in: media)
        if let h = s.history { for n in h.nodes { if let p = try? h.project(of: n.id) { names.formUnion(MediaStorage.names(usedBy: p, in: media)) } } }
        MediaRegister.seen(names, usedBy: location(s), in: media)
    }
}

@MainActor
enum StorageWindow {
    private static var window: NSWindow?
    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Storage"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: StorageView())
        w.setContentSize(w.contentView!.fittingSize)
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in MainActor.assumeIsolated { window = nil } }
    }
}

struct StorageView: View {
    @State private var report = MediaStorage.Report(files: [], register: "none", trashed: [])
    @State private var chosen = Set<String>()
    @State private var asking = false
    @State private var said: String?

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage").font(.title2.bold())
            Text("Effects, repairs and frozen tracks are made as new audio files in Jämmer's media folder; your own files are never changed. This shows what is there. Nothing is removed unless you choose it here, and what you choose goes to the Trash.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if report.register == "broken" {
                Label("Jämmer's record of the files it has made can't be read, so nothing here can be chosen.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    group("Can be freed", .canBeFreed, "Made by Jämmer, and no project that has used them uses them any more, now or anywhere in its history.", choosable: true)
                    group("In use", .inUse, "Used by a project, as it is now or at a step in its history.", choosable: false)
                    group("Can't tell", .unknown, "Made by Jämmer and last used by a project that can't be read just now (on another disk, or moved). They can be chosen once that project has been opened again.", choosable: false)
                    group("Not Jämmer's to remove", .unregistered, "Your own audio, and files made before Jämmer kept a record of what it makes. Never touched.", choosable: false)
                }
                .padding(.trailing, 6)
            }
            .frame(minHeight: 260, maxHeight: 420)
            if let said { Text(said).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("storage.said") }
            HStack {
                Button("Show the Folder") { NSWorkspace.shared.open(MediaStore.folder) }
                Spacer()
                let bytes = report.files.filter { chosen.contains($0.name) }.reduce(Int64(0)) { $0 + $1.bytes }
                Button(chosen.isEmpty ? "Move to Trash…" : "Move \(chosen.count) File\(chosen.count == 1 ? "" : "s") to Trash… (\(Self.size(bytes)))") { asking = true }
                    .disabled(chosen.isEmpty)
                    .accessibilityIdentifier("storage.move")
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear(perform: reload)
        .confirmationDialog(confirmTitle, isPresented: $asking) {
            Button("Move to Trash", role: .destructive, action: move)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They stay in the Trash until you empty it, so they can be put back. Nothing is deleted.")
        }
    }

    private var confirmTitle: String {
        let bytes = report.files.filter { chosen.contains($0.name) }.reduce(Int64(0)) { $0 + $1.bytes }
        return "Move \(chosen.count) file\(chosen.count == 1 ? "" : "s") to the Trash? That frees \(Self.size(bytes))."
    }

    @ViewBuilder private func group(_ title: String, _ g: MediaStorage.Group, _ what: String, choosable: Bool) -> some View {
        let files = report.files.filter { $0.group == g }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(title): \(files.count) file\(files.count == 1 ? "" : "s"), \(Self.size(report.bytes(g)))").font(.headline)
                if choosable, !files.isEmpty {
                    Spacer()
                    Button(chosen.count == files.count ? "Choose None" : "Choose All") { chosen = chosen.count == files.count ? [] : Set(files.map(\.name)) }
                        .buttonStyle(.link)
                }
            }
            Text(what).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(files.prefix(200), id: \.name) { f in
                HStack(spacing: 8) {
                    if choosable {
                        Toggle(isOn: Binding(get: { chosen.contains(f.name) }, set: { if $0 { chosen.insert(f.name) } else { chosen.remove(f.name) } })) { EmptyView() }
                            .toggleStyle(.checkbox).labelsHidden()
                            .accessibilityLabel("Choose \(f.name)")
                    }
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                    if let kind = f.kind { Text(kind).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if !f.projects.isEmpty { Text(f.projects.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Text(Self.size(f.bytes)).monospacedDigit().font(.caption)
                }
            }
            if files.count > 200 { Text("…and \(files.count - 200) more.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func reload() {
        report = StorageScanner.report()
        chosen = chosen.intersection(report.names(.canBeFreed))
    }

    private func move() {
        do {
            // What would go is worked out first, and only then moved: the same reading both times.
            let known = StorageScanner.known()
            let dry = try MediaStorage.moveToTrash(Array(chosen), media: MediaStore.folder, known: known, dryRun: true)
            let moved = try MediaStorage.moveToTrash(dry.names, media: MediaStore.folder, known: known, dryRun: false)
            said = "\(moved.names.count) file\(moved.names.count == 1 ? " is" : "s are") in the Trash (\(Self.size(moved.bytes))). Nothing was deleted: put \(moved.names.count == 1 ? "it" : "them") back from the Trash if a project turns out to need \(moved.names.count == 1 ? "it" : "them")."
        } catch {
            said = error.localizedDescription
        }
        chosen = []
        reload()
    }
}
