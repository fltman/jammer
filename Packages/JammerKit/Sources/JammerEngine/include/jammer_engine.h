// Jammer's realtime core: a C API over a small C++20 engine.
//
// Threads:
// - The audio device thread calls only `jm_engine_pull` / `jm_engine_au_render`.
//   Both are `nonblocking`: the compiler (-Werror=function-effects) refuses any
//   allocation, lock or blocking call reachable from them.
// - A render worker inside the engine renders the current plan ahead of the
//   playhead into a lock-free ring buffer (reads files, mixes clips).
// - Everything else (building plans, offline renders, reading sources) runs on
//   ordinary threads.
//
// Plans are immutable once finalized. Publishing a new plan never blocks the
// audio thread: the worker picks it up at its next block.

#ifndef JAMMER_ENGINE_H
#define JAMMER_ENGINE_H

#include <stdbool.h>
#include <stdint.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>

#ifdef __cplusplus
extern "C" {
#endif

// Marks audio-thread entry points: noexcept, and checked by the compiler to be nonblocking.
#if defined(__cplusplus)
#define JM_NONBLOCKING noexcept __attribute__((nonblocking))
#elif defined(__clang__)
#define JM_NONBLOCKING __attribute__((nonblocking))
#else
#define JM_NONBLOCKING
#endif

// MARK: Sources

/// Sample encodings a source can be read from.
typedef enum jm_sample_format {
    JM_PCM_U8 = 1,   ///< unsigned 8-bit (WAV)
    JM_PCM_I8 = 2,   ///< signed 8-bit (AIFF)
    JM_PCM_I16 = 3,
    JM_PCM_I24 = 4,
    JM_PCM_I32 = 5,
    JM_PCM_F32 = 6,
    JM_PCM_F64 = 7,
} jm_sample_format;

/// An interleaved PCM region of a file, read with pread (never on the audio thread).
typedef struct jm_source jm_source;

/// Opens `frames` frames of interleaved PCM starting at byte `data_offset`.
/// Returns NULL if the file can't be opened.
jm_source *_Nullable jm_source_open(const char *_Nonnull path, int64_t data_offset, int64_t frames,
                                    int32_t channels, jm_sample_format format, bool big_endian);
/// An in-memory source (tests, generated audio). Copies `frames * channels` floats.
jm_source *_Nonnull jm_source_create_memory(const float *_Nonnull interleaved, int64_t frames, int32_t channels);
void jm_source_release(jm_source *_Nullable source);
int64_t jm_source_frames(const jm_source *_Nonnull source);
int32_t jm_source_channels(const jm_source *_Nonnull source);
/// Reads up to `frames` frames from `frame` as interleaved float in [-1, 1).
/// Integer samples are scaled by 2^(bits-1), so int16/int24 round-trip bit-exactly.
/// Returns the frames read; past the end it reads fewer. Thread-safe.
int64_t jm_source_read(const jm_source *_Nonnull source, int64_t frame, int64_t frames, float *_Nonnull interleaved);

// MARK: Plans

/// What the engine plays: tracks of clips over sources, compiled from the document model.
typedef struct jm_plan jm_plan;

typedef enum jm_fade_shape {
    JM_FADE_LINEAR = 0,
    JM_FADE_EQUAL_POWER = 1,
} jm_fade_shape;

jm_plan *_Nonnull jm_plan_create(int32_t channels, double sample_rate);
/// Adds a source the plan's clips can refer to (retained). Returns its index.
int32_t jm_plan_add_source(jm_plan *_Nonnull plan, jm_source *_Nonnull source);
/// Adds a track. Gain is linear. Returns its index.
int32_t jm_plan_add_track(jm_plan *_Nonnull plan, float gain, bool mute);
/// Adds a clip: `length` frames of `source` from `source_start`, placed at `timeline_start`.
/// Fades are in frames and lie inside the clip. Gain is linear.
void jm_plan_add_clip(jm_plan *_Nonnull plan, int32_t track, int32_t source, int64_t source_start,
                      int64_t timeline_start, int64_t length, float gain,
                      int64_t fade_in, int64_t fade_out, jm_fade_shape shape);
/// Sorts and freezes the plan. Must be called before rendering or publishing.
void jm_plan_finalize(jm_plan *_Nonnull plan);
void jm_plan_release(jm_plan *_Nullable plan);
/// The end of the last clip, in frames.
int64_t jm_plan_length(const jm_plan *_Nonnull plan);
int32_t jm_plan_channels(const jm_plan *_Nonnull plan);

/// Renders `frames` frames from `start` as interleaved float. Deterministic: the
/// same plan and range always give the same bits, whatever the block size.
/// Not for the audio thread. Returns false if the plan isn't finalized.
bool jm_render(const jm_plan *_Nonnull plan, int64_t start, int64_t frames, float *_Nonnull interleaved);

// MARK: Insert chains (Audio Units)
//
// A track can run its audio through a chain of Audio Units before its gain. Chains run in
// the render worker or an offline render, never on the device thread. Each chain keeps
// its own stream position: rendering from anywhere other than where it left off resets
// the units and pre-rolls `preroll` frames, and the chain's total latency is compensated,
// so the track stays in time with the others. Units process fixed 512-frame quanta, so
// the output doesn't depend on the caller's block size.

/// One Audio Unit instance, set up by the caller: non-interleaved float32 at the plan's
/// rate and channel count on input and output bus 0, maximum frames per slice >= 512,
/// initialized. Takes over the unit's input render callback. `release(context)` runs
/// when the last chain using it is gone (on whatever thread drops it).
typedef struct jm_unit jm_unit;
jm_unit *_Nonnull jm_unit_create(AudioUnit _Nonnull unit, int32_t channels, void *_Nullable context,
                                 void (*_Nullable release)(void *_Nullable context));
/// An effect that isn't an Audio Unit (a VST 3 or CLAP plugin held by a helper process).
/// `process` gets planar input and writes planar output, `channels` × `frames` floats each
/// (channel c at c × frames), and returns false when the block wasn't processed; the chain then
/// lets the input through, delayed by the unit's latency so the track stays in time. It is
/// called from the render worker or an offline render, never the device thread, and may block.
jm_unit *_Nonnull jm_unit_create_processor(int32_t channels, void *_Nullable context,
                                           bool (*_Nonnull process)(void *_Nullable context, const float *_Nonnull in, float *_Nonnull out,
                                                                    int32_t channels, int32_t frames),
                                           void (*_Nullable reset)(void *_Nullable context),
                                           void (*_Nullable release)(void *_Nullable context));
void jm_unit_release(jm_unit *_Nullable unit);

typedef struct jm_chain jm_chain;
jm_chain *_Nonnull jm_chain_create(int32_t channels, int64_t preroll);
/// Appends a unit (retained) with its latency in frames.
void jm_chain_add(jm_chain *_Nonnull chain, jm_unit *_Nonnull unit, int64_t latency);
void jm_chain_release(jm_chain *_Nullable chain);
/// The sum of the units' latencies, in frames.
int64_t jm_chain_latency(const jm_chain *_Nonnull chain);
/// The last error a unit returned while rendering (0 if none). A failing unit passes its
/// input through.
OSStatus jm_chain_status(const jm_chain *_Nonnull chain);
/// Runs `track` through `chain` (retained) before its gain. Before finalize.
void jm_plan_set_chain(jm_plan *_Nonnull plan, int32_t track, jm_chain *_Nonnull chain);

// MARK: Engine

typedef struct jm_engine jm_engine;

/// `ring_frames` is how far the worker renders ahead (rounded up to a power of two).
jm_engine *_Nonnull jm_engine_create(int32_t channels, double sample_rate, int32_t ring_frames);
void jm_engine_destroy(jm_engine *_Nullable engine);
/// Publishes a finalized plan (retained). The worker uses it from its next block.
void jm_engine_set_plan(jm_engine *_Nonnull engine, jm_plan *_Nullable plan);
/// Starts (or restarts) playback at `frame`. Audio already rendered ahead is discarded.
void jm_engine_play(jm_engine *_Nonnull engine, int64_t frame);
void jm_engine_stop(jm_engine *_Nonnull engine);
bool jm_engine_is_playing(const jm_engine *_Nonnull engine);
/// The timeline frame the device has played up to.
int64_t jm_engine_playhead(const jm_engine *_Nonnull engine);
/// Output gain, linear. Applied on the audio thread.
void jm_engine_set_gain(jm_engine *_Nonnull engine, float gain);
/// The highest absolute sample per channel since the last call (then resets).
float jm_engine_take_peak(jm_engine *_Nonnull engine, int32_t channel);
/// Times the device asked for audio the worker hadn't rendered yet.
int64_t jm_engine_underruns(const jm_engine *_Nonnull engine);
/// True once the audio thread has taken the latest play request (the seek has happened).
bool jm_engine_seek_settled(const jm_engine *_Nonnull engine);
/// Blocks until the worker has rendered ahead (or `timeout_ms` passes). For tests.
bool jm_engine_wait_primed(jm_engine *_Nonnull engine, int32_t timeout_ms);

/// Audio thread: fills `channels` non-interleaved buffers with `frames` device frames.
void jm_engine_pull(jm_engine *_Nonnull engine, float *_Nonnull const *_Nonnull outs, int32_t channels,
                    int32_t frames) JM_NONBLOCKING;

/// Describes the device. Call while the device isn't running. `device_rate` is the
/// device's sample rate: when it differs from the project's, the render worker
/// resamples (the audio thread never does). Slot i writes engine channel
/// `sources[i]` to interleaved channel `channels[i]` of output buffer `buffers[i]`
/// (both from 0); up to 64 slots. Channels without a slot are silent.
void jm_engine_set_output(jm_engine *_Nonnull engine, double device_rate, const int32_t *_Nonnull buffers,
                          const int32_t *_Nonnull channels, const int32_t *_Nonnull sources, int32_t count);
/// The rate the engine is producing for (the project rate until set_output).
double jm_engine_output_rate(const jm_engine *_Nonnull engine);

/// An AudioDeviceIOProc for a HAL device whose output streams are float32
/// (interleaved or not), routed by jm_engine_set_output; client_data is the engine.
OSStatus jm_engine_ioproc(AudioObjectID device, const AudioTimeStamp *_Nonnull now,
                          const AudioBufferList *_Nonnull input_data, const AudioTimeStamp *_Nonnull input_time,
                          AudioBufferList *_Nonnull output_data, const AudioTimeStamp *_Nonnull output_time,
                          void *_Nullable client_data) JM_NONBLOCKING;

/// An AURenderCallback for an output unit fed non-interleaved float32; refCon is the engine.
OSStatus jm_engine_au_render(void *_Nonnull ref_con, AudioUnitRenderActionFlags *_Nonnull flags,
                             const AudioTimeStamp *_Nonnull time_stamp, UInt32 bus, UInt32 frames,
                             AudioBufferList *_Nullable io_data) JM_NONBLOCKING;

#ifdef __cplusplus
}
#endif

#endif
