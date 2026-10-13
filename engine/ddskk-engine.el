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

;; Defer `skk-tankan.el'.  It is 単漢字検索 -- looking a single kanji up by
;; radical or stroke count -- and on this runtime it costs 3.5-4.0s to
;; load, about 30% of the whole cold start, because
;; `skk-tankan-name-radical-alist' (skk-tankan.el:1836) builds a ~640-entry
;; alist through a multibyte `split-string' and a padded `format' per
;; entry.  `skk.el' pulls the file in from its `eval-and-compile' require
;; block and never touches a symbol from it; the engine host therefore paid
;; the whole cost before it could answer its first keystroke, for a feature
;; the first keystroke cannot reach.
;;
;; What makes deferring safe rather than merely faster: the one entry point
;; that the DEFAULT `skk-search-prog-list' reaches, `skk-tankan-search', is
;; a no-op unless the reading ends with `skk-tankan-search-key' (@) --
;; see its own `when' at skk-tankan.el:1950.  So the stub below can decide
;; whether the real thing is needed using only `skk-vars.el' data, which is
;; already loaded, and an ordinary conversion never loads the file at all.
;; The cost moves to the first ACTUAL 単漢字 lookup instead of every start.
;;
;; `autoload' is void on standalone NeLisp, so these are hand-written: each
;; stub loads the file (which redefines it) and then re-dispatches.
(defvar ddskk-engine--tankan-loaded nil)
(defun ddskk-engine--load-tankan ()
  (unless ddskk-engine--tankan-loaded
    (setq ddskk-engine--tankan-loaded t)
    (load "vendor/ddskk/skk-tankan.el")))
