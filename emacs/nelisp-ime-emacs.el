;;; nelisp-ime-emacs.el --- Follow evil with the Windows NeLisp IME -*- lexical-binding: t; -*-

;; Copyright (C) 2026 nelisp-skk-ime contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Native Windows TSF integration; no Emacs input method or evil dependency.
;; Configure Apps\emacs.exe once as described in README.org.

;;; Code:
(require 'cl-lib)
(defgroup nelisp-ime-emacs nil "Windows NeLisp IME integration." :group 'environment)
(defcustom nelisp-ime-emacs-open-states '(insert replace)
  "Evil states whose entry opens the IME in the selected buffer."
  :type '(repeat symbol))
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
(defvar nelisp-ime-emacs-before-open-hook nil
  "Predicates called before opening. Any nil return vetoes opening.
For example, add `nelisp-ime-emacs-outside-org-src-p'.")
(defvar nelisp-ime-emacs--timer nil)
(defvar nelisp-ime-emacs--label "")
(defvar nelisp-ime-emacs--base-mode "hiragana")
(defvar nelisp-ime-emacs--cursors (make-hash-table :test #'eq))
(defvar nelisp-ime-emacs--warned nil)
(defvar nelisp-ime-emacs-mode nil)
(defvar evil-state)
(declare-function w32-read-registry "w32fns.c" (root key name))
(declare-function w32-set-ime-open-status "w32fns.c" (status))
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
  (when (frame-live-p frame)
    (with-selected-frame frame
      (if (and (bound-and-true-p evil-local-mode)
               (fboundp 'evil-refresh-cursor))
          (evil-refresh-cursor)
        (let ((color (gethash frame nelisp-ime-emacs--cursors)))
          (when color (set-cursor-color color)))))))

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
      (unless open
        (setq nelisp-ime-emacs--label "")
        (nelisp-ime-emacs--restore (selected-frame))))))

(defun nelisp-ime-emacs--read (key name)
  (when (fboundp 'w32-read-registry)
    (condition-case nil (w32-read-registry 'HKCU key name) (error nil))))

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
          (if (or (not (equal open 1))
                  (not (memq (nelisp-ime-emacs--state) nelisp-ime-emacs-open-states)))
              (progn (setq nelisp-ime-emacs--label "")
                     (nelisp-ime-emacs--restore frame))
            ;; Preedit/candidate/registration are engine states, not scripts.
            ;; Retain the last input script for their cursor and label.
            (when (member mode '("hiragana" "katakana" "jisx0201" "wide-latin" "latin" "abbrev"))
              (setq nelisp-ime-emacs--base-mode mode))
            (unless (gethash frame nelisp-ime-emacs--cursors)
              (puthash frame (frame-parameter frame 'cursor-color) nelisp-ime-emacs--cursors))
            (let ((color (cdr (assoc nelisp-ime-emacs--base-mode
                                     (if (eq (frame-parameter frame 'background-mode) 'dark)
                                         nelisp-ime-emacs-dark-colors nelisp-ime-emacs-light-colors)))))
              (when color (set-cursor-color color)))
            (setq nelisp-ime-emacs--label
                  (or (cdr (assoc nelisp-ime-emacs--base-mode
                                  '(("hiragana" . "[あ]") ("katakana" . "[ア]")
                                    ("jisx0201" . "[ｱ]") ("wide-latin" . "[Ａ]")
                                    ("latin" . "[A]") ("abbrev" . "[aA]")))) ""))))
        (force-mode-line-update t)))))

(defun nelisp-ime-emacs--install-evil-hooks ()
  (dolist (state '(normal insert replace visual motion operator emacs))
    (add-hook (intern (format "evil-%s-state-entry-hook" state))
              #'nelisp-ime-emacs--state-entry)))

(with-eval-after-load 'evil
  (when nelisp-ime-emacs-mode (nelisp-ime-emacs--install-evil-hooks)))

;;;###autoload
(define-minor-mode nelisp-ime-emacs-mode
  "Follow evil states and show the Windows NeLisp IME's input mode."
  :global t :group 'nelisp-ime-emacs
  (if nelisp-ime-emacs-mode
      (progn
        (nelisp-ime-emacs--install-evil-hooks)
        (add-to-list 'global-mode-string
                     '(nelisp-ime-emacs-mode (:eval (when nelisp-ime-emacs-mode-line nelisp-ime-emacs--label))))
        (unless nelisp-ime-emacs--timer
          (setq nelisp-ime-emacs--timer
                (run-at-time nil nelisp-ime-emacs-poll-interval #'nelisp-ime-emacs--poll)))
        (nelisp-ime-emacs--check-settings))
    (when (timerp nelisp-ime-emacs--timer) (cancel-timer nelisp-ime-emacs--timer))
    (setq nelisp-ime-emacs--timer nil nelisp-ime-emacs--label "")
    (dolist (state '(normal insert replace visual motion operator emacs))
      (remove-hook (intern (format "evil-%s-state-entry-hook" state)) #'nelisp-ime-emacs--state-entry))
    (maphash (lambda (frame _) (nelisp-ime-emacs--restore frame)) nelisp-ime-emacs--cursors)
    (clrhash nelisp-ime-emacs--cursors))
  (force-mode-line-update t))

(provide 'nelisp-ime-emacs)
;;; nelisp-ime-emacs.el ends here
