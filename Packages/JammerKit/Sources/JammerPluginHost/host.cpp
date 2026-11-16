// The C API of the plugin host: the same calls for every format.

#include "host_internal.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>

extern "C" {

void jph_close(jph_plugin *p) { delete p; }
bool jph_process(jph_plugin *p, const float *const *in, float *const *out, int32_t frames) { return p->process(in, out, frames); }
void jph_reset(jph_plugin *p) { p->reset(); }
int32_t jph_latency(jph_plugin *p) { return p->latency(); }
int32_t jph_param_count(jph_plugin *p) { return p->paramCount(); }
bool jph_param_info(jph_plugin *p, int32_t index, jph_param *out) { return p->paramInfo(index, out); }
bool jph_param_set(jph_plugin *p, uint32_t id, double value) { return p->paramSet(id, value); }
bool jph_param_get(jph_plugin *p, uint32_t id, double *value) { return p->paramGet(id, value); }

bool jph_state_save(jph_plugin *p, uint8_t **data, size_t *size) {
    std::vector<uint8_t> bytes;
    if (!p->stateSave(bytes)) return false;
    *size = bytes.size();
    *data = static_cast<uint8_t *>(std::malloc(std::max<size_t>(1, bytes.size())));
    if (!bytes.empty()) std::memcpy(*data, bytes.data(), bytes.size());
    return true;
}

bool jph_state_load(jph_plugin *p, const uint8_t *data, size_t size) { return p->stateLoad(data, size); }
void jph_free(void *data) { std::free(data); }

} // extern "C"
