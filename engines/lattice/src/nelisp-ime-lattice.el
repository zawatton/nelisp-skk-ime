;;; nelisp-ime-lattice.el --- Bundled lattice conversion engine  -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The dictionary-lattice conversion engine bundled with the nelisp-ime
;; framework.  It registers itself with the engine registry under the name
;; `lattice' (the framework default), so loading this file is what gives a
;; stock install its conversion behavior.
;;
;; This file is deliberately self-contained on top of the framework core
;; (`nelisp-ime') so it can move to its own repository: it owns the indexed
;; dictionary, the SKK dictionary loader with okurigana expansion, and the
;; minimum-cost lattice search.  Alternative engines (for example an SKK
;; modal engine) implement the same `:convert' contract and register under
;; their own names without loading this file.

;;; Code:

(require 'nelisp-ime)

(defvar nelisp-ime-dictionary-index (make-hash-table :test 'equal)
  "Indexed dictionary populated by `nelisp-ime-dictionary-load-skk'.")

(defvar nelisp-ime-system-candidates
  '(("は" "は") ("へ" "へ") ("を" "を") ("に" "に") ("の" "の")
    ("が" "が") ("と" "と") ("で" "で") ("も" "も") ("や" "や")
    ("か" "か") ("ね" "ね") ("よ" "よ") ("です" "です")
    ("ます" "ます") ("でした" "でした") ("ました" "ました")
    ("する" "する") ("します" "します") ("して" "して") ("した" "した")
    ("いる" "いる") ("ある" "ある") ("ない" "ない")
    ("いい" "いい"))
  "Readings whose grammatical kana form must precede dictionary homophones.")

(defvar nelisp-ime-unknown-cost 10000
  "Cost assigned to one unknown kana character in lattice conversion.")

(defconst nelisp-ime-infinity 1000000000000
  "Portable unreachable-path cost for the conversion lattice.")

