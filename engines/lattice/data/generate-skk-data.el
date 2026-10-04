;;; generate-skk-data.el --- Build portable NeLisp IME dictionary -*- lexical-binding: t; -*-

(require 'nelisp-ime)
(require 'nelisp-ime-lattice)

;; Regenerate from the repository root (all environment variables are paths):
;; NELISP_IME_SKK_INPUT=engines/lattice/data/SKK-JISYO.M
;; NELISP_IME_SKK_OUTPUT=engines/lattice/data/nelisp-ime-dictionary-data.el
;; NELISP_IME_SKK_RANKING=<original SKK-JISYO.L, not a portable table>
;; NELISP_IME_VERB_CLASSES=<MeCab dic/ipadic/Verb.csv>
;; emacs -Q --batch -L framework/src -L engines/lattice/src \
;;   -l engines/lattice/data/generate-skk-data.el
;; SKK sources default to EUC-JP; set NELISP_IME_SKK_CODING and/or
;; NELISP_IME_SKK_RANKING_CODING for converted sources. IPAdic is EUC-JP.
;; NELISP_IME_SKK_RANKING_DATA=<HEAD portable table saved before regeneration>
;; The portable reference supplies order ONLY; all candidates are validated
;; against the original SKK sources and IPAdic classes. Volitionals follow
;; genuine words; competing legacy expansions prefer the matching okuri code.
;; Adj.csv, Adverb.csv, Noun*.csv and Suffix.csv attest non-verbs.
;; Adjectives use only HEAD row suffixes: i = い/くない/かった/くて/ければ/そう,
;; k = く, s = そう; na-adjective stems additionally admit s = そう.
;; IPAdic is required ONLY at generation time; runtime and tests use the
;; bundled table. Its license notice is retained in IPADIC-COPYING.
;; A legacy portable ranking table has lost okuri provenance and contains
;; invented words, so it cannot safely replace the original ranking source.

(defvar nelisp-ime-generate-library-only nil
  "Non-nil loads generator helpers without writing the bundled dictionary.")

(defun nelisp-ime-generate--verb-classes (file)
  "Read IPAdic basic-form spelling/reading to conjugation classes from FILE."
  (let ((table (make-hash-table :test 'equal))
        (surfaces (make-hash-table :test 'equal))
        (coding-system-for-read 'euc-jp))
    (with-temp-buffer
      (insert-file-contents file)
      (dolist (line (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t))
        (let ((fields (split-string line ",")))
          (when (equal (nth 4 fields) "動詞")
            (let ((surface (cons (nth 0 fields) (japanese-hiragana (nth 11 fields)))))
              (puthash surface (cl-adjoin (nth 8 fields) (gethash surface surfaces)
                                          :test #'equal) surfaces)))
          (when (and (equal (nth 4 fields) "動詞")
                     (equal (nth 9 fields) "基本形"))
            (let* ((key (cons (nth 10 fields)
                              (japanese-hiragana (nth 11 fields))))
                   (classes (gethash key table)))
              (puthash key (cl-adjoin (nth 8 fields) classes :test #'equal)
                       table))))))
    ;; A basic-form spelling can also be an inflected form of another class
    ;; (e.g. a literary suru form). Reject that lexical ambiguity as well.
    (maphash (lambda (key types)
               (puthash key (cl-union types (gethash key surfaces) :test #'equal) table))
             table)
    table))

(defun nelisp-ime-generate--suffixes (class)
  "Return dictionary ending and common suffixes attested by verb CLASS."
  (cond
   ((equal class "一段")
    '("る" "る" "ない" "ます" "た" "て" "よう" "れば" "られる"))
   ((equal class "五段・カ行促音便")
    '("く" "く" "かない" "きます" "った" "って" "けば" "こう"))
   ;; The aru class has a suppletive negative, not stem + らない.
   ((equal class "五段・ラ行特殊")
    '("る" "る" "ります" "った" "って" "れば" "ろう"))
   ((equal class "五段・ワ行ウ音便")
    '("う" "う" "わない" "います" "うた" "うて" "えば" "おう"))
   (t
    (let* ((row (cdr (assoc class '(("五段・カ行イ音便" . "k")
                                    ("五段・ガ行" . "g")
                                    ("五段・サ行" . "s")
                                    ("五段・タ行" . "t")
                                    ("五段・ナ行" . "n")
                                    ("五段・バ行" . "b")
                                    ("五段・マ行" . "m")
                                    ("五段・ラ行" . "r")
                                    ("五段・ワ行促音便" . "w")))))
           (forms (cdr (assoc row nelisp-ime--okuri-forms))))
      (when forms (cons (caar forms) (mapcar #'cdr forms)))))))

(defun nelisp-ime-generate--attestations (classes)
  "Index CLASS records by matching SKK spelling/reading stems.
The omitted okurigana must be identical in spelling and reading. The
SKK consonant can describe a past form (よn /読/), not the verb row."
  (let ((table (make-hash-table :test 'equal)))
    (maphash
     (lambda (key types)
       ;; Ambiguous class records are not a license to invent forms.
       (when (= (length types) 1)
         (let* ((word (car key)) (reading (cdr key))
                (forms (nelisp-ime-generate--suffixes (car types)))
                (ending (car forms)))
           (when (and ending (string-suffix-p ending word)
                      (string-suffix-p ending reading))
             (dotimes (offset (1- (min (length word) (length reading))))
               (let* ((size (1+ offset))
                      (tail (substring word (- (length word) size))))
                 (when (and (>= size (length ending))
                            (string-suffix-p tail reading)
                            ;; Only kana may be omitted from an SKK stem.
                            (string-match-p "\\`[ぁ-ゖ]+\\'" tail))
                   (let ((stem (cons (substring word 0 (- (length word) size))
                                     (substring reading 0 (- (length reading) size))))
                         (prefix (substring tail 0 (- size (length ending)))))
                     (puthash stem
                              (cl-adjoin (list :prefix prefix :suffixes (cdr forms)
                                               :lemma key)
                                         (gethash stem table) :test #'equal)
                              table)))))))))
     classes)
    table))

(defun nelisp-ime-generate--append (reading surface table)
  "Append SURFACE to READING in TABLE, without duplicates."
  (let ((existing (gethash reading table)))
    (unless (member surface existing)
      (puthash reading (append existing (list surface)) table))))

(defun nelisp-ime-generate--literal-spellings (file &optional table adjectives na-adjectives)
  "Index attested non-verbs from IPAdic FILE without reading word costs.
Also index basic ADJECTIVES and NA-ADJECTIVES when those tables are supplied."
  (let ((table (or table (make-hash-table :test 'equal))) (coding-system-for-read 'euc-jp))
    (with-temp-buffer
      (insert-file-contents file)
      (dolist (line (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t))
        (let ((fields (split-string line ",")))
          (let ((key (cons (nth 0 fields) (japanese-hiragana (nth 11 fields))))
                (adjective (and (equal (nth 4 fields) "形容詞")
                                (equal (nth 9 fields) "基本形")
                                (member (nth 8 fields) '("形容詞・アウオ段" "形容詞・イ段" "形容詞・イイ")))))
            (when (or (member (nth 4 fields) '("名詞" "副詞")) adjective)
              (puthash key t table))
            (when (and adjective adjectives) (puthash key t adjectives))
            (when (and na-adjectives (equal (nth 4 fields) "名詞")
                       (equal (nth 5 fields) "形容動詞語幹"))
              (puthash key t na-adjectives))))))
    table))

(defun nelisp-ime-generate--okuri-code (okuri)
  "Return SKK's consonant/vowel code for the first kana of OKURI."
  (let ((kana (substring okuri 0 1)))
    (car (cl-find-if
          (lambda (row) (string-match-p (regexp-quote kana) (cdr row)))
          '(("a" . "あぁ") ("i" . "いぃ") ("u" . "うぅ") ("e" . "えぇ") ("o" . "おぉ")
            ("k" . "かきくけこ") ("g" . "がぎぐげご") ("s" . "さしすせそ")
            ("z" . "ざじずぜぞ") ("t" . "たちつてとっ") ("d" . "だぢづでど")
            ("n" . "なにぬねのん") ("h" . "はひふへほ") ("b" . "ばびぶべぼ")
            ("p" . "ぱぴぷぺぽ") ("m" . "まみむめも") ("y" . "やゆよゃゅょ")
            ("r" . "らりるれろ") ("w" . "わをゎ"))))))

(defun nelisp-ime-generate--conjugations (file coding attestations table &optional provenance literals adjectives na-adjectives)
  "Append attested forms from SKK FILE and record their PROVENANCE.
Legacy forms retain their HEAD positions; newly attested forms are appended.
An i code alone does not attest a standalone word (聞い is onbin)."
  (let ((coding-system-for-read coding))
    (with-temp-buffer
      (insert-file-contents file)
      (dolist (line (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t))
        (when (string-match "\\`\\([ぁ-ゖ]+\\)\\([a-z]\\) /" line)
          (let ((base (match-string 1 line)) (code (match-string 2 line)))
            (dolist (part (cdr (split-string line "/")))
              (let ((candidate (nelisp-ime--skk-candidate part)))
                (when candidate
                  ;; Non-verbs retain only HEAD's row forms. An adjective
                  ;; lemma attests its paradigm; other words must match the
                  ;; whole surface/reading, except na-adjective stem + そう.
                  (let ((adjective (and adjectives
                                        (gethash (cons (concat candidate "い") (concat base "い")) adjectives))))
                    (dolist (form (cdr (assoc code nelisp-ime--okuri-forms)))
                      (let* ((suffix (cdr form)) (reading (concat base suffix))
                             (surface (concat candidate suffix)))
                        (when (or (and adjective (member suffix '("い" "く" "くない" "かった" "くて" "ければ" "そう")))
                                  (and literals (gethash (cons surface reading) literals))
                                  (and (equal suffix "そう") na-adjectives
                                       (gethash (cons candidate base) na-adjectives)))
                          (nelisp-ime-generate--append reading surface table)
                          (when provenance
                            (let ((key (cons reading surface)))
                              (puthash key (append (gethash key provenance)
                                                   (list (list :legacy t
                                                               :matching (equal code (nelisp-ime-generate--okuri-code suffix)))))
                                       provenance)))))))
                  (dolist (record (gethash (cons candidate base) attestations))
                    (dolist (suffix (plist-get record :suffixes))
                      (let* ((okuri (concat (plist-get record :prefix) suffix))
                             (reading (concat base okuri)) (surface (concat candidate okuri))
                             (legacy (assoc okuri (cdr (assoc code nelisp-ime--okuri-forms))))
                             ;; Dictionary-form う is not a volitional. The
                             ;; lemma identifies the dictionary okurigana.
                             (dictionary-okuri (substring (car (plist-get record :lemma)) (length candidate)))
                             (volitional (and (string-suffix-p "う" suffix)
                                              (not (equal okuri dictionary-okuri)))))
                        (nelisp-ime-generate--append reading surface table)
                        (when provenance
                          (let ((key (cons reading surface)))
                            (puthash key
                                     (append (gethash key provenance)
                                             (list (list :legacy (and legacy t)
                                                         :matching (equal code (nelisp-ime-generate--okuri-code okuri))
                                                         :volitional volitional)))
                                     provenance)))))))))))))))

(defun nelisp-ime-generate--rank (table plain provenance reference)
  "Restore REFERENCE order using only validated TABLE candidates.
Legacy non-volitional expansions precede plain words as in HEAD, with
matching-code entries first. New forms follow the existing candidates;
all generated volitionals follow genuine words. Plain SKK order is stable."
  (maphash
   (lambda (reading candidates)
     (let* ((old (gethash reading reference))
            (ordered (append (cl-remove-if-not (lambda (s) (member s candidates)) old)
                             (cl-remove-if (lambda (s) (member s old)) candidates)))
            (seen (make-hash-table :test 'equal)) rows (index 0))
       (dolist (surface ordered)
         (unless (gethash surface seen)
           (puthash surface t seen)
           (let* ((records (gethash (cons reading surface) provenance))
                  (legacy (cl-remove-if-not (lambda (r) (plist-get r :legacy)) records))
                  (origins (or legacy records))
                  (volitional (and records (cl-every (lambda (r) (plist-get r :volitional)) records)))
                  (matching (cl-some (lambda (r) (plist-get r :matching)) origins))
                  (genuine (member surface (gethash reading plain)))
                  (tier (cond ((and volitional (not genuine)) (if matching 5 6))
                              (legacy (if matching 0 1))
                              (genuine 2) (matching 3) (t 4))))
             (push (list surface tier index) rows)
             (setq index (1+ index)))))
       (setq rows (sort rows (lambda (l r)
                               (if (= (nth 1 l) (nth 1 r)) (< (nth 2 l) (nth 2 r))
                                 (< (nth 1 l) (nth 1 r))))))
       (puthash reading (mapcar #'car rows) table))) table))

(unless nelisp-ime-generate-library-only
  (let* ((input (or (getenv "NELISP_IME_SKK_INPUT")
                    "engines/lattice/data/SKK-JISYO.M"))
         (output (or (getenv "NELISP_IME_SKK_OUTPUT")
                     "engines/lattice/data/nelisp-ime-dictionary-data.el"))
         (ranking (getenv "NELISP_IME_SKK_RANKING"))
         (verb-classes (getenv "NELISP_IME_VERB_CLASSES"))
         (ranking-data (getenv "NELISP_IME_SKK_RANKING_DATA"))
         (coding (intern (or (getenv "NELISP_IME_SKK_CODING") "euc-jp")))
         (ranking-coding (intern (or (getenv "NELISP_IME_SKK_RANKING_CODING")
                                     (getenv "NELISP_IME_SKK_CODING") "euc-jp")))
         rows)
    (unless (and verb-classes (file-readable-p verb-classes))
      (error "NELISP_IME_VERB_CLASSES must name IPAdic Verb.csv"))
    ;; M defines the reading footprint; L supplies richer genuine candidates
    ;; for those readings. Accepted candidates never come from row expansion.
    ;; Legacy expansions define only the small M reading footprint, never
    ;; accepted candidates. This retains genuine L words at collided keys.
    (nelisp-ime-dictionary-load-skk input coding t)
    (let* ((footprint nelisp-ime-dictionary-index)
           ranked
           (provenance (make-hash-table :test 'equal))
           (adjectives (make-hash-table :test 'equal))
           (na-adjectives (make-hash-table :test 'equal))
           (literals (let* ((directory (file-name-directory (expand-file-name verb-classes)))
                            (table (nelisp-ime-generate--literal-spellings
                                    (expand-file-name "Adj.csv" directory) nil adjectives na-adjectives)))
                       (dolist (file (directory-files directory t "\\`Noun.*\\.csv\\'"))
                         (nelisp-ime-generate--literal-spellings file table adjectives na-adjectives))
                       (nelisp-ime-generate--literal-spellings
                        (expand-file-name "Adverb.csv" directory) table adjectives na-adjectives)
                       (nelisp-ime-generate--literal-spellings
                        (expand-file-name "Suffix.csv" directory) table adjectives na-adjectives)
                       table))
           (reference (if ranking-data
                          (progn (load (expand-file-name ranking-data) nil t) nelisp-ime-dictionary-index)
                        footprint))
           (base (progn (nelisp-ime-dictionary-load-skk input coding nil)
                        nelisp-ime-dictionary-index))
           (attestations (nelisp-ime-generate--attestations
                          (nelisp-ime-generate--verb-classes verb-classes))))
      (when ranking
        (nelisp-ime-dictionary-load-skk ranking ranking-coding nil)
        (setq ranked nelisp-ime-dictionary-index)
        (progn
          (maphash (lambda (reading _candidates)
                     (let ((genuine (gethash reading ranked)))
                       (when genuine (puthash reading genuine base))))
                   footprint)))
      (let ((plain (copy-hash-table base)))
	(nelisp-ime-generate--conjugations input coding attestations base provenance literals adjectives na-adjectives)
	;; Keep M's expanded reading footprint while enriching its forms from L.
	(when ranking
          (let ((expanded (make-hash-table :test 'equal)))
            (nelisp-ime-generate--conjugations ranking ranking-coding attestations expanded
                                               provenance literals adjectives na-adjectives)
            (maphash (lambda (reading candidates)
                       (when (or (gethash reading base) (gethash reading footprint))
			 (dolist (candidate candidates)
                           (nelisp-ime-generate--append reading candidate base))))
                     expanded)))
	(nelisp-ime-generate--rank base plain provenance reference))
      (setq nelisp-ime-dictionary-index base))
    (maphash (lambda (reading candidates) (push (cons reading candidates) rows))
             nelisp-ime-dictionary-index)
    (setq rows (sort rows (lambda (left right) (string< (car left) (car right)))))
    (let ((coding-system-for-write 'utf-8-unix) (print-length nil) (print-level nil))
      (with-temp-file output
        (insert ";;; nelisp-ime-dictionary-data.el --- Generated SKK data  -*- lexical-binding: t; -*-\n")
        (insert ";; Generated from SKK-JISYO.M with original SKK ranking data; do not edit.\n")
        (insert ";; Forms attested by IPAdic; SKK ordering with volitional/code rules; see IPADIC-COPYING.\n\n")
        (prin1 `(nelisp-ime-dictionary-install ',rows) (current-buffer))
        (insert "\n\n(provide 'nelisp-ime-dictionary-data)\n")
        (insert ";;; nelisp-ime-dictionary-data.el ends here\n")))))

(provide 'nelisp-ime-generate-skk-data)
;;; generate-skk-data.el ends here
