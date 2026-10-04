;;; generate-skk-data.el --- Build portable NeLisp IME dictionary -*- lexical-binding: t; -*-

(require 'nelisp-ime)
(require 'nelisp-ime-lattice)

;; Regenerate from the repository root (environment variables are paths):
;; NELISP_IME_SKK_INPUT=engines/lattice/data/SKK-JISYO.M
;; NELISP_IME_SKK_OUTPUT=engines/lattice/data/nelisp-ime-dictionary-data.el
;; NELISP_IME_SKK_RANKING_DATA=<previous portable table, saved before writing>
;; NELISP_IME_VERB_CLASSES=<MeCab dic/ipadic/Verb.csv>
;; emacs -Q --batch -L framework/src -L engines/lattice/src \
;;   -l engines/lattice/data/generate-skk-data.el
;; Alternatively use NELISP_IME_SKK_RANKING=<SKK-JISYO.L> with its coding.
;; IPAdic (EUC-JP) is optional, and used ONLY at generation time. Neither
;; runtime conversion nor bundled-data tests need MeCab. Its license notice
;; is retained in IPADIC-COPYING. No vowel/romaji heuristic classifies verbs:
;; both dictionary-form spelling and reading must attest 一段 in IPAdic.
;; Missing spellings/readings (including variants) get no additional forms.

(defun nelisp-ime-generate--verb-classes (file)
  "Read IPAdic basic-form spelling/reading to conjugation classes from FILE."
  (let ((table (make-hash-table :test 'equal))
        (coding-system-for-read 'euc-jp))
    (with-temp-buffer
      (insert-file-contents file)
      (dolist (line (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t))
        (let ((fields (split-string line ",")))
          (when (and (equal (nth 4 fields) "動詞")
                     (equal (nth 9 fields) "基本形"))
            (let* ((key (cons (nth 10 fields)
                              (japanese-hiragana (nth 11 fields))))
                   (classes (gethash key table)))
              (puthash key (cl-adjoin (nth 8 fields) classes :test #'equal)
                       table))))))
    table))

(defun nelisp-ime-generate--ichidan (file coding classes table)
  "Add attested ichidan forms from SKK FILE to TABLE, preserving candidates."
  (let ((coding-system-for-read coding))
    (with-temp-buffer
      (insert-file-contents file)
      (dolist (line (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t))
        (when (string-match "\\`\\([ぁ-ゖ]+\\)\\([a-z]\\) /" line)
          (let* ((base (match-string 1 line))
                 (code (match-string 2 line))
                 ;; r may record the whole stem; other codes can omit the
                 ;; final stem kana (たb /食/ -> 食べる, おk /起/ -> 起きる).
                 (vowels (cdr (assoc code '(("r" "" "り" "れ")
                                            ("i" "い") ("e" "え")
                                            ("k" "き" "け") ("g" "ぎ" "げ")
                                            ("s" "し" "せ") ("t" "ち" "て")
                                            ("n" "に" "ね") ("h" "ひ" "へ")
                                            ("b" "び" "べ") ("m" "み" "め"))))))
            (dolist (vowel vowels)
              (let* ((ending (concat vowel "る"))
                     (reading (concat base ending)))
                (dolist (part (cdr (split-string line "/")))
                  (let* ((candidate (nelisp-ime--skk-candidate part))
                         (types (and candidate
                                     (gethash (cons (concat candidate ending) reading)
                                              classes))))
                    ;; Reject ambiguous class records too; never infer from r.
                    (when (equal types '("一段"))
                      (dolist (suffix '("る" "ない" "ます" "た" "て" "よう" "れば" "られる"))
                        (let* ((key (concat base vowel suffix))
                               (surface (concat candidate vowel suffix))
                               (existing (gethash key table)))
                          (unless (member surface existing)
                            (puthash key (append existing (list surface)) table)))))))))))))))

;; The shipped data is base = SKK-JISYO.M, ranking = SKK-JISYO.L: the
;; reading set comes from M, and every reading M has is then given L's
;; richer candidate list.  That keeps the file small while still offering
;; L's candidates for them, and
;; regenerating from M alone quietly halves the候補 -- so the recipe is
;; recorded here rather than left in someone's shell history.
;;
;; Codings are separate because a distribution SKK-JISYO is EUC-JP but a
;; locally converted one (assets/ddskk/SKK-JISYO.L.utf8) is not, and
;; reading UTF-8 as EUC-JP silently produces a dictionary of mojibake
;; rather than an error.
(let ((input (or (getenv "NELISP_IME_SKK_INPUT")
                 "data/SKK-JISYO.M"))
      (output (or (getenv "NELISP_IME_SKK_OUTPUT")
                  "data/nelisp-ime-dictionary-data.el"))
      (ranking (getenv "NELISP_IME_SKK_RANKING"))
      ;; A previously generated portable table can preserve richer rankings
      ;; when the original ranking dictionary is unavailable.
      (ranking-data (getenv "NELISP_IME_SKK_RANKING_DATA"))
      (verb-classes (getenv "NELISP_IME_VERB_CLASSES"))
      (coding (intern (or (getenv "NELISP_IME_SKK_CODING") "euc-jp")))
      (ranking-coding
       (intern (or (getenv "NELISP_IME_SKK_RANKING_CODING")
                   (getenv "NELISP_IME_SKK_CODING")
                   "euc-jp")))
      rows)
  (nelisp-ime-dictionary-load-skk input coding t)
  (let ((base nelisp-ime-dictionary-index))
    (when (or (and ranking (file-readable-p ranking)) ranking-data)
      (if ranking-data
          (load (expand-file-name ranking-data))
        (nelisp-ime-dictionary-load-skk ranking ranking-coding t))
      (let ((ranked nelisp-ime-dictionary-index))
        (maphash (lambda (reading candidates)
                   (let ((ranked-candidates (gethash reading ranked)))
                     ;; Legacy portable tables expanded bare ASCII names
                     ;; like k /κ/ into く /κく/. Only these empty-stem
                     ;; suffix keys need cleanup; preserve genuine M entries.
                     (when ranking-data
                       (dolist (group nelisp-ime--okuri-forms)
                         (when (assoc reading (cdr group))
                           (setq ranked-candidates
                                 (cl-remove-if
                                  (lambda (surface)
                                    (and (string-suffix-p reading surface)
                                         (not (member surface candidates))))
                                  ranked-candidates)))))
                     (when ranked-candidates
                       (puthash reading ranked-candidates base))))
                 base)))
    (setq nelisp-ime-dictionary-index base))
  ;; Add after ranking so a legacy portable table cannot erase new forms.
  (when verb-classes
    (let ((classes (nelisp-ime-generate--verb-classes verb-classes)))
      (nelisp-ime-generate--ichidan input coding classes nelisp-ime-dictionary-index)
      (when (and ranking (file-readable-p ranking))
        (nelisp-ime-generate--ichidan ranking ranking-coding classes
                                     nelisp-ime-dictionary-index))))
  (maphash (lambda (reading candidates)
             (push (cons reading candidates) rows))
           nelisp-ime-dictionary-index)
  (setq rows (sort rows (lambda (left right)
                          (string< (car left) (car right)))))
  (let ((coding-system-for-write 'utf-8-unix)
        (print-length nil)
        (print-level nil))
    (with-temp-file output
      (insert ";;; nelisp-ime-dictionary-data.el --- Generated SKK data  -*- lexical-binding: t; -*-\n")
      (insert ";; Generated from SKK-JISYO.M with optional ranking data; do not edit.\n\n")
      (when verb-classes
        (insert ";; Ichidan forms classified with IPAdic at generation time; see IPADIC-COPYING.\n\n"))
      (prin1 `(nelisp-ime-dictionary-install ',rows) (current-buffer))
      (insert "\n\n(provide 'nelisp-ime-dictionary-data)\n")
      (insert ";;; nelisp-ime-dictionary-data.el ends here\n"))))

;;; generate-skk-data.el ends here
