import Foundation
import Testing
import JammerPluginHost
import JammerPlugins
import JammerCore
import JammerEngine
import JammerAgent

/// A real CLAP effect, compiled for the test: a gain with a 64-sample delay (so it has
/// latency), one automatable parameter, one read-only one, and saved state.
enum TestEffect {
    static let source = """
    #include <clap/clap.h>
    #include <stdlib.h>
    #include <string.h>
    #include <stdio.h>
    #include <unistd.h>
    #include <sys/socket.h>
    #include <netinet/in.h>
    static int blocks = 0;
    static double leaks = 0.25;
    #ifndef CHANNELS
    #define CHANNELS 2
    #endif
    #define LAT 64
    typedef struct { clap_plugin_t plugin; double gain; float line[2][LAT]; int at; } fx_t;
    static const char *features[] = { CLAP_PLUGIN_FEATURE_AUDIO_EFFECT, NULL };
    static const clap_plugin_descriptor_t desc = { CLAP_VERSION_INIT, "com.brattoo.test.fx", "Delay Gain", "Brattoo Tests", "", "", "", "1.0", "", features };
    static bool fx_init(const clap_plugin_t *p) {
    #ifdef CRASH_ON_INIT
        abort();
    #endif
    #ifdef SNOOP
        /* Tries what a hosted plugin must not be able to do; the read-only parameter says how many worked. */
        leaks = 0;
        FILE *f = fopen(SECRET, "r"); if (f) { leaks += 1; fclose(f); }
        f = fopen(SECRET ".written", "w"); if (f) { leaks += 1; fclose(f); }
        int s = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in a; memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = htons(PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (s >= 0 && connect(s, (struct sockaddr *)&a, sizeof a) == 0) leaks += 1;
        printf("a plugin that prints to stdout must not disturb the host\\n"); fflush(stdout);
    #endif
        return true;
    }
    static void fx_destroy(const clap_plugin_t *p) { free(p->plugin_data); }
    static bool fx_activate(const clap_plugin_t *p, double sr, uint32_t min, uint32_t max) {
    #ifdef FAIL_ACTIVATE
        return false;
    #endif
        return true;
    }
    static void fx_deactivate(const clap_plugin_t *p) {}
    static bool fx_start(const clap_plugin_t *p) { return true; }
    static void fx_stop(const clap_plugin_t *p) {}
    static void fx_reset(const clap_plugin_t *p) { fx_t *f = p->plugin_data; memset(f->line, 0, sizeof f->line); f->at = 0; }
    static void take(fx_t *f, const clap_input_events_t *in) {
        uint32_t n = in ? in->size(in) : 0;
        for (uint32_t i = 0; i < n; ++i) {
            const clap_event_header_t *h = in->get(in, i);
            if (h->space_id == CLAP_CORE_EVENT_SPACE_ID && h->type == CLAP_EVENT_PARAM_VALUE) {
                const clap_event_param_value_t *e = (const clap_event_param_value_t *)h;
                if (e->param_id == 7) f->gain = e->value;
            }
        }
    }
    static clap_process_status fx_process(const clap_plugin_t *p, const clap_process_t *pr) {
    #ifdef PROCESS_ERROR
        return CLAP_PROCESS_ERROR;
    #endif
        ++blocks;
    #ifdef CRASH_AT_BLOCK
        if (blocks == CRASH_AT_BLOCK) abort();
    #endif
    #ifdef HANG_AT_BLOCK
        if (blocks == HANG_AT_BLOCK) for (;;) pause();
    #endif
        fx_t *f = p->plugin_data;
        take(f, pr->in_events);
        for (uint32_t i = 0; i < pr->frames_count; ++i) {
            for (int c = 0; c < CHANNELS; ++c) {
                float x = pr->audio_inputs[0].data32[c][i];
                pr->audio_outputs[0].data32[c][i] = (float)(f->line[c][f->at] * f->gain);
                f->line[c][f->at] = x;
            }
            f->at = (f->at + 1) % LAT;
        }
        return CLAP_PROCESS_CONTINUE;
    }
    static uint32_t ports_count(const clap_plugin_t *p, bool in) { return 1; }
    static bool ports_get(const clap_plugin_t *p, uint32_t i, bool in, clap_audio_port_info_t *info) {
        if (i) return false;
        memset(info, 0, sizeof *info); info->id = in ? 1 : 2; strcpy(info->name, "main"); info->channel_count = CHANNELS;
        info->flags = CLAP_AUDIO_PORT_IS_MAIN; info->port_type = CHANNELS == 2 ? CLAP_PORT_STEREO : CLAP_PORT_MONO; info->in_place_pair = CLAP_INVALID_ID; return true;
    }
    static const clap_plugin_audio_ports_t ports = { ports_count, ports_get };
    static uint32_t params_count(const clap_plugin_t *p) { return 2; }
    static bool params_info(const clap_plugin_t *p, uint32_t i, clap_param_info_t *info) {
        if (i > 1) return false;
        memset(info, 0, sizeof *info);
        if (i == 0) { info->id = 7; strcpy(info->name, "Gain"); strcpy(info->module, "Level"); info->min_value = 0; info->max_value = 2; info->default_value = 1; info->flags = CLAP_PARAM_IS_AUTOMATABLE; }
        else { info->id = 9; strcpy(info->name, "Meter"); info->min_value = 0; info->max_value = 1; info->flags = CLAP_PARAM_IS_READONLY; }
        return true;
    }
    static bool params_value(const clap_plugin_t *p, clap_id id, double *v) { fx_t *f = p->plugin_data; if (id == 7) { *v = f->gain; return true; } if (id == 9) { *v = leaks; return true; } return false; }
    static bool params_text(const clap_plugin_t *p, clap_id id, double v, char *out, uint32_t n) { return false; }
    static bool params_from(const clap_plugin_t *p, clap_id id, const char *t, double *v) { return false; }
    static void params_flush(const clap_plugin_t *p, const clap_input_events_t *in, const clap_output_events_t *out) { take(p->plugin_data, in); }
    static const clap_plugin_params_t params = { params_count, params_info, params_value, params_text, params_from, params_flush };
    static uint32_t latency_get(const clap_plugin_t *p) { return LAT; }
    static const clap_plugin_latency_t latency = { latency_get };
    static bool state_save(const clap_plugin_t *p, const clap_ostream_t *s) { fx_t *f = p->plugin_data; return s->write(s, &f->gain, sizeof f->gain) == sizeof f->gain; }
    static bool state_load(const clap_plugin_t *p, const clap_istream_t *s) { fx_t *f = p->plugin_data; double g; if (s->read(s, &g, sizeof g) != sizeof g) return false; f->gain = g; return true; }
    static const clap_plugin_state_t state = { state_save, state_load };
    static const void *fx_ext(const clap_plugin_t *p, const char *id) {
        if (!strcmp(id, CLAP_EXT_AUDIO_PORTS)) return &ports;
        if (!strcmp(id, CLAP_EXT_PARAMS)) return &params;
        if (!strcmp(id, CLAP_EXT_LATENCY)) return &latency;
    #ifndef NO_STATE
        if (!strcmp(id, CLAP_EXT_STATE)) return &state;
    #endif
        return NULL;
    }
    static void fx_main(const clap_plugin_t *p) {}
    static const clap_plugin_t *create(const clap_plugin_factory_t *fa, const clap_host_t *h, const char *id) {
        if (strcmp(id, desc.id)) return NULL;
        fx_t *f = calloc(1, sizeof *f);
        f->gain = 1;
        f->plugin = (clap_plugin_t){ &desc, f, fx_init, fx_destroy, fx_activate, fx_deactivate, fx_start, fx_stop, fx_reset, fx_process, fx_ext, fx_main };
        return &f->plugin;
    }
    static uint32_t count(const clap_plugin_factory_t *f) { return 1; }
    static const clap_plugin_descriptor_t *get(const clap_plugin_factory_t *f, uint32_t i) { return i ? NULL : &desc; }
    static const clap_plugin_factory_t factory = { count, get, create };
    static bool entry_init(const char *path) { return true; }
    static void entry_deinit(void) {}
    static const void *get_factory(const char *id) { return strcmp(id, CLAP_PLUGIN_FACTORY_ID) ? NULL : &factory; }
    CLAP_EXPORT const clap_plugin_entry_t clap_entry = { CLAP_VERSION_INIT, entry_init, entry_deinit, get_factory };
    """

