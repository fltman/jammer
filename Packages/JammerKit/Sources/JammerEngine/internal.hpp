// Shared C++ types behind the C API. Not part of the public header.

#pragma once

#include "jammer_engine.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <vector>

namespace jm {

struct Source {
    int fd = -1;
    int64_t dataOffset = 0;
    int64_t frames = 0;
    int32_t channels = 1;
    jm_sample_format format = JM_PCM_F32;
    bool bigEndian = false;
    std::vector<float> memory; // non-empty for in-memory sources

    ~Source();
    /// Thread-safe (pread); allocates scratch, so never on the audio thread.
    int64_t read(int64_t frame, int64_t count, float *out) const;
};

struct Clip {
    int32_t track;
    int32_t source;
    int64_t sourceStart;
    int64_t start; // timeline
    int64_t length;
    float gain;
    int64_t fadeIn;
    int64_t fadeOut;
    jm_fade_shape shape;
    int64_t end() const { return start + length; }
};

struct Track {
    float gain = 1.0f;
    bool mute = false;
};

struct Plan {
    int32_t channels;
    double sampleRate;
    std::vector<std::shared_ptr<Source>> sources;
    std::vector<Track> tracks;
    std::vector<Clip> clips; // sorted by start once finalized
    int64_t length = 0;
    bool finalized = false;
};

/// Renders a plan into interleaved float. Owns its scratch, so reuse one per thread.
class Renderer {
public:
    explicit Renderer(int32_t channels) : channels_(channels) {}
    void render(const Plan &plan, int64_t start, int64_t frames, float *out);

private:
    int32_t channels_;
    std::vector<float> scratch_;
};

} // namespace jm

struct jm_source {
    std::shared_ptr<jm::Source> ptr;
};

struct jm_plan {
    std::shared_ptr<jm::Plan> ptr;
};
