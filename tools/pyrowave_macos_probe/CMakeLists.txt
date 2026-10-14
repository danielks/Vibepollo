cmake_minimum_required(VERSION 3.24)
project(PyroWaveMacOSProbe LANGUAGES C CXX)

if(NOT APPLE)
    message(FATAL_ERROR "This diagnostic is intended for macOS/MoltenVK")
endif()

get_filename_component(VIBEPOLLO_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
add_subdirectory("${VIBEPOLLO_SOURCE_DIR}/third-party/pyrowave"
                 "${CMAKE_CURRENT_BINARY_DIR}/pyrowave" EXCLUDE_FROM_ALL)
# Expose the vendored C API's existing diagnostics in this standalone tool.
target_compile_definitions(pyrowave-capi PRIVATE VULKAN_DEBUG)
add_executable(pyrowave_macos_probe main.cpp)
target_compile_features(pyrowave_macos_probe PRIVATE cxx_std_20)
target_link_libraries(pyrowave_macos_probe PRIVATE pyrowave::capi granite-volk-headers)

enable_testing()
add_test(NAME pyrowave_macos_roundtrip COMMAND pyrowave_macos_probe)
set_tests_properties(pyrowave_macos_roundtrip PROPERTIES
    SKIP_RETURN_CODE 77 TIMEOUT 60 LABELS "integration;gpu")
