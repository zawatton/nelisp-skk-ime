# sumi-ui — SKK mode indicator + settings window (Sumi app)

Implements Phase 2 ("indicator MVP") and Phase 3 ("settings tabs") of
[`docs/design/sumi-indicator-settings.md`](../docs/design/sumi-indicator-settings.md):
a small always-on-top window that shows the current DDSKK input mode
(color + glyph, CorvusSKK-style) and lets the user switch modes from a
click menu, talking to the shared engine session over the same
`\\.\pipe\ddskk-ime-v1` named pipe the TSF DLL uses; plus a settings
window (right-click the pill, or launch with `--settings`) that reads
and writes the same `HKCU\Software\NativeIME` registry key the DLL's
`LoadSettings()` reads, across the design doc's four tabs (動作/表示/
辞書/調整).

## Structure and why

One executable, built by `build.el` into `target/sumi-skk-ui.exe` from
four translation units plus one NeLisp AOT object:

- **`indicator/main.c`** — hand-authored C. Owns everything that is
  I/O, registry access, or a rendering/widget primitive: the GTK4
  pill window and settings window, Cairo/Pango drawing, the
  `--settings`/`--settings-selftest` CLI dispatch, and the one piece of
  Windows-specific "always on top" glue GTK4 no longer exposes
  portably (see "Substrate limitations" below).
- **`indicator/pipe-client.h`/`.c`** (Phase 3, split out of Phase 2's
  main.c) — the Win32 named-pipe client (`CreateFileW` +
  `SetNamedPipeHandleState(PIPE_READMODE_MESSAGE)` + overlapped
  `WriteFile`/`ReadFile` bounded by a timeout, mirroring
  `windows/src/engine_client.cpp`'s own transaction shape). Split out
  so the settings window's "engine restart" button can reuse the exact
  same transaction code the pill's STATUS polling uses, rather than a
  second copy.
- **`indicator/settings.h`/`.c`** (Phase 3) — `Settings` struct +
  registry I/O (`settings_load`/`settings_save`/`settings_defaults`)
  and the headless `settings_selftest()` the `--settings-selftest` CLI
  flag runs. No GTK dependency at all — pure Win32
  `RegGetValueW`/`RegSetKeyValueW`/`RegDeleteTreeW`, directly testable
  without a window (see "Verification").
- **`indicator/mode-logic.el`** — a NeLisp AOT source module in the
  same restricted dialect as `dev/nelisp-sumi/src/*.el` (a `seq` of
  `defun` forms). Compiled by `build.el` with
  `nelisp-aot-compile-to-object` (`:format 'coff`) straight to a COFF
  `.o` and linked into the same executable as the other three objects.
  It owns every *decision*: mode → color, mode → label, whether the
  mode-switch menu should be offered, and what a menu selection sends.
  `main.c` never hardcodes a color or a mode→label rule; it only calls
  into this object's exported functions (plain `int64_t`-in/`int64_t`-
  out C symbols — see "How the AOT object and main.c actually link").
  Phase 3 extended this without moving the decision into C: `main.c`
  reads the five configurable colors from the registry (via
  `settings.c`) into a small packed array and hands that array's
  *pointer* to `skkui_color_for_configured(mode, previous_base,
  colors_ptr)`, which still decides which slot applies — see
  mode-logic.el's header comment for the full COLORS_PTR contract, and
  "Why COLORS_PTR is a pointer, not five arguments" below for why.

### Why not build the whole window in the frame-v1 restricted dialect

`dev/sumi` and `dev/nelisp-sumi` build *their* whole GTK window —
`main`, GTK/GLib signal handlers, the works — as NeLisp AOT source,
using `extern-call` to reach `gtk_init`/`g_signal_connect_data`/
`cairo_*`/`pango_*` directly and linking straight to an executable (no
hand-written C at all; see `dev/nelisp-sumi/build.el`'s
`nelisp-sumi-live-rewrite`). That is the "real" Sumi pattern, and it
was the first option this task's design brief offered.

