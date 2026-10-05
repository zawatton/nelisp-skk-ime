;;; inline-emacs-subscriber.el --- Real listener integrated probe -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'nelisp-ime-emacs)
(let* ((pidfile (getenv "INLINE_TEST_PIDFILE"))
       (directory (getenv "NELISP_IME_INLINE_DIR"))
       (stopfile (expand-file-name "stop" directory))
       (logfile (getenv "INLINE_TEST_LOG"))
       (pairing (equal (getenv "INLINE_TEST_PAIR") "1"))
       (imported nil)
       (deadline (+ (float-time) 150)))
  (with-temp-buffer
    (insert (format "EMACS_PID=%d\n" (emacs-pid)))
    (write-region (point-min) (point-max) logfile nil 'silent))
  (while (and (not (file-exists-p pidfile)) (< (float-time) deadline))
    (sleep-for 0.02))
  (unless (file-exists-p pidfile) (error "No private TSF PID"))
  (setq nelisp-ime-emacs--inline-test-pid
        (with-temp-buffer (insert-file-contents pidfile) (string-to-number (buffer-string))))
  (switch-to-buffer (get-buffer-create "*inline-integrated-probe*"))
  (setq nelisp-ime-emacs--warned t)
  (cl-letf (((symbol-function 'window-absolute-pixel-position)
             (lambda (&rest _) '(321 . 456)))
            ((symbol-function 'line-pixel-height) (lambda () 23)))
    (advice-add 'nelisp-ime-emacs--inline-line :before
                (lambda (_client line)
                  (when (string-prefix-p "PAIR " line)
                    (with-temp-buffer
                      (insert (concat line "\n"))
                      (write-region (point-min) (point-max) logfile t 'silent)))))
    (advice-add 'nelisp-ime-emacs--inline-render :after
                (lambda (text cursor)
                  (let ((display (overlay-get nelisp-ime-emacs--inline-overlay 'after-string)))
                    (with-temp-buffer
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
          (unless (process-live-p nelisp-ime-emacs--inline-server)
            (error "Real Emacs TCP listener failed"))
          (while (and (not (file-exists-p stopfile)) (< (float-time) deadline))
            (accept-process-output nil 0.02)
            ;; Batch Emacs has no IMM input queue. Import the actual committed
            ;; opener from the TSF fixture, independently of PAIR handling.
            (when (and pairing (not imported))
              (let* ((artifacts (getenv "INLINE_TEST_ARTIFACTS"))
                     (logs (file-expand-wildcards
                            (expand-file-name "harness-*/tsf.stdout.log" artifacts)))
                     (text (mapconcat
                            (lambda (file)
                              (with-temp-buffer
                                (let ((coding-system-for-read 'utf-8))
                                  (insert-file-contents file))
                                (buffer-string))) logs "")))
                (when (string-match "AFTER WAIT100 BUF=\\[\\([^]\n]+\\)\\] SEL=\\([0-9]+\\),\\2 COMP=-" text)
                  (let ((opener (match-string 1 text)))
                    (with-current-buffer "*inline-integrated-probe*"
                      (insert opener)
                      (run-hooks 'post-command-hook)))
                  (setq imported t)))))
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
