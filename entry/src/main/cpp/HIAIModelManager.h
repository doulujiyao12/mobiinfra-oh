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

    // Get input tensor shape (used to derive the OM's fixed sequence length)
    std::vector<int64_t> GetInputShape(int idx);

    // Semantic routing helpers. The offline OMG input order is
    // [hidden_states_in, rotary_pos_emb, attention_mask] while the
    // engine-online order is [rotary_pos_emb, hidden_states_in, attention_mask],
    // so inputs must be routed by role (shape/name), never by a fixed index.
    // These return an empty string when the runtime does not expose a name.
    std::string GetInputName(int idx);
    std::string GetOutputName(int idx);
    // Total element count of the i-th input tensor (0 when unavailable).
    size_t GetInputElementCount(int idx);

    // Get input/output counts and sizes
    int GetInputCount();
    size_t GetInputSize(int idx);
    int GetOutputCount();

    // Free all resources
    OH_NN_ReturnCode UnloadModel();

private:
    size_t deviceID_ {0};
    std::vector<NN_Tensor*> inputTensors_;
    std::vector<NN_Tensor*> outputTensors_;
    OH_NNExecutor *executor_ {nullptr};
};

#endif // HIAI_MODEL_MANAGER_H
