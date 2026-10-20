# CMake configuration
cmake_minimum_required(VERSION 3.5)
project(ryloth_direct_probe_sw)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(EN_SIM "Enable simulation mode for Coyote" OFF)

if(EN_SIM)
    add_subdirectory(../../../sim/sw ${CMAKE_BINARY_DIR}/coyote)
else()
    add_subdirectory(../../../sw ${CMAKE_BINARY_DIR}/coyote)
endif()

message("*** Ryloth direct-HBM probe [Software] ***")

# Directory containing the executable(s) to be compiled
set(TARGET_DIR "${CMAKE_SOURCE_DIR}/src/")

# Create build targets and link against required libraries
set(EXEC ryloth_direct_probe)
add_executable(${EXEC} ${TARGET_DIR}/main.cpp)

target_link_libraries(${EXEC} PUBLIC Coyote)

# as the Ryloth kit host: Boost static, -march=x86-64-v3 (the box has AVX2)
set(Boost_USE_STATIC_LIBS ON)
find_package(Boost REQUIRED COMPONENTS program_options)
target_compile_options(${EXEC} PRIVATE -march=x86-64-v3)
target_link_libraries(${EXEC} PUBLIC Boost::program_options)
