#include "OfflineNpuChunkExecutor.h"

#include "CANNKit/hiai_helper.h"
#include "CANNKit/hiai_options.h"
#include "neural_network_runtime/neural_network_core.h"

#include <hilog/log.h>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <limits>

#undef LOG_DOMAIN
#define LOG_DOMAIN 0x0000
#undef LOG_TAG
#define LOG_TAG "MobiInfra"
#define OFFLINE_LOGI(fmt, ...) OH_LOG_INFO(LOG_APP, "[MobiInfra][OfflineNPU] " fmt, ##__VA_ARGS__)
#define OFFLINE_LOGE(fmt, ...) OH_LOG_ERROR(LOG_APP, "[MobiInfra][OfflineNPU] " fmt, ##__VA_ARGS__)

namespace {

struct TensorMetadata {
    std::string name;
    OH_NN_DataType dataType = OH_NN_UNKNOWN;
    OH_NN_Format format = OH_NN_FORMAT_NONE;
    bool formatAvailable = false;
    std::vector<int32_t> shape;
    size_t elementCount = 0;
    size_t byteSize = 0;
};

void traceOffline(const char* level, int chunkIdx, const std::string& message) {
    std::printf("[OFFLINE_NPU] level=%s chunk=%d %s\n", level, chunkIdx, message.c_str());
    std::fflush(stdout);
}

void traceDiagnostic(int chunkIdx, const std::string& message) {
    OFFLINE_LOGI("chunk=%{public}d %{public}s", chunkIdx, message.c_str());
    traceOffline("diagnostic", chunkIdx, message);
}

std::string nnReturnCodeString(OH_NN_ReturnCode ret) {
    switch (ret) {
        case OH_NN_SUCCESS:
            return "OH_NN_SUCCESS(0)";
        case OH_NN_FAILED:
            return "OH_NN_FAILED(1)";
        case OH_NN_INVALID_PARAMETER:
            return "OH_NN_INVALID_PARAMETER(" + std::to_string(static_cast<int>(ret)) + ")";
        case OH_NN_MEMORY_ERROR:
            return "OH_NN_MEMORY_ERROR(" + std::to_string(static_cast<int>(ret)) + ")";
        case OH_NN_OPERATION_FORBIDDEN:
            return "OH_NN_OPERATION_FORBIDDEN(" + std::to_string(static_cast<int>(ret)) + ")";
        case OH_NN_NULL_PTR:
            return "OH_NN_NULL_PTR(" + std::to_string(static_cast<int>(ret)) + ")";
        default:
            return "OH_NN_RETURN_CODE(" + std::to_string(static_cast<int>(ret)) + ")";
    }
}

std::string fileSizeString(const std::string& path) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream.is_open()) return "unavailable";
    const std::streampos position = stream.tellg();
    if (position == std::streampos(-1)) return "unavailable";
    return std::to_string(static_cast<unsigned long long>(static_cast<std::streamoff>(position)));
}

std::string readProcValues(const char* path, const std::vector<std::string>& keys) {
    std::ifstream stream(path);
    if (!stream.is_open()) return "unavailable";
    std::string result;
    std::string line;
    while (std::getline(stream, line)) {
        for (const std::string& key : keys) {
            if (line.rfind(key, 0) != 0) continue;
            if (!result.empty()) result += ',';
            result += line;
            break;
        }
    }
    return result.empty() ? "unavailable" : result;
}

std::string resourceSnapshotString(const char* stage) {
    return "resource_snapshot stage=" + std::string(stage) +
        " self={" + readProcValues("/proc/self/status", {"VmSize:", "VmRSS:", "VmData:", "VmSwap:"}) +
        "} system={" + readProcValues("/proc/meminfo", {"MemAvailable:", "SwapFree:", "CmaFree:"}) + "}";
}

std::string floatVectorSummary(const char* role, const TensorMetadata& metadata,
                               const std::vector<float>& values) {
    size_t finiteCount = 0;
    size_t nanCount = 0;
    size_t positiveInfinityCount = 0;
    size_t negativeInfinityCount = 0;
    float minimum = std::numeric_limits<float>::infinity();
    float maximum = -std::numeric_limits<float>::infinity();
    uint64_t hash = 1469598103934665603ULL;
    for (float value : values) {
        uint32_t bits = 0;
        std::memcpy(&bits, &value, sizeof(bits));
        hash ^= static_cast<uint64_t>(bits);
        hash *= 1099511628211ULL;
        if (std::isnan(value)) {
            ++nanCount;
        } else if (std::isinf(value)) {
            if (value > 0.0f) {
                ++positiveInfinityCount;
            } else {
                ++negativeInfinityCount;
            }
        } else {
            ++finiteCount;
            minimum = std::min(minimum, value);
            maximum = std::max(maximum, value);
        }
    }
    char minimumText[32] = "unavailable";
    char maximumText[32] = "unavailable";
    if (finiteCount > 0) {
        std::snprintf(minimumText, sizeof(minimumText), "%.9g", static_cast<double>(minimum));
        std::snprintf(maximumText, sizeof(maximumText), "%.9g", static_cast<double>(maximum));
    }
    char hashText[24] = {};
    std::snprintf(hashText, sizeof(hashText), "%016llx", static_cast<unsigned long long>(hash));
    return "input_values role=" + std::string(role) +
        " name=" + (metadata.name.empty() ? "<empty>" : metadata.name) +
        " actual_elements=" + std::to_string(values.size()) +
        " expected_elements=" + std::to_string(metadata.elementCount) +
        " finite=" + std::to_string(finiteCount) +
        " nan=" + std::to_string(nanCount) +
        " pos_inf=" + std::to_string(positiveInfinityCount) +
        " neg_inf=" + std::to_string(negativeInfinityCount) +
        " min=" + minimumText + " max=" + maximumText + " fnv64=" + hashText;
}

