;;; nelisp-ime-lattice-test.el --- Tests for the lattice engine  -*- lexical-binding: t; -*-

(require 'ert)
(require 'nelisp-ime)
(require 'nelisp-ime-lattice)

(defmacro nelisp-ime-lattice-test--isolated (&rest body)
  "Run BODY with isolated sessions, learning, and dictionaries."
  (declare (indent 0) (debug t))
  `(let ((nelisp-ime-sessions (make-hash-table :test 'equal))
         (nelisp-ime-learning (make-hash-table :test 'equal))
         (nelisp-ime-dictionary-index (make-hash-table :test 'equal))
         (nelisp-ime-dictionary nil)
         (nelisp-ime-converter-function #'nelisp-ime-lattice-convert))
     ,@body))

(ert-deftest nelisp-ime-lattice-test-prefers-lower-cost-path ()
  (nelisp-ime-lattice-test--isolated
    (setq nelisp-ime-dictionary
          '(("きょう" (:surface "今日" :cost 80))
            ("は" (:surface "は" :cost 10))
            ("きょうは" (:surface "教派" :cost 500))))
    (nelisp-ime-session-open "s")
    (nelisp-ime-feed "s" '(:op :insert :text "きょうは"))
    (let ((result (nelisp-ime-feed "s" '(:op :convert))))
      (should (equal (plist-get result :preedit) "今日は"))
      (should (= (length (plist-get result :segments)) 2))
      (should (equal (mapcar (lambda (segment)
                              (plist-get segment :reading))
                            (plist-get result :segments))
                     '("きょう" "は"))))))

(ert-deftest nelisp-ime-lattice-test-preserves-unknown-kana ()
  (nelisp-ime-lattice-test--isolated
    (setq nelisp-ime-dictionary
          '(("ねこ" (:surface "猫" :cost 50))))
    (let ((result (nelisp-ime-lattice-convert "ねこです" nil)))
      (should (equal (plist-get result :preedit) "猫です"))
      (should (= (length (plist-get result :segments)) 2)))))

(ert-deftest nelisp-ime-lattice-test-selects-candidate-within-active-segment ()
  (nelisp-ime-lattice-test--isolated
    (setq nelisp-ime-dictionary
          '(("はし" "橋" "箸") ("です" "です")))
    (nelisp-ime-session-open "s")
    (nelisp-ime-feed "s" '(:op :insert :text "はしです"))
    (nelisp-ime-feed "s" '(:op :convert))
    (let ((result (nelisp-ime-feed
                   "s" '(:op :select-candidate :index 1))))
      (should (equal (plist-get result :preedit) "箸です")))
    (let ((result (nelisp-ime-feed
                   "s" '(:op :select-segment :index 1))))
      (should (= (plist-get result :active-segment) 1))
      (should (equal (plist-get result :candidates) ["です"])))))

(ert-deftest nelisp-ime-lattice-test-commit-learns-selected-candidate ()
  (nelisp-ime-lattice-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸")))
    (nelisp-ime-session-open "s")
    (nelisp-ime-feed "s" '(:op :insert :text "はし"))
    (nelisp-ime-feed "s" '(:op :convert))
    (nelisp-ime-feed "s" '(:op :select-candidate :index 1))
    (nelisp-ime-feed "s" '(:op :commit))
    (should (= (nelisp-ime-learning-count "はし" "箸") 1))
    (let ((result (nelisp-ime-lattice-convert "はし" nil)))
      (should (equal (plist-get result :preedit) "箸")))))

(ert-deftest nelisp-ime-lattice-test-loads-and-indexes-skk-dictionary ()
  (nelisp-ime-lattice-test--isolated
    (let* ((directory (make-temp-file "nelisp-ime-skk-" t))
           (file (expand-file-name "SKK-JISYO.test" directory)))
      (unwind-protect
          (progn
            ;; The loader below reads with an explicit utf-8, so pin the
            ;; write coding too — the host default is locale-dependent
            ;; (e.g. japanese-shift-jis-dos on Japanese Windows).
            (let ((coding-system-for-write 'utf-8-unix))
              (with-temp-file file
                (insert ";; okuri-nasi entries.\n")
                (insert "かな /仮名;annotation/かな/\n")
                (insert "おくr /送/\n")))
            (should (= (nelisp-ime-dictionary-load-skk file 'utf-8) 1))
            (let ((result (nelisp-ime-lattice-convert "かな" nil)))
              (should (equal (plist-get result :preedit) "仮名"))
              (should (equal (plist-get result :candidates)
                             '("仮名" "かな")))))
        (delete-directory directory t)))))

(ert-deftest nelisp-ime-lattice-test-expands-skk-okuri-conjugations ()
  (nelisp-ime-lattice-test--isolated
    (let* ((directory (make-temp-file "nelisp-ime-okuri-" t))
           (file (expand-file-name "SKK-JISYO.okuri" directory)))
      (unwind-protect
          (progn
            ;; Pin the write coding to match the loader's explicit utf-8
            ;; (the host default may be a non-UTF-8 DOS coding).
            (let ((coding-system-for-write 'utf-8-unix))
              (with-temp-file file
                (insert "いk /行/\n")
                (insert "はなs /話/\n")))
            (nelisp-ime-dictionary-load-skk file 'utf-8 t)
            (should (equal (plist-get (nelisp-ime-lattice-convert "いきます" nil)
                                      :preedit)
                           "行きます"))
            (should (equal (plist-get (nelisp-ime-lattice-convert "はなした" nil)
                                      :preedit)
                           "話した")))
        (delete-directory directory t)))))

(ert-deftest nelisp-ime-lattice-test-registers-as-default-engine ()
  (nelisp-ime-lattice-test--isolated
    (setq nelisp-ime-converter-function nil)
    (let ((nelisp-ime-default-engine 'lattice))
      (setq nelisp-ime-dictionary '(("はし" "橋" "箸")))
      (nelisp-ime-session-open "s")
      (nelisp-ime-feed "s" '(:op :insert :text "はし"))
      (should (equal (plist-get (nelisp-ime-feed "s" '(:op :convert))
                                :preedit)
                     "橋")))))

(provide 'nelisp-ime-lattice-test)
;;; nelisp-ime-lattice-test.el ends here