    static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func build(_ name: String, defines: [String] = [], in dir: URL) throws -> URL {
        let bundle = dir.appending(path: "\(name).clap"), macos = bundle.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try "<plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>\(name)</string></dict></plist>"
            .write(to: bundle.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
        let c = dir.appending(path: "\(name).c")
        try source.write(to: c, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["clang", "-bundle", "-arch", "arm64", "-I", package.appending(path: "Vendor/clap/include").path] + defines.map { "-D\($0)" }
            + ["-o", macos.appending(path: name).path, c.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "TestEffect", code: 1, userInfo: [NSLocalizedDescriptionKey: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
        }
        return bundle
    }
}

@Suite("Hosting a CLAP effect")
struct HostTests {
    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "jammer-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func open(_ bundle: URL, id: String = "com.brattoo.test.fx", channels: Int32 = 2, max: Int32 = 512) -> (OpaquePointer?, String) {
        var error = [CChar](repeating: 0, count: 256)
        let p = jph_clap_open(bundle.path, id, 48_000, channels, max, &error, 256)
        return (p, String(cString: error))
    }

    /// Runs `left` (and its negative on the right) through the plugin in blocks of `block`.
    func run(_ p: OpaquePointer, _ left: [Float], block: Int = 512, channels: Int = 2) -> (out: [[Float]], ok: Bool) {
        var out = [[Float]](repeating: [Float](repeating: 0, count: left.count), count: channels)
        let input: [[Float]] = channels == 2 ? [left, left.map { -$0 }] : [left]
        var ok = true, at = 0
        // Plain allocated buffers: what the host's C interface takes.
        let ins = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        let outs = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        defer { (ins + outs).forEach { $0.deallocate() } }
        let inPointers = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: channels)
        let outPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
        defer { inPointers.deallocate(); outPointers.deallocate() }
        for c in 0..<channels { inPointers[c] = UnsafePointer(ins[c]); outPointers[c] = outs[c] }
        while at < left.count {
            let n = min(block, left.count - at)
            for c in 0..<channels {
                for i in 0..<n { ins[c][i] = input[c][at + i]; outs[c][i] = 0 }
            }
            if !jph_process(p, inPointers, outPointers, Int32(n)) { ok = false }
            for c in 0..<channels { for i in 0..<n { out[c][at + i] = outs[c][i] } }
            at += n
        }
        return (out, ok)
    }

    @Test("Loads, reports latency and parameters, processes in any block size, takes parameter changes, saves and restores state")
    func effect() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try TestEffect.build("Fx", in: dir)
        let (opened, why) = open(bundle)
        let p = try #require(opened, "\(why)")
        defer { jph_close(p) }
        #expect(jph_latency(p) == 64 && jph_param_count(p) == 2)
        var info = jph_param()
        #expect(jph_param_info(p, 0, &info) && info.id == 7 && info.min == 0 && info.max == 2 && info.value == 1 && info.initial == 1 && !info.readonly)
        #expect(withUnsafeBytes(of: info.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } == "Gain")
        #expect(withUnsafeBytes(of: info.module) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } == "Level")
        #expect(jph_param_info(p, 1, &info) && info.id == 9 && info.readonly && info.value == 0.25 && !jph_param_info(p, 2, &info))
        // A ramp through it: the same samples 64 later, each side its own, whatever the block size.
        let ramp = (0..<2_000).map { Float($0 + 1) / 4_000 }
        for block in [512, 100, 1, 333] {
            jph_reset(p)
            let (out, ok) = run(p, ramp, block: block)
            #expect(ok && out[0][0..<64].allSatisfy { $0 == 0 }, "block \(block)")
            #expect((64..<2_000).allSatisfy { out[0][$0] == ramp[$0 - 64] && out[1][$0] == -ramp[$0 - 64] }, "block \(block)")
        }
        // A parameter change is heard from the next block; a read-only or unknown one is refused; values are clamped.
        #expect(jph_param_set(p, 7, 0.5) && !jph_param_set(p, 9, 1) && !jph_param_set(p, 99, 1))
        var v = 0.0
        #expect(jph_param_get(p, 7, &v) && v == 0.5)
        jph_reset(p)
        #expect(run(p, ramp).out[0][100] == ramp[36] * 0.5)
        #expect(jph_param_set(p, 7, 5) && jph_param_get(p, 7, &v) && v == 2)
        // State out of this one, into a fresh one.
        #expect(jph_param_set(p, 7, 0.25))
        var data: UnsafeMutablePointer<UInt8>?, size = 0
        #expect(jph_state_save(p, &data, &size) && size == 8)
        defer { jph_free(data) }
        let (second, _) = open(bundle)
        let q = try #require(second)
        defer { jph_close(q) }
        #expect(jph_param_get(q, 7, &v) && v == 1)
        #expect(jph_state_load(q, data!, size) && jph_param_get(q, 7, &v) && v == 0.25)
        #expect(run(q, ramp).out[0][100] == ramp[36] * 0.25)
        // Reset forgets the delay line: no old sound comes out after it.
        _ = run(q, ramp)
        jph_reset(q)
        #expect(run(q, [Float](repeating: 0, count: 256)).out[0].allSatisfy { $0 == 0 })
        // A block larger than it was set up for is refused and the sound passes through untouched.
        let (big, ok) = run(q, ramp, block: 600)
        #expect(!ok && big[0][0..<600] == ramp[0..<600])
    }

