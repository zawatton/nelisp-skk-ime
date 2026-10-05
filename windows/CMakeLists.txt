cmake_minimum_required(VERSION 3.24)
project(ddskk_ime_windows LANGUAGES CXX RC)

add_library(nativeime-local-index STATIC src/local_index.cpp src/engine_protocol.cpp)
target_compile_features(nativeime-local-index PUBLIC cxx_std_20)
target_compile_definitions(nativeime-local-index PUBLIC UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(nativeime-local-index PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(nativeime-local-index PUBLIC bcrypt advapi32)

set(NATIVEIME_CORE_SOURCES
  src/core_entry.cpp src/text_service.cpp src/candidate_ui.cpp
  src/display_attribute.cpp src/langbar_button.cpp src/mode_indicator.cpp
  src/realtime_frontend.cpp src/engine_client.cpp src/engine_protocol.cpp
  src/inline_preedit.cpp src/auto_pair.cpp src/local_conversion.cpp)
function(nativeime_dll target)
  target_compile_features(${target} PRIVATE cxx_std_20)
  target_compile_definitions(${target} PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
  target_compile_options(${target} PRIVATE /W4 /permissive- /utf-8)
  target_link_libraries(${target} PRIVATE ole32 oleaut32 advapi32 uuid gdi32 user32)
endfunction()
add_library(ddskk-ime SHARED src/ddskk-ime.def src/ddskk-ime.rc src/dllmain.cpp
  src/shim_service.cpp src/display_attribute.cpp src/langbar_button.cpp src/mode_indicator.cpp)
nativeime_dll(ddskk-ime)
add_library(ddskk-ime-core SHARED ${NATIVEIME_CORE_SOURCES})
nativeime_dll(ddskk-ime-core)
target_compile_definitions(ddskk-ime-core PRIVATE NATIVEIME_CORE_BUILD)
target_link_libraries(ddskk-ime-core PRIVATE nativeime-local-index)
# Identical production sources; only diagnostics/failure injection differ.
foreach(variant IN ITEMS B bad-abi bad-init)
  add_library(ddskk-ime-core-${variant} SHARED ${NATIVEIME_CORE_SOURCES})
  nativeime_dll(ddskk-ime-core-${variant})
  target_link_libraries(ddskk-ime-core-${variant} PRIVATE nativeime-local-index)
  target_compile_definitions(ddskk-ime-core-${variant} PRIVATE NATIVEIME_CORE_BUILD
    NATIVEIME_CORE_LABEL="${variant}")
endforeach()
# Deterministic pending-request coverage: delay only the test B provider worker.
target_compile_definitions(ddskk-ime-core-B PRIVATE NATIVEIME_CORE_PROVIDER_DELAY_MS=400)
target_compile_definitions(ddskk-ime-core-bad-abi PRIVATE NATIVEIME_CORE_BAD_ABI)
target_compile_definitions(ddskk-ime-core-bad-init PRIVATE NATIVEIME_CORE_FAIL_INIT)

enable_testing()
function(nativeime_test target)
  add_test(NAME ${target} COMMAND powershell -NoProfile -ExecutionPolicy Bypass
    -File "${CMAKE_CURRENT_SOURCE_DIR}/test/run-isolated-test.ps1"
    -Executable $<TARGET_FILE:${target}> ${ARGN})
endfunction()
add_executable(nativeime-local-conversion-test test/local_conversion_test.cpp
  src/local_conversion.cpp src/engine_client.cpp)
target_include_directories(nativeime-local-conversion-test PRIVATE src)
target_compile_features(nativeime-local-conversion-test PRIVATE cxx_std_20)
target_compile_options(nativeime-local-conversion-test PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(nativeime-local-conversion-test PRIVATE nativeime-local-index)
nativeime_test(nativeime-local-conversion-test)
add_executable(ddskk-engine-protocol-test
  test/engine_protocol_test.cpp
  src/engine_protocol.cpp)
target_include_directories(ddskk-engine-protocol-test PRIVATE src)
target_compile_features(ddskk-engine-protocol-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-engine-protocol-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-engine-protocol-test PRIVATE /W4 /permissive- /utf-8)
nativeime_test(ddskk-engine-protocol-test)

add_executable(ddskk-engine-client-test
  test/engine_client_test.cpp
  src/engine_client.cpp
  src/engine_protocol.cpp)
target_include_directories(ddskk-engine-client-test PRIVATE src)
target_compile_features(ddskk-engine-client-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-engine-client-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-engine-client-test PRIVATE /W4 /permissive- /utf-8)
nativeime_test(ddskk-engine-client-test)

add_executable(ddskk-candidate-ui-test
  test/candidate_ui_test.cpp src/candidate_ui.cpp)
target_include_directories(ddskk-candidate-ui-test PRIVATE src)
target_compile_features(ddskk-candidate-ui-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-candidate-ui-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-candidate-ui-test PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(ddskk-candidate-ui-test PRIVATE oleaut32 uuid)
nativeime_test(ddskk-candidate-ui-test)

add_executable(ddskk-display-attribute-test
  test/display_attribute_test.cpp src/display_attribute.cpp)
target_include_directories(ddskk-display-attribute-test PRIVATE src)
target_compile_features(ddskk-display-attribute-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-display-attribute-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-display-attribute-test PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(ddskk-display-attribute-test PRIVATE oleaut32 uuid)
nativeime_test(ddskk-display-attribute-test)

add_executable(ddskk-langbar-button-test
  test/langbar_button_test.cpp src/langbar_button.cpp)
target_include_directories(ddskk-langbar-button-test PRIVATE src)
target_compile_features(ddskk-langbar-button-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-langbar-button-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-langbar-button-test PRIVATE /W4 /permissive- /utf-8)
# gdi32/user32: langbar_button.cpp's mode-aware icon synthesis (DIB
# section, GDI text/fill, CreateIconIndirect) and menu handling now pull
# in both.
target_link_libraries(ddskk-langbar-button-test PRIVATE oleaut32 uuid gdi32 user32)
nativeime_test(ddskk-langbar-button-test)

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
nativeime_test(ddskk-mode-indicator-test)

add_executable(ddskk-realtime-frontend-test
  test/realtime_frontend_test.cpp
  src/realtime_frontend.cpp)
target_include_directories(ddskk-realtime-frontend-test PRIVATE src)
target_compile_features(ddskk-realtime-frontend-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-realtime-frontend-test PRIVATE
  UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-realtime-frontend-test PRIVATE /W4 /permissive- /utf-8)
nativeime_test(ddskk-realtime-frontend-test)

add_executable(nativeime-registry-settings-test test/registry_settings_test.cpp)
target_include_directories(nativeime-registry-settings-test PRIVATE src)
target_compile_features(nativeime-registry-settings-test PRIVATE cxx_std_20)
target_compile_definitions(nativeime-registry-settings-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(nativeime-registry-settings-test PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(nativeime-registry-settings-test PRIVATE advapi32)
nativeime_test(nativeime-registry-settings-test)

add_executable(ddskk-registration-probe tools/registration_probe.cpp)
target_include_directories(ddskk-registration-probe PRIVATE src)
target_compile_features(ddskk-registration-probe PRIVATE cxx_std_20)
target_compile_definitions(ddskk-registration-probe PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-registration-probe PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(ddskk-registration-probe PRIVATE ole32 uuid)

# Standalone operator tool: applies just the two GUID_TFCAT_TIPCAP_*
# category registrations dllmain.cpp's RegisterCategories() also performs
# as part of DllRegisterServer -- which is never run against the live
# installation on this machine. See windows/tools/register-categories.cpp.
add_executable(register-categories tools/register-categories.cpp)
target_include_directories(register-categories PRIVATE src)
target_compile_features(register-categories PRIVATE cxx_std_20)
target_compile_definitions(register-categories PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(register-categories PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(register-categories PRIVATE ole32 uuid)

add_executable(set-profile-icon tools/set-profile-icon.cpp)
target_include_directories(set-profile-icon PRIVATE src)
target_compile_features(set-profile-icon PRIVATE cxx_std_20)
target_compile_definitions(set-profile-icon PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(set-profile-icon PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(set-profile-icon PRIVATE ole32 uuid)

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
target_link_libraries(ddskk-engine-host PRIVATE nativeime-local-index)

add_executable(ddskk-host-utf8-protocol-test test-host/host_utf8_protocol_test.cpp)
target_compile_features(ddskk-host-utf8-protocol-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-host-utf8-protocol-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-host-utf8-protocol-test PRIVATE /W4 /permissive- /utf-8)
target_link_libraries(ddskk-host-utf8-protocol-test PRIVATE ws2_32 advapi32)
target_link_libraries(ddskk-host-utf8-protocol-test PRIVATE nativeime-local-index)
nativeime_test(ddskk-host-utf8-protocol-test)

add_executable(ddskk-engine-e2e-test
  test/engine_e2e_test.cpp src/engine_client.cpp src/engine_protocol.cpp)
target_include_directories(ddskk-engine-e2e-test PRIVATE src)
target_compile_features(ddskk-engine-e2e-test PRIVATE cxx_std_20)
target_compile_definitions(ddskk-engine-e2e-test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
target_compile_options(ddskk-engine-e2e-test PRIVATE /W4 /permissive- /utf-8)
set(NELISP_EXECUTABLE "" CACHE FILEPATH "NeLisp executable for DDSKK E2E tests")
if(NELISP_EXECUTABLE)
  nativeime_test(ddskk-engine-e2e-test
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
target_link_libraries(tsf-host PRIVATE ole32 oleaut32 uuid user32 advapi32)
