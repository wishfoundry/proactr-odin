cmake_minimum_required(VERSION 3.16)
project(drogon_empty_ok CXX)

set(CMAKE_CXX_STANDARD 17)

# Prefer third_party submodule if built/installed; else system package.
set(PROACTR_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../..")
list(APPEND CMAKE_PREFIX_PATH "${PROACTR_ROOT}/third_party/drogon/build/install")

find_package(Drogon CONFIG REQUIRED)

add_executable(drogon_empty_ok main.cc)
target_link_libraries(drogon_empty_ok PRIVATE Drogon::Drogon)
