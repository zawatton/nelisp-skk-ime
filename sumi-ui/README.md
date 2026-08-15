# sumi-ui — SKK mode indicator (Sumi app, Phase 2 MVP)

Implements Phase 2 ("indicator MVP") of
[`docs/design/sumi-indicator-settings.md`](../docs/design/sumi-indicator-settings.md):
a small always-on-top window that shows the current DDSKK input mode
(color + glyph, CorvusSKK-style) and lets the user switch modes from a
click menu, talking to the shared engine session over the same
`\\.\pipe\ddskk-ime-v1` named pipe the TSF DLL uses.

## Structure and why

One executable, `indicator/main.c` + `indicator/mode-logic.el`, built by
`build.el` into `target/sumi-skk-ui.exe`:

- **`indicator/main.c`** — hand-authored C. Owns everything that is
  I/O or a rendering primitive: the Win32 named-pipe client
  (`CreateFileW` + `SetNamedPipeHandleState(PIPE_READMODE_MESSAGE)` +
  overlapped `WriteFile`/`ReadFile` bounded by a timeout, mirroring
  `windows/src/engine_client.cpp`'s own transaction shape), the GTK4
  window/widgets, Cairo/Pango drawing, and the one piece of
  Windows-specific "always on top" glue GTK4 no longer exposes
  portably (see "Substrate limitations" below).
- **`indicator/mode-logic.el`** — a NeLisp AOT source module in the
  same restricted dialect as `dev/nelisp-sumi/src/*.el` (a `seq` of
  `defun` forms). Compiled by `build.el` with
  `nelisp-aot-compile-to-object` (`:format 'coff`) straight to a COFF
  `.o` and linked into the same executable as `main.o`. It owns every
  *decision*: mode → color, mode → label, whether the mode-switch menu
  should be offered, and what a menu selection sends. `main.c` never
  hardcodes a color or a mode→label rule; it only calls into this
  object's exported functions (plain `int64_t`-in/`int64_t`-out C
  symbols — see "How the AOT object and main.c actually link").

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

## Build

```
$env:PATH = "C:\msys64\mingw64\bin;$env:PATH"   # only needed if `emacs` is not already on PATH
emacs -Q --batch -l build.el
```

Produces `target/sumi-skk-ui.exe`, `target/mode-logic.o`,
`target/main.o`. Requires (all available via the existing MSYS2
mingw64 install this repo already uses for `dev/sumi`):
`pkg-config`, `gtk4`, `pangocairo`, `gcc`, and a real Emacs (not
NeLisp — `nelisp-aot-compiler.el` is itself an ordinary-Elisp meta-
compiler, run under GNU Emacs, the same way every other Sumi/NeLisp-
Sumi `build.el`/`build-live.el` runs it).

### Env var overrides

| Var | Default | Meaning |
|---|---|---|
| `NELISP_ROOT` | `../../nelisp` (sibling of this repo under `dev/`) | Where `nelisp-aot-compiler.el` (and its `lisp`/`src` load-path) lives. This project's only real build-time dependency on another `dev/` checkout — see "Why not build the whole window..." above for why there is no `SUMI_ROOT`/`NELISP_SUMI_ROOT`: no source from either is loaded. |
| `MINGW_BIN` | `C:/msys64/mingw64/bin` | Prepended to `PATH` for `gcc`/`pkg-config`/DLL loading. |
| `PKG_CONFIG_PATH` | `/c/msys64/mingw64/lib/pkgconfig` | Passed to `pkg-config`. |

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
- **`abbrev` has no assigned indicator color yet.** The design doc's
  own "Tab 表示" registry-defaults table lists `ModeColorAbbrev` with
  default `—` (undecided). `mode-logic.el`'s `skkui_base_color`
  reuses the same `#808080` gray as the "pipe unreachable/ERR" bucket
  for `abbrev` rather than inventing an unspec'd seventh color; the
  label still reads `Ab` (not `――`) so it is visually distinguishable
  from a real connectivity error. Revisit once Phase 3 gives
  `ModeColorAbbrev` a real default and wires registry overrides.

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
flashes a console for a normal user, but `stdout` still flows through
an explicitly redirected handle exactly like any other process's — no
special flag is needed to make the verification script's redirection
work.

## Configuring against the real pipe

No configuration needed for the default case: with `DDSKK_PIPE_NAME`
unset, `sumi-skk-ui.exe` talks to `\\.\pipe\ddskk-ime-v1`, the same
default the TSF DLL and `windows/src/engine_client.cpp` use.