    @Test("What can't be hosted says why, and a plugin that fails while processing lets the sound through")
    func refusals() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stereo = try TestEffect.build("Fx", in: dir)
        #expect(open(stereo, id: "no.such.plugin") == (nil, "The bundle has no plugin with that id.") as (OpaquePointer?, String))
        #expect(open(stereo, channels: 1).1 == "The plugin doesn't take mono audio.")
        #expect(open(dir.appending(path: "Nothing.clap")).1 == "The plugin's code couldn't be loaded.")
        let mono = try TestEffect.build("Mono", defines: ["CHANNELS=1"], in: dir)
        #expect(open(mono).1 == "The plugin doesn't take stereo audio.")
        let (m, _) = open(mono, channels: 1)
        let mp = try #require(m)
        defer { jph_close(mp) }
        let ramp = (0..<300).map { Float($0 + 1) / 600 }
        #expect(run(mp, ramp, channels: 1).out[0][200] == ramp[136])
        #expect(open(try TestEffect.build("NoStart", defines: ["FAIL_ACTIVATE"], in: dir)).1 == "The plugin couldn't be activated at this sample rate.")
        let (e, _) = open(try TestEffect.build("Errs", defines: ["PROCESS_ERROR"], in: dir))
        let ep = try #require(e)
        defer { jph_close(ep) }
        let (out, ok) = run(ep, ramp)
        #expect(!ok && out[0] == ramp && out[1] == ramp.map { -$0 })
        // No state extension: saving says so instead of inventing an empty state.
        let (n, _) = open(try TestEffect.build("Stateless", defines: ["NO_STATE"], in: dir))
        let np = try #require(n)
        defer { jph_close(np) }
        var data: UnsafeMutablePointer<UInt8>?, size = 0
        #expect(!jph_state_save(np, &data, &size))
    }
}

