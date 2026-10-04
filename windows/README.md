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

The taskbar menu selects DDSKK, かな漢字変換 (lattice), or パススルー by
writing the Engine setting. Open applications follow the change after their
current composition ends. エンジン再起動 sends `ENGINE RELOAD`; the host
warms a replacement child while the old engine continues serving requests.
The IPC contract also exposes `ENGINE SWITCH <id>`, `ENGINE CURRENT`,
`ENGINE LIST`, and the compatible `ENGINE SET <id>` selection command.

For isolated verification, build into a private directory and pass explicit
`-TsfHostExe`, `-EngineHostPath`, `-EngineExecutablePath`, and `-RepositoryPath`
to `test-host/run-harness.ps1`. It creates a private pipe, registry key
(`NATIVEIME_REGISTRY_KEY`) and user dictionary, then removes its key on exit.
Harness scripts can use `ENGINE:lattice`, `KILLCHILD` and `KILLHOST` to
exercise changes within one activation. `test-host/test-hot-swap.ps1` accepts
the host/runtime paths and `-BuildDirectory` and verifies the host lifecycle
with a persistent client connection.

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

The lattice runner (`framework/nelisp-ime-stdio.el`) replies with
`STATE mode cursor composition-start hex-text hex-pending candidate-index hex-candidates`.
Strings are six hex digits per Unicode scalar, `-` for empty, and candidates
are comma separated. A converted composition may append one ninth field:
`start:length,start:length,...;active`. Starts and lengths count code points
in displayed text (including any settled prefix), and `active` is a zero-based
segment index. For example `0:1,1:1;1` describes `僕達` with `達` active.
The cursor is the active segment's displayed end; composition-start still
marks the whole composition. Candidates and candidate-index belong only to
the active segment. The Windows parser accepts eight-field replies and
translates segment offsets to UTF-16 for TSF. The indicator can still read
candidates from field 7. Registration's existing ninth hex-reading field
keeps its original meaning.

In candidate state, Space/previous cycle the active segment, Right/Left move
focus (`SEGMENT-NEXT`/`SEGMENT-PREV`), and Shift+Right/Left move its reading
boundary one kana (`SEGMENT-EXTEND`/`SEGMENT-SHRINK`). Enter commits exactly
the displayed text. TSF marks the active segment as target converted and the
other segments as converted.

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
executable verifies a real `KEY` round trip, independent application sessions,
conversion, child respawn and same-client recovery. Set the CMake cache variable
`NELISP_EXECUTABLE` to the runtime path to register `ddskk-engine-e2e-test` in
CTest. Cold readiness has a separate 90-second budget; warm transactions retain
their ten-second budget. The test owns a kill-on-close job object, so assertion
failures and CTest termination clean up its host and runtime children.

The host appends lifecycle events to `%LOCALAPPDATA%\DDSKK\host.log`.
`DDSKK_HOST_LOG` overrides the file path (its parent directory must exist).
At 1 MiB, the host replaces `host.log.1` with the previous log and starts a
new file. Events include child pid, engine, runner, exit code, uptime and
expected-exit status, replacement requests/publication and host stop reason.
Use a private `LOCALAPPDATA` or `DDSKK_HOST_LOG` for tests. Forced host termination
cannot emit a final stop event; its last recorded lifecycle event remains useful.
`DDSKK_HOST_DEBUG=1` adds per-request dispatch, mutex wait, CPU time, working set,
page faults and dictionary relay timing to stderr.
