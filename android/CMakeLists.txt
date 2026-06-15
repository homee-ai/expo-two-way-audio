cmake_minimum_required(VERSION 3.22.1)
project(twowayaudio_aic)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Prebuilt ai-coustics C library, vendored per-ABI under jniLibs by
# scripts/vendor-aic-sdk.sh. It is a complete Rust-built shared object; we link
# against it dynamically (DT_NEEDED libaic.so), and AGP packages it from jniLibs.
add_library(aic SHARED IMPORTED)
set_target_properties(aic PROPERTIES
    IMPORTED_LOCATION ${CMAKE_SOURCE_DIR}/src/main/jniLibs/${ANDROID_ABI}/libaic.so)

add_library(twowayaudio_aic SHARED src/main/cpp/aic_jni.cpp)

target_include_directories(twowayaudio_aic PRIVATE ${CMAKE_SOURCE_DIR}/src/main/cpp/include)

find_library(log-lib log)
target_link_libraries(twowayaudio_aic aic ${log-lib})
