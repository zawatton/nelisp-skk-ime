;;; generate-skk-data.el --- Build portable NeLisp IME dictionary -*- lexical-binding: t; -*-

(require 'nelisp-ime)
(require 'nelisp-ime-lattice)

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
      (prin1 `(nelisp-ime-dictionary-install ',rows) (current-buffer))
      (insert "\n\n(provide 'nelisp-ime-dictionary-data)\n")
      (insert ";;; nelisp-ime-dictionary-data.el ends here\n"))))

;;; generate-skk-data.el ends here
