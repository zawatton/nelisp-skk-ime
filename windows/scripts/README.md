# windows/scripts

Maintained deployment tooling for the live DDSKK IME installation. This
replaces four session-only scratchpad scripts that had accumulated the
real deployment procedure ad hoc; `deploy-live.ps1` is the single
supported entry point going forward.

## deploy-live.ps1

```powershell
pwsh -File windows\scripts\deploy-live.ps1 [-Dll] [-HostExe] [-Engine] [-Indicator] [-DryRun]
```

Four independently combinable switches:

| Switch       | Effect |
|--------------|--------|
| `-Dll`       | Copy `windows\build\Release\ddskk-ime.dll` into a new timestamped `%LOCALAPPDATA%\DDSKK\<stamp>` directory and repoint **only** the CLSID `InprocServer32` default value at it. |
| `-HostExe`   | Copy `windows\build\Release\ddskk-engine-host.exe` into the timestamped directory. Combined with the shared restart step, this updates `EngineHost` in the registry and restarts the live host. Named `-HostExe` rather than `-Host`: PowerShell's automatic `$Host` variable is read-only/constant, so a script parameter literally cannot be named `-Host` -- this failed at runtime (not at parse time) the first time this script was validated with `-DryRun`, which is exactly why that validation step exists. |
| `-Engine`    | Refresh the frozen live engine snapshot: robocopy the repository into a new `live-<stamp>` directory, prewarm it privately, then (via the shared restart step) update `Repository` and restart the live host onto it. |
| `-Indicator` | Launch `sumi-skk-ui.exe` (the mode indicator) detached on the default pipe, if present. |

`-HostExe` and `-Engine` share a single restart-and-verify step, so
`-HostExe -Engine` together restart the live host exactly once, already
pointed at both the new exe and the new snapshot. Passing none of the
four switches prints usage and does nothing.

### -DryRun

```powershell
pwsh -File windows\scripts\deploy-live.ps1 -Dll -HostExe -Engine -Indicator -DryRun
```

Prints every action the script would take -- file copies, registry
reads/writes, process stop/start, and live-pipe round trips -- and
performs none of them. It never touches the registry, never enumerates
or stops processes, and never opens a named pipe, so it has no
dependency on the target machine actually having DDSKK installed. This
is also how the script itself is validated: a syntax parse plus several
`-DryRun` invocations covering each switch and combination, run before
any real deployment.

Always run with `-DryRun` first when in doubt about what a given
combination of switches will do.

## Deployment model

**Timestamped, immutable directories.** Every deploy writes into a fresh
`%LOCALAPPDATA%\DDSKK\<yyyyMMdd-HHmmss>` directory; nothing is ever
copied over a previous deployment's files. This means:

- A previously deployed binary or snapshot is never mutated out from
  under a process that already has it open (loaded DLL, running host,
  in-flight `robocopy`-read engine files).
- Rolling back is just pointing the relevant registry value at an older
  timestamped directory that is still sitting on disk -- no rebuild or
  re-copy required.
- Old directories are not cleaned up by this script; that is a separate,
  deliberate decision left to the operator (or a future retention-policy
  script), not something a deploy script should do implicitly.

**Live snapshot frozen from the repository.** The engine host walks the
`Repository` directory to load Elisp sources at boot. Pointing it
directly at the working repository would mean any further work in that
repository (an in-progress edit, a `git checkout`, a merge) could
silently perturb a live IME session mid-use. `-Engine` instead robocopies
the repository (excluding `.git`, build output, and other VCS/build
noise) into an immutable `live-<stamp>` snapshot directory, plus its
`..\nelisp\src\nelisp-buffer.el` sibling dependency copied alongside it
at the same relative path the engine expects (the two source repositories
are normally siblings under `dev\`). The live host only ever points at
one of these frozen snapshots, never at the working tree.

**Why prewarm.** A freshly `robocopy`'d tree is, from Windows' point of
view, a large batch of brand-new files. The very first process to touch
each of those files pays real-time antivirus scanning on top of the
engine's own cold-load cost -- this was observed once to take roughly 38
minutes under concurrent build load, compared to a normal cold boot of a
few seconds. `-Engine` therefore boots the fresh snapshot once, before
switching anything live to it: on a **private** named pipe (a random
`ddskk-prewarm-<8 hex>` name) with a **private, temporary** user
dictionary (so it never touches the real one), it starts the host,
waits for `STATUS` to answer, then shuts that instance down. By the time
the live restart happens in step 5, every file in the snapshot has
already been scanned and the engine's own load path has already run
once, so the actual user-visible restart is fast.

## Constraints preserved from the original ad-hoc procedure

These were hard-won operational rules (one of them from an incident) and
are enforced structurally in the script, not just documented:

- **Only `ddskk-engine-host.exe` processes are ever stopped.** No other
  NeLisp process, and no application that merely has the DLL loaded, is
  ever touched.
- **The DLL change requires an application restart.** `-Dll` cannot force
  running applications to reload an in-process COM server; it prints a
  reminder instead. `DllRegisterServer` is never invoked -- its
  `Repository` derivation logic corrupted the registry once in the past.
- **Registry writes are limited to exactly three values**:
  `HKCU\Software\NativeIME\EngineHost`,
  `HKCU\Software\NativeIME\Repository`, and the CLSID `InprocServer32`
  default value. Nothing else under `HKCU\Software\NativeIME` is ever
  written by this script.
- **Env vars are explicitly cleared before starting the live host.**
  `DDSKK_PIPE_NAME`, `DDSKK_USER_JISYO`,
  `DDSKK_USER_JISYO_SAVE_BATCH_SIZE`, and `DDSKK_ENGINE_IDLE_GC_MS` are
  removed from the environment right before the live host is started, so
  it always serves the default pipe, default user dictionary, default
  save-batch size, and default idle-GC interval -- never a leftover
  probe/test override left behind by this or a parent shell.

## Superseded scratchpad scripts

`deploy-dll.ps1`, `deploy-host.ps1`, `deploy-jisyo-pipeline.ps1`, and
`refresh-live-snapshot.ps1` were session-scoped scripts written to work
out this procedure interactively. `deploy-live.ps1` supersedes all four;
new deployment work should extend this script (and this README) rather
than growing another scratchpad variant.