(defun skk-tankan-search (func &rest args)
  "Load `skk-tankan.el' on demand, then run the real `skk-tankan-search'.
Answers nil without loading anything unless the reading actually asks for
単漢字変換, which is the same condition the real function tests first."
  (when (and (boundp 'skk-henkan-key)
             (stringp skk-henkan-key)
             (boundp 'skk-tankan-search-key)
             (string-match (format "%s$"
                                   (regexp-quote
                                    (char-to-string skk-tankan-search-key)))
                           skk-henkan-key))
    (ddskk-engine--load-tankan)
    (apply 'skk-tankan-search func args)))
(defun skk-tankan (arg)
  "Load `skk-tankan.el' on demand, then run the real `skk-tankan'."
  (ddskk-engine--load-tankan)
  (skk-tankan arg))
(provide 'skk-tankan)

;; Henkan points as plain positions, not markers.
;;
;; DDSKK keeps `skk-henkan-start-point' and friends in markers and then
;; does ordinary arithmetic on them -- `skk-start-henkan' guards with
;; `(< pos skk-henkan-start-point)'.  In GNU Emacs that is fine: `<' accepts
;; a marker, which is what `number-or-marker-p' in its error message names.
;; On standalone NeLisp a marker is an ordinary struct, so that comparison
;; signalled `wrong-type-argument' and every conversion failed.
;;
;; The runtime now accepts markers in `1-', `max' and `min' (see
;; `nelisp-marker-install-arithmetic', ../nelisp/src/nelisp-buffer.el), but
;; deliberately NOT in `<': measured interleaved on this engine's own load,
;; wrapping `<' costs 1.30-1.42x and wrapping the whole arithmetic family
;; 2.8-3.6x, because this runtime charges a basic operation per call and
;; those are the hottest primitives it has.
;;
;; So the marker is removed from the hot path instead of the check being
;; added to it.  This runtime's markers do not adjust on insertion anyway
;; (see the `set-marker' commentary in skk-nelisp-compat.el), so for these
;; variables a marker carries nothing an integer does not -- and every
;; henkan point is set through this one macro, so overriding it covers all
;; of them at once rather than call site by call site.
;;
;; It must be redefined BEFORE `skk.el' is loaded: it is a macro, and
;; `skk.el' expands it at load time.
(defmacro skk-set-marker (marker position &optional _buffer)
  "Set MARKER to POSITION as a plain position (NeLisp override)."
  (list 'setq marker position))

;; This runtime's point markers do not adjust and its comparison operators
;; reject markers. DDSKK's q command compares the saved point using >=.
;; Use the same numeric-position policy as the henkan markers above.
(defmacro skk-save-point (&rest body)
  `(let ((skk-save-point (point)))
     (unwind-protect (progn ,@body) (goto-char skk-save-point))))

;; `marker-position' is then handed an integer by anything that still asks
;; a henkan point for its position (`skk-emacs.el' does).  Answer it rather
;; than signal: the value IS the position.
(unless (fboundp 'nelisp-skk--native-marker-position)
  (defalias 'nelisp-skk--native-marker-position (symbol-function 'marker-position))
  (defun marker-position (m)
    (if (numberp m) m (nelisp-skk--native-marker-position m))))

(load "vendor/ddskk/skk.el")

;; When DDSKK restores candidate zero, deleting the candidate moves its
;; end marker to the start before the reading is inserted. Our numeric
;; henkan positions above do not move. Emulate that one marker adjustment
;; while running the original DDSKK command, or okuri precedes the reading
;; ("▽くか" instead of "▽かく"). Keep stock conversion/quit logic intact.
(defvar ddskk-engine--restoring-candidate nil)
(unless (fboundp 'ddskk-engine--delete-region)
  (defalias 'ddskk-engine--delete-region (symbol-function 'delete-region)))
(defun delete-region (start end)
  (let ((adjust (and ddskk-engine--restoring-candidate
                     (numberp skk-henkan-end-point)
                     (= start skk-henkan-start-point)
                     (= end skk-henkan-end-point))))
    (ddskk-engine--delete-region start end)
    (when adjust (setq skk-henkan-end-point start))))
(unless (fboundp 'ddskk-engine--previous-candidate)
  (defalias 'ddskk-engine--previous-candidate
    (symbol-function 'skk-previous-candidate)))
(defun skk-previous-candidate (&optional arg)
  (let ((ddskk-engine--restoring-candidate
         (and (eq skk-henkan-mode 'active) (= skk-henkan-count 0))))
    (ddskk-engine--previous-candidate arg)))

(load "engine/skk-input-rules.el")
(skk-input-rules-load)

;; `skk-okurigana-prefix' in DDSKK derives the romaji prefix of an
;; okurigana through Mule's JIS-octet API.  Both GNU Emacs in a UTF-8-only
;; batch environment and standalone NeLisp can report the UTF-8 trailing
;; byte there (for example 0x8b for る) instead of its JIS column.  The
;; resulting vector index is outside `skk-kana-rom-vector' and the final
;; key of an okuri-ari word is lost (KieRu used to stop at ▽きえ*r).
;; Hiragana U+3041..U+3093 has exactly the same order as that vector, so use
;; the Unicode scalar directly and leave dictionary/conversion semantics to
;; DDSKK unchanged.
(defun skk-okurigana-prefix (okurigana)
  (let* ((headchar (substring okurigana 0 1))
         (target (if (and (string= headchar "っ")
                          (not (string= okurigana "っ")))
                     (substring okurigana 1 2)
                   headchar))
         (char (string-to-char target)))
    (cond
     ((string= headchar "ん") "n")
     ((not (and (<= #x3041 char) (<= char #x3093))) nil)
     (t (aref skk-kana-rom-vector (- char #x3041))))))

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
;; Registration inside the modal editor is resumed asynchronously. Capture
;; its native state before DDSKK cleans up the nil result; serialization
;; pushes that checkpoint as a new frame after the command has returned.
;; The engine stack replaces DDSKK's recursive minibuffer depth and hooks.
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
(defun skk-henkan-in-minibuff ()
  (when (ddskk-engine--registration-active-p)
    (setq ddskk-engine--registration-pending
          (vector (skk-ime-session-snapshot ddskk-engine--session)
                  (skk-ime-session-checkpoint ddskk-engine--session)
                  skk-henkan-key)))
  nil)

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
    (setq skk-rule-tree (ddskk-engine--rule-tree))))

(defvar ddskk-engine--rule-tree-cache nil
  "Pre-built romaji rule tree, loaded from `skk-rule-tree-cache.el'.")

(defun ddskk-engine--rule-tree ()
  "Return the compiled romaji rule tree, from the generated cache if valid.

`skk-compile-rule-list' costs ~1.7-2.3s on this runtime and is the largest
single item left on the path the TSF host's first keystroke has to walk.
Its inputs are two constants, so `engine/gen-rule-tree.el' builds the tree
once and writes it out as data: measured 1.738s to build against 0.008s to
load, with the two trees `equal'.

The cache carries `sxhash-equal' of both input lists and is used only when
they still match -- `skk-rom-kana-rule-list' is a `defcustom', so the
premise that the inputs are constant is a claim about a particular
configuration, not about the program.  A cache whose inputs moved costs the time it was meant
to save and nothing else; it never yields a tree that does not match the
rules in force."
  (or skk-input-rules--tree
  (let ((cache-file (expand-file-name "engine/skk-rule-tree-cache.el")))
    (when (and (null ddskk-engine--rule-tree-cache)
               (file-exists-p cache-file))
      (load cache-file))
    (or (and ddskk-engine--rule-tree-cache
             (equal (plist-get ddskk-engine--rule-tree-cache :base-hash)
                    (sxhash-equal skk-rom-kana-base-rule-list))
             (equal (plist-get ddskk-engine--rule-tree-cache :extra-hash)
                    (sxhash-equal skk-rom-kana-rule-list))
             (plist-get ddskk-engine--rule-tree-cache :tree))
        (skk-compile-rule-list skk-rom-kana-base-rule-list
                               skk-rom-kana-rule-list)))))

(defvar ddskk-engine--session nil)
(defvar ddskk-engine--registration-stack nil
  "Innermost-first [CHECKPOINT READING HAD-CANDIDATES EDITOR] frames.")
(defvar ddskk-engine--registration-pending nil)
(defvar ddskk-engine--registration-learning nil)
(defconst ddskk-engine--registration-max-depth 8)
(defvar ddskk-engine--sessions (make-hash-table :test 'equal)
  "Client-scoped DDSKK states used by SESSION-prefixed native requests.")
(load "engine/session-v2.el")
(load "engine/conversion-hot-path.el")
(defvar ddskk-engine--active-session-id nil
  "Session whose native DDSKK globals are currently installed.")
(defvar ddskk-engine--active-session-prefix nil)
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
  (setq ddskk-engine--session nil
        ddskk-engine--registration-stack nil
        ddskk-engine--registration-pending nil))

(defconst ddskk-engine--hex-digits "0123456789abcdef"
  "Lowercase nibble table for `ddskk-engine--hex'.")

(defvar ddskk-engine--hex-cache (make-hash-table :test 'equal)
  "Bounded content cache for immutable scalar-hex wire encodings.")

(defun ddskk-engine--hex (string)
  "Encode STRING, reusing an encoding only for identical current content.
Copy keys because callers may later edit their input strings. The cache
contains no dictionary results and cannot hide a host dictionary update."
  (if (= (length string) 0) "-"
    (or (gethash string ddskk-engine--hex-cache)
        (let ((encoded (ddskk-engine--hex-uncached string)))
          (when (>= (hash-table-count ddskk-engine--hex-cache) 512)
            (clrhash ddskk-engine--hex-cache))
          (puthash (copy-sequence string) encoded ddskk-engine--hex-cache)
          encoded))))

(defun ddskk-engine--hex-uncached (string)
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

(defun ddskk-engine--unhex (hex)
  "Decode the six-hex-scalar wire representation, or return nil.
Registration is the only client-to-engine Unicode string request; keeping
it in this strict encoding prevents spaces, newlines and protocol tokens
from entering the line protocol."
  (when (and (stringp hex) (> (length hex) 0) (= (% (length hex) 6) 0))
    (let ((out "") (offset 0) (valid t))
      (while (< offset (length hex))
        ;; NeLisp's current `string-to-number' ignores its optional radix
        ;; argument.  Parsing "00004b" through it therefore yielded codepoint
        ;; 4, and the atomic Kana replay became control characters 4/6/0.
        ;; Accumulate the fixed six nibbles explicitly so this wire decoder is
        ;; identical under GNU Emacs and the standalone runtime.
        (let ((code 0) (digit 0))
          (while (< digit 6)
            (let* ((char (aref hex (+ offset digit)))
                   (nibble (cond ((and (>= char ?0) (<= char ?9)) (- char ?0))
                                 ((and (>= char ?a) (<= char ?f))
                                  (+ 10 (- char ?a)))
                                 (t -1))))
              (if (< nibble 0)
                  (setq valid nil digit 6)
                (setq code (+ (ash code 4) nibble)
                      digit (1+ digit)))))
          (if (or (> code #x10ffff) (and (>= code #xd800) (<= code #xdfff)))
              (setq valid nil)
            (when valid (setq out (concat out (string code))))))
        (setq offset (+ offset 6)))
      (and valid out))))

(defun ddskk-engine--decode-codepoints (encoded)
  "Decode comma-separated decimal Unicode scalars in ENCODED, or nil."
  (when (and (stringp encoded) (> (length encoded) 0)
             (/= (aref encoded (1- (length encoded))) ?,))
    (let ((start 0) (out "") (valid t) end)
      (while (and valid (< start (length encoded)))
        (setq end (or (string-match "," encoded start) (length encoded)))
        (if (= end start)
            (setq valid nil)
          (let ((index start) (code 0))
            (while (and valid (< index end))
              (let ((char (aref encoded index)))
                (if (or (< char ?0) (> char ?9))
                    (setq valid nil)
                  (setq code (+ (* code 10) (- char ?0))
                        index (1+ index)))))
            (if (or (> code #x10ffff)
                    (and (>= code #xd800) (<= code #xdfff)))
                (setq valid nil)
              (when valid (setq out (concat out (string code)))))))
        (setq start (1+ end)))
      (and valid out))))

(defvar ddskk-engine--utf8-wire nil)

(defun ddskk-engine--request-keys (line offset)
  "Decode legacy decimal keys, or negotiated UTF-8 keys already in LINE."
  (if (and ddskk-engine--utf8-wire
           (equal (substring line (- offset 5) offset) "UTF8 "))
      (substring line offset)
    (ddskk-engine--decode-codepoints (substring line offset))))

(defun ddskk-engine--utf8-field (text)
  "Frame TEXT by Unicode scalar count without walking its characters."
  (concat (number-to-string (length text)) ":" text))

(defun ddskk-engine--raw-state-line (state &optional registration-reading)
  "Return the wire STATE line for STATE.

Assembled with `concat' rather than one `format'.  Measured on this
runtime (slope method, 20 vs 120 iterations): `format' with these seven
directives costs 23.5 ms per call, while the whole `concat' below costs
1.8 ms -- roughly 136 us per argument.  This function runs on every
keystroke, so that difference is most of the per-key budget: the common
short-state line went from 28.7 ms to 9.8 ms.

Legacy STATE bytes are unchanged; negotiated STATE2 fields carry raw
UTF-8 for the host to translate back to the DLL-facing STATE format.
Every numeric field here is an
integer -- `skk-ime-session-snapshot' derives them from `point',
`marker-position' and `skk-henkan-count' -- so `number-to-string' and
%d agree; `%s' on a string and on `symbol-name' output is likewise the
identity.  `:candidates' is read once instead of twice."
  (let ((candidates (plist-get state :candidates)))
    (if ddskk-engine--utf8-wire
        (concat "STATE2 " (symbol-name (plist-get state :mode)) " "
                (number-to-string (plist-get state :cursor)) " "
                (number-to-string (or (plist-get state :composition-start) -1)) " "
                (number-to-string (or (plist-get state :candidate-index) -1)) " "
                (number-to-string (length candidates)) " "
                (if registration-reading "1" "0") "\n"
                (ddskk-engine--utf8-field (plist-get state :text))
                (ddskk-engine--utf8-field (plist-get state :pending-romaji))
                (mapconcat #'ddskk-engine--utf8-field candidates "")
                (if registration-reading
                    (ddskk-engine--utf8-field registration-reading) ""))
      (concat "STATE "
            (symbol-name (plist-get state :mode)) " "
            (number-to-string (plist-get state :cursor)) " "
            (number-to-string (or (plist-get state :composition-start) -1)) " "
            (ddskk-engine--hex (plist-get state :text)) " "
            (ddskk-engine--hex (plist-get state :pending-romaji)) " "
            (number-to-string (or (plist-get state :candidate-index) -1)) " "
            (if candidates
                (mapconcat #'ddskk-engine--hex candidates ",")
              "-")
            (if registration-reading
                (concat " " (ddskk-engine--hex registration-reading)) "")))))

;; CorvusSKK keeps dictionary registration inside the TIP rather than
;; focusing an ordinary edit control.  Mirror that architecture with a
;; checkpoint of the main DDSKK state.  The same session then accepts kana
;; input and nested conversion, and is restored before confirm/cancel.  This
;; is also compatible with NeLisp's current process-wide buffer-local table.
(defun ddskk-engine--registration-active-p ()
  (and ddskk-engine--registration-stack t))

(defun ddskk-engine--registration-state-line ()
  "Return the nine-field STATE extension used only during registration."
  (when ddskk-engine--registration-pending
    (let ((pending ddskk-engine--registration-pending))
      (setq ddskk-engine--registration-pending nil)
      (ddskk-engine--begin-registration
       (aref pending 0) (aref pending 1) (aref pending 2))))
  (let ((state (skk-ime-session-snapshot ddskk-engine--session)))
    ;; Keep the flush on the mandatory serialization path.  NeLisp's `if'
    ;; evaluator only retains one else expression on the KEY dispatch form,
    ;; so a side effect placed between feed-key and this serializer is lost.
    (ddskk-engine--registration-flush state)
    (setq state (skk-ime-session-snapshot ddskk-engine--session))
    (let* (
         (wire-state (copy-sequence state))
         (cursor (aref (aref (car ddskk-engine--registration-stack) 3) 1))
         (session-text (plist-get state :text))
         (editor-text (aref (aref (car ddskk-engine--registration-stack) 3) 0))
         (before (substring editor-text 0 cursor))
         (after (substring editor-text cursor))
         (start (plist-get state :composition-start)))
    (setq wire-state (plist-put wire-state :mode 'registration))
    (setq wire-state
          (plist-put wire-state :text (concat before session-text after)))
    (setq wire-state
          (plist-put wire-state :cursor
                     (+ cursor (plist-get state :cursor))))
    (when start
      (setq wire-state
            (plist-put wire-state :composition-start (+ cursor start))))
      (ddskk-engine--raw-state-line wire-state
                                    (aref (car ddskk-engine--registration-stack) 1)))))

(defun ddskk-engine--registration-flush (state)
  "Move finalized DDSKK text in STATE into the registration editor."
  (when (and (not (ddskk-engine--registration-composing-p state))
             (> (length (plist-get state :text)) 0))
    (let* ((cursor (aref (aref (car ddskk-engine--registration-stack) 3) 1))
           (editor-text (aref (aref (car ddskk-engine--registration-stack) 3) 0))
           (text (plist-get state :text))
           (new-text
            (concat (substring editor-text 0 cursor)
                    text
                    (substring editor-text cursor)))
           (new-cursor (+ cursor (length text))))
      ;; Clear only DDSKK's transient direct-input state here.  Calling the
      ;; full session reset from inside this function crosses another NeLisp
      ;; buffer scope and loses NEW-TEXT/NEW-CURSOR before they can be saved.
      (with-current-buffer (skk-ime-session-buffer ddskk-engine--session)
        (erase-buffer)
        (setq skk-prefix "" skk-current-rule-tree nil
              skk-kana-start-point nil skk-henkan-mode nil
              skk-henkan-start-point nil skk-henkan-end-point nil
              skk-henkan-key nil skk-henkan-list nil skk-henkan-count -1)
        (setf (skk-ime-session-last-command ddskk-engine--session) nil))
      (aset (aref (car ddskk-engine--registration-stack) 3) 0 new-text)
      (aset (aref (car ddskk-engine--registration-stack) 3) 1 new-cursor))))

(defun ddskk-engine--begin-registration (main-state &optional checkpoint reading-override)
  (let* ((saved (or checkpoint
                    (skk-ime-session-checkpoint ddskk-engine--session)))
         (native-state (plist-get saved :native-state))
         (reading (cdr (assq 'skk-henkan-key native-state)))
         (candidates (cdr (assq 'skk-henkan-list native-state))))
    (push (vector saved
                  (if (and (stringp reading-override)
                           (> (length reading-override) 0))
                      reading-override (if (stringp reading) reading ""))
                  (and (listp candidates) (> (length candidates) 0))
                  (vector "" 0))
          ddskk-engine--registration-stack)
    (if (> (length ddskk-engine--registration-stack)
           ddskk-engine--registration-max-depth)
        (ddskk-engine--cancel-registration)
      (progn
        (skk-ime-session-reset ddskk-engine--session)
        (ddskk-engine--registration-state-line)))))

(defun ddskk-engine--phase (name)
  "Emit a phase boundary for host wall-clock timing, never runtime clocks."
  (when (getenv "DDSKK_PHASE_TRACE")
    (nelisp--write-stdout-bytes (concat "PHASE " name "\n"))))

(defun ddskk-engine--romaji-walk (node)
  "Flatten a compiled NODE into wire records without local functions."
  (let* ((key (nth 1 node)) (carry (nth 2 node)) (output (nth 3 node))
         (action (and (symbolp output) output)) records)
    (when output
      (when (eq output 'skk-auto-kutouten)
        (setq last-command-event (aref key (1- (length key))))
        (setq output (skk-auto-kutouten nil) action nil))
      (push (mapconcat #'ddskk-engine--hex
                       (list key (or carry "")
                             (cond ((stringp output) output)
                                   ((consp output) (cdr output)) (t ""))
                             (cond ((stringp output) output)
                                   ((consp output) (car output)) (t ""))
                             (if action (symbol-name action) "")) ":") records))
    (dolist (child (nth 4 node))
      (setq records (append records (ddskk-engine--romaji-walk child))))
    records))

(defun ddskk-engine--romaji-rules ()
  "Export the effective compiled tree, including command leaves, as RULES 1.
Fields are scalar hex: key, carry, hiragana, katakana, command.  Command
leaves remain engine-owned; punctuation is resolved in the current buffer."
  (let ((last-command-event (if (boundp 'last-command-event)
                                last-command-event nil)))
    (skk-ime-session--with-buffer ddskk-engine--session
      (skk-input-rules-export (ddskk-engine--rule-tree)))))

(defun ddskk-engine--convert-or-register (&optional before-state prepared-checkpoint)
  "Convert once, preserving a zero-result reading for native registration."
  (let* ((before (or before-state
                     (skk-ime-session-snapshot ddskk-engine--session)))
         (checkpoint (or prepared-checkpoint (progn
                       (ddskk-engine--phase "checkpoint-begin")
                       (prog1 (skk-ime-session-checkpoint ddskk-engine--session)
                         (ddskk-engine--phase "checkpoint-end")))))
         (start (plist-get before :composition-start))
         (text (plist-get before :text))
         (reading (if (and (numberp start) (>= start 0)
                           (stringp text) (<= start (length text)))
                      (substring text start)
                    ""))
         (state (progn
                  (ddskk-engine--phase "convert-begin")
                  (prog1 (skk-ime-session-control ddskk-engine--session 'convert)
                    (ddskk-engine--phase "convert-end")))))
    (setq ddskk-engine--prepared-state state)
    ;; Current DDSKK cleans a missing first conversion back to an empty
    ;; hiragana state after the noninteractive minibuffer stub returns nil.
    ;; Older builds left a candidate state with an empty list, which
    ;; `ddskk-engine--state-line' already detects. Cover both behaviours.
    (if ddskk-engine--registration-pending
        (ddskk-engine--registration-state-line)
      (if (and (eq (plist-get before :mode) 'preedit)
             (> (length reading) 0)
             (eq (plist-get state :mode) 'hiragana)
             (= (length (plist-get state :text)) 0)
             (= (length (plist-get state :pending-romaji)) 0))
        (ddskk-engine--begin-registration before checkpoint reading)
      (ddskk-engine--state-line state)))))

(defun ddskk-engine--candidates-exhausted-p (state)
  "Return non-nil when STATE has moved beyond its final candidate.

DDSKK keeps `skk-henkan-list' intact after the last SPC and advances
`skk-henkan-count' one position past that list.  Testing only for an empty
candidate list therefore catches a missing reading's first conversion but
misses exhaustion after one or more real candidates."
  (let ((candidates (plist-get state :candidates))
        (index (plist-get state :candidate-index)))
    (and (eq (plist-get state :mode) 'candidate)
         (or (null candidates)
             (and (numberp index) (>= index (length candidates)))))))

(defun ddskk-engine--state-line (state)
  "Encode STATE, entering CorvusSKK-style registration on exhaustion."
  (cond
   ((ddskk-engine--registration-active-p)
    (ddskk-engine--registration-state-line))
   ((ddskk-engine--candidates-exhausted-p state)
    (ddskk-engine--begin-registration state))
   (t (ddskk-engine--raw-state-line state))))

(defun ddskk-engine--registration-composing-p (state)
  (or (plist-get state :composition-start)
      (> (length (plist-get state :pending-romaji)) 0)))

(defun ddskk-engine--end-registration ()
  (setq ddskk-engine--registration-stack nil
        ddskk-engine--registration-pending nil))

(defun ddskk-engine--registration-return-state (state)
  (if (ddskk-engine--registration-active-p)
      (ddskk-engine--registration-state-line)
    (ddskk-engine--raw-state-line state)))

(defun ddskk-engine--cancel-registration ()
  (let* ((frame (pop ddskk-engine--registration-stack))
         (checkpoint (aref frame 0))
         (had-candidates (aref frame 2)))
    (skk-ime-session-restore ddskk-engine--session checkpoint)
    (if had-candidates
        ;; Stock cancellation of an exhausted prompt selects the previous
        ;; candidate, rather than turning the candidate word into a reading.
        (ddskk-engine--registration-return-state
         (skk-ime-session-control ddskk-engine--session 'previous))
      (progn
        ;; A miss restores the reading. Keep the native marker-safe transition:
        ;; full DDSKK inactivation duplicates text with NeLisp's static markers.
        (with-current-buffer (skk-ime-session-buffer ddskk-engine--session)
          (let* ((marker-pos (and (or (numberp skk-henkan-start-point)
                                     (markerp skk-henkan-start-point))
                                  (marker-position skk-henkan-start-point)))
                 (marker-char-pos
                  (max (point-min) (1- (or marker-pos (1+ (point-min)))))))
            (delete-region marker-char-pos (1+ marker-char-pos))
            (goto-char marker-char-pos)
            (insert "▽")
            (setq skk-henkan-mode 'on skk-henkan-count -1
                  skk-henkan-list nil skk-current-search-prog-list nil)
            (skk-set-marker skk-henkan-start-point (1+ marker-char-pos))
            (goto-char (point-max))))
        (ddskk-engine--registration-return-state
         (skk-ime-session-snapshot ddskk-engine--session))))))

(defun ddskk-engine--finish-registration (word)
  (let* ((frame (pop ddskk-engine--registration-stack))
         (checkpoint (aref frame 0))
         (okuri (cdr (assq 'skk-henkan-okurigana
                           (plist-get checkpoint :native-state)))))
    (skk-ime-session-restore ddskk-engine--session checkpoint)
    (let ((state (skk-ime-session-control ddskk-engine--session
                                           'register-and-commit word)))
      (setq ddskk-engine--registration-learning
            (concat "REGISTRATION-LEARNED " (ddskk-engine--hex word) " "
                    (ddskk-engine--hex (if (stringp okuri) okuri ""))
                    " -1 - " (ddskk-engine--hex (aref frame 1))))
      (if (ddskk-engine--registration-active-p)
          (progn
            (when (and (stringp okuri) (> (length okuri) 0))
              (with-current-buffer (skk-ime-session-buffer ddskk-engine--session)
                (goto-char (point-max))
                (insert okuri)))
            (ddskk-engine--registration-state-line))
        (ddskk-engine--raw-state-line state)))))

(defun ddskk-engine--registration-edit (control)
  "Edit the idle registration buffer at its own cursor."
  (let ((cursor (aref (aref (car ddskk-engine--registration-stack) 3) 1))
        (text (aref (aref (car ddskk-engine--registration-stack) 3) 0)))
    (pcase control
      ('backspace
       (when (> cursor 0)
         (setq text (concat (substring text 0 (1- cursor))
                            (substring text cursor))
               cursor (1- cursor))))
      ('delete
       (when (< cursor (length text))
         (setq text (concat (substring text 0 cursor)
                            (substring text (1+ cursor))))))
      ('left (when (> cursor 0) (setq cursor (1- cursor))))
      ('right (when (< cursor (length text)) (setq cursor (1+ cursor))))
      ('home (setq cursor 0))
      ('end (setq cursor (length text)))
      ('space
       (setq text (concat (substring text 0 cursor) " "
                          (substring text cursor))
             cursor (1+ cursor))))
    (aset (aref (car ddskk-engine--registration-stack) 3) 0 text)
    (aset (aref (car ddskk-engine--registration-stack) 3) 1 cursor)
    (skk-ime-session-snapshot ddskk-engine--session)))

(defun ddskk-engine--registration-request-p (line)
  (or (string-match "\\`KEY " line)
      (string-match "\\`CONTROL " line)
      (string-match "\\`REGISTER " line)))

(defun ddskk-engine--registration-feed-key (key)
  (if (= key 32)
      (ddskk-engine--dispatch-registration "CONTROL CONVERT")
    (progn
      (skk-ime-session-feed-key ddskk-engine--session key)
      (ddskk-engine--registration-state-line))))

(defun ddskk-engine--dispatch-registration (line)
  "Handle one protocol LINE while the registration sub-session is active."
  (condition-case err
       (let ((state (skk-ime-session-snapshot
                    ddskk-engine--session)))
        (cond
         ((string-match "\\`REGISTER \\([0-9a-f]+\\)\\'" line)
          (let ((word (ddskk-engine--unhex (match-string 1 line))))
            (if (and word (> (length word) 0))
                (ddskk-engine--finish-registration word)
              (ddskk-engine--cancel-registration))))
         ((string-match "\\`KEY \\([0-9]+\\)\\'" line)
          (let ((codepoint (string-to-number (match-string 1 line))))
            (if (or (< codepoint 0) (> codepoint 1114111))
                "ERR CODEPOINT"
              (ddskk-engine--registration-feed-key codepoint))))
         ((and (> (length line) 18)
               (or (equal (substring line 0 18) "CONTROL FEED-KEYS ")
                   (and ddskk-engine--utf8-wire
                        (equal (substring line 0 18) "CONTROL FEED-UTF8 "))))
          (let ((keys (ddskk-engine--request-keys line 18)))
            (if (not keys)
                "ERR FEED-KEYS"
              (progn
                (dolist (key (string-to-list keys))
                  (ddskk-engine--registration-feed-key key))
                (ddskk-engine--registration-state-line)))))
         ((equal line "CONTROL COMMIT")
          ;; Stock exit-minibuffer confirms the inner conversion and exits
          ;; on the same RET (the default skk-egg-like-newline is nil).
          (when (ddskk-engine--registration-composing-p state)
            (skk-ime-session-control ddskk-engine--session 'commit))
          (ddskk-engine--registration-flush
           (skk-ime-session-snapshot ddskk-engine--session))
          (let ((word (aref (aref (car ddskk-engine--registration-stack) 3) 0)))
            (if (or (= (length word) 0)
                    (string-match "\\`[ \\t\\r\\n]+\\'" word))
                (ddskk-engine--cancel-registration)
              (ddskk-engine--finish-registration word))))
         ((or (equal line "CONTROL QUIT") (equal line "CONTROL CANCEL"))
          ;; Like DDSKK's abort-recursive-edit advice: unwind the nested
          ;; candidate/reading/prefix before leaving the registration editor.
          (if (ddskk-engine--registration-composing-p state)
              (progn
                (skk-ime-session-control ddskk-engine--session 'quit)
                (ddskk-engine--registration-state-line))
            (ddskk-engine--cancel-registration)))
         ((equal line "CONTROL BACKSPACE")
          (if (ddskk-engine--registration-composing-p state)
              (skk-ime-session-control
               ddskk-engine--session 'backspace)
            (ddskk-engine--registration-edit 'backspace))
          (ddskk-engine--registration-state-line))
         ((equal line "CONTROL CONVERT")
          (if (ddskk-engine--registration-composing-p state)
              (ddskk-engine--convert-or-register state)
            (progn
              (ddskk-engine--registration-edit 'space)
              (ddskk-engine--registration-state-line))))
         ((equal line "CONTROL PREVIOUS")
          (when (ddskk-engine--registration-composing-p state)
            (skk-ime-session-control
             ddskk-engine--session 'previous))
          (ddskk-engine--registration-state-line))
         ((equal line "CONTROL LEFT")
          (ddskk-engine--registration-edit 'left)
          (ddskk-engine--registration-state-line))
         ((equal line "CONTROL RIGHT")
          (ddskk-engine--registration-edit 'right)
          (ddskk-engine--registration-state-line))
         ((equal line "CONTROL HOME")
          (ddskk-engine--registration-edit 'home)
          (ddskk-engine--registration-state-line))
         ((equal line "CONTROL END")
          (ddskk-engine--registration-edit 'end)
          (ddskk-engine--registration-state-line))
         ((equal line "CONTROL DELETE")
          (ddskk-engine--registration-edit 'delete)
          (ddskk-engine--registration-state-line))
         ((equal line "CONTROL TO-HIRAGANA")
          (skk-ime-session-control
           ddskk-engine--session 'to-hiragana)
          (ddskk-engine--registration-state-line))
         ((equal line "CONTROL TO-KATAKANA")
          (skk-ime-session-control
           ddskk-engine--session 'to-katakana)
          (ddskk-engine--registration-state-line))
         (t "ERR REGISTRATION REQUEST")))
    (error (ddskk-engine--error-token "ERR REGISTRATION" err))))

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

(defun ddskk-engine--dispatch-line-1 (line)
  (ddskk-engine-start)
  (cond
   ((and (ddskk-engine--registration-active-p)
         (ddskk-engine--registration-request-p line))
    (ddskk-engine--dispatch-registration line))
   ((and (> (length line) 21)
         (or (equal (substring line 0 21) "CONTROL CONVERT-KEYS ")
             (and ddskk-engine--utf8-wire
                  (equal (substring line 0 21) "CONTROL CONVERT-UTF8 "))))
    ;; Native real-time input keeps ordinary romaji off the NeLisp critical
    ;; path.  At the conversion barrier replay the exact DDSKK key sequence
    ;; into a clean session and start conversion atomically, so no other
    ;; client can observe or interleave the intermediate states.
    ;; Do not use `string-match' here.  The standalone NeLisp regexp shim
    ;; does not implement Emacs' \\`/\\' anchors and silently failed to
    ;; recognize this otherwise-valid request in the real stdio runner.
    (let ((keys (ddskk-engine--request-keys line 21)))
      (if (not keys) "ERR CONVERT-KEYS"
        (condition-case err
            (progn
              (ddskk-engine--phase "replay-begin")
              (skk-ime-session-reset ddskk-engine--session t)
              (let ((state (skk-ime-session-feed-string
                            ddskk-engine--session keys)))
                (ddskk-engine--phase "replay-end")
                ;; Okuri-ari conversion starts automatically when its final
                ;; kana resolves.  A second CONVERT here advances past that
                ;; fresh candidate (and a one-candidate entry immediately
                ;; exhausts into registration).  Preserve the automatic
                ;; result; only an ordinary ▽ reading needs explicit convert.
                (if (memq (plist-get state :mode) '(candidate registration))
                    (ddskk-engine--state-line state)
                  (ddskk-engine--convert-or-register state))))
          (error (ddskk-engine--error-token "ERR CONVERT-KEYS" err))))))
    ((equal line "HELLO 1") "OK 1")
   ((equal line "ROMAJI RULES 1") (ddskk-engine--romaji-rules))
   ((and (> (length line) 22)
         (or (equal (substring line 0 22) "CONTROL REGISTER-KEYS ")
             (equal (substring line 0 22) "CONTROL REGISTER-UTF8 ")))
    (let ((keys (ddskk-engine--request-keys line 22)))
      (if (not keys) "ERR REGISTER-KEYS"
        (skk-ime-session-reset ddskk-engine--session t)
        (ddskk-engine--begin-registration
         (skk-ime-session-feed-string ddskk-engine--session keys)))))
   ((and (> (length line) 18)
         (or (equal (substring line 0 18) "CONTROL SYNC-KEYS ")
             (and ddskk-engine--utf8-wire
                  (equal (substring line 0 18) "CONTROL SYNC-UTF8 "))))
    (let ((keys (ddskk-engine--request-keys line 18)))
      (if (not keys) "ERR SYNC-KEYS"
        (condition-case err
            (progn
              (skk-ime-session-reset ddskk-engine--session)
              (ddskk-engine--state-line
               (skk-ime-session-feed-string ddskk-engine--session keys)))
          ;; DDSKK rejects / while already in ▽. Preserve its unchanged
          ;; reading rather than treating a normal command error as EOF.
          (error (ddskk-engine--safe-state-line))))))
   ((equal line "ENGINE LIST") "ENGINES ddskk passthrough")
   ((equal line "ENGINE CURRENT")
    (concat "ENGINE " native-ime-engine-id))
   ((equal line "ENGINE SET ddskk")
    (ddskk-engine--end-registration)
    (skk-ime-session-reset ddskk-engine--session)
    (setq native-ime-engine-id "ddskk") "OK ENGINE ddskk")
   ((equal line "ENGINE SET passthrough")
    (ddskk-engine--end-registration)
    (skk-ime-session-reset ddskk-engine--session)
    (setq native-ime-engine-id "passthrough") "OK ENGINE passthrough")
   ((equal line "RESET")
    (ddskk-engine--end-registration)
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
        (ddskk-engine--convert-or-register)
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
   ((string-match "\\`REGISTER \\([0-9a-f]+\\)\\'" line)
    (let ((candidate (ddskk-engine--unhex (match-string 1 line))))
      (if (not candidate) "ERR REGISTER"
        (condition-case err
            (ddskk-engine--state-line
             (skk-ime-session-control ddskk-engine--session
                                      'register-and-commit candidate))
          (error (ddskk-engine--error-token "ERR REGISTER" err))))))
   ((equal line "CONTROL TO-HIRAGANA")
    (condition-case err
        (ddskk-engine--state-line
         (skk-ime-session-control ddskk-engine--session 'to-hiragana))
      (error (ddskk-engine--error-token "ERR TO-HIRAGANA" err))))
   ((equal line "CONTROL TO-KATAKANA")
    (condition-case err
        (ddskk-engine--state-line
         (skk-ime-session-control ddskk-engine--session 'to-katakana))
      (error (ddskk-engine--error-token "ERR TO-KATAKANA" err))))
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

(defun ddskk-engine--session-id-valid-p (session-id)
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

(defun ddskk-engine--session-record (session-id)
  "Return SESSION-ID's mutable state record, creating it when absent."
  (or (gethash session-id ddskk-engine--sessions)
      (progn
        (ddskk-engine--evict-session)
        (let* ((session (skk-ime-session-create))
             ;; NeLisp's current buffer-local table is process-wide.  Keep a
             ;; full DDSKK checkpoint per client and restore it whenever the
             ;; active client changes; separate buffer objects alone do not
             ;; isolate the mode/prefix/marker variables in this runtime.
             (record (vector session nil nil nil nil
                             (skk-ime-session-checkpoint session) nil 0 nil nil nil nil)))
        (puthash session-id record ddskk-engine--sessions)
        record))))

(defun ddskk-engine--dispatch-session-line (session-id line)
  "Dispatch LINE with every mutable DDSKK field scoped to SESSION-ID."
  (if (equal line "CLOSE")
      (let ((record (gethash session-id ddskk-engine--sessions)))
        (when record
          (skk-ime-session-destroy (aref record 0))
          (remhash session-id ddskk-engine--sessions))
        (when (equal session-id ddskk-engine--active-session-id)
          (setq ddskk-engine--active-session-id nil))
        "OK CLOSED")
    ;; NeLisp's buffer-local table is process-wide, but switching its full
    ;; DDSKK checkpoint on EVERY key makes registration/candidate traversal
    ;; hundreds of milliseconds slower.  Save/restore only at the actual
    ;; client boundary; consecutive requests from one application then run
    ;; on the already-installed state exactly as the old singleton did.
    (unless (equal session-id ddskk-engine--active-session-id)
      (when ddskk-engine--active-session-id
        (let ((old (gethash ddskk-engine--active-session-id
                            ddskk-engine--sessions)))
          (when old
            (aset old 5 (skk-ime-session-checkpoint (aref old 0))))))
      (let ((next (ddskk-engine--session-record session-id)))
        (skk-ime-session-restore (aref next 0) (aref next 5)))
      (setq ddskk-engine--active-session-id session-id
            ddskk-engine--active-session-prefix (concat "SESSION " session-id " ")))
    (let* ((record (ddskk-engine--session-record session-id))
           (ddskk-engine--session (aref record 0))
           (ddskk-engine--registration-stack (aref record 1))
           (ddskk-engine--registration-pending nil)
           (ddskk-engine--registration-learning
            (and (equal line "REGISTRATION-LEARNING") (aref record 11)))
           (ddskk-engine--prepared-keys (aref record 6))
           (ddskk-engine--prepared-state (aref record 10))
           response)
      (setq ddskk-engine--session-clock (1+ ddskk-engine--session-clock))
      (aset record 7 ddskk-engine--session-clock)
      (unwind-protect
          (setq response
                (cond
                 ((equal line "OPEN 2") (aset record 8 t) "OK OPEN 2")
                 ((equal line "REGISTRATION-LEARNING")
                  (prog1 (or ddskk-engine--registration-learning "OK NONE")
                    (setq ddskk-engine--registration-learning nil)))
                 ((equal line "SPACE 2")
                  (if (ddskk-engine--registration-active-p)
                      (ddskk-engine--registration-state-line)
                  (if (not ddskk-engine--prepared-keys) "ERR SESSION NOT PREPARED"
                    (let ((state (or ddskk-engine--prepared-state
                                     (skk-ime-session-snapshot ddskk-engine--session))))
                      (if (memq (plist-get state :mode) '(candidate registration))
                          (ddskk-engine--state-line state)
                        (ddskk-engine--convert-or-register state (aref record 9)))))))
                 ((or (and (> (length line) 10)
                           (equal (substring line 0 10) "PREPARE 2 "))
                      (and (> (length line) 15)
                           (equal (substring line 0 15) "CONVERT-LIVE 2 ")))
                  (prog1 (ddskk-engine--dispatch-v2 line)
                    ;; Preparation pays for the modal recovery checkpoint once.
                    ;; SPACE consumes it without recapturing 50+ native globals.
                    (aset record 9 (skk-ime-session-checkpoint ddskk-engine--session))))
                 (t
                  ;; Commands after preparation own the authoritative live
                  ;; state. Do not mistake a later identical raw reading for
                  ;; an unchanged prepared state after cancel/commit/edit.
                  (unless (member line '("HELLO 1" "STATUS"))
                    (setq ddskk-engine--prepared-keys nil ddskk-engine--prepared-state nil)
                    (aset record 9 nil))
                  (ddskk-engine--dispatch-line-1 line))))
        (aset record 0 ddskk-engine--session)
        (aset record 1 ddskk-engine--registration-stack)
        (aset record 11 ddskk-engine--registration-learning)
        (aset record 6 ddskk-engine--prepared-keys)
        (aset record 10 ddskk-engine--prepared-state))
      response)))

(defun ddskk-engine-dispatch-line (line)
  "Dispatch legacy LINE or a client-scoped `SESSION ID LINE' request."
  ;; Metadata must not create or activate a legacy editing session. The
  ;; host fetches this once at startup and after replacement publication.
  (cond
   ((equal line "WIRE LEARNING 2")
    (setq ddskk-engine--learning-worker t)
    "OK WIRE LEARNING 2")
   ((equal line "WIRE UTF8 1")
    (setq ddskk-engine--utf8-wire t)
    "OK WIRE UTF8 1")
   ((equal line "ROMAJI RULES 1") (ddskk-engine--romaji-rules))
   ((equal line "DIAG SESSION-COUNT")
      (concat "SESSIONS " (number-to-string
                           (hash-table-count ddskk-engine--sessions))))
   ((and (> (length line) 6) (equal (substring line 0 6) "LOCAL "))
    (ddskk-local-dispatch line))
   ((and (> (length line) 8)
         (equal (substring line 0 8) "SESSION "))
      (let ((separator
             (if (and ddskk-engine--active-session-prefix
                      (>= (length line) (length ddskk-engine--active-session-prefix))
                      (equal ddskk-engine--active-session-prefix
                             (substring line 0 (length ddskk-engine--active-session-prefix))))
                 (1- (length ddskk-engine--active-session-prefix))
               (string-match " " line 8))))
        (if (not separator)
            "ERR SESSION"
          (let ((session-id (substring line 8 separator))
                (request (substring line (1+ separator))))
            (if (or (not (or (gethash session-id ddskk-engine--sessions)
                             (ddskk-engine--session-id-valid-p session-id)))
                    (= (length request) 0))
                "ERR SESSION"
              (if (and (> (length request) 3)
                       (equal (substring request 0 3) "V2 "))
                  (if (and (gethash session-id ddskk-engine--sessions)
                           (aref (gethash session-id ddskk-engine--sessions) 8))
                      (ddskk-engine--dispatch-session-line
                       session-id (substring request 3))
                    "ERR SESSION LOST")
                (ddskk-engine--dispatch-session-line session-id request)))))))
   (t (ddskk-engine--dispatch-session-line "legacy" line))))

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

(defun ddskk-engine--learning-metadata (line)
  "Serialize only the operation identity changed by this transaction."
  (if (and (> (length line) 12) (equal (substring line 0 12) "LOCAL LEARN "))
      (let* ((id (nth 2 (split-string line " " t)))
             (client (car (split-string id "\\.")))
             (watermark (gethash client ddskk-local-operations)))
        (if watermark
            (concat ";; local-ack " client " " (number-to-string (car watermark))
                    " " (number-to-string (cdr watermark)) "\n")
          ""))
    ""))

(defun ddskk-engine-dispatch-line-to-stdout (line)
  (let ((response (ddskk-engine-dispatch-line line)))
    ;; Duplicate LOCAL operation ids must retry a failed native publication.
    (when (and ddskk-engine--learning-worker
               (or ddskk-engine--learning-dirty
                   (and (> (length line) 12)
                        (equal (substring line 0 12) "LOCAL LEARN ")
                        (equal (substring response 0 (min 4 (length response))) "ACK "))))
      (when (and (not ddskk-engine--learning-keys)
                 (> (length line) 12) (equal (substring line 0 12) "LOCAL LEARN "))
        (let ((key (ddskk-engine--unhex (nth 3 (split-string line " " t)))))
          (when key (setq ddskk-engine--learning-keys (list key)))))
      (ddskk-engine--phase "learning-checkpoint-begin")
      (let ((content
             (if ddskk-engine--learning-keys
                 (let (ari nasi)
                   (dolist (key ddskk-engine--learning-keys)
                     (if (eq (or (gethash key ddskk-user-jisyo--sections)
                                 (if (ddskk-user-jisyo--okuri-ari-p key) 'ari 'nasi)) 'ari)
                         (push (cons key (gethash key ddskk-user-jisyo--table)) ari)
                       (push (cons key (gethash key ddskk-user-jisyo--table)) nasi)))
                   (concat ";; EG2 delta v2\n;; EG2 revision "
                           (number-to-string ddskk-user-jisyo-local-revision) "\n"
                           (ddskk-engine--learning-metadata line)
                           ";; okuri-ari entries.\n" (ddskk-user-jisyo--serialize-entries ari)
                           ";; okuri-nasi entries.\n" (ddskk-user-jisyo--serialize-entries nasi)))
               (concat ";; EG2 checkpoint v2\n" (ddskk-user-jisyo--serialize)))))
        (nelisp--write-stdout-bytes
         (concat "LEARNING2 " (number-to-string (length content)) "\n" content "\n")))
      (ddskk-engine--phase "learning-checkpoint-end")
      (setq ddskk-engine--learning-dirty nil ddskk-engine--learning-keys nil))
    (ddskk-engine-write-response response)))

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
    (if (and ddskk-engine--utf8-wire (> count 4)
             (equal (substring reply 0 5) "LIST "))
        (condition-case nil
            (let ((candidates (read (substring reply 5))))
              (and (listp candidates)
                   (cl-every #'stringp candidates)
                   (ddskk-user-jisyo--clean-candidates candidates)))
          (error nil))
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
        (ddskk-user-jisyo--clean-candidates (nreverse candidates)))))))

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
(load "engine/skk-local-conversion.el")

(ddskk-engine-start)
