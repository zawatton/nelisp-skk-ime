;;; nelisp-ime-test.el --- Tests for the NeLisp IME framework core  -*- lexical-binding: t; -*-

;; These tests exercise the engine-agnostic framework only.  The bundled
;; lattice engine has its own suite in the nelisp-ime-lattice package.

(require 'ert)
(require 'nelisp-ime)

(defmacro nelisp-ime-test--isolated (&rest body)
  "Run BODY with isolated sessions and dictionary."
  (declare (indent 0) (debug t))
  `(let ((nelisp-ime-sessions (make-hash-table :test 'equal))
         (nelisp-ime-learning (make-hash-table :test 'equal))
         (nelisp-ime-dictionary nil)
         (nelisp-ime-converter-function #'nelisp-ime-dictionary-convert))
     ,@body))

(ert-deftest nelisp-ime-test-open-and-insert-kana ()
  (nelisp-ime-test--isolated
    (nelisp-ime-session-open "mac:1" '(:input-style kana))
    (let ((result (nelisp-ime-feed "mac:1" '(:op :insert :text "かな"))))
      (should (equal (plist-get result :reading) "かな"))
      (should (equal (plist-get result :preedit) "かな")))))

(ert-deftest nelisp-ime-test-live-converts-after-each-insert ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary
          '(("きょう" "今日" "教") ("きょ" "許")))
    (nelisp-ime-session-open "s")
    (should (equal (plist-get
                    (nelisp-ime-feed "s" '(:op :insert :text "きょ"))
                    :preedit)
                   "許"))
    (should (equal (plist-get
                    (nelisp-ime-feed "s" '(:op :insert :text "う"))
                    :preedit)
                   "今日"))))

(ert-deftest nelisp-ime-test-select-and-commit-candidate ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸" "端")))
    (nelisp-ime-session-open "s")
    (nelisp-ime-feed "s" '(:op :insert :text "はし"))
    (let ((selected (nelisp-ime-feed
                     "s" '(:op :select-candidate :index 1))))
      (should (equal (plist-get selected :preedit) "箸")))
    (let ((committed (nelisp-ime-feed "s" '(:op :commit))))
      (should (equal (plist-get committed :commit) "箸"))
      (should (equal (plist-get committed :preedit) "")))))

(ert-deftest nelisp-ime-test-backspace-reconverts ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary '(("か" "蚊") ("かな" "仮名")))
    (nelisp-ime-session-open "s")
    (nelisp-ime-feed "s" '(:op :insert :text "かな"))
    (let ((result (nelisp-ime-feed "s" '(:op :backspace))))
      (should (equal (plist-get result :reading) "か"))
      (should (equal (plist-get result :preedit) "蚊")))))

(ert-deftest nelisp-ime-test-cancel-and-session-isolation ()
  (nelisp-ime-test--isolated
    (nelisp-ime-session-open "linux:1")
    (nelisp-ime-session-open "windows:1")
    (nelisp-ime-feed "linux:1" '(:op :insert :text "あ"))
    (nelisp-ime-feed "windows:1" '(:op :insert :text "い"))
    (should-not (plist-get (nelisp-ime-feed "linux:1" '(:op :cancel))
                           :commit))
    (should (equal
             (plist-get (nelisp-ime-feed "windows:1" '(:op :commit)) :commit)
             "い"))))

(ert-deftest nelisp-ime-test-rejects-invalid-events ()
  (nelisp-ime-test--isolated
    ;; Session-level errors still signal: they are adapter bugs, not
    ;; keystrokes to pass through.
    (should-error (nelisp-ime-session-open "") :type 'error)
    (should-error (nelisp-ime-feed "missing" '(:op :commit))
                  :type 'error)
    (nelisp-ime-session-open "s")
    ;; Malformed events reach the user as unconsumed keystrokes under the
    ;; default fail-open policy, and signal when it is disabled.
    (dolist (event '((:op :insert :text 1) (:op :unknown)))
      (should-not (plist-get (nelisp-ime-feed "s" event) :consumed))
      (let ((nelisp-ime-fail-open nil))
        (should-error (nelisp-ime-feed "s" event) :type 'error)))))

(ert-deftest nelisp-ime-test-jis-kana-physical-keys-and-marks ()
  (nelisp-ime-test--isolated
    (nelisp-ime-session-open "s" '(:input-style kana))
    (nelisp-ime-feed "s" '(:op :key :code "KeyT"))
    (let ((result (nelisp-ime-feed
                   "s" '(:op :key :code "BracketLeft"))))
      (should (equal (plist-get result :reading) "が")))
    (let ((result (nelisp-ime-feed
                   "s" '(:op :key :code "KeyZ" :shift t))))
      (should (equal (plist-get result :reading) "がっ")))))

(ert-deftest nelisp-ime-test-jis-kana-specific-and-punctuation-keys ()
  (should (equal (nelisp-ime-jis-kana-key "IntlYen" nil) "ー"))
  (should (equal (nelisp-ime-jis-kana-key "Backslash" nil) "む"))
  (should (equal (nelisp-ime-jis-kana-key "IntlRo" nil) "ろ"))
  (should (equal (nelisp-ime-jis-kana-key "Comma" t) "、"))
  (should (equal (nelisp-ime-jis-kana-key "Period" t) "。"))
  (should (equal (nelisp-ime-jis-kana-key "Slash" t) "・")))

(ert-deftest nelisp-ime-test-romaji-incremental-normalization ()
  (nelisp-ime-test--isolated
    (nelisp-ime-session-open "s" '(:input-style romaji))
    (dolist (key '("k" "y" "o" "u"))
      (nelisp-ime-feed "s" `(:op :key :key ,key)))
    (let ((result (nelisp-ime-feed "s" '(:op :key :key "h"))))
      (should (equal (plist-get result :reading) "きょう"))
      (should (equal (plist-get result :preedit) "きょうh"))
      (should (equal (plist-get result :pending) "h")))
    (let ((result (nelisp-ime-feed "s" '(:op :key :key "a"))))
      (should (equal (plist-get result :reading) "きょうは"))
      (should (equal (plist-get result :pending) "")))))

(ert-deftest nelisp-ime-test-romaji-double-consonant-and-n ()
  (should (equal (nelisp-ime-romaji-step "k" "k")
                 '(:text "っ" :pending "k")))
  (let ((first (nelisp-ime-romaji-step "" "n")))
    (should (equal (plist-get first :pending) "n"))
    (should (equal (nelisp-ime-romaji-step "n" "n")
                   '(:text "ん" :pending "")))))

(ert-deftest nelisp-ime-test-romaji-pending-backspace-and-commit ()
  (nelisp-ime-test--isolated
    (nelisp-ime-session-open "s" '(:input-style romaji))
    (nelisp-ime-feed "s" '(:op :key :key "k"))
    (let ((result (nelisp-ime-feed "s" '(:op :backspace))))
      (should (equal (plist-get result :preedit) ""))
      (should (equal (plist-get result :pending) "")))
    (nelisp-ime-feed "s" '(:op :key :key "n"))
    (let ((result (nelisp-ime-feed "s" '(:op :commit))))
      (should (equal (plist-get result :commit) "ん")))))

(ert-deftest nelisp-ime-test-commit-learns-selected-candidate ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸")))
    (nelisp-ime-session-open "s")
    (nelisp-ime-feed "s" '(:op :insert :text "はし"))
    (nelisp-ime-feed "s" '(:op :select-candidate :index 1))
    (nelisp-ime-feed "s" '(:op :commit))
    (should (= (nelisp-ime-learning-count "はし" "箸") 1))))

(ert-deftest nelisp-ime-test-learning-round-trips-without-eval ()
  (nelisp-ime-test--isolated
    (let* ((directory (make-temp-file "nelisp-ime-learning-" t))
           (file (expand-file-name "learning.eldata" directory)))
      (unwind-protect
          (progn
            (puthash (nelisp-ime--learning-key "かな" "仮名") 3
                     nelisp-ime-learning)
            (nelisp-ime-learning-save file)
            (setq nelisp-ime-learning (make-hash-table :test 'equal))
            (should (= (nelisp-ime-learning-load file) 1))
            (should (= (nelisp-ime-learning-count "かな" "仮名") 3)))
        (delete-directory directory t)))))

(ert-deftest nelisp-ime-test-learning-import-validates-data ()
  (nelisp-ime-test--isolated
    (should-error (nelisp-ime-learning-import '(("key" "value" -1)))
                  :type 'error)
    (should-error (nelisp-ime-learning-import '((symbol "value" 1)))
                  :type 'error)))

(ert-deftest nelisp-ime-test-snapshot-truncates-candidates ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary '(("は" "端" "歯" "葉" "刃" "派")))
    (let ((nelisp-ime-candidate-limit 2))
      (nelisp-ime-session-open "s")
      (let ((result (nelisp-ime-feed "s" '(:op :insert :text "は"))))
        (should (equal (plist-get result :candidates) ["端" "歯"]))))
    (let ((nelisp-ime-candidate-limit nil))
      (nelisp-ime-session-open "s")
      (let ((result (nelisp-ime-feed "s" '(:op :insert :text "は"))))
        (should (= (length (plist-get result :candidates)) 5))))))

(ert-deftest nelisp-ime-test-session-selects-registered-engine ()
  (nelisp-ime-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines)))
      (nelisp-ime-engine-register
       'upcase-test
       :convert (lambda (reading _context)
                  (list :preedit (upcase reading)
                        :candidates (list (upcase reading))
                        :segments nil)))
      (nelisp-ime-session-open "s" '(:input-style romaji :engine upcase-test))
      (should (equal (plist-get
                      (nelisp-ime-feed "s" '(:op :insert :text "abc"))
                      :preedit)
                     "ABC")))))

(ert-deftest nelisp-ime-test-feed-hook-intercepts-events ()
  (nelisp-ime-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines)))
      (nelisp-ime-engine-register
       'modal-test
       :feed (lambda (_session-id _session event)
               (list :consumed t
                     :preedit (format "modal:%s" (plist-get event :op)))))
      (nelisp-ime-session-open "s" '(:engine modal-test))
      (should (equal (plist-get
                      (nelisp-ime-feed "s" '(:op :insert :text "x"))
                      :preedit)
                     "modal::insert")))))

(ert-deftest nelisp-ime-test-open-rejects-unknown-engine ()
  (nelisp-ime-test--isolated
    (should-error (nelisp-ime-session-open "s" '(:engine no-such-engine))
                  :type 'error)))

(ert-deftest nelisp-ime-test-default-engine-used-without-converter ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-converter-function nil)
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines))
          (nelisp-ime-default-engine 'default-test))
      (nelisp-ime-engine-register
       'default-test
       :convert (lambda (reading _context)
                  (list :preedit (concat "d:" reading)
                        :candidates (list reading)
                        :segments nil)))
      (nelisp-ime-session-open "s")
      (should (equal (plist-get
                      (nelisp-ime-feed "s" '(:op :insert :text "はし"))
                      :preedit)
                     "d:はし")))))

(ert-deftest nelisp-ime-test-engine-learn-hook-replaces-framework-learning ()
  (nelisp-ime-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines))
          (learned nil))
      (nelisp-ime-engine-register
       'learn-test
       :convert #'nelisp-ime-dictionary-convert
       :learn (lambda (segments) (setq learned segments)))
      (setq nelisp-ime-dictionary '(("はし" "橋")))
      (nelisp-ime-session-open "s" '(:engine learn-test))
      (nelisp-ime-feed "s" '(:op :insert :text "はし"))
      (nelisp-ime-feed "s" '(:op :commit))
      (should learned)
      (should (= (nelisp-ime-learning-count "はし" "橋") 0)))))

;;; Snapshot shape absorbed from the SKK adapter contract

(ert-deftest nelisp-ime-test-snapshot-reports-mode-cursor-and-composition ()
  (nelisp-ime-test--isolated
    (nelisp-ime-session-open "s")
    (let ((idle (nelisp-ime-feed "s" '(:op :cancel))))
      (should (equal (plist-get idle :mode) "hiragana"))
      (should (= (plist-get idle :cursor) 0))
      (should (= (plist-get idle :composition-start) -1)))
    (setq nelisp-ime-dictionary '(("かな" "仮名")))
    (let ((composing (nelisp-ime-feed "s" '(:op :insert :text "かな"))))
      (should (equal (plist-get composing :mode) "preedit"))
      (should (= (plist-get composing :cursor) 2))
      (should (= (plist-get composing :composition-start) 0)))))

(ert-deftest nelisp-ime-test-engine-mode-hook-wins ()
  (nelisp-ime-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines)))
      (nelisp-ime-engine-register
       'mode-test
       :convert #'nelisp-ime-dictionary-convert
       :mode (lambda (_session) 'katakana))
      (nelisp-ime-session-open "s" '(:engine mode-test))
      (should (equal (plist-get (nelisp-ime-feed "s" '(:op :insert :text "あ"))
                                :mode)
                     "katakana")))))

(ert-deftest nelisp-ime-test-candidate-annotation-survives-normalization ()
  (should (equal (plist-get (nelisp-ime--candidate-normalize
                             '(:surface "橋" :cost 10 :annotation "bridge") 0)
                            :annotation)
                 "bridge"))
  (should-not (plist-get (nelisp-ime--candidate-normalize "橋" 0) :annotation)))

;;; Fail-open, reset, status, maintenance

(ert-deftest nelisp-ime-test-feed-fails-open-on-engine-error ()
  (nelisp-ime-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines)))
      (nelisp-ime-engine-register
       'boom-test
       :feed (lambda (_id _session _event) (error "engine exploded")))
      (nelisp-ime-session-open "s" '(:engine boom-test))
      (let ((result (nelisp-ime-feed "s" '(:op :insert :text "あ"))))
        (should-not (plist-get result :consumed))
        (should (string-match-p "exploded" (plist-get result :error))))
      ;; The session must survive so the next keystroke still works.
      (should (nelisp-ime-session-status "s")))))

(ert-deftest nelisp-ime-test-fail-open-can-be-disabled ()
  (nelisp-ime-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines))
          (nelisp-ime-fail-open nil))
      (nelisp-ime-engine-register
       'boom-test
       :feed (lambda (_id _session _event) (error "engine exploded")))
      (nelisp-ime-session-open "s" '(:engine boom-test))
      (should-error (nelisp-ime-feed "s" '(:op :insert :text "あ"))
                    :type 'error))))

(ert-deftest nelisp-ime-test-status-does-not-change-state ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary '(("かな" "仮名")))
    (nelisp-ime-session-open "s")
    (nelisp-ime-feed "s" '(:op :insert :text "かな"))
    (let ((first (nelisp-ime-session-status "s"))
          (second (nelisp-ime-session-status "s")))
      (should (equal (plist-get first :reading) "かな"))
      (should (equal first second)))))

(ert-deftest nelisp-ime-test-reset-clears-composition-and-calls-engine ()
  (nelisp-ime-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines))
          (reset-called nil))
      (nelisp-ime-engine-register
       'reset-test
       :convert #'nelisp-ime-dictionary-convert
       :reset (lambda (_id _session) (setq reset-called t)))
      (nelisp-ime-session-open "s" '(:engine reset-test))
      (nelisp-ime-feed "s" '(:op :insert :text "かな"))
      (let ((result (nelisp-ime-session-reset "s")))
        (should reset-called)
        (should (equal (plist-get result :reading) ""))
        (should (= (plist-get result :composition-start) -1)))
      ;; The session keeps its engine, so the next feed still routes there.
      (should (eq (plist-get (nelisp-ime--session "s") :engine) 'reset-test)))))

(ert-deftest nelisp-ime-test-maintain-dispatches-and-tolerates-absence ()
  (nelisp-ime-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines))
          (seen nil))
      (nelisp-ime-engine-register
       'maintain-test
       :convert #'nelisp-ime-dictionary-convert
       :maintain (lambda (operation) (setq seen operation) 'done))
      (should (eq (nelisp-ime-maintain 'gc 'maintain-test) 'done))
      (should (eq seen 'gc))
      ;; An engine without the hook must not signal.
      (should-not (nelisp-ime-maintain 'gc 'dictionary)))))

;;; Journal-based learning

(ert-deftest nelisp-ime-test-learning-journal-defers-full-writes ()
  (nelisp-ime-test--isolated
    (let* ((directory (make-temp-file "nelisp-ime-journal-" t))
           (file (expand-file-name "learning.eldata" directory))
           (nelisp-ime-learning-journal-file nil))
      (unwind-protect
          (progn
            (nelisp-ime-learning-save file)
            (setq nelisp-ime-dictionary '(("はし" "橋" "箸")))
            (nelisp-ime-session-open "s")
            (nelisp-ime-feed "s" '(:op :insert :text "はし"))
            (nelisp-ime-feed "s" '(:op :commit))
            ;; The commit appended to the journal without rewriting the table.
            (should (file-readable-p (concat file ".journal")))
            (setq nelisp-ime-learning (make-hash-table :test 'equal))
            (nelisp-ime-learning-load file)
            (should (= (nelisp-ime-learning-count "はし" "橋") 1))
            ;; Compaction folds the journal in and removes it.
            (nelisp-ime-learning-compact file)
            (should-not (file-exists-p (concat file ".journal")))
            (setq nelisp-ime-learning (make-hash-table :test 'equal))
            (nelisp-ime-learning-load file)
            (should (= (nelisp-ime-learning-count "はし" "橋") 1)))
        (delete-directory directory t)))))

(ert-deftest nelisp-ime-test-learning-journal-skips-torn-line ()
  (nelisp-ime-test--isolated
    (let* ((directory (make-temp-file "nelisp-ime-torn-" t))
           (file (expand-file-name "learning.eldata" directory))
           (nelisp-ime-learning-journal-file nil))
      (unwind-protect
          (progn
            (nelisp-ime-learning-save file)
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region "(\"かな\" \"仮名\")\n(\"やぶ\" \"破" nil
                            (concat file ".journal") nil 'silent))
            (nelisp-ime-learning-load file)
            (should (= (nelisp-ime-learning-count "かな" "仮名") 1)))
        (delete-directory directory t)))))

(ert-deftest nelisp-ime-test-compact-snapshot-omits-lists ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸" "端")))
    (nelisp-ime-session-open "s" '(:detail compact))
    (let ((result (nelisp-ime-feed "s" '(:op :insert :text "はし"))))
      ;; The composition itself still renders: only the lists are dropped.
      (should (equal (plist-get result :preedit) "橋"))
      (should (equal (plist-get result :reading) "はし"))
      (should (equal (plist-get result :candidates) []))
      (should (equal (plist-get result :segments) [])))))

(ert-deftest nelisp-ime-test-compact-session-answers-selection-in-full ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸" "端")))
    (nelisp-ime-session-open "s" '(:detail compact))
    (nelisp-ime-feed "s" '(:op :insert :text "はし"))
    ;; Selecting needs the list being selected from, compact or not.
    (let ((result (nelisp-ime-feed "s" '(:op :select-candidate :index 1))))
      (should (equal (plist-get result :preedit) "箸"))
      (should (> (length (plist-get result :candidates)) 1)))))

(ert-deftest nelisp-ime-test-status-detail-overrides-session ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸")))
    (nelisp-ime-session-open "s" '(:detail compact))
    (nelisp-ime-feed "s" '(:op :insert :text "はし"))
    (should (equal (plist-get (nelisp-ime-session-status "s") :candidates) []))
    (should (> (length (plist-get (nelisp-ime-session-status "s" 'full)
                                  :candidates))
               0))
    ;; Asking for full must not make the session full from then on.
    (should (equal (plist-get (nelisp-ime-session-status "s") :candidates) []))))

(provide 'nelisp-ime-test)
;;; nelisp-ime-test.el ends here