std::string normalizeTensorName(std::string name) {
    std::transform(name.begin(), name.end(), name.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    size_t suffix = name.rfind(":0");
    if (suffix != std::string::npos && suffix + 2 == name.size()) {
        name.erase(suffix);
    }
    return name;
}

bool tensorNameContains(const TensorMetadata& metadata, const char* expected) {
    return normalizeTensorName(metadata.name).find(expected) != std::string::npos;
}

bool isFloatingPointTensor(const TensorMetadata& metadata) {
    return metadata.dataType == OH_NN_FLOAT16 || metadata.dataType == OH_NN_FLOAT32;
}

// Offline OMC generated with OMG's default use_origin_format=false exposes
// rank-3 sequence tensors as NCHW rank-4 tensors by inserting a singleton
// channel dimension. The flat element order is unchanged, so normalize only
// the logical shape used for tensor mapping and sequence-length validation.
bool logicalHiddenShape(const TensorMetadata& metadata, size_t& sequenceLength, size_t& hiddenSize) {
    const std::vector<int32_t>& shape = metadata.shape;
    if (shape.size() == 3 && shape[0] == 1 && shape[1] > 0 && shape[2] > 0) {
        sequenceLength = static_cast<size_t>(shape[1]);
        hiddenSize = static_cast<size_t>(shape[2]);
        return true;
    }
    if (metadata.formatAvailable && metadata.format == OH_NN_FORMAT_NCHW &&
        shape.size() == 4 && shape[0] == 1 && shape[1] == 1 && shape[2] > 0 && shape[3] > 0) {
        sequenceLength = static_cast<size_t>(shape[2]);
        hiddenSize = static_cast<size_t>(shape[3]);
        return true;
    }
    return false;
}

bool logicalRotaryShape(const TensorMetadata& metadata, size_t& sequenceLength, size_t& rotarySize) {
    const std::vector<int32_t>& shape = metadata.shape;
    if (shape.size() != 4 || shape[0] != 2 || shape[1] <= 0 || shape[2] != 1 || shape[3] <= 0) {
        return false;
    }
    sequenceLength = static_cast<size_t>(shape[1]);
    rotarySize = static_cast<size_t>(shape[3]);
    return true;
}

bool logicalMaskShape(const TensorMetadata& metadata, size_t& sequenceLength) {
    const std::vector<int32_t>& shape = metadata.shape;
    if (shape.size() == 3 && shape[0] == 1 && shape[1] > 0 && shape[1] == shape[2]) {
        sequenceLength = static_cast<size_t>(shape[1]);
        return true;
    }
    if (metadata.formatAvailable && metadata.format == OH_NN_FORMAT_NCHW &&
        shape.size() == 4 && shape[0] == 1 && shape[1] == 1 && shape[2] > 0 && shape[2] == shape[3]) {
        sequenceLength = static_cast<size_t>(shape[2]);
        return true;
    }
    return false;
}

int findUniqueInputByShape(const std::vector<TensorMetadata>& metadata,
                           const std::function<bool(const TensorMetadata&)>& predicate) {
    int match = -1;
    for (size_t i = 0; i < metadata.size(); ++i) {
        if (!predicate(metadata[i])) continue;
        if (match >= 0) return -1;
        match = static_cast<int>(i);
    }
    return match;
}

std::string shapeString(const std::vector<int32_t>& shape) {
    std::string result = "[";
    for (size_t i = 0; i < shape.size(); ++i) {
        if (i > 0) result += ',';
        result += std::to_string(shape[i]);
    }
    result += ']';
    return result;
}

std::string dataTypeString(OH_NN_DataType dataType) {
    std::string name = "unknown";
    if (dataType == OH_NN_FLOAT16) {
        name = "float16";
    } else if (dataType == OH_NN_FLOAT32) {
        name = "float32";
    }
    return name + "(" + std::to_string(static_cast<int>(dataType)) + ")";
}

std::string formatString(const TensorMetadata& metadata) {
    if (!metadata.formatAvailable) return "unavailable";
    std::string name = "unknown";
    if (metadata.format == OH_NN_FORMAT_NONE) {
        name = "none";
    } else if (metadata.format == OH_NN_FORMAT_NCHW) {
        name = "nchw";
    } else if (metadata.format == OH_NN_FORMAT_NHWC) {
        name = "nhwc";
    } else if (metadata.format == OH_NN_FORMAT_ND) {
        name = "nd";
    }
    return name + "(" + std::to_string(static_cast<int>(metadata.format)) + ")";
}

std::string tensorMetadataString(const char* ioKind, size_t index,
                                 const TensorMetadata& metadata, NN_Tensor* tensor) {
    size_t tensorByteSize = 0;
    const bool tensorByteSizeAvailable = tensor != nullptr &&
        OH_NNTensor_GetSize(tensor, &tensorByteSize) == OH_NN_SUCCESS;
    int tensorFd = -1;
    const bool tensorFdAvailable = tensor != nullptr &&
        OH_NNTensor_GetFd(tensor, &tensorFd) == OH_NN_SUCCESS;
    size_t tensorOffset = 0;
    const bool tensorOffsetAvailable = tensor != nullptr &&
        OH_NNTensor_GetOffset(tensor, &tensorOffset) == OH_NN_SUCCESS;
    const std::string displayName = metadata.name.empty() ? "<empty>" : metadata.name;
    return "tensor_desc io=" + std::string(ioKind) +
           " index=" + std::to_string(index) +
           " name=" + displayName +
           " dtype=" + dataTypeString(metadata.dataType) +
           " format=" + formatString(metadata) +
           " rank=" + std::to_string(metadata.shape.size()) +
           " shape=" + shapeString(metadata.shape) +
           " elements=" + std::to_string(metadata.elementCount) +
           " desc_bytes=" + std::to_string(metadata.byteSize) +
           " tensor_bytes=" + (tensorByteSizeAvailable ? std::to_string(tensorByteSize) : "unavailable") +
           " tensor_fd=" + (tensorFdAvailable ? std::to_string(tensorFd) : "unavailable") +
           " tensor_offset=" + (tensorOffsetAvailable ? std::to_string(tensorOffset) : "unavailable");
}

void traceTensorMetadata(int chunkIdx, const char* ioKind, size_t index,
                         const TensorMetadata& metadata, NN_Tensor* tensor) {
    const std::string message = tensorMetadataString(ioKind, index, metadata, tensor);
    OFFLINE_LOGI("chunk=%{public}d %{public}s", chunkIdx, message.c_str());
    traceOffline("tensor_desc", chunkIdx, message);
}

void appendFailedCheck(std::string& failedChecks, const char* checkName, bool passed) {
    if (passed) return;
    if (!failedChecks.empty()) failedChecks += ',';
    failedChecks += checkName;
}

bool readTensorMetadata(NN_TensorDesc* desc, TensorMetadata& metadata) {
    if (desc == nullptr) return false;
    const char* name = nullptr;
    if (OH_NNTensorDesc_GetName(desc, &name) == OH_NN_SUCCESS && name != nullptr) {
        metadata.name = name;
    }
    if (OH_NNTensorDesc_GetDataType(desc, &metadata.dataType) != OH_NN_SUCCESS) {
        return false;
    }
    metadata.formatAvailable = OH_NNTensorDesc_GetFormat(desc, &metadata.format) == OH_NN_SUCCESS;
    int32_t* dims = nullptr;
    size_t dimCount = 0;
    if (OH_NNTensorDesc_GetShape(desc, &dims, &dimCount) != OH_NN_SUCCESS || dims == nullptr) {
        return false;
    }
    metadata.shape.assign(dims, dims + dimCount);
    if (OH_NNTensorDesc_GetElementCount(desc, &metadata.elementCount) != OH_NN_SUCCESS ||
        OH_NNTensorDesc_GetByteSize(desc, &metadata.byteSize) != OH_NN_SUCCESS) {
        return false;
    }
    if (metadata.dataType != OH_NN_FLOAT16 && metadata.dataType != OH_NN_FLOAT32) {
        return metadata.elementCount > 0 && metadata.byteSize > 0;
    }
    size_t bytesPerElement = metadata.dataType == OH_NN_FLOAT16 ? sizeof(uint16_t) : sizeof(float);
    return metadata.elementCount > 0 && metadata.byteSize == metadata.elementCount * bytesPerElement;
}

uint16_t floatToHalf(float value) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    const uint32_t sign = (bits >> 16) & 0x8000u;
    const uint32_t mantissa = bits & 0x007fffffu;
    const int32_t exponent = static_cast<int32_t>((bits >> 23) & 0xffu) - 127 + 15;
    if (exponent <= 0) {
        if (exponent < -10) return static_cast<uint16_t>(sign);
        uint32_t normalized = mantissa | 0x00800000u;
        uint32_t shift = static_cast<uint32_t>(14 - exponent);
        uint32_t rounded = normalized + ((1u << (shift - 1)) - 1u) + ((normalized >> shift) & 1u);
        return static_cast<uint16_t>(sign | (rounded >> shift));
    }
    if (exponent >= 31) {
        if (((bits >> 23) & 0xffu) == 0xffu && mantissa != 0) {
            return static_cast<uint16_t>(sign | 0x7e00u);
        }
        return static_cast<uint16_t>(sign | 0x7c00u);
    }
    uint32_t roundedMantissa = mantissa + 0x00000fffu + ((mantissa >> 13) & 1u);
    uint32_t halfExponent = static_cast<uint32_t>(exponent);
    if (roundedMantissa & 0x00800000u) {
        roundedMantissa = 0;
        ++halfExponent;
        if (halfExponent >= 31) return static_cast<uint16_t>(sign | 0x7c00u);
    }
    return static_cast<uint16_t>(sign | (halfExponent << 10) | (roundedMantissa >> 13));
}

