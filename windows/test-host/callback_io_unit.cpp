#include "callback_io_probe.h"
int wmain(int argc, wchar_t** argv) {
  if (argc != 2) return 2;
  HMODULE fixture = LoadLibraryW(argv[1]);
  if (!fixture) return 3;
  auto run = reinterpret_cast<void (*)(HANDLE, HANDLE, HANDLE)>(GetProcAddress(fixture, "CallbackIoFixture"));
  if (!run) { FreeLibrary(fixture); return 4; }
  HANDLE read = nullptr, write = nullptr;
  HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!event || !CreatePipe(&read, &write, nullptr, 4096)) return 5;
  callback_io_probe::Install(fixture);
  run(read, write, event);
  const bool background = callback_io_probe::pipe_io == 0 && callback_io_probe::blocking_waits == 0;
  callback_io_probe::active = true;
  run(read, write, event);
  callback_io_probe::active = false;
  const bool callback = callback_io_probe::pipe_io == 2 && callback_io_probe::blocking_waits == 1;
  std::printf("callback IO probe: checks=2 background_ignored=%d actual_pipe_io=%u actual_blocking_waits=%u hooks=%u failures=%d\n",
      background, callback_io_probe::pipe_io, callback_io_probe::blocking_waits,
      callback_io_probe::hooks, !(background && callback));
  CloseHandle(read); CloseHandle(write); CloseHandle(event); FreeLibrary(fixture);
  return background && callback ? 0 : 1;
}
