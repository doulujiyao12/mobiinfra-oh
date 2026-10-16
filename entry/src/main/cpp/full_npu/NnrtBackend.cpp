#include "NnrtBackend.hpp"
#include "PortBinding.hpp"
#include "CANNKit/hiai_helper.h"
#include "CANNKit/hiai_options.h"
#include "neural_network_runtime/neural_network_core.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <map>
#include <sstream>

namespace KirinFullNpu {
namespace {
struct Tensor {
    NN_Tensor* handle = nullptr;
    Port port;
    size_t bytes = 0;
};
struct DeviceGraph {
    OH_NNExecutor* executor = nullptr;
    std::vector<Tensor> inputs, outputs;
    std::vector<size_t> inputMap, outputMap;
    ~DeviceGraph() {
        for (auto& t : inputs) if (t.handle) OH_NNTensor_Destroy(&t.handle);
        for (auto& t : outputs) if (t.handle) OH_NNTensor_Destroy(&t.handle);
        if (executor) OH_NNExecutor_Destroy(&executor);
    }
};

class NnrtBackend final : public Backend {
public:
    explicit NnrtBackend(Log log) : log(std::move(log)) {}
    bool probe(const Graph& g, std::string& error) override { return load(g, error) != nullptr; }
    void release() override { resident.clear(); }
    bool run(const Graph& g, const std::vector<View>& inputs,
             std::vector<std::vector<float>>& outputs, std::string& error) override {
        auto* device = load(g, error);
        if (!device) return false;
        for (size_t i = 0; i < inputs.size(); ++i) {
            auto& dst = device->inputs[device->inputMap[i]];
            auto* buffer = OH_NNTensor_GetDataBuffer(dst.handle);
            size_t allocated = 0;
            if (!buffer || OH_NNTensor_GetSize(dst.handle, &allocated) != OH_NN_SUCCESS || allocated < dst.bytes) {
                error = "Missing or undersized device input buffer"; return false;
            }
            const auto& src = inputs[i];
            if (src.dtype == dst.port.dtype) std::memcpy(buffer, src.data, dst.bytes);
            else if (src.dtype == DType::F32 && dst.port.dtype == DType::F16) {
                auto* target = static_cast<uint16_t*>(buffer); auto* values = static_cast<const float*>(src.data);
                for (size_t j = 0; j < src.elements; ++j) {
                    target[j] = toHalf(values[j]);
                    if ((target[j] & 0x7fff) == 0x7c00 && std::isfinite(values[j]) && values[j] != std::numeric_limits<float>::lowest()) {
                        error = "Device FP16 input overflow: " + dst.port.name; return false;
                    }
                }
            } else if (src.dtype == DType::F16 && dst.port.dtype == DType::F32) {
                auto* target = static_cast<float*>(buffer); auto* values = static_cast<const uint16_t*>(src.data);
                for (size_t j = 0; j < src.elements; ++j) target[j] = fromHalf(values[j]);
            } else { error = "Integer device dtype differs from compiled interface"; return false; }
        }
        std::vector<NN_Tensor*> in, out;
        for (auto& t : device->inputs) in.push_back(t.handle);
        for (auto& t : device->outputs) out.push_back(t.handle);
        auto ret = OH_NNExecutor_RunSync(device->executor, in.data(), in.size(), out.data(), out.size());
        if (ret != OH_NN_SUCCESS) { error = "NNRT RunSync returned " + std::to_string(int(ret)); return false; }
        outputs.clear();
        for (size_t index : device->outputMap) {
            auto& src = device->outputs[index];
            const void* buffer = OH_NNTensor_GetDataBuffer(src.handle);
            size_t allocated = 0;
            if (!buffer || OH_NNTensor_GetSize(src.handle, &allocated) != OH_NN_SUCCESS || allocated < src.bytes) {
                error = "Missing or undersized device output buffer"; return false;
            }
            outputs.emplace_back(src.port.elements()); auto& values = outputs.back();
            if (src.port.dtype == DType::F32) std::memcpy(values.data(), buffer, src.bytes);
            else if (src.port.dtype == DType::F16) {
                auto* raw = static_cast<const uint16_t*>(buffer);
                for (size_t j = 0; j < values.size(); ++j) values[j] = fromHalf(raw[j]);
            } else { error = "Unsupported integer output boundary"; return false; }
        }
        return true;
    }
private:
    Log log;
    std::map<std::string, std::unique_ptr<DeviceGraph>> resident;