/// The same effect, in a helper process of its own.
@Suite("A plugin in its own process")
struct HostProcessTests {
    static var helper: URL { Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appending(path: "jammer-plugin-host") }
    final class Anchor {}

    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "jammer-hostp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func start(_ bundle: URL, id: String = "com.brattoo.test.fx", channels: Int = 2, timeout: Double = 20) throws -> PluginHostProcess {
        try PluginHostProcess(helper: Self.helper, format: .clap, bundle: bundle, id: id, sampleRate: 48_000, channels: channels, timeout: timeout)
    }

    /// Runs `left` (and its negative on the right) through the plugin in blocks; says which blocks were processed.
    func run(_ p: PluginHostProcess, _ left: [Float], block: Int = 512, during: (Int) -> Void = { _ in }) -> (out: [[Float]], processed: [Bool]) {
        let channels = p.channels
        var out = [[Float]](repeating: [Float](repeating: 0, count: left.count), count: channels), processed: [Bool] = []
        let input: [[Float]] = channels == 2 ? [left, left.map { -$0 }] : [left]
        let ins = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        let outs = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        defer { (ins + outs).forEach { $0.deallocate() } }
        let inPointers = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: channels)
        let outPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
        defer { inPointers.deallocate(); outPointers.deallocate() }
        for c in 0..<channels { inPointers[c] = UnsafePointer(ins[c]); outPointers[c] = outs[c] }
        var at = 0
        while at < left.count {
            let n = min(block, left.count - at)
            for c in 0..<channels { for i in 0..<n { ins[c][i] = input[c][at + i]; outs[c][i] = 0 } }
            during(processed.count)
            processed.append(p.process(inPointers, outPointers, frames: n))
            for c in 0..<channels { for i in 0..<n { out[c][at + i] = outs[c][i] } }
            at += n
        }
        return (out, processed)
    }

    let ramp = (0..<8_192).map { Float($0 + 1) / 16_384 }

    @Test("The layout the helper sends parameters in is the C struct's")
    func layout() {
        #expect(MemoryLayout<jph_param>.size == 560 && MemoryLayout<jph_param>.offset(of: \.name) == 4 && MemoryLayout<jph_param>.offset(of: \.module) == 260)
        #expect(MemoryLayout<jph_param>.offset(of: \.min) == 520 && MemoryLayout<jph_param>.offset(of: \.initial) == 544 && MemoryLayout<jph_param>.offset(of: \.hidden) == 554)
    }

    @Test("Through the helper the sound is the same as hosted directly: latency, parameters, state, any block size")
    func sameAsDirect() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try TestEffect.build("Fx", in: dir)
        let p = try start(bundle)
        #expect(p.latency == 64 && p.died == nil)
        #expect(p.parameters.map(\.name) == ["Gain", "Meter"] && p.parameters[0] == .init(id: 7, name: "Gain", module: "Level", min: 0, max: 2, value: 1, initial: 1, stepped: false, readonly: false, hidden: false))
        #expect(p.parameters[1].readonly && p.parameters[1].value == 0.25)
        for block in [512, 100, 1] {
            p.reset()
            let (out, processed) = run(p, Array(ramp.prefix(block == 1 ? 300 : 2_000)), block: block)
            #expect(processed.allSatisfy { $0 } && out[0][0..<64].allSatisfy { $0 == 0 })
            #expect((64..<out[0].count).allSatisfy { out[0][$0] == ramp[$0 - 64] && out[1][$0] == -ramp[$0 - 64] }, "block \(block)")
        }
        #expect(p.set(7, to: 0.5) && !p.set(9, to: 1))
        p.refresh()
        #expect(p.parameters[0].value == 0.5)
        p.reset()
        #expect(run(p, ramp).out[0][100] == ramp[36] * 0.5)
        let state = try #require(p.saveState())
        let q = try start(bundle)
        #expect(q.loadState(state))
        q.refresh()
        #expect(q.parameters[0].value == 0.5 && state.count == 8)
        // A block larger than it was set up for passes through.
        let (big, processed) = run(q, ramp, block: 600)
        #expect(processed.first == false && big[0][0..<600] == ramp[0..<600])
    }

    @Test("A plugin that crashes in the middle: that block and the rest pass through, the death is told once, another plugin is untouched")
    func crashes() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try start(try TestEffect.build("Bad", defines: ["CRASH_AT_BLOCK=5"], in: dir))
        let other = try start(try TestEffect.build("Fine", in: dir))
        final class Told: @unchecked Sendable { var deaths: [PluginHostProcess.Death] = [] }
        let told = Told()
        p.onDeath = { told.deaths.append($0) }
        let (out, processed) = run(p, ramp)
        #expect(processed == [true, true, true, true] + [Bool](repeating: false, count: 12))
        #expect(p.died == .crashed(signal: SIGABRT) && told.deaths == [.crashed(signal: SIGABRT)])
        // Four processed blocks (delayed by the plugin), then the sound as it went in.
        #expect(out[0][2_047] == ramp[2_047 - 64] && Array(out[0][2_048...]) == Array(ramp[2_048...]) && Array(out[1][2_048...]) == ramp[2_048...].map { -$0 })
        #expect(!p.set(7, to: 0.5) && p.saveState() == nil)
        #expect(run(other, ramp).processed.allSatisfy { $0 } && other.died == nil)
    }

    @Test("A plugin that hangs in the middle is given up on at the time limit and killed; the sound goes on")
    func hangs() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try start(try TestEffect.build("Stuck", defines: ["HANG_AT_BLOCK=3"], in: dir), timeout: 1)
        let pid = p.processIdentifier
        let t0 = Date()
        let (out, processed) = run(p, ramp)
        let took = Date().timeIntervalSince(t0)
        #expect(processed == [true, true] + [Bool](repeating: false, count: 14) && p.died == .hung && took >= 1 && took < 10, "\(took) s")
        #expect(Array(out[0][1_024...]) == Array(ramp[1_024...]))
        usleep(300_000)
        #expect(kill(pid, 0) != 0, "the helper is still running")
    }

    @Test("The helper killed from outside in the middle of a render: nothing but that plugin is lost")
    func killed() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try start(try TestEffect.build("Fx", in: dir))
        let long = (0..<(512 * 400)).map { Float($0 % 1_000) / 2_000 }
        let pid = p.processIdentifier
        let (out, processed) = run(p, long, during: { block in if block == 150 { kill(pid, SIGKILL) } })
        #expect(processed.prefix(150).allSatisfy { $0 } && processed.suffix(240).allSatisfy { !$0 } && p.died == .crashed(signal: SIGKILL), "\(String(describing: p.died))")
        let first = processed.firstIndex(of: false)!
        #expect(Array(out[0][(first * 512)...]) == Array(long[(first * 512)...]), "from the block it died in, the sound is what went in")
    }

    @Test("In the helper a plugin can't read the user's files, write or reach the network, and what it prints doesn't disturb the host")
    func confined() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appending(path: "secret.txt")
        try "the user's own".write(to: secret, atomically: true, encoding: .utf8)
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, len) == 0 && getsockname(listener, $0, &len) == 0 } }
        #expect(bound && listen(listener, 4) == 0)
        let real = realpath(secret.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? secret.path
        let bundle = try TestEffect.build("Snoop", defines: ["SNOOP", "SECRET=\"\(real)\"", "PORT=\(Int(UInt16(bigEndian: addr.sin_port)))"], in: dir)
        let p = try start(bundle)
        #expect(p.parameters[1].value == 0, "the plugin managed \(p.parameters[1].value) of read, write, connect")
        #expect(!FileManager.default.fileExists(atPath: real + ".written") && run(p, ramp).processed.allSatisfy { $0 })
        // Hosted directly, outside the confinement, the same plugin does all three: the test plugin does try.
        var error = [CChar](repeating: 0, count: 256)
        let direct = try #require(jph_clap_open(bundle.path, "com.brattoo.test.fx", 48_000, 2, 512, &error, 256))
        defer { jph_close(direct) }
        var v = 0.0
        #expect(jph_param_get(direct, 9, &v) && v == 3)
        try? FileManager.default.removeItem(atPath: real + ".written")
    }

    @Test("A plugin that won't start says why; one that crashes while loading is reported, not fatal")
    func startErrors() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try TestEffect.build("Fx", in: dir)
        func message(_ body: () throws -> PluginHostProcess) -> String? {
            do { _ = try body(); return nil } catch { return (error as? PluginHostProcess.StartError)?.message }
        }
        #expect(message { try start(bundle, id: "no.such") } == "The bundle has no plugin with that id.")
        #expect(message { try start(bundle, channels: 1) } == "The plugin doesn't take mono audio.")
        #expect(message { try start(try TestEffect.build("Dies", defines: ["CRASH_ON_INIT"], in: dir)) } == "The plugin crashed while it was being loaded.")
        #expect(message { try PluginHostProcess(helper: dir.appending(path: "none"), format: .clap, bundle: bundle, id: "x", sampleRate: 48_000, channels: 2) } == "The plugin host helper is missing.")
        #expect(message { try PluginHostProcess(helper: Self.helper, format: .vst3, bundle: bundle, id: "x", sampleRate: 48_000, channels: 2) } == "This build can't host vst3 plugins yet.")
    }
}

