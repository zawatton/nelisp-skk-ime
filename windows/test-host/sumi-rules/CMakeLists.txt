cmake_minimum_required(VERSION 3.24)
project(sumi_rules_tests LANGUAGES CXX)
# Reuse the existing TSF fixture without editing it or the Win32 editors.
# Its generated source includes actions.h from its own build directory first.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../input-rules/actions.h" ACTIONS)
set(LAUNCH [=[
bool SumiEditorAction(const std::wstring& token) {
 if (token != L"SUMIEDIT") return false;
 auto exe=keymap::env(L"NELISP_TEST_SUMI_EXE");
 if(exe.empty() || keymap::env(L"NATIVEIME_REGISTRY_KEY").empty() || keymap::env(L"NELISP_IME_INPUT_RULES").empty())std::exit(2);
 std::wstring command=L"\""+exe+L"\" --rules-apply-selftest";
 STARTUPINFOW startup{};startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESHOWWINDOW;startup.wShowWindow=SW_HIDE;
 PROCESS_INFORMATION child{};
 if(!CreateProcessW(nullptr,command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child))std::exit(2);
 DWORD exit=1;bool done=WaitForSingleObject(child.hProcess,30000)==WAIT_OBJECT_0;
 if(!done){TerminateProcess(child.hProcess,2);WaitForSingleObject(child.hProcess,3000);}
 GetExitCodeProcess(child.hProcess,&exit);CloseHandle(child.hProcess);CloseHandle(child.hThread);
 if(!done || exit)std::exit(2);
 std::printf("SUMI_EDITOR gtk-edit-and-save=1 explicit-reload=0 hooks=0 SendInput=0\n");return true;
}
bool InputRulesAction(const std::wstring& token) {
 if (SumiEditorAction(token)) return true;
]=])
string(REPLACE "bool InputRulesAction(const std::wstring& token) {" "${LAUNCH}" ACTIONS "${ACTIONS}")
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/fixture")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/fixture/actions.h" "${ACTIONS}")
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../input-rules" "${CMAKE_CURRENT_BINARY_DIR}/fixture")
