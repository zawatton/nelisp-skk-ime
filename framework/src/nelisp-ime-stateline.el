;;; nelisp-ime-stateline.el --- STATE line protocol for nelisp-ime  -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Speaks the line protocol that the nelisp-skk-ime Windows stack already
;; runs in production, so its C++ host and TSF text service can drive this
;; framework without modification.  That stack is the proven one -- pipe
;; multiplexing, fail-open when the engine is absent, resync after an IPC
;; timeout, idle-driven GC, and the dictionary held host-side -- so the
;; framework conforms to it rather than asking it to move.
;;
;; Requests are single lines:
;;
;;   HELLO 1                      -> OK 1
;;   KEY <decimal-codepoint>      -> STATE ...
;;   CONTROL BACKSPACE|CONVERT|PREVIOUS|COMMIT|CANCEL|QUIT
;;                                -> STATE ...
;;   RESET                        -> STATE ...
;;   STATUS                       -> STATE ...        (no side effects)
;;   GC                           -> OK GC
;;   COMPACT                      -> OK COMPACT [NOOP]
;;   ENGINE LIST                  -> ENGINES <name>...
;;   ENGINE CURRENT               -> ENGINE <name>
;;   ENGINE SET <name>            -> OK ENGINE <name>
;;   QUIT                         -> OK BYE
;;
;; A STATE line has eight space-separated fields:
;;
;;   STATE <mode> <cursor> <composition-start> <hex-text> <hex-pending>
;;         <candidate-index> <hex-candidates-comma-separated>
;;
;; Strings are fixed-width 6-digit lowercase scalar hex; an empty string is
;; "-".  Numeric fields are decimal, with -1 standing for "absent".  The
;; encoding is deliberately identical to nelisp-skk-ime's, including the
;; costs: hex is per-character work and per-character work is expensive on
;; this runtime.  Both sides intend to replace hex with length-prefixed
;; UTF-8; that has to happen on both sides at once, so it is not done here.
;;
;; Errors degrade to an `ERR <TOKEN>' line rather than propagating, matching
;; the fail-open contract the adapter relies on.

;;; Code:

(require 'nelisp-ime)

(defconst nelisp-ime-stateline-version 1
  "Protocol version answered to HELLO.")

(defvar nelisp-ime-stateline--session-id "stateline"
  "Session the line protocol drives.

The wire format carries no session id: the host serializes every request
onto one engine, so this protocol owns exactly one session.")

(defconst nelisp-ime-stateline--hex-digits "0123456789abcdef"
  "Lowercase nibble table for `nelisp-ime-stateline--hex'.")

(defun nelisp-ime-stateline--hex (string)
  "Return STRING as fixed-width 6-digit lowercase scalar hex, or \"-\".

Written as one preallocated string with `aset' rather than per-character
`format' or repeated `concat': an interpreted element operation costs
~140us on the standalone runtime, and `format' alone costs ~23ms per
call, so the shape of this loop is most of the per-key budget."
  (let ((count (length (or string ""))))
    (if (= count 0)
        "-"
      (let ((out (make-string (* count 6) ?0))
            (index 0)
            (offset 0))
        (while (< index count)
          ;; `make-string' pre-filled every position with ?0, so only the
          ;; significant nibbles need writing.  Characters an IME handles are
          ;; almost always in the BMP, where the top two digits stay "00".
          (let ((code (aref string index)))
            (if (< code 65536)
                (let ((digit 5))
                  (while (>= digit 2)
                    (aset out (+ offset digit)
                          (aref nelisp-ime-stateline--hex-digits
                                (logand code 15)))
                    (setq code (ash code -4))
                    (setq digit (1- digit))))
              (let ((digit 5))
                (while (>= digit 0)
                  (aset out (+ offset digit)
                        (aref nelisp-ime-stateline--hex-digits
                              (logand code 15)))
                  (setq code (ash code -4))
                  (setq digit (1- digit))))))
          (setq index (1+ index))
          (setq offset (+ offset 6)))
        out))))