/// A helper must never be left behind.
@Suite("Helpers don't outlive what started them")
struct OrphanTests {
    func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    @Test("When the process that started a helper is killed, the helper ends by itself, also with its input still open")
    func parentKilled() throws {
        // A stand-in for the app: a shell that starts the helper and then just sits there. The test
        // holds the helper's input open, so the only thing that can end the helper is the watcher.
        let app = Process(), input = Pipe(), output = Pipe()
        app.executableURL = URL(fileURLWithPath: "/bin/sh")
        app.arguments = ["-c", "\"$0\" <&0 & echo $!; exec sleep 1000", HostProcessTests.helper.path]
        app.standardInput = input
        app.standardOutput = output
        try app.run()
        var line = Data()
        while let b = try output.fileHandleForReading.read(upToCount: 1), b != Data([10]) { line.append(b) }
        let helper = try #require(Int32(String(decoding: line, as: UTF8.self)))
        usleep(300_000)
        #expect(alive(helper) && alive(app.processIdentifier))
        kill(app.processIdentifier, SIGKILL)
        app.waitUntilExit()
        var waited = 0.0
        while alive(helper), waited < 5 { usleep(100_000); waited += 0.1 }
        #expect(!alive(helper), "the helper is still running \(waited) s after its parent was killed")
        _ = input   // kept open until here on purpose
    }

    @Test("Letting go of the plugin object ends its helper")
    func released() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-hostp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var pids: [Int32] = []
        do {
            let bundle = try TestEffect.build("Fx", in: dir)
            let hosts = try (0..<4).map { _ in try PluginHostProcess(helper: HostProcessTests.helper, format: .clap, bundle: bundle, id: "com.brattoo.test.fx", sampleRate: 48_000, channels: 2) }
            pids = hosts.map(\.processIdentifier)
            #expect(pids.allSatisfy(alive))
            // Also when it is held by an engine unit: the unit's release lets it go.
            _ = PluginHostUnit(hosts[0])
        }
        usleep(500_000)
        #expect(pids.allSatisfy { !alive($0) })
    }
}

/// The helper process in the engine's insert chain, where it will run: latency compensated,
/// sample for sample, and a dead helper leaves the track in time.
@Suite("A hosted plugin in the engine's chain")
struct ChainTests {
    /// Puts one hosted plugin on every track that has inserts.
    final class Provider: ChainProvider {
        let unit: PluginHostUnit
        let latency: Int64
        init(_ host: PluginHostProcess) { unit = PluginHostUnit(host); latency = Int64(host.latency) }
        func attachChain(for track: Track, to plan: OpaquePointer, index: Int32) -> Int64? {
            let chain = jm_chain_create(2, 4_096)
            jm_chain_add(chain, unit.unit, latency)
            jm_plan_set_chain(plan, index, chain)
            jm_chain_release(chain)
            return latency
        }
    }

