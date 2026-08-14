# nelisp-skk-ime

A Windows Text Services Framework (TSF) input method that runs the real
DDSKK (Daredevil SKK) conversion engine on top of the [NeLisp](../nelisp)
runtime, in-process with a C++ TSF host. Dictionary lookups are relayed by
the C++ host to a running SKK dictionary server (skkserv-compatible) rather
than performed inside the engine process.

## Layout

```
vendor/ddskk/          DDSKK itself (git submodule, unmodified upstream source)
engine/                Elisp adapter and dispatcher loaded by the NeLisp engine process
  skk-nelisp-compat.el   Emacs-buffer API shim for NeLisp's native buffer
  skk-ime-session.el     Per-session hidden-buffer wrapper around DDSKK commands
  ddskk-engine.el        Load order + protocol dispatcher for one persistent session
  ddskk-engine-stdio.el  Stdio line-protocol runner (entry point for --load)
  ddskk-hotpath.el       Small native-compilation probes (+ prebuilt .neln artifact)
windows/                TSF DLL, engine host process, config UI, tests
test/                   Elisp-level smoke and session tests
docs/                   Design notes (see docs/windows-ime-architecture.md)
```

The engine process is launched by the C++ host as `nelisp.exe --load
engine/ddskk-engine-stdio.el`, with its working directory set to this
repository's root, so every `(load ...)` path inside `engine/` and `test/`
is resolved relative to the repository root.

## Build

From a Visual Studio 2022 Developer PowerShell:

```powershell
cmake -S windows -B build/windows -G "Visual Studio 17 2022" -A x64
cmake --build build/windows --config Debug
```

See `windows/README.md` for registration and interactive-test steps, and
`docs/windows-ime-architecture.md` for the architecture and IPC protocol.

## License

This project is licensed under the GNU General Public License v3.0 or
later (GPL-3.0-or-later); see `LICENSE`. It derives from and links against
[DDSKK (Daredevil SKK)](https://github.com/skk-dev/ddskk), vendored
unmodified as the `vendor/ddskk` git submodule. This is an independent
project and is not an official DDSKK release.
