#include "kernel_operator.h"

using namespace AscendC;

class KernelLayerNormCustom {
public:
    __aicore__ inline KernelLayerNormCustom() {}

    __aicore__ inline void Init(
        GM_ADDR x,
        GM_ADDR gamma,
        GM_ADDR beta,
        GM_ADDR y,
        uint32_t totalLength,
        uint32_t storageNormSize,
        uint32_t originalNormSize,
        float invOriginalNormSize,
        float epsilon)
    {
        totalLength_ = totalLength;
        storageNormSize_ = storageNormSize;
        originalNormSize_ = originalNormSize;
        invOriginalNormSize_ = invOriginalNormSize;
        epsilon_ = epsilon;
        rowCount_ = (storageNormSize_ > 0U) ? (totalLength_ / storageNormSize_) : 0U;

        xGm.SetGlobalBuffer((__gm__ DTYPE_X *)x, totalLength_);
        gammaGm.SetGlobalBuffer((__gm__ DTYPE_GAMMA *)gamma, storageNormSize_);
        betaGm.SetGlobalBuffer((__gm__ DTYPE_BETA *)beta, storageNormSize_);
        yGm.SetGlobalBuffer((__gm__ DTYPE_Y *)y, totalLength_);
    }

    __aicore__ inline void Process()
    {
        if (storageNormSize_ == 0U || originalNormSize_ == 0U || rowCount_ == 0U) {
            return;
        }

        const uint32_t blockNum = AscendC::GetBlockNum();
        const uint32_t blockIdx = AscendC::GetBlockIdx();
        for (uint32_t row = blockIdx; row < rowCount_; row += blockNum) {
            ComputeRow(row);
        }
    }

private:
    __aicore__ inline float InvSqrt(float value) const
    {
        if (value <= 0.0f) {
            return 0.0f;
        }

        union {
            float f;
            int32_t i;
        } conv;

        conv.f = value;
        conv.i = 0x5f3759df - (conv.i >> 1);
        float result = conv.f;
        const float halfValue = 0.5f * value;
        result = result * (1.5f - halfValue * result * result);
        result = result * (1.5f - halfValue * result * result);
        return result;
    }

    __aicore__ inline void ComputeRow(uint32_t row)
    {
        const uint64_t rowOffset = static_cast<uint64_t>(row) * static_cast<uint64_t>(storageNormSize_);

        float sum = 0.0f;
        for (uint32_t i = 0; i < storageNormSize_; ++i) {
            sum += static_cast<float>(xGm.GetValue(rowOffset + i));
        }
        const float mean = sum * invOriginalNormSize_;

        float varianceSum = 0.0f;
        for (uint32_t i = 0; i < storageNormSize_; ++i) {
            const float centered = static_cast<float>(xGm.GetValue(rowOffset + i)) - mean;
            varianceSum += centered * centered;
        }
        const float variance = varianceSum * invOriginalNormSize_;
        const float invStd = InvSqrt(variance + epsilon_);

        for (uint32_t i = 0; i < storageNormSize_; ++i) {
            const float xValue = static_cast<float>(xGm.GetValue(rowOffset + i));
            const float gammaValue = static_cast<float>(gammaGm.GetValue(i));
            const float betaValue = static_cast<float>(betaGm.GetValue(i));
            const float normalized = (xValue - mean) * invStd;
            yGm.SetValue(rowOffset + i, static_cast<DTYPE_Y>(normalized * gammaValue + betaValue));
        }
    }

private:
    AscendC::GlobalTensor<DTYPE_X> xGm;
    AscendC::GlobalTensor<DTYPE_GAMMA> gammaGm;
    AscendC::GlobalTensor<DTYPE_BETA> betaGm;
    AscendC::GlobalTensor<DTYPE_Y> yGm;
    uint32_t totalLength_ = 0;
    uint32_t storageNormSize_ = 0;
    uint32_t originalNormSize_ = 0;
    uint32_t rowCount_ = 0;
    float invOriginalNormSize_ = 0.0f;
    float epsilon_ = 0.0f;
};

extern "C" __global__ __aicore__ void layer_norm_custom(
    GM_ADDR x,
    GM_ADDR gamma,
    GM_ADDR beta,
    GM_ADDR y,
    GM_ADDR workspace,
    GM_ADDR tiling)
{
    GET_TILING_DATA(tiling_data, tiling);
    KernelLayerNormCustom op;
    op.Init(
        x,
        gamma,
        beta,
        y,
        tiling_data.total_length,
        tiling_data.storage_norm_size,
        tiling_data.original_norm_size,
        tiling_data.inv_original_norm_size,
        tiling_data.epsilon);
    op.Process();
}
