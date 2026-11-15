import Foundation
import Testing
@testable import JammerPlugins

/// Small CLAP plugins compiled for the test, so the scanner meets real bundles that load,
/// crash and hang, not a script pretending to be one.
enum TestPlugins {
    static let source = """
    #include <clap/clap.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>
    #include <stdio.h>
    #include <signal.h>
    #include <sys/socket.h>
    #include <netinet/in.h>
    static const char *features[] = { CLAP_PLUGIN_FEATURE_AUDIO_EFFECT, CLAP_PLUGIN_FEATURE_STEREO, NULL };
    static const clap_plugin_descriptor_t desc = {
        .clap_version = CLAP_VERSION_INIT, .id = "com.brattoo.test." NAME, .name = "Test \\"" NAME "\\"", .vendor = "Brattoo Tests",
        .url = "", .manual_url = "", .support_url = "", .version = "1.2.3", .description = "", .features = features };
    static uint32_t count(const clap_plugin_factory_t *f) { return 1; }
    static const clap_plugin_descriptor_t *get(const clap_plugin_factory_t *f, uint32_t i) { return i == 0 ? &desc : NULL; }
    static const clap_plugin_t *create(const clap_plugin_factory_t *f, const clap_host_t *h, const char *id) { return NULL; }
    static const clap_plugin_factory_t factory = { count, get, create };
    static bool init(const char *path) {
    #ifdef CRASH
        abort();
    #endif
    #ifdef SEGV
        volatile int *p = 0; *p = 1;
    #endif
    #ifdef HANG
        for (;;) pause();
    #endif
    #ifdef IGNORES_TERM
        signal(SIGTERM, SIG_IGN); for (;;) pause();
    #endif
    #ifdef CHATTY
        for (int i = 0; i < 200000; ++i) fprintf(stdout, "noise noise noise noise noise noise noise noise\\n");
    #endif
    #ifdef SNOOP
        /* Tries what a scan must not allow, and says which of them worked. */
        char said[256] = "";
        FILE *f = fopen(SECRET, "r"); if (f) { strcat(said, " read"); fclose(f); }
        f = fopen(SECRET ".written", "w"); if (f) { strcat(said, " wrote"); fclose(f); }
        int s = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in a; memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = htons(PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (s >= 0 && connect(s, (struct sockaddr *)&a, sizeof a) == 0) strcat(said, " connected");
        if (said[0]) { fprintf(stderr, "LEAK:%s", said); return false; }
    #endif
    #ifdef REFUSES
        return false;
    #endif
        return true;
    }
    static void deinit(void) {}
    static const void *get_factory(const char *id) { return strcmp(id, CLAP_PLUGIN_FACTORY_ID) == 0 ? &factory : NULL; }
    CLAP_EXPORT const clap_plugin_entry_t clap_entry = { CLAP_VERSION_INIT, init, deinit, get_factory };
    """

