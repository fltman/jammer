import Foundation
import Testing
import JammerPluginHost
import JammerPlugins
import JammerCore

/// A real VST 3 effect, compiled for the test from the interface headers alone: the same gain
/// with a 64-sample delay as the CLAP one. Its gain is 0…2 in its own units (0…1 normalised),
/// so the host's unit conversion is tried. With SEPARATE its controller is a class of its own,
/// as in plugins built on Steinberg's SDK, and the processor tells the controller what gain it
/// heard in a message the host has to make for it; without, one object is both (as JUCE's are).
enum TestVST3 {
    static let processorID = "4A414D4D455200000000000000000001"
    static let source = #"""
    #include <pluginterfaces/base/funknown.h>
    #include <pluginterfaces/base/ibstream.h>
    #include <pluginterfaces/base/ipluginbase.h>
    #include <pluginterfaces/vst/ivstattributes.h>
    #include <pluginterfaces/vst/ivstaudioprocessor.h>
    #include <pluginterfaces/vst/ivstcomponent.h>
    #include <pluginterfaces/vst/ivsteditcontroller.h>
    #include <pluginterfaces/vst/ivsthostapplication.h>
    #include <pluginterfaces/vst/ivstmessage.h>
    #include <pluginterfaces/vst/ivstparameterchanges.h>
    #include <pluginterfaces/vst/vstspeaker.h>
    #include "pluginterfaces/base/funknown.cpp"
    #include "pluginterfaces/base/coreiids.cpp"
    #include "public.sdk/source/vst/vstinitiids.cpp"
    #include <cstdlib>
    #include <cstring>
    #include <unistd.h>
    using namespace Steinberg;
    using namespace Steinberg::Vst;
    #ifndef CHANNELS
    #define CHANNELS 2
    #endif
    #define LAT 64
    static int blocks = 0;
    // By-hand checks in the app build this under other names and ids (-DPLUGIN_NAME, -DID_LAST).
    #ifndef PLUGIN_NAME
    #define PLUGIN_NAME "Delay Gain"
    #endif
    #ifndef ID_LAST
    #define ID_LAST 1
    #endif
    static const TUID procID = {0x4A, 0x41, 0x4D, 0x4D, 0x45, 0x52, 0, 0, 0, 0, 0, 0, 0, 0, 0, ID_LAST};
    static const TUID ctlID = {0x4A, 0x41, 0x4D, 0x4D, 0x45, 0x52, 0, 0, 0, 0, 0, 0, 0, 0, 1, ID_LAST};
    static bool eq(const TUID a, const TUID b) { return FUnknownPrivate::iidEqual(a, b); }
    static void toWide(char16 *to, const char *from) { while ((*to++ = char16(*from++))) {} }

    struct Fx : IComponent, IAudioProcessor, IEditController, IConnectionPoint {
        bool isProcessor, isController;
        uint32 refs = 1;
        double gain = 1, norm = 0.5, heard = 0;
        float line[2][LAT] = {};
        int at = 0;
        IConnectionPoint *peer = nullptr;
        IHostApplication *host = nullptr;
        Fx(bool p, bool c) : isProcessor(p), isController(c) {}
        virtual ~Fx() {}

        tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
            *obj = nullptr;
            if (eq(iid, FUnknown::iid) || eq(iid, IPluginBase::iid)) *obj = isProcessor ? static_cast<IPluginBase *>(static_cast<IComponent *>(this)) : static_cast<IPluginBase *>(static_cast<IEditController *>(this));
            else if (isProcessor && eq(iid, IComponent::iid)) *obj = static_cast<IComponent *>(this);
            else if (isProcessor && eq(iid, IAudioProcessor::iid)) *obj = static_cast<IAudioProcessor *>(this);
            else if (isController && eq(iid, IEditController::iid)) *obj = static_cast<IEditController *>(this);
            else if (eq(iid, IConnectionPoint::iid)) *obj = static_cast<IConnectionPoint *>(this);
            if (!*obj) return kNoInterface;
            ++refs;
            return kResultOk;
        }
        uint32 PLUGIN_API addRef() override { return ++refs; }
        uint32 PLUGIN_API release() override { const uint32 r = --refs; if (!r) delete this; return r; }

        // IPluginBase
        tresult PLUGIN_API initialize(FUnknown *context) override {
    #ifdef CRASH_ON_INIT
            abort();
    #endif
            if (context) context->queryInterface(IHostApplication::iid, reinterpret_cast<void **>(&host));
            return kResultOk;
        }
        tresult PLUGIN_API terminate() override { if (host) { host->release(); host = nullptr; } return kResultOk; }

