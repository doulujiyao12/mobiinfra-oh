cmake_minimum_required(VERSION 3.5.0)
project(mnnllm)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(MNN_LIB_DIR ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH})
set(MNN_INCLUDE_DIR ${NATIVERENDER_ROOT_PATH}/include)

if("${OHOS_ARCH}" STREQUAL "x86_64")
    add_library(entry SHARED napi_stub.cpp)

    target_link_libraries(entry PUBLIC
        libace_napi.z.so
        libhilog_ndk.z.so
    )
else()
    set(FULL_NPU_SOURCES
        full_npu/FullNpuRuntime.cpp full_npu/FullNpuCache.cpp full_npu/NnrtBackend.cpp
        full_npu/tokenizer/tokenizer.cpp full_npu/tokenizer/unicode.cpp full_npu/tokenizer/unicode_data.cpp)
    add_library(entry SHARED napi_init.cpp HIAIModelManager.cpp OfflineNpuChunkExecutor.cpp ${FULL_NPU_SOURCES})
    # Keep the private tokenizer copy from interposing symbols inside libMNN.
    set_source_files_properties(${FULL_NPU_SOURCES} PROPERTIES COMPILE_OPTIONS "-fvisibility=hidden;-fno-rtti;-fno-exceptions")
    target_compile_features(entry PRIVATE cxx_std_17)
    target_include_directories(entry PRIVATE ${NATIVERENDER_ROOT_PATH}/full_npu)
    target_include_directories(entry PRIVATE ${MNN_INCLUDE_DIR})
    target_link_directories(entry PUBLIC ${MNN_LIB_DIR})

    find_library(cann-lib hiai_foundation)

    target_link_libraries(entry PUBLIC
        libace_napi.z.so
        libhilog_ndk.z.so
        librawfile.z.so
        libneural_network_core.so
        ${cann-lib}
        ${CMAKE_DL_LIBS}
        MNN
    )
endif()
