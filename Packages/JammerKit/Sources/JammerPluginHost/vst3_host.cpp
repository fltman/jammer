// The VST 3 side of the plugin host. Written against the interface headers of the SDK
// (pluginterfaces, MIT) and nothing else of it: the host's own objects (streams, parameter
// queues, messages) are the small ones below. Everything runs on the one thread that drives
// the plugin, in a helper process.

#include "host_internal.hpp"

#if __has_include(<pluginterfaces/vst/ivstaudioprocessor.h>)

#include <CoreFoundation/CoreFoundation.h>
#include <pluginterfaces/base/funknown.h>
#include <pluginterfaces/base/ibstream.h>
#include <pluginterfaces/base/ipluginbase.h>
#include <pluginterfaces/vst/ivstattributes.h>
#include <pluginterfaces/vst/ivstaudioprocessor.h>
#include <pluginterfaces/vst/ivstcomponent.h>
#include <pluginterfaces/vst/ivsteditcontroller.h>
#include <pluginterfaces/vst/ivstevents.h>
#include <pluginterfaces/vst/ivsthostapplication.h>
#include <pluginterfaces/vst/ivstmessage.h>
#include <pluginterfaces/vst/ivstparameterchanges.h>
#include <pluginterfaces/vst/ivstprocesscontext.h>
#include <pluginterfaces/vst/vstspeaker.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

// The interface ids are defined by these three files of the SDK.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include "pluginterfaces/base/funknown.cpp"
#include "pluginterfaces/base/coreiids.cpp"
#include "public.sdk/source/vst/vstinitiids.cpp"
#pragma clang diagnostic pop

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

bool same(const TUID a, const TUID b) { return FUnknownPrivate::iidEqual(a, b); }

/// queryInterface for the host's own objects, which answer for one interface and FUnknown.
template <class Interface, class Self> tresult answer(Self *self, const TUID iid, void **obj) {
    if (same(iid, Interface::iid) || same(iid, FUnknown::iid)) {
        *obj = static_cast<Interface *>(self);
        self->addRef();
        return kResultOk;
    }
    *obj = nullptr;
    return kNoInterface;
}

/// Objects the host owns for as long as the plugin lives: counting references would only
/// let a plugin's miscount free them.
#define JPH_OWNED \
    uint32 PLUGIN_API addRef() override { return 1; } \
    uint32 PLUGIN_API release() override { return 1; }

/// Objects made for the plugin, which keeps them as long as it holds a reference.
#define JPH_COUNTED \
    uint32 refs = 1; \
    uint32 PLUGIN_API addRef() override { return ++refs; } \
    uint32 PLUGIN_API release() override { const uint32 r = --refs; if (r == 0) delete this; return r; }

std::string utf8(const char16 *s, size_t max) {
    std::string out;
    for (size_t i = 0; i < max && s[i]; ++i) {
        uint32_t c = uint16_t(s[i]);
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < max && uint16_t(s[i + 1]) >= 0xDC00 && uint16_t(s[i + 1]) < 0xE000) {
            c = 0x10000 + ((c - 0xD800) << 10) + (uint16_t(s[++i]) - 0xDC00);
        }
        if (c < 0x80) out += char(c);
        else if (c < 0x800) { out += char(0xC0 | (c >> 6)); out += char(0x80 | (c & 0x3F)); }
        else if (c < 0x10000) { out += char(0xE0 | (c >> 12)); out += char(0x80 | ((c >> 6) & 0x3F)); out += char(0x80 | (c & 0x3F)); }
        else { out += char(0xF0 | (c >> 18)); out += char(0x80 | ((c >> 12) & 0x3F)); out += char(0x80 | ((c >> 6) & 0x3F)); out += char(0x80 | (c & 0x3F)); }
    }
    return out;
}

// MARK: A stream in memory

