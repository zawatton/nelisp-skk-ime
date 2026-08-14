;;; skk-nelisp-compat.el --- DDSKK adapter for standalone NeLisp -*- lexical-binding: t; -*-

;; This file is part of Daredevil SKK.

;;; Commentary:

;; Standalone NeLisp deliberately exposes its independent gap buffer through
;; `nelisp-*' names.  DDSKK uses the Emacs buffer API.  This adapter maps the
;; small synchronous input-engine surface onto NeLisp without copying any SKK
;; rules or conversion logic.  It is inert on GNU Emacs.

;;; Code:

(declare-function nelisp-buffer-list "../nelisp/src/nelisp-buffer")
(declare-function nelisp-buffer-name "../nelisp/src/nelisp-buffer")
(declare-function nelisp-current-buffer "../nelisp/src/nelisp-buffer")
(declare-function nelisp-set-marker "../nelisp/src/nelisp-buffer")
(declare-function nelisp-copy-marker "../nelisp/src/nelisp-buffer")

(when (and (fboundp 'nelisp-generate-new-buffer)
           (not (fboundp 'point)))
  (defalias 'generate-new-buffer 'nelisp-generate-new-buffer)
  (defalias 'kill-buffer 'nelisp-kill-buffer)
  (defalias 'current-buffer 'nelisp-current-buffer)
  (defalias 'set-buffer 'nelisp-set-buffer)
  (defalias 'point 'nelisp-point)
  (defalias 'point-min 'nelisp-point-min)
  (defalias 'point-max 'nelisp-point-max)
  (defalias 'goto-char 'nelisp-goto-char)
  (defalias 'insert 'nelisp-insert)
  (defalias 'insert-and-inherit 'nelisp-insert)
  (defalias 'erase-buffer 'nelisp-erase-buffer)
  (defalias 'delete-region 'nelisp-delete-region)
  (defalias 'buffer-string 'nelisp-buffer-string)
  (defalias 'buffer-substring-no-properties 'nelisp-buffer-substring)

  ;; Buffer predicates / position primitives DDSKK's SPACE-conversion
  ;; (skk-start-henkan -> skk-henkan -> skk-change-marker) and kakutei
  ;; (skk-kakutei -> skk-kakutei-cleanup-buffer -> skk-delete-henkan-markers)
  ;; paths reach right after the boundary guards.  `skk-nelisp--pos' is
  ;; used below even though it is defined later in this file (near the end,
  ;; after `self-insert-command'): these are plain `defun's, and by the
  ;; time any of the functions below are actually CALLED, the whole
  ;; enclosing `when' has finished loading, so the forward reference
  ;; resolves fine.
  ;;
  ;; NOTE on `bolp': the task that produced this edit asserted `bolp' is
  ;; already defined in engine/ddskk-engine.el and told this file
  ;; not to duplicate it.  That assertion does not hold: grepping
  ;; engine/ddskk-engine.el (264 lines, pure protocol
  ;; dispatch/hex/state-line code) finds no `bolp' definition at all, nor
  ;; does any other file under dev/ddskk-test define it -- its only
  ;; appearances anywhere in this tree are call sites in skk.el,
  ;; experimental/skk-dinsert.el and maint/install-info.el.  None of
  ;; those call sites are reachable from skk-start-henkan or skk-kakutei
  ;; (they're in skk-backward-and-set-henkan-point, a sibling command on
  ;; a different key), so it is not required to unblock the CONVERT/COMMIT
  ;; errors this change targets, and per the explicit "do NOT duplicate
  ;; it here" instruction it is intentionally left undefined in this
  ;; file.  Flagging this prominently rather than silently complying with
  ;; a premise that inspection shows is false: `bolp' will still be
  ;; void-function if/when `skk-backward-and-set-henkan-point' runs.

  (defun eobp ()
    "Return non-nil when point is at the end of the accessible buffer text."
    (= (nelisp-point) (nelisp-point-max)))

  (defun bobp ()
    "Return non-nil when point is at the beginning of the accessible buffer text."
    (= (nelisp-point) (nelisp-point-min)))

  (defun looking-at (regexp)
    "Return non-nil when text at point matches REGEXP.
Anchors REGEXP at point by matching against the buffer text from point
forward; the runtime has no buffer-aware search, only `string-match'
over strings.

This sets match data as a side effect of the underlying `string-match'
call, exactly like real `looking-at' does -- but because the match runs
against the extracted TAIL substring rather than the buffer itself,
`match-beginning'/`match-end' read afterwards are offsets into TAIL
\(0 = point), NOT absolute buffer positions.  Checked against every
caller reachable from `skk-start-henkan'/`skk-kakutei'
\(`skk-change-marker', `skk-delete-henkan-markers', `skk-what-char-type'):
none of them read match-data after calling `looking-at', they only test
its return value, so this divergence is safe on that path today.  A
caller that started reading `match-beginning'/`match-end' after
`looking-at' would get TAIL-relative, not buffer-relative, numbers and
must be fixed at the call site -- do not silently paper over that here."
    (let ((tail (nelisp-buffer-substring (nelisp-point) (nelisp-point-max))))
      (eq 0 (string-match regexp tail))))

  (defun looking-back (regexp &optional limit _greedy)
    "Return non-nil when the text ending at point matches REGEXP.
LIMIT bounds how far back a match may start (default `point-min').
GREEDY is accepted for signature compatibility but not honored: this
scans start offsets from LIMIT forward and accepts the first (i.e.
longest) match whose end lands exactly at point, rather than
replicating Emacs' exact non-greedy-vs-greedy selection rule.
No caller reachable from `skk-start-henkan'/`skk-kakutei' calls this
today -- grepping skk.el finds only a commented-out mention at
skk.el:4555 (`;(looking-back \">\")') -- so this is a best-effort
implementation, not a verified port; re-check it if a real caller
appears."
    (let* ((end (nelisp-point))
           (start (skk-nelisp--pos (or limit (nelisp-point-min))))
           (head (nelisp-buffer-substring start end))
           (len (length head))
           (i 0)
           (found nil))
      (while (and (not found) (<= i len))
        (when (and (eq (string-match regexp head i) i)
                   (eq (match-end 0) len))
          (setq found t))
        (setq i (1+ i)))
      found))

  (defun char-after (&optional position)
    "Return the character at POSITION (default point), or nil past the end.
POSITION may be an integer or a marker."
    (let ((pos (if position (skk-nelisp--pos position) (nelisp-point))))
      (and (>= pos (nelisp-point-min))
           (< pos (nelisp-point-max))
           (aref (nelisp-buffer-substring pos (1+ pos)) 0))))

  (defun char-before (&optional position)
    "Return the character before POSITION (default point), or nil at the start.
POSITION may be an integer or a marker."
    (let ((pos (if position (skk-nelisp--pos position) (nelisp-point))))
      (and (> pos (nelisp-point-min))
           (<= pos (nelisp-point-max))
           (aref (nelisp-buffer-substring (1- pos) pos) 0))))

  (defun forward-char (&optional n)
    "Move point forward N characters (default 1).
Clamped to the accessible region via `nelisp-goto-char' rather than
signalling `end-of-buffer' the way real Emacs does; sufficient here
because `skk-henkan' (the only convert/commit-path caller) already
guards its own call with `(unless (eobp) ...)' before reaching this."
    (nelisp-goto-char (+ (nelisp-point) (or n 1)))
    nil)

  (defun backward-char (&optional n)
    "Move point backward N characters (default 1).
See `forward-char' for the clamp-instead-of-signal rationale."
    (nelisp-goto-char (- (nelisp-point) (or n 1)))
    nil)

  ;; `delete-char' is not in the original request but is added here: it
  ;; is void-function on the very next step of both paths this change
  ;; targets -- `skk-change-marker' (CONVERT) and
  ;; `skk-delete-henkan-markers' (COMMIT, via
  ;; `skk-kakutei-cleanup-buffer') both call `(delete-char 1)'
  ;; unconditionally immediately after their `looking-at' check succeeds
  ;; -- and it is fully implementable with the buffer primitives already
  ;; available (`nelisp-delete-region' + point arithmetic), no search
  ;; primitive needed.
  (defun delete-char (n &optional _killflag)
    "Delete N characters after point, or before point when N is negative.
Clamped to the accessible region rather than signalling, matching the
clamp behaviour of `forward-char'/`backward-char' above.  KILLFLAG is
accepted for signature compatibility; no caller reachable from
`skk-start-henkan'/`skk-kakutei' passes a non-nil KILLFLAG, so no
kill-ring interaction is provided."
    (let ((here (nelisp-point)))
      (if (>= n 0)
          (nelisp-delete-region here (min (nelisp-point-max) (+ here n)))
        (nelisp-delete-region (max (nelisp-point-min) (+ here n)) here)))
    nil)

  (defalias 'markerp 'nelisp-markerp)
  (defalias 'make-marker 'nelisp-make-marker)
  (defalias 'marker-position 'nelisp-marker-position)

  (defun point-marker ()
    "Return a fresh marker at point in the current NeLisp buffer."
    (nelisp-copy-marker (nelisp-current-buffer) (nelisp-point)))

  (defun copy-marker (&optional position insertion-type)
    "Return a fresh marker at POSITION (an integer, a marker, or nil = point).
DDSKK calls this from `skk-kakutei' and friends; the standalone runtime
has no host `copy-marker'."
    (let ((pos (cond
                ((null position) (nelisp-point))
                ((nelisp-markerp position) (nelisp-marker-position position))
                (t position))))
      (nelisp-copy-marker (nelisp-current-buffer) pos insertion-type)))

  (defun buffer-live-p (buffer)
    ;; `nelisp-buffer-list' rebuilds the whole registry through `maphash'
    ;; on every call, which measured 73.9 ms in the standalone runtime and
    ;; sits on the per-keystroke path three times.  The registry is keyed by
    ;; buffer name, so a single `gethash' answers the same question.
    (and buffer
         (eq buffer (gethash (nelisp-buffer-name buffer)
                             nelisp-buffer--registry))))

  (defun set-marker (marker position &optional buffer)
    (nelisp-set-marker marker position (or buffer (nelisp-current-buffer))))

  (defmacro with-current-buffer (buffer &rest body)
    `(nelisp-with-buffer ,buffer ,@body))

  (defmacro with-temp-buffer (&rest body)
    `(let ((ddskk-temp-buffer (nelisp-generate-new-buffer
                               " *ddskk-nelisp-temp*")))
       (unwind-protect
           (nelisp-with-buffer ddskk-temp-buffer ,@body)
         (nelisp-kill-buffer ddskk-temp-buffer))))

  (defmacro save-match-data (&rest body)
    ;; NeLisp's regexp engine does not yet expose match-data/set-match-data.
    ;; DDSKK's synchronous engine requests cannot interleave regexp calls.
    `(progn ,@body))

  (defmacro setq-local (&rest pairs)
    `(setq ,@pairs))

  (defun autoload (&rest _args) nil)
  (defun barf-if-buffer-read-only () nil)
  (defun buffer-modified-p () nil)
  (defun use-region-p () nil)
  (defun force-mode-line-update (&rest _args) nil)
  (defun run-hooks (&rest _hooks) nil)

  ;; `skk-kakutei' (the COMMIT-control target) confirms every real candidate
  ;; through `skk-update-jisyo-p', which calls this on
  ;; `skk-search-excluding-word-pattern-function' -- a hook-shaped defcustom
  ;; that defaults to nil and, like every other hook variable in this
  ;; runtime, can never accumulate a real handler because `add-hook' below
  ;; is a no-op.  Its own docstring in skk-vars.el states the required
  ;; behaviour for that default: "この変数のデフォルトは nil であるため、
  ;; 関数 skk-update-jisyo-p は t を返す" -- i.e. running an empty hook must
  ;; report "nothing ran", exactly what `run-hooks' above already answers
  ;; for the fire-and-forget hooks.  This is genuinely reachable today:
  ;; without it, EVERY commit of a real candidate (CONTROL COMMIT while
  ;; `skk-henkan-mode' is active) signals void-function here before
  ;; `skk-kakutei-cleanup-buffer' / `skk-kakutei-initialize' ever run,
  ;; which leaves the session stuck in ▼ mode with a half-committed buffer
  ;; instead of cleanly erroring and resetting.
  (defun run-hook-with-args-until-success (&rest _args) nil)

  (defun add-hook (&rest _args) nil)
  (defun remove-hook (&rest _args) nil)
  ;; Minimal keymap surface.  These were inert stubs returning nil, which made
  ;; DDSKK's `(unless (keymapp ...))' / `(unless (eq (lookup-key ...) ...))'
  ;; guards fail open, so `skk-define-j-mode-map' re-ran its 95-iteration
  ;; `dotimes' on every call.  A keymap here is just `(keymap (KEY . DEF) ...)':
  ;; enough for the guards to settle after the first setup, and no key is ever
  ;; dispatched through it because the native session calls DDSKK commands
  ;; directly.
  (defun make-sparse-keymap (&optional _string) (list 'keymap))

  (defun keymapp (object)
    (and (consp object) (eq (car object) 'keymap)))

  (defun define-key (keymap key def &optional _remove)
    (when (consp keymap)
      (let ((cell (assoc key (cdr keymap))))
        (if cell
            (setcdr cell def)
          (setcdr keymap (cons (cons key def) (cdr keymap))))))
    def)

  (defun lookup-key (keymap key &optional _accept-default)
    (and (consp keymap)
         (cdr (assoc key (cdr keymap)))))

  (defun easy-menu-define (&rest _args) nil)

  ;; DDSKK mirrors the global bindings of `delete-backward-char' / `undo'
  ;; onto its own maps.  This runtime has no global keymap and performs no
  ;; key dispatch -- the native session invokes DDSKK commands directly --
  ;; so the honest answer is that no such key exists, which makes
  ;; `skk-setup-emulation-commands' iterate zero times.
  (defun current-global-map () (list 'keymap))
  (defun where-is-internal (&optional _definition _keymap _firstonly _noindirect _no-remap) nil)

  (defvar minor-mode-map-alist nil
    "Keymap alist stub.  This runtime has no keymaps -- `keymapp',
`lookup-key' and `define-key' are already inert here -- but DDSKK's
mode-switching commands read and rebind this variable, and an unbound
read terminates the whole engine process.")

  ;; DDSKK binds its kakutei key into the minibuffer maps during keymap
  ;; setup (`skk-define-minibuffer-maps', skk.el:441-445), which every
  ;; `skk-setup-keymap' call reaches regardless of which mode is turning
  ;; on -- that is what put `minibuffer-local-map' on the 'L' and '/'
  ;; paths.  This runtime has no minibuffer, but the three variables must
  ;; exist and be real keymaps: `skk-define-minibuffer-maps' calls
  ;; `define-key' on all three, and `define-key' above mutates its keymap
  ;; argument in place with `setcdr', which requires a cons.
  (defvar minibuffer-local-map (list 'keymap))
  (defvar minibuffer-local-completion-map (list 'keymap))
  (defvar minibuffer-local-ns-map (list 'keymap))

  ;; No minibuffer exists here, so the recursive-edit depth is genuinely 0.
  ;; DDSKK consults it in two places: `skk-henkan-in-minibuff' (the jisyo
  ;; registration entry point, reached from `skk-henkan' when the search
  ;; prog list is exhausted with zero candidates) records it as the nesting
  ;; baseline, and `skk-exit-henkan-in-minibuff' (wired onto
  ;; `minibuffer-exit-hook', which -- like every hook -- can never actually
  ;; fire here because `add-hook' above is a no-op) compares against it.
  ;; Both call sites only need "there is no nesting", which 0 states
  ;; directly.
  (defun minibuffer-depth () 0)

  ;; Not called by anything reachable from `skk-start-henkan' or
  ;; `skk-kakutei' in skk.el, skk-macs.el, skk-vars.el or skk-emacs.el
  ;; today -- grepping all four finds zero call sites.  Added anyway
  ;; because the answer is unconditionally correct (this runtime never
  ;; creates a minibuffer, so nothing passed in is ever it) and trivial,
  ;; and because DDSKK has other entry points outside this trace
  ;; (completion, isearch) that may reach it later; this pre-empts that
  ;; next round trip rather than waiting to hit it.
  (defun minibufferp (&optional _buffer-or-name) nil)

  (defun overlayp (_object) nil)
  (defun window-system (&optional _frame) nil)
  (defun frame-list () nil)

  ;; DDSKK's only two callers of `window-buffer' (skk-macs.el:529's
  ;; `skk-in-minibuffer-p', reached from `skk-toggle-characters' on the
  ;; 'q' path, and a tooltip-positioning form in skk-emacs.el:491) both
  ;; call it as `(window-buffer (minibuffer-window))', asking "what buffer
  ;; is shown in the minibuffer window", never "what buffer is shown in
  ;; the selected window".  This runtime never displays a minibuffer, so
  ;; `minibuffer-window' -- mirroring the `window-system' stub above,
  ;; which likewise answers "no such thing here" with nil -- always
  ;; reports that there is no such window.  `window-buffer' must then
  ;; answer "no buffer" (nil) for that nil window, NOT the current
  ;; buffer: `skk-in-minibuffer-p' compares its result against
  ;; `current-buffer' with `eq', and if it always returned the current
  ;; buffer here, `skk-in-minibuffer-p' would be vacuously true on every
  ;; call, which changes the branch `skk-toggle-characters' takes at
  ;; skk.el:972 -- i.e. it would change DDSKK's real behaviour on 'q',
  ;; not just satisfy the predicate's shape.  `selected-window',
  ;; `get-buffer-window' and `window-live-p' are not stubbed here: they
  ;; are not called from this call site, and their only appearances in
  ;; the four DDSKK core files are in the candidate-buffer window
  ;; management code (`skk-henkan-show-candidates-buffer',
  ;; `skk-show-num-type-info') and the tooltip mouse-position code, both
  ;; unreached from the 'q'/'L'/'/' paths.
  (defun minibuffer-window (&optional _frame) nil)

  (defun window-buffer (&optional window)
    (and window (nelisp-current-buffer)))

  (defun characterp (object) (integerp object))

  ;; `skk-insert-new-word' -- the function that actually splices a
  ;; dictionary candidate into the buffer, reached unconditionally on every
  ;; successful SPACE-conversion (`skk-henkan' -> `skk-henkan-1' returning
  ;; a candidate) -- reads and clears text properties on the candidate
  ;; STRING itself, not on the buffer:
  ;; `(get-text-property 0 'face word)' then
  ;; `(set-text-properties 0 (length word) nil word)'.  NeLisp's text
  ;; properties (`nelisp-get-text-property' / `nelisp-put-text-property' in
  ;; nelisp-buffer.el) are stored per-BUFFER in a side interval list; a
  ;; string object has nowhere to hold one.  That is also the correct
  ;; answer here regardless of storage: the only way a candidate string
  ;; could carry a face property is via `propertize', and this runtime's
  ;; only caller of that on the candidate-display path
  ;; (`skk-henkan-face-on') never runs because `skk-use-face' always
  ;; evaluates to nil here (`window-system' is stubbed nil above and
  ;; neither `selected-frame' nor `frame-face-alist' is fboundp in this
  ;; runtime).  So a STRING object genuinely never has a property to
  ;; report or clear.  A buffer/nil OBJECT is not exercised by any caller
  ;; reachable from `skk-start-henkan' or `skk-kakutei' and is
  ;; intentionally not implemented here.
  (defun get-text-property (_position _prop &optional _object) nil)

  (defun set-text-properties (_start _end _properties &optional _object) nil)

  (defun self-insert-command (&optional n _c)
    "Insert `last-command-event' N times (default once).
DDSKK relies on Emacs falling through to the global binding for keys that
its minor-mode maps leave unbound -- that fall-through is what makes
`skk-latin-mode' actually type ASCII."
    (let ((count (or n 1)))
      (while (> count 0)
        (nelisp-insert (string last-command-event))
        (setq count (1- count)))))

  ;; Marker-to-position coercion for arithmetic ops (`<' `>' `<=' `>=' `='
  ;; `/=' `+' `-' `1+' `1-') used to live here as Elisp `fset' wrappers
  ;; around each operator -- GNU Emacs itself accepts a marker anywhere an
  ;; integer position is expected (CHECK_FIXNUM_COERCE_MARKER) and DDSKK
  ;; relies on that in ~25 places in skk.el, so this runtime needed the
  ;; same coercion.  That coercion now lives inside the NeLisp runtime
  ;; itself for MOST of those operators -- confirmed directly against
  ;; nelisp-markerfix.exe with a marker at buffer position 2, in both
  ;; argument positions and multi-arg forms:
  ;;   (< 5 m)=nil (> 5 m)=t (<= m 2)=t (>= m 2)=t (= 2 m)=t (/= m 3)=t
  ;;   (- 5 m)=3 (- m 1)=1 (+ m 1)=3 (+ 1 m)=3 (< 1 m 5)=t (+ m m)=4
  ;; -- so the wrappers for `<' `>' `<=' `>=' `=' `/=' `+' `-' were removed
  ;; here along with their `skk-nelisp--orig-*' captures: they cost roughly
  ;; 5x per-keystroke latency and several hundred MB (every arithmetic call
  ;; in DDSKK routed through an interpreted wrapper lambda).
  ;;
  ;; `1+' and `1-' are NOT covered by the runtime fix, discovered when
  ;; removing every wrapper broke `CONTROL CONVERT' (candidates always
  ;; empty, mode stuck on "hiragana" instead of "candidate" --
  ;; scratchpad/test-conversion-skkime.ps1 went from PASS with all ten
  ;; wrappers to FAIL with none of them).  Root cause, isolated with
  ;; scratchpad/probe-marker-coercion-full.el against the raw runtime (no
  ;; Elisp wrapper loaded): `(1+ m)' and `(1- m)' read the marker as a raw
  ;; Record heap pointer instead of coercing it, returning an
  ;; address-sized integer (e.g. 1149766769) instead of 3.  This is not a
  ;; theoretical gap: `skk-change-marker' (skk.el:3333, directly on the
  ;; SPACE-conversion path documented above -- `skk-start-henkan' ->
  ;; `skk-henkan' -> `skk-change-marker') unconditionally calls
  ;; `(goto-char (1- skk-henkan-start-point))', so with `1-' unwrapped,
  ;; CONVERT jumps to a garbage position and the search silently returns
  ;; zero candidates.  So these two wrappers stay -- removing them was the
  ;; part of the original premise ("runtime now coerces, so the whole
  ;; wrapper layer is dead weight") that direct measurement shows is false.
  (defun skk-nelisp--pos (value)
    "Return VALUE, or its buffer position when VALUE is a marker.
Tests the record type tag directly (`recordp' + `nelisp--record-type' +
`eq') instead of calling `nelisp-markerp', which chains through
`nelisp-marker-p' and `nelisp-cl-macros--struct-isa' as well."
    (if (and (recordp value) (eq (nelisp--record-type value) 'nelisp-marker))
        (nelisp-marker-position value)
      value))

  (defvar skk-nelisp--orig-1+ (symbol-function '1+))
  (fset '1+
        (lambda (a) (funcall skk-nelisp--orig-1+ (skk-nelisp--pos a))))

  (defvar skk-nelisp--orig-1- (symbol-function '1-))
  (fset '1-
        (lambda (a) (funcall skk-nelisp--orig-1- (skk-nelisp--pos a)))))

(provide 'skk-nelisp-compat)

;;; skk-nelisp-compat.el ends here
