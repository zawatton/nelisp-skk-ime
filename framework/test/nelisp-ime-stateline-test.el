;;; nelisp-ime-stateline-test.el --- Tests for the STATE line protocol -*- lexical-binding: t; -*-

(require 'ert)
(require 'nelisp-ime)
(require 'nelisp-ime-stateline)
(require 'nelisp-ime-lattice)

(defmacro nelisp-ime-stateline-test--lattice (&rest body)
  "Run BODY with isolated lattice sessions and a small kana dictionary."
  (declare (indent 0))
  `(let ((nelisp-ime-sessions (make-hash-table :test 'equal))
         (nelisp-ime-learning (make-hash-table :test 'equal))
         (nelisp-ime-dictionary-index (make-hash-table :test 'equal))
         (nelisp-ime-dictionary nil)
         (nelisp-ime-default-engine 'lattice))
     (nelisp-ime-dictionary-install
      '(("ぼく" "ぼく" "僕") ("たち" "たち" "達")
        ("ぼ" "母") ("く" "く") ("できない" "出来ない" "できない")
        ("は" "葉")))
     ,@body))

(defun nelisp-ime-stateline-test--type (text)
  "Type romaji TEXT through the wire protocol."
  (mapc (lambda (char)
          (nelisp-ime-stateline-dispatch (concat "KEY " (number-to-string char))))
        text))

(ert-deftest nelisp-ime-stateline-test-lattice-active-candidates-and-commit ()
  (nelisp-ime-stateline-test--lattice
    (nelisp-ime-stateline-test--type "bokutati")
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL CONVERT")))
      (should (equal (nelisp-ime-stateline-test--field line 8) "0:2,2:2;0"))
      (should (equal (nelisp-ime-stateline-test--field line 7)
                     "00307c00304f,0050d5")))
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL CONVERT")))
      (should (equal (nelisp-ime-stateline-test--field line 4) "0050d500305f003061")))
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL SEGMENT-NEXT")))
      (should (equal (nelisp-ime-stateline-test--field line 8) "0:1,1:2;1"))
      (should (equal (nelisp-ime-stateline-test--field line 7)
                     "00305f003061,009054")))
    (nelisp-ime-stateline-dispatch "CONTROL CONVERT")
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL COMMIT")))
      (should (equal (nelisp-ime-stateline-test--field line 4) "0050d5009054"))
      (should (equal (nelisp-ime-stateline-test--field line 3) "-1"))
      (should (= (length (split-string line " ")) 8)))))

(ert-deftest nelisp-ime-stateline-test-lattice-focus-retains-selection ()
  (nelisp-ime-stateline-test--lattice
    (nelisp-ime-stateline-test--type "bokutati")
    (nelisp-ime-stateline-dispatch "CONTROL CONVERT")
    (nelisp-ime-stateline-dispatch "CONTROL CONVERT")
    (nelisp-ime-stateline-dispatch "CONTROL SEGMENT-NEXT")
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL SEGMENT-PREV")))
      (should (equal (nelisp-ime-stateline-test--field line 6) "1")))
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL PREVIOUS")))
      (should (equal (nelisp-ime-stateline-test--field line 4)
                     "00307c00304f00305f003061")))))

(ert-deftest nelisp-ime-stateline-test-lattice-particle-stays-kana ()
  (nelisp-ime-stateline-test--lattice
    (nelisp-ime-stateline-test--type "hadekinai")
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL CONVERT")))
      (should (equal (nelisp-ime-stateline-test--field line 4)
                     (nelisp-ime-stateline--hex "は出来ない"))))
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL SEGMENT-NEXT")))
      (should (equal (nelisp-ime-stateline-test--field line 8) "0:1,1:4;1"))
      (should (equal (nelisp-ime-stateline-test--field line 7)
                     (concat (nelisp-ime-stateline--hex "出来ない") ","
                             (nelisp-ime-stateline--hex "できない")))))))

(ert-deftest nelisp-ime-stateline-test-lattice-resize-preserves-readings ()
  (nelisp-ime-stateline-test--lattice
    (nelisp-ime-stateline-test--type "bokutati")
    (nelisp-ime-stateline-dispatch "CONTROL CONVERT")
    (nelisp-ime-stateline-dispatch "CONTROL SEGMENT-SHRINK")
    (let* ((session (nelisp-ime-stateline--session))
           (segments (plist-get session :segments)))
      (should (equal (mapcar (lambda (s) (plist-get s :reading)) segments)
                     '("ぼ" "く" "たち")))
      (should (equal (mapcar (lambda (s) (list (plist-get s :from) (plist-get s :to)))
                            segments) '((0 1) (1 2) (2 4)))))
    (nelisp-ime-stateline-dispatch "CONTROL SEGMENT-EXTEND")
    (should (equal (mapcar (lambda (s) (plist-get s :reading))
                          (plist-get (nelisp-ime-stateline--session) :segments))
                   '("ぼく" "たち")))))

(ert-deftest nelisp-ime-stateline-test-segment-field-uses-display-offsets ()
  (let ((line (nelisp-ime-stateline--line
               '(:mode "candidate" :preedit "前😀達" :cursor 3
                 :composition-start 0 :active-segment 0
                 :segments [(:reading "ぼく" :candidate "😀")
                            (:reading "たち" :candidate "達")]
                 :candidates ["😀"] :candidate-index 0))))
    (should (equal (nelisp-ime-stateline-test--field line 8) "1:1,2:1;0"))
    (should (equal (nelisp-ime-stateline-test--field line 2) "2"))))

(ert-deftest nelisp-ime-stateline-test-old-eight-field-reader-compatible ()
  (nelisp-ime-stateline-test--lattice
    (nelisp-ime-stateline-test--type "bokutati")
    (let* ((line (nelisp-ime-stateline-dispatch "CONTROL CONVERT"))
           (fields (split-string line " "))
           (old-form (mapconcat #'identity (cl-subseq fields 0 8) " ")))
      (should (= (length (split-string old-form " ")) 8))
      (should (equal (nelisp-ime-stateline-test--field old-form 7)
                     (nelisp-ime-stateline-test--field line 7))))))

(ert-deftest nelisp-ime-stateline-test-skk-abbreviations-not-okuri ()
  (nelisp-ime-stateline-test--lattice
    (let ((table (make-hash-table :test 'equal)))
      (nelisp-ime--skk-line "k /κ/ケイ/" table t)
      (nelisp-ime--skk-line "i /ι/" table t)
      (nelisp-ime--skk-line "Greek /Α/" table t)
      (should-not (gethash "く" table))
      (should-not (gethash "い" table))
      (should-not (gethash "Greeく" table))
      (nelisp-ime--skk-line "かk /書/" table t)
      (should (equal (gethash "かいた" table) '("書いた"))))))

(defconst nelisp-ime-stateline-test--dictionary-file
  (expand-file-name "../../engines/lattice/data/nelisp-ime-dictionary-data.el"
                    (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest nelisp-ime-stateline-test-shipped-lattice-segments ()
  (nelisp-ime-stateline-test--lattice
    (load nelisp-ime-stateline-test--dictionary-file nil t)
    (nelisp-ime-stateline-test--type "bokutati")
    (nelisp-ime-stateline-dispatch "CONTROL CONVERT")
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL SEGMENT-SHRINK")))
      (should (equal (nelisp-ime-stateline-test--field line 4)
                     (nelisp-ime-stateline--hex "母く達"))))
    (nelisp-ime-stateline-dispatch "CONTROL SEGMENT-EXTEND")
    (dotimes (_ 3) (nelisp-ime-stateline-dispatch "CONTROL CONVERT"))
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL SEGMENT-NEXT")))
      (should (equal (nelisp-ime-stateline-test--field line 8) "0:1,1:1;1")))
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL COMMIT")))
      (should (equal (nelisp-ime-stateline-test--field line 4)
                     (nelisp-ime-stateline--hex "僕達"))))
    (nelisp-ime-stateline-test--type "hadekinai")
    (nelisp-ime-stateline-dispatch "CONTROL CONVERT")
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL SEGMENT-NEXT")))
      (should (equal (nelisp-ime-stateline-test--field line 8) "0:1,1:4;1"))
      (should (equal (nelisp-ime-stateline-test--field line 4)
                     (nelisp-ime-stateline--hex "は出来ない"))))))

(defmacro nelisp-ime-stateline-test--isolated (&rest body)
  "Run BODY with isolated sessions and dictionary."
  (declare (indent 0) (debug t))
  `(let ((nelisp-ime-sessions (make-hash-table :test 'equal))
         (nelisp-ime-learning (make-hash-table :test 'equal))
         (nelisp-ime-dictionary nil)
         (nelisp-ime-converter-function #'nelisp-ime-dictionary-convert))
     ,@body))

(defun nelisp-ime-stateline-test--field (line index)
  "Return field INDEX of a space-separated STATE LINE."
  (nth index (split-string line " ")))

(ert-deftest nelisp-ime-stateline-test-hex-matches-wire-format ()
  ;; Fixed-width 6-digit lowercase scalar hex, "-" for empty.
  (should (equal (nelisp-ime-stateline--hex "") "-"))
  (should (equal (nelisp-ime-stateline--hex "a") "000061"))
  (should (equal (nelisp-ime-stateline--hex "あ") "003042"))
  (should (equal (nelisp-ime-stateline--hex "ab") "000061000062"))
  ;; Above the BMP the top two digits are significant.
  (should (equal (nelisp-ime-stateline--hex (char-to-string #x1F600))
                 "01f600")))

(ert-deftest nelisp-ime-stateline-test-hello-and-engine-verbs ()
  (nelisp-ime-stateline-test--isolated
    (should (equal (nelisp-ime-stateline-dispatch "HELLO 1") "OK 1"))
    (should (string-prefix-p "ENGINES "
                             (nelisp-ime-stateline-dispatch "ENGINE LIST")))
    (should (string-prefix-p "ENGINE "
                             (nelisp-ime-stateline-dispatch "ENGINE CURRENT")))
    (nelisp-ime-stateline-dispatch "KEY 107")
    (let ((nelisp-ime-default-engine nelisp-ime-default-engine))
      (should (equal (nelisp-ime-stateline-dispatch "ENGINE SET dictionary")
                     "OK ENGINE dictionary"))
      (should (eq nelisp-ime-default-engine 'dictionary))
      (let ((status (nelisp-ime-stateline-dispatch "STATUS")))
        (should (equal (nelisp-ime-stateline-test--field status 3) "-1"))
        (should (equal (nelisp-ime-stateline-test--field status 4) "-"))))
    (should (equal (nelisp-ime-stateline-dispatch "ENGINE SET nope")
                   "ERR ENGINE nope"))))

(ert-deftest nelisp-ime-stateline-test-key-produces-state-line ()
  (nelisp-ime-stateline-test--isolated
    ;; A bare consonant stays pending; a vowel completes a kana.
    (let ((line (nelisp-ime-stateline-dispatch "KEY 107")))   ; k
      (should (string-prefix-p "STATE " line))
      (should (= (length (split-string line " ")) 8))
      (should (equal (nelisp-ime-stateline-test--field line 5) "00006b")))
    (let ((line (nelisp-ime-stateline-dispatch "KEY 97")))    ; a -> か
      (should (equal (nelisp-ime-stateline-test--field line 4) "00304b"))
      (should (equal (nelisp-ime-stateline-test--field line 5) "-")))))

(ert-deftest nelisp-ime-stateline-test-key-rejects-bad-codepoints ()
  (nelisp-ime-stateline-test--isolated
    (should (equal (nelisp-ime-stateline-dispatch "KEY abc") "ERR CODEPOINT"))
    (should (equal (nelisp-ime-stateline-dispatch "KEY 0") "ERR CODEPOINT"))
    (should (equal (nelisp-ime-stateline-dispatch "KEY 99999999")
                   "ERR CODEPOINT"))
    (should (equal (nelisp-ime-stateline-dispatch "NOPE") "ERR REQUEST"))))

(ert-deftest nelisp-ime-stateline-test-status-has-no-side-effects ()
  (nelisp-ime-stateline-test--isolated
    (nelisp-ime-stateline-dispatch "KEY 107")   ; k
    (nelisp-ime-stateline-dispatch "KEY 97")    ; a
    (let ((first (nelisp-ime-stateline-dispatch "STATUS"))
          (second (nelisp-ime-stateline-dispatch "STATUS")))
      (should (string-prefix-p "STATE " first))
      (should (equal first second)))))

(ert-deftest nelisp-ime-stateline-test-session-prefix-isolates-composition ()
  (nelisp-ime-stateline-test--isolated
    (should (equal (nelisp-ime-stateline-dispatch "DIAG SESSION-COUNT")
                   "SESSIONS 0"))
    (should (string-prefix-p "STATE "
                             (nelisp-ime-stateline-dispatch
                              "SESSION app-a KEY 107"))) ; k
    (should (string-prefix-p "STATE "
                             (nelisp-ime-stateline-dispatch
                              "SESSION app-b KEY 110"))) ; n
    (let ((app-a (nelisp-ime-stateline-dispatch "SESSION app-a KEY 97"))
          (app-b (nelisp-ime-stateline-dispatch "SESSION app-b STATUS")))
      (should (equal (nelisp-ime-stateline-test--field app-a 4) "00304b"))
      (should (equal (nelisp-ime-stateline-test--field app-b 5) "00006e")))
    (should (equal (nelisp-ime-stateline-dispatch "SESSION app-a CLOSE")
                   "OK CLOSED"))
    (should (equal (nelisp-ime-stateline-dispatch "DIAG SESSION-COUNT")
                   "SESSIONS 1"))
    (should-not (gethash "app-a" nelisp-ime-sessions))))

(ert-deftest nelisp-ime-stateline-test-commit-and-reset ()
  (nelisp-ime-stateline-test--isolated
    (setq nelisp-ime-dictionary '(("かな" "仮名")))
    (nelisp-ime-stateline-dispatch "KEY 107")   ; k
    (nelisp-ime-stateline-dispatch "KEY 97")    ; a
    (nelisp-ime-stateline-dispatch "KEY 110")   ; n
    (nelisp-ime-stateline-dispatch "KEY 97")    ; a
    (should (string-prefix-p "STATE "
                             (nelisp-ime-stateline-dispatch "CONTROL COMMIT")))
    ;; After commit the composition is empty again.
    (let ((line (nelisp-ime-stateline-dispatch "STATUS")))
      (should (equal (nelisp-ime-stateline-test--field line 4) "-"))
      (should (equal (nelisp-ime-stateline-test--field line 3) "-1")))
    (should (string-prefix-p "STATE "
                             (nelisp-ime-stateline-dispatch "RESET")))))

(ert-deftest nelisp-ime-stateline-test-convert-steps-candidates ()
  (nelisp-ime-stateline-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸" "端")))
    (nelisp-ime-session-open nelisp-ime-stateline--session-id
                             '(:input-style romaji))
    (nelisp-ime-feed nelisp-ime-stateline--session-id
                     '(:op :insert :text "はし"))
    ;; The first CONVERT performs the conversion and lands on candidate 0;
    ;; only from there does it step.  This is the space key of any
    ;; Japanese IME, and it is why typing alone shows no candidates.
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL CONVERT")))
      (should (equal (nelisp-ime-stateline-test--field line 6) "0")))
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL CONVERT")))
      ;; Stepped from candidate 0 to 1.
      (should (equal (nelisp-ime-stateline-test--field line 6) "1")))
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL PREVIOUS")))
      (should (equal (nelisp-ime-stateline-test--field line 6) "0")))))

(ert-deftest nelisp-ime-stateline-test-convert-without-candidates-reports-state ()
  (nelisp-ime-stateline-test--isolated
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL CONVERT")))
      (should (string-prefix-p "STATE " line)))))

(ert-deftest nelisp-ime-stateline-test-maintenance-verbs ()
  (nelisp-ime-stateline-test--isolated
    (should (equal (nelisp-ime-stateline-dispatch "GC") "OK GC"))
    (should (string-prefix-p "OK COMPACT"
                             (nelisp-ime-stateline-dispatch "COMPACT")))
    (should (equal (nelisp-ime-stateline-dispatch "QUIT") "OK BYE"))))

(ert-deftest nelisp-ime-stateline-test-engine-failure-degrades ()
  (nelisp-ime-stateline-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines))
          (nelisp-ime-fail-open nil))
      (nelisp-ime-engine-register
       'boom-stateline
       :feed (lambda (_id _session _event) (error "engine exploded")))
      (nelisp-ime-session-open nelisp-ime-stateline--session-id
                               '(:input-style romaji :engine boom-stateline))
      ;; With fail-open disabled the engine signals; the protocol must still
      ;; answer a line rather than propagate.
      (should (equal (nelisp-ime-stateline-dispatch "KEY 97") "ERR INTERNAL")))))

(provide 'nelisp-ime-stateline-test)
;;; nelisp-ime-stateline-test.el ends here