struct Stream final : IBStream {
    std::vector<uint8_t> bytes;
    size_t at = 0;
    Stream() = default;
    Stream(const uint8_t *data, size_t size) : bytes(data, data + size) {}
    JPH_OWNED
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override { return answer<IBStream>(this, iid, obj); }
    tresult PLUGIN_API read(void *buffer, int32 n, int32 *got) override {
        const size_t take = n <= 0 ? 0 : std::min<size_t>(size_t(n), bytes.size() - at);
        if (take) std::memcpy(buffer, bytes.data() + at, take);
        at += take;
        if (got) *got = int32(take);
        return kResultOk;
    }
    tresult PLUGIN_API write(void *buffer, int32 n, int32 *put) override {
        if (n < 0 || bytes.size() + size_t(n) > (64u << 20)) { if (put) *put = 0; return kResultFalse; }
        if (at + size_t(n) > bytes.size()) bytes.resize(at + size_t(n));
        if (n) std::memcpy(bytes.data() + at, buffer, size_t(n));
        at += size_t(n);
        if (put) *put = n;
        return kResultOk;
    }
    tresult PLUGIN_API seek(int64 pos, int32 mode, int64 *result) override {
        int64 to = mode == kIBSeekSet ? pos : mode == kIBSeekCur ? int64(at) + pos : int64(bytes.size()) + pos;
        to = std::clamp<int64>(to, 0, int64(bytes.size()));
        at = size_t(to);
        if (result) *result = to;
        return kResultOk;
    }
    tresult PLUGIN_API tell(int64 *pos) override { if (pos) *pos = int64(at); return kResultOk; }
};

// MARK: Parameter changes into a block

struct Queue final : IParamValueQueue {
    ParamID id = 0;
    std::vector<std::pair<int32, ParamValue>> points;
    JPH_OWNED
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override { return answer<IParamValueQueue>(this, iid, obj); }
    ParamID PLUGIN_API getParameterId() override { return id; }
    int32 PLUGIN_API getPointCount() override { return int32(points.size()); }
    tresult PLUGIN_API getPoint(int32 index, int32 &offset, ParamValue &value) override {
        if (index < 0 || size_t(index) >= points.size()) return kResultFalse;
        offset = points[size_t(index)].first;
        value = points[size_t(index)].second;
        return kResultOk;
    }
    tresult PLUGIN_API addPoint(int32 offset, ParamValue value, int32 &index) override {
        index = int32(points.size());
        points.emplace_back(offset, value);
        return kResultOk;
    }
};

struct Changes final : IParameterChanges {
    std::vector<std::unique_ptr<Queue>> queues;
    int32 used = 0;
    JPH_OWNED
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override { return answer<IParameterChanges>(this, iid, obj); }
    int32 PLUGIN_API getParameterCount() override { return used; }
    IParamValueQueue *PLUGIN_API getParameterData(int32 index) override { return index >= 0 && index < used ? queues[size_t(index)].get() : nullptr; }
    IParamValueQueue *PLUGIN_API addParameterData(const ParamID &id, int32 &index) override {
        for (int32 i = 0; i < used; ++i) if (queues[size_t(i)]->id == id) { index = i; return queues[size_t(i)].get(); }
        if (size_t(used) == queues.size()) queues.push_back(std::make_unique<Queue>());
        Queue *q = queues[size_t(used)].get();
        q->id = id;
        q->points.clear();
        index = used++;
        return q;
    }
    void clear() { used = 0; }
    void set(ParamID id, ParamValue value) {
        int32 index = 0, point = 0;
        auto *q = static_cast<Queue *>(addParameterData(id, index));
        q->points.clear(); // the last value wins; everything lands at the start of the block
        q->addPoint(0, value, point);
    }
};

/// An effect gets no notes; plugins may still expect a list to ask.
struct NoEvents final : IEventList {
    JPH_OWNED
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override { return answer<IEventList>(this, iid, obj); }
    int32 PLUGIN_API getEventCount() override { return 0; }
    tresult PLUGIN_API getEvent(int32, Event &) override { return kResultFalse; }
    tresult PLUGIN_API addEvent(Event &) override { return kResultOk; }
};

