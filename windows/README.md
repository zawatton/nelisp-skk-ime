# NeLisp IME for Windows

Windows Text Services Framework (TSF) frontend for NeLisp Input Hub. The hub
can select DDSKK, Lattice, and additional Japanese input engines.
The current Phase 0 DLL registers a Japanese text-service profile and activates
inside TSF applications, but deliberately does not consume keys yet.

## Build

From a Visual Studio 2022 Developer PowerShell:

```powershell
cmake -S windows -B build/windows -G "Visual Studio 17 2022" -A x64
cmake --build build/windows --config Debug
```

Register the current debug build. The helper requests elevation because the
TSF profile/category APIs return `E_FAIL` from a non-elevated process on the
tested Windows 11 environment:

```powershell
powershell -ExecutionPolicy Bypass -File windows/tools/register-debug.ps1
```

Unregister before deleting or replacing the DLL:

```powershell
powershell -ExecutionPolicy Bypass -File windows/tools/register-debug.ps1 -Unregister
```

Registration changes Windows input settings. Building alone does not register
anything. A non-elevated registration attempt currently returns access denied
and rolls the partial COM registration back cleanly. Per-user packaging without
elevation remains a distribution task.

To diagnose registration without retaining changes, run
`build/windows/Debug/ddskk-registration-probe.exe`. It registers and immediately
unregisters each TSF boundary independently and prints its HRESULT.

After registration, run the interactive smoke test from a normal terminal:

```powershell
powershell -ExecutionPolicy Bypass -File windows/tools/interactive-test.ps1
```

It starts the NeLisp relay hidden, waits up to 90 seconds for the engine pipe,
prints the Notepad input sequence, and stops both host and child runtime when
the test finishes.

The initial input mode is ASCII. Press `Ctrl+J` to toggle DDSKK hiragana input;
press it again to commit any active composition and return to ASCII. A Windows
input-method options entry is exposed through `ITfFnConfigure`; the initial
dialog documents the active keys. Editable persisted options are not yet wired.
When DDSKK is the active input profile, an `ITfLangBarItemButton` named
`DDSKK` is added with `TF_LBI_STYLE_SHOWNINTRAYONLY`, targeting the taskbar
input-indicator area. Its left-click action opens the same settings/help dialog.
Windows may require reopening the target app or signing out once before showing
a newly registered item. The Windows taskbar setting "Input Indicator" must be
enabled; Windows 11 may still group the button inside its input flyout.

The taskbar button now also selects the input engine. `DDSKK` runs the existing
DDSKK/NeLisp path; `passthrough` is an experimental provider that returns all
keys to the application. The IPC contract exposes `ENGINE LIST`,
`ENGINE CURRENT`, and `ENGINE SET <id>` so additional engines can be added
without changing TSF key/composition plumbing.

Windows can keep an in-process TSF DLL loaded in `ctfmon`, Explorer, or a text
application after registration. If relinking reports `LNK1168`, build into a
new directory and register that DLL instead of terminating the shell:

```powershell
cmake -S windows -B build/windows-next -G "Visual Studio 17 2022" -A x64
cmake --build build/windows-next --config Debug
```

## Standalone runtime

When the NeLisp self-host build produces `nelisp-ddskk.exe`, install a portable
runtime copy under the current user's Local AppData directory:

```powershell
powershell -ExecutionPolicy Bypass -File windows/tools/install-local.ps1 `
  -EngineExecutable ..\nelisp\target\nelisp-ddskk.exe
```

The installer copies the TSF DLL, host, settings application, and standalone
engine into one versioned directory. Registration then discovers the adjacent
`nelisp-ddskk.exe`; the installed IME does not retain a path to either source
repository. Until the standalone executable exists, `register-debug.ps1`
continues to configure the development NeLisp runtime as a fallback.

## Engine session API

`skk-ime-session.el` wraps the existing DDSKK command path in an isolated hidden
buffer. Native hosts use `skk-ime-session-create`, `skk-ime-session-feed-key`,
`skk-ime-session-snapshot`, and `skk-ime-session-destroy`; no SKK conversion
rules are duplicated in the Windows host.

Standalone NeLisp smoke test:

```powershell
..\nelisp\target\nelisp.exe --load test/nelisp-session-smoke.el
```

Success prints `ddskk-nelisp-session-smoke-ok`.

`ddskk-engine-host.exe NELISP_EXE REPOSITORY` is the Windows named-pipe relay.
The host starts a persistent NeLisp REPL through inherited anonymous pipes,
loads the DDSKK dispatcher, and serves `\\.\pipe\ddskk-ime-v1`. A manual E2E
executable verifies a real `KEY` round trip. It is not registered in CTest yet
because Windows process-tree cleanup still needs a deterministic control path.
