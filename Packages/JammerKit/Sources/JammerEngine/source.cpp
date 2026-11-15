// Sources: interleaved PCM regions of files (or memory), read as float.

#include "internal.hpp"

#include <algorithm>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

namespace jm {

namespace {

int bytes_per_sample(jm_sample_format f) {
    switch (f) {
    case JM_PCM_U8:
    case JM_PCM_I8: return 1;
    case JM_PCM_I16: return 2;
    case JM_PCM_I24: return 3;
    case JM_PCM_I32: return 4;
    case JM_PCM_F32: return 4;
    case JM_PCM_F64: return 8;
    }
    return 0;
}

// Integer scales are powers of two, so int16/int24 → float → int is exact.
inline float decode(const uint8_t *p, jm_sample_format f, bool be) {
    switch (f) {
    case JM_PCM_U8: return (float(p[0]) - 128.0f) * (1.0f / 128.0f);
    case JM_PCM_I8: return float(int8_t(p[0])) * (1.0f / 128.0f);
    case JM_PCM_I16: {
        int16_t v = be ? int16_t((p[0] << 8) | p[1]) : int16_t(p[0] | (p[1] << 8));
        return float(v) * (1.0f / 32768.0f);
    }
    case JM_PCM_I24: {
        int32_t v = be ? (int32_t(p[0]) << 24) | (int32_t(p[1]) << 16) | (int32_t(p[2]) << 8)
                       : (int32_t(p[2]) << 24) | (int32_t(p[1]) << 16) | (int32_t(p[0]) << 8);
        return float(v >> 8) * (1.0f / 8388608.0f);
    }
    case JM_PCM_I32: {
        uint32_t u = be ? (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3]
                        : (uint32_t(p[3]) << 24) | (uint32_t(p[2]) << 16) | (uint32_t(p[1]) << 8) | p[0];
        return float(double(int32_t(u)) * (1.0 / 2147483648.0));
    }
    case JM_PCM_F32: {
        uint32_t u = be ? (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3]
                        : (uint32_t(p[3]) << 24) | (uint32_t(p[2]) << 16) | (uint32_t(p[1]) << 8) | p[0];
        float v;
        std::memcpy(&v, &u, 4);
        return v;
    }
    case JM_PCM_F64: {
        uint64_t u = 0;
        for (int i = 0; i < 8; ++i) u |= uint64_t(p[be ? i : 7 - i]) << (8 * (7 - i));
        double v;
        std::memcpy(&v, &u, 8);
        return float(v);
    }
    }
    return 0.0f;
}

} // namespace

Source::~Source() {
    if (fd >= 0) close(fd);
}

int64_t Source::read(int64_t frame, int64_t count, float *out) const {
    if (frame < 0 || count <= 0 || frame >= frames) return 0;
    count = std::min(count, frames - frame);
    const int64_t samples = count * channels;
    if (!memory.empty()) {
        std::memcpy(out, memory.data() + frame * channels, size_t(samples) * sizeof(float));
        return count;
    }
    const int bps = bytes_per_sample(format);
    const int64_t frameBytes = int64_t(bps) * channels;
    // Read in slices so the scratch stays small; the caller owns `out`.
    constexpr int64_t sliceFrames = 16384;
    std::vector<uint8_t> raw(size_t(std::min(count, sliceFrames) * frameBytes));
    int64_t done = 0;
    while (done < count) {
        const int64_t n = std::min(sliceFrames, count - done);
        const int64_t want = n * frameBytes;
        int64_t got = 0;
        while (got < want) {
            ssize_t r = pread(fd, raw.data() + got, size_t(want - got), off_t(dataOffset + (frame + done) * frameBytes + got));
            if (r <= 0) break;
            got += r;
        }
        const int64_t gotFrames = got / frameBytes;
        float *dst = out + done * channels;
        const uint8_t *src = raw.data();
        for (int64_t i = 0; i < gotFrames * channels; ++i, src += bps) dst[i] = decode(src, format, bigEndian);
        done += gotFrames;
        if (gotFrames < n) break;
    }
    return done;
}

} // namespace jm

using namespace jm;

extern "C" {

jm_source *jm_source_open(const char *path, int64_t data_offset, int64_t frames, int32_t channels,
                          jm_sample_format format, bool big_endian) {
    if (channels <= 0 || frames < 0 || data_offset < 0) return nullptr;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return nullptr;
    auto s = std::make_shared<Source>();
    s->fd = fd;
    s->dataOffset = data_offset;
    s->frames = frames;
    s->channels = channels;
    s->format = format;
    s->bigEndian = big_endian;
    return new jm_source{std::move(s)};
}

jm_source *jm_source_create_memory(const float *interleaved, int64_t frames, int32_t channels) {
    auto s = std::make_shared<Source>();
    s->frames = std::max<int64_t>(0, frames);
    s->channels = std::max(1, channels);
    s->memory.assign(interleaved, interleaved + s->frames * s->channels);
    s->format = JM_PCM_F32;
    return new jm_source{std::move(s)};
}

void jm_source_release(jm_source *source) { delete source; }
int64_t jm_source_frames(const jm_source *source) { return source->ptr->frames; }
int32_t jm_source_channels(const jm_source *source) { return source->ptr->channels; }

int64_t jm_source_read(const jm_source *source, int64_t frame, int64_t frames, float *interleaved) {
    return source->ptr->read(frame, frames, interleaved);
}

} // extern "C"
