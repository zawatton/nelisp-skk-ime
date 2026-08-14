;;; ddskk-engine.el --- Persistent DDSKK native engine -*- lexical-binding: t; -*-

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

(load "../nelisp/src/nelisp-buffer.el")
(load "engine/skk-nelisp-compat.el")
(provide 'skk)
(load "vendor/ddskk/skk-vars.el")
(load "vendor/ddskk/skk-macs.el")
(load "vendor/ddskk/skk-emacs.el")

;; `skk-macs.el' defines this via `encode-coding-string' inside
;; `ignore-errors', which signals on this runtime and therefore silently
;; yields nil for every character.  `skk.el' builds all four minor-mode
;; keymaps at load time using this function, so the broken version would
;; bind every key to nil and make `lookup-key' useless.  Override it here,
;; after `skk-macs.el' has been loaded but before `skk.el' runs.
(defun skk-char-to-unibyte-string (char) (string char))

(load "vendor/ddskk/skk.el")

;; `skk-use-face' (skk-vars.el:1982) defaults to
;; `(or window-system (fboundp 'selected-frame) (fboundp 'frame-face-alist))'.
;; This engine has no display of its own -- all visual treatment of the
;; preedit/candidate text is done by the Windows TSF DLL's
;; `ITfDisplayAttributeProvider' (windows/src/display_attribute.cpp),
;; driven by the `mode' field of the STATE line, never by anything DDSKK
;; draws into its own buffer -- so this decoration is both unusable and
;; unnecessary here, and forcing it off is what actually stops `CONTROL
;; CONVERT' from crashing:
;;
;; Every CONVERT that finds a candidate runs
;; `skk-henkan' -> `skk-henkan-1' -> `skk-insert-new-word' (skk.el:2539),
;; which at skk.el:2565-2566 does `(when skk-use-face (skk-henkan-face-on
;; face))' -- gated on this variable and nothing else -- and
;; `skk-henkan-face-on' (skk.el:4882) calls `skk-face-on' (skk-macs.el:161),
;; whose macro body runs `(setq OBJECT (make-overlay START END))' the first
;; time OBJECT (`skk-henkan-overlay') is not already an overlay, which it
;; never is here because `make-overlay' is not defined anywhere in
;; `skk-nelisp-compat.el'. That is exactly the reported
;; "CONTROL CONVERT -> ERR CONVERT void-function make-overlay".
;;
;; A prior trace claimed `skk-use-face' already evaluates to nil here
;; because `window-system' is stubbed nil in `skk-nelisp-compat.el'. That
;; stub is a `defun', but `skk-use-face's default form above references
;; the bare symbol `window-system' -- a variable read, not a function
;; call -- so the function stub never applies to it, and this runtime
;; never binds a `window-system' variable either (`skk-nelisp-compat.el'
;; and every file under dev/nelisp were grepped for it: no hits). The
;; CONVERT crash itself is the actual proof the claim was wrong: if
;; `skk-use-face' were nil, this call site could never reach
;; `make-overlay' at all, since the `(when skk-use-face ...)' guard
;; would short-circuit first.
;;
;; This engine's other decoration gates -- `skk-show-inline',
;; `skk-show-annotation', `skk-dcomp-activate', `skk-show-tooltip', and
;; `skk-show-candidates-always-pop-to-buffer' -- all default to a literal
;; nil in skk-vars.el (unlike `skk-use-face', theirs is not a computed
;; default) and are left untouched by
;; `skk-ime-session--initialize-native-buffer', so none of their
;; overlay/propertize/tooltip code is reachable from CONVERT or COMMIT
;; today; `skk-use-face' is the only gate that needs forcing off.
;;
;; `skk-use-face' is a plain global defcustom -- grepping this tree finds
;; no `make-variable-buffer-local' or `setq-local' on it anywhere -- so it
;; is set once here at top level, not inside the per-buffer setq in
;; `skk-ime-session--initialize-native-buffer' (which holds only the
;; variables DDSKK treats as buffer-local, like `skk-mode'/`skk-j-mode').
(setq skk-use-face nil)

