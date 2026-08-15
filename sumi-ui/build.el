;;; build.el --- Build sumi-skk-ui.exe -*- lexical-binding: t; -*-
;;
;; Orchestrates the two-part build described in sumi-ui/README.md:
;;
;;   1. indicator/mode-logic.el (NeLisp restricted-dialect decision
;;      logic) -> mode-logic.o, via `nelisp-aot-compile-to-object'
;;      (:format 'coff) -- the exact call
;;      dev/sumi/backends/cairo-elisp/build-live.el's
;;      `sumi-build-compile-to-object' makes, and the exact object-mode
;;      contract dev/nelisp-sumi/build.el's own helper modules
;;      (src/nelisp-sumi-move.el etc.) are written against.
;;   2. indicator/main.c (hand-authored GTK4/Cairo/Pango/Win32 glue) ->
;;      main.o, via plain `gcc -c'.
;;
;; Both objects are then linked together with `gcc' into one
;; sumi-skk-ui.exe -- the same "AOT object + gcc link" step
;; build-live.el and dev/nelisp-sumi/build.el use, just with a second,
;; ordinarily-compiled object added to the link line. See
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
before the flag ever reaches gcc."
  (replace-regexp-in-string "/mingw64/" (concat sumi-ui-mingw-root "/") flag t t))

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

(defun sumi-ui-compile-main-c (obj cflags)
  "Compile indicator/main.c to object OBJ using CFLAGS."
  (let* ((src (expand-file-name "main.c" sumi-ui-indicator-dir)))
    (princ (format "=== gcc -c %s -> %s ===\n" src obj))
    (with-temp-buffer
      (let ((status (apply #'call-process "gcc" nil t nil "-c" "-Wall" "-Wextra" src
                           (append cflags (list "-o" obj)))))
        (princ (buffer-string)) ; always show warnings, not just on failure
        (unless (eq status 0)
          (princ "MAIN-C-OBJ-ERR\n")
          (kill-emacs 1))))
    (princ "MAIN-C-OBJ-OK\n")))

(defun sumi-ui-link (objs exe libs)
  "Link OBJS into EXE with LIBS.
-mwindows suppresses the console subsystem (this is a background GUI
utility, same as dev/nelisp-sumi/build.el's nelisp-sumi.exe), which
also means stdout is silently discarded unless a caller explicitly
redirects it -- exactly what sumi-ui/verify/verify.ps1 does to read the
mode-transition log."
  (princ (format "=== link -> %s ===\n" exe))
  (with-temp-buffer
    (let ((status (apply #'call-process "gcc" nil t nil
                         (append objs libs (list "-mwindows" "-o" exe)))))
      (unless (eq status 0)
        (princ (format "LINK-ERR: %s\n" (buffer-string)))
        (kill-emacs 1))))
  (princ "LINK-OK\n"))

(defun sumi-ui-main ()
  (unless (file-directory-p sumi-ui-nelisp-root)
    (error "NELISP_ROOT %s does not exist -- set the NELISP_ROOT env var" sumi-ui-nelisp-root))
  (setenv "PATH" (concat sumi-ui-mingw-bin path-separator (or (getenv "PATH") "")))
  (setenv "PKG_CONFIG_PATH" sumi-ui-pkg-config-path)
  (setenv "HOME" (expand-file-name ".tmp-home/sumi-ui-emacs-home" sumi-ui-root))
  (make-directory (getenv "HOME") t)
  (make-directory sumi-ui-target-dir t)
  (let* ((mode-logic-obj (expand-file-name "mode-logic.o" sumi-ui-target-dir))
         (main-obj (expand-file-name "main.o" sumi-ui-target-dir))
         (exe (expand-file-name "sumi-skk-ui.exe" sumi-ui-target-dir))
         (gtk-cflags (sumi-ui-pkg-config-flags "--cflags" "gtk4"))
         (pango-cflags (sumi-ui-pkg-config-flags "--cflags" "pangocairo"))
         (gtk-libs (sumi-ui-pkg-config-flags "--libs" "gtk4"))
         (pango-libs (sumi-ui-pkg-config-flags "--libs" "pangocairo")))
    (sumi-ui-compile-mode-logic mode-logic-obj)
    (sumi-ui-compile-main-c main-obj (append gtk-cflags pango-cflags))
    (sumi-ui-link (list main-obj mode-logic-obj) exe
                  (cl-remove-duplicates (append gtk-libs pango-libs) :test #'string=))
    (princ (format "SUMI-UI-BUILD-OK %s\n" exe))))

(when noninteractive
  (sumi-ui-main))

;;; build.el ends here
