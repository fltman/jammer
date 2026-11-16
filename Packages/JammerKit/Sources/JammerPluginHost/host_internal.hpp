// What each plugin format implements; the C API in host.cpp hands every call to one of these.
#pragma once

#include "jammer_plugin_host.h"

#include <vector>

struct jph_plugin {
    virtual ~jph_plugin() = default;
    virtual bool process(const float *const *in, float *const *out, int32_t frames) = 0;
    virtual void reset() = 0;
    virtual int32_t latency() = 0;
    virtual int32_t paramCount() = 0;
    virtual bool paramInfo(int32_t index, jph_param *out) = 0;
    virtual bool paramSet(uint32_t id, double value) = 0;
    virtual bool paramGet(uint32_t id, double *value) = 0;
    virtual bool stateSave(std::vector<uint8_t> &bytes) = 0;
    virtual bool stateLoad(const uint8_t *data, size_t size) = 0;
};