;; `skk-henkan' (skk.el:1698) falls back to `skk-henkan-in-minibuff'
;; (skk.el:2266) whenever the search finds zero candidates for the current
;; reading, both on the very first SPC and when a later SPC exhausts the
;; remaining candidates.  The stock implementation opens an interactive
;; jisyo-registration prompt with `read-from-minibuffer' (skk.el:2292),
;; which this out-of-process engine has no minibuffer to service; that
;; primitive is not stubbed anywhere in `skk-nelisp-compat.el', so today
;; this would signal `void-function' and only be rescued by the
;; `condition-case' wrappers further down in this file, degrading the
;; keystroke to an ERR response.
;;
;; No DDSKK variable gates entry into `skk-henkan-in-minibuff' from
;; `skk-henkan' -- the only other reference to the function outside skk.el
;; is an `advice-add' notification in skk-jisyo-edit-mode.el, which this
;; engine never loads.  Redefining the function is therefore the least
;; invasive option.
;;
;; Returning nil reuses a return value the function already produces on its
;; own: when the user cancels registration with an empty string, skk.el's
;; comment at line 2367 says plainly "new-one が空文字列だったら nil を返
;; す" and the code at skk.el:2368-2370 does exactly that.  `skk-henkan'
;; (skk.el:1723-1730) already treats that nil as "no new word" -- its `cond'
;; simply falls through without inserting anything -- so this is a
;; sanctioned outcome of the existing call site, not a new branch.
;;
;; `skk-exit-henkan-in-minibuff' (skk.el:1748-1751) and the nesting depth it
;; reads at skk.el:1750 (`skk-henkan-in-minibuff-nest-level') exist only to
;; track recursive minibuffer registration and can never matter here:
;; `minibuffer-depth' is hard-wired to 0 in `skk-nelisp-compat.el' (this
;; runtime never opens a minibuffer), and `add-hook' there is an
;; unconditional no-op, so the `minibuffer-exit-hook' that would call
;; `skk-exit-henkan-in-minibuff' (skk.el:5083-5089) is never installed.
;;
;; The one thing this skips that the real empty-string path performs is its
;; own buffer cleanup (flipping the already-inserted ▼ marker back to ▽ and
;; resetting `skk-henkan-count' when the abort happens on the first
;; candidate).  That leftover "▼ active, zero candidates" state is not a
;; signal or corruption: `skk-henkan-list' stays empty, so
;; `skk-get-current-candidate-1' (skk-macs.el:603, `(nth count
;; skk-henkan-list)') returns nil for it, and the next `skk-kakutei'
;; (skk.el:2650) -- reached via the engine's own CONTROL COMMIT -- resolves
;; it cleanly: `kakutei-word' comes back nil so the jisyo-update branch is
;; skipped, while `skk-kakutei-cleanup-buffer' and `skk-kakutei-initialize'
;; still run unconditionally and remove the marker.  This matches the
;; intended behaviour of treating the word as unregistered and confirming
;; the reading as-is.
(defun skk-henkan-in-minibuff () nil)

(load "engine/skk-ime-session.el")

