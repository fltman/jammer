import AppKit
import JammerCore
import OSLog
import SwiftUI

let voiceProfileLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.brattoo.jammer", category: "voiceProfiles")

/// Voice profiles: a named voiceprint saved on this Mac, to name speakers in other recordings (Anders, 2026-11-19;
/// SIBLINGS, "Röstprofiler och andra biometriska avtryck"). Only in the app's own folder (inside its sandbox),
/// never in a document, an export, Send to Flimmer, a log or an API answer; made only by the user in the window,
/// with consent; listed, deleted and switched off in Settings.
@MainActor
final class VoiceProfileStore {
    static let shared = VoiceProfileStore()

    struct Profile: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var createdAt: Date
        /// Whose voice it is, as the user said when saving: "own" or "consented".
        var consent: String
        var print: [Float]
    }

    /// In the app's own data folder: ~/Library/Application Support/Jammer/VoiceProfiles in a release (the app is not
    /// sandboxed; what the manual names), "Jammer Debug" for a debug build, so a test never lands among real ones.
    var folder: URL { AppData.folder.appending(path: "VoiceProfiles") }

    private(set) var profiles: [Profile] = []
    private var loaded = false

    var recognize: Bool {
        get { UserDefaults.standard.object(forKey: "voiceProfiles.recognize") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voiceProfiles.recognize") }
    }

    func all() -> [Profile] {
        if !loaded {
            loaded = true
            // Biometric data in an app that isn't sandboxed: rights that have become wider are tightened, said in
            // the log by file name only.
            let changed = PrivateFiles.tighten(folder)
            if !changed.isEmpty { voiceProfileLog.notice("Voice profiles: tightened the rights of \(changed.count) item(s) to 0700/0600: \(changed.joined(separator: ", "), privacy: .public)") }
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            profiles = files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(Profile.self, from: Data(contentsOf: $0)) }
                .sorted { $0.createdAt < $1.createdAt }
        }
        return profiles
    }

    @discardableResult
    func save(name: String, consent: String, print: [Float]) throws -> Profile {
        _ = all()
        let p = Profile(id: UUID(), name: name, createdAt: Date(), consent: consent, print: print)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try PrivateFiles.write(try enc.encode(p), named: "\(p.id.uuidString).json", in: folder)
        profiles.append(p)
        NotificationCenter.default.post(name: Self.changed, object: nil)
        return p
    }

    /// For good: the file is removed. Documents that already carry the name keep it (it is their content).
    func delete(_ id: UUID) {
        _ = all()
        try? FileManager.default.removeItem(at: folder.appending(path: "\(id.uuidString).json"))
        profiles.removeAll { $0.id == id }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    static let changed = Notification.Name("JammerVoiceProfilesChanged")

    /// What the API may say about them: never the voiceprint.
    var listed: [[String: Any]] {
        all().map { ["id": $0.id.uuidString, "name": $0.name, "createdAt": ISO8601DateFormatter().string(from: $0.createdAt)] }
    }

    var matchProfiles: [VoiceMatch.Profile] { all().map { VoiceMatch.Profile(id: $0.id, name: $0.name, print: $0.print) } }
}

extension EditorSession {
    /// After a diarisation: speakers whose name the diarisation gave ("Speaker 3") and whose voice is like a saved
    /// profile take its name, as one undo step of their own, marked as a suggestion with its likeness. Each profile
    /// names at most one speaker; a name the user set is never replaced.
    @discardableResult
    func nameAfterVoiceProfiles() -> (matches: [Int: VoiceMatch.Match], alternatives: [Int: VoiceMatch.Match]) {
        let store = VoiceProfileStore.shared
        guard store.recognize, !store.all().isEmpty, !speakerPrints.isEmpty else { return ([:], [:]) }
        let protected = Set(project.speakers.indices.filter { !VoiceMatch.isGiven(project.speakers[$0]) })
        let r = VoiceMatch.assign(prints: speakerPrints, profiles: store.matchProfiles, protected: protected)
        guard !r.matches.isEmpty else { return r }
        var p = project
        for (speaker, m) in r.matches where p.speakers.indices.contains(speaker) {
            p.speakers[speaker] = m.name
            p.speakerSuggestions.removeAll { $0.speaker == speaker }
            p.speakerSuggestions.append(SpeakerSuggestion(speaker: speaker, score: (m.score * 100).rounded() / 100))
        }
        commit(p, action: L10n.text("voiceProfiles.nameAfter.undo"))
        status = r.matches.count == 1 ? L10n.text("voiceProfiles.named.one", r.matches.values.first!.name, L10n.number(r.matches.values.first!.score, 2))
            : L10n.text("voiceProfiles.named.other", String(r.matches.count))
        return r
    }
}

