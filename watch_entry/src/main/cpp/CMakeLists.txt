cmake_minimum_required(VERSION 3.5.0)
project(clawmate_voicevad LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
file(GLOB VAD_SOURCES CONFIGURE_DEPENDS
  "third_party/webrtc/common_audio/signal_processing/*.c"
  "third_party/webrtc/common_audio/third_party/spl_sqrt_floor/*.c"
  "third_party/webrtc/common_audio/vad/*.c")
add_library(voicevad SHARED voicevad.cpp ${VAD_SOURCES} third_party/webrtc/rtc_base/checks.cc)
target_include_directories(voicevad PRIVATE third_party)
target_compile_definitions(voicevad PRIVATE WEBRTC_POSIX NDEBUG)
target_compile_options(voicevad PRIVATE -O2 -fvisibility=hidden)
# WebRTC fixed-point DSP intentionally relies on signed wraparound.
target_compile_options(voicevad PRIVATE -fwrapv)
target_link_libraries(voicevad PUBLIC libace_napi.z.so)
