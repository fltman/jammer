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
        w.title = L10n.text("storage.title")
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
            Text(L10n.text("storage.title")).font(.title2.bold())
            Text(L10n.text("storage.intro"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if report.register == "broken" {
                StateLine(kind: .error, text: L10n.text("storage.noRecord"), font: .body)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    group(L10n.text("storage.group.free"), .canBeFreed, L10n.text("storage.group.free.what"), choosable: true)
                    group(L10n.text("storage.group.inUse"), .inUse, L10n.text("storage.group.inUse.what"), choosable: false)
                    group(L10n.text("storage.group.unknown"), .unknown, L10n.text("storage.group.unknown.what"), choosable: false)
                    group(L10n.text("storage.group.notOurs"), .unregistered, L10n.text("storage.group.notOurs.what"), choosable: false)
                }
                .padding(.trailing, 6)
            }
            .frame(minHeight: 260, maxHeight: 420)
            if let said { Text(said).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("storage.said") }
            HStack {
                Button(L10n.text("storage.showFolder")) { NSWorkspace.shared.open(MediaStore.folder) }
                Spacer()
                let bytes = report.files.filter { chosen.contains($0.name) }.reduce(Int64(0)) { $0 + $1.bytes }
                Button(chosen.isEmpty ? L10n.text("storage.move") : L10n.text("storage.move.chosen", L10n.count("storage.files.title", chosen.count), Self.size(bytes))) { asking = true }
                    .disabled(chosen.isEmpty)
                    .accessibilityIdentifier("storage.move")
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear(perform: reload)
        .confirmationDialog(confirmTitle, isPresented: $asking) {
            Button(L10n.text("storage.confirm.move"), role: .destructive, action: move)
            Button(L10n.text("button.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("storage.confirm.text"))
        }
    }

    private var confirmTitle: String {
        let bytes = report.files.filter { chosen.contains($0.name) }.reduce(Int64(0)) { $0 + $1.bytes }
        return L10n.text("storage.confirm.title", L10n.count("storage.files", chosen.count), Self.size(bytes))
    }

    @ViewBuilder private func group(_ title: String, _ g: MediaStorage.Group, _ what: String, choosable: Bool) -> some View {
        let files = report.files.filter { $0.group == g }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.text("storage.group.line", title, L10n.count("storage.files", files.count), Self.size(report.bytes(g)))).font(.headline)
                if choosable, !files.isEmpty {
                    Spacer()
                    Button(chosen.count == files.count ? L10n.text("storage.chooseNone") : L10n.text("storage.chooseAll")) { chosen = chosen.count == files.count ? [] : Set(files.map(\.name)) }
                        .buttonStyle(.link)
                }
            }
            Text(what).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(files.prefix(200), id: \.name) { f in
                HStack(spacing: 8) {
                    if choosable {
                        Toggle(isOn: Binding(get: { chosen.contains(f.name) }, set: { if $0 { chosen.insert(f.name) } else { chosen.remove(f.name) } })) { EmptyView() }
                            .toggleStyle(.checkbox).labelsHidden()
                            .accessibilityLabel(L10n.text("storage.choose.ax", f.name))
                    }
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                    if let kind = f.kind { Text(StorageKinds.name(kind)).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if !f.projects.isEmpty { Text(f.projects.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Text(Self.size(f.bytes)).monospacedDigit().font(.caption)
                }
            }
            if files.count > 200 { Text(L10n.text("storage.more", String(files.count - 200))).font(.caption).foregroundStyle(.secondary) }
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
            said = L10n.text("storage.moved", L10n.count("storage.moved.files", moved.names.count), Self.size(moved.bytes))
        } catch {
            said = L10n.error(error)
        }
        chosen = []
        reload()
    }
}

/// What made a file in Jämmer's media folder, in the window's language. The register keeps the step's own
/// word (`frozen`, `duck`, …), which stays as it is for an agent.
enum StorageKinds {
    static func name(_ kind: String) -> String {
        let names = ["frozen": L10n.text("storage.kind.frozen"), "duck": L10n.text("storage.kind.duck"), "echo": L10n.text("storage.kind.echo"),
                     "limit": L10n.text("storage.kind.limit"), "debleed": L10n.text("storage.kind.debleed"), "drift": L10n.text("storage.kind.drift"),
                     "levelled": L10n.text("storage.kind.levelled"), "spectral": L10n.text("storage.kind.spectral"), "stem": L10n.text("storage.kind.stem"),
                     "dehum": L10n.text("storage.kind.dehum"), "declip": L10n.text("storage.kind.declip"), "declick": L10n.text("storage.kind.declick"),
                     "denoise": L10n.text("storage.kind.denoise"), "dereverb": L10n.text("storage.kind.dereverb")]
        return names[kind] ?? kind
    }
}
