;;; host-native-index.el --- Bounded SKK line parsing -*- lexical-binding: t; -*-

;; Native code owns source IO, bounds, accumulation and index publication.
;; The supplied NeLisp search primitive returns BYTE offsets. Use it only for
;; unibyte strings, whose substring offsets are bytes too. Multibyte strings
;; and GNU Emacs use the public character-indexed operations unchanged.

;;;###autoload
(defun host-native-parse-jisyo-line (line &optional first-line)
  "Return (MIDASI . TAIL) from complete LINE, or nil for a skipped line.
When FIRST-LINE is non-nil, strip one leading UTF-8 BOM like LoadDictionaryFile.
Otherwise preserve BOM bytes like ParseSkkJisyo. Accept UTF-8 or unibyte data;
annotations, okuri blocks and even empty keys are copied verbatim."
  (when first-line
    (cond ((string-prefix-p (char-to-string 65279) line) (setq line (substring line 1)))
          ((string-prefix-p (unibyte-string 239 187 191) line)
           (setq line (substring line 3)))))
  (let* ((search (if (and (fboundp 'nelisp--string-search)
                          (fboundp 'nelisp--native-substring)
                          (not (multibyte-string-p line)))
                     #'nelisp--string-search #'string-search))
         (slice (if (eq search #'nelisp--string-search)
                    #'nelisp--native-substring #'substring)))
    ;; Search once for each delimiter. The usual trailing CR, LF or CRLF needs
    ;; only one slice; embedded/repeated breaks take the general search path.
    (let ((cr (funcall search "\r" line 0)) (lf (funcall search "\n" line 0)))
      (cond
       ((and cr (not lf) (= cr (1- (length line))))
        (setq line (funcall slice line 0 cr)))
       ((and lf (not cr) (= lf (1- (length line))))
        (setq line (funcall slice line 0 lf)))
       ((and cr lf (= cr (- (length line) 2)) (= lf (1- (length line))))
        (setq line (funcall slice line 0 cr)))
       ((or cr lf)
        (dolist (break '("\r" "\n"))
          (let ((start 0) (pieces nil) hit)
            (while (setq hit (funcall search break line start))
              (push (funcall slice line start hit) pieces)
              (setq start (1+ hit)))
            (when pieces
              (push (funcall slice line start) pieces)
              (setq line (apply #'concat (nreverse pieces)))))))))
    (unless (if (eq search #'nelisp--string-search)
                  (eq (funcall search ";;" line 0) 0)
                (string-prefix-p ";;" line))
      (let* ((space (funcall search " " line 0))
             (slash (and space (funcall search "/" line space))))
        (when slash (cons (funcall slice line 0 space) (funcall slice line slash)))))))

;;;###autoload
(defun host-native-parse-jisyo-batch (lines &optional first-line)
  "Parse bounded complete LINES in order, returning only midasi/tail records.
FIRST-LINE marks the first line of the file, not every batch. Duplicates remain
ordered records; accumulation, serialization and publication belong to native."
  (let ((records nil) record)
    (when (and first-line lines)
      (setq record (host-native-parse-jisyo-line (car lines) t))
      (when record (push record records))
      (setq lines (cdr lines)))
    (while lines
      (setq record (host-native-parse-jisyo-line (car lines)))
      (when record (push record records))
      (setq lines (cdr lines)))
    (nreverse records)))

(provide 'host-native-index)
;;; host-native-index.el ends here