(defun skk-ime-session--initialize-native-buffer ()
  ;; On this machine, learning and the personal dictionary live on the SKK
  ;; server side (`~/Notes/assets/ddskk/SKK-MY-JISYO.utf8', served by the
  ;; running skkserv), not in a local file -- the default `~/.skk-jisyo' is
  ;; 0 bytes here.  Setting `skk-jisyo' to nil makes `skk-get-jisyo-buffer'
  ;; (skk.el:3839) return nil immediately (its whole body is `(when file
  ;; ...)'), which makes `skk-update-jisyo-original' (skk.el:4225) skip its
  ;; entire personal-dictionary update under `(when jisyo-buffer ...)' -- a
  ;; clean no-op, not a signal.  `skk-save-jisyo-instantly' already defaults
  ;; to nil and is untouched by this file, so `skk-update-jisyo'
  ;; (skk.el:4216) never calls `skk-save-jisyo' either.
  (setq skk-mode t skk-j-mode t skk-abbrev-mode nil skk-latin-mode nil
        skk-jisx0208-latin-mode nil skk-jisx0201-mode nil skk-katakana nil
        skk-echo nil skk-prefix "" skk-current-rule-tree nil
        skk-henkan-mode nil skk-henkan-start-point nil skk-henkan-end-point nil
        skk-kana-start-point nil skk-okurigana nil skk-insert-keysequence nil
        buffer-undo-list t overwrite-mode nil auto-fill-function nil
        current-prefix-arg nil skk-jisyo nil)
  (unless skk-rule-tree
    (setq skk-rule-tree
          (skk-compile-rule-list skk-rom-kana-base-rule-list
                                 skk-rom-kana-rule-list))))

(defvar ddskk-engine--session nil)
(defvar native-ime-engine-id "ddskk")

(defvar ddskk-engine--debug-errors (getenv "DDSKK_ENGINE_DEBUG")
  "When non-nil, degraded responses carry the signalled error symbol.
The dispatch paths catch every signal so one keystroke cannot terminate
the resident IME, but that also hides real defects.  Setting the
`DDSKK_ENGINE_DEBUG' environment variable makes each handler report
`ERR <TOKEN> <error-symbol>' instead of its silent fallback, so a probe
harness can see what actually failed.")

(defun ddskk-engine-start ()
  (unless (skk-ime-session-live-p ddskk-engine--session)
    (setq ddskk-engine--session (skk-ime-session-create)))
  t)

(defun ddskk-engine-stop ()
  (when (skk-ime-session-live-p ddskk-engine--session)
    (skk-ime-session-destroy ddskk-engine--session))
  (setq ddskk-engine--session nil))

(defconst ddskk-engine--hex-digits "0123456789abcdef"
  "Lowercase nibble table for `ddskk-engine--hex'.")

(defun ddskk-engine--hex (string)
  "Return STRING as fixed-width 6-digit lowercase scalar hex, or \"-\".
The wire format is unchanged; only the encoding cost is.  The previous
implementation grew a result string with `concat' (quadratic) and called
`format' once per character (~1.9 ms each in this runtime)."
  (let ((count (length string)))
    (if (= count 0)
        "-"
      (let ((out (make-string (* count 6) ?0))
            (index 0)
            (offset 0))
        (while (< index count)
          ;; `make-string' already filled every position with ?0, so only the
          ;; significant nibbles need writing.  Almost every character an IME
          ;; handles is in the BMP, where the top two digits stay "00":
          ;; writing four instead of six drops a third of the inner loop, and
          ;; each iteration here is four interpreted calls in this runtime.
          (let ((code (aref string index)))
            (if (< code 65536)
                (let ((digit 5))
                  (while (>= digit 2)
                    (aset out (+ offset digit)
                          (aref ddskk-engine--hex-digits (logand code 15)))
                    (setq code (ash code -4))
                    (setq digit (1- digit))))
              (let ((digit 5))
                (while (>= digit 0)
                  (aset out (+ offset digit)
                        (aref ddskk-engine--hex-digits (logand code 15)))
                  (setq code (ash code -4))
                  (setq digit (1- digit))))))
          (setq index (1+ index))
          (setq offset (+ offset 6)))
        out))))

(defun ddskk-engine--state-line (state)
  (format "STATE %s %d %d %s %s %d %s"
          (symbol-name (plist-get state :mode)) (plist-get state :cursor)
          (or (plist-get state :composition-start) -1)
          (ddskk-engine--hex (plist-get state :text))
          (ddskk-engine--hex (plist-get state :pending-romaji))
          (or (plist-get state :candidate-index) -1)
          (if (plist-get state :candidates)
              (mapconcat #'ddskk-engine--hex
                         (plist-get state :candidates) ",")
            "-")))

(defun ddskk-engine--maybe-truncate-session ()
  "Drop already-committed text from the session buffer at a clean boundary.
The native host never sends RESET, so the session buffer would otherwise
grow for the lifetime of the IME: every request re-encodes the whole
buffer, and the Windows adapter re-commits it.  Truncating only when
DDSKK has no active conversion and no pending romaji prefix keeps every
marker-bearing state untouched."
  (when (skk-ime-session-live-p ddskk-engine--session)
    (with-current-buffer (skk-ime-session-buffer ddskk-engine--session)
      (when (and (null skk-henkan-mode)
                 (equal skk-prefix "")
                 (> (point-max) (point-min)))
        (erase-buffer)))))

(defun ddskk-engine--error-datum-string (value)
  "Render one error datum element of an Elisp error condition as a string.
VALUE may be a symbol, a string, a number, or (for any other shape)
something rendered as \"?\".  The result is not yet protocol-safe; see
`ddskk-engine--sanitize-protocol-line'."
  (cond
   ((symbolp value) (symbol-name value))
   ((stringp value) value)
   ((numberp value) (number-to-string value))
   (t "?")))

(defun ddskk-engine--sanitize-protocol-line (string)
  "Replace newline and tab characters in STRING with a space.
Error data can embed arbitrary text (for example an `error' message),
but the wire protocol allows exactly one line per response."
  (let ((out (copy-sequence string))
        (index 0)
        (count (length string)))
    (while (< index count)
      (when (memq (aref out index) '(?\n ?\t))
        (aset out index ?\s))
      (setq index (1+ index)))
    out))

(defun ddskk-engine--error-token (token err)
  "Return TOKEN, plus ERR's symbol and data when debugging is enabled.
The data carries the missing symbol name for `void-variable' /
`void-function', which is exactly what a compat-layer gap looks like."
  (if ddskk-engine--debug-errors
      (let ((parts (concat token " "
                            (ddskk-engine--error-datum-string
                             (car-safe err))))
            (rest (cdr-safe err)))
        (while (consp rest)
          (setq parts (concat parts " "
                              (ddskk-engine--error-datum-string
                               (car rest))))
          (setq rest (cdr rest)))
        (ddskk-engine--sanitize-protocol-line parts))
    token))

(defun ddskk-engine-dispatch-line (line)
  (ddskk-engine-start)
  (cond
   ((equal line "HELLO 1") "OK 1")
   ((equal line "ENGINE LIST") "ENGINES ddskk passthrough")
   ((equal line "ENGINE CURRENT")
    (concat "ENGINE " native-ime-engine-id))
   ((equal line "ENGINE SET ddskk")
    (setq native-ime-engine-id "ddskk") "OK ENGINE ddskk")
   ((equal line "ENGINE SET passthrough")
    (setq native-ime-engine-id "passthrough") "OK ENGINE passthrough")
   ((equal line "RESET")
    (ddskk-engine--state-line (skk-ime-session-reset ddskk-engine--session)))
   ((equal line "CONTROL BACKSPACE")
    ;; A signal here would terminate the whole engine process and with it the
    ;; user's resident IME.  Degrade to an error response instead.
    (condition-case err
        (let ((response (ddskk-engine--state-line
                         (skk-ime-session-control ddskk-engine--session 'backspace))))
          (ddskk-engine--maybe-truncate-session)
          response)
      (error (ddskk-engine--error-token "ERR BACKSPACE" err))))
   ((equal line "CONTROL COMMIT")
    ;; A signal here would terminate the whole engine process and with it the
    ;; user's resident IME.  Degrade to an error response instead.
    (condition-case err
        (let ((response (ddskk-engine--state-line
                         (skk-ime-session-control ddskk-engine--session 'commit))))
          (ddskk-engine--maybe-truncate-session)
          response)
      (error (ddskk-engine--error-token "ERR COMMIT" err))))
   ((equal line "CONTROL CONVERT")
    ;; DDSKK's henkan guards compare a marker with `point' arithmetically.
    ;; This runtime does not coerce a marker to its position, so the guard
    ;; can signal and would otherwise terminate the whole engine process and
    ;; with it the user's resident IME.  Degrade to an error response.
    (condition-case err
        (ddskk-engine--state-line
         (skk-ime-session-control ddskk-engine--session 'convert))
      (error (ddskk-engine--error-token "ERR CONVERT" err))))
   ((equal line "CONTROL PREVIOUS")
    ;; DDSKK's henkan guards compare a marker with `point' arithmetically.
    ;; This runtime does not coerce a marker to its position, so the guard
    ;; can signal and would otherwise terminate the whole engine process and
    ;; with it the user's resident IME.  Degrade to an error response.
    (condition-case err
        (ddskk-engine--state-line
         (skk-ime-session-control ddskk-engine--session 'previous))
      (error (ddskk-engine--error-token "ERR PREVIOUS" err))))
   ((equal line "CONTROL CANCEL")
    ;; A signal here would terminate the whole engine process and with it the
    ;; user's resident IME.  Degrade to an error response instead.
    (condition-case err
        (let ((response (ddskk-engine--state-line
                         (skk-ime-session-control ddskk-engine--session 'cancel))))
          (ddskk-engine--maybe-truncate-session)
          response)
      (error (ddskk-engine--error-token "ERR CANCEL" err))))
   ((equal line "QUIT") "OK BYE")
   ((string-match "^KEY \\([0-9]+\\)$" line)
    (let ((codepoint (string-to-number (match-string 1 line))))
      (if (or (< codepoint 0) (> codepoint 1114111)) "ERR CODEPOINT"
        ;; A signal here would terminate the whole engine process and with it
        ;; the user's resident IME, leaking the raw keystroke into the user's
        ;; document.  Degrade to a STATE line for the current session instead.
        (condition-case err
            (let ((state-line
                   (ddskk-engine--state-line
                    (skk-ime-session-feed-key ddskk-engine--session codepoint))))
              (ddskk-engine--maybe-truncate-session)
              state-line)
          (error (if ddskk-engine--debug-errors
                     (ddskk-engine--error-token "ERR KEY" err)
                   (ddskk-engine--safe-state-line)))))))
   (t "ERR REQUEST")))

(defun ddskk-engine-write-response (response)
  (nelisp--write-stdout-bytes (concat response "\n")))

(defun ddskk-engine--safe-state-line ()
  "Return a STATE line for the current session, or an ERR token.
Used as the degraded response when a key handler signals: emitting a
valid state keeps the Windows adapter from failing open and leaking the
raw keystroke into the user's document."
  (condition-case err
      (ddskk-engine--state-line
       (skk-ime-session-snapshot ddskk-engine--session))
    (error (ddskk-engine--error-token "ERR STATE" err))))

(defun ddskk-engine-dispatch-key-to-stdout (codepoint)
  (ddskk-engine-start)
  (ddskk-engine-write-response
   (condition-case err
       (let ((response (ddskk-engine--state-line
                        (skk-ime-session-feed-key ddskk-engine--session codepoint))))
         (ddskk-engine--maybe-truncate-session)
         response)
     (error (if ddskk-engine--debug-errors
                (ddskk-engine--error-token "ERR KEY" err)
              (ddskk-engine--safe-state-line))))))

(defun ddskk-engine-dispatch-keys-to-stdout (keys)
  (ddskk-engine-start)
  (ddskk-engine-write-response
   (condition-case err
       (let ((response (ddskk-engine--state-line
                        (skk-ime-session-feed-string ddskk-engine--session keys))))
         (ddskk-engine--maybe-truncate-session)
         response)
     (error (if ddskk-engine--debug-errors
                (ddskk-engine--error-token "ERR KEY" err)
              (ddskk-engine--safe-state-line))))))

(defun ddskk-engine-dispatch-line-to-stdout (line)
  (ddskk-engine-write-response (ddskk-engine-dispatch-line line)))

(defun ddskk-engine--server-request (midasi)
  "Ask the native host for MIDASI and return its raw reply line.
The host intercepts a `SERVER ' line on stdout, performs the dictionary
lookup, and writes one reply line back to stdin.  Returns nil on EOF,
and also nil -- without writing anything -- if MIDASI itself contains a
newline or carriage return: the wire protocol allows exactly one line
per request, and while DDSKK's own `skk-henkan-key' should never contain
one, this guard keeps a broken request line from ever being emitted.

`ddskk-engine-read-stdio-line' is defined in `ddskk-engine-stdio.el',
which `load's this file first and only starts dispatching requests via
`ddskk-engine-run-stdio' after that `load' returns and the function has
been defined.  A plain call form such as the one below resolves its
function symbol at the moment it actually runs, not when this `defun'
is read, so by the time `CONTROL CONVERT' can ever reach this code
`ddskk-engine-read-stdio-line' is already bound."
  (let ((index 0) (count (length midasi)) (has-eol nil))
    (while (and (not has-eol) (< index count))
      (when (memq (aref midasi index) '(?\n ?\r))
        (setq has-eol t))
      (setq index (1+ index)))
    (unless has-eol
      (nelisp--write-stdout-bytes (concat "SERVER " midasi "\n"))
      (ddskk-engine-read-stdio-line))))

(defun ddskk-engine--parse-server-reply (reply)
  "Split a skkserv REPLY line into a list of candidate strings.
`1/A/B/C/' -> (\"A\" \"B\" \"C\").  `4' or anything malformed -> nil.
Each candidate is returned verbatim, including any `;annotation' suffix:
DDSKK's own jisyo format stores the annotation as part of the candidate
string and splits it back off again at display time -- see the
`(string-match \";\" e)' step in `skk-henkan-candidate-list' in `skk.el'
-- so keeping it here matches what the rest of DDSKK already expects to
receive."
  (let ((count (length reply)))
    (when (and (> count 0) (= (aref reply 0) ?1))
      (let ((candidates nil)
            (start 1)
            (index 1))
        (while (< index count)
          (when (= (aref reply index) ?/)
            (when (> index start)
              (push (substring reply start index) candidates))
            (setq start (1+ index)))
          (setq index (1+ index)))
        (nreverse candidates)))))

(defun ddskk-engine-server-search ()
  "Search the host-relayed dictionary for the current midasi.
Installed into `skk-search-prog-list'; DDSKK binds `skk-henkan-key' to the
midasi before evaluating each element of that list."
  (let ((reply (ddskk-engine--server-request skk-henkan-key)))
    (and reply (ddskk-engine--parse-server-reply reply))))

;; DDSKK's stock `skk-search-prog-list' references file/CDB/server search
;; functions that cannot run on this runtime (no buffer search primitive).
;; The host performs the lookup instead, so one entry is enough.
(setq skk-search-prog-list '((ddskk-engine-server-search)))

(ddskk-engine-start)
