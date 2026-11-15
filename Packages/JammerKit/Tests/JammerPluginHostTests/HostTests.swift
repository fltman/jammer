import Foundation
import Testing
import JammerPluginHost

/// A real CLAP effect, compiled for the test: a gain with a 64-sample delay (so it has
/// latency), one automatable parameter, one read-only one, and saved state.
enum TestEffect {
    static let source = """
    #include <clap/clap.h>
    #include <stdlib.h>
    #include <string.h>
    #ifndef CHANNELS
    #define CHANNELS 2
    #endif
    #define LAT 64
    typedef struct { clap_plugin_t plugin; double gain; float line[2][LAT]; int at; } fx_t;
    static const char *features[] = { CLAP_PLUGIN_FEATURE_AUDIO_EFFECT, NULL };
    static const clap_plugin_descriptor_t desc = { CLAP_VERSION_INIT, "com.brattoo.test.fx", "Delay Gain", "Brattoo Tests", "", "", "", "1.0", "", features };
    static bool fx_init(const clap_plugin_t *p) { return true; }
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
    static bool params_value(const clap_plugin_t *p, clap_id id, double *v) { fx_t *f = p->plugin_data; if (id == 7) { *v = f->gain; return true; } if (id == 9) { *v = 0.25; return true; } return false; }
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