    func film(seconds: Double = 4) -> (Project, SourcePool, [Float]) {
        let n = Int(seconds * 48_000)
        // Not periodic in 64 samples, so a shift by the plugin's latency can't hide.
        let x = (0..<n).flatMap { i -> [Float] in let v = Float(sin(Double(i) * 0.0137) * 0.4 + sin(Double(i) * 0.211) * 0.1); return [v, -v * 0.5] }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let ref = SourceRef(name: "t", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(ref.id, memory: x, channels: 2)
        var p = Project(source: ref)
        // Any insert makes the compiler ask the provider for a chain.
        p.tracks[0].inserts = [Insert(plugin: .init(type: 1, subtype: 2, manufacturer: 3), name: "Hosted")]
        return (p, pool, x)
    }

    func host(_ dir: URL, defines: [String] = [], timeout: Double = 20) throws -> PluginHostProcess {
        try PluginHostProcess(helper: HostProcessTests.helper, format: .clap, bundle: try TestEffect.build("Fx\(defines.count)", defines: defines, in: dir),
                              id: "com.brattoo.test.fx", sampleRate: 48_000, channels: 2, timeout: timeout)
    }

    @Test("An export with a plugin of known latency lines up sample for sample with one without")
    func latency() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-hostp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, pool, x) = film()
        let h = try host(dir)
        #expect(h.latency == 64 && h.set(7, to: 0.5))
        let plain = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length))
        #expect(plain == x)
        let provider = Provider(h)
        let with = PlanCompiler.compile(p, pool: pool, inserts: provider).render(from: 0, frames: Int(p.length))
        // The plugin delays by 64 and halves; in the export only the halving is left, at every sample.
        #expect(with.count == plain.count && with == plain.map { $0 * 0.5 })
        // From the middle, and in odd block sizes: the same samples as the whole export has there.
        let plan = PlanCompiler.compile(p, pool: pool, inserts: provider)
        let mid = plan.render(from: 50_001, frames: 30_000)
        #expect(mid == Array(with[(50_001 * 2)..<(80_001 * 2)]))
        var pieces: [Float] = []
        var at: Frame = 0
        for n in [1, 777, 512, 5_000, 63, 64, 65] { pieces += plan.render(from: at, frames: n); at += Frame(n) }
        #expect(pieces == Array(with[0..<pieces.count]))
    }

    @Test("The helper dies in the middle of an export: the rest is the unprocessed sound, still in time", arguments: ["CRASH_AT_BLOCK=40", "HANG_AT_BLOCK=40"])
    func dies(how: String) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-hostp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, pool, x) = film()
        let h = try host(dir, defines: [how], timeout: 1)
        #expect(h.set(7, to: 0.5))
        let out = PlanCompiler.compile(p, pool: pool, inserts: Provider(h)).render(from: 0, frames: Int(p.length))
        #expect(h.died == (how.hasPrefix("CRASH") ? .crashed(signal: SIGABRT) : .hung))
        // Halved while the plugin lived, then exactly what went in, with no jump in time where it died.
        let firstPlain = (0..<out.count).first { out[$0] != x[$0] * 0.5 }!
        #expect(firstPlain > 10_000 && firstPlain < 60_000, "died at sample \(firstPlain / 2)")
        #expect(Array(out[firstPlain...]) == Array(x[firstPlain...]))
        #expect(Array(out[..<firstPlain]) == x[..<firstPlain].map { $0 * 0.5 })
    }
}

/// The whole way: scanned, listed, put on a track by a step, changed, rendered, saved.
@Suite("VST 3 and CLAP plugins on tracks", .serialized)
struct HostedPluginTests {
    static let probe = Bundle(for: HostProcessTests.Anchor.self).bundleURL.deletingLastPathComponent().appending(path: "jammer-plugin-probe")
    let id = "clap:com.brattoo.test.fx"

    /// A folder of test plugins, scanned and installed as the app does at launch.
    func install(_ dir: URL, defines: [String] = []) throws -> PluginCatalogue {
        let clap = dir.appending(path: "CLAP")
        try FileManager.default.createDirectory(at: clap, withIntermediateDirectories: true)
        _ = try TestEffect.build("Fx", defines: defines, in: clap)
        var c = PluginCatalogue()
        c.scan(with: PluginScanner(probe: Self.probe), folders: [.clap: [clap]])
        HostedPlugins.install(helper: HostProcessTests.helper, catalogue: c)
        return c
    }

    func state() -> (EditState, [Float]) {
        let n = 48_000 * 2
        let x = (0..<n).flatMap { i -> [Float] in let v = Float(sin(Double(i) * 0.0137) * 0.4); return [v, -v] }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let ref = SourceRef(name: "t", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(ref.id, memory: x, channels: 2)
        return (EditState(project: Project(source: ref), pool: pool, media: FileManager.default.temporaryDirectory), x)
    }

    let measure: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }

    func run(_ s: inout EditState, _ op: String, _ params: [String: JSONValue]) -> StepResult {
        StepRunner.run([Step(op: op, params: params)], on: &s, measure: measure)[0]
    }

