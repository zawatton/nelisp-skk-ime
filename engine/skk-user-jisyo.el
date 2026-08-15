;;; skk-user-jisyo.el --- Client-side SKK personal dictionary (learning) -*- lexical-binding: t; -*-

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

;;; Commentary:

;; This is the client-side counterpart to the server-side personal
;; dictionary the user already has (`SKK-MY-JISYO.utf8', served by the
;; skkserv `ddskk-engine-server-search' talks to -- see the long
;; comment above `skk-ime-session--initialize-native-buffer' in
;; `ddskk-engine.el' for why `skk-jisyo' is nil and DDSKK's own
;; file-backed jisyo machinery is disabled).  Without this module every
;; conversion returns raw server dictionary order forever; this module
;; makes the engine LEARN: the candidate the user actually confirms
;; moves to the front of its midasi's candidate list, in memory and on
;; disk, so it stays first on the next conversion of the same reading
;; -- and across engine restarts, since it is loaded back from disk at
;; boot.
;;
;; Architecture:
;;   - `ddskk-user-jisyo--table' is the whole learned dictionary in
;;     memory: MIDASI (string) -> ordered candidate-string list,
;;     most-recently-confirmed first, already deduplicated.
;;   - `ddskk-user-jisyo-search' is installed at the FRONT of
;;     `skk-search-prog-list' (ahead of `ddskk-engine-server-search'),
;;     so a learned candidate is offered before the shared dictionary
;;     is even asked.  See "Dedup" below for why this does not produce
;;     duplicate candidates once the server's own results are merged
;;     in on a later SPC press.
;;   - `ddskk-user-jisyo--update' is installed as `skk-update-jisyo-
;;     function' (skk-vars.el's documented indirection point for
;;     `skk-update-jisyo', skk.el:4216-4217: `(funcall skk-update-jisyo-
;;     function word purge)') in place of the stock `skk-update-jisyo-
;;     original', which this engine cannot use -- that function reads
;;     via `skk-get-jisyo-buffer' which is a `(when skk-jisyo ...)' no-
;;     op here.  Read via `skk.el' L2650-2672 (`skk-kakutei'):
;;     `skk-henkan-key' still holds the midasi at the exact call site
;;     that reaches `skk-update-jisyo' (L2672) -- the only `let'-shadow
;;     of `skk-henkan-key' in that function (L2693, prefix/suffix
;;     combining) happens strictly AFTER that call already returned --
;;     so `ddskk-user-jisyo--update' can safely read it, exactly like
;;     `ddskk-engine-server-search' already does for the same variable.
;;
;; Dedup, verified from `vendor/ddskk' source, not assumed:
;;   `skk-search' (skk.el:3906-3927) stops calling further
;;   `skk-search-prog-list' entries as soon as ONE entry returns a
;;   non-nil result -- so on the very first SPC, if this module's
;;   search finds a learned candidate, `ddskk-engine-server-search' is
;;   never even invoked in that same call.  The server IS reached on a
;;   later SPC (`skk-henkan-1', skk.el:1809-1819, keeps calling
;;   `skk-search' while `skk-current-search-prog-list' is non-empty and
;;   no new candidate has been found yet at the current index), and its
;;   results are merged in via `(skk-nunion skk-henkan-list (skk-search))'.
;;   `skk-nunion' (skk-macs.el:761-793) is NOT a plain nconc: it walks
;;   the existing list and only appends a Y-element that is not already
;;   `equal' (also matching across a `;annotation' suffix, L779-790) to
;;   something already in X.  So a candidate this module already put at
;;   the front of `skk-henkan-list' is skipped, not re-appended, when
;;   the server's copy of the same string shows up later.  No separate
;;   dedup layer was needed for the cross-source case; this module still
;;   keeps its OWN per-midasi list internally duplicate-free (see
;;   `ddskk-user-jisyo--move-to-front') so its own results are never
;;   duplicated against themselves either.
;;
;; File format (SKK-JISYO, UTF-8) -- interoperable with other SKK
;; tools, matching the shape of the user's existing server-side
;; dictionary:
;;
;;     ;;; -*- coding: utf-8 -*-
;;     ;; okuri-ari entries.
;;     つk /付/着/[く/着/付/]/[き/付/着/]/
;;     ;; okuri-nasi entries.
;;     かんじ /漢字/幹事/感じ/
;;
;; v1 LIMITATION (deliberate): the `[okurigana/candidates.../]' ranking
;; blocks inside an okuri-ari entry are read (so they don't corrupt
;; parsing) and then DISCARDED -- only the plain candidate list ahead
;; of the first `[' is kept.  This engine never reproduces those bracket
;; blocks when writing either; every entry this module writes is a
;; flat plain-candidate list, which remains valid SKK-JISYO (any SKK
;; tool that doesn't understand the bracket refinement already falls
;; back to exactly this plain list).
;;
;; Runtime facts this file was written against (probed empirically on
;; the actual `nelisp.exe' / `nelisp-markerfix2.exe' standalone build
;; used by this repo's own test scripts -- NOT assumed from the task
;; description, which flagged some of these as unconfirmed):
;;   - `write-region' (`dev/nelisp/lisp/nelisp-stdlib-misc.el') takes a
;;     whole STRING as its first argument (not buffer positions),
;;     always truncate-writes, and SIGNALS if APPEND is non-nil -- so
;;     `ddskk-user-jisyo-save' always serializes the entire table and
;;     writes it in exactly one `write-region' call.
;;   - That same `write-region', on this build, ALSO signals a spurious
;;     error whenever its content contains any non-ASCII character --
;;     i.e. on every real save here, since candidates are Japanese.
;;     Probed with strings of precisely known char-vs-byte length: its
;;     internal check compares the actual UTF-8 BYTE count written
;;     against elisp's CHARACTER count of the string and raises on any
;;     mismatch, even though the byte-for-byte disk write itself
;;     already completed correctly.  `ddskk-user-jisyo-save' therefore
;;     never trusts `write-region's own return/signal contract -- it
;;     verifies success independently by reading the path back
;;     afterwards; see that function's docstring for the detail.
;;   - `file-exists-p' / `file-readable-p' / `file-directory-p' (built
;;     on `nelisp--syscall-stat') were fboundp but UNCONDITIONALLY
;;     returned "absent" for every path tried in this build, including
;;     paths just written and successfully read back moments earlier
;;     (both relative and absolute, both `/'- and `\'-separated). This
;;     module therefore never branches on their result: it treats
;;     `nelisp--syscall-read-file' returning nil as "file missing or
;;     unreadable" (its own documented contract), which needs no stat
;;     call at all.
;;   - `make-directory' was fboundp t but did not actually create a
;;     directory on disk in this build (probed: called on a brand-new
;;     nested path, returned normally with no signal, yet a subsequent
;;     `write-region' into that same path still failed with the same
;;     error a genuinely-missing directory produces, and the directory
;;     was independently confirmed absent from the host filesystem).
;;     `ddskk-user-jisyo-save' still calls it as a harmless best effort
;;     (it may work correctly in other builds / on other platforms) but
;;     never depends on it succeeding -- the real safety net is that a
;;     `write-region' failure is always caught and never propagated.
;;   - `float-time' and `current-time' are fboundp t but BOTH returned a
;;     dummy zero value on their first call in this build and then
;;     ABORTED THE WHOLE PROCESS (uncaught, not even a signal
;;     `condition-case' could intercept -- "form aborted without
;;     signal") on their second call within the same process.  This is
;;     a serious, separate hazard from the already-known "nemacs bridge
;;     GUI float is broken" issue (a different runtime target) and is
;;     why this file contains NO in-process timing instrumentation:
;;     save-cost was instead measured externally, over the wire, by the
;;     verification harness (see the task's worklog / chat report for
;;     the numbers). Do not add a second call to either function
;;     anywhere reachable from this engine.
;;
;; Save timing: measured externally (over the wire -- see commentary
;; above for why an in-process measurement was not safe on this
;; runtime) by isolating the CONTROL CONVERT (search only) vs CONTROL
;; COMMIT (search + record + save) round-trip cost for the same midasi.
;; First measurement, with `ddskk-user-jisyo--serialize-entries' still
;; using nested `mapconcat' + lambda per entry/candidate:
;;   - 2-entry table:   CONVERT ~87ms,  COMMIT ~100ms  -> ~13ms delta.
;;   - 351-entry table: CONVERT ~100ms, COMMIT ~1013ms -> ~900ms delta.
;; After rewriting that function to avoid the nested closures (see its
;; docstring), re-measured under the same conditions:
;;   - 351-entry table: CONVERT ~100ms, COMMIT ~424ms  -> ~324ms delta.
;; The delta scales with table size in both versions (every save
;; serializes and writes the WHOLE table -- `write-region' cannot
;; append on this runtime, see above); the closure removal alone cut
;; the per-save cost at this scale by more than half, confirming the
;; earlier hypothesis that interpreted call/closure overhead, not the
;; underlying disk write, dominates.  ~324-900ms for a few hundred
;; entries is still far past any keystroke-latency budget, so saving on
;; every single confirmation (this module's first-cut behavior) does
;; NOT hold up at scale, exactly as anticipated.  `ddskk-user-jisyo--
;; update' therefore batches: it saves only every `ddskk-user-jisyo-
;; save-batch-size' confirmations (see that variable for why 10, not
;; DDSKK's own `skk-jisyo-save-count' default of 50), and `ddskk-user-
;; jisyo-purge' (an explicit, rare user correction) always flushes
;; immediately rather than waiting for the batch.  Batching amortizes
;; the AVERAGE cost but not the worst case: the occasional batched save
;; at scale is still several hundred ms on this runtime; a fully
;; async/deferred write was judged out of scope for v1 -- this single-
;; threaded engine processes one wire request at a time, so there is no
;; existing background-execution mechanism to defer onto.  A crash or
;; hard kill between batched saves can lose up to `ddskk-user-jisyo-
;; save-batch-size' minus one confirmations: `SHUTDOWN' (windows/host/
;; main.cpp) is handled entirely by the C++ host and never reaches this
;; engine at all, so there is no clean-shutdown hook here to flush on
;; either -- `ddskk-user-jisyo-flush' exists for a future caller that
;; gets one.

;;; Code:

;; --- Storage --------------------------------------------------------------

(defvar ddskk-user-jisyo--table (make-hash-table :test 'equal)
  "MIDASI (string) -> ordered list of candidate strings.
The first element is the most recently confirmed candidate for that
midasi; the list never contains a duplicate (per `equal').")

(defvar ddskk-user-jisyo--last-save-error nil
  "The error signalled by the most recent `ddskk-user-jisyo-save', or nil.
A save failure must never propagate to the caller -- see the file
commentary for why this variable, not a stray stdout write, is this
module's \"debug channel\": stdout is the wire protocol (exactly one
response line per request) and an extra line at an arbitrary point
would desynchronize the host's reads from the engine's own responses.
Inspect this variable directly (e.g. from a test harness loading this
file standalone) to see what went wrong, if anything.")

(defvar ddskk-user-jisyo-save-batch-size
  (let ((env (getenv "DDSKK_USER_JISYO_SAVE_BATCH_SIZE")))
    (if (and env (> (length env) 0) (string-match "\\`[0-9]+\\'" env))
        (max 1 (string-to-number env))
      10))
  "Confirmations between disk saves; see \"Save timing\" above.
Every save serializes and writes the WHOLE table (this runtime's
`write-region' cannot append), and that cost was measured at roughly
2-3ms per entry -- a few hundred entries already means the better part
of a second per save.  Saving on every confirmation therefore does not
scale; this many confirmations are batched into one save instead.
DDSKK's own `skk-jisyo-save-count' defaults to 50 for its much cheaper
incremental save; this one is picked smaller because each save here is
comparatively expensive AND there is no clean-shutdown hook to flush
pending confirmations on this engine (see above) -- a smaller batch
bounds how much can be lost to a crash or hard kill between saves.
`DDSKK_USER_JISYO_SAVE_BATCH_SIZE', when set to a positive integer,
overrides the default -- mirrors the existing `DDSKK_USER_JISYO' /
`DDSKK_ENGINE_DEBUG' env-var pattern, and lets a test harness set this
to 1 to get immediate-save semantics without changing production code.")

(defvar ddskk-user-jisyo--pending-saves 0
  "Confirmations recorded since the last `ddskk-user-jisyo-save' attempt.
Reset to 0 by `ddskk-user-jisyo-flush', whether or not the save
actually succeeded -- a save that keeps failing must not make this
counter grow without bound.")

;; --- Path resolution --------------------------------------------------

(defun ddskk-user-jisyo--default-path ()
  "Return the default per-user learned-dictionary path, or nil.
Built from `LOCALAPPDATA' at call time -- never a literal PC-specific
path.  This is a NEW file, distinct from the SKK server's own personal
dictionary (`SKK-MY-JISYO.utf8', served by skkserv and read via
`ddskk-engine-server-search'); this engine has never written to that
one and still does not.  Returns nil if `LOCALAPPDATA' is unset, which
callers must treat the same as \"no dictionary available\"."
  (let ((base (getenv "LOCALAPPDATA")))
    (and base (concat base "/DDSKK/user-jisyo.utf8"))))

(defun ddskk-user-jisyo-path ()
  "Return the active user-dictionary path, or nil.
`DDSKK_USER_JISYO', when set, overrides the default entirely -- this
is how tests point the engine at a private, disposable file instead of
ever touching the user's real one, mirroring the existing
`DDSKK_ENGINE_DEBUG' pattern read in `ddskk-engine.el'."
  (or (getenv "DDSKK_USER_JISYO") (ddskk-user-jisyo--default-path)))

(defun ddskk-user-jisyo--directory (path)
  "Return the parent directory portion of PATH (text before the last
slash).  Accepts either separator: this runtime's own file syscalls
were confirmed to tolerate both `/' and `\\', including mixed within
one path (see file commentary)."
  (let ((index (length path)) (found nil))
    (while (and (not found) (> index 0))
      (setq index (1- index))
      (when (memq (aref path index) '(?/ ?\\))
        (setq found index)))
    (if found (substring path 0 found) path)))

;; --- Small list helpers -------------------------------------------------

(defun ddskk-user-jisyo--remove-equal (item list)
  "Return a new list: LIST with every element `equal' to ITEM removed."
  (let (out)
    (dolist (x list)
      (unless (equal x item) (push x out)))
    (nreverse out)))

(defun ddskk-user-jisyo--move-to-front (item list)
  "Return a new list: ITEM first, then LIST with ITEM's old occurrence(s)
removed.  This is what keeps a midasi's candidate list duplicate-free
after repeated confirmations of the same word."
  (cons item (ddskk-user-jisyo--remove-equal item list)))

(defun ddskk-user-jisyo--index-of (string char)
  "Return the index of the first occurrence of CHAR in STRING, or nil."
  (let ((count (length string)) (index 0) (found nil))
    (while (and (not found) (< index count))
      (when (= (aref string index) char) (setq found index))
      (setq index (1+ index)))
    found))

;; --- Okuri-ari / okuri-nasi classification -----------------------------

(defun ddskk-user-jisyo--okuri-ari-p (midasi)
  "Return non-nil when MIDASI belongs in the okuri-ari section.
Per the task spec: a midasi is okuri-ari exactly when its last
character is an ASCII lowercase letter (e.g. \"かk\", \"たのs\");
everything else (including the empty string) is okuri-nasi."
  (and (> (length midasi) 0)
       (let ((c (aref midasi (1- (length midasi)))))
         (and (>= c ?a) (<= c ?z)))))

;; --- Parsing (SKK-JISYO -> in-memory table) ------------------------------

(defun ddskk-user-jisyo--split-fields (string)
  "Split STRING on `/' into a list of fields, dropping empty fields.
SKK-JISYO candidate fields never contain `/' themselves, so a manual
scan (mirroring `ddskk-engine--parse-server-reply's style in
`ddskk-engine.el') is enough -- no regex engine needed."
  (let ((count (length string)) (fields nil) (start 0) (index 0))
    (while (< index count)
      (when (= (aref string index) ?/)
        (when (> index start) (push (substring string start index) fields))
        (setq start (1+ index)))
      (setq index (1+ index)))
    (when (> count start) (push (substring string start count) fields))
    (nreverse fields)))

(defun ddskk-user-jisyo--plain-candidates (fields)
  "Return FIELDS with every `[...]' okurigana-ranking block dropped.
Each such block starts with a field beginning with `[' and ends with
the literal field `]'.  SKK-JISYO's okuri-ari ranking blocks are not
nested, so one skip flag is enough.  This is the v1 simplification
documented at the top of this file: only the plain candidate list
ahead of the first `[' survives."
  (let (out (skipping nil))
    (dolist (field fields)
      (cond
       (skipping (when (equal field "]") (setq skipping nil)))
       ((and (> (length field) 0) (= (aref field 0) ?\[)) (setq skipping t))
       (t (push field out))))
    (nreverse out)))

(defun ddskk-user-jisyo--parse-line (line)
  "Parse one SKK-JISYO entry LINE into (MIDASI . CANDIDATES), or nil.
Returns nil (\"skip, do not error\") for comment lines (leading `;'),
blank lines, and any line that does not have the `MIDASI /CAND/.../'
shape -- this is what makes `ddskk-user-jisyo-load' tolerant of a
malformed file."
  (if (or (= (length line) 0) (= (aref line 0) ?\;))
      nil
    (let ((space (ddskk-user-jisyo--index-of line ?\s)))
      (when space
        (let ((midasi (substring line 0 space))
              (rest (substring line (1+ space))))
          (when (and (> (length rest) 0) (= (aref rest 0) ?/))
            (let ((candidates (ddskk-user-jisyo--plain-candidates
                                (ddskk-user-jisyo--split-fields rest))))
              (and candidates (cons midasi candidates)))))))))

(defun ddskk-user-jisyo--parse-into-table (text table)
  "Parse TEXT (whole SKK-JISYO file contents) and populate TABLE.
TABLE maps MIDASI -> CANDIDATES, in file order (so a freshly loaded
file already reflects whatever priority order it was last saved in)."
  (let ((len (length text)) (pos 0))
    (while (< pos len)
      (let ((nl pos))
        (while (and (< nl len) (/= (aref text nl) ?\n))
          (setq nl (1+ nl)))
        (let ((parsed (ddskk-user-jisyo--parse-line (substring text pos nl))))
          (when parsed (puthash (car parsed) (cdr parsed) table)))
        (setq pos (1+ nl))))))

;; --- Load / Save ------------------------------------------------------

(defun ddskk-user-jisyo-load ()
  "Populate the in-memory personal dictionary from disk.
Called once at engine start.  A missing or unreadable file is NOT an
error -- an empty table is exactly the correct starting state -- and a
malformed file degrades to whatever entries did parse.  This never
signals.  See the file commentary for why this deliberately never
calls `file-exists-p' / `file-readable-p' (both were found to always
report \"absent\" on this runtime build) and instead relies purely on
`nelisp--syscall-read-file's own documented nil-on-failure contract."
  (clrhash ddskk-user-jisyo--table)
  (let ((path (ddskk-user-jisyo-path)))
    (when (stringp path)
      (let ((text (ignore-errors (nelisp--syscall-read-file path))))
        (when (stringp text)
          (ignore-errors
            (ddskk-user-jisyo--parse-into-table text ddskk-user-jisyo--table))))))
  t)

(defun ddskk-user-jisyo--serialize-entries (entries)
  "Render ENTRIES (list of (MIDASI . CANDIDATES)) as SKK-JISYO lines.
Builds the output with `dolist' + `push' + a single trailing `concat'
rather than nested `mapconcat' + lambda calls -- on this runtime, every
interpreted function/closure call has real, measurable overhead (see
the \"Save timing\" commentary at the top of this file), and the
nested form was one closure invocation per entry PLUS one per
candidate.  This version keeps `car'/`cdr' access and string literals
only, no per-item closures."
  (let (chunks)
    (dolist (entry entries)
      (push (car entry) chunks)
      (push " /" chunks)
      (dolist (candidate (cdr entry))
        (push candidate chunks)
        (push "/" chunks))
      (push "\n" chunks))
    (apply #'concat (nreverse chunks))))

(defun ddskk-user-jisyo--serialize ()
  "Return the whole in-memory personal dictionary as one SKK-JISYO string.
Both section headers are always emitted, even when a section is empty,
so the file stays parseable (by this module and by other SKK-JISYO
tools) regardless of which kind of word was learned first."
  (let (ari nasi)
    (maphash (lambda (midasi candidates)
               (if (ddskk-user-jisyo--okuri-ari-p midasi)
                   (push (cons midasi candidates) ari)
                 (push (cons midasi candidates) nasi)))
             ddskk-user-jisyo--table)
    (concat ";;; -*- coding: utf-8 -*-\n"
            ";; okuri-ari entries.\n"
            (ddskk-user-jisyo--serialize-entries ari)
            ";; okuri-nasi entries.\n"
            (ddskk-user-jisyo--serialize-entries nasi))))

(defun ddskk-user-jisyo-save ()
  "Write the whole in-memory personal dictionary to disk in one call.
`write-region' on this runtime truncate-writes only (it signals on
APPEND), so the whole table is always serialized and written as a
single call, never incrementally -- see file commentary.

This runtime build's `write-region' was found, empirically, to raise a
SPURIOUS error whenever the content contains any non-ASCII character
-- which every real save here does, since candidates are Japanese: its
internal check compares the actual UTF-8 BYTE count written against
elisp's CHARACTER count of the string and signals on any mismatch,
even though the byte-for-byte disk write itself already completed
correctly (confirmed by probing with strings of precisely known
char-vs-byte length; see file commentary).  So this function does not
trust `write-region's own return/signal contract: it swallows
whatever `write-region' does locally, then independently verifies
success the same way `ddskk-user-jisyo-load' establishes \"file
present\" -- by reading the path back and comparing it, byte for byte,
against the content just asked to be written.  Genuine failures (e.g.
a missing parent directory, where nothing was written at all) still
surface as a mismatch here and are reported as an error like any other.

A write failure is caught and never propagated -- a broken personal-
dictionary save must not turn an otherwise-normal keystroke
confirmation into an ERR response.  Sets
`ddskk-user-jisyo--last-save-error' to nil on success or to the
signalled error on failure; never signals itself."
  (setq ddskk-user-jisyo--last-save-error nil)
  (condition-case err
      (let ((path (ddskk-user-jisyo-path))
            (content (ddskk-user-jisyo--serialize)))
        (unless (stringp path)
          (signal 'error (list "DDSKK_USER_JISYO/LOCALAPPDATA unresolved, cannot save")))
        (when (fboundp 'make-directory)
          ;; Best effort only -- probed non-functional in this runtime
          ;; build (see file commentary), but harmless to attempt, and
          ;; may work on other builds/platforms.
          (ignore-errors (make-directory (ddskk-user-jisyo--directory path) t)))
        ;; Swallow whatever `write-region' itself reports (see docstring
        ;; above for why it cannot be trusted here) and verify the real
        ;; outcome by reading the path back.
        (condition-case nil (write-region content nil path) (error nil))
        (unless (equal (nelisp--syscall-read-file path) content)
          (signal 'error (list "write-region verification read-back mismatch" path)))
        t)
    (error
     (setq ddskk-user-jisyo--last-save-error err)
     nil)))

(defun ddskk-user-jisyo-flush ()
  "Save immediately and reset the pending-confirmation batch counter.
See `ddskk-user-jisyo-save-batch-size' for why `ddskk-user-jisyo--
update' does not call `ddskk-user-jisyo-save' directly on every
confirmation."
  (setq ddskk-user-jisyo--pending-saves 0)
  (ddskk-user-jisyo-save))

;; --- Search / record / purge API ---------------------------------------

(defun ddskk-user-jisyo-search ()
  "Search the learned personal dictionary for the current midasi.
Installed at the FRONT of `skk-search-prog-list' in `ddskk-engine.el',
ahead of `ddskk-engine-server-search'.  DDSKK binds `skk-henkan-key' to
the midasi for the duration of the search (same contract
`ddskk-engine-server-search' already relies on)."
  (gethash skk-henkan-key ddskk-user-jisyo--table))

(defun ddskk-user-jisyo-record (midasi candidate)
  "Move CANDIDATE to the front of MIDASI's learned candidate list.
Creates the list if MIDASI has never been learned before."
  (puthash midasi
           (ddskk-user-jisyo--move-to-front
            candidate (gethash midasi ddskk-user-jisyo--table))
           ddskk-user-jisyo--table))

(defun ddskk-user-jisyo-purge (midasi candidate)
  "Remove CANDIDATE from MIDASI's learned list.
Drops the MIDASI key entirely once its candidate list becomes empty,
so an emptied entry does not linger as a spurious (but harmless, since
empty-list and absent-key both `gethash' to nil) table entry."
  (let ((remaining (ddskk-user-jisyo--remove-equal
                     candidate (gethash midasi ddskk-user-jisyo--table))))
    (if remaining
        (puthash midasi remaining ddskk-user-jisyo--table)
      (remhash midasi ddskk-user-jisyo--table))))

;; --- `skk-update-jisyo-function' override -------------------------------

(defun ddskk-user-jisyo--update (word &optional purge)
  "Learn WORD as the confirmed candidate for the current midasi.
Installed as `skk-update-jisyo-function' -- see `skk.el's
`skk-update-jisyo' (\"(funcall skk-update-jisyo-function word purge)\")
-- in place of the stock `skk-update-jisyo-original', which this
engine cannot use (it reads via `skk-get-jisyo-buffer', a `(when skk-
jisyo ...)' no-op here since `skk-jisyo' is nil by design; see
`ddskk-engine.el').  `skk-henkan-key' still holds the midasi at the
call site that reaches here -- see the file commentary for the exact
source line trace confirming this.  PURGE non-nil removes WORD instead
of learning it, mirroring `skk-update-jisyo-original's contract, and
always flushes to disk immediately (an explicit user correction, and
rare enough that batching it away is not worth the risk of losing it).
An ordinary (non-purge) confirmation only records in memory and
increments `ddskk-user-jisyo--pending-saves'; the actual disk save is
batched every `ddskk-user-jisyo-save-batch-size' confirmations -- see
the \"Save timing\" commentary at the top of this file for the
measurement that motivated batching over saving on every call."
  (when (and (boundp 'skk-henkan-key) (stringp skk-henkan-key) (stringp word))
    (if purge
        (progn
          (ddskk-user-jisyo-purge skk-henkan-key word)
          (ddskk-user-jisyo-flush))
      (ddskk-user-jisyo-record skk-henkan-key word)
      (setq ddskk-user-jisyo--pending-saves (1+ ddskk-user-jisyo--pending-saves))
      (when (>= ddskk-user-jisyo--pending-saves ddskk-user-jisyo-save-batch-size)
        (ddskk-user-jisyo-flush)))))

(provide 'skk-user-jisyo)

;;; skk-user-jisyo.el ends here
