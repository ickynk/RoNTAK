# RoNTAK's native (C++) UE4SS mod, built against the UE4SS source of the
# UE4SS version players run (see README.md). The GitHub Action
# .github/workflows/native.yml does this on Windows.
cmake_minimum_required(VERSION 3.18)
project(RoNTAKNativeBuild)

set(UE4SS_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/RE-UE4SS" CACHE PATH "RE-UE4SS source at the UE4SS release tag")

add_subdirectory(${UE4SS_SOURCE_DIR} RE-UE4SS)
add_subdirectory(RoNTAKNative)