float halfToFloat(uint16_t value) {
    const uint32_t sign = static_cast<uint32_t>(value & 0x8000u) << 16;
    uint32_t exponent = (value >> 10) & 0x1fu;
    uint32_t mantissa = value & 0x03ffu;
    uint32_t bits = 0;
    if (exponent == 0) {
        if (mantissa == 0) {
            bits = sign;
        } else {
            int32_t normalizedExponent = -14;
            while ((mantissa & 0x0400u) == 0) {
                mantissa <<= 1;
                --normalizedExponent;
            }
            mantissa &= 0x03ffu;
            bits = sign | (static_cast<uint32_t>(normalizedExponent + 127) << 23) | (mantissa << 13);
        }
    } else if (exponent == 31) {
        bits = sign | 0x7f800000u | (mantissa << 13);
    } else {
        bits = sign | ((exponent - 15 + 127) << 23) | (mantissa << 13);
    }
    float result = 0.0f;
    std::memcpy(&result, &bits, sizeof(result));
    return result;
}

bool writeFloatTensor(NN_Tensor* tensor, const TensorMetadata& metadata,
                      const std::vector<float>& values, std::string& error) {
    if (values.size() != metadata.elementCount) {
        error = "input " + metadata.name + " element mismatch: expected=" +
                std::to_string(metadata.elementCount) + " actual=" + std::to_string(values.size()) +
                " shape=" + shapeString(metadata.shape);
        return false;
    }
    void* buffer = OH_NNTensor_GetDataBuffer(tensor);
    if (buffer == nullptr) {
        error = "input " + metadata.name + " has null buffer";
        return false;
    }
    size_t tensorSize = 0;
    if (OH_NNTensor_GetSize(tensor, &tensorSize) != OH_NN_SUCCESS || tensorSize < metadata.byteSize) {
        error = "input " + metadata.name + " buffer is smaller than tensor metadata";
        return false;
    }
    if (metadata.dataType == OH_NN_FLOAT32) {
        std::memcpy(buffer, values.data(), values.size() * sizeof(float));
        return true;
    }
    if (metadata.dataType == OH_NN_FLOAT16) {
        uint16_t* target = static_cast<uint16_t*>(buffer);
        for (size_t i = 0; i < values.size(); ++i) target[i] = floatToHalf(values[i]);
        return true;
    }
    error = "input " + metadata.name + " unsupported dtype=" + std::to_string(metadata.dataType);
    return false;
}

