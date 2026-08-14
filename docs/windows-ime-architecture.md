# Windows IME architecture

## Goal

DDSKK remains the canonical SKK implementation. Platform code adapts native
input APIs to DDSKK events; it must not grow a second conversion engine.

```text
Windows application
  <-> TSF in-process DLL (COM, composition, edit sessions)
  <-> per-user local IPC (versioned messages, bounded latency)
  <-> NeLisp DDSKK engine process
       -> existing skk.el / skk-search.el / user dictionary
```

The in-process DLL is intentionally small. Loading the full runtime into every
TSF client would duplicate state, complicate updates, and expose applications to
engine crashes. If the engine is unavailable or times out, the DLL must fail
open and return the key to the application.

## Ownership boundary

- DDSKK/NeLisp owns modes, romaji-to-kana rules, conversion, learning, and
  dictionary registration.
- The TSF host owns key normalization, `ITfComposition`, edit sessions,
  display attributes, caret rectangles, and Windows profile registration.
- Candidate rendering follows CorvusSKK's compact vertical list and annotation
  treatment, but uses TSF UI-element interfaces so accessibility and modern
  Windows applications can integrate with it.

## Delivery slices

1. **TSF lifecycle** (implemented): build, per-user COM registration, profile
   registration, activation, and non-consuming key sink.
2. **Engine contract** (Emacs and NeLisp smoke implemented): `skk-ime-session.el` owns one
   hidden DDSKK buffer per native input context and exposes explicit key-feed
   and snapshot operations. Its state-transition tests pass under Emacs, and
   `skk-nelisp-compat.el` maps the same engine path onto NeLisp's native gap
   buffer. The standalone smoke covers direct hiragana, pending romaji, ▽
   preedit, reset, and destroy. NeLisp still lacks true buffer-local cells, so
   the smoke serializes unfinished rule-tree state; the production engine must
   serialize requests per session or add runtime buffer-local support.
3. **Composition MVP** (in progress): TSF now converts virtual keys through the
   active Windows keyboard layout, sends Unicode scalar values to DDSKK, and
   applies returned direct text / ▽ preedit through a synchronous
   `ITfEditSession` and `ITfComposition`. Engine absence remains fail-open.
   Backspace, Enter/commit, and Escape/cancel now travel as explicit control
   requests and are executed by the DDSKK session rather than reimplemented in
   TSF. Space starts conversion or advances to the next candidate through
   `skk-start-henkan`. Engine state now carries the complete DDSKK candidate
   list and selected index. The TSF adapter publishes that model through
   `ITfCandidateListUIElement`, including selection and page metadata, so
   applications and accessibility clients can consume it. Cursor placement,
   `ITfCandidateListUIElementBehavior` callbacks now move DDSKK forward or
   backward to the requested candidate and asynchronously apply selection,
   finalize, or abort state to the composition. Custom CorvusSKK-style
   rendering and cursor placement remain before interactive registration
   testing. A registered `ITfDisplayAttributeProvider` now marks ▽ preedit with
   a normal underline and ▼ candidate text with a bold conversion underline.
   The service consumes `Ctrl+J` to toggle DDSKK hiragana mode and can start in
   kana mode from the per-user setting. A TSF language-bar button exposes the
   mode and settings entry.
4. **Candidate UI**: paging, annotation, horizontal/vertical writing placement,
   DPI/theme/accessibility, and CorvusSKK-inspired visual defaults.
5. **Distribution**: x64/ARM64 builds, signed installer, update/rollback, and
   Windows 10/11 application compatibility matrix. Non-elevated registration
   currently fails at the TSF profile boundary with access denied on the test
   machine; the failed registration rolls back without leaving the CLSID.

## Cross-platform continuation

The engine contract and tests remain platform-neutral. A macOS InputMethodKit
host and Linux IBus/Fcitx5 host replace only the native adapter and renderer.

## IPC protocol status

The TSF-side named-pipe client and version-1 line protocol codec are implemented
and tested against an in-process fake pipe server. Requests use decimal Unicode
code points; response strings use fixed-width Unicode scalar hex and `-` for empty strings. The
client fails open when the pipe is absent or a transaction fails.

`engine/ddskk-engine-stdio.el` implements the matching serialized DDSKK
dispatcher. `ddskk-engine-host.exe` starts a persistent
NeLisp child through anonymous pipes, loads the dispatcher, and relays named-pipe
requests. A CTest E2E test starts the real child, completes a `KEY 107` round
trip, observes the pending-romaji state, and verifies deterministic shutdown.
Tests use an isolated pipe name so the installed IME can remain active.

The E2E runner must keep a console association because this NeLisp build does
not read inherited standard input when launched with `CREATE_NO_WINDOW`.
Normal TSF transactions continue to fail open through the bounded client
connection timeout. The relay defaults to the compatible Elisp load path;
setting `DDSKK_NELISP_ENTRY=native` selects the AOT-backed
`--ddskk-ime-server` entry on a NeLisp reader that provides it.
