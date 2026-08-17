;;; nelisp-ime.el --- Portable NeLisp input method framework core  -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; OS-independent input method sessions.  Platform adapters normalize native
;; key events before calling this package and render the returned snapshot with
;; InputMethodKit, Fcitx/IBus, or TSF.
;;
;; This file is the engine-agnostic framework: composition sessions, reading
;; accumulation (kana and romaji), candidate/segment selection, frequency
;; learning, and the engine registry.  Conversion itself is pluggable — an
;; engine registers a `:convert' function under a name (see
;; `nelisp-ime-engine-register'), sessions select one with the `:engine'
;; option, and `nelisp-ime-default-engine' names the fallback.  The bundled
;; minimum-cost lattice engine lives in `nelisp-ime-lattice' and registers
;; itself as `lattice'.

;;; Code:

(require 'cl-lib)
(require 'nelisp-ime-input)

(defgroup nelisp-ime nil
  "Portable input method framework core."
  :group 'nelisp
  :prefix "nelisp-ime-")

(defvar nelisp-ime-sessions (make-hash-table :test 'equal)
  "Active input sessions keyed by platform-supplied string identifiers.")

(defvar nelisp-ime-dictionary nil
  "Alist mapping readings to ordered conversion candidates.

A candidate may be a surface string or a plist containing :surface and
:cost.  Lower costs win.  String candidates receive costs from their order.")

(defvar nelisp-ime-learning (make-hash-table :test 'equal)
  "Selection frequencies keyed by a reading and surface pair.")

(defvar nelisp-ime-learning-weight 100
  "Cost reduction applied for each learned candidate selection.")

(defvar nelisp-ime-learning-journal-file nil
  "Journal path for commit-time learning appends, or nil to disable.
`nelisp-ime-learning-save' sets this alongside the table it writes; see
the learning journal section for why commits do not rewrite the table.")

