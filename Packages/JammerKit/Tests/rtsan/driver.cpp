// RTSan harness: drives the engine the way a device would, with the engine built
// under -fsanitize=realtime. Every call into a `nonblocking` function is checked
// at runtime: an allocation, lock or blocking syscall anywhere below it (system
// libraries included) aborts with a report. Run by scripts/rtsan.sh.

#include "jammer_engine.h"

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

namespace {

jm_plan *make_plan(jm_source *src, int64_t frames, int32_t pieces) {
    jm_plan *plan = jm_plan_create(2, 48000);
    const int32_t s = jm_plan_add_source(plan, src);
    const int32_t t = jm_plan_add_track(plan, 0.8f, false);
    const int64_t len = frames / pieces;
    for (int32_t i = 0; i < pieces; ++i) {
        jm_plan_add_clip(plan, t, s, i * len, i * len, len, 1.0f, 256, 256, i % 2 ? JM_FADE_LINEAR : JM_FADE_EQUAL_POWER);
    }
    jm_plan_finalize(plan);
    return plan;
}

#ifdef JM_RTSAN_PLANT
// Proves the harness bites: an allocation the static check can't see (through a pointer).
void *(*volatile hidden_malloc)(size_t) = std::malloc;
void planted() noexcept __attribute__((nonblocking)) { std::free(hidden_malloc(64)); }
#endif

/// Plays `seconds` through `pull` on a thread of its own while the main thread
/// seeks and swaps plans.
template <typename Pull>
void run(const char *name, jm_engine *engine, jm_source *src, int64_t frames, double seconds, Pull pull) {
    std::atomic<bool> stop{false};
    std::atomic<int64_t> calls{0};
    std::thread device([&] {
        while (!stop.load()) {
            pull();
            calls.fetch_add(1);
            std::this_thread::sleep_for(std::chrono::microseconds(800));
        }
    });
    const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    int i = 0;
    while (std::chrono::steady_clock::now() < end) {
        jm_plan *plan = make_plan(src, frames, 1 + i % 7);
        jm_engine_set_plan(engine, plan);
        jm_plan_release(plan);
        if (i % 3 == 0) jm_engine_play(engine, (i * 7919) % frames);
        if (i % 11 == 5) jm_engine_stop(engine);
        jm_engine_set_gain(engine, i % 2 ? 0.0f : 0.5f);
        (void)jm_engine_take_peak(engine, 0);
        std::this_thread::sleep_for(std::chrono::milliseconds(15));
        ++i;
    }
    // Let it run to the end once.
    jm_engine_play(engine, frames - 4800);
    for (int k = 0; k < 400 && jm_engine_is_playing(engine); ++k) std::this_thread::sleep_for(std::chrono::milliseconds(2));
    stop.store(true);
    device.join();
    std::printf("RTSAN  %-28s %lld device calls, %d plan swaps, playhead %lld, underruns %lld\n", name, (long long)calls.load(), i,
                (long long)jm_engine_playhead(engine), (long long)jm_engine_underruns(engine));
}

} // namespace

int main() {
    const int64_t frames = 48000 * 4;
    std::vector<float> signal(size_t(frames * 2));
    for (int64_t i = 0; i < frames; ++i) {
        signal[size_t(i * 2)] = float(0.5 * std::sin(i * 0.031));
        signal[size_t(i * 2 + 1)] = float(0.5 * std::sin(i * 0.017));
    }
    jm_source *src = jm_source_create_memory(signal.data(), frames, 2);

#ifdef JM_RTSAN_PLANT
    planted();
    std::printf("RTSAN  the planted violation was NOT caught\n");
    return 1;
#endif

    // 1. jm_engine_pull at the project rate (the bit-exact path).
    {
        jm_engine *engine = jm_engine_create(2, 48000, 16384);
        std::vector<float> l(512), r(512);
        float *outs[2] = {l.data(), r.data()};
        run("pull, 48 kHz", engine, src, frames, 1.5, [&] { jm_engine_pull(engine, outs, 2, 512); });
        jm_engine_destroy(engine);
    }
    // 2. The IOProc into a 4-channel interleaved device at 44.1 kHz (resampling worker).
    {
        jm_engine *engine = jm_engine_create(2, 48000, 16384);
        const int32_t buffers[2] = {0, 0}, channels[2] = {2, 3}, sources[2] = {0, 1};
        jm_engine_set_output(engine, 44100, buffers, channels, sources, nullptr, 2);
        std::vector<float> data(512 * 4);
        AudioBufferList out{};
        out.mNumberBuffers = 1;
        out.mBuffers[0] = AudioBuffer{4, UInt32(data.size() * 4), data.data()};
        AudioBufferList in{};
        AudioTimeStamp ts{};
        run("ioproc, 44.1 kHz device", engine, src, frames, 1.5,
            [&] { jm_engine_ioproc(0, &ts, &in, &ts, &out, &ts, engine); });
        jm_engine_destroy(engine);
    }
    // 3. The audio-unit callback, non-interleaved.
    {
        jm_engine *engine = jm_engine_create(2, 48000, 16384);
        std::vector<float> l(512), r(512);
        struct {
            AudioBufferList list;
            AudioBuffer second;
        } abl{};
        abl.list.mNumberBuffers = 2;
        abl.list.mBuffers[0] = AudioBuffer{1, 512 * 4, l.data()};
        abl.second = AudioBuffer{1, 512 * 4, r.data()};
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp ts{};
        run("audio unit callback", engine, src, frames, 1.0,
            [&] { jm_engine_au_render(engine, &flags, &ts, 0, 512, &abl.list); });
        jm_engine_destroy(engine);
    }
    jm_source_release(src);
    std::printf("RTSAN  clean: no realtime violations\n");
    return 0;
}