It was not used here because it buys nothing for a ~120×40 status
pill and costs a lot: `nelisp-sumi/build.el` is 57 KB of hand-authored
IR forms tracking a 232-byte hand-laid-out `ctx` struct (event
sequencing, image cache, resize loop-breaking, IME forwarding, cursor
hit-testing...) to drive the full `protocol/frame-v1.org` frame/EVENT
stream for an editor-grade window. This indicator needs none of that
protocol — it has no buffer to render, no keyboard capture, no resize
negotiation. Task brief's own words: *"driving the full frame-v1
protocol for this small window is disproportionate"* — confirmed true
after reading `nelisp-sumi/build.el` and
`nelisp-sumi/protocol/frame-v1.org` in full. The brief's own suggested
MVP simplification (a real GTK4 C program plus a NeLisp AOT object for
decision logic, linked the way `build-live.el` links its AOT object)
is what got built.

A second reason: `dev/sumi/backends/cairo-elisp/sumi-cairo.el` (the
*pure-elisp* Cairo binding, calling libcairo through NeLisp's own
dynamic FFI) is explicitly `READY-TO-TEST, pending one runtime
feature` — `nl-ffi-call` did not yet marshal `:double` when that file
was written, and `cairo_show_text`/`cairo_set_source_rgb`/etc. are all
`double`-heavy. That limitation is specific to *calling cairo from
NeLisp over the dynamic FFI*; it does not apply here at all, because
`main.c` is real C calling cairo/Pango directly — the SysV/Win64 ABI
`double` marshaling a C compiler emits is not NeLisp's problem to
solve. Text rendering (`あ`/`ア`/`Ａ`/`SKK`/`――`/the ▽▼ markers) uses
`pangocairo` directly in `main.c`, the same library
`nelisp-sumi/build.el`'s own `text_at` vocabulary macro-expands to
(see its `pango_cairo_create_layout`/`pango_layout_set_text`/
`pango_cairo_show_layout` sequence) — just called from C instead of
generated as AOT `extern-call` forms.

### What still makes this "made with Sumi"

- Same MSYS2 mingw64 toolchain, same `pkg-config gtk4`/`pangocairo`
  linkage, same `emacs -Q --batch -l build.el` invocation convention
  as `dev/sumi/backends/cairo-elisp/build-live.el` and
  `dev/nelisp-sumi/build.el`.
- Same `nelisp-aot-compile-to-object … :format 'coff` call, on the
  same restricted `(seq (defun ...) ...)` dialect, producing a COFF
  object linked directly with `gcc` — verbatim the "AOT object + gcc
  link" step every other Sumi/NeLisp-Sumi executable uses; this
  project just adds one more, ordinarily-compiled object
  (`main.o`) to the same link line.
- The mode→color/label/menu *decision logic* — the part with product
  behavior worth getting right and auditing — lives in the restricted
  dialect, not scattered through C `if`/`switch` statements.

### How the AOT object and main.c actually link

