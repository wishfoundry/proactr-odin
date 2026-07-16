cmake_minimum_required(VERSION 3.16)
project(seastar_tfb CXX)

set(CMAKE_CXX_STANDARD 20)

find_package(Seastar REQUIRED)
find_package(SQLite3 REQUIRED)

add_executable(seastar_tfb main.cc)
target_link_libraries(seastar_tfb PRIVATE Seastar::seastar SQLite::SQLite3)