// MARK: Messages between a plugin's two halves

struct Attributes final : IAttributeList {
    struct Value { int64 i = 0; double f = 0; std::u16string s; std::vector<uint8_t> b; };
    std::map<std::string, Value> values;
    JPH_COUNTED
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override { return answer<IAttributeList>(this, iid, obj); }
    tresult PLUGIN_API setInt(AttrID id, int64 value) override { if (!id) return kInvalidArgument; values[id].i = value; return kResultOk; }
    tresult PLUGIN_API getInt(AttrID id, int64 &value) override {
        auto it = id ? values.find(id) : values.end();
        if (it == values.end()) return kResultFalse;
        value = it->second.i;
        return kResultOk;
    }
    tresult PLUGIN_API setFloat(AttrID id, double value) override { if (!id) return kInvalidArgument; values[id].f = value; return kResultOk; }
    tresult PLUGIN_API getFloat(AttrID id, double &value) override {
        auto it = id ? values.find(id) : values.end();
        if (it == values.end()) return kResultFalse;
        value = it->second.f;
        return kResultOk;
    }
    tresult PLUGIN_API setString(AttrID id, const TChar *string) override {
        if (!id || !string) return kInvalidArgument;
        size_t n = 0;
        while (n < 65536 && string[n]) ++n;
        values[id].s.assign(reinterpret_cast<const char16_t *>(string), n);
        return kResultOk;
    }
    tresult PLUGIN_API getString(AttrID id, TChar *string, uint32 sizeInBytes) override {
        auto it = id ? values.find(id) : values.end();
        if (it == values.end() || !string || sizeInBytes < sizeof(TChar)) return kResultFalse;
        const size_t room = sizeInBytes / sizeof(TChar) - 1, n = std::min(room, it->second.s.size());
        std::memcpy(string, it->second.s.data(), n * sizeof(TChar));
        string[n] = 0;
        return kResultOk;
    }
    tresult PLUGIN_API setBinary(AttrID id, const void *data, uint32 size) override {
        if (!id || (!data && size) || size > (16u << 20)) return kInvalidArgument;
        const auto *b = static_cast<const uint8_t *>(data);
        values[id].b.assign(b, b + size);
        return kResultOk;
    }
    tresult PLUGIN_API getBinary(AttrID id, const void *&data, uint32 &size) override {
        auto it = id ? values.find(id) : values.end();
        if (it == values.end()) return kResultFalse;
        data = it->second.b.data();
        size = uint32(it->second.b.size());
        return kResultOk;
    }
};

struct Message final : IMessage {
    std::string id;
    Attributes *attributes = new Attributes;
    virtual ~Message() { attributes->release(); }
    JPH_COUNTED
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override { return answer<IMessage>(this, iid, obj); }
    FIDString PLUGIN_API getMessageID() override { return id.c_str(); }
    void PLUGIN_API setMessageID(FIDString m) override { id = m ? m : ""; }
    IAttributeList *PLUGIN_API getAttributes() override { return attributes; }
};

struct HostApp final : IHostApplication {
    JPH_OWNED
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override { return answer<IHostApplication>(this, iid, obj); }
    tresult PLUGIN_API getName(String128 name) override {
        const char16_t n[] = u"Jammer";
        std::memcpy(name, n, sizeof n);
        return kResultOk;
    }
    tresult PLUGIN_API createInstance(TUID cid, TUID iid, void **obj) override {
        if (!obj) return kInvalidArgument;
        if (same(cid, IMessage::iid) && same(iid, IMessage::iid)) { *obj = static_cast<IMessage *>(new Message); return kResultOk; }
        if (same(cid, IAttributeList::iid) && same(iid, IAttributeList::iid)) { *obj = static_cast<IAttributeList *>(new Attributes); return kResultOk; }
        *obj = nullptr;
        return kResultFalse;
    }
};

