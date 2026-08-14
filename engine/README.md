# DDSKK engine protocol

The engine process keeps one serialized DDSKK session and communicates over
UTF-8 line-delimited stdio. `ddskk-engine-host.exe` will expose this process to
the TSF DLL through a per-user Windows named pipe.

Manual smoke test:

```powershell
@('HELLO 1', 'KEY 107', 'KEY 97', 'KEY 110', 'KEY 97', 'QUIT') |
  ..\nelisp\target\nelisp.exe --load engine/ddskk-engine-stdio.el
```

The final `STATE` text field is a sequence of fixed-width six-hex-digit Unicode
scalar values. `00304b00306a` is `かな`; `-` represents an empty string.
