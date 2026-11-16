#ifndef JAMMER_RESAMPLE_H
#define JAMMER_RESAMPLE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Sample rate conversion with r8brain-free-src (MIT, Aleksey Vaneev of Voxengo), one converter per
/// channel at its 24-bit setting. Not for the audio thread: it allocates.
typedef struct jr_resampler jr_resampler;

/// NULL when a rate is not positive or channels is not 1…64. `max_frames` is the most `jr_process` will be given at once.
jr_resampler *jr_create(double from_rate, double to_rate, int channels, int max_frames);
/// Takes `frames` interleaved frames and writes what comes out of them, interleaved, into `out`
/// (room for `out_capacity` frames). Returns the frames written; -1 when `out` is too small or
/// `frames` is over `max_frames`. The converter takes its own delay away: the output starts where the input does.
int jr_process(jr_resampler *r, const float *in, int frames, float *out, int out_capacity);
/// The most frames one call of `jr_process` can write.
int jr_max_out(const jr_resampler *r);
void jr_destroy(jr_resampler *r);
/// r8brain's version string, e.g. "7.7".
const char *jr_version(void);

#ifdef __cplusplus
}
#endif
#endif