`nelisp-aot-compiler.el`'s `nelisp-aot-compile-to-object` supports
compiling a *library* — "SEXP must be either a single `(defun NAME
(PARAMS...) BODY)` form or a `(seq (defun ...) ...)` wrapping multiple
defuns. Each defun becomes a GLOBAL STT_FUNC symbol named after the
defun ... Emit pass: only the defuns, no main `_start` body." COFF
output additionally binds the calling convention to Win64 (`nelisp-
aot-compile-to-link-unit`: *"COFF/Windows targets bind --abi to
'win64 before parsing, so arity validation and emission both see
Win64 register budgets"*) — exactly the ABI `gcc`-compiled `main.c`
expects when it calls a plain `extern int64_t foo(int64_t, ...)`. No
`extern-call`/FFI marshaling is involved on the `main.c` side at all;
these are ordinary C function calls into an ordinary object file, and
`mode-logic.el` never uses a string literal (object-mode compilation
rejects any defun body that does — see the `:object-mode-no-strings`
gate), so ​the "spike scope" restriction in that gate is never
exercised. This was verified stand-alone before `main.c` was written
at all: a throwaway C program (`long long skkui_base_color(long long
m)` etc., declared `extern` and called directly) linked against
`mode-logic.o` and printed the exact expected values for every mode.

### Why COLORS_PTR is a pointer, not five arguments

Phase 3's `skkui_color_for_configured` needs to choose among five
registry-configurable colors (かな/カナ/全英/SKK/Abbrev) plus MODE and
PREVIOUS_BASE — seven logical inputs. It does not take seven
parameters. `nelisp-aot-compiler.el`'s COFF/Win64 object-mode path
binds the *real* Win64 calling convention (four GP argument registers
— RCX/RDX/R8/R9 — not SysV's six), and this project never needed to
exercise whatever stack-argument support exists for functions beyond
that (the doc comment above 5+-argument extern-calls only mentions a
"SysV stack-argument path"). Rather than be the first thing in this
codebase to test 5+-argument Win64 object-mode calls, `main.c` packs
the five colors into a small `int64_t[7]` array (indices 0/1/2/3/6 —
hiragana/katakana/wide-latin/latin/abbrev; see mode-logic.el's
COLORS_PTR contract) and passes its address as a single `int64_t`
(the same "pointer smuggled as an integer" pattern
`dev/nelisp-sumi/src/nelisp-sumi-move.el`'s `ctx`/`eventbuf` params
already use), so the function stays at 3 parameters. `mode-logic.el`
reads the array with `ptr-read-u64` — a primitive already proven in
object-mode-compiled code by that same nelisp-sumi module. The
decision of *which* slot to use for a given MODE/PREVIOUS_BASE is
still entirely NeLisp's; `main.c` only decides what a slot's bytes
say (`RegGetValueW`'s DWORD, or a design-doc default).

## Build

```
$env:PATH = "C:\msys64\mingw64\bin;$env:PATH"   # only needed if `emacs` is not already on PATH
emacs -Q --batch -l build.el
```

Produces `target/sumi-skk-ui.exe` plus one `.o` per translation unit:
`mode-logic.o` (NeLisp AOT), `pipe-client.o`, `settings.o`, `main.o`.
Requires (all available via the existing MSYS2 mingw64 install this
repo already uses for `dev/sumi`): `pkg-config`, `gtk4`, `pangocairo`,
`gcc`, and a real Emacs (not NeLisp — `nelisp-aot-compiler.el` is
itself an ordinary-Elisp meta-compiler, run under GNU Emacs, the same
way every other Sumi/NeLisp-Sumi `build.el`/`build-live.el` runs it).
`settings.c`'s registry calls link against `advapi32` (added
explicitly in `build.el`'s link step — not pulled in transitively by
`gtk4`/`pangocairo`'s own `pkg-config --libs` output).

**The output is not always `target/sumi-skk-ui.exe` itself.** Windows
refuses to overwrite the image file of an already-running process
("Permission denied" from `ld`), unlike POSIX's unlink-and-replace —
and a pill and/or settings window left running across a rebuild is
routine while iterating on this app. `sumi-ui-link` in `build.el`
detects that specific failure and falls back to a sibling
`target/sumi-skk-ui.new.exe`, printing which path it actually used
(`SUMI-UI-BUILD-OK <path>`) — read that line rather than assuming the
default name. Any other link failure (missing symbol, bad flag, ...)
still aborts the build as before.

### Env var overrides

| Var | Default | Meaning |
|---|---|---|
| `NELISP_ROOT` | `../../nelisp` (sibling of this repo under `dev/`) | Where `nelisp-aot-compiler.el` (and its `lisp`/`src` load-path) lives. This project's only real build-time dependency on another `dev/` checkout — see "Why not build the whole window..." above for why there is no `SUMI_ROOT`/`NELISP_SUMI_ROOT`: no source from either is loaded. |
| `MINGW_BIN` | `C:/msys64/mingw64/bin` | Prepended to `PATH` for `gcc`/`pkg-config`/DLL loading. |
| `PKG_CONFIG_PATH` | `/c/msys64/mingw64/lib/pkgconfig` | Passed to `pkg-config`. |
| `DDSKK_PIPE_NAME` | `\\.\pipe\ddskk-ime-v1` | *Runtime*, not build-time: which named pipe the pill/settings-window "engine restart" button talk to. See `windows/src/engine_client.cpp`'s own use of the same variable. |
| `DDSKK_SETTINGS_KEY` | `Software\NativeIME` | *Runtime*, not build-time: the HKCU-relative registry key `settings.c`'s `settings_load`/`settings_save`/`settings_delete_all` all resolve through. `verify/verify-settings.ps1` always overrides this to a disposable key (`Software\NativeIME-PhaseThreeTest`), and `settings_selftest()` itself refuses to run at all unless this is set to something non-empty — see "Verification". |
| `DDSKK_ALLOW_MULTIPLE_INSTANCES` | unset | *Runtime*, not build-time: forces `G_APPLICATION_NON_UNIQUE` for a plain (non-`--settings`) launch too. Default off (production keeps the single-pill behavior); `verify/verify.ps1` sets it so a freshly built exe can be tested without disturbing an already-running pill/settings instance — see "Substrate limitations". |

### Substrate limitation hit during the build: pkg-config's self-relocation

`C:\msys64\mingw64\bin\pkg-config.exe` is relocatable — it resolves
its own install prefix relative to `argv[0]` at runtime. Called with
an explicit path (as this README's own build-live.el-style smoke test
did) it correctly self-locates to `C:/msys64/mingw64/...`. Called as a
bare `"pkg-config"` resolved off `PATH` — which is exactly what
`call-process` does from inside `build.el` — it instead falls back to
the POSIX-style prefix baked into its `.pc` files (`/mingw64/...`),
which only means anything inside an MSYS2 shell's own automatic path
translation. A native `gcc.exe` (no MSYS runtime linkage) cannot
resolve `/mingw64/...` at all, so `gcc -c main.c` failed with `gtk/
gtk.h: No such file or directory` even though the correct `-I` flags
were, in a sense, "present." `build.el`'s `sumi-ui-fix-mingw-path`
rewrites any leading `/mingw64/` in a pkg-config-emitted flag back to
the real, already-resolved mingw64 root before it reaches `gcc`.
Neither `dev/sumi/backends/cairo-elisp/build-live.el` nor
`dev/nelisp-sumi/build.el` hit this, because both call `pkg-config
--libs gtk4` with only one dependency and (per their own working
builds) apparently get the resolved form in their environment; this
project depends on two pkg-config modules (`gtk4` and `pangocairo`)
and hit the unresolved form consistently in this environment, so the
fix is applied unconditionally rather than investigated further.

**The rewrite is anchored** (`\`\(-[IL]\)?/mingw64/` — start of the
flag, past an optional `-I`/`-L`), not a blanket
`replace-regexp-in-string`: pkg-config does not consistently emit one
form or the other even within a single invocation, and a flag that had
*already* self-located to a real path like
`-Ic:/msys64/mingw64/bin/../include` also contains the literal
substring `/mingw64/` — mid-string, not at the start. An unanchored
rewrite corrupted exactly that flag into
`-Ic:/msys64C:/msys64/mingw64/bin/../include`, which is how a
fully-resolved, individually-correct `-I` flag still made `gcc` fail
to find `glib.h`: the corruption, not a missing/wrong path.

