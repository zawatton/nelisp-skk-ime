;;; nelisp-ime-emacs.el --- Evil and inline Windows NeLisp IME integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 nelisp-skk-ime contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Native Windows TSF integration; no Emacs input method or evil dependency.
;; Configure Apps\emacs.exe once as described in README.org.

;;; Code:
(require 'cl-lib)
(require 'json)
(defgroup nelisp-ime-emacs nil "Windows NeLisp IME integration." :group 'environment)
(defcustom nelisp-ime-emacs-open-states '(insert replace)
  "Evil states whose entry opens the IME in the selected buffer."
  :type '(repeat symbol))
(defcustom nelisp-ime-emacs-open-mode-function nil
  "Function selecting SKK mode for an opening or a changed editing context.
Return `latin' for ASCII with the IME open, `kana' for hiragana, or nil to
preserve its mode. Called in the selected window's buffer. Requires inline
preedit and a core supporting MODE requests. An unchanged return value never
reasserts a mode during typing: C-j remains free to switch latin to kana."
  :type '(choice (const nil) function))
(defvar nelisp-ime-emacs--open-mode-context nil)
(defvar nelisp-ime-emacs--pending-open-mode nil)

(defun nelisp-ime-emacs--send-open-mode ()
  (when (and nelisp-ime-emacs--pending-open-mode
             (process-live-p nelisp-ime-emacs--inline-client)
             (process-get nelisp-ime-emacs--inline-client 'authenticated))
    (when (nelisp-ime-emacs--inline-send
           nelisp-ime-emacs--inline-client
           (format "MODE %s\n" nelisp-ime-emacs--pending-open-mode))
      (setq nelisp-ime-emacs--pending-open-mode nil))))

(defun nelisp-ime-emacs--request-open-mode (open &optional force)
  "Request the selected context's mode once; FORCE marks a new opening."
  (if (not open)
      (setq nelisp-ime-emacs--open-mode-context nil
            nelisp-ime-emacs--pending-open-mode nil)
    (when nelisp-ime-emacs-open-mode-function
      (with-current-buffer (window-buffer (selected-window))
        (let* ((mode (funcall nelisp-ime-emacs-open-mode-function))
               (context (list (selected-frame) (current-buffer) mode)))
          (unless (memq mode '(nil kana latin))
            (error "IME open mode must be nil, kana or latin: %S" mode))
          (when (or force (not (equal context nelisp-ime-emacs--open-mode-context)))
            (setq nelisp-ime-emacs--open-mode-context context
                  nelisp-ime-emacs--pending-open-mode mode)
            (nelisp-ime-emacs--send-open-mode)))))))

(defun nelisp-ime-emacs--check-open-mode ()
  "Detect a context transition without overriding IME mode keys."
  (when (and nelisp-ime-emacs-mode nelisp-ime-emacs-open-mode-function
             (not (minibufferp)))
    (nelisp-ime-emacs--request-open-mode
     (if (bound-and-true-p evil-local-mode)
         (nelisp-ime-emacs--desired-open)
       (and (fboundp 'w32-get-ime-open-status) (w32-get-ime-open-status))))))

(defcustom nelisp-ime-emacs-poll-interval 0.1
  "Seconds between focused-frame registry polls."
  :type 'number)
(defcustom nelisp-ime-emacs-registry-key
  (or (getenv "NATIVEIME_REGISTRY_KEY") "Software\\NativeIME")
  "HKCU settings key shared with the DLL."
  :type 'string)
(defcustom nelisp-ime-emacs-dark-colors
  '(("hiragana" . "pink") ("katakana" . "spring green")
    ("jisx0201" . "thistle") ("wide-latin" . "gold")
    ("latin" . "gray") ("abbrev" . "orange"))
  "Cursor colors on dark frames."
  :type '(alist :key-type string :value-type color))
(defcustom nelisp-ime-emacs-light-colors
  '(("hiragana" . "coral4") ("katakana" . "forest green")
    ("jisx0201" . "blueviolet") ("wide-latin" . "gold")
    ("latin" . "ivory4") ("abbrev" . "dark orange"))
  "Cursor colors on light frames."
  :type '(alist :key-type string :value-type color))
(defcustom nelisp-ime-emacs-mode-line t
  "Display a mode label in the global mode line."
  :type 'boolean)
(defcustom nelisp-ime-emacs-inline-preedit t
  "Render the IME's preedit inline while `nelisp-ime-emacs-mode' is on.
On Windows this is enabled by default.  Elsewhere, explicitly set
`nelisp-ime-emacs-inline-directory' or NELISP_IME_INLINE_DIR to opt in."
  :type 'boolean
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (and (bound-and-true-p nelisp-ime-emacs-mode)
                    (fboundp 'nelisp-ime-emacs--inline-start))
           (if value (nelisp-ime-emacs--inline-start)
             (nelisp-ime-emacs--inline-stop)))))
(defcustom nelisp-ime-emacs-inline-directory nil
  "Local discovery directory, or nil for the Windows default.
NELISP_IME_INLINE_DIR takes precedence.  The Windows default is
DDSKK/emacs-inline under LOCALAPPDATA.  Setting a directory also opts
into inline preedit on other systems."
  :type '(choice (const nil) directory)
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (and (bound-and-true-p nelisp-ime-emacs-mode)
                    (fboundp 'nelisp-ime-emacs--inline-start))
           (nelisp-ime-emacs--inline-stop)
           (nelisp-ime-emacs--inline-start))))
(defface nelisp-ime-emacs-preedit '((t (:inherit underline)))
  "Face for inline IME composition text.")
(defvar nelisp-ime-emacs-before-open-hook nil
  "Predicates called before opening. Any nil return vetoes opening.
For example, add `nelisp-ime-emacs-outside-org-src-p'.")
(defvar nelisp-ime-emacs--timer nil)
(defvar nelisp-ime-emacs--reconcile-timer nil)
(defvar nelisp-ime-emacs--selection nil)
(defvar nelisp-ime-emacs--label "")
(defvar nelisp-ime-emacs--base-mode "hiragana")
(defvar nelisp-ime-emacs--cursors (make-hash-table :test #'eq))
(defvar nelisp-ime-emacs--ime-colors (make-hash-table :test #'eq)
  "Active IME cursor color per frame, independent of transient labels.")
(defvar nelisp-ime-emacs--closing-frames (make-hash-table :test #'eq)
  "Frames with one confirmed closed snapshot; require a second to restore.")
(defvar nelisp-ime-emacs--warned nil)
(defvar nelisp-ime-emacs-mode nil)
(defvar nelisp-ime-emacs--inline-server nil)
(defvar nelisp-ime-emacs--inline-client nil)
(defvar nelisp-ime-emacs--inline-connections nil)
(defvar nelisp-ime-emacs--inline-token nil)
(defvar nelisp-ime-emacs--inline-file nil)
(defvar nelisp-ime-emacs--inline-overlay nil)
(defvar nelisp-ime-emacs--inline-warned nil)
(defvar nelisp-ime-emacs--inline-test-pid nil
  "Override the discovery PID and HELLO PID in tests only.")
(defvar evil-state)
(declare-function w32-read-registry "w32fns.c" (root key name))
(declare-function w32-set-ime-open-status "w32fns.c" (status))
(declare-function w32-get-ime-open-status "w32fns.c" ())
(declare-function evil-refresh-cursor "evil-core")

(defun nelisp-ime-emacs-outside-org-src-p ()
  "Permit opening only outside Org source blocks."
  (not (and (derived-mode-p 'org-mode)
            (fboundp 'org-in-src-block-p) (org-in-src-block-p))))

(defun nelisp-ime-emacs--state ()
  (if (bound-and-true-p evil-local-mode) evil-state 'insert))

(defun nelisp-ime-emacs--focused-frame ()
  (cl-find-if (lambda (frame) (eq (frame-focus-state frame) t)) (frame-list)))

(defun nelisp-ime-emacs--restore (frame)
  (remhash frame nelisp-ime-emacs--closing-frames)
  (remhash frame nelisp-ime-emacs--ime-colors)
  (when (frame-live-p frame)
    (with-selected-frame frame
      (let ((color (gethash frame nelisp-ime-emacs--cursors)))
        (when (and color (not (equal color (frame-parameter frame 'cursor-color))))
          (set-cursor-color color))
        (remhash frame nelisp-ime-emacs--cursors)
        (when (and color (bound-and-true-p evil-local-mode)
                   (fboundp 'evil-refresh-cursor))
          (evil-refresh-cursor))))))

(defun nelisp-ime-emacs--cursor-color (frame)
  "Resolve the current script's DDSKK override or background palette."
  (let ((variable (cdr (assoc nelisp-ime-emacs--base-mode
                              '(("hiragana" . skk-cursor-hiragana-color)
                                ("katakana" . skk-cursor-katakana-color)
                                ("jisx0201" . skk-cursor-jisx0201-color)
                                ("wide-latin" . skk-cursor-jisx0208-latin-color)
                                ("latin" . skk-cursor-latin-color)
                                ("abbrev" . skk-cursor-abbrev-color))))))
    (if (and variable (boundp variable)) (symbol-value variable)
      (cdr (assoc nelisp-ime-emacs--base-mode
                  (if (eq (or frame-background-mode
                              (frame-parameter frame 'background-mode)) 'dark)
                      nelisp-ime-emacs-dark-colors nelisp-ime-emacs-light-colors))))))

(defun nelisp-ime-emacs--evil-set-cursor-color (function color)
  "Keep Evil's shape updates without resetting an active IME color."
  (let ((ime-color (and nelisp-ime-emacs-mode
                        (with-current-buffer (window-buffer (selected-window))
                          (memq (nelisp-ime-emacs--state) nelisp-ime-emacs-open-states))
                        (gethash (selected-frame) nelisp-ime-emacs--ime-colors))))
    (if ime-color
        (unless (equal ime-color (frame-parameter nil 'cursor-color))
          (funcall function ime-color))
      (funcall function color))))

(defun nelisp-ime-emacs--state-entry ()
  "Follow an Evil state entry only in the selected window's buffer."
  (when (and nelisp-ime-emacs-mode (bound-and-true-p evil-local-mode)
             (bound-and-true-p evil-state)
             (eq (current-buffer) (window-buffer (selected-window))))
     (let ((open (and (memq evil-state nelisp-ime-emacs-open-states)
                     (run-hook-with-args-until-failure
                      'nelisp-ime-emacs-before-open-hook))))
      (when (fboundp 'w32-set-ime-open-status)
        (w32-set-ime-open-status (and open t)))
      (nelisp-ime-emacs--request-open-mode open t)
      (unless open
        (setq nelisp-ime-emacs--label "")
        (nelisp-ime-emacs--restore (selected-frame))))))

(defun nelisp-ime-emacs--read (key name)
  (when (fboundp 'w32-read-registry)
    (condition-case nil (w32-read-registry 'HKCU key name) (error nil))))

(defun nelisp-ime-emacs--selected-context ()
  "Return the real selected window and its buffer, independent of current buffer."
  (let ((window (selected-window)))
    (cons window (window-buffer window))))

(defun nelisp-ime-emacs--desired-open ()
  "Compute the selected buffer's requested IME status at its window point."
  (let ((window (selected-window)))
    (with-current-buffer (window-buffer window)
      (save-excursion
        (goto-char (window-point window))
        (and (bound-and-true-p evil-local-mode)
             (bound-and-true-p evil-state)
             (memq evil-state nelisp-ime-emacs-open-states)
             (run-hook-with-args-until-failure
              'nelisp-ime-emacs-before-open-hook)
             t)))))

(defun nelisp-ime-emacs--reconcile ()
  "Reconcile a coalesced selection or focus event with the actual IME status."
  (setq nelisp-ime-emacs--reconcile-timer nil)
  (when nelisp-ime-emacs-mode
    (setq nelisp-ime-emacs--selection (nelisp-ime-emacs--selected-context))
    ;; Minibuffer entry/exit retains its existing behavior.
    (unless (minibufferp (cdr nelisp-ime-emacs--selection))
      (when (and (fboundp 'w32-get-ime-open-status)
                 (fboundp 'w32-set-ime-open-status))
        (let ((open (nelisp-ime-emacs--desired-open)))
          (unless (eq open (and (w32-get-ime-open-status) t))
            (w32-set-ime-open-status open)
            (nelisp-ime-emacs--request-open-mode open t)
            (unless open
              (setq nelisp-ime-emacs--label "")
              (nelisp-ime-emacs--restore (selected-frame)))))))))

(defun nelisp-ime-emacs--schedule-reconcile ()
  (unless nelisp-ime-emacs--reconcile-timer
    (setq nelisp-ime-emacs--reconcile-timer
          (run-at-time 0 nil #'nelisp-ime-emacs--reconcile))))

(defun nelisp-ime-emacs--selection-change (frame)
  "Handle global window hooks for FRAME, ignoring unchanged selections."
  (when (and nelisp-ime-emacs-mode (eq frame (selected-frame))
             (not (equal nelisp-ime-emacs--selection
                         (nelisp-ime-emacs--selected-context))))
    (nelisp-ime-emacs--schedule-reconcile)))

(defun nelisp-ime-emacs--focus-change ()
  "Reconcile when the selected frame gains focus."
  (when (and nelisp-ime-emacs-mode
             (eq (frame-focus-state (selected-frame)) t))
    (nelisp-ime-emacs--schedule-reconcile)))

;;;###autoload
(defun nelisp-ime-emacs-describe ()
  "Show the selected buffer's Evil state and desired/actual IME status."
  (interactive)
  (let* ((buffer (window-buffer (selected-window)))
         (state (with-current-buffer buffer
                  (and (boundp 'evil-state) evil-state)))
         (desired (nelisp-ime-emacs--desired-open))
         (actual (if (fboundp 'w32-get-ime-open-status)
                     (if (w32-get-ime-open-status) "open" "closed")
                   "unavailable"))
         (mode (nelisp-ime-emacs--read
                (format "%s\\Clients\\%d" nelisp-ime-emacs-registry-key (emacs-pid))
                "mode")))
    (message "Buffer: %s; Evil state: %s; desired IME: %s; actual IME: %s; published mode: %s"
             (buffer-name buffer) state (if desired "open" "closed") actual
             (or mode "unavailable"))))

(defun nelisp-ime-emacs--check-settings ()
  (when (and (fboundp 'w32-read-registry) (not nelisp-ime-emacs--warned)
             (not (equal 1 (nelisp-ime-emacs--read
                            (concat nelisp-ime-emacs-registry-key "\\Apps\\emacs.exe")
                            "PublishState"))))
    (setq nelisp-ime-emacs--warned t)
    (display-warning 'nelisp-ime-emacs
                     "Apps\\emacs.exe\\PublishState is off; set DWORD 1 (see README.org).")))

(defun nelisp-ime-emacs--poll ()
  "Read a consistent state only while a frame has focus."
  (when-let* ((frame (and nelisp-ime-emacs-mode
                         (nelisp-ime-emacs--focused-frame))))
    (with-selected-frame frame
      (nelisp-ime-emacs--check-settings)
      (let* ((key (format "%s\\Clients\\%d" nelisp-ime-emacs-registry-key (emacs-pid)))
             (revision (nelisp-ime-emacs--read key "revision"))
             (sequence (nelisp-ime-emacs--read key "sequence"))
             (mode (nelisp-ime-emacs--read key "mode"))
             (open (nelisp-ime-emacs--read key "open")))
        (when (and sequence (integerp revision) (zerop (% revision 2))
                   (equal revision (nelisp-ime-emacs--read key "revision"))
                   (equal sequence (nelisp-ime-emacs--read key "sequence")))
          ;; Every side effect below forces a frame or mode-line redisplay,
          ;; which costs 10-30 ms in large buffers; at 10 Hz that is a
          ;; sizable share of a core, so apply only actual changes.
          (let* ((old-label nelisp-ime-emacs--label)
                 (closed (and (equal open 0)
                              ;; Native status may lag a focus/composition
                              ;; publication.  Require agreement, then two
                              ;; polls so a one-poll close cannot flash.
                              (or (not (display-graphic-p frame))
                                  (not (fboundp 'w32-get-ime-open-status))
                                  (not (w32-get-ime-open-status)))))
                 (confirmed (and closed (gethash frame nelisp-ime-emacs--closing-frames))))
            (if closed (puthash frame t nelisp-ime-emacs--closing-frames)
              (remhash frame nelisp-ime-emacs--closing-frames))
            (cond
             ((or (not (memq (nelisp-ime-emacs--state) nelisp-ime-emacs-open-states))
                  confirmed)
                (unless (equal old-label "")
                  (setq nelisp-ime-emacs--label "")
                  (nelisp-ime-emacs--restore frame)))
             ((equal open 1)
              ;; Preedit/candidate/registration are engine states, not scripts.
              ;; Retain the last input script for their cursor and label.
              (when (member mode '("hiragana" "katakana" "jisx0201" "wide-latin" "latin" "abbrev"))
                (setq nelisp-ime-emacs--base-mode mode))
              (unless (gethash frame nelisp-ime-emacs--cursors)
                (puthash frame (frame-parameter frame 'cursor-color) nelisp-ime-emacs--cursors))
              (let ((color (nelisp-ime-emacs--cursor-color frame)))
                (unless (equal color (gethash frame nelisp-ime-emacs--ime-colors))
                  (puthash frame color nelisp-ime-emacs--ime-colors)
                  (when (and color (not (equal color (frame-parameter frame 'cursor-color))))
                    (set-cursor-color color))))
              (setq nelisp-ime-emacs--label
                    (or (cdr (assoc nelisp-ime-emacs--base-mode
                                    '(("hiragana" . "[あ]") ("katakana" . "[ア]")
                                      ("jisx0201" . "[ｱ]") ("wide-latin" . "[Ａ]")
                                      ("latin" . "[A]") ("abbrev" . "[aA]")))) ""))))
            (unless (equal old-label nelisp-ime-emacs--label)
              (force-mode-line-update t))))))))

(defun nelisp-ime-emacs--install-evil-hooks ()
  (advice-add 'evil-set-cursor-color :around #'nelisp-ime-emacs--evil-set-cursor-color)
  (dolist (state '(normal insert replace visual motion operator emacs))
    (add-hook (intern (format "evil-%s-state-entry-hook" state))
              #'nelisp-ime-emacs--state-entry)))

(with-eval-after-load 'evil
  (when nelisp-ime-emacs-mode (nelisp-ime-emacs--install-evil-hooks)))

(defun nelisp-ime-emacs--inline-directory ()
  (or (let ((directory (getenv "NELISP_IME_INLINE_DIR")))
        (and directory (not (equal directory "")) directory))
      nelisp-ime-emacs-inline-directory
      (and (eq system-type 'windows-nt) (getenv "LOCALAPPDATA")
           (expand-file-name "DDSKK/emacs-inline" (getenv "LOCALAPPDATA")))))

(defun nelisp-ime-emacs--inline-pid ()
  (or nelisp-ime-emacs--inline-test-pid (emacs-pid)))

(defun nelisp-ime-emacs--inline-random-token ()
  "Return 128 bits of OS-backed entropy as 32 hexadecimal characters."
  (require 'gnutls)
  (let ((bytes
         (if (memq 'digests (gnutls-available-p))
             ;; iv-auto uses GnuTLS's cryptographic random generator.
             (gnutls-hash-digest 'SHA256 '(iv-auto 16))
           (with-temp-buffer
             (set-buffer-multibyte nil)
             (insert-file-contents-literally "/dev/urandom" nil 0 16)
             (buffer-string)))))
    (unless (and (stringp bytes) (>= (length bytes) 16))
      (error "No cryptographic random source for inline preedit"))
    (mapconcat (lambda (byte) (format "%02x" byte)) (substring bytes 0 16) "")))

(defun nelisp-ime-emacs--inline-warn (error-data)
  (unless nelisp-ime-emacs--inline-warned
    (setq nelisp-ime-emacs--inline-warned t)
    (condition-case nil
        (display-warning 'nelisp-ime-emacs
                         (concat "Inline preedit: " (error-message-string error-data)))
      (error nil))))

(defun nelisp-ime-emacs--inline-clear ()
  (when (overlayp nelisp-ime-emacs--inline-overlay)
    (delete-overlay nelisp-ime-emacs--inline-overlay))
  (setq nelisp-ime-emacs--inline-overlay nil))

(defun nelisp-ime-emacs--inline-move ()
  (when nelisp-ime-emacs--inline-overlay
    (let* ((window (selected-window)) (buffer (window-buffer window))
           (position (window-point window)))
      (move-overlay nelisp-ime-emacs--inline-overlay position position buffer)
      (overlay-put nelisp-ime-emacs--inline-overlay 'window window))))

(defun nelisp-ime-emacs--inline-render (text cursor)
  ;; The cursor needs a glyph, including at end of text and before a
  ;; newline.  The newline carrier needs a drawable pixel to produce a glyph;
  ;; the endpoint carrier can have zero width.  Integer 1 also overrides
  ;; the visible buffer cursor.
  (let ((display (if (or (= cursor (length text)) (= (aref text cursor) ?\n))
                     (concat (substring text 0 cursor)
                             (propertize " " 'display
                                         `(space :width ,(if (= cursor (length text)) 0 '(1))))
                             (substring text cursor))
                   (copy-sequence text))))
    (put-text-property 0 (length display) 'face 'nelisp-ime-emacs-preedit display)
    (put-text-property cursor (1+ cursor) 'cursor 1 display)
    (unless (and (overlayp nelisp-ime-emacs--inline-overlay)
                 (overlay-buffer nelisp-ime-emacs--inline-overlay))
      (setq nelisp-ime-emacs--inline-overlay
            (make-overlay (window-point) (window-point)
                          (window-buffer (selected-window)))))
    (overlay-put nelisp-ime-emacs--inline-overlay 'after-string display)
    (nelisp-ime-emacs--inline-move)))

;;; Pair requests are scoped to the selected buffer and expire after two seconds.
(defconst nelisp-ime-emacs--inline-pair-window 2.0
  "Maximum pairing request and insertion age in seconds.")
(defvar nelisp-ime-emacs--inline-pair nil)
(defvar-local nelisp-ime-emacs--inline-insertion nil)

(defun nelisp-ime-emacs--inline-pair-clear ()
  (when nelisp-ime-emacs--inline-pair
    (set-marker (nth 1 nelisp-ime-emacs--inline-pair) nil))
  (setq nelisp-ime-emacs--inline-pair nil))

(defun nelisp-ime-emacs--inline-after-change (beg end old)
  ;; Record real buffer insertion, never an overlay or replacement.  Defer
  ;; the closer until hooks are enabled again so modification hooks see it.
  (when (and (> old 0) nelisp-ime-emacs--inline-pair
             (eq (current-buffer) (marker-buffer (nth 1 nelisp-ime-emacs--inline-pair))))
    (nelisp-ime-emacs--inline-pair-clear))
  (setq nelisp-ime-emacs--inline-insertion
        (and (= old 0) (< beg end)
             (list beg end (float-time) (buffer-chars-modified-tick)))))

(defun nelisp-ime-emacs--inline-pair-apply ()
  (when nelisp-ime-emacs--inline-pair
    (pcase-let* ((`(,closer ,marker ,deadline ,opener) nelisp-ime-emacs--inline-pair)
                 (buffer (marker-buffer marker))
                 (window (selected-window)))
      (if (or (> (float-time) deadline) (not (buffer-live-p buffer))
              (not (eq buffer (window-buffer window))))
          (nelisp-ime-emacs--inline-pair-clear)
        (with-current-buffer buffer
          (let* ((position (window-point window))
                 (recent nelisp-ime-emacs--inline-insertion)
                 (size (and opener (length opener))))
            (cond
             ((or buffer-read-only
                  (and (minibufferp) (not (eq window (active-minibuffer-window)))))
              (nelisp-ime-emacs--inline-pair-clear))
             ((and recent (> (- (float-time) (nth 2 recent))
                             nelisp-ime-emacs--inline-pair-window))
              (nelisp-ime-emacs--inline-pair-clear))
             ((and recent (= (nth 3 recent) (buffer-chars-modified-tick)))
              ;; A request received before insertion anchors at its beginning;
              ;; one received after insertion anchors at its end.
              (when (and size (= position (nth 1 recent))
                         (= size (- position (car recent)))
                         (memq (marker-position marker) (list (car recent) position))
                         (equal opener (buffer-substring-no-properties (car recent) position)))
                (nelisp-ime-emacs--inline-pair-clear)
                (let ((undo-before buffer-undo-list))
                  (condition-case nil
                    (save-excursion
                      (goto-char position)
                      ;; Drop only the immediately preceding opener's boundary.
                      (let ((entry (and (listp buffer-undo-list)
                                        (if (null (car-safe buffer-undo-list))
                                            (cadr buffer-undo-list)
                                          (car-safe buffer-undo-list)))))
                        (when (and (consp entry) (equal entry (cons (car recent) position))
                                   (null (car-safe buffer-undo-list)))
                          (setq buffer-undo-list (cdr buffer-undo-list))))
                      (atomic-change-group (insert closer)))
                    ((error quit) (setq buffer-undo-list undo-before))))
                (set-window-point window position))
              ;; Consume mismatched insertions too, never a later matching key.
              (when (and nelisp-ime-emacs--inline-pair
                         (or (>= (car recent) (marker-position marker))
                             (= (nth 1 recent) (marker-position marker))))
                (nelisp-ime-emacs--inline-pair-clear))))))))))

(defun nelisp-ime-emacs--inline-pair-receive (opener closer)
  "Queue the core's OPENER and CLOSER for up to two seconds.
An opener already inserted at point may also be up to two seconds old."
  (nelisp-ime-emacs--inline-pair-clear)
  (let ((window (selected-window)))
    (with-current-buffer (window-buffer window)
      ;; Prior typing is not the insertion awaited by a new request. Keep
      ;; it only if it could be the opener that raced ahead of PAIR.
      (let ((recent nelisp-ime-emacs--inline-insertion))
        (unless (and recent
                     (<= (- (float-time) (nth 2 recent))
                         nelisp-ime-emacs--inline-pair-window)
                     (= (nth 1 recent) (window-point window))
                     (= (nth 3 recent) (buffer-chars-modified-tick))
                     (equal opener (buffer-substring-no-properties
                                    (car recent) (nth 1 recent))))
          (setq nelisp-ime-emacs--inline-insertion nil)))
      (setq nelisp-ime-emacs--inline-pair
            (list closer (copy-marker (window-point window))
                  (+ (float-time) nelisp-ime-emacs--inline-pair-window) opener)))
    (nelisp-ime-emacs--inline-pair-apply)))


(defun nelisp-ime-emacs--inline-forget-client (client)
  "Clear CLIENT's connection state without disturbing its replacement."
  (setq nelisp-ime-emacs--inline-connections
        (delq client nelisp-ime-emacs--inline-connections))
  (when (eq client nelisp-ime-emacs--inline-client)
    (nelisp-ime-emacs--inline-pair-clear)
    (setq nelisp-ime-emacs--inline-client nil)
    (nelisp-ime-emacs--inline-clear)))

(defun nelisp-ime-emacs--inline-disconnect (client)
  "Close CLIENT silently, including when its disconnect sentinel is delayed."
  (when (processp client)
    (condition-case nil (delete-process client) (error nil))
    (nelisp-ime-emacs--inline-forget-client client)))

(defun nelisp-ime-emacs--inline-send (client text)
  "Send TEXT to CLIENT; treat a write failure as its disconnect."
  (condition-case nil
      (progn (process-send-string client text) t)
    (error (nelisp-ime-emacs--inline-disconnect client) nil)))

(defun nelisp-ime-emacs--inline-update (&rest _)
  "Move the overlay and publish a changed caret; contain hook errors."
  (condition-case nil
      (progn
        (nelisp-ime-emacs--inline-pair-apply)
        (nelisp-ime-emacs--inline-move)
        (when (process-live-p nelisp-ime-emacs--inline-client)
          (let* ((client nelisp-ime-emacs--inline-client)
                 (window (selected-window))
                 (position (window-absolute-pixel-position (window-point window) window)))
            (when position
              (let ((caret (list (car position) (cdr position)
                                 (with-current-buffer (window-buffer window)
                                   (save-excursion
                                     (goto-char (window-point window))
                                     (line-pixel-height))))))
                (unless (equal caret (process-get client 'caret))
                  (when (nelisp-ime-emacs--inline-send
                         client (apply #'format "CARET %d %d %d\n" caret))
                    (process-put client 'caret caret))))))))
    (error nil)))

(defun nelisp-ime-emacs--inline-decode (text)
  "Decode precisely the four Protocol v1 percent escapes in TEXT."
  (replace-regexp-in-string
   "%..\\|%" (lambda (escape)
                (or (cdr (assoc escape '(("%25" . "%") ("%20" . " ")
                                         ("%0D" . "\r") ("%0A" . "\n"))))
                    (error "Invalid inline preedit escape")))
   text t t))

(defun nelisp-ime-emacs--inline-line (client line)
  (let ((case-fold-search nil))
    (when (cl-some (lambda (char) (> char #x10ffff)) line)
      (error "Invalid UTF-8 in inline preedit"))
    (if (not (process-get client 'authenticated))
        (if (and (string-match "\\`HELLO 1 \\([0-9a-f]\\{32\\}\\) \\([0-9]+\\)\\'" line)
                 (equal (match-string 1 line) nelisp-ime-emacs--inline-token)
                 (= (string-to-number (match-string 2 line)) (nelisp-ime-emacs--inline-pid)))
            (let ((old nelisp-ime-emacs--inline-client))
              (setq nelisp-ime-emacs--inline-client client)
              (process-put client 'authenticated t)
              (nelisp-ime-emacs--inline-clear)
              (nelisp-ime-emacs--inline-pair-clear)
              (when (and old (not (eq old client)))
                (nelisp-ime-emacs--inline-disconnect old))
              (when (nelisp-ime-emacs--inline-send client "OK 1 pair\n")
                (nelisp-ime-emacs--send-open-mode)
                (nelisp-ime-emacs--inline-update)))
          (error "Invalid inline preedit handshake"))
      (cond
       ((member line '("MODE-APPLIED latin" "MODE-APPLIED kana")) nil)
       ((string-match-p "\\`PAIR\\(?:[ \t\r]\\|\\'\\)" line)
        ;; PAIR is advisory. A malformed request must not disconnect the
        ;; listener, advance the sequence, or erase a valid pending pair.
        (condition-case nil
            (when (string-match "\\`PAIR \\([0-9]+\\) \\([^ \r\n]+\\) \\([^ \r\n]+\\)\\'" line)
              (let* ((sequence (string-to-number (match-string 1 line)))
                     (opener-field (match-string 2 line))
                     (closer-field (match-string 3 line))
                     (opener (nelisp-ime-emacs--inline-decode opener-field))
                     (closer (nelisp-ime-emacs--inline-decode closer-field)))
                (when (> sequence (process-get client 'sequence))
                  (process-put client 'sequence sequence)
                  (nelisp-ime-emacs--inline-pair-receive opener closer))))
          (error nil)))
       ((string-match "\\`PREEDIT \\([0-9]+\\) \\([0-9]+\\) \\([^ \r\n]*\\)\\'" line)
        (let* ((sequence (string-to-number (match-string 1 line)))
               (cursor (string-to-number (match-string 2 line)))
               (text (nelisp-ime-emacs--inline-decode (match-string 3 line))))
          (when (> cursor (length text)) (error "Inline preedit cursor out of range"))
          (when (> sequence (process-get client 'sequence))
            (nelisp-ime-emacs--inline-pair-clear)
            (nelisp-ime-emacs--inline-render text cursor)
            (process-put client 'sequence sequence)
            (nelisp-ime-emacs--inline-update))))
       ((string-match "\\`CLEAR \\([0-9]+\\)\\'" line)
        (let ((sequence (string-to-number (match-string 1 line))))
          (when (> sequence (process-get client 'sequence))
            (nelisp-ime-emacs--inline-clear)
            (process-put client 'sequence sequence)
            (nelisp-ime-emacs--inline-update))))
       (t (error "Invalid inline preedit command"))))))

(defun nelisp-ime-emacs--inline-filter (client chunk)
  (condition-case nil
      (let ((pending (concat (process-get client 'pending) chunk)) end)
        (while (and (process-live-p client) (setq end (string-match "\n" pending)))
          (let ((line (substring pending 0 end)))
            (setq pending (substring pending (1+ end)))
            (nelisp-ime-emacs--inline-line client line)))
        (process-put client 'pending pending))
    (error (nelisp-ime-emacs--inline-disconnect client))))

(defun nelisp-ime-emacs--inline-sentinel (client _event)
  (unless (process-live-p client)
    (nelisp-ime-emacs--inline-forget-client client)))

(defun nelisp-ime-emacs--inline-accept (_server client _message)
  (process-put client 'pending "")
  (process-put client 'sequence -1)
  (process-put client 'authenticated nil)
  (process-put client 'caret nil)
  (push client nelisp-ime-emacs--inline-connections))

(defun nelisp-ime-emacs--inline-write-discovery (directory)
  (let ((temporary (make-temp-file (expand-file-name ".inline-" directory)))
        (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (progn
          (write-region
           (json-serialize `((version . 1)
                             (port . ,(process-contact nelisp-ime-emacs--inline-server :service))
                             (token . ,nelisp-ime-emacs--inline-token)))
           nil temporary nil 'silent)
          (rename-file temporary nelisp-ime-emacs--inline-file t))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun nelisp-ime-emacs--inline-stop ()
  "Close all inline connections and remove this instance's discovery."
  (nelisp-ime-emacs--inline-pair-clear)
  (remove-hook 'after-change-functions #'nelisp-ime-emacs--inline-after-change)
  (remove-hook 'post-self-insert-hook #'nelisp-ime-emacs--inline-update)
  (remove-hook 'post-command-hook #'nelisp-ime-emacs--inline-update)
  (remove-hook 'window-selection-change-functions #'nelisp-ime-emacs--inline-update)
  (remove-hook 'window-size-change-functions #'nelisp-ime-emacs--inline-update)
  (remove-hook 'window-buffer-change-functions #'nelisp-ime-emacs--inline-update)
  (remove-function after-focus-change-function #'nelisp-ime-emacs--inline-update)
  (remove-hook 'kill-emacs-hook #'nelisp-ime-emacs--inline-stop)
  (dolist (client nelisp-ime-emacs--inline-connections)
    (nelisp-ime-emacs--inline-disconnect client))
  (when (processp nelisp-ime-emacs--inline-server)
    (condition-case error-data (delete-process nelisp-ime-emacs--inline-server)
      (error (nelisp-ime-emacs--inline-warn error-data))))
  (setq nelisp-ime-emacs--inline-server nil nelisp-ime-emacs--inline-client nil
        nelisp-ime-emacs--inline-connections nil nelisp-ime-emacs--inline-token nil)
  (nelisp-ime-emacs--inline-clear)
  (when nelisp-ime-emacs--inline-file
    (condition-case error-data
        (when (file-exists-p nelisp-ime-emacs--inline-file)
          (delete-file nelisp-ime-emacs--inline-file))
      (error (nelisp-ime-emacs--inline-warn error-data))))
  (setq nelisp-ime-emacs--inline-file nil))

(defun nelisp-ime-emacs--inline-start ()
  (when (and nelisp-ime-emacs-inline-preedit (nelisp-ime-emacs--inline-directory)
             (not (process-live-p nelisp-ime-emacs--inline-server)))
    (setq nelisp-ime-emacs--inline-warned nil)
    (condition-case error-data
        (let ((directory (expand-file-name (nelisp-ime-emacs--inline-directory))))
          (when (file-remote-p directory) (error "Inline discovery must be local"))
          (unless (file-directory-p directory)
            (make-directory directory t)
            (set-file-modes directory #o700))
          (setq nelisp-ime-emacs--inline-token (nelisp-ime-emacs--inline-random-token)
                nelisp-ime-emacs--inline-file
                (expand-file-name (format "%d.json" (nelisp-ime-emacs--inline-pid)) directory)
                nelisp-ime-emacs--inline-server
                (make-network-process
                 :name "nelisp-ime-inline" :server t :host "127.0.0.1" :family 'ipv4
                 :service t :coding 'utf-8-unix :noquery t :no-delay t
                 :filter #'nelisp-ime-emacs--inline-filter
                 :sentinel #'nelisp-ime-emacs--inline-sentinel
                 :log #'nelisp-ime-emacs--inline-accept))
          (nelisp-ime-emacs--inline-write-discovery directory)
          (add-hook 'kill-emacs-hook #'nelisp-ime-emacs--inline-stop)
          (add-hook 'after-change-functions #'nelisp-ime-emacs--inline-after-change)
          (add-hook 'post-self-insert-hook #'nelisp-ime-emacs--inline-update)
          (add-hook 'post-command-hook #'nelisp-ime-emacs--inline-update)
          (add-hook 'window-selection-change-functions #'nelisp-ime-emacs--inline-update)
          (add-hook 'window-size-change-functions #'nelisp-ime-emacs--inline-update)
          (add-hook 'window-buffer-change-functions #'nelisp-ime-emacs--inline-update)
          (add-function :after after-focus-change-function #'nelisp-ime-emacs--inline-update))
      (error
       (nelisp-ime-emacs--inline-warn error-data)
       (nelisp-ime-emacs--inline-stop)))))

;;;###autoload
(define-minor-mode nelisp-ime-emacs-mode
  "Follow Evil and show the Windows NeLisp IME's mode and inline preedit."
  :global t :group 'nelisp-ime-emacs
  (if nelisp-ime-emacs-mode
      (progn
        (nelisp-ime-emacs--install-evil-hooks)
        (setq nelisp-ime-emacs--selection (nelisp-ime-emacs--selected-context))
        (add-hook 'window-selection-change-functions #'nelisp-ime-emacs--selection-change)
        (add-hook 'window-buffer-change-functions #'nelisp-ime-emacs--selection-change)
        (add-function :after after-focus-change-function #'nelisp-ime-emacs--focus-change)
        (add-to-list 'global-mode-string
                     '(nelisp-ime-emacs-mode (:eval (when nelisp-ime-emacs-mode-line nelisp-ime-emacs--label))))
        (unless nelisp-ime-emacs--timer
          (setq nelisp-ime-emacs--timer
                (run-at-time nil nelisp-ime-emacs-poll-interval #'nelisp-ime-emacs--poll)))
        (nelisp-ime-emacs--check-settings)
        (nelisp-ime-emacs--inline-start)
        (add-hook 'post-command-hook #'nelisp-ime-emacs--check-open-mode))
    (nelisp-ime-emacs--inline-stop)
    (remove-hook 'post-command-hook #'nelisp-ime-emacs--check-open-mode)
    (setq nelisp-ime-emacs--open-mode-context nil nelisp-ime-emacs--pending-open-mode nil)
    (advice-remove 'evil-set-cursor-color #'nelisp-ime-emacs--evil-set-cursor-color)
    (remove-hook 'window-selection-change-functions #'nelisp-ime-emacs--selection-change)
    (remove-hook 'window-buffer-change-functions #'nelisp-ime-emacs--selection-change)
    (remove-function after-focus-change-function #'nelisp-ime-emacs--focus-change)
    (when (timerp nelisp-ime-emacs--reconcile-timer)
      (cancel-timer nelisp-ime-emacs--reconcile-timer))
    (setq nelisp-ime-emacs--reconcile-timer nil nelisp-ime-emacs--selection nil)
    (when (timerp nelisp-ime-emacs--timer) (cancel-timer nelisp-ime-emacs--timer))
    (setq nelisp-ime-emacs--timer nil nelisp-ime-emacs--label "")
    (dolist (state '(normal insert replace visual motion operator emacs))
      (remove-hook (intern (format "evil-%s-state-entry-hook" state)) #'nelisp-ime-emacs--state-entry))
    (maphash (lambda (frame _) (nelisp-ime-emacs--restore frame)) nelisp-ime-emacs--cursors)
    (clrhash nelisp-ime-emacs--cursors)
    (clrhash nelisp-ime-emacs--closing-frames))
  (force-mode-line-update t))

(provide 'nelisp-ime-emacs)
;;; nelisp-ime-emacs.el ends here
