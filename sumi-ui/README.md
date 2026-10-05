# Sumi resident indicator and settings

One executable, `target/sumi-skk-ui.exe`, owns the resident indicator,
candidate surfaces and the six-tab settings window. The keyboard hook and
its editors remain separate until stages B/C.

The settings application now follows the NeLisp AOT pattern used by
`../emacs-skkserv/standalone/skkserv-sumi-app.el`. The object modules use
`extern-call` to invoke GTK4, GLib, Win32 and narrow native primitives:

- `indicator/settings-window.el`: window lifetime, all six pages, engine
  selection/pages, widget loading/reading, Apply, restart, browse and text
  button callbacks. Additional editors can attach pages to this module.
- `indicator/settings-logic.el`: defaults, registry field mapping,
  engine-scoped load/save and experimental-engine visibility preference.
- `indicator/text-logic.el`: SU1 option parsing, byte-preserving patches,
  no-op/external-edit merging, partial-save baselines and file/editor/status
  actions. Writes retain the atomic file primitive.
- `indicator/registry.el`: low-level registry calls.
- `indicator/widgets.el`, `colors.el`, `mode-logic.el`: GTK row primitive,
  configured color extraction and indicator decisions.
- `indicator/main.c`: resident transport, indicator/candidate drawing,
  UTF conversion/color/process primitives, ABI address/data providers and
  an independent hidden-window selftest oracle.
- `indicator/settings.c`: registry path primitives and independent
  registry selftests. `text-settings.c` retains native file/path primitives,
  immutable templates/value tables and independent file selftests.
- `indicator/pipe-client.c`: bounded overlapped engine-pipe transactions.

`settings-abi.inc` asserts every struct size/field offset consumed by AOT.
AOT scratch buffers are heap allocated and released on every return; the
`_done`/`_result` cells represent early returns while preserving cleanup.
String data blobs occupy multiples of eight bytes because Win32 registry
APIs require aligned UTF-16 names. GTK float arguments use `(:f32 LIT)`;
spin-button double arguments use `(:f64 ...)`.

## Resident settings channel

The GTK main thread owns a message-only HWND of class
`NeLispSumiSettingsV1`, with the resolved HKCU registry path as its title.
The core sends registered message `NativeIME.Sumi.ShowSettings.v1`, waiting
up to 500 ms for acknowledgment `1`. The endpoint queues GTK work on the
main context and presents/reuses its settings window in the same process.
Absence, rejection or timeout leaves the existing `SettingsExe --settings`
spawn fallback intact. Standalone settings also own an endpoint so later
requests reuse that process. The legacy title lookup is confined to the
production identity, preventing a private host from activating a live UI.

A non-default registry identity automatically uses a non-unique GTK app;
private launches cannot be absorbed by a production GApplication instance.
The resident endpoint remains alive while the settings window is closed.
Closing during engine restart releases the poll's window reference before
it could access destroyed controls.

## Build

Run from this checkout (GNU Emacs and MSYS2 mingw64 GTK4 are required):

```powershell
$env:HOME=[Environment]::GetFolderPath('UserProfile')
$env:NELISP_ROOT=(Resolve-Path ../nelisp-f32).Path
$env:PATH="$env:MINGW_BIN;$env:PATH" # set MINGW_BIN to the MSYS2 DLL/bin directory
emacs -Q --batch -l sumi-ui/build.el
```

`NELISP_ROOT` must provide `feat/aot-f32-literal-args`. Other build overrides:
`MINGW_BIN`, `PKG_CONFIG_PATH`. Read `SUMI-UI-BUILD-OK` for the actual output:
a locked executable causes a link retry into `sumi-skk-ui.new.exe`.

Runtime overrides: `NATIVEIME_REGISTRY_KEY` (first), `DDSKK_SETTINGS_KEY`
(second), `DDSKK_PIPE_NAME`, `NELISP_IME_INPUT_RULES`,
`NELISP_IME_KEYMAP_FILE`, and `DDSKK_ALLOW_MULTIPLE_INSTANCES`. Defaults are
production identities; always set private overrides in tests.

## Verification

Run with the MSYS2 DLL directory on PATH:

```powershell
./sumi-ui/verify/verify-settings.ps1 -SettingsKey 'Software\NativeIME-Tests\SN1-private'
./sumi-ui/verify/verify-text-settings.ps1
./sumi-ui/verify/verify-settings-hidden.ps1
./sumi-ui/verify/verify-settings-window-title.ps1
./sumi-ui/verify/verify-resident-settings.ps1
./windows/test-host/test-resident-settings.ps1
```