struct Vst3Plugin;

/// What the plugin's controller tells its host. There is no editor window here, so edits
/// don't start from the plugin; what matters is a request to restart.
struct Handler final : IComponentHandler {
    Vst3Plugin *owner = nullptr;
    JPH_OWNED
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override { return answer<IComponentHandler>(this, iid, obj); }
    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue value) override;
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32 flags) override;
};

struct Bus {
    int32 channels = 0;
    std::vector<float> samples;
    std::vector<float *> pointers;
};

struct Vst3Plugin final : jph_plugin {
    CFBundleRef bundle = nullptr;
    bool entered = false;
    IPluginFactory *factory = nullptr;
    IComponent *component = nullptr;
    IAudioProcessor *processor = nullptr;
    IEditController *controller = nullptr;
    IConnectionPoint *componentPoint = nullptr, *controllerPoint = nullptr;
    bool separate = false, componentUp = false, controllerUp = false, active = false, processing = false, wantsRestart = false;
    HostApp app;
    Handler handler;
    Changes changes, outChanges;
    NoEvents inEvents, outEvents;
    int32_t channels = 2, maxFrames = 512;
    double sampleRate = 48000;
    int64_t steady = 0;
    /// The buses beside the main ones (side-chains, extra outputs): silent in, ignored out.
    std::vector<Bus> inBuses, outBuses;
    std::vector<AudioBusBuffers> inBuffers, outBuffers;

    ~Vst3Plugin() override;
    bool start();
    void stop();
    bool setUpBuses(std::string &why);
    void run(const float *const *in, float *const *out, int32_t frames, tresult &result);
    struct Range { double low, high; bool plain; };
    Range range(ParamID id);
    bool info(ParamID id, ParameterInfo &out);

    bool process(const float *const *in, float *const *out, int32_t frames) override;
    void reset() override;
    int32_t latency() override { return processor ? int32_t(processor->getLatencySamples()) : 0; }
    int32_t paramCount() override { return controller ? std::max<int32_t>(0, controller->getParameterCount()) : 0; }
    bool paramInfo(int32_t index, jph_param *out) override;
    bool paramSet(uint32_t id, double value) override;
    bool paramGet(uint32_t id, double *value) override;
    bool stateSave(std::vector<uint8_t> &bytes) override;
    bool stateLoad(const uint8_t *data, size_t size) override;
};

tresult PLUGIN_API Handler::performEdit(ParamID id, ParamValue value) {
    // The controller changed a value by itself: the processor must hear of it too.
    if (owner) owner->changes.set(id, value);
    return kResultOk;
}

tresult PLUGIN_API Handler::restartComponent(int32 flags) {
    if (owner && (flags & (kReloadComponent | kIoChanged | kLatencyChanged))) owner->wantsRestart = true;
    return kResultOk;
}

bool Vst3Plugin::start() {
    if (!active) {
        if (component->setActive(true) != kResultOk) return false;
        active = true;
    }
    if (!processing) {
        // Plugins may answer "not implemented" here and still process.
        processor->setProcessing(true);
        processing = true;
    }
    return true;
}

void Vst3Plugin::stop() {
    if (processing) { processor->setProcessing(false); processing = false; }
    if (active) { component->setActive(false); active = false; }
}