bool readFloatTensor(NN_Tensor* tensor, const TensorMetadata& metadata,
                     std::vector<float>& values, std::string& error) {
    void* buffer = OH_NNTensor_GetDataBuffer(tensor);
    if (buffer == nullptr) {
        error = "output " + metadata.name + " has null buffer";
        return false;
    }
    size_t tensorSize = 0;
    if (OH_NNTensor_GetSize(tensor, &tensorSize) != OH_NN_SUCCESS || tensorSize < metadata.byteSize) {
        error = "output " + metadata.name + " buffer is smaller than tensor metadata";
        return false;
    }
    values.resize(metadata.elementCount);
    if (metadata.dataType == OH_NN_FLOAT32) {
        std::memcpy(values.data(), buffer, values.size() * sizeof(float));
        return true;
    }
    if (metadata.dataType == OH_NN_FLOAT16) {
        const uint16_t* source = static_cast<const uint16_t*>(buffer);
        for (size_t i = 0; i < values.size(); ++i) values[i] = halfToFloat(source[i]);
        return true;
    }
    error = "output " + metadata.name + " unsupported dtype=" + std::to_string(metadata.dataType);
    return false;
}

bool selectHiaiDevice(size_t& deviceId) {
    const size_t* allDeviceIds = nullptr;
    uint32_t deviceCount = 0;
    if (OH_NNDevice_GetAllDevicesID(&allDeviceIds, &deviceCount) != OH_NN_SUCCESS || allDeviceIds == nullptr) {
        return false;
    }
    for (uint32_t i = 0; i < deviceCount; ++i) {
        const char* name = nullptr;
        if (OH_NNDevice_GetName(allDeviceIds[i], &name) == OH_NN_SUCCESS &&
            name != nullptr && std::string(name) == "HIAI_F") {
            deviceId = allDeviceIds[i];
            return true;
        }
    }
    return false;
}

} // namespace

struct OfflineNpuChunkExecutor::ChunkRuntime {
    size_t deviceId = 0;
    OH_NNExecutor* executor = nullptr;
    std::vector<NN_Tensor*> inputs;
    std::vector<NN_Tensor*> outputs;
    std::vector<TensorMetadata> inputMetadata;
    std::vector<TensorMetadata> outputMetadata;
    int hiddenInputIndex = -1;
    int rotaryInputIndex = -1;
    int maskInputIndex = -1;
    int hiddenOutputIndex = -1;

    ~ChunkRuntime() { release(); }

