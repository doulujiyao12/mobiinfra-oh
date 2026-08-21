#ifndef OFFLINE_NPU_CHUNK_EXECUTOR_H
#define OFFLINE_NPU_CHUNK_EXECUTOR_H

#include "llm/npu_chunk_executor.hpp"

#include <memory>
#include <string>
#include <vector>

// HarmonyOS NNRT implementation of MobiInfer's platform-neutral offline OM
// chunk interface. One executor is retained per loaded visual chunk so model
// construction happens once during LLM loading, not once per image.
class OfflineNpuChunkExecutor final : public MNN::Transformer::INpuChunkExecutor {
public:
    OfflineNpuChunkExecutor();
    ~OfflineNpuChunkExecutor() override;

    bool loadChunk(int chunkIdx, const std::string& omPath) override;
    bool runChunk(int chunkIdx,
                  const std::vector<float>& hiddenInput,
                  const std::vector<float>& rotaryInput,
                  const std::vector<float>& maskInput,
                  std::vector<std::vector<float>>& outputs) override;
    size_t chunkSequenceLength(int chunkIdx) const override;
    void unload() override;

private:
    struct ChunkRuntime;
    std::vector<std::unique_ptr<ChunkRuntime>> chunks_;
};

#endif // OFFLINE_NPU_CHUNK_EXECUTOR_H
