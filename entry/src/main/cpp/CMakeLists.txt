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
    add_library(entry SHARED napi_init.cpp HIAIModelManager.cpp OfflineNpuChunkExecutor.cpp)
    target_include_directories(entry PRIVATE ${MNN_INCLUDE_DIR})
    target_link_directories(entry PUBLIC ${MNN_LIB_DIR})

    find_library(cann-lib hiai_foundation)

    target_link_libraries(entry PUBLIC
        libace_napi.z.so
        libhilog_ndk.z.so
        librawfile.z.so
        libneural_network_core.so
        ${cann-lib}
        MNN
    )
endif()
