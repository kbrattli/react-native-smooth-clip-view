cmake_minimum_required(VERSION 3.16)
project(smoothclipview)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(fbjni REQUIRED CONFIG)
find_package(ReactAndroid REQUIRED CONFIG)

# Folly compile flags used across the React Native C++ surface.
include("${REACT_NATIVE_DIR}/ReactAndroid/cmake-utils/folly-flags.cmake")
add_compile_options(${folly_FLAGS})

file(GLOB smoothclip_SOURCES CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/src/main/cpp/*.cpp")

add_library(smoothclipview SHARED ${smoothclip_SOURCES})

# 16 KB page-size support for NDKs where ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES
# is unavailable (< r26.3) or ignored.
target_link_options(smoothclipview PRIVATE "-Wl,-z,max-page-size=16384")

# C++20, RTTI, exceptions and React Native macros.
include("${REACT_NATIVE_DIR}/ReactCommon/cmake-utils/react-native-flags.cmake")
target_compile_reactnative_options(smoothclipview PUBLIC)

target_include_directories(
  smoothclipview
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src/main/cpp"
          "${CMAKE_CURRENT_SOURCE_DIR}/../cpp"
          "${REACT_NATIVE_DIR}/ReactCommon"
          "${REACT_NATIVE_DIR}/ReactCommon/jsi"
          "${REACT_NATIVE_DIR}/ReactCommon/callinvoker"
          "${REACT_NATIVE_DIR}/ReactCommon/react/nativemodule/core/ReactCommon"
          "${REACT_NATIVE_DIR}/ReactAndroid/src/main/jni/react/turbomodule")

target_link_libraries(
  smoothclipview
  log
  fbjni::fbjni
  ReactAndroid::jsi
  ReactAndroid::reactnative)

# Debug-only hot-path ATrace slices; see SmoothClipTrace.h.
# Passed from the debug build type in build.gradle, never for release.
if(SMOOTH_CLIP_ENABLE_ATRACE)
  target_compile_definitions(smoothclipview PRIVATE SMOOTH_CLIP_ENABLE_ATRACE=1)
  target_link_libraries(smoothclipview android)
endif()
