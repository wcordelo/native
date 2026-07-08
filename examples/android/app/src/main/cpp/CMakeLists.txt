cmake_minimum_required(VERSION 3.22.1)

project(native_sdk_android_example C)

add_library(native-sdk STATIC IMPORTED)
set_target_properties(native-sdk PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/lib/libnative-sdk.a"
)

add_library(native_sdk_example SHARED native_sdk_jni.c)
target_include_directories(native_sdk_example PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(native_sdk_example native-sdk android log)