    static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Builds `<name>.clap` in `dir` with the given behaviour (a -D flag) and returns the bundle.
    static func build(_ name: String, flag: String? = nil, defines: [String] = [], in dir: URL) throws -> URL {
        let bundle = dir.appending(path: "\(name).clap"), macos = bundle.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>\(name)</string><key>CFBundleIdentifier</key><string>com.brattoo.test.\(name)</string>
        <key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
        """.write(to: bundle.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
        let c = dir.appending(path: "\(name).c")
        try source.write(to: c, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["clang", "-bundle", "-arch", "arm64", "-I", package.appending(path: "Vendor/clap/include").path, "-DNAME=\"\(name)\""]
            + (flag.map { ["-D\($0)"] } ?? []) + defines.map { "-D\($0)" } + ["-o", macos.appending(path: name).path, c.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "TestPlugins", code: 1, userInfo: [NSLocalizedDescriptionKey: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
        }
        return bundle
    }

    /// The helper, built next to the tests (the test bundle's folder is the products folder).
    static var probe: URL { Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appending(path: "jammer-plugin-probe") }
    final class Anchor {}
}

@Suite("Plugin scanner")
struct ScannerTests {
    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "jammer-scan-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("A plugin that loads is described: id, name, vendor, version, features")
    func good() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try TestPlugins.build("Good", in: dir)
        let outcome = PluginScanner(probe: TestPlugins.probe).probe(bundle, format: .clap)
        #expect(outcome == .found([ScannedPlugin(format: .clap, id: "com.brattoo.test.Good", name: "Test \"Good\"", vendor: "Brattoo Tests", version: "1.2.3",
                                                 features: ["audio-effect", "stereo"], bundle: bundle.path)]), "\(outcome)")
    }

    @Test("A plugin that crashes while it is loaded takes the helper with it, not the caller", arguments: [("CRASH", SIGABRT), ("SEGV", SIGSEGV)])
    func crash(flag: String, signal: Int32) throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try TestPlugins.build("Bad", flag: flag, in: dir)
        let outcome = PluginScanner(probe: TestPlugins.probe).probe(bundle, format: .clap)
        #expect(outcome == .crashed(signal: signal) && outcome.failure == "crashed", "\(outcome)")
        // And the scanner is as good as before: the next bundle is read.
        let good = try TestPlugins.build("After", in: dir)
        #expect(PluginScanner(probe: TestPlugins.probe).probe(good, format: .clap).failure == nil)
    }

    @Test("A plugin that hangs is given up on at the time limit and killed, also when it ignores being asked", arguments: ["HANG", "IGNORES_TERM"])
    func hang(flag: String) throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try TestPlugins.build("Stuck", flag: flag, in: dir)
        let t0 = Date()
        let outcome = PluginScanner(probe: TestPlugins.probe, timeout: 1).probe(bundle, format: .clap)
        let took = Date().timeIntervalSince(t0)
        #expect(outcome == .timedOut && took >= 1 && took < 4, "\(outcome) after \(took) s")
        // Nothing is left running.
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command"]
        let out = Pipe()
        ps.standardOutput = out
        try ps.run()
        let list = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(!list.contains(bundle.path), "the helper for the stuck plugin is still running")
    }

    @Test("While it is scanned a plugin can't read the user's files, write anything or reach the network")
    func confined() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appending(path: "secret.txt")
        try "the user's own".write(to: secret, atomically: true, encoding: .utf8)
        // Something to connect to, so that a refused connection means the sandbox and not an empty port.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, len) == 0 && getsockname(listener, $0, &len) == 0 } }
        #expect(bound && listen(listener, 4) == 0)
        let port = Int(UInt16(bigEndian: addr.sin_port))
        let bundle = try TestPlugins.build("Snoop", flag: "SNOOP", defines: ["SECRET=\"\(secret.path)\"", "PORT=\(port)"], in: dir)
        let outcome = PluginScanner(probe: TestPlugins.probe).probe(bundle, format: .clap)
        #expect(outcome.failure == nil, "\(outcome)")
        #expect(!FileManager.default.fileExists(atPath: secret.path + ".written"))
        // The same plugin outside the confinement does all three, which is what the test plugin is for.
        let p = Process()
        p.executableURL = TestPlugins.probe
        p.arguments = ["clap", bundle.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("LEAK: read wrote connected"))
    }

    @Test("What isn't a plugin is said to be invalid: a folder, a bundle without the entry, one that refuses, one that floods the output")
    func invalid() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scanner = PluginScanner(probe: TestPlugins.probe, timeout: 10)
        let empty = dir.appending(path: "Empty.clap")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(scanner.probe(empty, format: .clap).failure == "invalid")
        // A bundle with code but no clap_entry (a text file as its "executable" can't be loaded at all).
        let fake = dir.appending(path: "Fake.clap")
        try FileManager.default.createDirectory(at: fake.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try "not code".write(to: fake.appending(path: "Contents/MacOS/Fake"), atomically: true, encoding: .utf8)
        try "<plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>Fake</string></dict></plist>".write(to: fake.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
        #expect(scanner.probe(fake, format: .clap).failure == "invalid")
        #expect(scanner.probe(try TestPlugins.build("Refuses", flag: "REFUSES", in: dir), format: .clap) == .invalid("clap_entry.init failed"))
        // Megabytes of output before the answer: still read, and the answer is the last line.
        #expect(scanner.probe(try TestPlugins.build("Chatty", flag: "CHATTY", in: dir), format: .clap).failure == nil)
        #expect(scanner.probe(dir.appending(path: "nothing-here.clap"), format: .clap).failure == "invalid")
        #expect(PluginScanner(probe: dir.appending(path: "no-helper")).probe(empty, format: .clap).failure == "invalid")
    }

    @Test("The catalogue remembers each bundle: only new and changed ones are loaded again, failures stay failures, a blocked plugin is listed apart")
    func catalogue() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clap = dir.appending(path: "CLAP")
        try FileManager.default.createDirectory(at: clap.appending(path: "Vendor"), withIntermediateDirectories: true)
        let good = try TestPlugins.build("Good", in: clap.appending(path: "Vendor"))
        _ = try TestPlugins.build("Bad", flag: "CRASH", in: clap)
        _ = try TestPlugins.build("Stuck", flag: "HANG", in: clap)
        try "x".write(to: clap.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        let scanner = PluginScanner(probe: TestPlugins.probe, timeout: 1)
        var c = PluginCatalogue()
        #expect(c.scan(with: scanner, folders: [.clap: [clap]]) == 3)
        #expect(c.plugins.map(\.id) == ["com.brattoo.test.Good"])
        #expect(Set(c.failed.map { "\($0.name) \($0.reason)" }) == ["Bad crashed", "Stuck timed_out"])
        // Saved and read back; nothing has changed, so nothing is loaded.
        let file = dir.appending(path: "store/plugins.json")
        try c.save(file)
        var again = PluginCatalogue.load(file)
        #expect(again == c && again.scan(with: scanner, folders: [.clap: [clap]]) == 0 && again == c)
        // A bundle that changed is loaded again; one that is gone is dropped; force loads everything.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: good.path)
        try FileManager.default.removeItem(at: clap.appending(path: "Stuck.clap"))
        #expect(again.scan(with: scanner, folders: [.clap: [clap]]) == 1 && again.failed.map(\.reason) == ["crashed"] && again.plugins.count == 1)
        #expect(again.scan(with: scanner, folders: [.clap: [clap]], force: true) == 2)
        // Blocked after a crash in use: not offered, listed as blocked, and back when unblocked.
        again.blocked.insert("clap:com.brattoo.test.Good")
        #expect(again.plugins.isEmpty && again.plugin("clap:com.brattoo.test.Good") == nil && again.failed.contains(.init(name: "Test \"Good\"", format: .clap, reason: "blocked")))
        again.blocked.removeAll()
        #expect(again.plugin("clap:com.brattoo.test.Good")?.bundle.hasSuffix("CLAP/Vendor/Good.clap") == true)
        // A missing or broken file is an empty catalogue, not an error.
        #expect(PluginCatalogue.load(dir.appending(path: "none.json")) == PluginCatalogue())
    }
}