(defvar nelisp-ime--candidates-cache (make-hash-table :test 'equal)
  "Learning-independent normalized candidates keyed by reading.
Flush with `nelisp-ime-lattice-cache-clear' after replacing the
dictionary; learning changes never require a flush.")

(defun nelisp-ime-lattice-cache-clear ()
  "Flush the normalized-candidate cache after a dictionary change."
  (clrhash nelisp-ime--candidates-cache))

(defun nelisp-ime--learning-affects-p (reading candidates)
  "Return non-nil when READING has learned counts for any of CANDIDATES.
Short-circuits on an empty learning table so the common no-learning case
costs one hash-table-count instead of a walk over every candidate —
short readings carry hundreds, and this runs on every cache hit."
  (and (> (hash-table-count nelisp-ime-learning) 0)
       (let (affected)
         (dolist (candidate candidates)
           (when (> (nelisp-ime-learning-count
                     reading (plist-get candidate :surface))
                    0)
             (setq affected t)))
         affected)))

(defun nelisp-ime--dictionary-candidates-compute (reading)
  "Normalize, deduplicate, and rank-sort dictionary candidates for READING."
  (let ((items (append (cdr (assoc reading nelisp-ime-system-candidates))
                       (or (gethash reading nelisp-ime-dictionary-index)
                           (cdr (assoc reading nelisp-ime-dictionary)))))
        (seen (make-hash-table :test 'equal))
        (rank 0)
        result)
    (dolist (item items)
      (let* ((candidate (nelisp-ime--candidate-normalize item rank))
             (surface (plist-get candidate :surface)))
        (unless (gethash surface seen)
          (puthash surface t seen)
          (push candidate result)))
      (setq rank (1+ rank)))
    (sort (nreverse result)
          (lambda (left right)
            (< (plist-get left :cost) (plist-get right :cost))))))

(defun nelisp-ime--dictionary-candidates (reading)
  "Return normalized dictionary candidates for READING.

The learning-independent normalization (plist conversion, duplicate
removal, rank-cost sort) is cached per reading: the lattice re-looks-up
the same substrings on every keystroke, and short readings can carry
hundreds of homophones, which made the uncached path the dominant cost
of live conversion.  Frequency learning is applied on top only when the
reading actually has learned selections, so the cache never needs
invalidation."
  (let ((cached (gethash reading nelisp-ime--candidates-cache 'miss)))
    (when (eq cached 'miss)
      (setq cached (nelisp-ime--dictionary-candidates-compute reading))
      (puthash reading cached nelisp-ime--candidates-cache))
    (if (nelisp-ime--learning-affects-p reading cached)
        (sort (mapcar (lambda (candidate)
                        (list :surface (plist-get candidate :surface)
                              :cost (- (plist-get candidate :cost)
                                       (* (nelisp-ime-learning-count
                                           reading
                                           (plist-get candidate :surface))
                                          nelisp-ime-learning-weight))))
                      cached)
              (lambda (left right)
                (< (plist-get left :cost) (plist-get right :cost))))
      cached)))

(defun nelisp-ime--skk-candidate (value)
  "Return plain candidate text from SKK VALUE, or nil if unsupported."
  (let* ((annotation (string-match ";" value))
         (surface (if annotation (substring value 0 annotation) value)))
    (when (and (> (length surface) 0)
               (not (= (aref surface 0) 40)))
      surface)))

(defconst nelisp-ime--okuri-forms
  '(("k" ("く" . "く") ("かない" . "かない") ("きます" . "きます")
     ("いた" . "いた") ("いて" . "いて") ("けば" . "けば") ("こう" . "こう"))
    ("g" ("ぐ" . "ぐ") ("がない" . "がない") ("ぎます" . "ぎます")
     ("いだ" . "いだ") ("いで" . "いで") ("げば" . "げば") ("ごう" . "ごう"))
    ("s" ("す" . "す") ("さない" . "さない") ("します" . "します")
     ("した" . "した") ("して" . "して") ("せば" . "せば") ("そう" . "そう"))
    ("t" ("つ" . "つ") ("たない" . "たない") ("ちます" . "ちます")
     ("った" . "った") ("って" . "って") ("てば" . "てば") ("とう" . "とう"))
    ("n" ("ぬ" . "ぬ") ("なない" . "なない") ("にます" . "にます")
     ("んだ" . "んだ") ("んで" . "んで") ("ねば" . "ねば") ("のう" . "のう"))
    ("b" ("ぶ" . "ぶ") ("ばない" . "ばない") ("びます" . "びます")
     ("んだ" . "んだ") ("んで" . "んで") ("べば" . "べば") ("ぼう" . "ぼう"))
    ("m" ("む" . "む") ("まない" . "まない") ("みます" . "みます")
     ("んだ" . "んだ") ("んで" . "んで") ("めば" . "めば") ("もう" . "もう"))
    ("w" ("う" . "う") ("わない" . "わない") ("います" . "います")
     ("った" . "った") ("って" . "って") ("えば" . "えば") ("おう" . "おう"))
    ("r" ("る" . "る") ("らない" . "らない") ("ります" . "ります")
     ("った" . "った") ("って" . "って") ("れば" . "れば") ("ろう" . "ろう"))
    ("i" ("い" . "い") ("くない" . "くない") ("かった" . "かった")
     ("くて" . "くて") ("ければ" . "ければ") ("そう" . "そう")))
  "Conservative conjugation forms used to expand SKK okuri entries.")

(defun nelisp-ime--skk-expand-okuri (reading candidates table)
  "Expand okuri-ari READING and CANDIDATES into TABLE."
  (let* ((end (1- (length reading)))
         (base (substring reading 0 end))
         (code (substring reading end))
         (forms (cdr (assoc code nelisp-ime--okuri-forms))))
    (dolist (form forms)
      (let ((key (concat base (car form)))
            surfaces)
        (dolist (candidate candidates)
          (push (concat candidate (cdr form)) surfaces))
        (puthash key (append (gethash key table) (nreverse surfaces)) table)))))

(defun nelisp-ime--skk-line (line table expand-okuri)
  "Parse one SKK dictionary LINE into TABLE."
  (unless (or (= (length line) 0) (= (aref line 0) ?\;))
    (let ((space (string-match " " line)))
      (when space
        (let* ((reading (substring line 0 space))
               (body (substring line (1+ space)))
               (parts (split-string body "/" t))
               candidates)
          (dolist (part parts)
            (let ((candidate (nelisp-ime--skk-candidate part)))
              (when candidate (push candidate candidates))))
          (setq candidates (nreverse candidates))
          (when candidates
            (if (and (> (length reading) 0)
                     (< (aref reading (1- (length reading))) 128))
                (when expand-okuri
                  (nelisp-ime--skk-expand-okuri reading candidates table))
              (puthash reading candidates table))))))))

(defun nelisp-ime-dictionary-install (entries)
  "Install portable dictionary ENTRIES and return their count.

ENTRIES is an alist whose keys are readings and whose values are candidate
lists.  This representation can be loaded by standalone NeLisp without
depending on editor buffer primitives."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry entries)
      (puthash (car entry) (cdr entry) table))
    (setq nelisp-ime-dictionary-index table)
    (nelisp-ime-lattice-cache-clear)
    (hash-table-count table)))

;;;###autoload
(defun nelisp-ime-dictionary-load-skk (file &optional coding expand-okuri)
  "Load SKK dictionary FILE into an indexed table and return entry count.

CODING defaults to euc-jp, the canonical SKK distribution encoding.  Lisp
expression candidates are ignored; plain candidates and annotations are safe."
  (let ((coding-system-for-read (or coding 'euc-jp))
        (table (make-hash-table :test 'equal)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let ((start (point))
              (end (line-end-position)))
          (forward-line 1)
          (nelisp-ime--skk-line
           (buffer-substring-no-properties start end)
           table expand-okuri))))
    (setq nelisp-ime-dictionary-index table)
    (nelisp-ime-lattice-cache-clear)
    (hash-table-count table)))

(defun nelisp-ime--lattice-edges (reading from)
  "Return conversion edges beginning at FROM in READING."
  (let ((remaining (- (length reading) from))
        (size 1)
        edges)
    (while (<= size remaining)
      (let* ((key (substring reading from (+ from size)))
             (candidates (nelisp-ime--dictionary-candidates key)))
        (when candidates
          (push (list :from from :to (+ from size) :reading key
                      :candidates candidates
                      :surface (plist-get (car candidates) :surface)
                      :cost (plist-get (car candidates) :cost))
                edges)))
      (setq size (1+ size)))
    (when (> remaining 0)
      (let ((kana (substring reading from (1+ from))))
        (push (list :from from :to (1+ from) :reading kana
                    :candidates (list (list :surface kana
                                            :cost nelisp-ime-unknown-cost))
                    :surface kana :cost nelisp-ime-unknown-cost)
              edges)))
    edges))

(defun nelisp-ime--segment-public (edge)
  "Convert internal lattice EDGE to a public segment plist."
  (list :from (plist-get edge :from)
        :to (plist-get edge :to)
        :reading (plist-get edge :reading)
        :candidate (plist-get edge :surface)
        :candidates (mapcar (lambda (item) (plist-get item :surface))
                            (plist-get edge :candidates))))

;;;###autoload
(defun nelisp-ime-lattice-convert (reading _context)
  "Convert READING through a minimum-cost dictionary lattice."
  (if (= (length reading) 0)
      '(:preedit "" :candidates nil :segments nil)
    (let* ((size (length reading))
           (infinity nelisp-ime-infinity)
           (costs (make-vector (1+ size) infinity))
           (paths (make-vector (1+ size) nil)))
      (aset costs 0 0)
      (let ((position 0))
        (while (< position size)
          (unless (= (aref costs position) infinity)
            (dolist (edge (nelisp-ime--lattice-edges reading position))
              (let* ((to (plist-get edge :to))
                     (cost (+ (aref costs position)
                              (plist-get edge :cost))))
                (when (< cost (aref costs to))
                  (aset costs to cost)
                  (aset paths to (append (aref paths position)
                                         (list edge)))))))
          (setq position (1+ position))))
      (let* ((path (aref paths size))
             (segments (mapcar #'nelisp-ime--segment-public path))
             (preedit (mapconcat (lambda (edge)
                                   (plist-get edge :surface))
                                 path ""))
             (first (car segments)))
        (list :preedit preedit
              :candidates (plist-get first :candidates)
              :segments segments
              :cost (aref costs size))))))

(nelisp-ime-engine-register 'lattice
                            :convert #'nelisp-ime-lattice-convert)

(provide 'nelisp-ime-lattice)
;;; nelisp-ime-lattice.el ends here
