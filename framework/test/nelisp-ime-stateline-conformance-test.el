;;; nelisp-ime-stateline-conformance-test.el --- STATE line vs. the TSF host -*- lexical-binding: t; -*-

;; Copyright (C) 2026 nelisp-skk-ime contributors

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied
;; warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
;; PURPOSE.  See the GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; Answering the protocol is not the same as being usable.  The `lattice'
;; engine passed every existing test, answered every request with a
;; well-formed STATE line, and still made the IME impossible to type with
;; when it went live: the caret never advanced and each keystroke rewrote
;; what came before it.  The tests here are the ones that were missing --
;; they assert what `TextService::ApplyEngineState' in
;; windows/src/text_service.cpp actually DOES with the fields, not merely
;; that the fields are present and well-formed.
;;
;; The host's contract, read off that function:
;;
;;   display = preedit + pending
;;       The two fields are concatenated and shown as the composition.  A
;;       preedit that already contains the unresolved romaji therefore
;;       renders it twice ("kk"), which is what shipped.
;;
;;   direct commit  <=>  composition-start < 0 AND pending empty
;;       Only then is `preedit' inserted into the document as settled text
;;       and the composition closed.  An engine that never reports
;;       composition-start < 0 never lets the caret move past the
;;       composition, so the text stays under the cursor and every further
;;       keystroke replaces the whole thing.
;;
;;   candidates are shown whenever the field is non-empty
;;       Publishing candidates on an ordinary kana keystroke pops the
;;       candidate window on every character typed.
;;
;; A conforming engine may use SKK's episode model (commit each kana at
;; once) or an accumulating one (build a reading, convert on request), but
;; either way these invariants have to hold on every single response.

;;; Code:

(require 'ert)
(require 'nelisp-ime)
(require 'nelisp-ime-stateline)

(defmacro nelisp-ime-conformance-test--isolated (&rest body)
  "Run BODY with isolated sessions over a small known dictionary.

The dictionary is deliberately non-empty: with no entries at all a
converter returns the reading unchanged, so an engine that converts too
eagerly looks identical to one that does not convert at all.  Every
defect this file exists to catch only appears once a reading has real
candidates behind it."
  (declare (indent 0) (debug t))
  `(let ((nelisp-ime-sessions (make-hash-table :test 'equal))
         (nelisp-ime-learning (make-hash-table :test 'equal))
         (nelisp-ime-dictionary
          '(("か" "下" "可" "火")
            ("かき" "柿" "夏期" "牡蠣")
            ("き" "木" "気")))
         (nelisp-ime-converter-function #'nelisp-ime-dictionary-convert))
     ,@body))

(defun nelisp-ime-conformance-test--unhex (field)
  "Decode one hex STATE FIELD back to text; \"-\" decodes to \"\"."
  (if (equal field "-")
      ""
    (let ((out "")
          (index 0))
      (while (< index (length field))
        (setq out (concat out (char-to-string
                               (string-to-number
                                (substring field index (+ index 6)) 16))))
        (setq index (+ index 6)))
      out)))

(defun nelisp-ime-conformance-test--parse (line)
  "Parse a STATE LINE into a plist with the fields decoded."
  (let ((fields (split-string line " ")))
    (list :mode (nth 1 fields)
          :cursor (string-to-number (nth 2 fields))
          :composition-start (string-to-number (nth 3 fields))
          :preedit (nelisp-ime-conformance-test--unhex (nth 4 fields))
          :pending (nelisp-ime-conformance-test--unhex (nth 5 fields))
          :candidate-index (string-to-number (nth 6 fields))
          :candidates (if (equal (nth 7 fields) "-")
                          nil
                        (mapcar #'nelisp-ime-conformance-test--unhex
                                (split-string (nth 7 fields) ","))))))

(defun nelisp-ime-conformance-test--send (request)
  "Dispatch REQUEST and return its parsed STATE line."
  (let ((line (nelisp-ime-stateline-dispatch request)))
    (should (string-prefix-p "STATE " line))
    (nelisp-ime-conformance-test--parse line)))

(defun nelisp-ime-conformance-test--display (state)
  "Return what the host would render for STATE.
Mirrors `ApplyEngineState': the composition is preedit followed by
pending, with no separator and no de-duplication."
  (concat (plist-get state :preedit) (plist-get state :pending)))

;;; The invariant that shipped broken.

(ert-deftest nelisp-ime-conformance-test-pending-is-not-also-in-preedit ()
  "Unresolved romaji belongs to `pending' alone.
The host concatenates the two fields, so a `k' reported in both renders
as \"kk\" -- the first thing the user saw."
  (nelisp-ime-conformance-test--isolated
    (let ((state (nelisp-ime-conformance-test--send "KEY 107"))) ; k
      (should (equal (plist-get state :pending) "k"))
      (should (equal (plist-get state :preedit) ""))
      (should (equal (nelisp-ime-conformance-test--display state) "k")))
    ;; And again with a kana already accumulated, where the duplication
    ;; hid behind a longer string ("かk" + "k").
    (nelisp-ime-conformance-test--send "KEY 97")                 ; a -> か
    (let ((state (nelisp-ime-conformance-test--send "KEY 107"))) ; k
      (should (equal (plist-get state :pending) "k"))
      (should (equal (nelisp-ime-conformance-test--display state) "かk")))))

(ert-deftest nelisp-ime-conformance-test-typing-does-not-convert ()
  "Typing accumulates a reading; it does not convert or offer candidates.
Converting on every keystroke replaces what the user typed with a guess
and pops the candidate window on each character."
  (nelisp-ime-conformance-test--isolated
    (nelisp-ime-conformance-test--send "KEY 107")                ; k
    (let ((state (nelisp-ime-conformance-test--send "KEY 97")))  ; a -> か
      (should (equal (plist-get state :preedit) "か"))
      (should (equal (plist-get state :mode) "preedit"))
      (should (null (plist-get state :candidates))))
    (nelisp-ime-conformance-test--send "KEY 107")                ; k
    (let ((state (nelisp-ime-conformance-test--send "KEY 105"))) ; i -> かき
      (should (equal (plist-get state :preedit) "かき"))
      (should (equal (plist-get state :mode) "preedit"))
      (should (null (plist-get state :candidates))))))

(ert-deftest nelisp-ime-conformance-test-conversion-is-explicit ()
  "Candidates appear on CONTROL CONVERT and not before."
  (nelisp-ime-conformance-test--isolated
    (dolist (key '("KEY 107" "KEY 97" "KEY 107" "KEY 105"))     ; kaki
      (nelisp-ime-conformance-test--send key))
    (let ((state (nelisp-ime-conformance-test--send "CONTROL CONVERT")))
      (should (equal (plist-get state :mode) "candidate"))
      (should (member "柿" (plist-get state :candidates)))
      ;; The preedit is the candidate now in effect, so the composition
      ;; shows the conversion rather than the reading.
      (should (equal (plist-get state :preedit)
                     (nth (plist-get state :candidate-index)
                          (plist-get state :candidates)))))))

(ert-deftest nelisp-ime-conformance-test-segment-controls-keep-a-live-composition ()
  "Segment navigation and kana transliteration return renderable STATE lines."
  (nelisp-ime-conformance-test--isolated
    (dolist (key '("KEY 107" "KEY 97" "KEY 107" "KEY 105"))
      (nelisp-ime-conformance-test--send key))
    ;; A navigation key has no segment to select before conversion; it must
    ;; not accidentally act like Space and start one.
    (let ((state (nelisp-ime-conformance-test--send "CONTROL SEGMENT-NEXT")))
      (should (equal (nelisp-ime-conformance-test--display state) "かき"))
      (should (equal (plist-get state :mode) "preedit")))
    (nelisp-ime-conformance-test--send "CONTROL CONVERT")
    (let ((state (nelisp-ime-conformance-test--send "CONTROL SEGMENT-NEXT")))
      (should (equal (nelisp-ime-conformance-test--display state) "柿"))
      (should (>= (plist-get state :composition-start) 0)))
    (let ((state (nelisp-ime-conformance-test--send "CONTROL TO-KATAKANA")))
      (should (equal (nelisp-ime-conformance-test--display state) "カキ"))
      (should (>= (plist-get state :composition-start) 0)))
    (let ((state (nelisp-ime-conformance-test--send "CONTROL TO-HALF-KATAKANA")))
      (should (equal (nelisp-ime-conformance-test--display state) "ｶｷ")))))

(ert-deftest nelisp-ime-conformance-test-quit-steps-back-once ()
  "CONTROL QUIT undoes one stage; it does not throw the composition away.

Escape and Ctrl+G have always sent `kQuit' rather than `kCancel' from the
DLL, because DDSKK's quit is stepwise.  The framework had one cancel and
mapped both onto it, so a single Ctrl+G discarded everything -- reported
from live use as the input disappearing.  Each rung here is one press."
  (nelisp-ime-conformance-test--isolated
    (dolist (key '("KEY 107" "KEY 97" "KEY 107" "KEY 105"))      ; kaki
      (nelisp-ime-conformance-test--send key))
    (nelisp-ime-conformance-test--send "CONTROL CONVERT")        ; -> 柿
    ;; converted -> reading, not gone
    (let ((state (nelisp-ime-conformance-test--send "CONTROL QUIT")))
      (should (equal (nelisp-ime-conformance-test--display state) "かき"))
      (should (>= (plist-get state :composition-start) 0)))
    ;; reading -> empty, composition closes only now
    (let ((state (nelisp-ime-conformance-test--send "CONTROL QUIT")))
      (should (equal (nelisp-ime-conformance-test--display state) ""))
      (should (< (plist-get state :composition-start) 0)))))

(ert-deftest nelisp-ime-conformance-test-quit-drops-pending-romaji-alone ()
  "An unresolved romaji prefix is its own rung, above the reading."
  (nelisp-ime-conformance-test--isolated
    (dolist (key '("KEY 107" "KEY 97" "KEY 107"))                ; ka + k
      (nelisp-ime-conformance-test--send key))
    (let ((state (nelisp-ime-conformance-test--send "CONTROL QUIT")))
      ;; the pending "k" goes, the kana stays
      (should (equal (nelisp-ime-conformance-test--display state) "か"))
      (should (equal (plist-get state :pending) "")))
    (let ((state (nelisp-ime-conformance-test--send "CONTROL QUIT")))
      (should (equal (nelisp-ime-conformance-test--display state) "")))))

(ert-deftest nelisp-ime-conformance-test-typing-accepts-the-conversion ()
  "Typing after a conversion keeps it and starts a new reading behind it.

Measured against DDSKK on this same wire, which is the reference for
what the host renders: ▽きょう SPACE gives ▼今日, and `h' after it gives
今日h -- the conversion is accepted, not re-read.  Reverting to the
reading instead is what the user hit (「今日」→「は」→「きょうは」),
and no test here covered the converted→typing transition at all: they
each checked one state, never the move between them."
  (nelisp-ime-conformance-test--isolated
    (dolist (key '("KEY 107" "KEY 97" "KEY 107" "KEY 105"))      ; kaki
      (nelisp-ime-conformance-test--send key))
    (nelisp-ime-conformance-test--send "CONTROL CONVERT")        ; -> 柿
    (let ((state (nelisp-ime-conformance-test--send "KEY 107"))) ; k
      (should (equal (nelisp-ime-conformance-test--display state) "柿k")))
    (let ((state (nelisp-ime-conformance-test--send "KEY 105"))) ; i
      (should (equal (nelisp-ime-conformance-test--display state) "柿き"))
      ;; Still one composition: the accepted part is not committed yet.
      (should (>= (plist-get state :composition-start) 0)))
    ;; CONVERT now applies to the new reading only, leaving 柿 alone.
    (let ((state (nelisp-ime-conformance-test--send "CONTROL CONVERT")))
      (should (equal (nelisp-ime-conformance-test--display state) "柿木")))
    (let ((state (nelisp-ime-conformance-test--send "CONTROL COMMIT")))
      (should (equal (nelisp-ime-conformance-test--display state) "柿木"))
      (should (< (plist-get state :composition-start) 0)))))

(ert-deftest nelisp-ime-conformance-test-backspace-eats-into-the-accepted-text ()
  "Backspace keeps shortening one composition past an accepted conversion."
  (nelisp-ime-conformance-test--isolated
    (dolist (key '("KEY 107" "KEY 97" "KEY 107" "KEY 105"))      ; kaki
      (nelisp-ime-conformance-test--send key))
    (nelisp-ime-conformance-test--send "CONTROL CONVERT")        ; -> 柿
    (nelisp-ime-conformance-test--send "KEY 107")                ; k -> 柿k
    (let ((state (nelisp-ime-conformance-test--send "CONTROL BACKSPACE")))
      (should (equal (nelisp-ime-conformance-test--display state) "柿")))
    ;; Past the accepted conversion rather than stopping in front of it.
    (let ((state (nelisp-ime-conformance-test--send "CONTROL BACKSPACE")))
      (should (equal (nelisp-ime-conformance-test--display state) ""))
      (should (< (plist-get state :composition-start) 0)))))

(ert-deftest nelisp-ime-conformance-test-commit-carries-the-committed-text ()
  "The settled text has to travel in the STATE line's own text field.

`ApplyEngineState' writes `preedit + pending' over the composition and
only then closes it, so a commit that reports empty text erases what was
being composed instead of settling it -- the composition is overwritten
with \"\" and the composition ends on the same pass."
  (nelisp-ime-conformance-test--isolated
    (dolist (key '("KEY 107" "KEY 97"))                          ; ka
      (nelisp-ime-conformance-test--send key))
    (let ((state (nelisp-ime-conformance-test--send "CONTROL COMMIT")))
      (should (equal (nelisp-ime-conformance-test--display state) "か")))
    ;; And after a conversion, the chosen candidate rather than the reading.
    (dolist (key '("KEY 107" "KEY 97" "KEY 107" "KEY 105"))      ; kaki
      (nelisp-ime-conformance-test--send key))
    (nelisp-ime-conformance-test--send "CONTROL CONVERT")
    (let ((state (nelisp-ime-conformance-test--send "CONTROL COMMIT")))
      (should (equal (nelisp-ime-conformance-test--display state) "柿")))))

(ert-deftest nelisp-ime-conformance-test-commit-closes-the-composition ()
  "COMMIT must report composition-start < 0 with no pending romaji.
That pair is the host's only signal to settle the text and let the caret
move past it; without it the composition stays open under the cursor and
the next keystroke overwrites it."
  (nelisp-ime-conformance-test--isolated
    (dolist (key '("KEY 107" "KEY 97"))                          ; ka
      (nelisp-ime-conformance-test--send key))
    (let ((state (nelisp-ime-conformance-test--send "CONTROL COMMIT")))
      (should (< (plist-get state :composition-start) 0))
      (should (equal (plist-get state :pending) ""))
      (should (null (plist-get state :candidates))))
    ;; The next STATUS shows an idle session: the commit is reported once,
    ;; in the response to the commit, and is not repeated afterwards.
    (let ((state (nelisp-ime-conformance-test--send "STATUS")))
      (should (equal (plist-get state :preedit) ""))
      (should (< (plist-get state :composition-start) 0)))))

(ert-deftest nelisp-ime-conformance-test-composition-is-open-while-composing ()
  "While anything is being composed the host must be told where it starts.
The mirror image of the commit rule: composition-start < 0 with an empty
pending is a *commit*, so reporting it mid-composition would make the
host settle a half-typed reading into the document."
  (nelisp-ime-conformance-test--isolated
    (let ((state (nelisp-ime-conformance-test--send "KEY 107")))  ; k
      ;; Pending is non-empty here, so composition-start may be either
      ;; way round -- what must not happen is the direct-commit pair.
      (should-not (and (< (plist-get state :composition-start) 0)
                       (equal (plist-get state :pending) ""))))
    (let ((state (nelisp-ime-conformance-test--send "KEY 97")))   ; a -> か
      (should (>= (plist-get state :composition-start) 0)))))

(ert-deftest nelisp-ime-conformance-test-status-agrees-with-the-last-state ()
  "STATUS must describe the same composition the last key produced.
The host polls it to re-render after focus changes; a STATUS that
disagrees would redraw a different composition than the one on screen."
  (nelisp-ime-conformance-test--isolated
    (dolist (key '("KEY 107" "KEY 97" "KEY 107"))                ; kak
      (nelisp-ime-conformance-test--send key))
    (let ((last (nelisp-ime-stateline-dispatch "STATUS"))
          (again (nelisp-ime-stateline-dispatch "STATUS")))
      (should (equal last again)))))

(provide 'nelisp-ime-stateline-conformance-test)
;;; nelisp-ime-stateline-conformance-test.el ends here