bool Vst3Plugin::setUpBuses(std::string &why) {
    const int32 ins = component->getBusCount(kAudio, kInput), outs = component->getBusCount(kAudio, kOutput);
    if (outs < 1) { why = "The plugin has no audio output."; return false; }
    if (ins < 1) { why = "The plugin takes no audio in (it's an instrument, not an effect)."; return false; }
    if (ins > 16 || outs > 64) { why = "The plugin has more buses than Jammer hosts."; return false; }
    const SpeakerArrangement want = channels == 1 ? SpeakerArr::kMono : SpeakerArr::kStereo;
    std::vector<SpeakerArrangement> inArr(static_cast<size_t>(ins), 0), outArr(static_cast<size_t>(outs), 0);
    for (int32 i = 0; i < ins; ++i) if (processor->getBusArrangement(kInput, i, inArr[size_t(i)]) != kResultOk) inArr[size_t(i)] = 0;
    for (int32 i = 0; i < outs; ++i) if (processor->getBusArrangement(kOutput, i, outArr[size_t(i)]) != kResultOk) outArr[size_t(i)] = 0;
    inArr[0] = want;
    outArr[0] = want;
    processor->setBusArrangements(inArr.data(), ins, outArr.data(), outs);
    // What it answered matters less than what it now has.
    SpeakerArrangement gotIn = 0, gotOut = 0;
    if (processor->getBusArrangement(kInput, 0, gotIn) != kResultOk || processor->getBusArrangement(kOutput, 0, gotOut) != kResultOk
        || gotIn != want || gotOut != want) {
        why = channels == 1 ? "The plugin doesn't take mono audio." : "The plugin doesn't take stereo audio.";
        return false;
    }
    auto prepare = [&](BusDirection dir, int32 count, std::vector<Bus> &buses, std::vector<AudioBusBuffers> &buffers) {
        buses.assign(size_t(count), Bus{});
        buffers.assign(size_t(count), AudioBusBuffers{});
        for (int32 i = 0; i < count; ++i) {
            component->activateBus(kAudio, dir, i, i == 0);
            if (i == 0) { buffers[0].numChannels = channels; continue; }
            BusInfo busInfo{};
            int32 n = component->getBusInfo(kAudio, dir, i, busInfo) == kResultOk ? busInfo.channelCount : 0;
            n = std::clamp<int32>(n, 0, 64);
            Bus &bus = buses[size_t(i)];
            bus.channels = n;
            bus.samples.assign(size_t(n) * size_t(maxFrames), 0.0f);
            for (int32 c = 0; c < n; ++c) bus.pointers.push_back(bus.samples.data() + size_t(c) * size_t(maxFrames));
            buffers[size_t(i)].numChannels = n;
            buffers[size_t(i)].channelBuffers32 = bus.pointers.data();
            buffers[size_t(i)].silenceFlags = dir == kInput && n > 0 ? (n >= 64 ? ~0ull : (1ull << n) - 1) : 0;
        }
    };
    prepare(kInput, ins, inBuses, inBuffers);
    prepare(kOutput, outs, outBuses, outBuffers);
    return true;
}

void Vst3Plugin::run(const float *const *in, float *const *out, int32_t frames, tresult &result) {
    inBuffers[0].channelBuffers32 = const_cast<Sample32 **>(in);
    inBuffers[0].silenceFlags = 0;
    outBuffers[0].channelBuffers32 = const_cast<Sample32 **>(out);
    outBuffers[0].silenceFlags = 0;
    ProcessContext context{};
    context.state = ProcessContext::kPlaying;
    context.sampleRate = sampleRate;
    context.projectTimeSamples = steady;
    ProcessData data{};
    data.processMode = kRealtime;
    data.symbolicSampleSize = kSample32;
    data.numSamples = frames;
    data.numInputs = frames > 0 ? int32(inBuffers.size()) : 0;
    data.numOutputs = frames > 0 ? int32(outBuffers.size()) : 0;
    data.inputs = frames > 0 ? inBuffers.data() : nullptr;
    data.outputs = frames > 0 ? outBuffers.data() : nullptr;
    data.inputParameterChanges = &changes;
    data.outputParameterChanges = &outChanges;
    data.inputEvents = &inEvents;
    data.outputEvents = &outEvents;
    data.processContext = &context;
    result = processor->process(data);
    changes.clear();
    // What the processor reports back (meters, a value it changed) belongs to the controller.
    if (controller) {
        for (int32 i = 0; i < outChanges.used; ++i) {
            Queue *q = outChanges.queues[size_t(i)].get();
            if (!q->points.empty()) controller->setParamNormalized(q->id, q->points.back().second);
        }
    }
    outChanges.clear();
}

