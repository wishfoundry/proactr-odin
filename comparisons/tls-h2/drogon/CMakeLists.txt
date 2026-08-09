cmake_minimum_required(VERSION 3.16)
project(drogon_tls_h2 CXX)
set(CMAKE_CXX_STANDARD 17)

set(PROACTR_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../..")
list(APPEND CMAKE_PREFIX_PATH "${CMAKE_CURRENT_SOURCE_DIR}/install")
list(APPEND CMAKE_PREFIX_PATH "${PROACTR_ROOT}/comparisons/tfb/drogon/install")
list(APPEND CMAKE_PREFIX_PATH "${PROACTR_ROOT}/third_party/drogon/build/install")

find_package(Drogon CONFIG REQUIRED)

add_executable(drogon_tls_h2 main.cc)
target_link_libraries(drogon_tls_h2 PRIVATE Drogon::Drogon)