## Substrate limitations hit (functional, not just build-time)

- **GTK4 dropped the portable "always on top" API.**
  `gtk_window_set_keep_above()` existed in GTK3 and was removed in
  GTK4 for portability reasons; there is no `GdkToplevel`-level
  replacement. The task brief already sanctions Windows-specific
  host-side code in the glue layer for the named-pipe I/O ("this is
  Windows-specific host-side code, which is fine in the glue layer —
  the same place GTK signal handlers live"); the same reasoning is
  applied here: `main.c`'s `apply_always_on_top()` reaches through
  `gdk_win32_surface_get_handle()` (from `<gdk/win32/gdkwin32.h>`,
  shipped in the mingw64 `gtk4` package and already covered by
  `pkg-config --cflags gtk4`) to get the real `HWND` and calls
  `SetWindowPos(hwnd, HWND_TOPMOST, ...)` directly, on the window's
  `"realize"` signal.
- **Draggable-by-drag-anywhere, with a working click underneath.**
  GTK4 ships exactly the widget this needs — `GtkWindowHandle` — which
  turns a press-and-drag into an interactive window move while still
  passing an undragged click through to its child (here, the
  `GtkGestureClick` on the drawing area that opens the mode-switch
  popover). No workaround needed; noted here because it is the kind
  of thing that would have needed one.
- **Cairo `double` FFI marshaling** — see "What still makes this
  'made with Sumi'" above: not actually a limitation for this
  project, since text/color primitives are called from real C, but
  worth recording as the reason `sumi-cairo.el`'s pure-elisp path was
  not used.
- **`abbrev` still has no design-doc-assigned indicator color.** The
  design doc's "Tab 表示" registry-defaults table lists
  `ModeColorAbbrev` with default `—` (undecided) — Phase 3 wires
  `ModeColorAbbrev` fully into the registry (it is readable, writable,
  and has its own `GtkColorDialogButton` in the settings window's 表示
  tab), but `settings.c`'s `settings_defaults()` still has to supply
  *some* value for a first run before the user has ever picked one,
  and reuses the same `#808080` gray Phase 2 used for the "pipe
  unreachable/ERR" bucket rather than inventing an unspec'd color the
  design doc never chose. The label still reads `Ab` (not `――`) so
  it stays visually distinguishable from a real connectivity error.
  This is a "no real default value" gap, not a "not configurable" gap
  any more — the user can already override it via the settings window.
- **`ModeIndicatorScale` is stored and round-trips, but is not yet
  wired to the drawn pill size**, and Phase 3's text-color logic does
  not yet flip to dark text for a pale user-chosen override color (see
  `draw_indicator()`'s comment). Both are settings-window/rendering
  polish, not registry-I/O gaps; tracked here rather than silently
  left out.
- **Spawning this GTK app through Windows PowerShell 5.1
  (`powershell.exe`) was unreliable in this development environment**
  (child process starts but produces no output at all, even via
  `Start-Process -RedirectStandardOutput`) while PowerShell 7 (`pwsh`)
  was reliable for the identical invocation. All verification here
  runs through `pwsh` for that reason. This reads as host/session
  flakiness rather than anything `sumi-skk-ui.exe` does differently
  per PowerShell version — the same build, run enough times under
  `pwsh`, reliably produces full trace output every time (including a
  once-observed multi-second stall in `gtk_window_present()` that did
  not reproduce on retry) — but it is recorded here in case it recurs:
  if a launch produces truly zero output under automation, suspect the
  launcher/session before the binary.
- **GApplication uniqueness silently absorbs a second plain launch.**
  Discovered directly while verifying against a build left running for
  interactive testing (an indicator pill + a `--settings` window):
  launching a fresh, unmodified `sumi-skk-ui.exe` next to an
  already-running pill exits in well under a second with status 0 and
  produces zero stdout/stderr — GApplication's single-instance-per-app-
  ID behavior hands the activation off to the *existing* process and
  the new one never runs its own `on_activate()`/STATUS-poll code at
  all. Indistinguishable from a hang from the outside, and easy to
  mistake for the flakiness noted above (it produced the exact same
  symptom: an empty indicator log) until reproduced twice in a row and
  confirmed with a bare 3-second standalone run showing `HasExited`
  true almost immediately. `DDSKK_ALLOW_MULTIPLE_INSTANCES` (see the
  env var table) is the fix — `verify/verify.ps1` sets it so testing
  never needs to touch a developer's already-running instances.

## Settings window (Phase 3)

Two entry points, both building the same window (`open_settings_window()`
in `main.c`):

- **Right-click the pill** — a second `GtkGestureClick` on the
  drawing area, bound to `GDK_BUTTON_SECONDARY`, alongside the
  existing left-click mode-switch-menu gesture.
- **`sumi-skk-ui.exe --settings`** — skips creating the pill/STATUS
  polling entirely and opens only the settings window; closing it
  quits the process. Intended for a future Start-menu shortcut (task
  brief), so a user who never wants the persistent pill running can
  still reach settings. Registered as `G_APPLICATION_NON_UNIQUE`
  (plain pill launches stay the default unique-per-app-ID) — with the
  default uniqueness, a `--settings` launch next to an already-running
  pill would just hand off activation to that pill (whose
  `settings_only` is `FALSE`) and exit, so no settings window would
  ever appear. `argv` is not forwarded to `g_application_run()` beyond
  `argv[0]` for the same reason in reverse: GApplication parses the
  command line itself and rejects any option it does not recognize
  (`--settings`/`--settings-selftest`, both already consumed before
  `gtk_application_new()` runs).

Four tabs (`GtkNotebook`), field-for-field the design doc's schema
tables — see `settings.h`'s `Settings` struct for the exact
registry-value-name/type/default mapping the UI reads and writes:

| Tab | 日本語 | Controls |
|---|---|---|
| 動作 | behavior | エンジン (read-only label); 初期入力モード (two `GtkCheckButton`s in a `gtk_check_button_set_group` radio group — かな/英数); four CorvusSKK-modeled behavior checkboxes — 送り仮名が一致した候補を優先する (`BehaviorOkuriStrictly`), 取消のとき送り仮名を削除する (`BehaviorDeleteOkuriOnCancel`), 候補に片仮名変換を追加する (`BehaviorAddKatakanaCand`), 学習しない（プライベートモード） (`BehaviorLearnDisabled`) — all DWORD 0/1, default 0 |
| 表示 | display | 入力モードを表示する (checkbox); 表示時間・表示倍率 (`GtkSpinButton`); five mode colors (`GtkColorDialogButton`, one per `ModeColor*` value) |
| 辞書 | dictionary | 辞書サーバを使用する (checkbox); ホスト (`GtkEntry`); ポート (`GtkSpinButton`); ユーザー辞書パス (`GtkEntry` + 参照 button opening a `GtkFileDialog`); 保存間隔 (`GtkSpinButton`) |
| 調整 | maintenance | アイドルGC間隔 (`GtkSpinButton`); デバッグログ (checkbox) |

The four 動作-tab behavior checkboxes take effect only via engine
restart — the host bridges them to the engine child's environment at
spawn, the same mechanism `UserJisyoPath`/`UserJisyoBatch` already use
(see the 辞書 tab's design-doc note) — not read live by a running
session. They share the tab strip's one status label (below the
`GtkNotebook`, not per-tab) with every other setting, so the
CorvusSKK-style 反映には IME の切替（またはエンジン再起動）が必要です
note after 適用 already covers them; no separate note was needed on
the 動作 tab specifically.

Widget choices vs. the original Phase 1 "UI design" section's sumi-
sprite-vocabulary language (label/checkbox/number-field/text-field/
color-swatch): the task brief that authorized Phase 3 supersedes that
section's widget-kind wording with concrete GTK4 widget choices, which
is what got built. Two calls worth recording:

- **`GtkColorDialogButton`, not the deprecated `GtkColorButton`.**
  This GTK4 install is 4.22.4, well past GTK 4.10 where
  `GtkColorDialogButton`/`GtkFileDialog` (both used here) landed as
  the non-deprecated replacements for `GtkColorButton`+
  `GtkColorChooserDialog` and `GtkFileChooserDialog`. No reason to
  write against a deprecated API on a toolchain this current.
- **The 辞書 tab's ユーザー辞書パス is a live, editable `GtkEntry`**,
  not the original UI-design section's "read-only display +
  エクスプローラで開く/既定に戻す" pattern (that wording predates the
  Phase 3 brief, which explicitly asks for "entry + 参照 file-chooser
  button"). The brief's instruction is the more specific and more
  recent authority here, so it is what got built.

Behavior:

- **On open**, every control is populated from `settings_load()` —
  registry values where present, `settings_defaults()` (the design
  doc's own defaults) for anything absent.
- **適用 (Apply)** reads every control back into a `Settings` struct
  and calls `settings_save()`, which writes everything **except**
  `Engine` (read-only per the design doc's Tab 動作 table — this UI
  does not own that value). Shows the CorvusSKK-style note 反映には
  IME の切替（またはエンジン再起動）が必要です on success, or a
  distinct failure message if any individual registry write failed
  (best-effort: every field is still attempted). The running pill's
  colors/visibility update immediately from the just-applied values
  regardless of persistence success, so what the user set is what they
  see right away; only the label's wording depends on whether it
  actually reached the registry.
- **エンジン再起動 (restart engine)** sends a literal `SHUTDOWN\n`
  over the same pipe-client machinery the pill's STATUS polling uses.
  Confirmed by reading `windows/host/main.cpp`'s `ServeClient()`
  directly (not assumed): it accepts `"SHUTDOWN"` from *any* connected
  client (trailing `\n`/`\r` stripped before the comparison), replies
  `"OK"`, and tears down the whole host + engine child process — the
  TSF DLL respawns the host lazily on its own next keystroke, already
  picking up whatever was just written to the registry (see the design
  doc's Architecture section). This app only requests the shutdown; it
  does not orchestrate the respawn itself. A client-triggerable
  shutdown verb does exist, so — per the task brief's own fallback
  instruction — the button was kept rather than dropped.
- **閉じる (Close)** and the window's own close button both go through
  `close_settings_window()`, which destroys the window and (only in
  `--settings`-launched, no-pill mode) quits the application.
- **`ModeIndicator = 0` hides the pill.** `app_sync_pill_visibility()`
  runs after the initial load and after every Apply: it calls
  `gtk_window_present()` when `ModeIndicator` is truthy or
  `gtk_widget_set_visible(window, FALSE)` when it is not. The process
  keeps running either way (`--settings` still works, and the pill can
  reappear on a later Apply); the STATUS-poll cadence itself drops from
  500 ms to 2000 ms while hidden (`schedule_poll()` is a self-
  rescheduling one-shot timer — `on_poll_tick` always returns
  `G_SOURCE_REMOVE` and arms its own next tick — specifically so the
  interval can change between ticks whenever `ModeIndicator` changes,
  which a single fixed `g_timeout_add()` cannot do).

## Verification

See `verify/verify.ps1`. It starts a private `ddskk-engine-host.exe` +
`nelisp.exe` pair on a disposable named pipe and a disposable user
jisyo (same pattern as `windows/test-host/run-harness.ps1`, but
talking to the engine host directly instead of through `tsf-host.exe`
— this indicator never goes through TSF), starts `sumi-skk-ui.exe`
against that same pipe via `DDSKK_PIPE_NAME`, and — as a *second*,
independent client of the same shared engine session (the design
doc's own point: *"The engine session is shared by all clients, so
the UI app can both observe and drive the input mode over the same
pipe"*) — drives a scripted sequence of `KEY`/`CONTROL` requests.
`sumi-skk-ui.exe` polls `STATUS` on its own connection every 500 ms
and logs every observed mode change to stdout as `MODE <name>` (see
`main.c`'s `app_log_transition`); the script captures that stdout and
asserts the expected transition sequence appears in order. Only
processes the script itself started are ever killed (`SHUTDOWN` over
the pipe first, then a PID-scoped `Stop-Process` fallback for the
host; `Stop-Process` by PID for the indicator).

`sumi-skk-ui.exe` is linked with `-mwindows` (no console subsystem,
same as `dev/nelisp-sumi/build.el`'s own executable) so it never
flashes a console for a normal user. `stdout`/`stderr` still flow
through an explicitly redirected handle exactly like any other
process's **only when the parent supplies one via
`Start-Process -RedirectStandardOutput/-RedirectStandardError`** (both
verification scripts do this). Plain `& exe args 2>&1` pipeline
capture does **not** reliably work for this binary — confirmed
empirically while writing `verify-settings.ps1`: it silently returned
`$null` instead of the self-test's PASS/FAIL lines, even though the
process itself ran and exited normally. Both scripts use
`Start-Process` with file redirection for exactly this reason; if you
write a new verification script against this exe, do the same rather
than capturing `& exe` output into a variable.

### Settings I/O verification: `verify/verify-settings.ps1`

Runs the headless `sumi-skk-ui.exe --settings-selftest` entry point
(`settings_selftest()` in `settings.c`) against a disposable registry
key and asserts every check passed. Full GUI interaction (opening the
settings window, clicking through its four tabs) is not required for
this verification — the task brief's own bar is "compile-clean +
selftest PASS + the existing indicator verify still PASS" — but the
headless path exercises exactly the same `settings_load()`/
`settings_save()` functions the settings window's Apply button and
initial load use.

`settings_selftest()`:

1. Saves `settings_defaults()`, reloads, asserts equality.
2. Mutates every field (every registry type this schema uses — DWORD
   bool, DWORD int, DWORD packed color, SZ string), saves, reloads,
   asserts equality — exercising `settings_save()`/`settings_load()`
   for each type, not just the defaults path.
3. Deletes the whole key, reloads, asserts every field falls back to
   `settings_defaults()`.
4. Deletes the key again unconditionally (belt-and-suspenders), then
   prints `SELFTEST-PASS (0 failures)` or `SELFTEST-FAIL (N failures)`.

Safety (task brief: "do NOT write the real registry key from any
automated test"): `DDSKK_SETTINGS_KEY` is set to a disposable key
(`Software\NativeIME-PhaseThreeTest`) by `verify-settings.ps1` *before*
invoking `--settings-selftest`, and independently,
`settings_selftest()` itself **refuses to run at all** — prints an
error to stderr, returns 1 — unless `DDSKK_SETTINGS_KEY` is set to a
non-empty value, so the destructive self-test cannot mutate or delete
the real `HKCU\Software\NativeIME` even if invoked directly by
mistake. Verified directly: `HKCU\Software\NativeIME` (the real,
already-populated production key — `EngineHost`/`EngineExecutable`/
`Repository`/`InitialKanaMode`/etc., written by this IME's own
installer/config, not by anything in this repo) was read before and
after every self-test run in this session and was unchanged throughout
development.

## Configuring against the real pipe / real registry key

No configuration needed for the default case: with `DDSKK_PIPE_NAME`
and `DDSKK_SETTINGS_KEY` both unset, `sumi-skk-ui.exe` talks to
`\\.\pipe\ddskk-ime-v1` and `HKCU\Software\NativeIME` — the same
defaults the TSF DLL, `windows/src/engine_client.cpp`, and the
installer/config tool use.
