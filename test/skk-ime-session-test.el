;;; skk-ime-session-test.el --- Tests for native IME session API -*- lexical-binding: t; -*-

(require 'ert)
(require 'skk-ime-session)

(defmacro skk-ime-session-test--with-session (name &rest body)
  (declare (indent 1) (debug t))
  `(let ((,name (skk-ime-session-create)))
     (unwind-protect
         (progn ,@body)
       (skk-ime-session-destroy ,name))))

(ert-deftest skk-ime-session-direct-hiragana-input ()
  (skk-ime-session-test--with-session session
    (let ((state (skk-ime-session-feed-string session "kana")))
      (should (eq (plist-get state :mode) 'hiragana))
      (should (equal (plist-get state :text) "かな"))
      (should (equal (plist-get state :pending-romaji) ""))
      (should-not (plist-get state :composition-start)))))

(ert-deftest skk-ime-session-retains-incomplete-romaji ()
  (skk-ime-session-test--with-session session
    (let ((state (skk-ime-session-feed-key session ?n)))
      (should (equal (plist-get state :pending-romaji) "n"))
      ;; DDSKK displays an incomplete prefix through its own UI machinery; it
      ;; is not committed buffer text.
      (should (equal (plist-get state :text) "")))))

(ert-deftest skk-ime-session-uppercase-starts-preedit ()
  (skk-ime-session-test--with-session session
    (let ((state (skk-ime-session-feed-string session "Kana")))
      (should (eq (plist-get state :mode) 'preedit))
      (should (equal (plist-get state :text) "▽かな"))
      (should (= (plist-get state :composition-start) 1)))))

(ert-deftest skk-ime-session-reset-reuses-session ()
  (skk-ime-session-test--with-session session
    (skk-ime-session-feed-string session "kana")
    (let ((state (skk-ime-session-reset session)))
      (should (eq (plist-get state :mode) 'hiragana))
      (should (equal (plist-get state :text) ""))
      (should (= (plist-get state :cursor) 0)))))

(ert-deftest skk-ime-session-control-backspace ()
  (skk-ime-session-test--with-session session
    (skk-ime-session-feed-string session "kana")
    (let ((state (skk-ime-session-control session 'backspace)))
      (should (equal (plist-get state :text) "か")))))

(ert-deftest skk-ime-session-control-cancel-preedit ()
  (skk-ime-session-test--with-session session
    (skk-ime-session-feed-string session "Kana")
    (let ((state (skk-ime-session-control session 'cancel)))
      (should (eq (plist-get state :mode) 'hiragana))
      (should (equal (plist-get state :text) "")))))

(ert-deftest skk-ime-session-control-convert-with-test-dictionary ()
  (skk-ime-session-test--with-session session
    (skk-ime-session-feed-string session "Kana")
    (with-current-buffer (skk-ime-session-buffer session)
      (let ((skk-search-prog-list '((list "仮名" "かな"))))
        (let ((state (skk-ime-session-control session 'convert)))
          (should (eq (plist-get state :mode) 'candidate))
          (should (string-match-p "仮名" (plist-get state :text))))))))

(ert-deftest skk-ime-session-control-previous-candidate ()
  (skk-ime-session-test--with-session session
    (skk-ime-session-feed-string session "Kana")
    (with-current-buffer (skk-ime-session-buffer session)
      (let ((skk-search-prog-list '((list "仮名" "カナ"))))
        (skk-ime-session-control session 'convert)
        (skk-ime-session-control session 'convert)
        (let ((state (skk-ime-session-control session 'previous)))
          (should (= (plist-get state :candidate-index) 0))
          (should (string-match-p "仮名" (plist-get state :text))))))))

(ert-deftest skk-ime-session-rejects-use-after-destroy ()
  (let ((session (skk-ime-session-create)))
    (skk-ime-session-destroy session)
    (should-error (skk-ime-session-snapshot session))))

(provide 'skk-ime-session-test)

;;; skk-ime-session-test.el ends here
