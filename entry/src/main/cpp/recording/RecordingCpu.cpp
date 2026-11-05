#include "RecordingCpu.h"
#include <sched.h>
#include <unistd.h>
#include <algorithm>

namespace {
napi_value AvailableCpus(napi_env env, napi_callback_info) {
    const long online = sysconf(_SC_NPROCESSORS_ONLN);
    int available = online > 0 ? static_cast<int>(online) : 4;
    cpu_set_t mask;
    CPU_ZERO(&mask);
    if (sched_getaffinity(0, sizeof(mask), &mask) == 0) {
        int allowed = 0;
        for (int cpu = 0; cpu < CPU_SETSIZE; ++cpu) {
            if (CPU_ISSET(cpu, &mask)) ++allowed;
        }
        if (allowed > 0) available = std::min(available, allowed);
    }
    napi_value value;
    napi_create_int32(env, std::max(1, available), &value);
    return value;
}
}  // namespace

void RegisterRecordingCpu(napi_env env, napi_value exports) {
    napi_property_descriptor property = {
        "recordingAvailableCpus", nullptr, AvailableCpus, nullptr, nullptr, nullptr, napi_default, nullptr};
    napi_define_properties(env, exports, 1, &property);
}
