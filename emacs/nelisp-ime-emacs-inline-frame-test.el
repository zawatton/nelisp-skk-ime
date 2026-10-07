;;; nelisp-ime-emacs-inline-frame-test.el --- Terminal frame tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run in a terminal Emacs, using script(1) to provide a controlling tty.
;; Batch Emacs cannot create the second frame or enter an active minibuffer.
;; These tests supplement the batch suite; they are never skipped.

;;; Code:
(load (expand-file-name "nelisp-ime-emacs-inline-test.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil t)

(ert-deftest nelisp-ime-emacs-inline-s22-interactive-other-frame ()
  (nelisp-ime-emacs-inline-test--with-server
    (let ((client (nelisp-ime-emacs-inline-test--client))
          (original-frame (selected-frame)) (height 18) frame)
      (push client test-clients)
      (unwind-protect
          (cl-letf (((symbol-function 'window-absolute-pixel-position)
                     (lambda (position window)
                       (should (eq window (selected-window)))
                       (should (= position (window-point window)))
                       (if (eq (window-frame window) original-frame) '(10 . 20) '(300 . 400))))
                    ((symbol-function 'line-pixel-height) (lambda () height)))
            (nelisp-ime-emacs-inline-test--hello client)
            (process-send-string client "PREEDIT 1 1 ▽かな\n")
            (nelisp-ime-emacs-inline-test--sequence 1)
            (setq frame (make-frame '((window-system . nil))))
            (should-not (eq frame original-frame))
            (select-frame frame)
            (select-window (frame-selected-window frame))
            (with-temp-buffer
              (switch-to-buffer (current-buffer))
              (insert "second frame")
              (goto-char 4)
              (setq height 22)
              (run-hook-with-args 'window-selection-change-functions frame)
              (nelisp-ime-emacs-inline-test--wait
               (lambda () (equal (process-get client 'received)
                                  "OK 1 pair\nCARET 10 20 18\nCARET 300 400 22\n")))
              (should (eq (overlay-buffer nelisp-ime-emacs--inline-overlay) (current-buffer)))
              (should (= (overlay-start nelisp-ime-emacs--inline-overlay) 4))
              (should (eq (window-frame (overlay-get nelisp-ime-emacs--inline-overlay 'window)) frame))))
        (when (frame-live-p frame) (delete-frame frame))
        (select-frame original-frame)))))

(ert-deftest nelisp-ime-emacs-inline-s22-interactive-active-minibuffer ()
  (nelisp-ime-emacs-inline-test--with-server
    (let ((client (nelisp-ime-emacs-inline-test--client)) visited
          (unread-command-events nil))
      (push client test-clients)
      (cl-letf (((symbol-function 'window-absolute-pixel-position)
                 (lambda (_point window)
                   (if (minibufferp (window-buffer window)) '(30 . 40) '(10 . 20))))
                ((symbol-function 'line-pixel-height) (lambda () 18)))
        (nelisp-ime-emacs-inline-test--hello client)
        (should
         (equal
          (minibuffer-with-setup-hook
              (lambda ()
                (should (active-minibuffer-window))
                (insert "unchanged")
                (let ((undo buffer-undo-list) (modified (buffer-modified-p))
                      (buffer-read-only t))
                  (process-send-string client "PREEDIT 1 1 ▽かな\n")
                  (nelisp-ime-emacs-inline-test--sequence 1)
                  (run-hooks 'post-command-hook)
                  (nelisp-ime-emacs-inline-test--wait
                   (lambda () (string-match-p "CARET 30 40 18\n" (process-get client 'received))))
                  (should (eq (overlay-buffer nelisp-ime-emacs--inline-overlay) (current-buffer)))
                  (should (eq (overlay-get nelisp-ime-emacs--inline-overlay 'window)
                              (active-minibuffer-window)))
                  (should (= (overlay-start nelisp-ime-emacs--inline-overlay) (point)))
                  (should (eq undo buffer-undo-list))
                  (should (eq modified (buffer-modified-p)))
                  (setq visited t))
                (push ?\r unread-command-events))
            (read-from-minibuffer "Inline test: "))
          "unchanged"))
        (should visited)))))

;;; nelisp-ime-emacs-inline-frame-test.el ends here
