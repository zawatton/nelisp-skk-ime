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
(load "engine/skk-user-jisyo.el")

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
  ;;
  ;; `skk-henkan-key' / `skk-henkan-list' / `skk-henkan-count' /
  ;; `skk-kakutei-flag' / `skk-kakutei-henkan-flag' / `skk-undo-kakutei-flag'
  ;; / `skk-okuri-char' / `skk-okuri-index-min' / `skk-okuri-index-max' /
  ;; `skk-exit-show-candidates' / `skk-henkan-okurigana' /
  ;; `skk-current-search-prog-list' are reset here to the exact values
  ;; `skk-kakutei-initialize' (skk.el:2839-2882) resets them to on a normal
  ;; COMMIT.  Without this, `RESET' issued while a conversion is mid-flight
  ;; (CONVERT already ran, no COMMIT yet -- a real scenario: e.g. the native
  ;; host resets on a focus change during composition) leaves a stale
  ;; `skk-henkan-list'/`skk-henkan-key' behind.  The NEXT conversion's first
  ;; search then does `(setq skk-henkan-list (skk-nunion skk-henkan-list
  ;; (skk-search)))' (skk.el:1763) with that stale list as X: `skk-nunion'
  ;; only APPENDS non-duplicate Y-elements to X, it never clears X, so the
  ;; previous conversion's candidate leaks into the front of the new one's
  ;; candidate list -- reproduced concretely as converting かんじ, resetting
  ;; without committing, then converting the unrelated okuri-ari word かk
  ;; and getting "感じ" (かんじ's own candidate) prepended ahead of
  ;; かk's actual candidates.  `skk-ime-session-control's `cancel' branch
  ;; already avoids this by calling `skk-kakutei-initialize' directly when
  ;; `skk-henkan-mode' is non-nil; `RESET' had no equivalent.
  (setq skk-mode t skk-j-mode t skk-abbrev-mode nil skk-latin-mode nil
        skk-jisx0208-latin-mode nil skk-jisx0201-mode nil skk-katakana nil
        skk-echo nil skk-prefix "" skk-current-rule-tree nil
        skk-henkan-mode nil skk-henkan-start-point nil skk-henkan-end-point nil
        skk-kana-start-point nil skk-okurigana nil skk-insert-keysequence nil
        buffer-undo-list t overwrite-mode nil auto-fill-function nil
        current-prefix-arg nil skk-jisyo nil
        skk-henkan-key nil skk-henkan-list nil skk-henkan-count -1
        skk-kakutei-flag nil skk-kakutei-henkan-flag nil
        skk-undo-kakutei-flag nil skk-okuri-char nil skk-okuri-index-min -1
        skk-okuri-index-max -1 skk-exit-show-candidates nil
        skk-henkan-okurigana nil skk-current-search-prog-list nil)
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

;; --- GC scheduling -------------------------------------------------------
;; An earlier version of this file ran `garbage-collect' from
;; `ddskk-engine--maybe-truncate-session' itself, at every confirmed-word
;; boundary (gated by a `ddskk-engine--gc-every-boundaries' counter,
;; overridable via a `DDSKK_ENGINE_GC_EVERY' env var). That fixed the
;; runtime's unbounded ~1.6 MB/keystroke growth completely -- flat working
;; set across 0/25/50/100/200 confirmed words -- but at a cost that is not
;; acceptable for an IME: every single CONTROL COMMIT paid the collector's
;; full price (this runtime's collector is a semispace copier whose cost
;; tracks LIVE heap size, and the live heap here is ~311 MB of loaded
;; DDSKK + compat layer + runtime), which measured at a steady ~306 ms
;; median / ~468 ms worst case on every confirmed word, versus ~127 ms
;; median with no GC at all (and growing unboundedly from there).
;;
;; This runtime's collector cost cannot be reduced by generating less
;; garbage, and `nelisp-gc-inner-collect' (the generational entry point in
;; dev/nelisp/src/nelisp-gc-inner.el) is not `fboundp' in this standalone
;; binary, so a cheap minor collection is not available either. The fix
;; is therefore not "collect less garbage" or "collect more cheaply" but
;; "collect at a moment nobody is waiting on a keystroke": the `GC'
;; protocol line below lets the host (windows/host/main.cpp) request a
;; collection explicitly, and the host only ever sends that line after its
;; pipe has sat idle for a while -- see that file's `IdleGcLoop' for the
;; idle-interval measurement and the ordering argument for why a real
;; keystroke can never queue up behind a GC that had not yet started.
;; `ddskk-engine--maybe-truncate-session' no longer calls a collector at
;; all; truncation and collection are now on two entirely different
;; triggers (a clean DDSKK boundary vs. host-observed pipe idleness).
;;
;; `DDSKK_ENGINE_GC_EVERY' (and the boundary counter it used to space out)
;; is removed rather than kept as a dead knob: it controlled how many
;; confirmed-word boundaries passed between GCs, but there is no longer
;; any boundary-triggered call site for it to space out -- keeping the
;; variable would just be configuration pointing at nothing. GC frequency
;; is now controlled entirely on the host side, by the idle interval
;; (`DDSKK_ENGINE_IDLE_GC_MS' env var / `HKCU\Software\NativeIME\IdleGcMs'
;; registry value), which is the new single point of control.

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
  "Return the wire STATE line for STATE.

Assembled with `concat' rather than one `format'.  Measured on this
runtime (slope method, 20 vs 120 iterations): `format' with these seven
directives costs 23.5 ms per call, while the whole `concat' below costs
1.8 ms -- roughly 136 us per argument.  This function runs on every
keystroke, so that difference is most of the per-key budget: the common
short-state line went from 28.7 ms to 9.8 ms.

The emitted bytes are unchanged.  Every numeric field here is an
integer -- `skk-ime-session-snapshot' derives them from `point',
`marker-position' and `skk-henkan-count' -- so `number-to-string' and
%d agree; `%s' on a string and on `symbol-name' output is likewise the
identity.  `:candidates' is read once instead of twice."
  (let ((candidates (plist-get state :candidates)))
    (concat "STATE "
            (symbol-name (plist-get state :mode)) " "
            (number-to-string (plist-get state :cursor)) " "
            (number-to-string (or (plist-get state :composition-start) -1)) " "
            (ddskk-engine--hex (plist-get state :text)) " "
            (ddskk-engine--hex (plist-get state :pending-romaji)) " "
            (number-to-string (or (plist-get state :candidate-index) -1)) " "
            (if candidates
                (mapconcat #'ddskk-engine--hex candidates ",")
              "-"))))

(defun ddskk-engine--maybe-truncate-session ()
  "Drop already-committed text from the session buffer at a clean boundary.
The native host never sends RESET, so the session buffer would otherwise
grow for the lifetime of the IME: every request re-encodes the whole
buffer, and the Windows adapter re-commits it.  Truncating only when
DDSKK has no active conversion and no pending romaji prefix keeps every
marker-bearing state untouched.

This function no longer runs a collector itself -- see the \"GC
scheduling\" comment above `ddskk-engine-start' for why that was moved
to an explicit, host-triggered `GC' protocol line instead of running
here on every confirmed word."
  (when (skk-ime-session-live-p ddskk-engine--session)
    (with-current-buffer (skk-ime-session-buffer ddskk-engine--session)
      (when (and (null skk-henkan-mode)
                 (equal skk-prefix ""))
        (when (> (point-max) (point-min))
          (erase-buffer))))))

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
   ((equal line "CONTROL QUIT")
    ;; DDSKK keyboard-quit semantics (see the long comment on the `quit'
    ;; case in `skk-ime-session-control', skk-ime-session.el) -- distinct
    ;; from `CONTROL CANCEL' above (Ctrl+J's unconditional "back to plain
    ;; kana"): graduated, mode-dependent dismissal that the ▼/▽ paths route
    ;; through real DDSKK functions (`skk-henkan-inactivate' /
    ;; `skk-henkan-off-by-quit'), each of which can in principle signal on
    ;; this runtime the same way `CONTROL CONVERT'/`CONTROL PREVIOUS' can.
    ;; Degrade to an error response rather than take down the resident IME.
    (condition-case err
        (let ((response (ddskk-engine--state-line
                         (skk-ime-session-control ddskk-engine--session 'quit))))
          (ddskk-engine--maybe-truncate-session)
          response)
      (error (ddskk-engine--error-token "ERR QUIT" err))))
   ((equal line "QUIT") "OK BYE")
   ((equal line "GC")
    ;; Explicit maintenance request from the host's idle timer (see
    ;; `IdleGcLoop' in windows/host/main.cpp) -- sent only after the pipe
    ;; has sat idle for a while, never on the per-keystroke or
    ;; per-confirmed-word critical path (see the "GC scheduling" comment
    ;; above `ddskk-engine-start').  A signal here must not kill the
    ;; resident engine, so degrade to an error response like the
    ;; neighbouring arms do.
    (condition-case err
        (progn
          (when (fboundp 'garbage-collect) (garbage-collect))
          "OK GC")
      (error (ddskk-engine--error-token "ERR GC" err))))
   ((equal line "STATUS")
    ;; The mode-indicator UI (docs/design/sumi-indicator-settings.md) polls
    ;; this verb to display the current input mode.  Until now every verb
    ;; mutated the session -- KEY dispatches a keystroke, RESET
    ;; reinitializes, CONTROL edits the buffer, GC collects -- so an
    ;; observer had no safe way to look without also changing something.
    ;; This reads via `skk-ime-session-snapshot', which performs no key
    ;; dispatch, no truncation, and no jisyo learning, and formats the
    ;; result with the exact same `ddskk-engine--state-line' helper the KEY
    ;; arm uses (also the one `ddskk-engine--safe-state-line' already
    ;; relies on for its degraded fallback), so the wire format can never
    ;; drift between verbs.
    (condition-case err
        (ddskk-engine--state-line
         (skk-ime-session-snapshot ddskk-engine--session))
      (error (ddskk-engine--error-token "ERR STATUS" err))))
   ((equal line "COMPACT")
    ;; Explicit maintenance request from the host's idle timer, exactly
    ;; like `GC' above -- sent only after the pipe has sat idle for a
    ;; while, never on the per-keystroke or per-commit critical path.
    ;; `ddskk-user-jisyo-compact' (engine/skk-user-jisyo.el) folds the
    ;; learn journal into a full save of the user dictionary ONLY once
    ;; enough confirmations have queued (returning nil, a fast no-op,
    ;; otherwise); every ordinary confirmation instead pays only for one
    ;; short journal-append, on the CONTROL COMMIT path, so this is what
    ;; keeps the ~300-500ms whole-table serialize off commit latency.
    ;; Unlike the other error-degrading arms above, `ddskk-user-jisyo-
    ;; compact' deliberately SIGNALS on a genuine save failure (rather
    ;; than swallowing it the way `ddskk-user-jisyo-save' always does)
    ;; specifically so this condition-case can report it back to
    ;; whoever explicitly asked for a compaction.
    (condition-case err
        (if (ddskk-user-jisyo-compact) "OK COMPACT" "OK COMPACT NOOP")
      (error (ddskk-engine--error-token "ERR COMPACT" err))))
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
;; The host performs the shared-dictionary lookup; `ddskk-user-jisyo-search'
;; (engine/skk-user-jisyo.el) is listed FIRST so a previously-confirmed
;; candidate for this midasi is offered before the shared dictionary is
;; even asked -- see that file for the personal-dictionary learning
;; machinery and for why listing it first does not produce duplicate
;; candidates once the server's own results are merged in on a later SPC
;; (`skk-nunion' in skk-macs.el already dedups by `equal').
(setq skk-search-prog-list '((ddskk-user-jisyo-search)
                              (ddskk-engine-server-search)))

;; --- Behavior toggles (registry-driven; docs/design/sumi-indicator-
;; settings.md "Tab 動作") -------------------------------------------------
;;
;; The settings UI writes these as DWORDs to HKCU\Software\NativeIME; the
;; host bridges registry -> environment variable when it spawns this
;; engine process (same precedent as `ApplyUserJisyoEnvFromRegistry' in
;; windows/host/main.cpp), and the settings window's エンジン再起動 button
;; is what makes a changed value actually take effect, since every one of
;; these is read exactly once here at boot, never polled afterward.  Each
;; is applied only when its env var is literally "1"; absent or any other
;; value leaves the DDSKK default alone.  This has to run after `(load
;; "vendor/ddskk/skk-vars.el")' above (its `defcustom' forms are what
;; establish the nil defaults being overridden) and, for the katakana
;; toggle specifically, after the `skk-search-prog-list' `setq' directly
;; above -- exactly the same reasoning `(setq skk-use-face nil)' documents
;; near the top of this file for why a plain `setq' at this point in the
;; load, not a `defvar', is what makes an override stick.
(when (equal (getenv "DDSKK_OKURI_STRICTLY") "1")
  ;; Registry: BehaviorOkuriStrictly.  CorvusSKK "送り仮名が一致した候補を
  ;; 優先する" -- among candidates for an okuri-ari reading, only offer the
  ;; ones whose okurigana conjugation matches what was actually typed.
  (setq skk-henkan-okuri-strictly t))

(when (equal (getenv "DDSKK_DELETE_OKURI_ON_CANCEL") "1")
  ;; Registry: BehaviorDeleteOkuriOnCancel.  CorvusSKK "取消のとき送り仮名
  ;; を削除する" -- canceling an okuri-ari conversion also removes the
  ;; already-typed okurigana kana, not just the kanji candidate (consulted
  ;; by `skk-kakutei' in skk.el; wired through this engine's own CONTROL
  ;; CANCEL path in `skk-ime-session-control').
  (setq skk-delete-okuri-when-quit t))

(when (equal (getenv "DDSKK_SEARCH_KATAKANA") "1")
  ;; Registry: BehaviorAddKatakanaCand.  CorvusSKK "候補に片仮名変換を追加
  ;; する".  `skk-search-katakana' (skk-vars.el:1462) exists in this
  ;; vendored DDSKK, and its search function `skk-search-katakana-maybe'
  ;; (skk.el:4536-4538) already gates on the variable internally -- but
  ;; this engine replaces `skk-search-prog-list' wholesale, immediately
  ;; above, with its own two-entry list (jisyo-search + server-search),
  ;; which never carried over the stock default list's katakana entry
  ;; (skk-vars.el:449).  Setting the variable alone would therefore be a
  ;; silent no-op on this engine; appending the search function is what
  ;; actually wires it in.  Appended LAST, exactly where upstream's own
  ;; default list places it (after every dictionary search): `skk-search'
  ;; stops at the first entry that returns a non-nil result, so this only
  ;; contributes candidates once the jisyo/server searches are already
  ;; exhausted for the current reading -- matching `skk-search-katakana''s
  ;; own docstring ("単純にカタカナに変換したものを候補として返す"), an
  ;; extra option at the end of the list, not a hit that would pre-empt a
  ;; real dictionary match.
  (setq skk-search-katakana t)
  (setq skk-search-prog-list
        (append skk-search-prog-list '((skk-search-katakana-maybe)))))

;; Learning: DDSKK's own file-backed jisyo machinery is disabled (`skk-jisyo'
;; is nil -- see the comment above `skk-ime-session--initialize-native-
;; buffer'), but `skk-update-jisyo' (skk.el:4216-4217) still calls through
;; the `skk-update-jisyo-function' indirection on every confirmed candidate
;; regardless of `skk-jisyo'.  Redirect it at the client-side personal
;; dictionary instead of the stock `skk-update-jisyo-original', which would
;; silently no-op here.
(setq skk-update-jisyo-function #'ddskk-user-jisyo--update)
(ddskk-user-jisyo-load)

(ddskk-engine-start)
