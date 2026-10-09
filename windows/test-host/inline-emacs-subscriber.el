;;; inline-emacs-subscriber.el --- Real listener integrated probe -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'nelisp-ime-emacs)
(let* ((pidfile (getenv "INLINE_TEST_PIDFILE"))
       (directory (getenv "NELISP_IME_INLINE_DIR"))
       (stopfile (expand-file-name "stop" directory))
       (logfile (getenv "INLINE_TEST_LOG"))
       ;; All writes, including process-filter advice, use the log protocol's
       ;; encoding regardless of Windows locale or Emacs coding defaults.
       (coding-system-for-write 'utf-8-unix)
       (pairing (member (getenv "INLINE_TEST_PAIR") '("1" "2")))
       (imported-text "")
       (deadline (+ (float-time) (if (getenv "INLINE_TEST_TIMEOUT_SEC")
                                   (string-to-number (getenv "INLINE_TEST_TIMEOUT_SEC")) 150))))
  (with-temp-buffer
    (insert (format "EMACS_PID=%d\n" (emacs-pid)))
    (write-region (point-min) (point-max) logfile nil 'silent))
  (while (and (not (file-exists-p pidfile))
              (not (file-exists-p stopfile)) (< (float-time) deadline))
    (sleep-for 0.02))
  (when (file-exists-p stopfile) (kill-emacs 0))
  (unless (file-exists-p pidfile) (error "No private TSF PID"))
  (setq nelisp-ime-emacs--inline-test-pid
        (with-temp-buffer (insert-file-contents pidfile) (string-to-number (buffer-string))))
  (switch-to-buffer (get-buffer-create "*inline-integrated-probe*"))
  (setq nelisp-ime-emacs--warned t)
  (when (equal (getenv "INLINE_TEST_OPEN_MODE") "latin")
    (setq nelisp-ime-emacs-open-mode-function (lambda () 'latin)))
  (cl-letf (((symbol-function 'window-absolute-pixel-position)
             (lambda (&rest _) '(321 . 456)))
            ((symbol-function 'line-pixel-height) (lambda () 23)))
    (advice-add 'nelisp-ime-emacs--inline-line :before
                (lambda (_client line)
                  (when (or (string-prefix-p "PAIR " line)
                            (string-prefix-p "MODE-APPLIED " line))
                    (with-temp-buffer
                      (insert (concat (if (string-prefix-p "MODE-APPLIED " line) "MODEACK " "") line "\n"))
                      (write-region (point-min) (point-max) logfile t 'silent)))))
    (advice-add 'nelisp-ime-emacs--inline-render :after
                (lambda (text cursor)
                  (let ((display (overlay-get nelisp-ime-emacs--inline-overlay 'after-string)))
                    (with-temp-buffer
                      (insert (format "RENDER_AT %.6f\n" (float-time)))
                      (insert (format "RENDER %d %s cursor=%S\n" cursor text
                                      (get-text-property cursor 'cursor display)))
                      (write-region (point-min) (point-max) logfile t 'silent)))))
    (advice-add 'nelisp-ime-emacs--inline-clear :after
                (lambda () (with-temp-buffer
                             (insert "CLEAR\n")
                             (write-region (point-min) (point-max) logfile t 'silent))))
    (unwind-protect
        (progn
          (nelisp-ime-emacs-mode 1)
          (when nelisp-ime-emacs-open-mode-function
            (nelisp-ime-emacs--request-open-mode t t))
          (unless (process-live-p nelisp-ime-emacs--inline-server)
            (error "Real Emacs TCP listener failed"))
          (while (and (not (file-exists-p stopfile)) (< (float-time) deadline))
            (accept-process-output nil 0.02)
            ;; Batch Emacs has no IMM input queue. Import the actual committed
            ;; opener from the TSF fixture, independently of PAIR handling.
            (when pairing
              (let* ((artifacts (getenv "INLINE_TEST_ARTIFACTS"))
                     (logs (file-expand-wildcards
                            (expand-file-name "harness-*/tsf.stdout.log" artifacts)))
                     (text (mapconcat
                            (lambda (file)
                              (with-temp-buffer
                                (let ((coding-system-for-read 'utf-8))
                                  (insert-file-contents file))
                                (buffer-string))) logs "")))
                (let ((offset 0))
                  (while (string-match "AFTER WAIT100 BUF=\\[\\([^]\n]+\\)\\] SEL=\\([0-9]+\\),\\2 COMP=-" text offset)
                    (let ((committed (match-string 1 text)))
                      (setq offset (match-end 0))
                      (when (and (string-prefix-p imported-text committed)
                                 (> (length committed) (length imported-text)))
                        (let ((opener (substring committed (length imported-text))))
                          (with-current-buffer "*inline-integrated-probe*"
                            (insert-before-markers opener)
                            (run-hooks 'post-command-hook)))
                        (setq imported-text committed))))))))
          (when pairing
            (let ((result (with-current-buffer "*inline-integrated-probe*"
                            (format "PAIR_BUFFER=%s POINT=%d\n" (buffer-string) (point)))))
              (with-temp-buffer
                (insert result)
                (write-region (point-min) (point-max) logfile t 'silent))))
          (with-temp-buffer
            (insert (format "BUFFER_UNCHANGED=%S\n" (equal "" (with-current-buffer "*inline-integrated-probe*" (buffer-string)))))
            (write-region (point-min) (point-max) logfile t 'silent)))
      (nelisp-ime-emacs-mode -1))))
