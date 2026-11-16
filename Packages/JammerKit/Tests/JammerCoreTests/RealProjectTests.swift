import CryptoKit
import Foundation
import Testing
@testable import JammerCore

/// Projects that really are on a Mac (not ones the test suite makes up), each rendered as it is now and
/// at every step of its history. Run with `JAMMER_REAL_PROJECTS` set to paths separated by ":" (project
/// packages, folders of them, or a Final Cut timeline file). Every project is read from a copy.
///
/// With the older render paths and the graph both in the engine (up to the commit tagged
/// `before-graph-only`), it compares the two. And it keeps the comparison possible once the older paths
/// are gone: `JAMMER_REAL_WRITE=<file>` writes a digest of every state's render (run it at the tag, where
/// it writes what the OLDER paths give), and `JAMMER_REAL_CHECK=<file>` holds the present build to that
/// file. So a document that turns up later, a user's or Anders's, can still be tried against what shipped.
@Suite("Real projects: the graph against the older paths", .serialized, .enabled(if: ProcessInfo.processInfo.environment["JAMMER_REAL_PROJECTS"] != nil))
struct RealProjectTests {
    @Test("Every project found, and every state in its history: the same samples both ways")
    func bothWays() throws {
        let given = (ProcessInfo.processInfo.environment["JAMMER_REAL_PROJECTS"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let scratch = TempDir()
        var compared = 0, states = 0, frames: Int64 = 0, different: [String] = [], unread: [String] = []
        let env = ProcessInfo.processInfo.environment
        var written: [String: String] = [:]
        let reference: [String: String]? = env["JAMMER_REAL_CHECK"].flatMap { try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: $0))) }
        if env["JAMMER_REAL_CHECK"] != nil { #expect(reference != nil, "the reference file can't be read") }
        var checked = 0, missing: [String] = []
        func digest(_ x: [Float], _ y: [Float]) -> String { (x + y).withUnsafeBytes { SHA256.hash(data: Data($0)) }.map { String(format: "%02x", $0) }.joined() }
        func compare(_ name: String, _ p: Project) {
            guard p.length > 0 else { return }
            let pool = SourcePool()
            func plan(_ graph: Bool) -> RenderPlan {
                PlanCompiler.compile(p, pool: pool, inserts: p.hasActiveInserts ? InsertHost.makeBlocking(for: p) : nil, allInGraph: graph)
            }
            // The whole project in one piece, and a stretch from the middle after a seek.
            let n = Int(min(p.length, Frame(p.sampleRate * 120)))
            let a = plan(false).render(from: 0, frames: n), b = plan(true).render(from: 0, frames: n)
            let from = n / 3, some = min(n - from, 20_000)
            let c = plan(false).render(from: Frame(from), frames: some), d = plan(true).render(from: Frame(from), frames: some)
            let silent = a.allSatisfy { $0 == 0 }
            // The reference is of the older paths' render (a, c); it is checked against the graph's (b, d).
            written[name] = digest(a, c)
            if let reference {
                if let was = reference[name] { checked += 1; if digest(b, d) != was { different.append("\(name) (not the reference's samples)") } } else { missing.append(name) }
            }
            states += 1
            frames += Int64(n)
            if a != b || c != d {
                var worst: Float = 0
                for i in 0..<min(a.count, b.count) { worst = max(worst, abs(a[i] - b[i])) }
                different.append("\(name) (largest difference \(worst))")
            }
            print("REAL \(name): \(p.tracks.count) tracks, \(p.tracks.reduce(0) { $0 + $1.clips.count }) clips, \(p.allInserts.count) plugins, \(p.buses.count) buses, \(String(format: "%.1f", Double(n) / p.sampleRate)) s\(silent ? ", SILENT (its audio couldn't be read)" : ""): \(a == b && c == d ? "bit for bit" : "DIFFERENT")")
        }
        for url in given {
            var packages: [URL] = []
            if url.pathExtension == "jammer" { packages = [url] }
            else if url.pathExtension == "fcpxml" {
                // A film's timeline as Flimmer exports it: built into a project here, its media read in place.
                do {
                    let built = try FCPXMLImport.build(try FCPXMLImport.read(url), mediaFolder: scratch.url.appending(path: "decoded"))
                    compare(url.lastPathComponent, built.project)
                    compared += 1
                } catch { unread.append("\(url.lastPathComponent): \(error)") }
                continue
            } else {
                packages = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "jammer" }.sorted { $0.path < $1.path }
            }
            for package in packages {
                // A copy: nothing of the project on disk is opened for writing or touched.
                let copy = scratch.url.appending(path: "\(UUID().uuidString.prefix(6))-\(package.lastPathComponent)")
                do {
                    try FileManager.default.copyItem(at: package, to: copy)
                    let wrapper = try FileWrapper(url: copy)
                    let project = try ProjectPackage.read(wrapper, packageURL: copy)
                    compare(package.lastPathComponent, project)
                    compared += 1
                    if let data = wrapper.fileWrappers?["history.json"]?.regularFileContents, let h = try? JSONDecoder().decode(History.self, from: data) {
                        for (i, node) in h.nodes.enumerated() { if let p = try? h.project(of: node.id) { compare("\(package.lastPathComponent) history \(i) (\(node.action))", p) } }
                    }
                } catch { unread.append("\(package.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        print("REAL \(compared) projects, \(states) states, \(frames) frames rendered each way; different: \(different.isEmpty ? "none" : different.joined(separator: "; ")); not read: \(unread.isEmpty ? "none" : unread.joined(separator: "; "))")
        if let path = env["JAMMER_REAL_WRITE"] {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys, .prettyPrinted]
            try e.encode(written).write(to: URL(fileURLWithPath: path), options: .atomic)
            print("REAL wrote \(written.count) digests to \(path)")
        }
        if reference != nil { print("REAL checked \(checked) states against the reference; not in it: \(missing.isEmpty ? "none" : missing.joined(separator: "; "))") }
        #expect(compared > 0 && different.isEmpty, "\(different)")
    }
}