(defvar nelisp-ime-converter-function nil
  "Function called with READING and CONTEXT to produce a conversion plist.

When non-nil this overrides `nelisp-ime-default-engine' for sessions that
did not select an engine explicitly.  Prefer registering an engine with
`nelisp-ime-engine-register'; this variable remains as the low-level hook.")

;;; Engine registry

(defvar nelisp-ime-engines (make-hash-table :test 'eq)
  "Registered conversion engines keyed by symbol name.")

(defvar nelisp-ime-default-engine 'lattice
  "Engine used by sessions that do not select one explicitly.

The name only takes effect once an engine registers under it, so the
framework loads without any engine and adapters may swap the default before
or after engines load.")

(defconst nelisp-ime-modes
  '(hiragana katakana latin wide-latin abbrev preedit candidate)
  "Input modes an engine may report through its :mode hook.

Platform mode indicators and language-bar buttons render these directly, so
the set is fixed by the framework rather than by any single engine.
Engines without modal behavior report `preedit' while composing,
`candidate' while a candidate list is open, and `hiragana' otherwise.")

;;;###autoload
(defun nelisp-ime-engine-register (name &rest hooks)
  "Register conversion engine NAME with HOOKS and return NAME.

NAME is a symbol.  HOOKS is a plist:
  :convert  function of READING and CONTEXT returning a plist with
            :preedit, :candidates, and :segments — the same contract as
            `nelisp-ime-converter-function'.
  :feed     function of SESSION-ID, SESSION, and EVENT returning a public
            snapshot.  A modal engine (SKK-style) that owns key handling
            supplies this to intercept every event before the framework's
            default composition pipeline; such an engine may omit :convert.
  :learn    (optional) function of SEGMENTS called on commit in place of
            the framework frequency learning.
  :mode     (optional) function of SESSION returning the input mode symbol
            reported in snapshots (see `nelisp-ime-modes').  Modal engines
            supply this so platform mode indicators and language-bar
            buttons track the engine's own mode instead of guessing.
  :reset    (optional) function of SESSION-ID and SESSION that discards
            engine-side composition state without closing the session.
            Adapters call it to resynchronize after the application
            terminated a composition behind the engine's back.
  :maintain (optional) function of an OPERATION symbol (see
            `nelisp-ime-maintain') performing engine-side housekeeping such
            as collecting garbage or compacting a learning journal.  Return
            value is reported to the caller.

At least one of :convert or :feed is required.  Registering NAME again
replaces the previous definition."
  (unless (symbolp name)
    (error "nelisp-ime: engine name must be a symbol"))
  (unless (or (functionp (plist-get hooks :convert))
              (functionp (plist-get hooks :feed)))
    (error "nelisp-ime: engine %s requires :convert or :feed" name))
  (puthash name (append (list :name name) hooks) nelisp-ime-engines)
  name)

(defun nelisp-ime-engine-get (name)
  "Return the engine plist registered under symbol NAME, or nil."
  (and (symbolp name) name (gethash name nelisp-ime-engines)))

(defun nelisp-ime-engine-names ()
  "Return registered engine names sorted by `string<'."
  (let (names)
    (maphash (lambda (name _engine) (push name names)) nelisp-ime-engines)
    (sort names (lambda (left right)
                  (string< (symbol-name left) (symbol-name right))))))

(defun nelisp-ime--session-engine (session)
  "Return the engine plist governing SESSION, or nil for the legacy hook.

Resolution order: the session's :engine name, then
`nelisp-ime-converter-function' (which returns nil here so the caller uses
the hook directly), then `nelisp-ime-default-engine'."
  (let ((name (plist-get session :engine)))
    (cond
     (name (or (nelisp-ime-engine-get name)
               (error "nelisp-ime: unknown engine %s" name)))
     (nelisp-ime-converter-function nil)
     (t (nelisp-ime-engine-get nelisp-ime-default-engine)))))

(defun nelisp-ime--convert (session reading context)
  "Convert READING with CONTEXT using the engine governing SESSION."
  (let ((engine (nelisp-ime--session-engine session)))
    (funcall (or (and engine (plist-get engine :convert))
                 nelisp-ime-converter-function
                 #'nelisp-ime-dictionary-convert)
             reading context)))

;;; Reference exact-match engine

(defun nelisp-ime-dictionary-convert (reading _context)
  "Convert READING using `nelisp-ime-dictionary'.

The first candidate is the live preedit.  An unknown reading remains kana.
This exact-reading converter is intentionally small; lattice or modal
engines replace it without changing the session or platform adapter APIs."
  (let ((candidates (cdr (assoc reading nelisp-ime-dictionary))))
    (list :preedit (or (car candidates) reading)
          :candidates (or candidates (and (> (length reading) 0)
                                          (list reading)))
          :segments (and (> (length reading) 0)
                         (list (list :from 0 :to (length reading)
                                     :reading reading
                                     :candidate (or (car candidates)
                                                    reading)))))))

(nelisp-ime-engine-register 'dictionary
                            :convert #'nelisp-ime-dictionary-convert)

;;; Shared candidate and learning helpers

(defun nelisp-ime--candidate-normalize (candidate rank)
  "Return a normalized candidate plist for CANDIDATE at RANK.

An :annotation carried by a plist candidate survives normalization: SKK
dictionaries gloss homophones this way and candidate windows show the
gloss beside the surface, so it must not be flattened away."
  (cond
   ((stringp candidate) (list :surface candidate :cost (+ 100 (* rank 10))))
   ((and (listp candidate) (stringp (plist-get candidate :surface)))
    ;; Preserve every engine-supplied key, not just the two the framework
    ;; owns: SKK dictionaries gloss homophones with :annotation and lattice
    ;; engines carry part-of-speech and connection ids for path scoring, and
    ;; all of it has to survive normalization to reach the candidate window.
    (let ((normalized (copy-sequence candidate)))
      (plist-put normalized :cost
                 (or (plist-get normalized :cost) (+ 100 (* rank 10))))
      normalized))
   (t (error "nelisp-ime: invalid dictionary candidate %S" candidate))))

(defun nelisp-ime--learning-key (reading surface)
  "Return an unambiguous learning key for READING and SURFACE."
  (cons reading surface))

(defun nelisp-ime-learning-count (reading surface)
  "Return learned selection count for READING and SURFACE."
  (or (gethash (nelisp-ime--learning-key reading surface)
               nelisp-ime-learning)
      0))

(defun nelisp-ime--learn-segments (segments)
  "Increase selection frequencies represented by SEGMENTS."
  (dolist (segment segments)
    (let* ((reading (plist-get segment :reading))
           (surface (plist-get segment :candidate))
           (key (and reading surface
                     (nelisp-ime--learning-key reading surface))))
      (when key
        (puthash key (1+ (or (gethash key nelisp-ime-learning) 0))
                 nelisp-ime-learning)
        (nelisp-ime-learning-journal-append reading surface)))))

(defun nelisp-ime-learning-export ()
  "Return deterministic readable learning rows."
  (let (rows)
    (maphash (lambda (key count)
               (push (list (car key) (cdr key) count) rows))
             nelisp-ime-learning)
    (sort rows
          (lambda (left right)
            (or (string< (car left) (car right))
                (and (equal (car left) (car right))
                     (string< (nth 1 left) (nth 1 right))))))))

(defun nelisp-ime-learning-import (rows)
  "Replace learning state with validated ROWS and return its row count."
  (when (vectorp rows) (setq rows (append rows nil)))
  (unless (listp rows) (error "nelisp-ime: invalid learning rows"))
  (let ((table (make-hash-table :test 'equal)))
    (dolist (row rows)
      (when (vectorp row) (setq row (append row nil)))
      (unless (and (listp row) (= (length row) 3)
                   (stringp (nth 0 row)) (stringp (nth 1 row))
                   (integerp (nth 2 row)) (>= (nth 2 row) 0))
        (error "nelisp-ime: invalid learning row %S" row))
      (puthash (nelisp-ime--learning-key (nth 0 row) (nth 1 row))
               (nth 2 row) table))
    (setq nelisp-ime-learning table)
    (hash-table-count table)))

;;;###autoload
(defun nelisp-ime-learning-save (file)
  "Atomically save learning state to FILE and adopt its journal.

Subsequent commits append to FILE's journal instead of rewriting the whole
table; see `nelisp-ime-learning-compact'."
  (let ((temporary (concat file ".tmp"))
        ;; Learning rows are Japanese, and the host default coding is
        ;; locale-dependent: an encoding it cannot represent makes the write
        ;; ask which coding system to use, which in batch mode fails outright.
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory (expand-file-name file)) t)
    (with-temp-file temporary
      (let ((print-length nil) (print-level nil))
        (prin1 (nelisp-ime-learning-export) (current-buffer))
        (insert "\n")))
    (rename-file temporary file t)
    (setq nelisp-ime-learning-journal-file
          (nelisp-ime--learning-journal-path file))
    file))

;;;###autoload
(defun nelisp-ime-learning-load (file)
  "Load validated learning state from FILE without evaluating code.

An adjacent journal written by `nelisp-ime-learning-journal-append' is
replayed on top, so selections recorded since the last full save are not
lost."
  (let ((rows (if (not (file-readable-p file))
                  0
                (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8-unix))
                    (insert-file-contents file))
                  (let* ((parsed (read-from-string (buffer-string)))
                         (rows (car parsed))
                         (end (cdr parsed)))
                    (unless (string-match-p "\\`[[:space:]]*\\'"
                                            (substring (buffer-string) end))
                      (error "nelisp-ime: trailing learning data"))
                    (nelisp-ime-learning-import rows))))))
    (nelisp-ime--learning-journal-replay file)
    rows))

;;; Learning journal
;;
;; Rewriting the whole learning table on every commit puts a file write on
;; the keystroke path.  Commits instead append one line to a journal and the
;; table is folded back only during idle housekeeping (`compact'), which is
;; what `nelisp-ime-maintain' exists for.

(defun nelisp-ime--learning-journal-path (file)
  "Return the journal path paired with learning table FILE."
  (concat file ".journal"))

(defun nelisp-ime-learning-journal-append (reading surface)
  "Append one learned READING and SURFACE selection to the journal."
  (when nelisp-ime-learning-journal-file
    (let ((line (let ((print-length nil) (print-level nil))
                  (concat (prin1-to-string (list reading surface)) "\n")))
          ;; Same reason as `nelisp-ime-learning-save': the rows are Japanese
          ;; and a host default coding that cannot encode them turns the write
          ;; into a coding-system prompt, which fails outright in batch mode.
          (coding-system-for-write 'utf-8-unix))
      (make-directory
       (file-name-directory
        (expand-file-name nelisp-ime-learning-journal-file))
       t)
      (write-region line nil nelisp-ime-learning-journal-file t 'silent))))

(defun nelisp-ime--learning-journal-replay (file)
  "Fold the journal paired with FILE into the in-memory learning table."
  (let ((journal (nelisp-ime--learning-journal-path file))
        (replayed 0))
    (when (file-readable-p journal)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8-unix))
          (insert-file-contents journal))
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-match-p "\\`[[:space:]]*\\'" line)
              ;; A torn final line (power loss mid-append) must not make the
              ;; whole table unreadable — skip it and keep the rest.
              (let ((entry (condition-case nil
                               (car (read-from-string line))
                             (error nil))))
                (when (and (listp entry) (= (length entry) 2)
                           (stringp (nth 0 entry)) (stringp (nth 1 entry)))
                  (let ((key (nelisp-ime--learning-key (nth 0 entry)
                                                       (nth 1 entry))))
                    (puthash key (1+ (or (gethash key nelisp-ime-learning) 0))
                             nelisp-ime-learning)
                    (setq replayed (1+ replayed)))))))
          (forward-line 1))))
    replayed))

;;;###autoload
(defun nelisp-ime-learning-compact (file)
  "Write the learning table to FILE, drop its journal, return the row count.

This is the `compact' housekeeping operation: it performs the full table
write that commits deliberately skip.  The in-memory table already
reflects every journalled selection — `nelisp-ime-learning-load' replays
the journal and live commits update the table as they append — so
compaction must not replay again or it would double-count."
  (nelisp-ime-learning-save file)
  (let ((journal (nelisp-ime--learning-journal-path file)))
    (when (file-exists-p journal) (delete-file journal)))
  (hash-table-count nelisp-ime-learning))

;;; Sessions

(defun nelisp-ime--check-session-id (session-id)
  "Require SESSION-ID to be a non-empty string."
  (unless (and (stringp session-id) (> (length session-id) 0))
    (error "nelisp-ime: session id must be a non-empty string")))

(defun nelisp-ime--session (session-id)
  "Return SESSION-ID state or signal an error when it is not open."
  (or (gethash session-id nelisp-ime-sessions)
      (error "nelisp-ime: unknown session %s" session-id)))

(defun nelisp-ime--segment-preedit (segments)
  "Concatenate selected candidates from SEGMENTS."
  (mapconcat (lambda (segment) (plist-get segment :candidate)) segments ""))

(defun nelisp-ime--reconvert (session)
  "Convert SESSION's reading and return SESSION holding the result.

Only ever reached through an explicit `:convert' (or a re-convert of an
already-converted composition) -- see `nelisp-ime--retype' for why
typing must not come through here."
  (let* ((reading (plist-get session :reading))
         (context (plist-get session :context))
         (conversion (nelisp-ime--convert session reading context)))
    (setq session (plist-put session :preedit
                             (or (plist-get conversion :preedit) reading)))
    (setq session (plist-put session :candidates
                             (plist-get conversion :candidates)))
    (setq session (plist-put session :segments
                             (plist-get conversion :segments)))
    (setq session (plist-put session :active-segment 0))
    (setq session (plist-put session :converted t))
    (plist-put session :candidate-index 0)))

(defun nelisp-ime--settle (session)
  "Accept SESSION's conversion into the settled prefix and return SESSION.

Typing after a conversion neither discards it nor re-reads it: the
conversion is accepted where it stands, and the key that arrived starts
a fresh reading behind it.  DDSKK does exactly this on the same wire --
▼今日 then `h' renders 今日h -- and doing the opposite is what reached
the user as \"「今日」に変換された後で「は」を打つと「きょうは」に戻る\".

Learning happens here rather than at commit because by commit these
segments are no longer in the session; a candidate the user chose and
then typed past was still chosen."
  (if (not (plist-get session :converted))
      session
    (let* ((engine (nelisp-ime--session-engine session))
           (learn (and engine (plist-get engine :learn))))
      (funcall (or learn #'nelisp-ime--learn-segments)
               (plist-get session :segments)))
    (setq session (plist-put session :settled
                             (concat (or (plist-get session :settled) "")
                                     (or (plist-get session :preedit) ""))))
    (setq session (plist-put session :reading ""))
    (setq session (plist-put session :preedit ""))
    (setq session (plist-put session :candidates nil))
    (setq session (plist-put session :segments nil))
    (setq session (plist-put session :active-segment 0))
    (setq session (plist-put session :candidate-index 0))
    (plist-put session :converted nil)))

(defun nelisp-ime--retype (session)
  "Show SESSION's reading unconverted and return SESSION.

The typing path.  Converting on every keystroke was how the framework
worked, and it made the IME unusable in practice: each character
replaced the composition with a guess at the whole reading so far and
reopened the candidate window, so what the user had typed kept being
rewritten underneath them.  Conversion belongs to `:convert' alone;
until then the composition shows exactly the kana that were typed."
  (setq session (plist-put session :preedit (plist-get session :reading)))
  (setq session (plist-put session :candidates nil))
  (setq session (plist-put session :segments nil))
  (setq session (plist-put session :active-segment 0))
  (setq session (plist-put session :converted nil))
  (plist-put session :candidate-index 0))

(defvar nelisp-ime-candidate-limit 30
  "Maximum candidates carried per list in a public snapshot, nil = all.

Snapshots are produced on every keystroke and cross the JSON-RPC
boundary; short readings can carry hundreds of homophones, and encoding
them dominated live-conversion latency.  Candidate windows show far
fewer, so snapshots truncate.  Selection operations index into the
truncated list the adapter received, so they stay consistent.")

(defvar nelisp-ime-snapshot-detail 'full
  "How much of the composition a snapshot carries: `full' or `compact'.

A compact snapshot omits the candidate lists and the segment breakdown,
keeping the reading, preedit, mode, and cursor an adapter needs to paint
the composition.  It exists because encoding cost tracks payload size:
one full snapshot of a sentence is ~1078 characters, and the standalone
runtime charges roughly a millisecond per character to encode.

Adapters that only open a candidate window on demand should run sessions
compact and ask for a full snapshot with `nelisp-ime-session-status' when
the window opens.  Selection operations always answer in full, because
the adapter needs the list it is selecting from.  The default stays
`full' so existing adapters keep working unchanged.")

(defun nelisp-ime--compact-p (&optional session)
  "Return non-nil when SESSION's snapshots omit candidates and segments."
  (eq (or (and session (plist-get session :detail))
          nelisp-ime-snapshot-detail)
      'compact))

(defun nelisp-ime--candidate-vector (candidates)
  "Return CANDIDATES as a vector truncated to `nelisp-ime-candidate-limit'."
  (let ((limit nelisp-ime-candidate-limit))
    (if (and limit (> (length candidates) limit))
        (let ((vector (make-vector limit nil))
              (index 0))
          (while (< index limit)
            (aset vector index (nth index candidates))
            (setq index (1+ index)))
          vector)
      (vconcat candidates))))

(defun nelisp-ime--session-mode (session)
  "Return the input mode symbol reported for SESSION.

An engine's :mode hook wins so modal engines stay authoritative.  The
framework fallback derives a mode from composition state, which is what a
non-modal engine's mode indicator should show anyway."
  (let* ((engine (nelisp-ime--session-engine session))
         (hook (and engine (plist-get engine :mode)))
         (mode (and hook (funcall hook session))))
    (cond
     ((memq mode nelisp-ime-modes) mode)
     ((> (length (or (plist-get session :candidates) nil)) 1) 'candidate)
     ((or (> (length (or (plist-get session :reading) "")) 0)
          (> (length (or (plist-get session :pending) "")) 0))
      'preedit)
     (t 'hiragana))))

(defun nelisp-ime--snapshot (session &optional commit)
  "Return the public representation of SESSION, optionally with COMMIT text."
  ;; `preedit' and `pending' stay separate all the way to the adapter.
  ;; Folding the unresolved romaji into the preedit here made every
  ;; adapter that renders the two fields -- the STATE line one does, and
  ;; so does the TSF host behind it -- show it twice, so a half-typed
  ;; `k' appeared as "kk".
  ;; The settled prefix is part of the composition the adapter paints, so
  ;; it is folded in here -- one text field on the wire, and the caret
  ;; belongs after all of it.  It stays a separate session field so that
  ;; `:convert' and the candidate lists apply to the current reading only.
  (let* ((preedit (concat (or (plist-get session :settled) "")
                          (or (plist-get session :preedit) "")))
         (pending (or (plist-get session :pending) ""))
         (composing (> (+ (length preedit) (length pending)) 0)))
    (list :consumed t
          :reading (plist-get session :reading)
          :preedit preedit
          ;; Platform adapters need more than the preedit text to render a
          ;; composition: `mode' drives mode indicators and language-bar
          ;; buttons, `cursor' places the caret inside the preedit, and
          ;; `composition-start' marks where the composition begins (-1 when
          ;; no composition is open, so a direct commit is distinguishable
          ;; from an empty one).
          ;; Snapshots are wire-ready: every field must survive JSON
          ;; encoding, so the mode crosses as its name rather than a symbol.
          :mode (symbol-name (nelisp-ime--session-mode session))
          :cursor (length preedit)
          :composition-start (if composing 0 -1)
          :segments
          (if (nelisp-ime--compact-p session)
              []
            (vconcat
             (mapcar (lambda (segment)
                       (let ((copy (copy-sequence segment)))
                         (plist-put copy :candidates
                                    (nelisp-ime--candidate-vector
                                     (plist-get copy :candidates)))))
                     (or (plist-get session :segments) nil))))
          :candidates (if (nelisp-ime--compact-p session)
                          []
                        (nelisp-ime--candidate-vector
                         (plist-get session :candidates)))
          :candidate-index (plist-get session :candidate-index)
          :active-segment (plist-get session :active-segment)
          :pending (plist-get session :pending)
          :commit commit)))

;;;###autoload
(defun nelisp-ime-session-open (session-id &optional options)
  "Open or replace SESSION-ID using platform-neutral OPTIONS.

OPTIONS may contain :input-style, :context, and :engine.  Input-style is
metadata for the platform adapter; physical key layout normalization stays
outside core.  :engine names a registered conversion engine for this
session; omitting it defers to `nelisp-ime-converter-function' and then
`nelisp-ime-default-engine'."
  (nelisp-ime--check-session-id session-id)
  (let ((engine (plist-get options :engine)))
    (when engine
      (unless (nelisp-ime-engine-get engine)
        (error "nelisp-ime: unknown engine %s" engine)))
    (let ((session (list :id session-id
                         :input-style (or (plist-get options :input-style)
                                          'kana)
                         :context (plist-get options :context)
                         :engine engine
                         :detail (or (plist-get options :detail)
                                     nelisp-ime-snapshot-detail)
                         :reading ""
                         :pending ""
                         :preedit ""
                         :settled ""
                         :segments nil
                         :candidates nil
                         :active-segment 0
                         :candidate-index 0)))
      (puthash session-id session nelisp-ime-sessions)
      (nelisp-ime--snapshot session))))

;;;###autoload
(defun nelisp-ime-session-close (session-id)
  "Close SESSION-ID and discard its uncommitted composition."
  (nelisp-ime--check-session-id session-id)
  (remhash session-id nelisp-ime-sessions))

(defun nelisp-ime--store (session-id session)
  "Store SESSION under SESSION-ID and return its public snapshot."
  (puthash session-id session nelisp-ime-sessions)
  (nelisp-ime--snapshot session))

(defun nelisp-ime--insert (session-id session text)
  "Append normalized TEXT to SESSION-ID's reading."
  (unless (stringp text)
    (error "nelisp-ime: :insert requires string :text"))
  (setq session (nelisp-ime--settle session))
  (setq session
        (plist-put session :reading
                   (concat (plist-get session :reading) text)))
  (nelisp-ime--store session-id (nelisp-ime--retype session)))

(defun nelisp-ime--key (session-id session event)
  "Normalize platform-neutral key EVENT and update SESSION-ID."
  ;; A key is typing, so an outstanding conversion is accepted first --
  ;; `nelisp-ime--insert' does the same for its own path, and settling
  ;; twice is a no-op, so the kana branch below may route through it.
  (setq session (nelisp-ime--settle session))
  (let ((style (plist-get session :input-style)))
    (cond
     ((eq style 'kana)
      (let ((kana (nelisp-ime-jis-kana-key
                   (plist-get event :code) (plist-get event :shift))))
        (unless kana (error "nelisp-ime: unmapped kana key"))
        (if (or (equal kana "゛") (equal kana "゜"))
            (progn
              (setq session
                    (plist-put session :reading
                               (nelisp-ime--apply-mark
                                (plist-get session :reading) kana)))
              (nelisp-ime--store session-id (nelisp-ime--retype session)))
          (nelisp-ime--insert session-id session kana))))
     ((eq style 'romaji)
      (let* ((result (nelisp-ime-romaji-step
                      (or (plist-get session :pending) "")
                      (plist-get event :key)))
             (text (plist-get result :text)))
        (setq session (plist-put session :pending
                                 (plist-get result :pending)))
        (when text
          (setq session
                (plist-put session :reading
                           (concat (plist-get session :reading) text))))
        (nelisp-ime--store session-id (nelisp-ime--retype session))))
     (t (error "nelisp-ime: unsupported input style %S" style)))))

(defun nelisp-ime--backspace (session-id session)
  "Remove the final character from SESSION-ID and reconvert."
  (let* ((pending (or (plist-get session :pending) ""))
         (reading (plist-get session :reading))
         (settled (or (plist-get session :settled) "")))
    (cond
     ((> (length pending) 0)
      (setq session (plist-put session :pending
                               (substring pending 0 (1- (length pending))))))
     ((> (length reading) 0)
      (setq session (plist-put session :reading
                               (substring reading 0 (1- (length reading))))))
     ;; Nothing left to retype: eat into what was settled, so backspace
     ;; keeps shortening one composition instead of stopping dead in
     ;; front of an accepted conversion the user can still see.
     ((> (length settled) 0)
      (setq session (plist-put session :settled
                               (substring settled 0 (1- (length settled)))))))
    ;; Deleting returns to typing: a composition being shortened is being
    ;; retyped, not re-converted.
    (nelisp-ime--store session-id (nelisp-ime--retype session))))

(defun nelisp-ime--select-candidate (session-id session index)
  "Select candidate INDEX in SESSION-ID."
  (let* ((segments (plist-get session :segments))
         (active (or (plist-get session :active-segment) 0))
         (segment (nth active segments))
         (candidates (or (plist-get segment :candidates)
                         (plist-get session :candidates))))
    (unless (and (integerp index) (>= index 0) (< index (length candidates)))
      (error "nelisp-ime: candidate index out of range"))
    (setq session (plist-put session :candidate-index index))
    (if segment
        (progn
          (setq segment (plist-put segment :candidate (nth index candidates)))
          (setcar (nthcdr active segments) segment)
          (setq session (plist-put session :segments segments))
          (setq session
                (plist-put session :preedit
                           (nelisp-ime--segment-preedit segments))))
      (setq session (plist-put session :preedit (nth index candidates))))
    (nelisp-ime--store session-id session)))

(defun nelisp-ime--select-segment (session-id session index)
  "Make segment INDEX active in SESSION-ID."
  (let ((segments (plist-get session :segments)))
    (unless (and (integerp index) (>= index 0) (< index (length segments)))
      (error "nelisp-ime: segment index out of range"))
    (let ((candidates (plist-get (nth index segments) :candidates)))
      (setq session (plist-put session :active-segment index))
      (setq session (plist-put session :candidate-index 0))
      (setq session (plist-put session :candidates candidates))
      (nelisp-ime--store session-id session))))

(defun nelisp-ime--finish (session-id session commit-p)
  "Finish SESSION-ID, returning preedit when COMMIT-P is non-nil."
  (when (and commit-p (> (length (or (plist-get session :pending) "")) 0))
    (setq session
          (plist-put session :reading
                     (concat (plist-get session :reading)
                             (nelisp-ime-romaji-flush
                              (plist-get session :pending)))))
    (setq session (plist-put session :pending ""))
    ;; Committing an unconverted composition commits the kana that were
    ;; typed, not a conversion of them: the user never asked for one.
    (setq session (if (plist-get session :converted)
                      (nelisp-ime--reconvert session)
                    (nelisp-ime--retype session))))
  (let ((commit (and commit-p
                     (concat (or (plist-get session :settled) "")
                             (or (plist-get session :preedit) ""))))
        (empty (list :id session-id
                     :input-style (plist-get session :input-style)
                     :context (plist-get session :context)
                     :engine (plist-get session :engine)
                     :reading "" :pending "" :preedit "" :settled ""
                     :segments nil
                     :candidates nil :active-segment 0 :candidate-index 0)))
    (when commit-p
      (let* ((engine (nelisp-ime--session-engine session))
             (learn (and engine (plist-get engine :learn))))
        (funcall (or learn #'nelisp-ime--learn-segments)
                 (plist-get session :segments))))
    (puthash session-id empty nelisp-ime-sessions)
    (nelisp-ime--snapshot empty commit)))

(defun nelisp-ime--dispatch (session-id session event)
  "Apply EVENT to SESSION under SESSION-ID and return a snapshot."
  (let ((engine (nelisp-ime--session-engine session))
        (operation (plist-get event :op)))
    (let ((feed (and engine (plist-get engine :feed))))
      (cond
       (feed (funcall feed session-id session event))
       ((eq operation :key)
        (nelisp-ime--key session-id session event))
       ((eq operation :insert)
        (nelisp-ime--insert session-id session (plist-get event :text)))
       ((eq operation :backspace)
        (nelisp-ime--backspace session-id session))
       ;; Conversion is a request, never a side effect of typing.  Unlike
       ;; :select-candidate this does not force full detail: converting
       ;; does not answer a question about a list, so a compact session
       ;; stays compact and fetches candidates with `session-status'.
       ((eq operation :convert)
        (nelisp-ime--store session-id (nelisp-ime--reconvert session)))
       ;; A selection answer must carry the list being selected from, so
       ;; these two ignore a compact session.
       ((eq operation :select-candidate)
        (let ((nelisp-ime-snapshot-detail 'full))
          (nelisp-ime--select-candidate session-id
                                        (plist-put session :detail 'full)
                                        (plist-get event :index))))
       ((eq operation :select-segment)
        (let ((nelisp-ime-snapshot-detail 'full))
          (nelisp-ime--select-segment session-id
                                      (plist-put session :detail 'full)
                                      (plist-get event :index))))
       ((eq operation :commit)
        (nelisp-ime--finish session-id session t))
       ((eq operation :cancel)
        (nelisp-ime--finish session-id session nil))
       (t (error "nelisp-ime: unsupported operation %S" operation))))))

(defvar nelisp-ime-fail-open t
  "When non-nil, a failing event yields an unconsumed snapshot.

An input method that signals mid-keystroke leaves the user unable to type
at all, so the framework degrades instead: the session is left untouched
and the snapshot reports :consumed nil, which tells the platform adapter
to pass the key through to the application.  Set to nil in tests and
engine development to surface the underlying error.")

;;;###autoload
(defun nelisp-ime-feed (session-id event)
  "Apply normalized EVENT to SESSION-ID and return a composition snapshot.

Supported operations are :key, :insert, :backspace, :select-segment,
:select-candidate, :commit, and :cancel.  Platform adapters retain ownership
of native key codes and UI.

An engine registered with a :feed hook receives every EVENT before the
default composition pipeline and returns the snapshot itself.

When the engine or the event fails and `nelisp-ime-fail-open' is non-nil,
the returned snapshot carries :consumed nil and an :error message instead
of the error propagating to the adapter."
  (let ((session (nelisp-ime--session session-id)))
    (if (not nelisp-ime-fail-open)
        (nelisp-ime--dispatch session-id session event)
      (condition-case err
          (nelisp-ime--dispatch session-id session event)
        (error
         (let ((snapshot (nelisp-ime--snapshot
                          (nelisp-ime--session session-id))))
           (setq snapshot (plist-put snapshot :consumed nil))
           (plist-put snapshot :error (error-message-string err))))))))

;;;###autoload
(defun nelisp-ime-session-reset (session-id)
  "Discard composition state for SESSION-ID and return a fresh snapshot.

Adapters call this to resynchronize after the application terminated a
composition behind the engine's back, or after an IPC timeout left the two
sides disagreeing.  Unlike `nelisp-ime-session-close' the session stays
open with its input style, context, and engine intact."
  (let* ((session (nelisp-ime--session session-id))
         (engine (nelisp-ime--session-engine session))
         (reset (and engine (plist-get engine :reset)))
         (empty (list :id session-id
                      :input-style (plist-get session :input-style)
                      :context (plist-get session :context)
                      :engine (plist-get session :engine)
                      :reading "" :pending "" :preedit "" :segments nil
                      :candidates nil :active-segment 0 :candidate-index 0)))
    (when reset (funcall reset session-id session))
    (puthash session-id empty nelisp-ime-sessions)
    (nelisp-ime--snapshot empty)))

;;;###autoload
(defun nelisp-ime-session-status (session-id &optional detail)
  "Return the snapshot for SESSION-ID without changing any state.

Mode indicators and language-bar buttons poll this; making it explicitly
side-effect free keeps such polling from perturbing composition.  DETAIL
overrides the session's own setting, so an adapter running compact
sessions asks for `full' when it opens a candidate window."
  (let ((session (nelisp-ime--session session-id)))
    (nelisp-ime--snapshot (if detail
                              (plist-put (copy-sequence session) :detail detail)
                            session))))

;;;###autoload
(defun nelisp-ime-maintain (operation &optional engine-name)
  "Run engine housekeeping OPERATION and return its result.

OPERATION is a symbol the engine understands; the framework defines
`gc' (release memory held by the engine) and `compact' (fold an
append-only learning journal into its table).  Housekeeping is separated
from the input path because both are slow enough to be visible as input
latency, so adapters trigger them while the user is idle.

ENGINE-NAME defaults to `nelisp-ime-default-engine'.  An engine without a
:maintain hook returns nil rather than signaling, so adapters can call
this unconditionally."
  (let* ((engine (nelisp-ime-engine-get (or engine-name
                                            nelisp-ime-default-engine)))
         (maintain (and engine (plist-get engine :maintain))))
    (and maintain (funcall maintain operation))))

(provide 'nelisp-ime)
;;; nelisp-ime.el ends here
