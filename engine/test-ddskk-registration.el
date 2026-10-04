;;; test-ddskk-registration.el --- Standalone registration regression -*- lexical-binding: t; -*-

;; Run from the repository root with --load and a fresh DDSKK_USER_JISYO.
(unless (and (getenv "DDSKK_USER_JISYO")
             (> (length (getenv "DDSKK_USER_JISYO")) 0))
  (error "Registration test requires an explicit private DDSKK_USER_JISYO"))
(load "engine/ddskk-engine.el")
(setq ddskk-engine--debug-errors t
      skk-search-prog-list '((ddskk-user-jisyo-search)))

(defvar ddskk-registration-test--checks 0)
(defun ddskk-registration-test--check (condition label)
  (unless condition (error "Registration regression: %s" label))
  (setq ddskk-registration-test--checks
        (1+ ddskk-registration-test--checks)))

(dolist (case (list (cons "97,105" "ai")
                   (cons "0,1114111" (string 0 #x10ffff))
                   (cons "00097" "a")
                   (cons nil nil) (cons "" nil) (cons "," nil)
                   (cons "97," nil) (cons ",97" nil)
                   (cons "97,,105" nil) (cons "97a" nil)
                   (cons " 97" nil) (cons "-1" nil)
                   (cons "55296" nil) (cons "57343" nil)
                   (cons "1114112" nil)))
  (ddskk-registration-test--check
   (equal (ddskk-engine--decode-codepoints (car case)) (cdr case))
   "decimal Unicode scalar validation"))

(defun ddskk-registration-test--request (request)
  (ddskk-engine-dispatch-line (concat "SESSION registration-test " request)))

(ddskk-registration-test--check
 (equal (ddskk-registration-test--request
         "CONTROL CONVERT-KEYS 80,97,112,97,112,97")
        "STATE registration 0 -1 - - -1 - 003071003071003071")
 "missing candidate enters registration")
(ddskk-registration-test--check
 (equal (ddskk-registration-test--request
         "CONTROL FEED-KEYS 116,101,115,117,116,111")
        "STATE registration 3 -1 003066003059003068 - -1 - 003071003071003071")
 "registration kana input")
(ddskk-registration-test--check
 (equal (ddskk-registration-test--request "CONTROL COMMIT")
        "STATE hiragana 3 -1 003066003059003068 - -1 -")
 "confirm once with an integer conversion position")
(ddskk-registration-test--check
 (equal (gethash (string #x3071 #x3071 #x3071) ddskk-user-jisyo--table)
        (list (string #x3066 #x3059 #x3068)))
 "registered word is learned")

(ddskk-registration-test--request "CONTROL CONVERT-KEYS 80,97,112,97,112,105")
(ddskk-registration-test--request "CONTROL FEED-KEYS 116,101")
(ddskk-registration-test--check
 (equal (ddskk-registration-test--request "CONTROL QUIT")
        "STATE preedit 4 1 0025bd003071003071003074 - -1 -")
 "first quit restores the reading with an integer position")
(ddskk-registration-test--check
 (equal (ddskk-registration-test--request "CONTROL QUIT")
        "STATE hiragana 0 -1 - - -1 -")
 "second quit dismisses the restored reading")
(ddskk-registration-test--request "KEY 107")
(ddskk-registration-test--check
 (equal (ddskk-registration-test--request "KEY 97")
        "STATE hiragana 1 -1 00304b - -1 -")
 "cancelled registration cannot leak into the next word")

(nelisp--write-stdout-bytes
 (concat "PASS registration assertions="
         (number-to-string ddskk-registration-test--checks) "\n"))
