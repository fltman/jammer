// Hosting one VST 3 or CLAP effect: load, activate, process blocks, parameters, state, latency.
// Plain C, so the audio host process and its tests use the same thing. Nothing here is
// thread-safe: one thread drives one plugin (in the host process, that process's own loop).
// This code only ever runs in a helper process, never in Jämmer itself.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct jph_plugin jph_plugin;

typedef struct jph_param {
    uint32_t id;
    char name[256];
    char module[256];
    double min, max, value, initial;
    bool stepped, readonly, hidden;
} jph_param;

/// Loads `bundle`, makes the plugin `id` and readies it for `channels` (1 or 2) at `sampleRate`
/// in blocks of at most `maxFrames`. NULL on failure, with the reason in `error`.
jph_plugin *_Nullable jph_clap_open(const char *_Nonnull bundle, const char *_Nonnull id, double sampleRate, int32_t channels,
                                    int32_t maxFrames, char *_Nonnull error, size_t errorSize);
/// The same for a VST 3 plugin; `id` is its class id as 32 hex digits. Parameters are in the plugin's
/// own units when it has any (0 to 1 otherwise). Fails in words in a build without the VST 3 headers.
jph_plugin *_Nullable jph_vst3_open(const char *_Nonnull bundle, const char *_Nonnull id, double sampleRate, int32_t channels,
                                    int32_t maxFrames, char *_Nonnull error, size_t errorSize);
void jph_close(jph_plugin *_Nullable plugin);

/// Planar float in and out, `frames` <= maxFrames. False when the plugin reports an error
/// (the output is then the input, unchanged).
bool jph_process(jph_plugin *_Nonnull plugin, const float *_Nonnull const *_Nonnull in, float *_Nonnull const *_Nonnull out, int32_t frames);
/// Forgets tails and delay lines, as before the first block.
void jph_reset(jph_plugin *_Nonnull plugin);
/// Frames the output lags the input.
int32_t jph_latency(jph_plugin *_Nonnull plugin);

int32_t jph_param_count(jph_plugin *_Nonnull plugin);
bool jph_param_info(jph_plugin *_Nonnull plugin, int32_t index, jph_param *_Nonnull out);
/// Takes effect at the start of the next block (or at once when nothing is processing).
bool jph_param_set(jph_plugin *_Nonnull plugin, uint32_t id, double value);
bool jph_param_get(jph_plugin *_Nonnull plugin, uint32_t id, double *_Nonnull value);

/// The plugin's saved state. `*data` is malloc'd; free it with jph_free. False when the plugin has none.
bool jph_state_save(jph_plugin *_Nonnull plugin, uint8_t *_Nullable *_Nonnull data, size_t *_Nonnull size);
bool jph_state_load(jph_plugin *_Nonnull plugin, const uint8_t *_Nonnull data, size_t size);
void jph_free(void *_Nullable data);

#ifdef __cplusplus
}
#endif
