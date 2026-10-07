;;; test-eg1-cleaner.el --- Candidate sanitation parity -*- lexical-binding: t; -*-
(require 'ert)
(require 'skk-user-jisyo)
(defun eg1-reference-clean (candidate)
  (when (stringp candidate)
    (let ((index 0) visible eol chars)
      (while (< index (length candidate))
        (let ((ch (aref candidate index)))
          (if (memq ch '(10 13)) (setq eol t) (push ch chars))
          (unless (or (<= ch 32) (and (>= ch 127) (<= ch 159))
                      (memq ch '(160 5760 8192 8193 8194 8195 8196 8197
                                 8198 8199 8200 8201 8202 8232 8233 8239
                                 8287 12288 65279)))
            (setq visible t)))
        (setq index (1+ index)))
      (when visible (if eol (apply #'string (nreverse chars)) candidate)))))
(ert-deftest eg1-cleaner-preserves-sanitation ()
  (dolist (value '(nil 4 "" " \t\177" "　" "\r\n" "A\r\nB;note"
                   "仮名;annotation" "😀" "𠮷" " \r漢\n " "\000A"))
    (should (equal (eg1-reference-clean value)
                   (ddskk-user-jisyo--clean-candidate value))))
  (dolist (space '(0 9 10 13 32 127 159 160 5760 8192 8193 8194
                    8195 8196 8197 8198 8199 8200 8201 8202 8232 8233
                    8239 8287 12288 65279))
    (dolist (word (list (string space) (concat (string space) "漢字")
                        (concat "漢" (string space) "字")))
      (should (equal (eg1-reference-clean word)
                     (ddskk-user-jisyo--clean-candidate word))))))
(ert-deftest eg1-cleaner-preserves-match-data-and-identity ()
  (string-match "b" "abc")
  (let ((data (match-data)) (candidate (copy-sequence "漢字;note")))
    (should (eq candidate (ddskk-user-jisyo--clean-candidate candidate)))
    (should (equal "AB" (ddskk-user-jisyo--clean-candidate "A\r\nB")))
    (should (equal data (match-data)))))
