;;; skk-ime-session-test.el --- Tests for native IME session API -*- lexical-binding: t; -*-

(require 'ert)
(require 'skk-ime-session)
(require 'skk-user-jisyo)

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

(ert-deftest skk-ime-session-okuri-ari-converts-kanji-plus-kana ()
  "KieRu converts a one-kanji stem while preserving its okurigana."
  (skk-ime-session-test--with-session session
    (with-current-buffer (skk-ime-session-buffer session)
      ;; SKK's okuri-ari candidate contains the conjugation stem; DDSKK
      ;; appends the typed okurigana (る) after it.
      (let ((skk-search-prog-list '((list "消え"))))
        (let ((state (skk-ime-session-feed-string session "KieRu")))
          (should (eq (plist-get state :mode) 'candidate))
          (should (equal (plist-get state :text) "▼消える")))))))

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

(ert-deftest skk-ime-session-control-quit-cancels-conversion-stepwise ()
  "Ctrl+G first cancels conversion, then cancels the restored reading."
  (skk-ime-session-test--with-session session
    (skk-ime-session-feed-string session "Kana")
    (with-current-buffer (skk-ime-session-buffer session)
      (let ((skk-search-prog-list '((list "仮名" "かな"))))
        (let ((candidate (skk-ime-session-control session 'convert)))
          (should (eq (plist-get candidate :mode) 'candidate)))
        (let ((reading (skk-ime-session-control session 'quit)))
          (should (eq (plist-get reading :mode) 'preedit))
          (should (equal (plist-get reading :text) "▽かな"))
          (should (= (plist-get reading :composition-start) 1)))
        (let ((cancelled (skk-ime-session-control session 'quit)))
          (should (eq (plist-get cancelled :mode) 'hiragana))
          (should (equal (plist-get cancelled :text) ""))
          (should-not (plist-get cancelled :composition-start)))))))

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

(ert-deftest skk-ime-session-control-registers-missing-candidate ()
  "A zero-result conversion accepts a UI-supplied registration word."
  (skk-ime-session-test--with-session session
    (skk-ime-session-feed-string session "Kana")
    (with-current-buffer (skk-ime-session-buffer session)
      (let ((skk-search-prog-list '((list)))
            registered)
        (cl-letf (((symbol-function 'skk-henkan-in-minibuff)
                   (lambda () nil))
                  ((symbol-function 'ddskk-user-jisyo--update)
                   (lambda (word &optional _purge)
                     (setq registered word)
                     ;; Model the just-updated personal dictionary for the
                     ;; immediate reconversion performed by `register'.
                     (setq skk-search-prog-list
                           (list (list 'list word))))))
          (let ((missing (skk-ime-session-control session 'convert)))
            (should (eq (plist-get missing :mode) 'candidate))
            (should-not (plist-get missing :candidates)))
          (let ((state (skk-ime-session-control session 'register "加奈")))
            (should (equal registered "加奈"))
            (should (eq (plist-get state :mode) 'candidate))
            (should (equal (car (plist-get state :candidates)) "加奈"))
            (should (string-match-p "加奈" (plist-get state :text)))))))))

(ert-deftest skk-ime-session-register-and-commit-supports-private-mode ()
  "CorvusSKK private mode confirms registration text without learning it."
  (skk-ime-session-test--with-session session
    (let ((ddskk-user-jisyo--table (make-hash-table :test 'equal))
          (ddskk-user-jisyo-learning-disabled t))
      (skk-ime-session-feed-string session "Kana")
      (with-current-buffer (skk-ime-session-buffer session)
        (let ((skk-search-prog-list '((list))))
          (cl-letf (((symbol-function 'skk-henkan-in-minibuff)
                     (lambda () nil)))
            (skk-ime-session-control session 'convert)
            (let ((state (skk-ime-session-control
                          session 'register-and-commit "加奈")))
              (should (eq (plist-get state :mode) 'hiragana))
              (should (equal (plist-get state :text) "加奈"))
              (should-not (gethash "かな" ddskk-user-jisyo--table)))))))))

(ert-deftest skk-ime-session-register-and-commit-keeps-annotation ()
  "The last-semicolon annotation remains in the SKK dictionary record."
  (skk-ime-session-test--with-session session
    (let ((ddskk-user-jisyo--table (make-hash-table :test 'equal))
          (ddskk-user-jisyo--journal-pending 0)
          (ddskk-user-jisyo-learning-disabled nil))
      (cl-letf (((symbol-function 'ddskk-user-jisyo--journal-append)
                 (lambda (_midasi) t))
                ((symbol-function 'skk-henkan-in-minibuff)
                 (lambda () nil)))
        (skk-ime-session-feed-string session "Kana")
        (with-current-buffer (skk-ime-session-buffer session)
          (let ((skk-search-prog-list '((list))))
            (skk-ime-session-control session 'convert)
            (skk-ime-session-control
             session 'register-and-commit "加奈;人名")
            (should (equal (car (gethash "かな" ddskk-user-jisyo--table))
                           "加奈;人名"))))))))

(ert-deftest skk-ime-session-confirmed-candidate-is-ranked-first ()
  "The candidate actually committed becomes the next search's first result."
  (skk-ime-session-test--with-session session
    (let ((ddskk-user-jisyo--table (make-hash-table :test 'equal))
          (ddskk-user-jisyo--journal-pending 0)
          (ddskk-user-jisyo-learning-disabled nil))
      (cl-letf (((symbol-function 'ddskk-user-jisyo--journal-append)
                 (lambda (_midasi) t)))
        (with-current-buffer (skk-ime-session-buffer session)
          (let ((skk-search-prog-list '((list "仮名" "佳名")))
                (skk-update-jisyo-function #'ddskk-user-jisyo--update))
            (skk-ime-session-feed-string session "Kana")
            (skk-ime-session-control session 'convert)
            (skk-ime-session-control session 'convert)
            (skk-ime-session-control session 'commit)
            (should (equal (car (gethash "かな" ddskk-user-jisyo--table))
                           "佳名"))
            (skk-ime-session-reset session)
            (skk-ime-session-feed-string session "Kana")
            (setq skk-search-prog-list
                  '((ddskk-user-jisyo-search) (list "仮名" "佳名")))
            (let ((state (skk-ime-session-control session 'convert)))
              (should (equal (car (plist-get state :candidates)) "佳名"))
              (should (string-match-p "佳名" (plist-get state :text))))))))))

(ert-deftest skk-ime-session-control-forces-kana-class ()
  (skk-ime-session-test--with-session session
    (skk-ime-session-feed-string session "Kana")
    (let ((state (skk-ime-session-control session 'to-katakana)))
      (should (eq (plist-get state :mode) 'preedit))
      (should (equal (plist-get state :text) "▽カナ")))
    (let ((state (skk-ime-session-control session 'to-hiragana)))
      (should (equal (plist-get state :text) "▽かな")))))

(ert-deftest skk-ime-session-control-cancel-returns-katakana-to-hiragana ()
  "Ctrl+J's CANCEL leaves direct katakana mode in hiragana mode."
  (skk-ime-session-test--with-session session
    (skk-ime-session-feed-key session ?q)
    (should (eq (plist-get (skk-ime-session-snapshot session) :mode)
                'katakana))
    (let ((state (skk-ime-session-control session 'cancel)))
      (should (eq (plist-get state :mode) 'hiragana)))))

(ert-deftest skk-ime-session-inserts-every-ascii-digit-in-kana-mode ()
  "Digits bypass DDSKK's kana rule tree, which otherwise drops them."
  (skk-ime-session-test--with-session session
    (should (equal (plist-get
                    (skk-ime-session-feed-string session "0123456789") :text)
                   "0123456789"))
    (skk-ime-session-reset session)
    (skk-ime-session-feed-string session "Kana")
    (should (equal (plist-get
                    (skk-ime-session-feed-string session "0123456789") :text)
                   "▽かな0123456789"))))

(ert-deftest skk-ime-session-inserts-shift-digit-symbols-in-kana-mode ()
  "JIS/US Shift+digit symbols are literal, not DDSKK commands."
  (skk-ime-session-test--with-session session
    (should (equal
             (plist-get
              (skk-ime-session-feed-string session "!\"#$%&'()*@^") :text)
             "!\"#$%&'()*@^"))))

(ert-deftest skk-ime-session-cycles-past-ddskk-popup-threshold ()
  "Sumi owns candidate display, so Space keeps cycling past candidate four."
  (skk-ime-session-test--with-session session
    (skk-ime-session-feed-string session "Kana")
    (with-current-buffer (skk-ime-session-buffer session)
      (let ((skk-search-prog-list
             '((list "一" "二" "三" "四" "五" "六"))))
        (dotimes (index 6)
          (let ((state (skk-ime-session-control session 'convert)))
            (should (= (plist-get state :candidate-index) index))
            (should (string-match-p
                     (nth index '("一" "二" "三" "四" "五" "六"))
                     (plist-get state :text)))))))))

(ert-deftest skk-ime-session-signals-candidate-exhaustion-by-index ()
  "DDSKK preserves its list but advances the index past its final entry."
  (skk-ime-session-test--with-session session
    (cl-letf (((symbol-function 'skk-henkan-in-minibuff) (lambda () nil)))
      (skk-ime-session-feed-string session "Kana")
      (with-current-buffer (skk-ime-session-buffer session)
        (let ((skk-search-prog-list '((list "一" "二"))))
          (skk-ime-session-control session 'convert)
          (skk-ime-session-control session 'convert)
          (let ((exhausted (skk-ime-session-control session 'convert)))
            (should (eq (plist-get exhausted :mode) 'candidate))
            (should (= (plist-get exhausted :candidate-index) 2))
            (should (= (length (plist-get exhausted :candidates)) 2))))))))

(ert-deftest skk-ime-session-checkpoint-restores-exhausted-conversion ()
  "Modal registration may reuse a session without losing its main state."
  (skk-ime-session-test--with-session session
    (cl-letf (((symbol-function 'skk-henkan-in-minibuff) (lambda () nil)))
      (skk-ime-session-feed-string session "Kana")
      (with-current-buffer (skk-ime-session-buffer session)
        (let ((skk-search-prog-list '((list))))
          (skk-ime-session-control session 'convert)
          (let ((checkpoint (skk-ime-session-checkpoint session)))
            (skk-ime-session-reset session)
            (should (equal (plist-get
                            (skk-ime-session-feed-string session "tesuto")
                            :text)
                           "てすと"))
            (let ((state (skk-ime-session-restore session checkpoint)))
              (should (eq (plist-get state :mode) 'candidate))
              (should (equal (plist-get state :text) "▼かな")))))))))

(ert-deftest skk-ime-session-rejects-use-after-destroy ()
  (let ((session (skk-ime-session-create)))
    (skk-ime-session-destroy session)
    (should-error (skk-ime-session-snapshot session))))

(provide 'skk-ime-session-test)

;;; skk-ime-session-test.el ends here
