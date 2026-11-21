cmake_minimum_required(VERSION 3.22.1)
project(openuu_jni LANGUAGES C CXX)

set(OPENUU_CORE_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../crates/openuu-core/include")
set(OPENUU_CORE_STATIC_LIB "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs-static/${ANDROID_ABI}/libopenuu_core.a")

if(NOT EXISTS "${OPENUU_CORE_STATIC_LIB}")
    message(FATAL_ERROR "libopenuu_core.a not found at ${OPENUU_CORE_STATIC_LIB}. Run scripts/build-android.sh first.")
endif()

add_library(openuu_core STATIC IMPORTED)
set_target_properties(openuu_core PROPERTIES
    IMPORTED_LOCATION "${OPENUU_CORE_STATIC_LIB}"
)

add_library(openuu_jni SHARED openuu_jni.cpp)
target_include_directories(openuu_jni PRIVATE "${OPENUU_CORE_INCLUDE_DIR}")

find_library(log-lib log)
find_library(android-lib android)

target_link_libraries(openuu_jni
    openuu_core
    ${log-lib}
    ${android-lib}
    m
    dl
)

# Android 15/16/17 16KB ELF page alignment compatibility
target_link_options(openuu_jni PRIVATE "-Wl,-z,max-page-size=16384")
