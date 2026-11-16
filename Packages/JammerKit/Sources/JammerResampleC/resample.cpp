// The one place r8brain-free-src is compiled into Jämmer. Built from its source as fetched by
// scripts/fetch-r8brain.sh, with its bundled Ooura FFT; PFFFT and Intel IPP are off (r8bconf.h defaults).
#include "jammer_resample.h"
#include "CDSPResampler.h"
#include <memory>
#include <vector>

struct jr_resampler {
    int channels;
    int maxFrames;
    int maxOut;
    std::vector<std::unique_ptr<r8b::CDSPResampler24>> convs;
    std::vector<double> in;
};

jr_resampler *jr_create(double from_rate, double to_rate, int channels, int max_frames) {
    if (!(from_rate > 0) || !(to_rate > 0) || channels < 1 || channels > 64 || max_frames < 1) return nullptr;
    auto r = new jr_resampler();
    r->channels = channels;
    r->maxFrames = max_frames;
    r->in.resize((size_t)max_frames);
    r->maxOut = 0;
    for (int c = 0; c < channels; c++) {
        r->convs.emplace_back(new r8b::CDSPResampler24(from_rate, to_rate, max_frames));
        r->maxOut = r->convs.back()->getMaxOutLen(0);
    }
    return r;
}

int jr_max_out(const jr_resampler *r) { return r ? r->maxOut : 0; }

int jr_process(jr_resampler *r, const float *in, int frames, float *out, int out_capacity) {
    if (!r || frames < 0 || frames > r->maxFrames) return -1;
    int written = 0;
    for (int c = 0; c < r->channels; c++) {
        for (int i = 0; i < frames; i++) r->in[(size_t)i] = in[(size_t)i * (size_t)r->channels + (size_t)c];
        double *op = nullptr;
        const int n = r->convs[(size_t)c]->process(r->in.data(), frames, op);
        if (n > out_capacity) return -1;
        for (int i = 0; i < n; i++) out[(size_t)i * (size_t)r->channels + (size_t)c] = (float)op[i];
        // Every channel is the same converter given the same number of samples: the counts agree.
        written = n;
    }
    return written;
}

void jr_destroy(jr_resampler *r) { delete r; }
const char *jr_version(void) { return R8B_VERSION; }
