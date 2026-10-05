;;; test-q-reading.el --- Completed-reading DDSKK q oracle -*- lexical-binding: t; -*-

(require 'ert)
;; Isolate DDSKK initialization as well as each session's dictionary.
(defvar q-reading--home (make-temp-file "q-reading-home-" t))
(setenv "HOME" q-reading--home)
(setq user-emacs-directory (expand-file-name ".emacs.d/" q-reading--home)
      skk-jisyo (expand-file-name "jisyo" q-reading--home)
      skk-large-jisyo nil)
(make-directory user-emacs-directory t)
(require 'skk-ime-session)
(remove-hook 'kill-emacs-hook #'skk-save-jisyo)
(remove-hook 'kill-emacs-hook #'skk-record-jisyo-data)
(add-hook 'kill-emacs-hook (lambda () (delete-directory q-reading--home t)))

(ert-deftest q-reading-stock-oracle ()
  "Export independently computed stock DDSKK results for the native matcher."
  (let ((skk-server-host nil) (skk-search-prog-list nil) records)
    (dolist (keys '("Ka" "Kana" "Kya" "Ga" "Gya" "Katta" "Kanpai" "Kan'a"))
      (let ((session (skk-ime-session-create)))
        (unwind-protect
            (progn
              (let ((before (skk-ime-session-feed-string session keys)))
                (should (eq (plist-get before :mode) 'preedit))
                (should (equal (plist-get before :pending-romaji) "")))
              (let ((after (skk-ime-session-feed-key session ?q)))
                (should (eq (plist-get after :mode) 'hiragana))
                (should-not (plist-get after :composition-start))
                (push (format "%s %s %s\n" keys (plist-get after :mode)
                              (mapconcat (lambda (ch) (format "%06x" ch))
                                         (string-to-list (plist-get after :text)) "")) records)))
          (skk-ime-session-destroy session))))
    (when-let ((output (getenv "Q_ORACLE_OUTPUT")))
      (with-temp-file output (insert (apply #'concat (nreverse records)))))))