    void release() {
        for (NN_Tensor* tensor : inputs) OH_NNTensor_Destroy(&tensor);
        for (NN_Tensor* tensor : outputs) OH_NNTensor_Destroy(&tensor);
        inputs.clear();
        outputs.clear();
        inputMetadata.clear();
        outputMetadata.clear();
        if (executor != nullptr) OH_NNExecutor_Destroy(&executor);
        executor = nullptr;
    }
};

OfflineNpuChunkExecutor::OfflineNpuChunkExecutor() = default;

OfflineNpuChunkExecutor::~OfflineNpuChunkExecutor() {
    unload();
}

bool OfflineNpuChunkExecutor::loadChunk(int chunkIdx, const std::string& omPath) {
    if (chunkIdx < 0 || omPath.empty()) {
        traceOffline("error", chunkIdx, "invalid chunk index or OM path");
        return false;
    }
    if (static_cast<size_t>(chunkIdx) >= chunks_.size()) chunks_.resize(static_cast<size_t>(chunkIdx) + 1);
    if (chunks_[chunkIdx] != nullptr) {
        traceOffline("error", chunkIdx, "chunk is already loaded");
        return false;
    }
    const HiAI_Compatibility compatibility = HMS_HiAICompatibility_CheckFromFile(omPath.c_str());
    const char* hiaiVersion = HMS_HiAI_GetVersion();
    traceDiagnostic(chunkIdx, "om_probe path=" + omPath + " file_bytes=" + fileSizeString(omPath) +
                    " compatibility=" + std::to_string(static_cast<int>(compatibility)) +
                    " hiai_version=" + (hiaiVersion == nullptr ? "unavailable" : hiaiVersion));
    if (compatibility != HIAI_COMPATIBILITY_COMPATIBLE) {
        traceOffline("error", chunkIdx, "OM is incompatible with this device: " + omPath);
        return false;
    }

    std::unique_ptr<ChunkRuntime> runtime(new ChunkRuntime());
    if (!selectHiaiDevice(runtime->deviceId)) {
        traceOffline("error", chunkIdx, "HIAI_F device not found");
        return false;
    }
    traceDiagnostic(chunkIdx, "selected_device name=HIAI_F id=" + std::to_string(runtime->deviceId));

    OH_NNCompilation* compilation = OH_NNCompilation_ConstructWithOfflineModelFile(omPath.c_str());
    if (compilation == nullptr) {
        traceOffline("error", chunkIdx, "ConstructWithOfflineModelFile failed: " + omPath);
        return false;
    }
    OH_NN_ReturnCode ret = OH_NNCompilation_SetDevice(compilation, runtime->deviceId);
    traceDiagnostic(chunkIdx, "compilation_step name=SetDevice ret=" + nnReturnCodeString(ret));
    if (ret == OH_NN_SUCCESS) {
        HiAI_ExecuteDevice deviceOrder[] = {HiAI_ExecuteDevice::HIAI_EXECUTE_DEVICE_NPU};
        ret = HMS_HiAIOptions_SetModelDeviceOrder(compilation, deviceOrder, 1);
        traceDiagnostic(chunkIdx, "compilation_step name=SetModelDeviceOrder_NPU ret=" +
                        nnReturnCodeString(ret));
    }
    if (ret == OH_NN_SUCCESS) {
        ret = HMS_HiAIOptions_SetFallbackMode(compilation, HIAI_FALLBACK_DISABLED);
        traceDiagnostic(chunkIdx, "compilation_step name=SetFallbackMode_DISABLED ret=" +
                        nnReturnCodeString(ret));
    }
    if (ret == OH_NN_SUCCESS) {
        const OH_NN_ReturnCode bandModeRet = HMS_HiAIOptions_SetBandMode(compilation, HIAI_BANDMODE_NORMAL);
        traceDiagnostic(chunkIdx, "compilation_step name=SetBandMode_NORMAL ret=" +
                        nnReturnCodeString(bandModeRet));
        ret = OH_NNCompilation_Build(compilation);
        traceDiagnostic(chunkIdx, "compilation_step name=Build ret=" + nnReturnCodeString(ret));
    }
    if (ret != OH_NN_SUCCESS) {
        OH_NNCompilation_Destroy(&compilation);
        traceOffline("error", chunkIdx, "offline compilation build failed ret=" + std::to_string(ret));
        return false;
    }
    runtime->executor = OH_NNExecutor_Construct(compilation);
    OH_NNCompilation_Destroy(&compilation);
    if (runtime->executor == nullptr) {
        traceOffline("error", chunkIdx, "OH_NNExecutor_Construct failed");
        return false;
    }
    traceDiagnostic(chunkIdx, "executor_constructed=true");

    size_t inputCount = 0;
    size_t outputCount = 0;
    const OH_NN_ReturnCode inputCountRet = OH_NNExecutor_GetInputCount(runtime->executor, &inputCount);
    const OH_NN_ReturnCode outputCountRet = OH_NNExecutor_GetOutputCount(runtime->executor, &outputCount);
    const std::string countSummary = "executor_io_counts input_ret=" +
        std::to_string(static_cast<int>(inputCountRet)) + " inputs=" + std::to_string(inputCount) +
        " output_ret=" + std::to_string(static_cast<int>(outputCountRet)) +
        " outputs=" + std::to_string(outputCount);
    OFFLINE_LOGI("chunk=%{public}d %{public}s", chunkIdx, countSummary.c_str());
    traceOffline("tensor_desc", chunkIdx, countSummary);
    if (inputCountRet != OH_NN_SUCCESS || inputCount != 3 ||
        outputCountRet != OH_NN_SUCCESS || outputCount == 0) {
        traceOffline("error", chunkIdx, "unexpected OM input/output count; " + countSummary);
        return false;
    }
    for (size_t i = 0; i < inputCount; ++i) {
        NN_TensorDesc* desc = OH_NNExecutor_CreateInputTensorDesc(runtime->executor, i);
        TensorMetadata metadata;
        bool metadataOk = readTensorMetadata(desc, metadata);
        NN_Tensor* tensor = metadataOk && isFloatingPointTensor(metadata) ?
            OH_NNTensor_Create(runtime->deviceId, desc) : nullptr;
        if (desc != nullptr) OH_NNTensorDesc_Destroy(&desc);
        if (!metadataOk || !isFloatingPointTensor(metadata) || tensor == nullptr) {
            const std::string createError = "failed to create input tensor index=" + std::to_string(i) +
                " metadata_ok=" + (metadataOk ? "true" : "false") +
                " floating_dtype=" + (isFloatingPointTensor(metadata) ? "true" : "false") +
                " tensor_created=" + (tensor != nullptr ? "true" : "false");
            OFFLINE_LOGE("chunk=%{public}d %{public}s", chunkIdx, createError.c_str());
            traceOffline("error", chunkIdx, createError);
            return false;
        }
        traceTensorMetadata(chunkIdx, "input", i, metadata, tensor);
        if (tensorNameContains(metadata, "hidden_states_in")) runtime->hiddenInputIndex = static_cast<int>(i);
        if (tensorNameContains(metadata, "rotary_pos_emb")) runtime->rotaryInputIndex = static_cast<int>(i);
        if (tensorNameContains(metadata, "attention_mask")) runtime->maskInputIndex = static_cast<int>(i);
        runtime->inputMetadata.push_back(metadata);
        runtime->inputs.push_back(tensor);
    }
    for (size_t i = 0; i < outputCount; ++i) {
        NN_TensorDesc* desc = OH_NNExecutor_CreateOutputTensorDesc(runtime->executor, i);
        TensorMetadata metadata;
        bool metadataOk = readTensorMetadata(desc, metadata);
        NN_Tensor* tensor = metadataOk && isFloatingPointTensor(metadata) ?
            OH_NNTensor_Create(runtime->deviceId, desc) : nullptr;
        if (desc != nullptr) OH_NNTensorDesc_Destroy(&desc);
        if (!metadataOk || !isFloatingPointTensor(metadata) || tensor == nullptr) {
            const std::string createError = "failed to create output tensor index=" + std::to_string(i) +
                " metadata_ok=" + (metadataOk ? "true" : "false") +
                " floating_dtype=" + (isFloatingPointTensor(metadata) ? "true" : "false") +
                " tensor_created=" + (tensor != nullptr ? "true" : "false");
            OFFLINE_LOGE("chunk=%{public}d %{public}s", chunkIdx, createError.c_str());
            traceOffline("error", chunkIdx, createError);
            return false;
        }
        traceTensorMetadata(chunkIdx, "output", i, metadata, tensor);
        const std::string normalized = normalizeTensorName(metadata.name);
        if (normalized.find("hidden_states") != std::string::npos &&
            normalized.find("deepstack") == std::string::npos) {
            runtime->hiddenOutputIndex = static_cast<int>(i);
        }
        runtime->outputMetadata.push_back(metadata);
        runtime->outputs.push_back(tensor);
    }

    // OMG may reorder model inputs and some runtime versions do not preserve
    // ONNX names. Infer only when the rank/shape signature is unambiguous.
    if (runtime->hiddenInputIndex < 0) {
        runtime->hiddenInputIndex = findUniqueInputByShape(runtime->inputMetadata,
            [](const TensorMetadata& value) {
                size_t sequenceLength = 0;
                size_t hiddenSize = 0;
                return logicalHiddenShape(value, sequenceLength, hiddenSize) && sequenceLength != hiddenSize;
            });
    }
    if (runtime->rotaryInputIndex < 0) {
        runtime->rotaryInputIndex = findUniqueInputByShape(runtime->inputMetadata,
            [](const TensorMetadata& value) {
                size_t sequenceLength = 0;
                size_t rotarySize = 0;
                return logicalRotaryShape(value, sequenceLength, rotarySize);
            });
    }
    if (runtime->maskInputIndex < 0) {
        runtime->maskInputIndex = findUniqueInputByShape(runtime->inputMetadata,
            [](const TensorMetadata& value) {
                size_t sequenceLength = 0;
                return logicalMaskShape(value, sequenceLength);
            });
    }
    if (runtime->hiddenOutputIndex < 0 && !runtime->outputMetadata.empty() &&
        runtime->hiddenInputIndex >= 0 &&
        runtime->outputMetadata[0].elementCount ==
            runtime->inputMetadata[runtime->hiddenInputIndex].elementCount) {
        // The export route contract always emits hidden_states first. This
        // fallback covers runtimes that strip output names from offline OM.
        runtime->hiddenOutputIndex = 0;
    }
    const std::string mappingSummary = "tensor_mapping hidden_idx=" +
        std::to_string(runtime->hiddenInputIndex) + " rotary_idx=" +
        std::to_string(runtime->rotaryInputIndex) + " mask_idx=" +
        std::to_string(runtime->maskInputIndex) + " hidden_out_idx=" +
        std::to_string(runtime->hiddenOutputIndex);
    OFFLINE_LOGI("chunk=%{public}d %{public}s", chunkIdx, mappingSummary.c_str());
    traceOffline("tensor_desc", chunkIdx, mappingSummary);
    if (runtime->hiddenInputIndex < 0 || runtime->rotaryInputIndex < 0 || runtime->maskInputIndex < 0 ||
        runtime->hiddenOutputIndex < 0 ||
        runtime->hiddenInputIndex == runtime->rotaryInputIndex ||
        runtime->hiddenInputIndex == runtime->maskInputIndex ||
        runtime->rotaryInputIndex == runtime->maskInputIndex) {
        traceOffline("error", chunkIdx,
                     "cannot map required OM tensors by name or unique shape; " + mappingSummary);
        return false;
    }
    const TensorMetadata& hiddenMetadata = runtime->inputMetadata[runtime->hiddenInputIndex];
    const TensorMetadata& rotaryMetadata = runtime->inputMetadata[runtime->rotaryInputIndex];
    const TensorMetadata& maskMetadata = runtime->inputMetadata[runtime->maskInputIndex];
    size_t hiddenSequenceLength = 0;
    size_t hiddenSize = 0;
    size_t rotarySequenceLength = 0;
    size_t rotarySize = 0;
    size_t maskSequenceLength = 0;
    const bool hiddenShapeOk = logicalHiddenShape(hiddenMetadata, hiddenSequenceLength, hiddenSize);
    const bool rotaryShapeOk = logicalRotaryShape(rotaryMetadata, rotarySequenceLength, rotarySize);
    const bool maskShapeOk = logicalMaskShape(maskMetadata, maskSequenceLength);
    const bool hiddenRotarySequenceOk = hiddenShapeOk && rotaryShapeOk &&
        hiddenSequenceLength == rotarySequenceLength;
    const bool hiddenMaskSequenceOk = hiddenShapeOk && maskShapeOk &&
        hiddenSequenceLength == maskSequenceLength;
    std::string failedChecks;
    appendFailedCheck(failedChecks, "hidden_supported_logical_shape", hiddenShapeOk);
    appendFailedCheck(failedChecks, "rotary_supported_logical_shape", rotaryShapeOk);
    appendFailedCheck(failedChecks, "mask_supported_logical_shape", maskShapeOk);
    appendFailedCheck(failedChecks, "hidden_seq_eq_rotary_seq", hiddenRotarySequenceOk);
    appendFailedCheck(failedChecks, "hidden_seq_eq_mask_seq", hiddenMaskSequenceOk);
    if (!failedChecks.empty()) {
        const std::string shapeError =
            "offline OM input shapes do not share one fixed visual sequence length; "
            "expected={hidden:[1,S,D]|NCHW[1,1,S,D],rotary:[2,S,1,R],"
            "mask:[1,S,S]|NCHW[1,1,S,S]} "
            "actual={hidden:{format:" + formatString(hiddenMetadata) + ",shape:" +
            shapeString(hiddenMetadata.shape) + "},rotary:{format:" + formatString(rotaryMetadata) +
            ",shape:" + shapeString(rotaryMetadata.shape) + "},mask:{format:" +
            formatString(maskMetadata) + ",shape:" + shapeString(maskMetadata.shape) +
            "}} failed_checks=" + failedChecks;
        OFFLINE_LOGE("chunk=%{public}d %{public}s", chunkIdx, shapeError.c_str());
        traceOffline("error", chunkIdx, shapeError);
        return false;
    }
    for (size_t i = 0; i < runtime->outputMetadata.size(); ++i) {
        if (runtime->outputMetadata[i].elementCount != hiddenMetadata.elementCount) {
            traceOffline("error", chunkIdx, "offline OM output shape does not match hidden state at index " +
                         std::to_string(i));
            return false;
        }
    }

    std::string summary = "loaded path=" + omPath + " inputs=" + std::to_string(inputCount) +
                          " outputs=" + std::to_string(outputCount) +
                          " hidden_idx=" + std::to_string(runtime->hiddenInputIndex) +
                          " rotary_idx=" + std::to_string(runtime->rotaryInputIndex) +
                          " mask_idx=" + std::to_string(runtime->maskInputIndex) +
                          " hidden_out_idx=" + std::to_string(runtime->hiddenOutputIndex) +
                          " hidden_shape=" + shapeString(hiddenMetadata.shape) +
                          " fixed_sequence_length=" + std::to_string(hiddenSequenceLength);
    OFFLINE_LOGI("chunk=%{public}d %{public}s", chunkIdx, summary.c_str());
    traceOffline("ready", chunkIdx, summary);
    traceDiagnostic(chunkIdx, resourceSnapshotString("after_chunk_load"));
    chunks_[chunkIdx] = std::move(runtime);
    return true;
}

