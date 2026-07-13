//
//  npu_chunk_executor.hpp
//  Abstract interface for pluggable NPU chunk execution.
//  The HarmonyOS app layer implements this with HIAIModelManager (OM).
//  MNN engine calls through the vtable — no HarmonyOS headers needed here.
//

#ifndef NPU_CHUNK_EXECUTOR_HPP
#define NPU_CHUNK_EXECUTOR_HPP

#include <cstddef>
#include <memory>
#include <string>
#include <vector>

namespace MNN {
namespace Transformer {

class INpuChunkExecutor {
public:
    virtual ~INpuChunkExecutor() = default;

    // Load a single OM chunk file. Called once per chunk during Omni::load().
    // The implementation may read+parse eagerly or defer to runChunk().
    virtual bool loadChunk(int chunkIdx, const std::string& omPath) = 0;

    // Run one chunk.
    //   chunkIdx:     0-based chunk index in the pipeline.
    //   hiddenInput:  flat float [S * hiddenDim]  (row-major)
    //   rotaryInput:  flat float [2 * S * headDim]
    //   maskInput:    flat float [S * S]
    //   outputs[0]:   hidden_states  [S * hiddenDim]
    //   outputs[1+]:  deepstack outputs (omni.cpp duplicates output[0] when
    //                 the OM model consolidates hidden==deepstack)
    // Returns false on error.
    virtual bool runChunk(int chunkIdx,
                          const std::vector<float>& hiddenInput,
                          const std::vector<float>& rotaryInput,
                          const std::vector<float>& maskInput,
                          std::vector<std::vector<float>>& outputs) = 0;

    // Release all resources held by this executor.
    virtual void unload() = 0;
};

} // namespace Transformer
} // namespace MNN

#endif // NPU_CHUNK_EXECUTOR_HPP
