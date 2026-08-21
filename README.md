# nelisp-skk-ime

**NeLisp IME** is a Windows Text Services Framework (TSF) input method.
Its internal architecture, **NeLisp Input Hub**, connects the Windows-facing
IME to selectable Japanese input engines such as DDSKK and Lattice. The
[NeLisp](https://github.com/zawatton/nelisp) runtime hosts those engines,
while Sumi provides the indicator, candidate window, and settings UI.

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

## Emacs: switch between Emacs DDSKK and NeLisp IME

Running Emacs DDSKK and the Windows NeLisp IME at the same time causes double
conversion. The following example makes Emacs DDSKK the default and allows
NeLisp IME to be selected per buffer. It also follows Evil state: NeLisp IME
opens only in `insert` and `replace`, and closes in Normal state.

```emacs-lisp
(define-minor-mode my-nelisp-ime-mode
  "Use the Windows NeLisp IME instead of Emacs DDSKK in this buffer."
  :init-value nil
  :lighter " NeIME"
  (if my-nelisp-ime-mode
      (when (bound-and-true-p skk-mode)
        (skk-mode -1))
    (unless (fboundp 'skk-mode)
      (require 'skk))
    (skk-mode 1))
  (my-w32-sync-nelisp-ime))

(defun my-w32-sync-nelisp-ime (&rest _)
  "Synchronize NeLisp IME with the current buffer and Evil state."
  (when (fboundp 'w32-set-ime-open-status)
    (w32-set-ime-open-status
     (and my-nelisp-ime-mode
          (memq (and (boundp 'evil-state) evil-state) '(insert replace))
          (not (bound-and-true-p skk-mode))))))

(defun my-w32-sync-selected-buffer-ime (&rest _)
  "Synchronize the IME using the selected window's buffer."
  (when-let ((window (selected-window)))
    (with-current-buffer (window-buffer window)
      (my-w32-sync-nelisp-ime))))

(defun my-w32-sync-after-skk-mode (&rest _)
  "Disable NeLisp IME whenever Emacs DDSKK is enabled."
  (when (bound-and-true-p skk-mode)
    (setq my-nelisp-ime-mode nil))
  (my-w32-sync-nelisp-ime))

(defun my-use-emacs-ddskk ()
  "Use Emacs DDSKK in the current buffer."
  (interactive)
  (my-nelisp-ime-mode -1)
  (message "Japanese input: Emacs DDSKK"))

(defun my-use-nelisp-ime ()
  "Use NeLisp IME in the current buffer."
  (interactive)
  (my-nelisp-ime-mode 1)
  (message "Japanese input: NeLisp IME"))

(defun my-toggle-japanese-input-backend ()
  "Toggle Emacs DDSKK and NeLisp IME in the current buffer."
  (interactive)
  (if my-nelisp-ime-mode
      (my-use-emacs-ddskk)
    (my-use-nelisp-ime)))

(when (eq system-type 'windows-nt)
  (add-hook 'focus-in-hook #'my-w32-sync-selected-buffer-ime)
  (add-hook 'buffer-list-update-hook #'my-w32-sync-selected-buffer-ime)
  (with-eval-after-load 'evil
    (dolist (hook '(evil-normal-state-entry-hook
                    evil-motion-state-entry-hook
                    evil-visual-state-entry-hook
                    evil-emacs-state-entry-hook
                    evil-insert-state-entry-hook
                    evil-replace-state-entry-hook))
      (add-hook hook #'my-w32-sync-nelisp-ime)))
  (with-eval-after-load 'skk
    (add-hook 'skk-mode-hook #'my-w32-sync-after-skk-mode)
    (unless (advice-member-p #'my-w32-sync-after-skk-mode 'skk-mode)
      (advice-add 'skk-mode :after #'my-w32-sync-after-skk-mode))))
```

Use `M-x my-toggle-japanese-input-backend` for normal switching, or select a
backend directly with `M-x my-use-emacs-ddskk` and `M-x my-use-nelisp-ime`.
The `NeIME` mode-line indicator means that the current buffer uses NeLisp IME;
otherwise it uses Emacs DDSKK. A key binding can be added if desired, for
example:

```emacs-lisp
(global-set-key (kbd "C-c C-j") #'my-toggle-japanese-input-backend)
```

## Build

DDSKK is a submodule, so clone recursively (or run `git submodule update
--init` in an existing checkout) — without it `vendor/ddskk` is empty and
the engine cannot load:

```powershell
git clone --recursive https://github.com/zawatton/nelisp-skk-ime.git
```

The engine also needs a built NeLisp runtime; the C++ host is pointed at
its executable through the per-user settings described in
`windows/README.md`.

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