bool Vst3Plugin::process(const float *const *in, float *const *out, int32_t frames) {
    auto passThrough = [&] { for (int32_t c = 0; c < channels; ++c) if (out[c] != in[c]) std::memcpy(out[c], in[c], size_t(frames) * sizeof(float)); };
    if (frames <= 0) return true;
    if (frames > maxFrames) { passThrough(); return false; }
    if (wantsRestart) {
        // The plugin asked to be made inactive and active again (its latency or buses changed).
        wantsRestart = false;
        stop();
    }
    if (!start()) { passThrough(); return false; }
    tresult result = kResultFalse;
    run(in, out, frames, result);
    steady += frames;
    if (result != kResultOk) { passThrough(); return false; }
    return true;
}

void Vst3Plugin::reset() {
    // Inactive and active again is how a VST 3 plugin is told to forget its tails.
    stop();
    start();
    steady = 0;
}

Vst3Plugin::Range Vst3Plugin::range(ParamID id) {
    const double low = controller->normalizedParamToPlain(id, 0), high = controller->normalizedParamToPlain(id, 1);
    if (!std::isfinite(low) || !std::isfinite(high) || !(high > low)) return {0, 1, false};
    return {low, high, true};
}

bool Vst3Plugin::info(ParamID id, ParameterInfo &out) {
    const int32_t n = paramCount();
    for (int32_t i = 0; i < n; ++i) {
        if (controller->getParameterInfo(i, out) == kResultOk && out.id == id) return true;
    }
    return false;
}

bool Vst3Plugin::paramInfo(int32_t index, jph_param *out) {
    if (!controller || index < 0) return false;
    ParameterInfo p{};
    if (controller->getParameterInfo(index, p) != kResultOk) return false;
    std::memset(out, 0, sizeof *out);
    out->id = p.id;
    std::snprintf(out->name, sizeof out->name, "%s", utf8(p.title, 128).c_str());
    // `module` stays empty: it is the group a parameter belongs to, which VST 3 keeps in units we don't read.
    // In the plugin's own units (Hz, dB) when it has any; 0 to 1 otherwise.
    const Range r = range(p.id);
    auto plain = [&](double normalized) { return r.plain ? controller->normalizedParamToPlain(p.id, normalized) : normalized; };
    out->min = r.low;
    out->max = r.high;
    out->initial = plain(p.defaultNormalizedValue);
    out->value = plain(controller->getParamNormalized(p.id));
    out->stepped = p.stepCount > 0;
    out->readonly = (p.flags & ParameterInfo::kIsReadOnly) != 0;
    out->hidden = (p.flags & ParameterInfo::kIsHidden) != 0;
    return true;
}

bool Vst3Plugin::paramSet(uint32_t id, double value) {
    if (!controller) return false;
    ParameterInfo p{};
    if (!info(id, p) || (p.flags & ParameterInfo::kIsReadOnly)) return false;
    const Range r = range(id);
    const double v = std::clamp(value, r.low, r.high);
    const double normalized = std::clamp(r.plain ? controller->plainParamToNormalized(id, v) : v, 0.0, 1.0);
    // Both halves are told: the controller now, the processor with its next block.
    controller->setParamNormalized(id, normalized);
    changes.set(id, normalized);
    return true;
}

bool Vst3Plugin::paramGet(uint32_t id, double *value) {
    if (!controller) return false;
    ParameterInfo p{};
    if (!info(id, p)) return false;
    const Range r = range(id);
    const double normalized = controller->getParamNormalized(id);
    *value = r.plain ? controller->normalizedParamToPlain(id, normalized) : normalized;
    return true;
}

