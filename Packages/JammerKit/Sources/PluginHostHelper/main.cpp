// jammer-plugin-host: hosts ONE plugin and serves it over its standard input and output.
// One process per plugin, so a plugin that crashes or hangs takes only itself along: Jämmer
// sees the pipe close (or the answer not come), lets the sound through unprocessed and says so.
//
// The protocol is frames of [u32 op][u32 length][payload], answered by [u32 status][u32 length][payload]
// (little-endian, status 0 = ok). Ops:
//   1 OPEN     payload: format\0bundle\0id\0 then f64 sampleRate, i32 channels, i32 maxFrames
//              answer:  i32 latency, i32 paramCount, then paramCount × jph_param
//   2 PROCESS  payload: i32 frames, then channels × frames floats (planar)   answer: the same shape
//   3 RESET
//   4 SET      payload: u32 id, f64 value
//   5 PARAMS   answer as in OPEN (current values)
//   6 SAVE     answer: the state bytes
//   7 LOAD     payload: the state bytes
//   8 QUIT

#include "jammer_plugin_host.h"

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

int out = 1;

bool readAll(int fd, void *buffer, size_t n) {
    auto *p = static_cast<uint8_t *>(buffer);
    while (n > 0) {
        const ssize_t got = read(fd, p, n);
        if (got == 0) return false;
        if (got < 0) { if (errno == EINTR) continue; return false; }
        p += got;
        n -= size_t(got);
    }
    return true;
}

bool writeAll(int fd, const void *buffer, size_t n) {
    auto *p = static_cast<const uint8_t *>(buffer);
    while (n > 0) {
        const ssize_t put = write(fd, p, n);
        if (put < 0) { if (errno == EINTR) continue; return false; }
        p += put;
        n -= size_t(put);
    }
    return true;
}

bool answer(uint32_t status, const void *payload = nullptr, uint32_t length = 0) {
    const uint32_t head[2] = {status, length};
    return writeAll(out, head, sizeof head) && (length == 0 || writeAll(out, payload, length));
}

bool answerError(const char *why) { return answer(1, why, uint32_t(std::strlen(why))); }

std::vector<uint8_t> describe(jph_plugin *p) {
    const int32_t latency = jph_latency(p), n = jph_param_count(p);
    std::vector<uint8_t> bytes(8 + size_t(n) * sizeof(jph_param));
    std::memcpy(bytes.data(), &latency, 4);
    int32_t kept = 0;
    for (int32_t i = 0; i < n; ++i) {
        jph_param info;
        if (jph_param_info(p, i, &info)) std::memcpy(bytes.data() + 8 + size_t(kept++) * sizeof info, &info, sizeof info);
    }
    std::memcpy(bytes.data() + 4, &kept, 4);
    bytes.resize(8 + size_t(kept) * sizeof(jph_param));
    return bytes;
}

} // namespace

int main() {
    // The plugin may print; the protocol must not see it. Keep the real stdout for answers
    // and point fd 1 at stderr for everything else.
    out = dup(1);
    dup2(2, 1);
    // Never outlive Jämmer. Normally its end closes our input and the loop below ends; but a
    // plugin stuck in its own code would never get there, so a watcher ends the process the
    // moment the parent is gone (the parent id changes when it dies).
    const pid_t parent = getppid();
    std::thread([parent] {
        for (;;) {
            if (getppid() != parent) _exit(0);
            usleep(250'000);
        }
    }).detach();
    jph_plugin *plugin = nullptr;
    int32_t channels = 2, maxFrames = 512;
    std::vector<uint8_t> payload;
    std::vector<float> outBuffer;
    for (;;) {
        uint32_t head[2];
        if (!readAll(0, head, sizeof head)) break; // Jämmer is gone or closed us
        if (head[1] > (64u << 20)) break;
        payload.resize(head[1]);
        if (head[1] && !readAll(0, payload.data(), head[1])) break;
        switch (head[0]) {
        case 1: {
            const char *s = reinterpret_cast<const char *>(payload.data());
            const char *end = s + payload.size();
            std::string parts[3];
            for (auto &part : parts) {
                const size_t n = strnlen(s, size_t(end - s));
                part.assign(s, n);
                s += std::min<size_t>(n + 1, size_t(end - s));
            }
            if (size_t(end - s) < 16 || plugin) { answerError("bad open"); break; }
            double rate;
            std::memcpy(&rate, s, 8);
            std::memcpy(&channels, s + 8, 4);
            std::memcpy(&maxFrames, s + 12, 4);
            char error[256] = "";
            if (parts[0] == "clap") plugin = jph_clap_open(parts[1].c_str(), parts[2].c_str(), rate, channels, maxFrames, error, sizeof error);
            else std::snprintf(error, sizeof error, "This build can't host %s plugins yet.", parts[0].c_str());
            if (!plugin) { answerError(error); break; }
            outBuffer.assign(size_t(channels) * size_t(maxFrames), 0.0f);
            const auto d = describe(plugin);
            answer(0, d.data(), uint32_t(d.size()));
            break;
        }
        case 2: {
            int32_t frames = 0;
            if (payload.size() >= 4) std::memcpy(&frames, payload.data(), 4);
            if (!plugin || frames <= 0 || frames > maxFrames || payload.size() != 4 + size_t(channels) * size_t(frames) * 4) { answerError("bad block"); break; }
            // The payload is unaligned for floats after its 4-byte head only by accident of layout; copy to be sure.
            std::vector<float> in(size_t(channels) * size_t(frames));
            std::memcpy(in.data(), payload.data() + 4, in.size() * 4);
            const float *ins[2] = {in.data(), in.data() + (channels > 1 ? frames : 0)};
            float *outs[2] = {outBuffer.data(), outBuffer.data() + (channels > 1 ? frames : 0)};
            const bool ok = jph_process(plugin, ins, outs, frames);
            std::vector<uint8_t> reply(4 + in.size() * 4);
            std::memcpy(reply.data(), &frames, 4);
            std::memcpy(reply.data() + 4, outBuffer.data(), in.size() * 4);
            answer(ok ? 0 : 2, reply.data(), uint32_t(reply.size()));
            break;
        }
        case 3:
            if (plugin) jph_reset(plugin);
            answer(0);
            break;
        case 4: {
            uint32_t id;
            double value;
            if (!plugin || payload.size() != 12) { answerError("bad set"); break; }
            std::memcpy(&id, payload.data(), 4);
            std::memcpy(&value, payload.data() + 4, 8);
            answer(jph_param_set(plugin, id, value) ? 0 : 1);
            break;
        }
        case 5: {
            if (!plugin) { answerError("not open"); break; }
            const auto d = describe(plugin);
            answer(0, d.data(), uint32_t(d.size()));
            break;
        }
        case 6: {
            uint8_t *data = nullptr;
            size_t size = 0;
            if (!plugin || !jph_state_save(plugin, &data, &size)) { answerError("The plugin has no state to save."); break; }
            answer(0, data, uint32_t(size));
            jph_free(data);
            break;
        }
        case 7:
            answer(plugin && jph_state_load(plugin, payload.data(), payload.size()) ? 0 : 1);
            break;
        case 8:
            answer(0);
            jph_close(plugin);
            return 0;
        default:
            answerError("unknown op");
        }
    }
    jph_close(plugin);
    return 0;
}
