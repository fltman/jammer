// jammer-plugin-probe: loads ONE plugin bundle and prints what is in it as JSON, then exits.
// Third-party code runs here and nowhere else during a scan: if the bundle crashes or hangs
// while it is loaded, it is this process that dies or is killed, and Jämmer notes the plugin
// as failed and goes on.
//
//   jammer-plugin-probe clap /path/to/Plugin.clap      (or: vst3 /path/to/Plugin.vst3)
//   → {"format":"clap","plugins":[{"id":"…","name":"…","vendor":"…","version":"…","features":["…"]}]}
// Exit codes: 0 found, 2 not a plugin of that format (stderr says why), 64 usage.

#include <CoreFoundation/CoreFoundation.h>
#include <clap/clap.h>
#include <cstdio>
#include <cstring>
#include <string>

int probeVST3(const char *path);
std::string probeJSON(const char *s);

namespace {

std::string json(const char *s) { return probeJSON(s); }

} // namespace

std::string probeJSON(const char *s) {
    std::string out = "\"";
    for (const unsigned char *p = reinterpret_cast<const unsigned char *>(s ? s : ""); *p; ++p) {
        if (*p == '"' || *p == '\\') { out += '\\'; out += char(*p); }
        else if (*p < 0x20) { char b[8]; std::snprintf(b, sizeof b, "\\u%04x", *p); out += b; }
        else out += char(*p);
    }
    return out + "\"";
}

namespace {

int fail(const char *why) {
    std::fprintf(stderr, "%s\n", why);
    return 2;
}

int probeCLAP(const char *path) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(path), CFIndex(std::strlen(path)), true);
    CFBundleRef bundle = url ? CFBundleCreate(nullptr, url) : nullptr;
    if (!bundle) return fail("not a bundle");
    if (!CFBundleLoadExecutable(bundle)) return fail("the bundle's code couldn't be loaded");
    auto *entry = static_cast<const clap_plugin_entry_t *>(CFBundleGetDataPointerForName(bundle, CFSTR("clap_entry")));
    if (!entry) return fail("no clap_entry");
    if (!clap_version_is_compatible(entry->clap_version)) return fail("an incompatible CLAP version");
    if (!entry->init || !entry->init(path)) return fail("clap_entry.init failed");
    auto *factory = static_cast<const clap_plugin_factory_t *>(entry->get_factory(CLAP_PLUGIN_FACTORY_ID));
    if (!factory) { entry->deinit(); return fail("no plugin factory"); }
    std::string out = "{\"format\":\"clap\",\"plugins\":[";
    const uint32_t n = factory->get_plugin_count(factory);
    bool first = true;
    for (uint32_t i = 0; i < n; ++i) {
        const clap_plugin_descriptor_t *d = factory->get_plugin_descriptor(factory, i);
        if (!d || !d->id || !d->id[0]) continue;
        if (!first) out += ",";
        first = false;
        out += "{\"id\":" + json(d->id) + ",\"name\":" + json(d->name) + ",\"vendor\":" + json(d->vendor) + ",\"version\":" + json(d->version) + ",\"features\":[";
        for (const char *const *f = d->features; f && *f; ++f) { if (f != d->features) out += ","; out += json(*f); }
        out += "]}";
    }
    out += "]}";
    entry->deinit();
    std::puts(out.c_str());
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    if (argc != 3) { std::fprintf(stderr, "usage: jammer-plugin-probe clap|vst3 <bundle>\n"); return 64; }
    if (std::strcmp(argv[1], "clap") == 0) return probeCLAP(argv[2]);
    if (std::strcmp(argv[1], "vst3") == 0) return probeVST3(argv[2]);
    std::fprintf(stderr, "unknown format %s\n", argv[1]);
    return 64;
}
