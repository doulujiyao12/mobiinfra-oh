/*
 * Adapted from CANNKit samplecode-clientdemo-cpp.
 * Uses HarmonyOS Neural Network Runtime (oh_nn) to load and run OMC models.
 */

#include "HIAIModelManager.h"
#include <hilog/log.h>
#include <cstring>
#include <cstdlib>
#include "neural_network_runtime/neural_network_core.h"
#include "CANNKit/hiai_options.h"
#include "CANNKit/hiai_helper.h"

#undef LOG_DOMAIN
#define LOG_DOMAIN 0x0000
#undef LOG_TAG
#define LOG_TAG "HIAIModelMgr"

HIAIModelManager &HIAIModelManager::GetInstance() {
    static HIAIModelManager instance;
    return instance;
}

namespace {

size_t GetDeviceID() {
    size_t deviceID = 0;
    const size_t *allDevicesID = nullptr;
    uint32_t deviceCount = 0;
    OH_NN_ReturnCode ret = OH_NNDevice_GetAllDevicesID(&allDevicesID, &deviceCount);
    if (ret != OH_NN_SUCCESS || allDevicesID == nullptr) {
        OH_LOG_ERROR(LOG_APP, "OH_NNDevice_GetAllDevicesID failed");
        return deviceID;
    }
    for (uint32_t i = 0; i < deviceCount; i++) {
        const char *name = nullptr;
        ret = OH_NNDevice_GetName(allDevicesID[i], &name);
        if (ret != OH_NN_SUCCESS || name == nullptr) continue;
        OH_LOG_INFO(LOG_APP, "Found device: %{public}s", name);
        if (std::string(name) == "HIAI_F") {
            deviceID = allDevicesID[i];
            OH_LOG_INFO(LOG_APP, "Selected NPU device: %{public}s (id=%{public}zu)", name, deviceID);
            break;
        }
    }
    return deviceID;
}

void DestroyTensors(std::vector<NN_Tensor*> &tensors) {
    for (auto t : tensors) {
        OH_NNTensor_Destroy(&t);
    }
    tensors.clear();
}
} // anonymous namespace

// ================================================================
// Public API
// ================================================================

OH_NN_ReturnCode HIAIModelManager::LoadModelFromBuffer(uint8_t *modelData, size_t modelSize) {
    if (executor_ != nullptr) {
        OH_LOG_ERROR(LOG_APP, "executor already initialized");
        return OH_NN_FAILED;
    }
    // (compatibility check skipped — CANNKit header may not be available)

    // Build from buffer
    OH_NNCompilation *compilation = OH_NNCompilation_ConstructWithOfflineModelBuffer(modelData, modelSize);
    if (compilation == nullptr) {
        OH_LOG_ERROR(LOG_APP, "OH_NNCompilation_ConstructWithOfflineModelBuffer failed");
        return OH_NN_FAILED;
    }

    size_t deviceID = GetDeviceID();
    if (deviceID == 0) {
        OH_LOG_ERROR(LOG_APP, "GetDeviceID failed — no HIAI_F device found");
        OH_NNCompilation_Destroy(&compilation);
        return OH_NN_FAILED;
    }
    deviceID_ = deviceID;

    OH_NN_ReturnCode ret = OH_NNCompilation_SetDevice(compilation, deviceID);
    if (ret != OH_NN_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "OH_NNCompilation_SetDevice failed");
        OH_NNCompilation_Destroy(&compilation);
        return ret;
    }

    // Set NPU as preferred execution device (same as CANNKit demo)
    HiAI_BandMode bandMode = HiAI_BandMode::HIAI_BANDMODE_NORMAL;
    ret = HMS_HiAIOptions_SetBandMode(compilation, bandMode);
    OH_LOG_INFO(LOG_APP, "SetBandMode ret=%{public}d", ret);
    if (ret == OH_NN_SUCCESS) {
        std::vector<HiAI_ExecuteDevice> devices {HiAI_ExecuteDevice::HIAI_EXECUTE_DEVICE_NPU};
        ret = HMS_HiAIOptions_SetModelDeviceOrder(compilation, devices.data(), devices.size());
        OH_LOG_INFO(LOG_APP, "SetModelDeviceOrder(NPU) ret=%{public}d", ret);
    }

    // Set OM profiling options (standard practice from CANNKit demo)
    // {
    //     const char *out_path = "/data/storage/el2/base/haps/entry/files";
    //     HiAI_OmType omType = HIAI_OM_TYPE_PROFILING;
    //     ret = HMS_HiAIOptions_SetOmOptions(compilation, omType, out_path);
    //     OH_LOG_INFO(LOG_APP, "SetOmOptions ret=%{public}d", ret);
    // }

    ret = OH_NNCompilation_Build(compilation);
    if (ret != OH_NN_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "OH_NNCompilation_Build failed, ret=%{public}d", ret);
        OH_NNCompilation_Destroy(&compilation);
        return ret;
    }

    executor_ = OH_NNExecutor_Construct(compilation);
    if (executor_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "OH_NNExecutor_Construct failed");
        OH_NNCompilation_Destroy(&compilation);
        return OH_NN_FAILED;
    }
    OH_NNCompilation_Destroy(&compilation);
    OH_LOG_INFO(LOG_APP, "LoadModelFromBuffer success");
    return OH_NN_SUCCESS;
}

