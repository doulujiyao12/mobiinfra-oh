/*
 * Adapted from CANNKit samplecode-clientdemo-cpp.
 * Loads OMC model via HarmonyOS Neural Network Runtime (oh_nn) and runs inference.
 */

#ifndef HIAI_MODEL_MANAGER_H
#define HIAI_MODEL_MANAGER_H

#include "neural_network_runtime/neural_network_core.h"
#include <string>
#include <vector>
#include <cstdint>

class HIAIModelManager {
public:
    HIAIModelManager() = default;
    ~HIAIModelManager() { if (executor_ != nullptr) UnloadModel(); }
    // 单例封装 OH_NN executor，供 op/OMC A-B 测试复用同一套加载与推理流程。
    static HIAIModelManager &GetInstance();

    HIAIModelManager(const HIAIModelManager &) = delete;
    HIAIModelManager &operator=(const HIAIModelManager &) = delete;

    // Load model from memory buffer (.omc file content)
    OH_NN_ReturnCode LoadModelFromBuffer(uint8_t *modelData, size_t modelSize);

    // Prepare input/output tensors (shapes auto-detected from model)
    OH_NN_ReturnCode InitIOTensors();

    // Write float data to the i-th input tensor
    OH_NN_ReturnCode SetInputData(int idx, const float *data, size_t count);

    // Run inference synchronously
    OH_NN_ReturnCode RunModel();

    // Get output tensor data as flat float vector
    std::vector<float> GetOutputData(int idx);

    // Get output tensor shape
    std::vector<int64_t> GetOutputShape(int idx);

    // Get input/output counts and sizes
    int GetInputCount();
    size_t GetInputSize(int idx);
    int GetOutputCount();

    // Free all resources
    OH_NN_ReturnCode UnloadModel();

private:
    // deviceID_ 记录选中的 HIAI_F NPU；tensor 生命周期跟随 executor_，UnloadModel 统一释放。
    size_t deviceID_ {0};
    std::vector<NN_Tensor*> inputTensors_;
    std::vector<NN_Tensor*> outputTensors_;
    OH_NNExecutor *executor_ {nullptr};
};

#endif // HIAI_MODEL_MANAGER_H