    @Test("Identity: the three written forms, and projects from before the formats")
    func identity() throws {
        #expect(PluginID("clap:com.x.y")?.format == .clap && PluginID("clap:com.x.y")?.uid == "com.x.y" && PluginID("clap:com.x.y")?.description == "clap:com.x.y")
        #expect(PluginID("vst3:A0A1A2A3A4A5A6A7A8A9AAABACADAEAF")?.format == .vst3 && PluginID("aufx/lmtr/appl")?.format == .au && PluginID("aufx/lmtr/appl")?.description == "aufx/lmtr/appl")
        #expect(PluginID("clap:") == nil && PluginID("nonsense") == nil)
        let old = try JSONDecoder().decode(Insert.self, from: Data(#"{"id":"\#(UUID().uuidString)","plugin":"aufx/lmtr/appl","name":"AUPeakLimiter","bypass":false}"#.utf8))
        #expect(old.plugin == PluginID(type: 0x61756678, subtype: 0x6C6D7472, manufacturer: 0x6170706C))
        let new = Insert(plugin: PluginID(format: .clap, uid: "com.x.y"), name: "Y")
        #expect(try JSONDecoder().decode(Insert.self, from: JSONEncoder().encode(new)) == new)
    }

    @Test("Scanned, listed, put on a track by a step, changed, rendered, and the settings survive saving")
    func onATrack() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-hostp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try install(dir)
        let listed = try #require(PluginCatalog.effects().first { $0.id.description == id })
        #expect(listed.name == "Delay Gain" && listed.manufacturer == "Brattoo Tests" && listed.format == .clap && listed.version == "1.0")
        #expect(PluginCatalog.find(id)?.id == listed.id && PluginCatalog.find("delay gain")?.id == listed.id)
        var (s, x) = state()
        let track = s.project.tracks[0].id.uuidString
        var r = run(&s, "add_insert", ["track": .string(track), "plugin": .string(id)])
        #expect(r.status == .done && r.info["latencyMs"] == 1.33 && s.project.tracks[0].inserts.map(\.plugin.description) == [id], "\(r.error ?? "")")
        // Unchanged, the plugin's gain is 1: the export is the source, in time (64 samples of latency made up for).
        #expect(PlanCompiler.mixBlocking(s.project, pool: s.pool!).render(from: 0, frames: Int(s.project.length)) == x)
        // By parameter id, and by name; outside the range and read-only are refused before anything changes.
        r = run(&s, "set_insert", ["track": .string(track), "insert": .string("Delay Gain"), "parameter": .string("7"), "value": .number(0.5)])
        #expect(r.status == .done, "\(r.error ?? "")")
        #expect(PlanCompiler.mixBlocking(s.project, pool: s.pool!).render(from: 0, frames: Int(s.project.length)) == x.map { $0 * 0.5 })
        r = run(&s, "set_insert", ["track": .string(track), "insert": .string("Delay Gain"), "parameter": .string("Gain"), "value": .number(0.25)])
        #expect(r.status == .done)
        #expect(run(&s, "set_insert", ["track": .string(track), "insert": .string("Delay Gain"), "parameter": .string("7"), "value": .number(3)]).reason == "out_of_range")
        #expect(run(&s, "set_insert", ["track": .string(track), "insert": .string("Delay Gain"), "parameter": .string("9"), "value": .number(0.5)]).reason == "out_of_range")
        #expect(run(&s, "set_insert", ["track": .string(track), "insert": .string("Delay Gain"), "parameter": .string("nope"), "value": .number(0.5)]).reason == "not_found")
        // Saved and opened again: the same sound, from the state in the document.
        let saved = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(s.project))
        #expect(saved.tracks[0].inserts[0].state?.count == 8)
        #expect(PlanCompiler.mixBlocking(saved, pool: s.pool!).render(from: 0, frames: Int(saved.length)) == x.map { $0 * 0.25 })
        // Bypassed and removed.
        #expect(run(&s, "set_insert", ["track": .string(track), "insert": .string("Delay Gain"), "bypass": .bool(true)]).status == .done)
        #expect(PlanCompiler.mixBlocking(s.project, pool: s.pool!).render(from: 0, frames: 1_000) == Array(x[0..<2_000]))
        #expect(run(&s, "remove_insert", ["track": .string(track), "insert": .string("Delay Gain")]).status == .done && s.project.tracks[0].inserts.isEmpty)
        #expect(run(&s, "add_insert", ["track": .string(track), "plugin": .string("clap:not.installed")]).reason == "plugin_not_found")
        // Nothing is left running when the plans are gone.
        usleep(400_000)
        #expect(HostedPlugins.runningCount == 0)
    }

    @Test("A plugin that can't save its own state keeps its settings anyway: Jämmer stores the parameter values in the document")
    func withoutState() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-hostp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try install(dir, defines: ["NO_STATE"])
        var (s, x) = state()
        let track = s.project.tracks[0].id.uuidString
        #expect(run(&s, "add_insert", ["track": .string(track), "plugin": .string(id)]).status == .done)
        #expect(run(&s, "set_insert", ["track": .string(track), "insert": .string("Delay Gain"), "parameter": .string("Gain"), "value": .number(0.5)]).status == .done)
        let stored = try #require(s.project.tracks[0].inserts[0].state)
        #expect(String(decoding: stored, as: UTF8.self) == "JAMMER-PARAMS-1\n{\"7\":0.5}", "only what can be set is kept, by parameter id")
        // Saved, opened again, rendered: the setting is still there.
        let saved = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(s.project))
        #expect(PlanCompiler.mixBlocking(saved, pool: s.pool!).render(from: 0, frames: Int(saved.length)) == x.map { $0 * 0.5 })
        // A second change builds on the first, and a stored value for a parameter that is gone or out of range does no harm.
        #expect(run(&s, "set_insert", ["track": .string(track), "insert": .string("Delay Gain"), "parameter": .string("7"), "value": .number(0.25)]).status == .done)
        #expect(PlanCompiler.mixBlocking(s.project, pool: s.pool!).render(from: 0, frames: 2_000) == x[0..<4_000].map { $0 * 0.25 })
        s.project.tracks[0].inserts[0].state = Data("JAMMER-PARAMS-1\n{\"7\":9,\"9\":1,\"12345\":3}".utf8)
        #expect(PlanCompiler.mixBlocking(s.project, pool: s.pool!).render(from: 0, frames: 2_000) == x[0..<4_000].map { $0 * 2 }, "clamped to the parameter's range")
    }

    @Test("The cap on helper processes is said in words; a blocked plugin is refused until it is switched on again; a death is told with the plugin's name")
    func limitsAndDeaths() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-hostp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var c = try install(dir, defines: ["CRASH_AT_BLOCK=30"])
        let plugin = try #require(PluginID(id))
        // Two at most: the third says why and what to do.
        HostedPlugins.limit = 2
        defer { HostedPlugins.limit = 64 }
        do {
            let a = try InsertUnits.makeBlocking(plugin, channels: 2, sampleRate: 48_000), b = try InsertUnits.makeBlocking(plugin, channels: 2, sampleRate: 48_000)
            #expect(HostedPlugins.runningCount == 2)
            #expect(throws: PluginError.failed("2 VST 3 and CLAP plugins are already running, which is the most Jämmer starts at once (each runs in a process of its own). Remove or bypass some to add Delay Gain.")) {
                _ = try InsertUnits.makeBlocking(plugin, channels: 2, sampleRate: 48_000)
            }
            _ = (a, b)
        }
        #expect(HostedPlugins.runningCount == 0)
        #expect(throws: PluginError.unsupportedFormat("Delay Gain: The plugin doesn't take mono audio.")) { _ = try InsertUnits.makeBlocking(plugin, channels: 1, sampleRate: 48_000) }
        #expect(HostedPlugins.runningCount == 0, "a plugin that didn't start doesn't count")
        // It crashes in its 30th block of an export: the callback names it, the export finishes with the rest unprocessed.
        final class Told: @unchecked Sendable { var said: [String] = [] }
        let told = Told()
        HostedPlugins.onDeath = { p, name, death in told.said.append("\(p) \(name) \(death.description)") }
        defer { HostedPlugins.onDeath = nil }
        var (s, x) = state()
        #expect(run(&s, "add_insert", ["track": .string(s.project.tracks[0].id.uuidString), "plugin": .string(id)]).status == .done)
        let out = PlanCompiler.mixBlocking(s.project, pool: s.pool!).render(from: 0, frames: Int(s.project.length))
        #expect(told.said == ["clap:com.brattoo.test.fx Delay Gain crashed"] && out == x, "\(told.said)")
        // Blocked (as the app does after such a death): not listed, refused with what to do, and back when unblocked.
        c.blocked.insert(id)
        HostedPlugins.update(c)
        #expect(PluginCatalog.find(id) == nil)
        #expect(throws: PluginError.failed("clap:com.brattoo.test.fx is switched off because it failed while it was in use. Switch it on again in Audio › Plugins….")) {
            _ = try InsertUnits.makeBlocking(plugin, channels: 2, sampleRate: 48_000)
        }
        c.blocked.removeAll()
        HostedPlugins.update(c)
        #expect(PluginCatalog.find(id) != nil)
    }
}

