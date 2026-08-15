cmake_minimum_required(VERSION 3.24)
project(ddskk_ime_windows LANGUAGES CXX)

add_library(ddskk-ime SHARED
  src/ddskk-ime.def
  src/dllmain.cpp
  src/candidate_ui.cpp
  src/candidate_ui.h
  src/display_attribute.cpp
  src/display_attribute.h
  src/langbar_button.cpp
  src/langbar_button.h
  src/mode_indicator.cpp
  src/mode_indicator.h
  src/engine_client.cpp
  src/engine_client.h
  src/engine_protocol.cpp
  src/engine_protocol.h
  src/text_service.cpp
  src/text_service.h
  src/guids.h)

target_compile_features(ddskk-ime PRIVATE cxx_std_20)
target_compile_definitions(ddskk-ime PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-ime PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(ddskk-ime PRIVATE ole32 oleaut32 advapi32 uuid gdi32 user32)
set_target_properties(ddskk-ime PROPERTIES OUTPUT_NAME "ddskk-ime")

enable_testing()
add_executable(ddskk-engine-protocol-test
  test/engine_protocol_test.cpp
  src/engine_protocol.cpp)
target_include_directories(ddskk-engine-protocol-test PRIVATE src)
target_compile_features(ddskk-engine-protocol-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-engine-protocol-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-engine-protocol-test PRIVATE /W4 /permissive- /utf-8)
add_test(NAME ddskk-engine-protocol-test COMMAND ddskk-engine-protocol-test)

add_executable(ddskk-engine-client-test
  test/engine_client_test.cpp
  src/engine_client.cpp
  src/engine_protocol.cpp)
target_include_directories(ddskk-engine-client-test PRIVATE src)
target_compile_features(ddskk-engine-client-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-engine-client-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-engine-client-test PRIVATE /W4 /permissive- /utf-8)
add_test(NAME ddskk-engine-client-test COMMAND ddskk-engine-client-test)

add_executable(ddskk-candidate-ui-test
  test/candidate_ui_test.cpp src/candidate_ui.cpp)
target_include_directories(ddskk-candidate-ui-test PRIVATE src)
target_compile_features(ddskk-candidate-ui-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-candidate-ui-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-candidate-ui-test PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(ddskk-candidate-ui-test PRIVATE oleaut32 uuid)
add_test(NAME ddskk-candidate-ui-test COMMAND ddskk-candidate-ui-test)

add_executable(ddskk-display-attribute-test
  test/display_attribute_test.cpp src/display_attribute.cpp)
target_include_directories(ddskk-display-attribute-test PRIVATE src)
target_compile_features(ddskk-display-attribute-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-display-attribute-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-display-attribute-test PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(ddskk-display-attribute-test PRIVATE oleaut32 uuid)
add_test(NAME ddskk-display-attribute-test COMMAND ddskk-display-attribute-test)

add_executable(ddskk-langbar-button-test
  test/langbar_button_test.cpp src/langbar_button.cpp)
target_include_directories(ddskk-langbar-button-test PRIVATE src)
target_compile_features(ddskk-langbar-button-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-langbar-button-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-langbar-button-test PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(ddskk-langbar-button-test PRIVATE oleaut32 uuid)
add_test(NAME ddskk-langbar-button-test COMMAND ddskk-langbar-button-test)

add_executable(ddskk-mode-indicator-test
  test/mode_indicator_test.cpp src/mode_indicator.cpp)
target_include_directories(ddskk-mode-indicator-test PRIVATE src)
target_compile_features(ddskk-mode-indicator-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-mode-indicator-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-mode-indicator-test PRIVATE /W4 /permissive- /utf-8)
# mode_indicator.cpp references GDI/user32 window-management APIs even
# though this test only exercises the pure ModeIndicatorLabel() mapping;
# since it is linked as a directly-specified object file (not a static
# library member), those symbols must still resolve at link time.
target_link_libraries(ddskk-mode-indicator-test PRIVATE gdi32 user32)
add_test(NAME ddskk-mode-indicator-test COMMAND ddskk-mode-indicator-test)

add_executable(ddskk-registration-probe tools/registration_probe.cpp)
target_include_directories(ddskk-registration-probe PRIVATE src)
target_compile_features(ddskk-registration-probe PRIVATE cxx_std_20)
target_compile_definitions(ddskk-registration-probe PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-registration-probe PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(ddskk-registration-probe PRIVATE ole32 uuid)

add_executable(ddskk-ime-config WIN32 config/main.cpp)
target_compile_features(ddskk-ime-config PRIVATE cxx_std_20)
target_compile_definitions(ddskk-ime-config PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-ime-config PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(ddskk-ime-config PRIVATE advapi32 user32)


add_executable(ddskk-engine-host host/main.cpp)
target_compile_features(ddskk-engine-host PRIVATE cxx_std_20)
target_compile_definitions(ddskk-engine-host PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-engine-host PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(ddskk-engine-host PRIVATE ws2_32 advapi32)

add_executable(ddskk-engine-e2e-test
  test/engine_e2e_test.cpp src/engine_client.cpp src/engine_protocol.cpp)
target_include_directories(ddskk-engine-e2e-test PRIVATE src)
target_compile_features(ddskk-engine-e2e-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-engine-e2e-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-engine-e2e-test PRIVATE /W4 /permissive- /utf-8)
set(NELISP_EXECUTABLE "" CACHE FILEPATH "NeLisp executable for DDSKK E2E tests")
if(NELISP_EXECUTABLE)
  add_test(NAME ddskk-engine-e2e-test COMMAND ddskk-engine-e2e-test
    $<TARGET_FILE:ddskk-engine-host>
    "${NELISP_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/..")
  set_tests_properties(ddskk-engine-e2e-test PROPERTIES TIMEOUT 120)
endif()

# Minimal TSF host test harness: drives the real, already-registered
# ddskk-ime text service end-to-end (key events in, document text out) for
# automated testing, without touching src/ or the registry. See
# test-host/tsf_host.cpp and test-host/run-harness.ps1.
add_executable(tsf-host test-host/tsf_host.cpp)
target_include_directories(tsf-host PRIVATE src)
target_compile_features(tsf-host PRIVATE cxx_std_20)
target_compile_definitions(tsf-host PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(tsf-host PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(tsf-host PRIVATE ole32 oleaut32 uuid user32)
