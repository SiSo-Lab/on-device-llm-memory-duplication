cmake_minimum_required(VERSION 3.22.1)

project("llama-android")

set(LLAMA_CPP_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../external/llama.cpp)

add_subdirectory(${LLAMA_CPP_DIR} build-llama)

add_library(${CMAKE_PROJECT_NAME} SHARED
    llama-android.cpp
)

target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE
    ${LLAMA_CPP_DIR}/include
    ${LLAMA_CPP_DIR}/common
    ${LLAMA_CPP_DIR}/ggml/include
)

# llama.cpp b39a7bf builds the common helpers as "llama-common".
target_link_libraries(${CMAKE_PROJECT_NAME} PRIVATE
    llama
    llama-common
    android
    log
)
