;;; build.el --- Build sumi-skk-ui.exe -*- lexical-binding: t; -*-
;;
;; Orchestrates the build described in sumi-ui/README.md:
;;
;;   1. indicator/mode-logic.el (NeLisp restricted-dialect decision
;;      logic) -> mode-logic.o, via `nelisp-aot-compile-to-object'
;;      (:format 'coff) -- the exact call
;;      dev/sumi/backends/cairo-elisp/build-live.el's
;;      `sumi-build-compile-to-object' makes, and the exact object-mode
;;      contract dev/nelisp-sumi/build.el's own helper modules
;;      (src/nelisp-sumi-move.el etc.) are written against.
;;   2. indicator/pipe-client.c, indicator/settings.c, indicator/main.c
;;      (hand-authored GTK4/Cairo/Pango/Win32 glue, split across three
;;      translation units since Phase 3 -- pipe-client.c/settings.c
;;      have no GTK dependency and are directly reusable/testable, see
;;      settings.h's docstring) -> one .o each, via plain `gcc -c'.
;;
;; All four objects are then linked together with `gcc' into one
;; sumi-skk-ui.exe -- the same "AOT object + gcc link" step
;; build-live.el and dev/nelisp-sumi/build.el use, just with three more,
;; ordinarily-compiled objects added to the link line. See
;; sumi-ui/README.md for why this project does not compile main.c's
;; window/GTK/pipe logic through the NeLisp AOT compiler itself the way
;; dev/nelisp-sumi/build.el compiles its whole program that way.
;;
;; Usage (same invocation convention as dev/sumi and dev/nelisp-sumi):
;;   emacs -Q --batch -l build.el
;;
;; Env var overrides (all optional; mirrors
;; dev/sumi/backends/cairo-elisp/build-live.el's `sumi-build-env-or'):
;;   NELISP_ROOT       path to the dev/nelisp checkout providing
;;                      `nelisp-aot-compiler' (default: ../../nelisp,
;;                      i.e. sibling of this repo -- matches
;;                      dev/nelisp-skk-ime's own layout under dev/).
;;   MINGW_BIN          MSYS2 mingw64 bin dir (default: C:/msys64/mingw64/bin).
;;   PKG_CONFIG_PATH     (default: /c/msys64/mingw64/lib/pkgconfig).

(require 'cl-lib)

(defconst sumi-ui-root
  ;; `expand-file-name' up front so this is a real absolute path, never
  ;; a "~/..." abbreviation -- `default-directory' is set from it just
  ;; below, and `setenv "HOME"' further down would otherwise make any
  ;; *later* "~" expansion (e.g. `call-process''s cwd handling, which
  ;; consults `default-directory') resolve against the wrong HOME and
  ;; fail with a bogus "no such directory" error.
  (expand-file-name (file-name-directory (or load-file-name buffer-file-name))))
(setq default-directory sumi-ui-root)
(defconst sumi-ui-indicator-dir (expand-file-name "indicator" sumi-ui-root))
(defconst sumi-ui-target-dir (expand-file-name "target" sumi-ui-root))

(defun sumi-ui-env-or (name fallback)
  "Return environment NAME unless it is empty, otherwise FALLBACK."
  (let ((value (getenv name)))
    (if (and value (not (string-empty-p value))) value fallback)))

(defconst sumi-ui-nelisp-root
  (sumi-ui-env-or "NELISP_ROOT" (expand-file-name "../../nelisp" sumi-ui-root)))

(defconst sumi-ui-mingw-bin
  (sumi-ui-env-or "MINGW_BIN" "C:/msys64/mingw64/bin"))

(defconst sumi-ui-pkg-config-path
  (sumi-ui-env-or "PKG_CONFIG_PATH" "/c/msys64/mingw64/lib/pkgconfig"))

(defun sumi-ui-process-lines (program &rest args)
  "Run PROGRAM with ARGS and return its stdout as a list of lines.
Signals an error (including captured output) on nonzero exit."
  (with-temp-buffer
    (let ((status (apply #'call-process program nil t nil args)))
      (unless (eq status 0)
        (error "%s %s failed: %s" program (mapconcat #'identity args " ") (buffer-string)))
      (split-string (string-trim (buffer-string)) "[\r\n]+" t))))

(defconst sumi-ui-mingw-root
  (directory-file-name (expand-file-name ".." sumi-ui-mingw-bin)))

(defun sumi-ui-fix-mingw-path (flag)
  "Rewrite a leading MSYS-virtual \"/mingw64/...\" path in FLAG.
The mingw64 pkg-config.exe is relocatable: it correctly self-locates to
its real Windows install path (e.g. \"C:/msys64/mingw64/include/...\")
when its own argv[0] is an explicit path, as when this build.el's own
smoke test called it directly, but falls back to the POSIX-style
prefix literally baked into its .pc files (\"/mingw64/...\", only
meaningful inside an MSYS2 shell's automatic path translation) when
`call-process' resolves the bare program name \"pkg-config\" off PATH,
as every real build here does. A native mingw64 gcc.exe (no MSYS
runtime linkage) cannot resolve \"/mingw64/...\" at all, so every such
prefix is rewritten back to the real, already-resolved mingw64 root
before the flag ever reaches gcc.

Anchored to the START of the path (after an optional -I/-L option
prefix): pkg-config sometimes self-locates and emits real Windows
paths like \"-Ic:/msys64/mingw64/bin/../include\" -- an unanchored
replace corrupted those mid-string (\"c:/msys64C:/msys64/...\"), which
is exactly how a fully-working toolchain still failed to find glib.h."
  (if (string-match "\\`\\(-[IL]\\)?/mingw64/" flag)
      (concat (or (match-string 1 flag) "")
              sumi-ui-mingw-root "/"
              (substring flag (match-end 0)))
    flag))

(defun sumi-ui-pkg-config-flags (flag module)
  "Return `pkg-config FLAG MODULE' output split into a flag list."
  (mapcar #'sumi-ui-fix-mingw-path
          (split-string (car (sumi-ui-process-lines "pkg-config" flag module)) " " t)))

(defun sumi-ui-compile-mode-logic (obj)
  "Compile indicator/mode-logic.el to COFF object OBJ."
  (add-to-list 'load-path (expand-file-name "lisp" sumi-ui-nelisp-root))
  (add-to-list 'load-path (expand-file-name "src" sumi-ui-nelisp-root))
  (require 'nelisp-aot-compiler)
  (let* ((src (expand-file-name "mode-logic.el" sumi-ui-indicator-dir))
         (program (with-temp-buffer
                    (insert-file-contents src)
                    (goto-char (point-min))
                    (read (current-buffer)))))
    (princ (format "=== compile-to-object %s -> %s ===\n" src obj))
    (condition-case err
        (progn
          (nelisp-aot-compile-to-object program obj :format 'coff)
          (princ "MODE-LOGIC-OBJ-OK\n"))
      (error
       (princ (format "MODE-LOGIC-OBJ-ERR %S\n" err))
       (kill-emacs 1)))))

(defun sumi-ui-compile-c (stem obj cflags)
  "Compile indicator/STEM.c to object OBJ using CFLAGS."
  (let* ((src (expand-file-name (concat stem ".c") sumi-ui-indicator-dir)))
    (princ (format "=== gcc -c %s -> %s ===\n" src obj))
    (with-temp-buffer
      (let ((status (apply #'call-process "gcc" nil t nil "-c" "-Wall" "-Wextra" src
                           (append cflags (list "-o" obj)))))
        (princ (buffer-string)) ; always show warnings, not just on failure
        (unless (eq status 0)
          (princ (format "%s-OBJ-ERR\n" (upcase stem)))
          (kill-emacs 1))))
    (princ (format "%s-OBJ-OK\n" (upcase stem)))))

(defun sumi-ui-link-attempt (objs exe libs)
  "One `gcc' link attempt into EXE.  Returns (STATUS . OUTPUT)."
  (with-temp-buffer
    (let ((status (apply #'call-process "gcc" nil t nil
                         (append objs libs (list "-mwindows" "-o" exe)))))
      (cons status (buffer-string)))))

(defun sumi-ui-link (objs exe libs)
  "Link OBJS into EXE with LIBS.  Returns the actual path linked to.
-mwindows suppresses the console subsystem (this is a background GUI
utility, same as dev/nelisp-sumi/build.el's nelisp-sumi.exe), which
also means stdout is silently discarded unless a caller explicitly
redirects it -- exactly what sumi-ui/verify/verify.ps1 does to read the
mode-transition log.

Unlike POSIX (where an open-but-unlinked file just keeps its old
content for existing readers), Windows refuses to overwrite the image
file of a running process at all -- `gcc'/`ld' fails with \"Permission
denied\". That is expected, not exceptional, while iterating on this
app: an indicator pill and/or a settings window (launched via
--settings) are routinely left running across rebuilds, and the task
brief itself anticipates it (\"do NOT kill them\"). On that specific
failure this falls back to a sibling `sumi-skk-ui.new.exe' next to EXE
and links there instead, so a build can still succeed; the caller
reports whichever path this returns. Any other link failure still
aborts the build as before -- only a locked *output* file gets the
fallback, not a genuine link error (missing symbol, bad flag, etc.)."
  (princ (format "=== link -> %s ===\n" exe))
  (let* ((first (sumi-ui-link-attempt objs exe libs))
         (status (car first))
         (output (cdr first)))
    (cond
     ((eq status 0)
      (princ "LINK-OK\n")
      exe)
     ((string-match-p "Permission denied" output)
      (let* ((dir (file-name-directory exe))
             (base (file-name-base exe))
             (ext (file-name-extension exe))
             (fallback (expand-file-name (concat base ".new." ext) dir))
             (second (progn
                       (princ (format "LINK-ERR (locked, likely a running instance): %s" output))
                       (princ (format "=== retry link -> %s ===\n" fallback))
                       (sumi-ui-link-attempt objs fallback libs))))
        (unless (eq (car second) 0)
          (princ (format "LINK-ERR: %s\n" (cdr second)))
          (kill-emacs 1))
        (princ (format "LINK-OK (fallback, %s was locked) %s\n" exe fallback))
        fallback))
     (t
      (princ (format "LINK-ERR: %s\n" output))
      (kill-emacs 1)))))

(defun sumi-ui-main ()
  (unless (file-directory-p sumi-ui-nelisp-root)
    (error "NELISP_ROOT %s does not exist -- set the NELISP_ROOT env var" sumi-ui-nelisp-root))
  (setenv "PATH" (concat sumi-ui-mingw-bin path-separator (or (getenv "PATH") "")))
  (setenv "PKG_CONFIG_PATH" sumi-ui-pkg-config-path)
  (setenv "HOME" (expand-file-name ".tmp-home/sumi-ui-emacs-home" sumi-ui-root))
  (make-directory (getenv "HOME") t)
  (make-directory sumi-ui-target-dir t)
  (let* ((mode-logic-obj (expand-file-name "mode-logic.o" sumi-ui-target-dir))
         (pipe-client-obj (expand-file-name "pipe-client.o" sumi-ui-target-dir))
         (settings-obj (expand-file-name "settings.o" sumi-ui-target-dir))
         (main-obj (expand-file-name "main.o" sumi-ui-target-dir))
         (exe (expand-file-name "sumi-skk-ui.exe" sumi-ui-target-dir))
         (gtk-cflags (sumi-ui-pkg-config-flags "--cflags" "gtk4"))
         (pango-cflags (sumi-ui-pkg-config-flags "--cflags" "pangocairo"))
         (gtk-libs (sumi-ui-pkg-config-flags "--libs" "gtk4"))
         (pango-libs (sumi-ui-pkg-config-flags "--libs" "pangocairo"))
         (all-cflags (append gtk-cflags pango-cflags)))
    (sumi-ui-compile-mode-logic mode-logic-obj)
    ;; pipe-client.c/settings.c only need glib.h (for `gboolean') plus
    ;; plain <windows.h> -- gtk4's own cflags already cover glib's
    ;; include path, so reuse ALL-CFLAGS rather than pkg-config'ing glib
    ;; separately.
    (sumi-ui-compile-c "pipe-client" pipe-client-obj all-cflags)
    (sumi-ui-compile-c "settings" settings-obj all-cflags)
    (sumi-ui-compile-c "main" main-obj all-cflags)
    (let ((linked (sumi-ui-link
                   (list main-obj mode-logic-obj pipe-client-obj settings-obj) exe
                   ;; advapi32 for settings.c's RegGetValueW/RegSetKeyValueW/
                   ;; RegDeleteTreeW (Phase 3) -- not pulled in transitively
                   ;; by gtk4/pangocairo's own pkg-config libs.
                   (append (cl-remove-duplicates (append gtk-libs pango-libs) :test #'string=)
                           (list "-ladvapi32")))))
      (princ (format "SUMI-UI-BUILD-OK %s\n" linked)))))

(when noninteractive
  (sumi-ui-main))

;;; build.el ends here
