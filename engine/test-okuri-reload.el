;;; test-okuri-reload.el --- Engine wrapper reload regression -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'skk-ime-session)

(ert-deftest okuri-engine-wrappers-survive-reload ()
  "Load the complete engine twice and exercise both wrapped commands."
  (let ((original-load (symbol-function 'load))
        (original-delete (symbol-function 'delete-region))
        (process-environment (copy-sequence process-environment))
        (load-path (cons default-directory load-path))
        (private-jisyo (make-temp-file "okuri-reload-"))
        (max-lisp-eval-depth 200)
        saved-delete saved-previous)
    (setenv "DDSKK_USER_JISYO" private-jisyo)
    (setenv "DDSKK_SKKSERV_ENABLE" "0")
    (unwind-protect
        (progn
          ;; GNU Emacs supplies its own buffer primitives. Skip only the
          ;; standalone buffer provider, without reading another checkout;
          ;; all engine forms and local DDSKK/compat files load normally.
          (cl-letf (((symbol-function 'load)
                     (lambda (file &rest args)
                       (unless (equal file "../nelisp/src/nelisp-buffer.el")
                         (apply original-load file args)))))
            (load "engine/ddskk-engine.el" nil t)
            (setq saved-delete (symbol-function 'ddskk-engine--delete-region)
                  saved-previous (symbol-function 'ddskk-engine--previous-candidate))
            (load "engine/ddskk-engine.el" nil t))
          (should (eq saved-delete (symbol-function 'ddskk-engine--delete-region)))
          (should (eq saved-previous (symbol-function 'ddskk-engine--previous-candidate)))
          (should-not (eq saved-delete (symbol-function 'delete-region)))
          (should-not (eq saved-previous (symbol-function 'skk-previous-candidate)))
          (with-temp-buffer
            (insert "abc")
            (delete-region 2 3)
            (should (equal (buffer-string) "ac")))
          (puthash "かk" '("書" "掛") ddskk-user-jisyo--table)
          (let ((state (skk-ime-session-feed-string ddskk-engine--session "KaKu")))
            (should (eq (plist-get state :mode) 'candidate))
            (should (equal (plist-get state :text) "▼書く")))
          (skk-ime-session--with-buffer ddskk-engine--session
            (skk-previous-candidate))
          (let ((state (skk-ime-session-snapshot ddskk-engine--session)))
            (should (eq (plist-get state :mode) 'preedit))
            (should (equal (plist-get state :text) "▽かく")))
          (message "RELOAD twice: delete-region=ac previous-candidate=25bd304b304f"))
      ;; Restore deletion even on the pre-fix recursion failure so ERT can
      ;; render its failure and dispose of buffers without recursing again.
      (fset 'delete-region original-delete)
      (when (fboundp 'ddskk-engine-stop) (ddskk-engine-stop))
      (remove-hook 'kill-emacs-hook #'skk-save-jisyo)
      (remove-hook 'kill-emacs-hook #'skk-record-jisyo-data)
      (delete-file private-jisyo))))
