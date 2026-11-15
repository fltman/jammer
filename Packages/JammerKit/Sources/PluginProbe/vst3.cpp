// The VST 3 half of the probe: enter the bundle the way the format prescribes, ask its factory
// which audio classes it has, print them, leave. Only the interface headers of the SDK are
// used (pluginterfaces, MIT); the two .cpp files included below define the interface ids.
#if __has_include(<pluginterfaces/base/ipluginbase.h>)

#include <CoreFoundation/CoreFoundation.h>
#include <pluginterfaces/base/funknown.h>
#include <pluginterfaces/base/ipluginbase.h>
#include <cstdio>
#include <cstring>
#include <string>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include "pluginterfaces/base/funknown.cpp"
#include "pluginterfaces/base/coreiids.cpp"
#pragma clang diagnostic pop

std::string probeJSON(const char *s);

namespace {
/// A fixed-size field that may not be terminated.
std::string field(const char *s, size_t max) { return std::string(s, strnlen(s, max)); }
}

int probeVST3(const char *path) {
    using namespace Steinberg;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(path), CFIndex(std::strlen(path)), true);
    CFBundleRef bundle = url ? CFBundleCreate(nullptr, url) : nullptr;
    if (!bundle) { std::fprintf(stderr, "not a bundle\n"); return 2; }
    if (!CFBundleLoadExecutable(bundle)) { std::fprintf(stderr, "the bundle's code couldn't be loaded\n"); return 2; }
    using Entry = bool (*)(CFBundleRef);
    using Exit = bool (*)();
    using Get = IPluginFactory *(*)();
    auto entry = reinterpret_cast<Entry>(CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleEntry")));
    auto leave = reinterpret_cast<Exit>(CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleExit")));
    auto get = reinterpret_cast<Get>(CFBundleGetFunctionPointerForName(bundle, CFSTR("GetPluginFactory")));
    if (!entry || !leave || !get) { std::fprintf(stderr, "no VST 3 entry points\n"); return 2; }
    if (!entry(bundle)) { std::fprintf(stderr, "bundleEntry failed\n"); return 2; }
    IPluginFactory *factory = get();
    if (!factory) { leave(); std::fprintf(stderr, "no plugin factory\n"); return 2; }
    PFactoryInfo info{};
    factory->getFactoryInfo(&info);
    IPluginFactory2 *factory2 = nullptr;
    if (factory->queryInterface(IPluginFactory2::iid, reinterpret_cast<void **>(&factory2)) != kResultOk) factory2 = nullptr;
    std::string out = "{\"format\":\"vst3\",\"plugins\":[";
    bool first = true;
    const int32 n = factory->countClasses();
    for (int32 i = 0; i < n; ++i) {
        PClassInfo c{};
        if (factory->getClassInfo(i, &c) != kResultOk) continue;
        // Audio processors only; the controller classes beside them aren't plugins to pick.
        if (field(c.category, PClassInfo::kCategorySize) != "Audio Module Class") continue;
        std::string vendor = field(info.vendor, PFactoryInfo::kNameSize), version, sub;
        PClassInfo2 c2{};
        if (factory2 && factory2->getClassInfo2(i, &c2) == kResultOk) {
            if (c2.vendor[0]) vendor = field(c2.vendor, PClassInfo2::kVendorSize);
            version = field(c2.version, PClassInfo2::kVersionSize);
            sub = field(c2.subCategories, PClassInfo2::kSubCategoriesSize);
        }
        char id[33];
        for (int b = 0; b < 16; ++b) std::snprintf(id + b * 2, 3, "%02X", static_cast<unsigned char>(c.cid[b]));
        if (!first) out += ",";
        first = false;
        out += "{\"id\":\"" + std::string(id) + "\",\"name\":" + probeJSON(field(c.name, PClassInfo::kNameSize).c_str()) + ",\"vendor\":" + probeJSON(vendor.c_str())
            + ",\"version\":" + probeJSON(version.c_str()) + ",\"features\":[";
        // "Fx|Reverb" → ["Fx","Reverb"]
        size_t at = 0;
        bool firstFeature = true;
        while (at <= sub.size() && !sub.empty()) {
            const size_t bar = sub.find('|', at);
            const std::string part = sub.substr(at, bar == std::string::npos ? std::string::npos : bar - at);
            if (!part.empty()) { if (!firstFeature) out += ","; firstFeature = false; out += probeJSON(part.c_str()); }
            if (bar == std::string::npos) break;
            at = bar + 1;
        }
        out += "]}";
    }
    out += "]}";
    if (factory2) factory2->release();
    factory->release();
    leave();
    std::puts(out.c_str());
    return 0;
}

#else
#include <cstdio>
int probeVST3(const char *) { std::fprintf(stderr, "this build has no VST 3 support\n"); return 2; }
#endif