The last gate needs `build/w/Release` core/TSF host binaries (or explicit
`-DllPath`/`-TsfHostExe`). It compiles the actual `ShowSettings` body in a
small probe, exercises absent/rejecting/hung endpoints and fallback reuse,
then invokes `SETTINGS` through the real toolbar item in an isolated TSF
host. Opening settings needs no engine, so this toolbar gate disables host
spawning. Every GUI/process/registry/file identity is private and every
started process is cleaned up by the gate.

The resident timing gate measures process-start/request to an owned visible
settings HWND followed by `DwmFlush`, on the same machine. This measures
visible-window/compositor readiness rather than an instrumented GTK
`after-paint` timestamp. Exact timings and gate tails are in
`tools/ai/sumi-settings-nelisp-progress.org`.

The 入力規則 tab's editor button opens an embedded rules page. `sumi-skk-ui.exe
--rules` selects the same page: it first requests the resident endpoint
(`NativeIME.Sumi.ShowRules.v1`, scoped by the registry identity), then opens
a standalone settings window if the resident does not acknowledge it.
The old `nelisp-ime-keymap.exe --rules` entry point remains available.

`rules-logic.el` implements the engine-compatible tokenizer, validation,
default/override rows, comment-preserving row changes and conflict checks.
`rules-window.el` owns the GTK controls and actions. Saving reuses SU1's
atomic file primitive; the existing keymap watcher requests engine reload.
Clean external edits reload automatically; dirty edits require an explicit
reload before saving. Deleting a file override restores the engine's built-in
row where one exists. The reload button explicitly discards pending edits.
Private registry identities also require an explicit rules file override.

Additional private gates:

```powershell
./sumi-ui/verify/verify-rules.ps1
./sumi-ui/verify/verify-rules-parity.ps1
./sumi-ui/verify/verify-resident-rules.ps1
cmake -S windows/test-host/sumi-rules -B build/sn3-rules -G "Visual Studio 17 2022" -A x64
cmake --build build/sn3-rules --config Release --target input-rules-host
# Supply the runtime and binaries built in this checkout:
./windows/test-host/sumi-rules/test-sumi-rules.ps1 -BuildDirectory build/w/Release `
  -RulesBuildDirectory build/sn3-rules -KeymapExe $KeymapExe `
  -IndicatorExe sumi-ui/target/sumi-skk-ui.exe -EngineExecutablePath $Runtime `
  -ColdLoadSleepSec 45
```

The parity gate compares AOT options, rows and diagnostics against the actual
engine parser in stock Emacs. The end-to-end fixture runs the real remapper
with `--no-hook`, invokes Sumi's GTK edit/save callbacks, and verifies the
next TSF symbol after the watcher reloads the real engine. It sends no
explicit reload request and leaves its private fixtures under build for review.

The キー置き換え tab now embeds the remapping editor and inspector.
`sumi-skk-ui.exe --editor` requests `NativeIME.Sumi.ShowEditor.v1` on the
registry-scoped resident endpoint, with a standalone fallback. The old
`nelisp-ime-keymap.exe --editor` remains available.

`editor-logic.el` owns parsing, validation, comment-preserving edits and
exclusions; `editor-window.el` owns controls, save/reload and conflict policy;
`editor-capture.el` owns chord capture and mapping lookup. Saves reuse the
atomic text-file primitive and the remapper's existing live watcher.

While capture has focus, Sumi sets the remapper's existing
`NelispImeKeymapCapture` window property and requests its held-output release
handshake (`WM_APP+4`). Only after acknowledgment does Sumi install a temporary
physical-key hook. This avoids observing remapped output, releases previously
owned outputs before capture, and leaves the normal remapping algorithm
unchanged. The property and hook are removed after completion, Esc, focus
loss, ten seconds or window destruction. Injected events and keys held before
capture pass through. Windows Scancode Map still precedes capture; secure
attention sequences such as Ctrl+Alt+Del cannot be captured. Character labels
use the current Windows keyboard layout, without changing its dead-key state.

Private gates (with the MSYS2 DLL directory already on `PATH`):

```powershell
./sumi-ui/verify/verify-editor.ps1
./sumi-ui/verify/verify-resident-editor.ps1
ctest --test-dir build/keymap -C Release --output-on-failure
./windows/test-host/sumi-editor/test-sumi-editor.ps1 -KeymapExe $KeymapExe `
  -IndicatorExe sumi-ui/target/sumi-skk-ui.exe
```

The editor selftest drives real GTK actions and the AOT capture state machine
without global input. The end-to-end gate runs an isolated `--no-hook`
remapper and queries its live decision snapshot after a Sumi edit. Its
capture handshake portion requires an interactive desktop with an owned
foreground window; a headless desktop must fail that assertion.
