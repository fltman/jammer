// The CLAP side of the plugin host (CLAP 1.2, MIT headers).

#include "jammer_plugin_host.h"

#include <CoreFoundation/CoreFoundation.h>
#include <clap/clap.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

struct jph_plugin {
    CFBundleRef bundle = nullptr;
    const clap_plugin_entry_t *entry = nullptr;
    const clap_plugin_t *plugin = nullptr;
    clap_host_t host{};
    const clap_plugin_params_t *params = nullptr;
    const clap_plugin_state_t *state = nullptr;
    const clap_plugin_latency_t *latency = nullptr;
    int32_t channels = 2, maxFrames = 512;
    double sampleRate = 48000;
    bool active = false, processing = false, wantsCallback = false, wantsRestart = false;
    int64_t steady = 0;
    /// Parameter changes waiting for the next block.
    std::vector<clap_event_param_value_t> pending;
    std::vector<float> silence;
};

namespace {

void fail(char *error, size_t size, const char *why) { std::snprintf(error, size, "%s", why); }

// What the plugin may ask of its host. Everything runs on the one thread that drives the plugin.
const void *hostExtension(const clap_host_t *, const char *id);
void requestRestart(const clap_host_t *h) { static_cast<jph_plugin *>(h->host_data)->wantsRestart = true; }
void requestProcess(const clap_host_t *) {}
void requestCallback(const clap_host_t *h) { static_cast<jph_plugin *>(h->host_data)->wantsCallback = true; }

bool isMainThread(const clap_host_t *) { return true; }
bool isAudioThread(const clap_host_t *) { return true; }
const clap_host_thread_check_t threadCheck{isMainThread, isAudioThread};

void latencyChanged(const clap_host_t *h) { static_cast<jph_plugin *>(h->host_data)->wantsRestart = true; }
const clap_host_latency_t hostLatency{latencyChanged};

void paramsRescan(const clap_host_t *, clap_param_rescan_flags) {}
void paramsClear(const clap_host_t *, clap_id, clap_param_clear_flags) {}
void paramsRequestFlush(const clap_host_t *) {}
const clap_host_params_t hostParams{paramsRescan, paramsClear, paramsRequestFlush};

void stateMarkDirty(const clap_host_t *) {}
const clap_host_state_t hostState{stateMarkDirty};

void hostLog(const clap_host_t *, clap_log_severity severity, const char *msg) {
    if (severity >= CLAP_LOG_WARNING) std::fprintf(stderr, "plugin: %s\n", msg ? msg : "");
}
const clap_host_log_t hostLogExt{hostLog};

const void *hostExtension(const clap_host_t *, const char *id) {
    if (!std::strcmp(id, CLAP_EXT_THREAD_CHECK)) return &threadCheck;
    if (!std::strcmp(id, CLAP_EXT_LATENCY)) return &hostLatency;
    if (!std::strcmp(id, CLAP_EXT_PARAMS)) return &hostParams;
    if (!std::strcmp(id, CLAP_EXT_STATE)) return &hostState;
    if (!std::strcmp(id, CLAP_EXT_LOG)) return &hostLogExt;
    return nullptr;
}

// Events into a block: the pending parameter changes, all at time 0.
uint32_t inSize(const clap_input_events_t *l) { return uint32_t(static_cast<jph_plugin *>(l->ctx)->pending.size()); }
const clap_event_header_t *inGet(const clap_input_events_t *l, uint32_t i) { return &static_cast<jph_plugin *>(l->ctx)->pending[i].header; }
bool outPush(const clap_output_events_t *, const clap_event_header_t *) { return true; }

void pump(jph_plugin *p) {
    if (p->wantsCallback) {
        p->wantsCallback = false;
        p->plugin->on_main_thread(p->plugin);
    }
}

bool start(jph_plugin *p) {
    if (!p->active) {
        if (!p->plugin->activate(p->plugin, p->sampleRate, 1, uint32_t(p->maxFrames))) return false;
        p->active = true;
    }
    if (!p->processing) {
        if (!p->plugin->start_processing(p->plugin)) return false;
        p->processing = true;
    }
    return true;
}

void stop(jph_plugin *p) {
    if (p->processing) { p->plugin->stop_processing(p->plugin); p->processing = false; }
    if (p->active) { p->plugin->deactivate(p->plugin); p->active = false; }
}

/// The plugin's main ports must both take our channel count.
bool portsFit(jph_plugin *p) {
    auto *ports = static_cast<const clap_plugin_audio_ports_t *>(p->plugin->get_extension(p->plugin, CLAP_EXT_AUDIO_PORTS));
    if (!ports) return true; // no say: the default is stereo in, stereo out
    for (bool input : {true, false}) {
        if (ports->count(p->plugin, input) < 1) return false;
        clap_audio_port_info_t info{};
        if (!ports->get(p->plugin, 0, input, &info) || int32_t(info.channel_count) != p->channels) return false;
    }
    return true;
}

} // namespace