/// How long a block takes through the pipe (JAMMER_PLUGIN_BENCH=1; numbers are printed, not asserted).
@Suite("Plugin host timing", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_PLUGIN_BENCH"] != nil), .serialized)
struct HostTiming {
    func stats(_ times: [Double]) -> String {
        let t = times.sorted()
        return String(format: "mean %.3f ms, median %.3f, p99 %.3f, max %.3f", t.reduce(0, +) / Double(t.count) * 1000, t[t.count / 2] * 1000, t[Int(Double(t.count) * 0.99)] * 1000, t.last! * 1000)
    }

    /// One 512-frame block through `plugins` in series (a chain on one track), `blocks` times.
    func chain(_ plugins: [PluginHostProcess], blocks: Int, pace: Double? = nil) -> [Double] {
        let n = 512
        let a = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }, b = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
        defer { (a + b).forEach { $0.deallocate() } }
        for c in 0..<2 { for i in 0..<n { a[c][i] = Float(i) / 1024; b[c][i] = 0 } }
        let ins = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2), outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        defer { ins.deallocate(); outs.deallocate() }
        var times: [Double] = []
        let start = Date()
        for k in 0..<blocks {
            if let pace {
                let due = start.addingTimeInterval(Double(k) * pace)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
            }
            let t0 = DispatchTime.now().uptimeNanoseconds
            var flip = false
            for p in plugins {
                for c in 0..<2 { ins[c] = UnsafePointer(flip ? b[c] : a[c]); outs[c] = flip ? a[c] : b[c] }
                p.process(ins, outs, frames: n)
                flip.toggle()
            }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
        }
        return times
    }

    @Test("Round trip per block", arguments: [48_000.0, 96_000.0])
    func timing(rate: Double) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-hostp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try TestEffect.build("Fx", in: dir)
        func make(_ n: Int) throws -> [PluginHostProcess] {
            try (0..<n).map { _ in try PluginHostProcess(helper: HostProcessTests.helper, format: .clap, bundle: bundle, id: "com.brattoo.test.fx", sampleRate: rate, channels: 2) }
        }
        let block = 512 / rate
        print(String(format: "BENCH %.0f Hz: a 512-frame block lasts %.2f ms", rate, block * 1000))
        for n in [1, 8, 24] {
            let t0 = Date()
            let plugins = try make(n)
            let started = Date().timeIntervalSince(t0)
            _ = chain(plugins, blocks: 200)
            // As fast as it goes (an export), then paced like playback, then paced while an export runs beside it.
            let flat = chain(plugins, blocks: 3_000)
            let paced = chain(plugins, blocks: 600, pace: block)
            let others = try make(n)
            let stop = DispatchSemaphore(value: 0)
            final class Flag: @unchecked Sendable { var done = false }
            let flag = Flag()
            Thread.detachNewThread { [self] in
                while !flag.done { _ = chain(others, blocks: 50) }
                stop.signal()
            }
            let busy = chain(plugins, blocks: 600, pace: block)
            flag.done = true
            stop.wait()
            let per = flat.reduce(0, +) / Double(flat.count) / Double(n)
            print(String(format: "BENCH %.0f Hz, %2d plugins in a chain (started in %.2f s): per plugin %.3f ms = %.1f %% of a block", rate, n, started, per * 1000, per / block * 100))
            print("BENCH   export speed:        ", stats(flat), String(format: "→ %.0f× real time", block / (flat.reduce(0, +) / Double(flat.count))))
            print("BENCH   playback pace:       ", stats(paced), String(format: "(%.1f %% of the block at p99)", paced.sorted()[Int(Double(paced.count) * 0.99)] / block * 100))
            print("BENCH   playback + an export:", stats(busy), String(format: "(%.1f %% of the block at p99; %d of %d blocks over a whole block)", busy.sorted()[Int(Double(busy.count) * 0.99)] / block * 100, busy.filter { $0 > block }.count, busy.count))
        }
    }
}