// The saved state is both halves': "JPHVST3\1", the length of the processor's, the processor's, the controller's.
const char stateMagic[8] = {'J', 'P', 'H', 'V', 'S', 'T', '3', 1};

bool Vst3Plugin::stateSave(std::vector<uint8_t> &bytes) {
    if (changes.used > 0 && start()) {
        // Values set since the last block have only reached the controller; a block of no samples hands them over.
        tresult result = kResultFalse;
        run(nullptr, nullptr, 0, result);
    }
    Stream processorState, controllerState;
    if (component->getState(&processorState) != kResultOk) return false;
    if (controller && separate) controller->getState(&controllerState);
    const uint32_t n = uint32_t(processorState.bytes.size());
    bytes.assign(stateMagic, stateMagic + 8);
    bytes.insert(bytes.end(), reinterpret_cast<const uint8_t *>(&n), reinterpret_cast<const uint8_t *>(&n) + 4);
    bytes.insert(bytes.end(), processorState.bytes.begin(), processorState.bytes.end());
    bytes.insert(bytes.end(), controllerState.bytes.begin(), controllerState.bytes.end());
    return true;
}

bool Vst3Plugin::stateLoad(const uint8_t *data, size_t size) {
    if (size < 12 || std::memcmp(data, stateMagic, 8) != 0) return false;
    uint32_t n = 0;
    std::memcpy(&n, data + 8, 4);
    if (size_t(n) > size - 12) return false;
    Stream forProcessor(data + 12, n);
    if (component->setState(&forProcessor) != kResultOk) return false;
    if (controller) {
        Stream forController(data + 12, n);
        controller->setComponentState(&forController);
        if (separate && size - 12 - n > 0) {
            Stream own(data + 12 + n, size - 12 - n);
            controller->setState(&own);
        }
    }
    changes.clear();
    return true;
}