        // IComponent
        tresult PLUGIN_API getControllerClassId(TUID id) override {
    #ifdef SEPARATE
            std::memcpy(id, ctlID, sizeof(TUID));
            return kResultOk;
    #else
            return kNotImplemented;
    #endif
        }
        tresult PLUGIN_API setIoMode(IoMode) override { return kNotImplemented; }
        int32 PLUGIN_API getBusCount(MediaType type, BusDirection dir) override {
            if (type != kAudio) return 0;
    #ifdef NO_INPUT
            if (dir == kInput) return 0;
    #endif
    #ifdef SIDECHAIN
            if (dir == kInput) return 2;
    #endif
            return 1;
        }
        tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo &bus) override {
            if (type != kAudio || index < 0 || index >= getBusCount(type, dir)) return kInvalidArgument;
            bus.mediaType = kAudio;
            bus.direction = dir;
            bus.channelCount = index == 0 ? CHANNELS : 2;
            toWide(bus.name, index == 0 ? "Main" : "Side-chain");
            bus.busType = index == 0 ? kMain : kAux;
            bus.flags = index == 0 ? BusInfo::kDefaultActive : 0;
            return kResultOk;
        }
        tresult PLUGIN_API getRoutingInfo(RoutingInfo &, RoutingInfo &) override { return kNotImplemented; }
        tresult PLUGIN_API activateBus(MediaType, BusDirection, int32, TBool) override { return kResultOk; }
        tresult PLUGIN_API setActive(TBool state) override {
    #ifdef FAIL_ACTIVATE
            if (state) return kResultFalse;
    #endif
            if (state) { std::memset(line, 0, sizeof line); at = 0; }
            return kResultOk;
        }
        // The processor's state is its gain, eight bytes and not one more; the controller's is one byte.
        tresult PLUGIN_API setState(IBStream *s) override {
            int32 got = 0;
            if (isProcessor) {
                double g = 0;
                char extra = 0;
                if (s->read(&g, 8, &got) != kResultOk || got != 8) return kResultFalse;
                if (s->read(&extra, 1, &got) == kResultOk && got != 0) return kResultFalse;
                gain = g;
                return kResultOk;
            }
            char tag = 0;
            return s->read(&tag, 1, &got) == kResultOk && got == 1 && tag == 'C' ? kResultOk : kResultFalse;
        }
        tresult PLUGIN_API getState(IBStream *s) override {
            if (isProcessor) return s->write(&gain, 8, nullptr);
            char tag = 'C';
            return s->write(&tag, 1, nullptr);
        }

        // IAudioProcessor
        tresult PLUGIN_API setBusArrangements(SpeakerArrangement *ins, int32 nIns, SpeakerArrangement *outs, int32 nOuts) override {
            const SpeakerArrangement mine = CHANNELS == 2 ? SpeakerArr::kStereo : SpeakerArr::kMono;
            return nIns >= 1 && nOuts >= 1 && ins[0] == mine && outs[0] == mine ? kResultTrue : kResultFalse;
        }
        tresult PLUGIN_API getBusArrangement(BusDirection dir, int32 index, SpeakerArrangement &arr) override {
            if (index < 0 || index >= getBusCount(kAudio, dir)) return kInvalidArgument;
            arr = index == 0 ? (CHANNELS == 2 ? SpeakerArr::kStereo : SpeakerArr::kMono) : SpeakerArr::kStereo;
            return kResultOk;
        }
        tresult PLUGIN_API canProcessSampleSize(int32 size) override { return size == kSample32 ? kResultTrue : kResultFalse; }
        uint32 PLUGIN_API getLatencySamples() override { return LAT; }
        tresult PLUGIN_API setupProcessing(ProcessSetup &) override { return kResultOk; }
        tresult PLUGIN_API setProcessing(TBool) override { return kNotImplemented; }
        uint32 PLUGIN_API getTailSamples() override { return 0; }
        tresult PLUGIN_API process(ProcessData &data) override {
            if (data.inputParameterChanges) {
                const int32 n = data.inputParameterChanges->getParameterCount();
                for (int32 i = 0; i < n; ++i) {
                    IParamValueQueue *q = data.inputParameterChanges->getParameterData(i);
                    int32 offset = 0;
                    ParamValue v = 0;
                    if (!q || q->getParameterId() != 7 || q->getPointCount() < 1 || q->getPoint(q->getPointCount() - 1, offset, v) != kResultOk) continue;
                    gain = v * 2;
                    // Tell the other half, in a message only the host can make.
                    IMessage *m = nullptr;
                    TUID mid;
                    std::memcpy(mid, IMessage::iid, sizeof(TUID));
                    if (peer && host && host->createInstance(mid, mid, reinterpret_cast<void **>(&m)) == kResultOk && m) {
                        m->setMessageID("gain");
                        m->getAttributes()->setFloat("value", gain);
                        m->getAttributes()->setInt("blocks", blocks);
                        peer->notify(m);
                        m->release();
                    }
                }
            }
            if (data.numSamples <= 0) return kResultOk;
    #ifdef PROCESS_ERROR
            return kResultFalse;
    #endif
            ++blocks;
    #ifdef CRASH_AT_BLOCK
            if (blocks == CRASH_AT_BLOCK) abort();
    #endif
    #ifdef HANG_AT_BLOCK
            if (blocks == HANG_AT_BLOCK) for (;;) pause();
    #endif
            float side = 0;
    #ifdef SIDECHAIN
            // The side-chain the host didn't connect must still be there to read, and silent.
            if (data.numInputs != 2 || data.inputs[1].numChannels != 2) return kResultFalse;
            side = data.inputs[1].channelBuffers32[0][0] + data.inputs[1].channelBuffers32[1][data.numSamples - 1];
    #endif
            for (int32 i = 0; i < data.numSamples; ++i) {
                for (int c = 0; c < CHANNELS; ++c) {
                    const float x = data.inputs[0].channelBuffers32[c][i];
                    data.outputs[0].channelBuffers32[c][i] = float(line[c][at] * gain) + side;
                    line[c][at] = x;
                }
                at = (at + 1) % LAT;
            }
            return kResultOk;
        }

        // IEditController
        tresult PLUGIN_API setComponentState(IBStream *s) override {
            double g = 0;
            int32 got = 0;
            if (s->read(&g, 8, &got) != kResultOk || got != 8) return kResultFalse;
            norm = g / 2;
            return kResultOk;
        }
        int32 PLUGIN_API getParameterCount() override { return 2; }
        tresult PLUGIN_API getParameterInfo(int32 index, ParameterInfo &info) override {
            if (index < 0 || index > 1) return kInvalidArgument;
            std::memset(&info, 0, sizeof info);
            if (index == 0) { info.id = 7; toWide(info.title, "Gain"); toWide(info.units, "x"); info.defaultNormalizedValue = 0.5; info.flags = ParameterInfo::kCanAutomate; }
            else { info.id = 9; toWide(info.title, "Heard"); info.flags = ParameterInfo::kIsReadOnly; }
            return kResultOk;
        }
        tresult PLUGIN_API getParamStringByValue(ParamID, ParamValue, String128) override { return kNotImplemented; }
        tresult PLUGIN_API getParamValueByString(ParamID, TChar *, ParamValue &) override { return kNotImplemented; }
        ParamValue PLUGIN_API normalizedParamToPlain(ParamID id, ParamValue v) override { return id == 7 ? v * 2 : v; }
        ParamValue PLUGIN_API plainParamToNormalized(ParamID id, ParamValue v) override { return id == 7 ? v / 2 : v; }
        ParamValue PLUGIN_API getParamNormalized(ParamID id) override { return id == 7 ? norm : id == 9 ? heard / 2 : 0; }
        tresult PLUGIN_API setParamNormalized(ParamID id, ParamValue v) override { if (id != 7) return kResultFalse; norm = v; return kResultOk; }
        tresult PLUGIN_API setComponentHandler(IComponentHandler *) override { return kResultOk; }
        IPlugView *PLUGIN_API createView(FIDString) override { return nullptr; }

        // IConnectionPoint
        tresult PLUGIN_API connect(IConnectionPoint *other) override { peer = other; return kResultOk; }
        tresult PLUGIN_API disconnect(IConnectionPoint *) override { peer = nullptr; return kResultOk; }
        tresult PLUGIN_API notify(IMessage *m) override {
            double v = 0;
            int64 n = -1;
            if (m && m->getMessageID() && !std::strcmp(m->getMessageID(), "gain") && m->getAttributes()->getFloat("value", v) == kResultOk
                && m->getAttributes()->getInt("blocks", n) == kResultOk && n >= 0) heard = v;
            return kResultOk;
        }
    };

    struct Factory : IPluginFactory {
        tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
            if (eq(iid, FUnknown::iid) || eq(iid, IPluginFactory::iid)) { *obj = this; return kResultOk; }
            *obj = nullptr;
            return kNoInterface;
        }
        uint32 PLUGIN_API addRef() override { return 1; }
        uint32 PLUGIN_API release() override { return 1; }
        tresult PLUGIN_API getFactoryInfo(PFactoryInfo *info) override {
            std::memset(info, 0, sizeof *info);
            std::strcpy(info->vendor, "Brattoo Tests");
            return kResultOk;
        }
        int32 PLUGIN_API countClasses() override {
    #ifdef SEPARATE
            return 2;
    #else
            return 1;
    #endif
        }
        tresult PLUGIN_API getClassInfo(int32 index, PClassInfo *info) override {
            if (index < 0 || index >= countClasses()) return kInvalidArgument;
            std::memset(info, 0, sizeof *info);
            std::memcpy(info->cid, index == 0 ? procID : ctlID, sizeof(TUID));
            info->cardinality = PClassInfo::kManyInstances;
            std::strcpy(info->category, index == 0 ? "Audio Module Class" : "Component Controller Class");
            std::strcpy(info->name, index == 0 ? PLUGIN_NAME : PLUGIN_NAME " Controller");
            return kResultOk;
        }
        tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void **obj) override {
            *obj = nullptr;
            Fx *fx = nullptr;
    #ifdef SEPARATE
            if (eq(cid, procID)) fx = new Fx(true, false);
            else if (eq(cid, ctlID)) fx = new Fx(false, true);
    #else
            if (eq(cid, procID)) fx = new Fx(true, true);
    #endif
            if (!fx) return kNoInterface;
            const tresult r = fx->queryInterface(iid, obj);
            fx->release();
            return r;
        }
    };

    extern "C" {
    __attribute__((visibility("default"))) bool bundleEntry(void *) { return true; }
    __attribute__((visibility("default"))) bool bundleExit() { return true; }
    __attribute__((visibility("default"))) IPluginFactory *GetPluginFactory() { static Factory factory; return &factory; }
    }
    """#

    static func build(_ name: String, defines: [String] = [], in dir: URL) throws -> URL {
        let bundle = dir.appending(path: "\(name).vst3"), macos = bundle.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try "<plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>\(name)</string></dict></plist>"
            .write(to: bundle.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
        let cpp = dir.appending(path: "\(name).cpp")
        try source.write(to: cpp, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["clang++", "-std=c++17", "-w", "-bundle", "-arch", "arm64", "-I", TestEffect.package.appending(path: "Vendor/vst3sdk").path]
            + defines.map { "-D\($0)" } + ["-framework", "CoreFoundation", "-o", macos.appending(path: name).path, cpp.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        let said = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "TestVST3", code: 1, userInfo: [NSLocalizedDescriptionKey: String(decoding: said, as: UTF8.self)])
        }
        return bundle
    }

    static var sdkPresent: Bool { FileManager.default.fileExists(atPath: TestEffect.package.appending(path: "Vendor/vst3sdk/pluginterfaces/vst/ivstaudioprocessor.h").path) }
}

@Suite("Hosting a VST 3 effect", .enabled(if: TestVST3.sdkPresent))
struct VST3HostTests {
    let clap = HostTests()

    func open(_ bundle: URL, id: String = TestVST3.processorID, channels: Int32 = 2, max: Int32 = 512) -> (OpaquePointer?, String) {
        var error = [CChar](repeating: 0, count: 256)
        let p = jph_vst3_open(bundle.path, id, 48_000, channels, max, &error, 256)
        return (p, String(cString: error))
    }

    func text<T>(_ field: T) -> String { withUnsafeBytes(of: field) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } }

    let ramp = (0..<2_000).map { Float($0 + 1) / 4_000 }

    @Test("Loads, reports latency and parameters in the plugin's own units, processes in any block size, takes changes, saves and restores state",
          arguments: [[], ["SEPARATE"]])
    func effect(defines: [String]) throws {
        let dir = try clap.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let separate = !defines.isEmpty
        let bundle = try TestVST3.build("Fx", defines: defines, in: dir)
        let (opened, why) = open(bundle)
        let p = try #require(opened, "\(why)")
        defer { jph_close(p) }
        #expect(jph_latency(p) == 64 && jph_param_count(p) == 2)
        var info = jph_param()
        // 0…2 in its own units, though the plugin is asked in 0…1.
        #expect(jph_param_info(p, 0, &info) && info.id == 7 && info.min == 0 && info.max == 2 && info.value == 1 && info.initial == 1 && !info.readonly)
        #expect(text(info.name) == "Gain" && text(info.module) == "")
        #expect(jph_param_info(p, 1, &info) && info.id == 9 && info.readonly && info.value == 0 && !jph_param_info(p, 2, &info))
        for block in [512, 100, 1, 333] {
            jph_reset(p)
            let (out, ok) = clap.run(p, ramp, block: block)
            #expect(ok && out[0][0..<64].allSatisfy { $0 == 0 }, "block \(block)")
            #expect((64..<2_000).allSatisfy { out[0][$0] == ramp[$0 - 64] && out[1][$0] == -ramp[$0 - 64] }, "block \(block)")
        }
        #expect(jph_param_set(p, 7, 0.5) && !jph_param_set(p, 9, 1) && !jph_param_set(p, 99, 1))
        var v = 0.0
        #expect(jph_param_get(p, 7, &v) && v == 0.5)
        jph_reset(p)
        #expect(clap.run(p, ramp).out[0][100] == ramp[36] * 0.5)
        // With two halves, the processor told the controller what it heard, in a message the host made.
        #expect(jph_param_get(p, 9, &v) && v == (separate ? 0.25 : 0))
        #expect(jph_param_set(p, 7, 5) && jph_param_get(p, 7, &v) && v == 2)
        // State saved before any block has carried the new value to the processor still has it.
        #expect(jph_param_set(p, 7, 0.25))
        var data: UnsafeMutablePointer<UInt8>?, size = 0
        #expect(jph_state_save(p, &data, &size) && size == 12 + 8 + (separate ? 1 : 0))
        defer { jph_free(data) }
        let (second, _) = open(bundle)
        let q = try #require(second)
        defer { jph_close(q) }
        #expect(jph_param_get(q, 7, &v) && v == 1)
        #expect(jph_state_load(q, data!, size) && jph_param_get(q, 7, &v) && v == 0.25)
        #expect(clap.run(q, ramp).out[0][100] == ramp[36] * 0.25)
        // State that isn't ours, or is cut short, is refused and changes nothing.
        #expect(!jph_state_load(q, data!, 11) && !jph_state_load(q, [UInt8](repeating: 7, count: 40), 40))
        #expect(jph_param_get(q, 7, &v) && v == 0.25)
        _ = clap.run(q, ramp)
        jph_reset(q)
        #expect(clap.run(q, [Float](repeating: 0, count: 256)).out[0].allSatisfy { $0 == 0 })
        let (big, ok) = clap.run(q, ramp, block: 600)
        #expect(!ok && big[0][0..<600] == ramp[0..<600])
    }

    @Test("What can't be hosted says why; a side-chain is given silence; a failing plugin lets the sound through")
    func refusals() throws {
        let dir = try clap.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stereo = try TestVST3.build("Fx", in: dir)
        #expect(open(stereo, id: "4A414D4D455200000000000000000009").1 == "The bundle has no plugin with that id.")
        #expect(open(stereo, id: "com.brattoo.test.fx").1 == "That isn't a VST 3 class id.")
        #expect(open(stereo, channels: 1).1 == "The plugin doesn't take mono audio.")
        #expect(open(dir.appending(path: "Nothing.vst3")).1 == "The plugin's code couldn't be loaded.")
        // A CLAP bundle isn't a VST 3 one.
        #expect(open(try TestEffect.build("Clap", in: dir)).1 == "It isn't a VST 3 plugin.")
        let mono = try TestVST3.build("Mono", defines: ["CHANNELS=1"], in: dir)
        #expect(open(mono).1 == "The plugin doesn't take stereo audio.")
        let (m, _) = open(mono, channels: 1)
        let mp = try #require(m)
        defer { jph_close(mp) }
        let short = (0..<300).map { Float($0 + 1) / 600 }
        #expect(clap.run(mp, short, channels: 1).out[0][200] == short[136])
        #expect(open(try TestVST3.build("Synth", defines: ["NO_INPUT"], in: dir)).1 == "The plugin takes no audio in (it's an instrument, not an effect).")
        #expect(open(try TestVST3.build("NoStart", defines: ["FAIL_ACTIVATE"], in: dir)).1 == "The plugin couldn't be activated at this sample rate.")
        let (s, why) = open(try TestVST3.build("Side", defines: ["SIDECHAIN"], in: dir))
        let sp = try #require(s, "\(why)")
        defer { jph_close(sp) }
        let (side, sideOK) = clap.run(sp, short, block: 100)
        #expect(sideOK && side[0][200] == short[136] && side[1][200] == -short[136])
        let (e, _) = open(try TestVST3.build("Errs", defines: ["PROCESS_ERROR"], in: dir))
        let ep = try #require(e)
        defer { jph_close(ep) }
        let (out, ok) = clap.run(ep, short)
        #expect(!ok && out[0] == short && out[1] == short.map { -$0 })
    }
}

@Suite("A VST 3 plugin in its own process", .enabled(if: TestVST3.sdkPresent))
struct VST3ProcessTests {
    let helper = HostProcessTests()

    func start(_ bundle: URL, timeout: Double = 20) throws -> PluginHostProcess {
        try PluginHostProcess(helper: HostProcessTests.helper, format: .vst3, bundle: bundle, id: TestVST3.processorID, sampleRate: 48_000, channels: 2, timeout: timeout)
    }

    @Test("The scanner's id opens it; through the helper the sound, parameters and state are the same", arguments: [[], ["SEPARATE"]])
    func hosted(defines: [String]) throws {
        let dir = try helper.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try TestVST3.build("Fx", defines: defines, in: dir)
        // What the scanner reads out of the bundle is what the host is given.
        let probe = HostProcessTests.helper.deletingLastPathComponent().appending(path: "jammer-plugin-probe")
        guard case .found(let found) = PluginScanner(probe: probe, readable: [dir]).probe(bundle, format: .vst3) else { Issue.record("the scanner couldn't read it"); return }
        #expect(found.map(\.id) == [TestVST3.processorID] && found.first?.name == "Delay Gain")
        let p = try PluginHostProcess(helper: HostProcessTests.helper, format: .vst3, bundle: bundle, id: found[0].id, sampleRate: 48_000, channels: 2, readable: [dir])
        #expect(p.latency == 64 && p.parameters.map(\.id) == [7, 9] && p.parameters[0].max == 2 && p.parameters[0].module == "")
        let ramp = helper.ramp
        let (out, processed) = helper.run(p, ramp, block: 300)
        #expect(processed.allSatisfy { $0 } && (64..<ramp.count).allSatisfy { out[0][$0] == ramp[$0 - 64] && out[1][$0] == -ramp[$0 - 64] })
        #expect(p.set(7, to: 0.5))
        p.reset()
        #expect(helper.run(p, ramp).out[0][100] == ramp[36] * 0.5)
        let state = try #require(p.saveState())
        let q = try PluginHostProcess(helper: HostProcessTests.helper, format: .vst3, bundle: bundle, id: found[0].id, sampleRate: 48_000, channels: 2, readable: [dir])
        #expect(q.loadState(state))
        q.refresh()
        #expect(q.parameters[0].value == 0.5 && helper.run(q, ramp).out[0][100] == ramp[36] * 0.5)
    }

    @Test("A VST 3 plugin that crashes or hangs takes its helper with it, not the sound", arguments: ["CRASH_AT_BLOCK=3", "HANG_AT_BLOCK=3", "CRASH_ON_INIT"])
    func dies(how: String) throws {
        let dir = try helper.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try TestVST3.build("Bad", defines: [how], in: dir)
        if how == "CRASH_ON_INIT" {
            #expect(throws: PluginHostProcess.StartError.self) {
                _ = try PluginHostProcess(helper: HostProcessTests.helper, format: .vst3, bundle: bundle, id: TestVST3.processorID, sampleRate: 48_000, channels: 2, readable: [dir])
            }
            return
        }
        let p = try PluginHostProcess(helper: HostProcessTests.helper, format: .vst3, bundle: bundle, id: TestVST3.processorID, sampleRate: 48_000, channels: 2,
                                      readable: [dir], timeout: 1)
        let ramp = helper.ramp
        let (out, processed) = helper.run(p, ramp, block: 512)
        #expect(processed.prefix(2) == [true, true] && processed.dropFirst(2).allSatisfy { !$0 })
        #expect(p.died == (how.hasPrefix("CRASH") ? .crashed(signal: SIGABRT) : .hung))
        // From the block it died in, what went in comes out.
        #expect(Array(out[0][1_024...]) == Array(ramp[1_024...]))
    }
}
