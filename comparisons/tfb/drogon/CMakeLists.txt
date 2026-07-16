cmake_minimum_required(VERSION 3.16)
project(drogon_tfb CXX)
set(CMAKE_CXX_STANDARD 17)

find_package(Drogon CONFIG REQUIRED)
add_executable(drogon_tfb main.cc)
target_link_libraries(drogon_tfb PRIVATE Drogon::Drogon)