Vst3Plugin::~Vst3Plugin() {
    if (component && processor) stop();
    if (componentPoint && controllerPoint) {
        componentPoint->disconnect(controllerPoint);
        controllerPoint->disconnect(componentPoint);
    }
    if (componentPoint) componentPoint->release();
    if (controllerPoint) controllerPoint->release();
    if (controller) {
        controller->setComponentHandler(nullptr);
        if (controllerUp) controller->terminate();
    }
    if (component && componentUp) component->terminate();
    if (controller) controller->release();
    if (processor) processor->release();
    if (component) component->release();
    if (factory) factory->release();
    if (entered && bundle) {
        using Exit = bool (*)();
        if (auto leave = reinterpret_cast<Exit>(CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleExit")))) leave();
    }
    // The bundle stays loaded: unloading code that may have left threads or atexit handlers behind is how hosts crash.
}

/// "0123…EF" (32 hex digits, as the scanner prints a class id) into its 16 bytes.
bool classID(const char *hex, TUID out) {
    if (std::strlen(hex) != 32) return false;
    for (int i = 0; i < 16; ++i) {
        unsigned byte = 0;
        if (std::sscanf(hex + i * 2, "%2x", &byte) != 1) return false;
        out[i] = char(byte);
    }
    return true;
}

} // namespace

extern "C" jph_plugin *jph_vst3_open(const char *bundlePath, const char *id, double sampleRate, int32_t channels, int32_t maxFrames, char *error, size_t errorSize) {
    auto *p = new Vst3Plugin;
    p->channels = std::clamp(channels, 1, 2);
    p->maxFrames = std::max(1, maxFrames);
    p->sampleRate = sampleRate;
    p->handler.owner = p;
    auto bail = [&](const char *why) -> jph_plugin * { std::snprintf(error, errorSize, "%s", why); delete p; return nullptr; };
    TUID cid;
    if (!classID(id, cid)) return bail("That isn't a VST 3 class id.");
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(bundlePath), CFIndex(std::strlen(bundlePath)), true);
    p->bundle = url ? CFBundleCreate(nullptr, url) : nullptr;
    if (url) CFRelease(url);
    if (!p->bundle || !CFBundleLoadExecutable(p->bundle)) return bail("The plugin's code couldn't be loaded.");
    using Entry = bool (*)(CFBundleRef);
    using Get = IPluginFactory *(*)();
    auto entry = reinterpret_cast<Entry>(CFBundleGetFunctionPointerForName(p->bundle, CFSTR("bundleEntry")));
    auto get = reinterpret_cast<Get>(CFBundleGetFunctionPointerForName(p->bundle, CFSTR("GetPluginFactory")));
    if (!entry || !get) return bail("It isn't a VST 3 plugin.");
    if (!entry(p->bundle)) return bail("The plugin refused to start.");
    p->entered = true;
    p->factory = get();
    if (!p->factory) return bail("The plugin has no factory.");
    if (p->factory->createInstance(cid, IComponent::iid, reinterpret_cast<void **>(&p->component)) != kResultOk || !p->component) {
        p->component = nullptr;
        return bail("The bundle has no plugin with that id.");
    }
    if (p->component->initialize(&p->app) != kResultOk) return bail("The plugin failed to initialise.");
    p->componentUp = true;
    if (p->component->queryInterface(IAudioProcessor::iid, reinterpret_cast<void **>(&p->processor)) != kResultOk || !p->processor) {
        p->processor = nullptr;
        return bail("The plugin doesn't process audio.");
    }
    // The controller (the half that knows the parameters) is the same object or a class of its own.
    if (p->component->queryInterface(IEditController::iid, reinterpret_cast<void **>(&p->controller)) != kResultOk) p->controller = nullptr;
    if (!p->controller) {
        TUID controllerID;
        if (p->component->getControllerClassId(controllerID) == kResultOk
            && p->factory->createInstance(controllerID, IEditController::iid, reinterpret_cast<void **>(&p->controller)) == kResultOk && p->controller) {
            p->separate = true;
            if (p->controller->initialize(&p->app) != kResultOk) return bail("The plugin's controller failed to initialise.");
            p->controllerUp = true;
        } else {
            p->controller = nullptr; // it processes; it just has nothing to set
        }
    }
    if (p->controller) p->controller->setComponentHandler(&p->handler);
    if (p->separate) {
        if (p->component->queryInterface(IConnectionPoint::iid, reinterpret_cast<void **>(&p->componentPoint)) != kResultOk) p->componentPoint = nullptr;
        if (p->controller->queryInterface(IConnectionPoint::iid, reinterpret_cast<void **>(&p->controllerPoint)) != kResultOk) p->controllerPoint = nullptr;
        if (p->componentPoint && p->controllerPoint) {
            p->componentPoint->connect(p->controllerPoint);
            p->controllerPoint->connect(p->componentPoint);
        }
        // The controller starts from what the processor has.
        Stream state;
        if (p->component->getState(&state) == kResultOk) {
            state.at = 0;
            p->controller->setComponentState(&state);
        }
    }
    if (p->processor->canProcessSampleSize(kSample32) != kResultOk) return bail("The plugin doesn't process 32-bit float audio.");
    std::string why;
    if (!p->setUpBuses(why)) return bail(why.c_str());
    ProcessSetup setup{};
    setup.processMode = kRealtime;
    setup.symbolicSampleSize = kSample32;
    setup.maxSamplesPerBlock = p->maxFrames;
    setup.sampleRate = sampleRate;
    if (p->processor->setupProcessing(setup) != kResultOk) return bail("The plugin couldn't be set up at this sample rate.");
    if (!p->start()) return bail("The plugin couldn't be activated at this sample rate.");
    p->wantsRestart = false;
    return p;
}

#else

#include <cstdio>

extern "C" jph_plugin *jph_vst3_open(const char *, const char *, double, int32_t, int32_t, char *error, size_t errorSize) {
    std::snprintf(error, errorSize, "This build has no VST 3 support.");
    return nullptr;
}

#endif
