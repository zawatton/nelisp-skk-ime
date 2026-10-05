This regression target compiles the production `MaybeShowModeIndicator`,
`FlushModeIndicator`, `LoadApplicationSettings`, `CaptureCaretRect`, and
`InlinePreedit::LastCaret` bodies extracted at CMake configuration time.
Only their dependencies are replaced by controlled sources: failed/successful
`GetTextExt`, inline caret, GUI-thread caret, mouse position, and popup calls.
The app settings checks use a private process-specific registry key and remove it.

Run from the repository root:

```powershell
cmake -S windows/test-host/mode-indicator -B build/indicator -G "Visual Studio 17 2022" -A x64
cmake --build build/indicator --config Release
ctest --test-dir build/indicator -C Release --verbose
```

On the original implementation the first case printed:

```text
no caret: anchor=777,888 popup=1 cursor_calls=1
FAIL no caret must suppress popup cursor_calls=1
```

The existing `ddskk-mode-indicator-test` target separately creates the actual
Win32 popup and checks its extended styles, full opacity, and hit-test result.

Use the standard `tsf-host.exe` for the five ordinary inline cases and
`input-rules-host.exe` for the four pairing cases, with a separate artifact
root for each case (the Emacs pairing subscriber scans that root's logs).
