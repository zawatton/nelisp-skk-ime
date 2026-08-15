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

  ;; --- Gap-aware accessors: looking-at / looking-back / char-after /
  ;; char-before ---------------------------------------------------------
  ;;
  ;; `nelisp-buffer-string' / `nelisp-buffer-substring'
  ;; (dev/nelisp/src/nelisp-buffer.el:172-181, read-only from this repo)
  ;; both go through
  ;;   (concat (nelisp-buffer-before-gap b) (nelisp-buffer-after-gap b))
  ;; i.e. a full copy of the ENTIRE buffer, on EVERY call -- `substring'
  ;; on top of that for `nelisp-buffer-substring'.  DDSKK's ▽-composition
  ;; path calls `looking-at' several times per keystroke (skk.el:3294-
  ;; 3301, :3334, :3349, :3371, :3376), and `ddskk-engine--maybe-truncate-
  ;; session' (engine/ddskk-engine.el) only erases the session buffer
  ;; when `(and (null skk-henkan-mode) (equal skk-prefix ""))' -- both
  ;; conditions fail for the ENTIRE duration of a ▽ composition -- so the
  ;; buffer keeps growing, uncapped, for as long as the user keeps typing
  ;; without committing.  Every additional character therefore makes every
  ;; subsequent keystroke's full-buffer copies bigger AND there are more
  ;; of them (several `looking-at' calls per key): measured 22.6 ms/key at
  ;; composition length 0 rising to ~60 ms/key at length 300, working set
  ;; ballooning past 500 MB, past the point where the Windows TSF DLL's
  ;; ~1500 ms `SendKey' timeout stops claiming the key and starts leaking
  ;; it into the document as raw ASCII -- exactly the reported "▽Ka "
  ;; instead of "▽か".
  ;;
  ;; The gap-buffer struct (`nelisp-buffer', nelisp-buffer.el:30-41) --
  ;;   (cl-defstruct (nelisp-buffer ...) name (before-gap "") (after-gap "") ...)
  ;; -- already stores the text split exactly where these four functions
  ;; need it, and `nelisp-goto-char' (nelisp-buffer.el:293-304) maintains
  ;; the split on every point move by re-slicing the full text at point:
  ;;   (setf (nelisp-buffer-before-gap b) (substring total 0 idx))
  ;;   (setf (nelisp-buffer-after-gap b) (substring total idx))
  ;; so as an invariant, whenever point is settled:
  ;;   - `before-gap' IS the buffer text for [point-min-of-1, point) --
  ;;     `nelisp-point' is literally defined as
  ;;     `(1+ (length (nelisp-buffer-before-gap b)))' (nelisp-buffer.el:
  ;;     155-158), i.e. point == (length before-gap) + 1.
  ;;   - `after-gap' IS the buffer text for [point, unrestricted-end).
  ;; Reading straight out of these slots -- a `cl-defstruct' accessor
  ;; (O(1), a field read) plus `length'/`aref'/`substring' bounded by the
  ;; size of the piece actually needed -- replaces the current full-buffer
  ;; `concat' (an unbounded copy on every single call, growing with total
  ;; composition length) with work bounded by the requested slice, and in
  ;; the common case (`looking-at', and `char-after'/`char-before' AT
  ;; point) with no copy at all.
  ;;
  ;; `skk-nelisp--char-at' below is the one piece of shared index algebra:
  ;; given a 1-based absolute buffer position POS and BEFORE = (before-gap
  ;; B) of length LB, POS falls in `before-gap' (index POS-1) when POS <=
  ;; LB, and in `after-gap' (index POS-LB-1, i.e. POS - point) when POS >
  ;; LB.  This holds for ANY position, not just point itself, so a
  ;; POSITION argument to `char-after'/`char-before' that is not point (an
  ;; explicit integer, or a marker coerced via `skk-nelisp--pos') is still
  ;; answered in O(1) from whichever half contains it -- never a
  ;; whole-buffer copy either.
  (defun skk-nelisp--char-at (pos before b)
    "Return the character at 1-based absolute position POS in B.
BEFORE must already be `(nelisp-buffer-before-gap B)' (passed in so
callers that fetched it for another reason do not fetch it twice).  POS
must lie within B's unrestricted [1, buffer-size]; callers are
responsible for the point-min/point-max accessibility check."
    (let ((lb (length before)))
      (if (<= pos lb)
          (aref before (1- pos))
        (aref (nelisp-buffer-after-gap b) (- pos lb 1)))))

  (defun looking-at (regexp)
    "Return non-nil when text at point matches REGEXP.
Anchors REGEXP at point by matching against the buffer text from point
forward; the runtime has no buffer-aware search, only `string-match'
over strings.

This sets match data as a side effect of the underlying `string-match'
call, exactly like real `looking-at' does -- but because the match runs
against the after-gap string (or a bounded prefix of it, when the buffer
is narrowed) rather than the buffer itself, `match-beginning'/`match-end'
read afterwards are offsets into that string \(0 = point), NOT absolute
buffer positions.  Checked against every caller reachable from
`skk-start-henkan'/`skk-kakutei' \(`skk-change-marker',
`skk-delete-henkan-markers', `skk-what-char-type'): none of them read
match-data after calling `looking-at', they only test its return value,
so this divergence is safe on that path today.  A caller that started
reading `match-beginning'/`match-end' after `looking-at' would get
tail-relative, not buffer-relative, numbers and must be fixed at the call
site -- do not silently paper over that here.

Reads `after-gap' directly (see the gap-aware accessors note above) --
no full-buffer copy, and in the unnarrowed case (the only case this
compat layer's reachable callers ever produce: narrowing is only used by
vendor/ddskk/maint and skk-tut.el, neither loaded by
engine/ddskk-engine.el) no copy at all.  When the buffer IS narrowed
\(`point-max' short of the unrestricted end), only the visible prefix of
`after-gap' is sliced off, still never the whole buffer."
    (let* ((b (nelisp-buffer--ambient nil))
           (after (nelisp-buffer-after-gap b))
           (visible (- (nelisp-point-max b) (nelisp-point b)))
           (tail (if (= visible (length after))
                     after
                   (substring after 0 visible))))
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
appears.

Reads `before-gap' directly (see the gap-aware accessors note above):
`before-gap' IS the buffer text for [point-min-of-1, point), so the
window [LIMIT, point) this function needs is always a plain `substring'
of `before-gap' alone -- bounded by that window's own size, never a
full-buffer copy, and `after-gap' is never even touched."
    (let* ((b (nelisp-buffer--ambient nil))
           (end (nelisp-point b))
           (before (nelisp-buffer-before-gap b))
           (start (skk-nelisp--pos (or limit (nelisp-point-min b))))
           (head (substring before (1- start) (length before)))
           (len (length head))
           (i 0)
           (found nil))
      (while (and (not found) (<= i len))
        (when (and (eq (string-match regexp head i) i)
                   (eq (match-end 0) len))
          (setq found t))
        (setq i (1+ i)))
      found))

  ;; --- `re-search-forward' ------------------------------------------------
  ;;
  ;; Void-function on the ▽-mode `q'/C-q path: `skk-toggle-characters'
  ;; (skk.el:944-982) converts the henkan-region kana to the other kana type
  ;; via `skk-katakana-region'/`skk-hiragana-region' (skk.el:4745-4772),
  ;; both of which call `skk-search-and-replace' (skk.el:4791-4810), and
  ;; THAT calls `(re-search-forward regexp end \\='noerror)' in a loop -- a
  ;; buffer-aware, POINT-relative regexp search this runtime never
  ;; implemented (only `string-match' over strings exists, same gap
  ;; documented above `looking-at').  Confirmed as the exact and ONLY
  ;; failure on this path by a live probe with `DDSKK_ENGINE_DEBUG=1':
  ;; typing K-a-n-A then `q' returned \"ERR KEY void-function
  ;; re-search-forward\", not any marker/point-related signal -- the
  ;; STATIC, non-adjusting markers this runtime uses elsewhere (see the
  ;; commentary above `set-marker') are NOT the culprit here: `goto-char'
  ;; with a marker argument (both `skk-toggle-characters' and
  ;; `skk-search-and-replace' pass one) already works correctly today,
  ;; because `nelisp-goto-char''s `(1- clamped)' step coerces whatever
  ;; `min'/`max' handed it back (per the commentary above `skk-nelisp--pos'
  ;; on the runtime's own marker-arithmetic coercion) into a real integer
  ;; before it is ever used to slice the buffer.
  ;;
  ;; Implements exactly the subset the sole reachable caller needs: REGEXP
  ;; searched forward from point, bounded by BOUND (required here --
  ;; `skk-search-and-replace' always passes one, a marker it just created
  ;; -- but nil is accepted too, defaulting to `point-max', for signature
  ;; completeness), NOERROR non-nil returns nil on failure instead of
  ;; signalling (every non-nil value collapses to the same behaviour here;
  ;; no reachable caller inspects point after a failed bounded search
  ;; inside a `while' loop that simply stops), and COUNT other than nil/1
  ;; is rejected rather than silently ignored, since nothing here needs it.
  ;;
  ;; Like `looking-at' above, this searches the `after-gap' string, not
  ;; the buffer itself -- so `string-match''s own match-data is, at first,
  ;; offsets into THAT string (0 = point), exactly `looking-at''s
  ;; documented divergence.  Unlike `looking-at', whose only callers on
  ;; the reachable path merely test its boolean return, `skk-search-and-
  ;; replace' reads `(match-beginning 0)'/`(match-end 0)' immediately
  ;; AFTER this returns and uses them as absolute buffer positions
  ;; (`(goto-char beg0)', `(delete-region (+ beg0 ...) (+ end0 ...))').
  ;; So, on a match, this rebases the regexp engine's own match-data
  ;; vector (`nlre--last-caps', generated into the runtime by
  ;; lisp/nelisp-stdlib-regexp.el -- the same vector `match-beginning' /
  ;; `match-end' / `match-data' all read) from tail-relative to absolute
  ;; buffer positions IN PLACE via `aset', before returning -- not by
  ;; redefining `match-beginning'/`match-end' themselves, which would
  ;; wrongly change `looking-back''s already-correct tail-relative reading
  ;; above.
  (defun re-search-forward (regexp &optional bound noerror count)
    "Search forward from point for REGEXP, bounded by BOUND (default
`point-max'), moving point to the end of the match on success and
returning the new point.  NOERROR non-nil returns nil instead of
signalling `search-failed' when no match is found.  COUNT, if given,
must be 1 -- repeat counts are not supported."
    (when (and count (/= count 1))
      (error "re-search-forward: COUNT other than 1 is not supported on this runtime"))
    (let* ((b (nelisp-buffer--ambient nil))
           (start (nelisp-point b))
           (limit (if bound (skk-nelisp--pos bound) (nelisp-point-max b)))
           (after (nelisp-buffer-after-gap b))
           (visible (max 0 (- limit start)))
           (tail (cond ((<= visible 0) "")
                       ((= visible (length after)) after)
                       (t (substring after 0 visible)))))
      (if (string-match regexp tail)
          (let ((rel-end (match-end 0))
                (caps nlre--last-caps))
            (when (vectorp caps)
              (let ((i 0) (n (length caps)))
                (while (< i n)
                  (let ((c (aref caps i)))
                    (when (consp c)
                      (aset caps i (cons (+ start (car c)) (+ start (cdr c))))))
                  (setq i (1+ i)))))
            (nelisp-goto-char (+ start rel-end) b))
        (if noerror nil (signal 'search-failed (list regexp))))))

  (defun char-after (&optional position)
    "Return the character at POSITION (default point), or nil past the end.
POSITION may be an integer or a marker.

Reads directly out of the gap halves via `skk-nelisp--char-at' (see the
gap-aware accessors note above) instead of building a 1-character
substring through a full-buffer copy; at point (the common case) this is
just the first character of `after-gap'."
    (let* ((b (nelisp-buffer--ambient nil))
           (pos (if position (skk-nelisp--pos position) (nelisp-point b))))
      (and (>= pos (nelisp-point-min b))
           (< pos (nelisp-point-max b))
           (skk-nelisp--char-at pos (nelisp-buffer-before-gap b) b))))

  (defun char-before (&optional position)
    "Return the character before POSITION (default point), or nil at the start.
POSITION may be an integer or a marker.

Reads directly out of the gap halves via `skk-nelisp--char-at' (see the
gap-aware accessors note above) instead of building a 1-character
substring through a full-buffer copy; at point (the common case) this is
just the last character of `before-gap'."
    (let* ((b (nelisp-buffer--ambient nil))
           (pos (if position (skk-nelisp--pos position) (nelisp-point b))))
      (and (> pos (nelisp-point-min b))
           (<= pos (nelisp-point-max b))
           (skk-nelisp--char-at (1- pos) (nelisp-buffer-before-gap b) b))))

  ;; Not part of the original char-charset request, but the very next
  ;; void-function once `char-charset' (below) unblocks the okurigana
  ;; keystroke: `skk-set-okurigana' (skk.el:1476-1506) calls this
  ;; unconditionally before it ever reaches `skk-okurigana-prefix':
  ;;   (unless (eq (following-char) ?*) (insert-and-inherit "*"))
  ;; Real Emacs's `following-char' is `char-after' at point, except it
  ;; returns 0 (not nil) at the end of the accessible buffer -- matched
  ;; here for the same reason `char-after' above documents its own nil
  ;; case: callers compare the result against a specific character code.
  (defun following-char ()
    "Return the character following point, as this runtime's `char-after' does.
Returns 0 at the end of the accessible buffer, matching real Emacs
\(where `char-after' returns nil there but `following-char' returns 0)."
    (or (char-after) 0))

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

  ;; Real Emacs `set-marker' accepts POSITION as an integer, a marker
  ;; (using ITS position), or nil (which detaches MARKER from its
  ;; buffer) -- `skk-set-marker' (skk-macs.el) forwards straight to
  ;; this, and `skk-set-okurigana' (skk.el:1480) calls it with a
  ;; MARKER as POSITION:
  ;;   (skk-set-marker skk-henkan-end-point skk-okurigana-start-point)
  ;; `nelisp-set-marker' (dev/nelisp/src/nelisp-buffer.el:439-463)
  ;; stores POS with a bare `(setf (nelisp-marker-position marker)
  ;; pos)' at the end of its non-nil branch -- no arithmetic anywhere
  ;; on that path, so none of the runtime's marker-in-arithmetic
  ;; coercion (see the commentary above `skk-nelisp--pos') ever runs
  ;; here, and a marker POSITION would be stored as the marker object
  ;; itself instead of its buffer position.  That corrupted end point
  ;; is what made `skk-set-okurigana' -> `buffer-substring-no-properties'
  ;; read back "か*く" instead of "か" for the okurigana midasi, so the
  ;; wrong search key ("か*くk") was sent to `SERVER' instead of the
  ;; correct "かk".
  ;;
  ;; `skk-nelisp--pos' already returns a nil VALUE unchanged (`recordp'
  ;; of nil is nil, so it falls through to the `value' branch below),
  ;; so routing POSITION through it here also preserves the
  ;; nil-detaches-the-marker behaviour DDSKK's cleanup paths rely on
  ;; (`skk-set-marker ... nil' appears in `skk-kakutei-cleanup-buffer'
  ;; and friends) -- no separate nil guard is needed.
  (defun set-marker (marker position &optional buffer)
    "Set MARKER's position to POSITION in BUFFER (default current buffer).
POSITION may be an integer, a marker (coerced to its buffer position
via `skk-nelisp--pos'), or nil (detaches MARKER from its buffer, per
`nelisp-set-marker')."
    (nelisp-set-marker marker (skk-nelisp--pos position)
                        (or buffer (nelisp-current-buffer))))

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

  ;; `char-charset' and its two callees below (`encode-char',
  ;; `charset-dimension') exist because DDSKK classifies characters through
  ;; Mule's charset system, which this UTF-8-only runtime does not have.
  ;;
  ;; Call-site evidence (all unmodified vendor code, quoted verbatim):
  ;;   - `skk-ascii-char-p'  (skk-macs.el:243)
  ;;       (eq (char-charset char skk-charset-list) 'ascii)
  ;;   - `skk-jisx0208-p'    (skk-macs.el:246)
  ;;       (eq (char-charset char skk-charset-list) 'japanese-jisx0208)
  ;;   - `skk-jisx0213-p'    (skk-macs.el:248-251) tests for
  ;;       'japanese-jisx0213-1/-2/.2004-1 symbols.  Its only callers in the
  ;;       whole tree are in skk-viper.el (following-char/preceding-char/
  ;;       char-after/char-before guards), and `engine/ddskk-engine.el' never
  ;;       loads skk-viper.el (only skk-vars.el, skk-macs.el, skk-emacs.el
  ;;       and skk.el are loaded) -- so this predicate is unreachable here
  ;;       and it does not matter that our mapping below never returns a
  ;;       jisx0213 symbol.
  ;;   - `skk-split-char'    (skk-macs.el:255-268) builds a (CHARSET . BYTES)
  ;;       list by calling `char-charset', then `encode-char' and
  ;;       `charset-dimension' on the result, unconditionally, before its
  ;;       byte-unpacking loop ever looks at those values.
  ;;   - `skk-char-octet'    (skk-macs.el:309-313)
  ;;       (or (nth (if n (1+ n) 1) (skk-split-char ch)) 0)
  ;;
  ;; The actual first crash on the traced okurigana keystroke ("K a k U"
  ;; etc.) is NOT inside `skk-okurigana-prefix' -- it is
  ;; `skk-set-henkan-point' (skk.el:2984-3110), the handler DDSKK runs for
  ;; every capitalised self-insert.  Around skk.el:3037-3039 it tests
  ;; whether the character before point continues a full-width "#0"-"#9"
  ;; marker:
  ;;     (and (skk-jisx0208-p p)
  ;;          (= (skk-char-octet p 0) 35)          ;?#
  ;;          (<= 48 (skk-char-octet p 1)) (<= (skk-char-octet p 1) 57))
  ;;   where P = (char-before) -- the hiragana reading character just typed
  ;;   (e.g. "か").  `skk-jisx0208-p' calls `char-charset' directly, and
  ;;   that is what void-functions first, before `skk-okurigana-prefix' is
  ;;   ever reached.  Once `char-charset' answers, `skk-char-octet' needs a
  ;;   working `skk-split-char', hence `encode-char' and `charset-dimension'
  ;;   are needed too.
  ;;
  ;; `skk-okurigana-prefix' itself (skk.el:5018-5037) is reached next, once
  ;; `skk-set-henkan-point' hands off through `skk-kana-input' to
  ;; `skk-set-okurigana'.  It repeats the same `skk-char-octet' call on the
  ;; first okurigana kana -- the actual reason this fix exists (see
  ;; skk-okurigana-prefix's `(t (aref skk-kana-rom-vector (- (skk-char-octet
  ;; headchar 1) 33)))' branch) -- guarded by
  ;; `(skk-string<= "ぁ" headchar)' / `(skk-string<= headchar "ん")', which
  ;; do not call `char-charset' at all.
  ;;
  ;; `skk-charset-list' (skk-vars.el:2200-2201, default nil) is only ever
  ;; populated by `skk-setup-charset-list' (skk.el:354-368), which filters a
  ;; fixed symbol list through `charsetp'.  The sole caller of that setup
  ;; function is `skk-mode-invoke' (skk.el:327), and this engine never calls
  ;; `skk-mode-invoke' -- `skk-ime-session--initialize-native-buffer'
  ;; (engine/ddskk-engine.el) sets up each session's buffer-local state
  ;; directly instead.  So `skk-charset-list' stays nil for the life of this
  ;; process, the RESTRICTION argument below is always nil, and `charsetp'
  ;; is never called -- it is deliberately NOT defined here.
  ;;
  ;; Ranges chosen for `char-charset', all standard Unicode blocks:
  ;;   ascii              < U+0080
  ;;   japanese-jisx0208   U+3000-303F  CJK punctuation/symbols
  ;;                       U+3040-309F  Hiragana
  ;;                       U+30A0-30FF  Katakana
  ;;                       U+4E00-9FFF  CJK Unified Ideographs
  ;;                       U+FF00-FFEF  Halfwidth and Fullwidth Forms
  ;;   unicode             everything else (catch-all; DDSKK's predicates
  ;;                       above never test for this symbol, so it reads as
  ;;                       "neither ascii nor jisx0208" wherever it appears)
  ;;
  ;; This mapping is coarser than real Mule -- e.g. it buckets full-width
  ;; digits/`#' and every CJK ideograph together with hiragana/katakana --
  ;; but that only matters to a caller that also runs `skk-char-octet' on
  ;; one of those characters, and see `encode-char' below for why the two
  ;; reachable callers still get exact answers.
  (defun char-charset (char &optional _restriction)
    "Return a charset symbol for CHAR, derived from its code point.
This runtime is UTF-8 only and has no charset registry; DDSKK uses this
to classify a character, chiefly through `skk-ascii-char-p'/`skk-jisx0208-p'
on the okurigana and digit-continuation paths, so the distinctions that
matter here are ASCII vs Japanese.  RESTRICTION (DDSKK always passes
`skk-charset-list', which never leaves its nil default in this engine --
see the commentary above) is ignored: the answer is already the single
charset the code point belongs to."
    (cond
     ((< char #x80) 'ascii)
     ((or (<= #x3000 char #x303f)   ; CJK punctuation/symbols
          (<= #x3040 char #x309f)   ; Hiragana
          (<= #x30a0 char #x30ff)   ; Katakana
          (<= #x4e00 char #x9fff)   ; CJK Unified Ideographs
          (<= #xff00 char #xffef))  ; Halfwidth and Fullwidth Forms
      'japanese-jisx0208)
     (t 'unicode)))

  (defun charset-dimension (charset)
    "Return the byte-width `skk-split-char' should unpack for CHARSET.
Only `ascii' (1 byte) and `japanese-jisx0208' (2 bytes, JIS X 0208's real
row/column code space) are ever consumed on a call path reachable in this
engine; see `encode-char'.  `unicode' is this file's catch-all charset and
is never actually split by a reachable caller (see `encode-char'), but is
given 1 anyway so `skk-split-char''s loop still terminates if it ever is."
    (if (eq charset 'japanese-jisx0208) 2 1))

  (defun encode-char (char charset)
    "Return CHAR's code point within CHARSET, as `skk-split-char' expects.
For `ascii' this is CHAR itself.

For `japanese-jisx0208', hiragana (U+3041-3093, ぁ..ん) and katakana
(U+30A1-30F3, ァ..ン) get the REAL JIS X 0208 row/column (ku/ten) GL byte
pair: row 4 for hiragana, row 5 for katakana, GL-encoded as (row + #x20)
in the high byte.  Unicode's block order for both ranges is identical to
their JIS X 0208 row order, so column = (CHAR - block-start) + 1, GL-coded
as (column + #x20) in the low byte.  This is exactly what the two
reachable callers need:
  - `skk-set-henkan-point' (skk.el:3037-3039) tests the row byte of the
    reading kana just typed against 35 (= 3 + #x20, JIS row 3, the
    digit/`#' row) to decide whether it continues a full-width number --
    hiragana's row byte is 36 (row 4), so this correctly reads false.
  - `skk-okurigana-prefix' (skk.el:5018-5037) indexes
    `skk-kana-rom-vector' with (column-byte - 33), i.e. the okurigana
    kana's offset from ぁ -- which this formula reproduces exactly, since
    the (+ 33) here and the (- 33) there cancel out.

Every other character this file's `char-charset' also classifies as
`japanese-jisx0208' (CJK ideographs, full-width forms, CJK punctuation)
has no real JIS X 0208 table here -- building one from scratch is out of
scope, and no path reachable from `skk-start-henkan'/`skk-kakutei' ever
runs `skk-char-octet' on one of them while its answer is actually
consulted -- so those get a bounded but not standards-accurate row/column
pair, purely so `skk-split-char' always has integers to shift instead of
ever signalling.

`unicode' (this file's catch-all charset) returns CHAR itself.  As shown
in the call-site evidence above, `skk-jisx0208-p' guards every reachable
`skk-char-octet' call, so a `unicode'-classified CHAR can only reach here
through code this engine does not exercise; this exists purely so
`skk-split-char' cannot signal if that ever changes."
    (cond
     ((eq charset 'ascii) char)
     ((eq charset 'japanese-jisx0208)
      (cond
       ((<= #x3041 char #x3093)         ; hiragana ぁ..ん, JIS row 4
        (+ (ash #x24 8) (+ (- char #x3041) 33)))
       ((<= #x30a1 char #x30f3)         ; katakana ァ..ン, JIS row 5
        (+ (ash #x25 8) (+ (- char #x30a1) 33)))
       (t
        ;; No real JIS X 0208 table for this range here (see docstring
        ;; above); derive a bounded, deterministic GL row/column pair from
        ;; CHAR's low bits so the arithmetic in `skk-split-char' never sees
        ;; anything outside the GL byte range and never signals.
        (+ (ash (+ 33 (mod (ash char -6) 94)) 8)
           (+ 33 (mod char 94))))))
     (t char)))

  ;; Not part of the char-charset family above, but the next void-function
  ;; on the same okurigana keystroke once `char-charset'/`following-char'
  ;; unblock it: `skk-okurigana-prefix' (skk.el:5018-5037) opens with
  ;;     (skk-string<= "ぁ" headchar)
  ;;     (skk-string<= headchar "ん")
  ;; `skk-string<=' (skk-macs.el:586-589) is `(or (skk-string< str1 str2)
  ;; (string= str1 str2))', and `skk-string<' (skk-macs.el:575-584) always
  ;; goes through `skk-string-lessp-in-coding-system' (skk-macs.el:571-573):
  ;;     (string< (encode-coding-string str1 coding-system)
  ;;              (encode-coding-string str2 coding-system))
  ;; called with CODING-SYSTEM = 'emacs-mule (skk-string<'s own docstring:
  ;; comparison is done on the emacs-mule-encoded byte string, precisely to
  ;; give Japanese characters a stable ordering independent of Emacs's
  ;; internal representation).  This runtime's `encode-coding-string' is a
  ;; NeLisp stdlib stub (lisp/nelisp-stdlib-misc.el, `unless (fboundp ...)')
  ;; that only accepts CODING = `utf-8' and signals `error' for anything
  ;; else -- confirmed directly:
  ;;     (encode-coding-string "a" 'emacs-mule)
  ;;       => (error "encode-coding-string stub: only utf-8 supported, got emacs-mule")
  ;; which is exactly the `ERR KEY error encode-coding-string stub: ...'
  ;; this call site produces before this override is loaded.
  ;;
  ;; This runtime has only one string representation (NeLisp strings are
  ;; internally UTF-8, i.e. Unicode scalar sequences -- the stdlib stub's
  ;; own comment confirms this), so there is no separate "emacs-mule
  ;; encoded" byte string to produce here, and none is needed: `string<'
  ;; already compares Emacs strings character-by-character by Unicode
  ;; scalar value, which is exactly the ordering
  ;; `skk-string-lessp-in-coding-system' is trying to obtain via the
  ;; emacs-mule round-trip on real Emacs.  For the only two characters this
  ;; call site ever actually compares against -- the fixed bounds "ぁ"
  ;; (U+3041) and "ん" (U+3093) -- and any headchar reachable from
  ;; `skk-set-okurigana'/`skk-set-char-before-as-okurigana', a bare
  ;; codepoint comparison already gives the correct answer, so returning
  ;; the string unchanged for every CODING (not just `utf-8') is sufficient
  ;; and correct here; it also still gives byte-identical results to the
  ;; existing stub for CODING = `utf-8', which is the coding every other
  ;; reachable caller uses (`skk-emacs.el' lines 336/345, both already
  ;; `'utf-8'), so nothing that worked before this override changes.
  (defun encode-coding-string (str &optional _coding _nocopy)
    "Return STR unchanged, regardless of the requested CODING.
NeLisp strings have exactly one representation (UTF-8 / Unicode scalar
sequences), so there is no separate encoded byte string to build; see the
commentary above for why this is sufficient for every caller reachable
from the okurigana path (and does not change behaviour for the `utf-8'
callers that already worked)."
    str)

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
  ;; `1+' and `1-' were the last two arithmetic ops still wrapped here: the
  ;; NeLisp standalone runtime's dispatch table now coerces a marker operand
  ;; through `wf_num_word' for `1+'/`1-' directly (same fix already applied
  ;; to `<' `>' `<=' `>=' `=' `/=' `+' `-'), confirmed against
  ;; nelisp-markerfix2.exe with a marker at buffer position 2:
  ;; `(1+ m)' -> 3, `(1- m)' -> 1 (previously an address-sized garbage
  ;; integer, e.g. 1149766769).  `skk-change-marker' (skk.el:3333, directly
  ;; on the SPACE-conversion path -- `skk-start-henkan' -> `skk-henkan' ->
  ;; `skk-change-marker') unconditionally calls
  ;; `(goto-char (1- skk-henkan-start-point))', so this was load-bearing for
  ;; CONVERT; the runtime fix removes the need for the wrapper.
  ;;
  ;; --- `write-region' fix -----------------------------------------------
  ;;
  ;; This unconditionally CLOBBERS the `write-region' baked into
  ;; `nelisp.exe' from `dev/nelisp/scripts/nelisp-stdlib-prelude.el'
  ;; (`(unless (fboundp 'write-region) (defun write-region ...))' there --
  ;; that guard only protects against a PRIOR definition, and by the time
  ;; this file loads the stub is already `fboundp', so a plain `defun'
  ;; here replaces it).  Every other shim in this file only fills a
  ;; genuine gap and is left `unless fboundp'-gated; this one is different
  ;; because the existing definition is not merely missing, it is
  ;; ACTIVELY WRONG, confirmed by direct probe against a running
  ;; `nelisp.exe' (not assumed):
  ;;
  ;;   (1) The stub validates success as `(= rc (length bytes))', where
  ;;       `rc' (the return value of the underlying `wrf' syscall) is a
  ;;       BYTE count but `(length bytes)' is Elisp's CHARACTER count of
  ;;       the string.  Those only agree for pure-ASCII content.  Probed
  ;;       directly: writing "かんじ /漢字/幹事/\n" (12 characters) makes
  ;;       `wrf' return 26 -- its true UTF-8 byte length -- which the stub
  ;;       then compares against 12 and rejects with a signalled error,
  ;;       even though the file on disk already contains exactly the
  ;;       correct 26 bytes.  Every real save in `engine/skk-user-
  ;;       jisyo.el' hits this, since learned candidates are Japanese.
  ;;   (2) APPEND unconditionally signals "not supported" instead of
  ;;       appending, forcing every caller that needs append semantics
  ;;       (the learn journal below) into a full read-modify-write of the
  ;;       whole file on every single confirmation -- exactly the cost
  ;;       the journal exists to avoid.
  ;;
  ;; `nelisp.exe' is shared by other applications on this machine and
  ;; must not be rebuilt to fix either defect; both are corrected here,
  ;; in this repository's own compat shim, instead.
  (defun skk-nelisp--utf8-byte-length (string)
    "Return STRING's length in UTF-8 encoded bytes, without encoding it.
Standard per-scalar-value UTF-8 width: 1 byte below U+0080, 2 below
U+0800, 3 below U+10000, 4 otherwise.  NeLisp strings are Unicode scalar
sequences (see `encode-coding-string' above), so no surrogate-pair
handling is needed here -- this is exactly the count `wrf' itself
produces when it writes STRING's UTF-8 bytes to disk, which is what
makes this the correct thing to validate `write-region' against below,
in place of the stub's broken character count."
    (let ((total 0) (index 0) (count (length string)))
      (while (< index count)
        (let ((code (aref string index)))
          (setq total (+ total
                         (cond ((< code #x80) 1)
                               ((< code #x800) 2)
                               ((< code #x10000) 3)
                               (t 4)))))
        (setq index (1+ index)))
      total))

  (defun write-region (start end filename &optional append _visit
                              _lockname _mustbenew)
    "Write START (through END, or in full when END is nil) to FILENAME.
Supports the same string-START-only subset the broken stub supported --
there is no buffer-position form here -- and signals
`wrong-type-argument' for a non-string START/FILENAME or a non-integer,
non-nil END, exactly like the stub did.

APPEND, when non-nil, reads FILENAME's existing content first via
`nelisp--syscall-read-file' (treating a missing or unreadable file as
empty, the same documented contract `ddskk-user-jisyo-load' already
relies on elsewhere in this engine) and writes the concatenation of the
existing content and the new payload in one `wrf' call -- there is no
real append syscall here to hand off to, only a whole-file write.
VISIT/LOCKNAME/MUSTBENEW are accepted for signature compatibility only,
same as the stub they replace.

Validates success by comparing `wrf's return value against the
payload's UTF-8 BYTE length computed by `skk-nelisp--utf8-byte-length'
-- not the stub's broken CHARACTER count -- and signals `error' only on
a genuine mismatch (nothing/only part of the payload actually reached
disk).  Always returns nil, like the stub it replaces."
    (unless (stringp start)
      (signal 'wrong-type-argument (list 'stringp start)))
    (unless (stringp filename)
      (signal 'wrong-type-argument (list 'stringp filename)))
    (let* ((new (cond
                 ((null end) start)
                 ((integerp end) (substring start 0 end))
                 (t (signal 'wrong-type-argument
                            (list '(or null integerp) end)))))
           (payload (if append
                        (concat (or (nelisp--syscall-read-file filename) "")
                                new)
                      new))
           (expected (skk-nelisp--utf8-byte-length payload))
           (rc (wrf filename payload)))
      (unless (= rc expected)
        (signal 'error
                (list (format
                       "write-region: wrf returned %S (expected %S UTF-8 bytes) path=%s"
                       rc expected filename)))))
    nil)

  ;; `skk-nelisp--pos' itself stays: it still backs `looking-back',
  ;; `char-after', `char-before' below, none of which route through the
  ;; runtime's arithmetic dispatch table.
  (defun skk-nelisp--pos (value)
    "Return VALUE, or its buffer position when VALUE is a marker.
Tests the record type tag directly (`recordp' + `nelisp--record-type' +
`eq') instead of calling `nelisp-markerp', which chains through
`nelisp-marker-p' and `nelisp-cl-macros--struct-isa' as well."
    (if (and (recordp value) (eq (nelisp--record-type value) 'nelisp-marker))
        (nelisp-marker-position value)
      value)))

(provide 'skk-nelisp-compat)

;;; skk-nelisp-compat.el ends here
