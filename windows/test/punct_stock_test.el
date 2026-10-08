;;; punct_stock_test.el --- Stock DDSKK punctuation oracle -*- lexical-binding: t; -*-
;; GPL-3.0-or-later. All dictionary writes stay in a disposable directory.
(setq native-comp-enable-subr-trampolines nil)
(require 'ert)
(defvar punct-stock-directory (make-temp-file "punct-stock-" t))
(setq user-emacs-directory (expand-file-name ".emacs.d/" punct-stock-directory)
      skk-jisyo (expand-file-name "user.jisyo" punct-stock-directory)
      skk-large-jisyo (expand-file-name "source.utf8" punct-stock-directory)
      skk-jisyo-code 'utf-8
      skk-backup-jisyo nil
      skk-server-host nil)
(make-directory user-emacs-directory t)
(with-temp-file skk-large-jisyo
  (insert-file-contents (expand-file-name "../test-host/data/behavior-jisyo.utf8"
                                       (file-name-directory load-file-name))))
(require 'skk-ime-session)
(remove-hook 'kill-emacs-hook #'skk-save-jisyo)
(remove-hook 'kill-emacs-hook #'skk-record-jisyo-data)
(add-hook 'kill-emacs-hook (lambda () (delete-directory punct-stock-directory t)))
(ert-deftest punct-stock-confirm-before-inserting ()
  (let ((cases '(("period" "Kana " "." "仮名。" hiragana)
                 ("comma" "Kana " "," "仮名、" hiragana)
                 ("okuri" "KieRu" "." "消える。" hiragana)
                 ("preedit" "Kana" "." "▼仮名。" candidate)
                 ("next" "Kana  " "." "哉。" hiragana)
                 ("previous" "Kana  " "." "仮名。" hiragana)
                 ("fast" "" "Kana ." "仮名。" hiragana)
                 ("async" "Kana " "." "仮名。" hiragana))))
    (dolist (case cases)
      (let ((session (skk-ime-session-create)))
        (unwind-protect
            (progn
              (skk-ime-session--with-buffer session
                (setq-local skk-jisyo-code 'utf-8)
                (setq-local skk-search-prog-list
                            '((skk-search-jisyo-file (cons skk-large-jisyo skk-jisyo-code) 0 t)))
                (setq-local skk-current-search-prog-list nil))
              (skk-ime-session-feed-string session (nth 1 case))
              (when (equal (car case) "previous")
                (skk-ime-session-control session 'previous))
              (let ((state (skk-ime-session-feed-string session (nth 2 case))))
                (message "STOCK observed case=%s mode=%s text=%s"
                         (car case) (plist-get state :mode)
                         (mapconcat (lambda (c) (format "%04x" c)) (plist-get state :text) ""))
                (should (equal (plist-get state :text) (nth 3 case)))
                (should (eq (plist-get state :mode) (nth 4 case)))
                (message "STOCK punctuation case=%s mode=%s text=%s PASS"
                         (car case) (plist-get state :mode)
                         (mapconcat (lambda (c) (format "%04x" c)) (plist-get state :text) ""))))
          (skk-ime-session-destroy session))))))
