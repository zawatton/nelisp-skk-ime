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

(defconst nelisp-ime-stateline--session-id "stateline"
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
   ;; CANCEL is the unconditional return to plain input; QUIT is the
   ;; stepwise escape.  The framework has one cancel, so both discard the
   ;; composition and QUIT additionally leaves the session ready for input.
   ((equal name "CANCEL") '(:op :cancel))
   ((equal name "QUIT") '(:op :cancel))
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
         ((and (eq (plist-get event :index) :next)
               (not (plist-get session :converted))
               (> (length (or (plist-get session :reading) "")) 0))
          (nelisp-ime-stateline--feed '(:op :convert)))
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
(defun nelisp-ime-stateline-dispatch (line)
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
              (progn (setq nelisp-ime-default-engine name)
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

(provide 'nelisp-ime-stateline)
;;; nelisp-ime-stateline.el ends here
