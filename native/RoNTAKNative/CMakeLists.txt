cmake_minimum_required(VERSION 3.18)

set(TARGET RoNTAKNative)
project(${TARGET})

add_library(${TARGET} SHARED "dllmain.cpp")
target_include_directories(${TARGET} PRIVATE .)
target_link_libraries(${TARGET} PUBLIC UE4SS)
# Zydis (built by UE4SS as a static library) decodes game code for RoNTAK_DumpCode.
target_link_libraries(${TARGET} PRIVATE Zydis)
