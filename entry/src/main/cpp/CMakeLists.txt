#  cmake_minimum_required(VERSION 3.5.0)
#  project(mnnllm)
#
#  set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
#  set(MNN_LIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH})
##  set(MNN_LIB_DIR ${NATIVERENDER_ROOT_PATH}/libs/${OHOS_ARCH})
#  set(MNN_INCLUDE_DIR ${NATIVERENDER_ROOT_PATH}/include)
#
#  # 导入预编译的 MNN 库
#  add_library(mnn SHARED IMPORTED)
#  set_target_properties(mnn PROPERTIES IMPORTED_LOCATION ${MNN_LIB_DIR}/libMNN.so)
#
#  add_library(mnn_express SHARED IMPORTED)
#  set_target_properties(mnn_express PROPERTIES IMPORTED_LOCATION ${MNN_LIB_DIR}/libMNN_Express.so)
#
#  add_library(llm SHARED IMPORTED)
#  set_target_properties(llm PROPERTIES IMPORTED_LOCATION ${MNN_LIB_DIR}/libllm.so)
#
#  # N-API 桥接模块
#  add_library(entry SHARED napi_init.cpp)
#
#  target_include_directories(entry PRIVATE ${MNN_INCLUDE_DIR})
#
#  target_link_libraries(entry PUBLIC
#      libace_napi.z.so
#      libhilog_ndk.z.so
#      llm
#      mnn_express
#      mnn
#  )
#  cmake_minimum_required(VERSION 3.5.0)
#  project(mnnllm)
#
#  set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
#  set(MNN_LIB_DIR ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH})
#  set(MNN_INCLUDE_DIR ${NATIVERENDER_ROOT_PATH}/include)
#
#  # N-API 桥接模块
#  add_library(entry SHARED napi_init.cpp)
#
#  target_include_directories(entry PRIVATE ${MNN_INCLUDE_DIR})
#
#  # 用目录+库名方式链接，避免绝对路径写入 so
#  target_link_directories(entry PUBLIC ${MNN_LIB_DIR})
#
#  target_link_libraries(entry PUBLIC
#      libace_napi.z.so
#      libhilog_ndk.z.so
#      llm
#      MNN
#      MNN_Express
#  )
 cmake_minimum_required(VERSION 3.5.0)
  project(mnnllm)

  set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
  set(MNN_LIB_DIR ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH})
  set(MNN_INCLUDE_DIR ${NATIVERENDER_ROOT_PATH}/include)
  # Extra header paths for IDSTEncoder (per-channel int8 quant helper used by
  # the op precision test). These are MNN's internal headers, needed only to
  # build a quant Convolution2DT description inline; libMNN.so still supplies
  # the runtime symbols.
  set(MNN_SRC_ROOT ${NATIVERENDER_ROOT_PATH}/../../../../../source)
  set(MNN_SCHEMA_ROOT ${NATIVERENDER_ROOT_PATH}/../../../../../schema/current)

  add_library(entry SHARED napi_init.cpp)
  target_include_directories(entry PRIVATE
      ${MNN_INCLUDE_DIR}
      ${MNN_SRC_ROOT}
      ${MNN_SCHEMA_ROOT}
  )
  target_link_directories(entry PUBLIC ${MNN_LIB_DIR})

  target_link_libraries(entry PUBLIC
      libace_napi.z.so
      libhilog_ndk.z.so
      MNN
  )