/// The sheet that saves a speaker as a voice profile, in the same form as Overdub's consent: whose voice it is,
/// first; nothing is saved before that and a name.
struct VoiceProfileSheet: View {
    let session: EditorSession
    let close: () -> Void
    @State private var speaker: Int
    @State private var name: String
    @State private var whose: String? = nil
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    init(session: EditorSession, speaker: Int?, close: @escaping () -> Void) {
        self.session = session
        self.close = close
        let first = speaker ?? session.speakerPrints.keys.sorted().first ?? 0
        _speaker = State(initialValue: first)
        _name = State(initialValue: session.project.speakers.indices.contains(first) && !VoiceMatch.isGiven(session.project.speakers[first]) ? session.project.speakers[first] : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("voiceProfiles.sheet.title")).font(.headline)
            Text(L10n.text("voiceProfiles.sheet.text")).fixedSize(horizontal: false, vertical: true)
            Picker(L10n.text("voiceProfiles.sheet.speaker"), selection: $speaker) {
                ForEach(session.speakerPrints.keys.sorted(), id: \.self) { s in
                    Text(session.project.speakers.indices.contains(s) ? session.project.speakers[s] : "\(s + 1)").tag(s)
                }
            }
            TextField(L10n.text("voiceProfiles.sheet.name"), text: $name)
                .focused($nameFocused)
                .accessibilityIdentifier("voiceProfile.name")
            Text(L10n.text("voiceProfiles.sheet.whose")).font(.subheadline)
            // Rows of their own rather than a radio group: the consent's words must be read whole, never cut off.
            ForEach([("own", L10n.text("voiceProfiles.sheet.own")), ("consented", L10n.text("voiceProfiles.sheet.consented"))], id: \.0) { value, label in
                Button { whose = value } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: whose == value ? "largecircle.fill.circle" : "circle").foregroundStyle(whose == value ? Color.accentColor : .secondary)
                        Text(label).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(whose == value ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("voiceProfile.\(value)")
            }
            if let failure { StateLine(kind: .error, text: failure) }
            HStack {
                Spacer()
                Button(L10n.text("button.cancel")) { close() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("voiceProfiles.sheet.save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || whose == nil || session.speakerPrints[speaker] == nil)
                    .accessibilityIdentifier("voiceProfile.save")
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard let print = session.speakerPrints[speaker], let whose else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        do {
            try VoiceProfileStore.shared.save(name: n, consent: whose, print: print)
            // The speaker takes the name it was saved under, when the diarisation had given it one.
            if session.project.speakers.indices.contains(speaker), VoiceMatch.isGiven(session.project.speakers[speaker]) {
                session.perform("rename_speaker", ["speaker": .string(String(speaker)), "name": .string(n)])
            }
            session.status = L10n.text("voiceProfiles.saved", n)
            close()
        } catch {
            failure = L10n.error(error)
        }
    }
}

/// Settings › Voice Profiles: the list, deleting, and recognition on or off.
struct VoiceProfileSettings: View {
    @State private var profiles: [VoiceProfileStore.Profile] = VoiceProfileStore.shared.all()
    @State private var recognize = VoiceProfileStore.shared.recognize
    @State private var deleting: VoiceProfileStore.Profile?

    var body: some View {
        // As the other tabs: a plain stack of fixed width (a Form in this TabView was drawn empty, seen 2026-11-19).
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.text("voiceProfiles.settings.recognize"), isOn: $recognize)
                .onChange(of: recognize) { VoiceProfileStore.shared.recognize = recognize }
            Text(L10n.text("voiceProfiles.settings.text", VoiceProfileStore.shared.folder.path)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if profiles.isEmpty {
                Text(L10n.text("voiceProfiles.settings.none")).foregroundStyle(.secondary)
            }
            ForEach(profiles) { p in
                HStack {
                    VStack(alignment: .leading) {
                        Text(p.name)
                        Text(p.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("voiceProfiles.settings.delete")) { deleting = p }
                        .accessibilityLabel(L10n.text("voiceProfiles.settings.delete.ax", p.name))
                }
            }
        }
        .padding()
        .frame(width: 560, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .onReceive(NotificationCenter.default.publisher(for: VoiceProfileStore.changed)) { _ in profiles = VoiceProfileStore.shared.all() }
        .confirmationDialog(L10n.text("voiceProfiles.delete.title", deleting?.name ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.text("voiceProfiles.settings.delete"), role: .destructive) {
                if let d = deleting { VoiceProfileStore.shared.delete(d.id) }
                deleting = nil
            }
        } message: {
            Text(L10n.text("voiceProfiles.delete.text"))
        }
    }
}
