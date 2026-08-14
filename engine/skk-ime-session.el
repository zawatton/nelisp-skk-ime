;;; skk-ime-session.el --- Stateful DDSKK API for native IME hosts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 SKK Development Team

;; This file is part of Daredevil SKK.

;;; Commentary:

;; A native IME cannot depend on Emacs's command loop.  This module gives each
;; native input context its own hidden buffer and drives the existing DDSKK
;; commands with explicit key events.  It intentionally contains no kana or
;; conversion logic of its own.

;;; Code:

(require 'cl-lib)
(require 'skk)

(cl-defstruct (skk-ime-session
               (:constructor skk-ime-session--make))
  buffer
  (last-command nil))

(defun skk-ime-session--initialize-buffer ()
  "Initialize the current buffer for the available runtime."
  (if (fboundp 'skk-ime-session--initialize-native-buffer)
      (skk-ime-session--initialize-native-buffer)
    (setq-local skk-show-mode-enable nil)
    (setq-local skk-show-tooltip nil)
    (setq-local skk-status-indicator 'minor-mode)
    (skk-mode 1)))

(defun skk-ime-session-create ()
  "Create and initialize an isolated DDSKK input session."
  (let ((buffer (generate-new-buffer " *ddskk-ime-session*")))
    (with-current-buffer buffer
      (skk-ime-session--initialize-buffer))
    (skk-ime-session--make :buffer buffer)))

(defun skk-ime-session-live-p (session)
  "Return non-nil when SESSION still owns a live buffer."
  (and (skk-ime-session-p session)
       (buffer-live-p (skk-ime-session-buffer session))))

(defun skk-ime-session-destroy (session)
  "Destroy SESSION and release its hidden buffer."
  (when (skk-ime-session-live-p session)
    (kill-buffer (skk-ime-session-buffer session))
    (setf (skk-ime-session-buffer session) nil))
  nil)

(defmacro skk-ime-session--with-buffer (session &rest body)
  "Evaluate BODY in SESSION's buffer, rejecting a destroyed SESSION."
  (declare (indent 1) (debug t))
  `(progn
     (unless (skk-ime-session-live-p ,session)
       (error "DDSKK IME session is not live"))
     (with-current-buffer (skk-ime-session-buffer ,session)
       ,@body)))

(defun skk-ime-session-reset (session)
  "Clear SESSION and return it to hiragana direct-input mode."
  (skk-ime-session--with-buffer session
    (erase-buffer)
    (if (fboundp 'skk-ime-session--initialize-native-buffer)
        (skk-ime-session--initialize-native-buffer)
      (skk-kakutei-initialize)
      (skk-j-mode-on nil))
    (setf (skk-ime-session-last-command session) nil)
    (skk-ime-session-snapshot session)))

(defun skk-ime-session--active-keymap ()
  "Return the DDSKK minor-mode keymap that is active in this buffer.
Mirrors the `minor-mode-map-alist' precedence Emacs would apply: abbrev
mode shadows wide-latin, which shadows latin, and `skk-j-mode-map' is the
fallback kana map.  Every variable is `boundp'-guarded because a session
buffer can be read mid-initialization, before DDSKK has set its
mode-tracking variables or built its maps."
  (cond
   ((and (boundp 'skk-abbrev-mode) skk-abbrev-mode
         (boundp 'skk-abbrev-mode-map)) skk-abbrev-mode-map)
   ((and (boundp 'skk-jisx0208-latin-mode) skk-jisx0208-latin-mode
         (boundp 'skk-jisx0208-latin-mode-map)) skk-jisx0208-latin-mode-map)
   ((and (boundp 'skk-latin-mode) skk-latin-mode
         (boundp 'skk-latin-mode-map)) skk-latin-mode-map)
   ((boundp 'skk-j-mode-map) skk-j-mode-map)
   (t nil)))

(defun skk-ime-session--call-command (command)
  "Run COMMAND the way the Emacs command loop would for a self-inserting key.

Most DDSKK insert commands (`skk-insert', `skk-abbrev-insert',
`skk-jisx0208-latin-insert', ...) take a numeric repeat-count prefix and
behave correctly when given 1, matching an unprefixed key press.  A few
commands take an argument that is not a repeat count, so passing 1 would
be semantically wrong rather than merely an arity mismatch:

- `skk-kakutei' takes an optional WORD to confirm with, not a count; an
  unprefixed key press should confirm with the current candidate, i.e.
  call it with no arguments at all.
- `skk-backward-and-set-henkan-point' treats a non-nil ARG as an explicit
  \\[universal-argument] count and takes the simple `backward-char' path;
  an unprefixed key press must pass nil so it takes the char-type-aware
  boundary scan instead.
- `skk-try-completion' treats a non-nil ARG as \"force first candidate\";
  an unprefixed key press must pass nil so it keeps auto-detecting
  first-vs-continue from `last-command' (repeated presses cycle
  candidates instead of restarting the search every time).

`skk-toggle-characters' has a mandatory but unused ARG parameter, so it is
deliberately left out of this `cond': the default branch below already
calls it with 1, which is both arity-correct and semantically harmless."
  (cond
   ((eq command 'skk-kakutei) (skk-kakutei))
   ((eq command 'skk-backward-and-set-henkan-point)
    (skk-backward-and-set-henkan-point nil))
   ((eq command 'skk-try-completion) (skk-try-completion nil))
   (t
    ;; Most DDSKK insert commands take a numeric prefix argument; a few take
    ;; none.  Try the prefix form first and fall back on an arity error.
    (condition-case nil
        (funcall command 1)
      (wrong-number-of-arguments (funcall command))))))

(defun skk-ime-session-feed-key (session key)
  "Feed character KEY to DDSKK in SESSION and return a state snapshot.

KEY is a character integer.  The key is dispatched through the DDSKK
minor-mode keymap that is active in this buffer, exactly as the Emacs
command loop would: a key the active map does not bind falls through to
`self-insert-command', which is what makes `skk-latin-mode' type ASCII
instead of kana."
  (unless (characterp key)
    (signal 'wrong-type-argument (list 'characterp key)))
  (skk-ime-session--with-buffer session
    (let* ((previous (skk-ime-session-last-command session))
           (map (skk-ime-session--active-keymap))
           (command (and map (lookup-key map (string key)))))
      (unless (or (and (symbolp command) (fboundp command))
                  (functionp command))
        (setq command 'self-insert-command))
      (setq last-command previous
            last-command-event key
            this-command command)
      (skk-ime-session--call-command command)
      (setf (skk-ime-session-last-command session) this-command))
    (skk-ime-session-snapshot session)))

(defun skk-ime-session-feed-string (session string)
  "Feed every character in STRING to SESSION and return the final snapshot."
  (unless (stringp string)
    (signal 'wrong-type-argument (list 'stringp string)))
  (let ((snapshot (skk-ime-session-snapshot session)))
    (dolist (key (string-to-list string) snapshot)
      (setq snapshot (skk-ime-session-feed-key session key)))))

(defun skk-ime-session-control (session control)
  "Apply native CONTROL to SESSION and return its state snapshot.

CONTROL is one of `backspace', `convert', `previous', `commit', or `cancel'."
  (skk-ime-session--with-buffer session
    (pcase control
      ('backspace
       (cond
        ((not (equal skk-prefix ""))
         (setq skk-prefix "" skk-current-rule-tree nil))
        ((> (point) (point-min))
         (delete-region (1- (point)) (point)))))
      ('commit
       (when skk-henkan-mode (skk-kakutei)))
      ('convert
       (when skk-henkan-mode (skk-start-henkan 1)))
      ('previous
       (when (eq skk-henkan-mode 'active) (skk-previous-candidate 1)))
      ('cancel
       (when skk-henkan-mode
         (let ((start (and (markerp skk-henkan-start-point)
                           (marker-position skk-henkan-start-point))))
           (when start (delete-region start (point-max)))
           ;; `skk-henkan-start-point' is immediately after the visible ▽.
           (when (and start (> start (point-min)))
             (delete-region (1- start) (point-max)))
           (skk-kakutei-initialize)))
       (setq skk-prefix "" skk-current-rule-tree nil)
       ;; The native host sends `cancel' for Ctrl+J when returning to kana
       ;; input.  In DDSKK the C-j binding exists in every mode map and ends
       ;; up back in kana; mirror that here so the engine's mode cannot drift
       ;; out of sync with the host's own flag.
       (when (fboundp 'skk-j-mode-on)
         (skk-j-mode-on (and (boundp 'skk-katakana) skk-katakana))))
      (_ (error "Unknown DDSKK IME control: %S" control)))
    (setf (skk-ime-session-last-command session) control)
    (skk-ime-session-snapshot session)))

(defun skk-ime-session-snapshot (session)
  "Return a platform-neutral snapshot of SESSION.

`:text' is the complete session buffer.  `:composition-start' is a zero-based
offset into that string, or nil outside ▽/▼ mode.  `:pending-romaji' contains
an incomplete DDSKK rule-tree prefix such as the letter n."
  (skk-ime-session--with-buffer session
    (let* ((composition-p (memq skk-henkan-mode '(on active)))
           (start (and composition-p
                       (markerp skk-henkan-start-point)
                       (marker-position skk-henkan-start-point))))
      (list :mode (cond
                   ((eq skk-henkan-mode 'active) 'candidate)
                   ((eq skk-henkan-mode 'on) 'preedit)
                   (skk-abbrev-mode 'abbrev)
                   (skk-jisx0208-latin-mode 'wide-latin)
                   (skk-latin-mode 'latin)
                   (skk-katakana 'katakana)
                   (t 'hiragana))
            :text (buffer-substring-no-properties (point-min) (point-max))
            :cursor (1- (point))
            :composition-start (and start (1- start))
            :pending-romaji (or skk-prefix "")
            :candidate-index (if (eq skk-henkan-mode 'active)
                                 skk-henkan-count -1)
            :candidates (if (eq skk-henkan-mode 'active)
                            (mapcar (lambda (candidate)
                                      (if (consp candidate)
                                          (car candidate) candidate))
                                    skk-henkan-list)
                          nil)))))

(provide 'skk-ime-session)

;;; skk-ime-session.el ends here