extern "C" {

jph_plugin *jph_clap_open(const char *bundlePath, const char *id, double sampleRate, int32_t channels, int32_t maxFrames, char *error, size_t errorSize) {
    auto *p = new jph_plugin;
    p->channels = std::clamp(channels, 1, 2);
    p->maxFrames = std::max(1, maxFrames);
    p->sampleRate = sampleRate;
    p->silence.assign(size_t(p->maxFrames), 0.0f);
    p->host = clap_host_t{CLAP_VERSION_INIT, p, "Jammer", "Brattoo", "https://jammer.brattoo.com", "0.1", hostExtension, requestRestart, requestProcess, requestCallback};
    auto bail = [&](const char *why) -> jph_plugin * { fail(error, errorSize, why); jph_close(p); return nullptr; };
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(bundlePath), CFIndex(std::strlen(bundlePath)), true);
    p->bundle = url ? CFBundleCreate(nullptr, url) : nullptr;
    if (url) CFRelease(url);
    if (!p->bundle || !CFBundleLoadExecutable(p->bundle)) return bail("The plugin's code couldn't be loaded.");
    auto *entry = static_cast<const clap_plugin_entry_t *>(CFBundleGetDataPointerForName(p->bundle, CFSTR("clap_entry")));
    if (!entry || !clap_version_is_compatible(entry->clap_version)) return bail("It isn't a CLAP plugin this version can host.");
    if (!entry->init(bundlePath)) return bail("The plugin refused to start.");
    p->entry = entry;
    auto *factory = static_cast<const clap_plugin_factory_t *>(entry->get_factory(CLAP_PLUGIN_FACTORY_ID));
    if (!factory) return bail("The plugin has no factory.");
    p->plugin = factory->create_plugin(factory, &p->host, id);
    if (!p->plugin) return bail("The bundle has no plugin with that id.");
    if (!p->plugin->init(p->plugin)) return bail("The plugin failed to initialise.");
    if (!portsFit(p)) return bail(p->channels == 1 ? "The plugin doesn't take mono audio." : "The plugin doesn't take stereo audio.");
    p->params = static_cast<const clap_plugin_params_t *>(p->plugin->get_extension(p->plugin, CLAP_EXT_PARAMS));
    p->state = static_cast<const clap_plugin_state_t *>(p->plugin->get_extension(p->plugin, CLAP_EXT_STATE));
    p->latency = static_cast<const clap_plugin_latency_t *>(p->plugin->get_extension(p->plugin, CLAP_EXT_LATENCY));
    if (!start(p)) return bail("The plugin couldn't be activated at this sample rate.");
    pump(p);
    return p;
}

void jph_close(jph_plugin *p) {
    if (!p) return;
    if (p->plugin) {
        stop(p);
        p->plugin->destroy(p->plugin);
    }
    if (p->entry) p->entry->deinit();
    // The bundle stays loaded: unloading code that may have left threads or atexit handlers behind is how hosts crash.
    delete p;
}

bool jph_process(jph_plugin *p, const float *const *in, float *const *out, int32_t frames) {
    auto passThrough = [&] { for (int32_t c = 0; c < p->channels; ++c) if (out[c] != in[c]) std::memcpy(out[c], in[c], size_t(frames) * sizeof(float)); };
    if (frames <= 0) return true;
    if (frames > p->maxFrames) { passThrough(); return false; }
    if (p->wantsRestart) {
        // The plugin asked to be deactivated and activated again (its latency or ports changed).
        p->wantsRestart = false;
        stop(p);
    }
    pump(p);
    if (!start(p)) { passThrough(); return false; }
    clap_audio_buffer_t inBuf{}, outBuf{};
    inBuf.data32 = const_cast<float **>(in);
    inBuf.channel_count = uint32_t(p->channels);
    outBuf.data32 = const_cast<float **>(out);
    outBuf.channel_count = uint32_t(p->channels);
    const clap_input_events_t inEvents{p, inSize, inGet};
    const clap_output_events_t outEvents{p, outPush};
    clap_process_t proc{};
    proc.steady_time = p->steady;
    proc.frames_count = uint32_t(frames);
    proc.audio_inputs = &inBuf;
    proc.audio_outputs = &outBuf;
    proc.audio_inputs_count = 1;
    proc.audio_outputs_count = 1;
    proc.in_events = &inEvents;
    proc.out_events = &outEvents;
    const clap_process_status status = p->plugin->process(p->plugin, &proc);
    p->pending.clear();
    p->steady += frames;
    if (status == CLAP_PROCESS_ERROR) { passThrough(); return false; }
    return true;
}