bool OfflineNpuChunkExecutor::runChunk(int chunkIdx,
                                      const std::vector<float>& hiddenInput,
                                      const std::vector<float>& rotaryInput,
                                      const std::vector<float>& maskInput,
                                      std::vector<std::vector<float>>& outputs) {
    if (chunkIdx < 0 || static_cast<size_t>(chunkIdx) >= chunks_.size() || chunks_[chunkIdx] == nullptr) {
        traceOffline("error", chunkIdx, "run requested for unloaded chunk");
        return false;
    }
    ChunkRuntime& runtime = *chunks_[chunkIdx];
    const long long runId = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    traceDiagnostic(chunkIdx, "run_begin run_id=" + std::to_string(runId) +
                    " inputs=" + std::to_string(runtime.inputs.size()) +
                    " outputs=" + std::to_string(runtime.outputs.size()));
    traceDiagnostic(chunkIdx, floatVectorSummary("hidden",
                    runtime.inputMetadata[runtime.hiddenInputIndex], hiddenInput));
    traceDiagnostic(chunkIdx, floatVectorSummary("rotary",
                    runtime.inputMetadata[runtime.rotaryInputIndex], rotaryInput));
    traceDiagnostic(chunkIdx, floatVectorSummary("mask",
                    runtime.inputMetadata[runtime.maskInputIndex], maskInput));
    traceDiagnostic(chunkIdx, resourceSnapshotString("before_input_copy"));
    std::string error;
    if (!writeFloatTensor(runtime.inputs[runtime.hiddenInputIndex],
                          runtime.inputMetadata[runtime.hiddenInputIndex], hiddenInput, error) ||
        !writeFloatTensor(runtime.inputs[runtime.rotaryInputIndex],
                          runtime.inputMetadata[runtime.rotaryInputIndex], rotaryInput, error) ||
        !writeFloatTensor(runtime.inputs[runtime.maskInputIndex],
                          runtime.inputMetadata[runtime.maskInputIndex], maskInput, error)) {
        OFFLINE_LOGE("chunk=%{public}d %{public}s", chunkIdx, error.c_str());
        traceOffline("error", chunkIdx, error);
        return false;
    }
    traceDiagnostic(chunkIdx, resourceSnapshotString("before_run_sync"));
    const std::chrono::steady_clock::time_point runStart = std::chrono::steady_clock::now();
    OH_NN_ReturnCode ret = OH_NNExecutor_RunSync(runtime.executor, runtime.inputs.data(), runtime.inputs.size(),
                                                  runtime.outputs.data(), runtime.outputs.size());
    const long long elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - runStart).count();
    if (ret != OH_NN_SUCCESS) {
        error = "RunSync failed run_id=" + std::to_string(runId) +
            " ret=" + nnReturnCodeString(ret) + " elapsed_ms=" + std::to_string(elapsedMs);
        OFFLINE_LOGE("chunk=%{public}d %{public}s", chunkIdx, error.c_str());
        traceOffline("error", chunkIdx, error);
        traceDiagnostic(chunkIdx, resourceSnapshotString("after_run_sync_failure"));
        return false;
    }
    traceDiagnostic(chunkIdx, "run_sync_complete run_id=" + std::to_string(runId) +
                    " ret=" + nnReturnCodeString(ret) + " elapsed_ms=" + std::to_string(elapsedMs));

    outputs.clear();
    outputs.resize(runtime.outputs.size());
    if (!readFloatTensor(runtime.outputs[runtime.hiddenOutputIndex],
                         runtime.outputMetadata[runtime.hiddenOutputIndex], outputs[0], error)) {
        traceOffline("error", chunkIdx, error);
        return false;
    }
    size_t nextOutput = 1;
    for (size_t i = 0; i < runtime.outputs.size(); ++i) {
        if (static_cast<int>(i) == runtime.hiddenOutputIndex) continue;
        if (!readFloatTensor(runtime.outputs[i], runtime.outputMetadata[i], outputs[nextOutput], error)) {
            traceOffline("error", chunkIdx, error);
            return false;
        }
        ++nextOutput;
    }
    traceOffline("exec_ok", chunkIdx, "RunSync succeeded");
    return true;
}

size_t OfflineNpuChunkExecutor::chunkSequenceLength(int chunkIdx) const {
    if (chunkIdx < 0 || static_cast<size_t>(chunkIdx) >= chunks_.size() || chunks_[chunkIdx] == nullptr) {
        return 0;
    }
    const ChunkRuntime& runtime = *chunks_[chunkIdx];
    if (runtime.hiddenInputIndex < 0 ||
        static_cast<size_t>(runtime.hiddenInputIndex) >= runtime.inputMetadata.size()) {
        return 0;
    }
    size_t sequenceLength = 0;
    size_t hiddenSize = 0;
    return logicalHiddenShape(runtime.inputMetadata[runtime.hiddenInputIndex], sequenceLength, hiddenSize) ?
        sequenceLength : 0;
}

void OfflineNpuChunkExecutor::unload() {
    if (!chunks_.empty()) traceOffline("unload", -1, "releasing all offline chunks");
    chunks_.clear();
}