    DeviceGraph* load(const Graph& g, std::string& error) {
        auto previous = resident.find(g.name);
        if (previous != resident.end()) return previous->second.get();
        auto trace = [&](const std::string& text) { if (log) log("[FULL_NPU] graph=" + g.name + " " + text); };
        auto begin = std::chrono::steady_clock::now();
        auto compatibility = HMS_HiAICompatibility_CheckFromFile(g.path.c_str());
        if (compatibility != HIAI_COMPATIBILITY_COMPATIBLE) {
            error = "Offline graph incompatible with this device: " + g.name; return nullptr;
        }
        size_t deviceId = 0; bool selected = false; const size_t* ids = nullptr; uint32_t count = 0;
        if (OH_NNDevice_GetAllDevicesID(&ids, &count) == OH_NN_SUCCESS && ids)
            for (uint32_t i = 0; i < count; ++i) {
                const char* name = nullptr;
                if (OH_NNDevice_GetName(ids[i], &name) == OH_NN_SUCCESS && name && std::string(name) == "HIAI_F") {
                    deviceId = ids[i]; selected = true; break;
                }
            }
        if (!selected) { error = "HIAI_F NPU device not found"; return nullptr; }
        OH_NNCompilation* compilation = OH_NNCompilation_ConstructWithOfflineModelFile(g.path.c_str());
        if (!compilation) { error = "Cannot construct offline model: " + g.name; return nullptr; }
        auto ret = OH_NNCompilation_SetDevice(compilation, deviceId);
        HiAI_ExecuteDevice order[] = {HiAI_ExecuteDevice::HIAI_EXECUTE_DEVICE_NPU};
        if (ret == OH_NN_SUCCESS) ret = HMS_HiAIOptions_SetModelDeviceOrder(compilation, order, 1);
        if (ret == OH_NN_SUCCESS) ret = HMS_HiAIOptions_SetFallbackMode(compilation, HIAI_FALLBACK_DISABLED);
        if (ret == OH_NN_SUCCESS) ret = OH_NNCompilation_Build(compilation);
        if (ret != OH_NN_SUCCESS) {
            OH_NNCompilation_Destroy(&compilation); error = "Offline NNRT build failed: " + std::to_string(int(ret)); return nullptr;
        }
        std::unique_ptr<DeviceGraph> device(new DeviceGraph);
        device->executor = OH_NNExecutor_Construct(compilation); OH_NNCompilation_Destroy(&compilation);
        if (!device->executor) { error = "Cannot construct NNRT executor"; return nullptr; }
        for (bool input : {true, false}) {
            size_t count = 0;
            ret = input ? OH_NNExecutor_GetInputCount(device->executor, &count) : OH_NNExecutor_GetOutputCount(device->executor, &count);
            if (ret != OH_NN_SUCCESS || !count) { error = "Cannot query NNRT port count"; return nullptr; }
            auto& tensors = input ? device->inputs : device->outputs;
            for (size_t i = 0; i < count; ++i) {
                NN_TensorDesc* desc = input ? OH_NNExecutor_CreateInputTensorDesc(device->executor, i) : OH_NNExecutor_CreateOutputTensorDesc(device->executor, i);
                Tensor tensor; const char* name = nullptr; OH_NN_DataType type = OH_NN_UNKNOWN;
                int32_t* dims = nullptr; size_t rank = 0, bytes = 0;
                bool valid = desc && OH_NNTensorDesc_GetName(desc, &name) == OH_NN_SUCCESS && name &&
                    OH_NNTensorDesc_GetDataType(desc, &type) == OH_NN_SUCCESS &&
                    OH_NNTensorDesc_GetShape(desc, &dims, &rank) == OH_NN_SUCCESS && dims && rank &&
                    OH_NNTensorDesc_GetByteSize(desc, &bytes) == OH_NN_SUCCESS;
                if (valid) {
                    tensor.port.name = name; tensor.port.shape.assign(dims, dims + rank);
                    if (type == OH_NN_FLOAT32) tensor.port.dtype = DType::F32;
                    else if (type == OH_NN_FLOAT16) tensor.port.dtype = DType::F16;
                    else if (type == OH_NN_INT8) tensor.port.dtype = DType::I8;
                    else if (type == OH_NN_INT32) tensor.port.dtype = DType::I32;
                    else valid = false;
                    valid = valid && tensor.port.elements() && bytes == tensor.port.elements() * elementSize(tensor.port.dtype);
                }
                if (valid) tensor.handle = OH_NNTensor_Create(deviceId, desc);
                if (desc) OH_NNTensorDesc_Destroy(&desc);
                if (!valid || !tensor.handle) { error = "Invalid device tensor descriptor/allocation"; return nullptr; }
                tensor.bytes = bytes; tensors.push_back(tensor);
                trace(std::string("level=tensor_desc direction=") + (input ? "input " : "output ") + description(tensor.port) + " bytes=" + std::to_string(bytes));
            }
        }
        std::vector<Port> inputPorts, outputPorts;
        for (const auto& t : device->inputs) inputPorts.push_back(t.port);
        for (const auto& t : device->outputs) outputPorts.push_back(t.port);
        if (!bindPorts(g.inputs, inputPorts, {}, device->inputMap, error) ||
            !bindPorts(g.outputs, outputPorts, g.aliases, device->outputMap, error)) return nullptr;
        trace("level=graph_ready cpu_fallback=disabled load_ms=" + std::to_string(
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count()));
        auto* result = device.get(); resident[g.name] = std::move(device); return result;
    }
};
} // namespace
std::unique_ptr<Backend> createNnrtBackend(Log log) { return std::unique_ptr<Backend>(new NnrtBackend(std::move(log))); }
} // namespace KirinFullNpu