OH_NN_ReturnCode HIAIModelManager::InitIOTensors() {
    if (executor_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "executor not initialized");
        return OH_NN_FAILED;
    }
    if (!inputTensors_.empty()) { DestroyTensors(inputTensors_); }
    if (!outputTensors_.empty()) { DestroyTensors(outputTensors_); }

    // --- Inputs ---
    size_t inputCount = 0;
    OH_NN_ReturnCode ret = OH_NNExecutor_GetInputCount(executor_, &inputCount);
    if (ret != OH_NN_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "GetInputCount failed");
        return ret;
    }
    for (size_t i = 0; i < inputCount; ++i) {
        NN_TensorDesc *desc = OH_NNExecutor_CreateInputTensorDesc(executor_, i);
        NN_Tensor *t = OH_NNTensor_Create(deviceID_, desc);
        if (t) inputTensors_.push_back(t);
        if (desc) OH_NNTensorDesc_Destroy(&desc);
    }

    // --- Outputs ---
    size_t outputCount = 0;
    ret = OH_NNExecutor_GetOutputCount(executor_, &outputCount);
    if (ret != OH_NN_SUCCESS) return ret;
    for (size_t i = 0; i < outputCount; ++i) {
        NN_TensorDesc *desc = OH_NNExecutor_CreateOutputTensorDesc(executor_, i);
        NN_Tensor *t = OH_NNTensor_Create(deviceID_, desc);
        if (t) outputTensors_.push_back(t);
        if (desc) OH_NNTensorDesc_Destroy(&desc);
    }

    OH_LOG_INFO(LOG_APP, "InitIOTensors success: %{public}zu in, %{public}zu out",
                inputTensors_.size(), outputTensors_.size());
    return OH_NN_SUCCESS;
}

OH_NN_ReturnCode HIAIModelManager::SetInputData(int idx, const float *data, size_t count) {
    if (idx < 0 || (size_t)idx >= inputTensors_.size()) return OH_NN_FAILED;
    void *buf = OH_NNTensor_GetDataBuffer(inputTensors_[idx]);
    size_t sz = 0;
    OH_NNTensor_GetSize(inputTensors_[idx], &sz);
    if (!buf) return OH_NN_FAILED;
    size_t actualCount = sz / sizeof(float);
    if (count == 0) count = actualCount;  // auto-size
    if (count > actualCount) count = actualCount;
    std::memcpy(buf, data, count * sizeof(float));
    return OH_NN_SUCCESS;
}

OH_NN_ReturnCode HIAIModelManager::RunModel() {
    if (!executor_ || inputTensors_.empty() || outputTensors_.empty()) {
        OH_LOG_ERROR(LOG_APP, "model/io not ready");
        return OH_NN_FAILED;
    }
    OH_LOG_INFO(LOG_APP, "RunSync BEGIN");
    OH_NN_ReturnCode ret = OH_NNExecutor_RunSync(executor_,
        inputTensors_.data(), inputTensors_.size(),
        outputTensors_.data(), outputTensors_.size());
    OH_LOG_INFO(LOG_APP, "RunSync END ret=%{public}d", ret);
    return ret;
}

std::vector<float> HIAIModelManager::GetOutputData(int idx) {
    std::vector<float> out;
    if (idx < 0 || (size_t)idx >= outputTensors_.size()) return out;
    void *d = OH_NNTensor_GetDataBuffer(outputTensors_[idx]);
    size_t sz = 0;
    OH_NNTensor_GetSize(outputTensors_[idx], &sz);
    if (!d || sz == 0) return out;
    float *fd = static_cast<float*>(d);
    out.assign(fd, fd + sz / sizeof(float));
    return out;
}

std::vector<int64_t> HIAIModelManager::GetOutputShape(int idx) {
    std::vector<int64_t> shape;
    if (idx < 0 || (size_t)idx >= outputTensors_.size()) return shape;
    NN_TensorDesc *desc = OH_NNTensor_GetTensorDesc(outputTensors_[idx]);
    if (!desc) return shape;
    int32_t *dims = nullptr;
    size_t dimCount = 0;
    OH_NN_ReturnCode ret = OH_NNTensorDesc_GetShape(desc, &dims, &dimCount);
    if (ret == OH_NN_SUCCESS && dims) {
        shape.assign(dims, dims + dimCount);
        free(dims);
    }
    OH_NNTensorDesc_Destroy(&desc);
    return shape;
}

int HIAIModelManager::GetInputCount() {
    return (int)inputTensors_.size();
}

std::vector<int64_t> HIAIModelManager::GetInputShape(int idx) {
    std::vector<int64_t> shape;
    if (idx < 0 || (size_t)idx >= inputTensors_.size()) return shape;
    NN_TensorDesc *desc = OH_NNTensor_GetTensorDesc(inputTensors_[idx]);
    if (!desc) return shape;
    int32_t *dims = nullptr;
    size_t dimCount = 0;
    OH_NN_ReturnCode ret = OH_NNTensorDesc_GetShape(desc, &dims, &dimCount);
    if (ret == OH_NN_SUCCESS && dims) {
        shape.assign(dims, dims + dimCount);
        free(dims);
    }
    OH_NNTensorDesc_Destroy(&desc);
    return shape;
}

size_t HIAIModelManager::GetInputSize(int idx) {
    if (idx < 0 || (size_t)idx >= inputTensors_.size()) return 0;
    size_t sz = 0;
    OH_NNTensor_GetSize(inputTensors_[idx], &sz);
    return sz;
}

int HIAIModelManager::GetOutputCount() {
    return (int)outputTensors_.size();
}

OH_NN_ReturnCode HIAIModelManager::UnloadModel() {
    DestroyTensors(inputTensors_);
    DestroyTensors(outputTensors_);
    OH_NNExecutor_Destroy(&executor_);
    executor_ = nullptr;
    return OH_NN_SUCCESS;
}