(defun nelisp-ime-stateline--candidates (snapshot)
  "Return SNAPSHOT's candidates as one comma-separated hex field."
  (let ((candidates (plist-get snapshot :candidates)))
    (if (or (null candidates) (= (length candidates) 0))
        "-"
      (let ((parts nil)
            (index (1- (length candidates))))
        (while (>= index 0)
          (push (nelisp-ime-stateline--hex (aref candidates index)) parts)
          (setq index (1- index)))
        (mapconcat #'identity parts ",")))))

(defun nelisp-ime-stateline--line (snapshot)
  "Return the wire STATE line for SNAPSHOT.

The text field carries the committed text when there is one, and the
live preedit otherwise.  The wire has one text field and the host writes
it over the composition before closing it, so a commit that sent the
now-empty preedit would erase the composition instead of settling it.

Assembled with `concat' rather than one `format': the seven directives a
`format' would need cost ~23ms per call on this runtime, against ~136us
per `concat' argument."
  (concat "STATE "
          (or (plist-get snapshot :mode) "hiragana") " "
          (number-to-string (or (plist-get snapshot :cursor) 0)) " "
          (number-to-string (or (plist-get snapshot :composition-start) -1)) " "
          (nelisp-ime-stateline--hex (or (plist-get snapshot :commit)
                                         (plist-get snapshot :preedit))) " "
          (nelisp-ime-stateline--hex (plist-get snapshot :pending)) " "
          (number-to-string (or (plist-get snapshot :candidate-index) -1)) " "
          (nelisp-ime-stateline--candidates snapshot)))

(defun nelisp-ime-stateline--session ()
  "Return the protocol's session, opening it when absent."
  (or (gethash nelisp-ime-stateline--session-id nelisp-ime-sessions)
      (progn
        (nelisp-ime-session-open nelisp-ime-stateline--session-id
                                 '(:input-style romaji))
        (gethash nelisp-ime-stateline--session-id nelisp-ime-sessions))))

(defun nelisp-ime-stateline--feed (event)
  "Apply EVENT to the protocol session and return its STATE line."
  (nelisp-ime-stateline--session)
  (nelisp-ime-stateline--line
   (nelisp-ime-feed nelisp-ime-stateline--session-id event)))

(defun nelisp-ime-stateline--decimal-p (string)
  "Return non-nil when STRING is a non-empty run of ASCII digits."
  (let ((index 0)
        (count (length string))
        (ok (> (length string) 0)))
    (while (and ok (< index count))
      (let ((char (aref string index)))
        (unless (and (>= char ?0) (<= char ?9)) (setq ok nil)))
      (setq index (1+ index)))
    ok))

(defun nelisp-ime-stateline--convert-keys (encoded)
  "Reset, replay comma-separated decimal codepoints, and convert atomically."
  (let ((start 0)
        (count (length encoded))
        (valid (> (length encoded) 0))
        (events nil))
    (while (and valid (< start count))
      (let* ((separator (string-match "," encoded start))
             (end (or separator count))
             (part (substring encoded start end)))
        (if (not (nelisp-ime-stateline--decimal-p part))
            (setq valid nil)
          (let ((code (string-to-number part)))
            (if (or (< code 1) (> code #x10ffff)
                    (and (>= code #xd800) (<= code #xdfff)))
                (setq valid nil)
              (setq events (cons (list :op :key :key (char-to-string code))
                                 events)))))
        (setq start (if separator (1+ separator) count))))
    (if (not valid)
        "ERR CONVERT-KEYS"
      (nelisp-ime-stateline--session)
      (nelisp-ime-session-reset nelisp-ime-stateline--session-id)
      (dolist (event (nreverse events))
        (nelisp-ime-feed nelisp-ime-stateline--session-id event))
      (nelisp-ime-stateline--feed '(:op :convert)))))

(defun nelisp-ime-stateline--control (name)
  "Return the event plist for CONTROL NAME, or nil when unsupported."
  (cond
   ((equal name "BACKSPACE") '(:op :backspace))
   ((equal name "COMMIT") '(:op :commit))
   ;; CONVERT starts the conversion, then steps through the candidate list
   ;; on every press after that -- the space key of any Japanese IME.  Which
   ;; of the two it means is decided against the live session in
   ;; `nelisp-ime-stateline--dispatch-control'.  PREVIOUS only ever steps.
   ;; A modal engine maps both onto its own conversion state through its
   ;; :feed hook.
   ((equal name "CONVERT") '(:op :select-candidate :index :next))
   ((equal name "PREVIOUS") '(:op :select-candidate :index :previous))
   ((equal name "SEGMENT-PREV") '(:op :select-segment :index :previous))
   ((equal name "SEGMENT-NEXT") '(:op :select-segment :index :next))
   ((equal name "SEGMENT-SHRINK") '(:op :resize-segment :direction :shrink))
   ((equal name "SEGMENT-EXTEND") '(:op :resize-segment :direction :extend))
   ((equal name "TO-HIRAGANA") '(:op :transliterate :target :hiragana))
   ((equal name "TO-KATAKANA") '(:op :transliterate :target :katakana))
   ((equal name "TO-HALF-KATAKANA") '(:op :transliterate :target :half-katakana))
   ((equal name "TO-WIDE-LATIN") '(:op :transliterate :target :wide-latin))
   ((equal name "TO-LATIN") '(:op :transliterate :target :latin))
   ;; CANCEL is the unconditional return to plain input; QUIT is the
   ;; stepwise escape the DLL has always sent for Escape and Ctrl+G
   ;; (`EngineControl::kQuit', chosen over kCancel for exactly this
   ;; reason).  They used to collapse onto the same cancel, so one press
   ;; discarded everything -- reported as Ctrl+G eating the input.
   ((equal name "CANCEL") '(:op :cancel))
   ((equal name "QUIT") '(:op :revert))
   (t nil)))

(defun nelisp-ime-stateline--relative-candidate (session step)
  "Return the candidate index STEP positions from SESSION's current one."
  (let* ((candidates (or (plist-get session :candidates) nil))
         (count (length candidates)))
    (if (= count 0)
        nil
      (mod (+ (or (plist-get session :candidate-index) 0) step) count))))

(defun nelisp-ime-stateline--dispatch-control (name)
  "Handle CONTROL NAME and return its response line."
  (let ((event (nelisp-ime-stateline--control name)))
    (cond
     ((null event) (concat "ERR " name))
     ((memq (plist-get event :index) '(:next :previous))
      (let ((session (nelisp-ime-stateline--session)))
        (cond
         ;; First CONVERT on a composition that has only been typed: the
         ;; user is asking for the conversion itself, not for the next
         ;; candidate of one that does not exist yet.
         ((and (eq (plist-get event :op) :select-candidate)
               (eq (plist-get event :index) :next)
               (not (plist-get session :converted))
               (> (length (or (plist-get session :reading) "")) 0))
          (nelisp-ime-stateline--feed '(:op :convert)))
         ((memq (plist-get event :op) '(:select-segment))
          (let* ((count (length (or (plist-get session :segments) nil)))
                 (current (or (plist-get session :active-segment) 0))
                 (index (max 0 (min (1- count)
                                    (+ current (if (eq (plist-get event :index) :next) 1 -1))))))
            (if (= count 0)
                (nelisp-ime-stateline--line
                 (nelisp-ime-session-status nelisp-ime-stateline--session-id))
              (nelisp-ime-stateline--feed
               (list :op :select-segment :index index)))))
         (t
          ;; Resolve the relative move against the live session; with no
          ;; candidates there is nothing to step through, so report state.
          (let ((index (nelisp-ime-stateline--relative-candidate
                        session
                        (if (eq (plist-get event :index) :next) 1 -1))))
            (if (null index)
                (nelisp-ime-stateline--line
                 (nelisp-ime-session-status nelisp-ime-stateline--session-id))
              (nelisp-ime-stateline--feed
               (list :op :select-candidate :index index))))))))
     (t (nelisp-ime-stateline--feed event)))))

;;;###autoload
(defun nelisp-ime-stateline--dispatch-1 (line)
  "Handle one protocol LINE and return the response line.

Every failure degrades to an `ERR <TOKEN>' line: the adapter treats a
malformed answer as \"engine unavailable\" and passes the key through to
the application, which is preferable to leaving the user unable to type."
  (condition-case _err
      (cond
       ((equal line "HELLO 1")
        (concat "OK " (number-to-string nelisp-ime-stateline-version)))
       ((equal line "ENGINE LIST")
        (concat "ENGINES "
                (mapconcat #'symbol-name (nelisp-ime-engine-names) " ")))
       ((equal line "ENGINE CURRENT")
        (concat "ENGINE " (symbol-name nelisp-ime-default-engine)))
       ((and (> (length line) 11) (equal (substring line 0 11) "ENGINE SET "))
        (let ((name (intern (substring line 11))))
          (if (nelisp-ime-engine-get name)
              (progn
                     ;; The wire has one implicit session.  An engine switch
                     ;; is therefore also a session boundary; retaining the
                     ;; old reading/candidates would leak provider state.
                     (remhash nelisp-ime-stateline--session-id
                              nelisp-ime-sessions)
                     (setq nelisp-ime-default-engine name)
                     (concat "OK ENGINE " (symbol-name name)))
            (concat "ERR ENGINE " (symbol-name name)))))
       ((equal line "RESET")
        (nelisp-ime-stateline--session)
        (nelisp-ime-stateline--line
         (nelisp-ime-session-reset nelisp-ime-stateline--session-id)))
       ((equal line "STATUS")
        (nelisp-ime-stateline--session)
        (nelisp-ime-stateline--line
         (nelisp-ime-session-status nelisp-ime-stateline--session-id)))
       ((equal line "GC")
        (nelisp-ime-maintain 'gc)
        "OK GC")
       ((equal line "COMPACT")
        (if (nelisp-ime-maintain 'compact) "OK COMPACT" "OK COMPACT NOOP"))
       ((equal line "QUIT") "OK BYE")
       ((and (> (length line) 21)
             (equal (substring line 0 21) "CONTROL CONVERT-KEYS "))
        (nelisp-ime-stateline--convert-keys (substring line 21)))
       ((and (> (length line) 8) (equal (substring line 0 8) "CONTROL "))
        (nelisp-ime-stateline--dispatch-control (substring line 8)))
       ((and (> (length line) 4) (equal (substring line 0 4) "KEY "))
        (let ((argument (substring line 4)))
          (if (not (nelisp-ime-stateline--decimal-p argument))
              "ERR CODEPOINT"
            (let ((code (string-to-number argument)))
              (if (or (< code 1) (> code #x10FFFF))
                  "ERR CODEPOINT"
                (nelisp-ime-stateline--feed
                 (list :op :key :key (char-to-string code))))))))
       (t "ERR REQUEST"))
    (error "ERR INTERNAL")))

(defun nelisp-ime-stateline--session-id-valid-p (session-id)
  "Return non-nil for a bounded wire-safe SESSION-ID."
  (let ((index 0)
        (count (length session-id))
        (valid (and (> (length session-id) 0)
                    (<= (length session-id) 96))))
    (while (and valid (< index count))
      (let ((char (aref session-id index)))
        (unless (or (and (>= char ?a) (<= char ?z))
                    (and (>= char ?A) (<= char ?Z))
                    (and (>= char ?0) (<= char ?9))
                    (memq char '(?- ?_ ?. ?:)))
          (setq valid nil)))
      (setq index (1+ index)))
    valid))

;;;###autoload
(defun nelisp-ime-stateline-dispatch (line)
  "Dispatch legacy LINE or a client-scoped `SESSION ID LINE' request."
  (if (and (> (length line) 8)
           (equal (substring line 0 8) "SESSION "))
      (let ((separator (string-match " " line 8)))
        (if (not separator)
            "ERR SESSION"
          (let ((session-id (substring line 8 separator))
                (request (substring line (1+ separator))))
            (if (or (not (nelisp-ime-stateline--session-id-valid-p session-id))
                    (= (length request) 0))
                "ERR SESSION"
              (if (equal request "CLOSE")
                  (progn
                    (nelisp-ime-session-close session-id)
                    "OK CLOSED")
                (let ((nelisp-ime-stateline--session-id session-id))
                  (nelisp-ime-stateline--dispatch-1 request)))))))
    (nelisp-ime-stateline--dispatch-1 line)))

(provide 'nelisp-ime-stateline)
;;; nelisp-ime-stateline.el ends here