void jph_reset(jph_plugin *p) {
    if (p->plugin->reset) p->plugin->reset(p->plugin);
    p->steady = 0;
}

int32_t jph_latency(jph_plugin *p) { return p->latency ? int32_t(p->latency->get(p->plugin)) : 0; }

int32_t jph_param_count(jph_plugin *p) { return p->params ? int32_t(p->params->count(p->plugin)) : 0; }

bool jph_param_info(jph_plugin *p, int32_t index, jph_param *out) {
    if (!p->params || index < 0) return false;
    clap_param_info_t info{};
    if (!p->params->get_info(p->plugin, uint32_t(index), &info)) return false;
    std::memset(out, 0, sizeof *out);
    out->id = info.id;
    std::snprintf(out->name, sizeof out->name, "%s", info.name);
    std::snprintf(out->module, sizeof out->module, "%s", info.module);
    out->min = info.min_value;
    out->max = info.max_value;
    out->initial = info.default_value;
    out->stepped = (info.flags & CLAP_PARAM_IS_STEPPED) != 0;
    out->readonly = (info.flags & CLAP_PARAM_IS_READONLY) != 0;
    out->hidden = (info.flags & CLAP_PARAM_IS_HIDDEN) != 0;
    double v = info.default_value;
    p->params->get_value(p->plugin, info.id, &v);
    out->value = v;
    return true;
}

bool jph_param_set(jph_plugin *p, uint32_t id, double value) {
    if (!p->params) return false;
    const int32_t n = jph_param_count(p);
    for (int32_t i = 0; i < n; ++i) {
        clap_param_info_t info{};
        if (!p->params->get_info(p->plugin, uint32_t(i), &info) || info.id != id) continue;
        if (info.flags & CLAP_PARAM_IS_READONLY) return false;
        clap_event_param_value_t e{};
        e.header.size = sizeof e;
        e.header.time = 0;
        e.header.space_id = CLAP_CORE_EVENT_SPACE_ID;
        e.header.type = CLAP_EVENT_PARAM_VALUE;
        e.param_id = id;
        e.cookie = info.cookie;
        e.note_id = -1;
        e.port_index = -1;
        e.channel = -1;
        e.key = -1;
        e.value = std::clamp(value, info.min_value, info.max_value);
        p->pending.push_back(e);
        // Nothing may be processing for a long while (an offline render that hasn't started): hand it over now.
        const clap_input_events_t inEvents{p, inSize, inGet};
        const clap_output_events_t outEvents{p, outPush};
        if (p->params->flush) {
            p->params->flush(p->plugin, &inEvents, &outEvents);
            p->pending.clear();
        }
        return true;
    }
    return false;
}

bool jph_param_get(jph_plugin *p, uint32_t id, double *value) { return p->params && p->params->get_value(p->plugin, id, value); }

bool jph_state_save(jph_plugin *p, uint8_t **data, size_t *size) {
    if (!p->state) return false;
    std::vector<uint8_t> bytes;
    clap_ostream_t stream{&bytes, [](const clap_ostream_t *s, const void *buffer, uint64_t n) -> int64_t {
                              auto *v = static_cast<std::vector<uint8_t> *>(s->ctx);
                              const auto *b = static_cast<const uint8_t *>(buffer);
                              v->insert(v->end(), b, b + n);
                              return int64_t(n);
                          }};
    if (!p->state->save(p->plugin, &stream)) return false;
    *size = bytes.size();
    *data = static_cast<uint8_t *>(std::malloc(std::max<size_t>(1, bytes.size())));
    if (!bytes.empty()) std::memcpy(*data, bytes.data(), bytes.size());
    return true;
}

bool jph_state_load(jph_plugin *p, const uint8_t *data, size_t size) {
    if (!p->state) return false;
    struct Cursor { const uint8_t *data; size_t size, at; } cursor{data, size, 0};
    clap_istream_t stream{&cursor, [](const clap_istream_t *s, void *buffer, uint64_t n) -> int64_t {
                              auto *c = static_cast<Cursor *>(s->ctx);
                              const size_t take = std::min<size_t>(size_t(n), c->size - c->at);
                              std::memcpy(buffer, c->data + c->at, take);
                              c->at += take;
                              return int64_t(take);
                          }};
    return p->state->load(p->plugin, &stream);
}

void jph_free(void *data) { std::free(data); }

} // extern "C"
