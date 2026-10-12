find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(hn_generated "${CMAKE_CURRENT_BINARY_DIR}/production.inc")
add_custom_command(OUTPUT "${hn_generated}"
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/extract.py"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../host/main.cpp" "${hn_generated}"
  DEPENDS extract.py ../../host/main.cpp
  VERBATIM)
add_executable(hn-oracle oracle.cpp "${hn_generated}")
target_include_directories(hn-oracle PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_compile_features(hn-oracle PRIVATE cxx_std_20)
target_compile_definitions(hn-oracle PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(hn-oracle PRIVATE /W4 /permissive- /utf-8)
