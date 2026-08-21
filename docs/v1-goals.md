# NeLisp IME v1.0 completion gates

Status: normative.  A feature is not complete because its implementation
exists; v1.0 is complete only when every gate in this document has current,
reproducible evidence.

## Product boundary

NeLisp IME v1.0 is the personal-production Windows release.  The visible
product name is **NeLisp IME**.  **NeLisp Input Hub** is its engine-neutral
architecture and supports DDSKK and Lattice providers.

The real-time frontend must not synchronously evaluate NeLisp for ordinary
typing.  A native frontend core owns key normalization, romaji/kana preedit,
mode state, local cancellation, request sequencing, and per-TSF-context
sessions.  NeLisp providers own conversion, dictionaries, registration, and
learning.  Provider work is asynchronous; replies carry a monotonically
increasing sequence and stale replies never alter the document.

## Performance gates

All warm measurements use the real DLL, TSF test host, private named pipe, and
real provider.  `windows/test-host/measure-latency.ps1` is the measurement of
record for ordinary keys.  `windows/test-host/measure-conversion-latency.ps1`
is the measurement of record for conversion acknowledgement and first-candidate
surface latency.  The first surface may use the host's immutable local
dictionary preview; the provider reply remains authoritative for selection,
commit, registration, and learning.

| Path | Gate |
| --- | --- |
| 1,000 ordinary keys | median <= 5 ms, p95 <= 10 ms, max <= 25 ms |
| Ctrl+G, including a hung provider | visible cancellation <= 20 ms |
| conversion request acknowledgement | visible busy/candidate surface <= 16 ms |
| warm first candidate | p95 <= 150 ms |
| cold provider | ordinary typing remains responsive; loading is background |

No timeout may leak, lose, duplicate, or reorder a claimed key.

## DDSKK functional gate

Each row needs an automated engine test and a TSF harness assertion of the
actual document buffer/key ownership.

- hiragana, katakana, wide Latin, and direct input modes
- one-character conversion and okuri-ari conversion
- Shift+Q and supported F6/F7 transliteration
- candidate traversal beyond the fourth candidate
- candidate exhaustion entering dictionary registration
- registration confirm exactly once and registration Ctrl+G cancellation
- committed-candidate learning places it first on the next conversion
- digits, Shift+digits, symbols, and supported function keys
- caret arrows outside composition and DDSKK candidate keys inside it
- Windows Ctrl+C/Z/W/S/A shortcuts pass through when they belong to the app
- Ctrl+G locally terminates every composition/registration state
- no prior unconfirmed state can appear in a later input episode

## Input Hub and Lattice gate

- provider discovery, selection, capability description, and error reporting
  use one versioned contract
- engine-specific settings are hidden or disabled when unsupported
- provider switching cannot leak the previous provider's session
- Lattice typing, conversion, learning, segment selection, and segment resize
  pass both conformance tests and the TSF harness
- DDSKK-specific behavior is not incorrectly imposed on Lattice

## UI and integration gate

- candidate window follows the active text caret, flips at monitor edges, and
  sizes to its candidate content without following the mouse while inactive
- registration is a compact CorvusSKK-style modal surface and never duplicates
  parked document text
- the taskbar shows the NeLisp IME logo separately from the current mode;
  keyboard-closed `--` is gray
- Sumi has no obsolete resident pill/red `あ` surface
- Emacs can select Emacs DDSKK or NeLisp IME per buffer; Evil non-insert states
  close the Windows IME and cannot produce double conversion

## Reliability and release gate

- 10,000-key scripted run: zero loss, duplication, reordering, or stale reply
- provider kill, pipe timeout, host restart, focus change, and application exit
  fault tests recover without restarting the target application
- simultaneous Notepad, Edge, Windows Terminal, and Emacs sessions never share
  preedit/candidate state
- 24-hour soak: zero crash/freeze/data-loss event; private memory <= 768 MiB and
  no unbounded post-warm growth
- Windows CTest, framework/Lattice ERT, DDSKK session tests, TSF behavior tests,
  and settings/Sumi tests all pass from one documented verification command
- versioned deployment and rollback are verified without overwriting an older
  runtime directory
- seven consecutive days of normal use contain no open P0/P1 defect

P0 means crash, freeze, text loss/duplication, cross-application state leak, or
an unavailable emergency cancel.  P1 means a failed performance gate, broken
core conversion/registration, swallowed application shortcut, or persistently
incorrect candidate/mode UI.

## Explicitly after v1.0

- public code signing and a general-audience installer
- macOS/Linux native frontends
- complete compatibility with every interactive Emacs DDSKK command
- arbitrary third-party provider support beyond the stable provider contract
- cosmetic settings not required by the gates above
