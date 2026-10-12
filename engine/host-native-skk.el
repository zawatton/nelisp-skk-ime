;;; host-native-skk.el --- Host candidate merge owners -*- lexical-binding: t; -*-

;; Inputs are copied UTF-8 strings, never dictionary paths or executable Lisp.
;; The C++ owners have no byte-length cap (including the oversized oracle).
;; All delimiters/escaped controls are ASCII: character slicing preserves UTF-8
;; bytes without imposing an Emacs character count as a native byte limit.

;;;###autoload
(defun host-native-merge-builtins (tails)
  "Merge ordered dictionary TAILS for a key; nil TAILS represents a missing key.
Keep the first annotation, include unterminated fields, and reset bracket
state for each dictionary. Lisp-looking fields remain opaque strings."
  (let ((seen nil) (words nil))
    (dolist (raw tails)
      (let ((in-bracket nil))
        (dolist (candidate (split-string raw "/" t))
          (cond
           (in-bracket
            (when (string= candidate "]") (setq in-bracket nil)))
           ((string-prefix-p "[" candidate) (setq in-bracket t))
           (t
            (let* ((note (string-search ";" candidate))
                   (key (if note (substring candidate 0 note) candidate)))
              (unless (member key seen)
                (push key seen)
                (push candidate words))))))))
    (if words (concat "/" (mapconcat #'identity (nreverse words) "/") "/") "")))

;;;###autoload
(defun host-native-merge-server-reply (files server)
  "Merge FILES then SERVER, using the native asymmetric annotation rule.
Only slash-terminated fields participate; bracket fields are ordinary data."
  (let ((words nil))
    (dolist (raw (list files server))
      (let ((start 0) slash)
        (while (setq slash (string-search "/" raw start))
          (when (> slash start)
            (let* ((word (substring raw start slash))
                   (note (string-search ";" word))
                   (key (if note (substring word 0 note) word))
                   (existing words) (found nil))
              (while (and existing (not found))
                (let* ((old (car existing)) (old-note (string-search ";" old)))
                  (setq found
                        (or (string= old word)
                            (and old-note (string= (substring old 0 old-note) key)))))
                (setq existing (cdr existing)))
              (unless found (push word words))))
          (setq start (1+ slash)))))
    (concat "1/" (if words (concat (mapconcat #'identity (nreverse words) "/") "/") ""))))

;;;###autoload
(defun host-native-quote-engine-string (value)
  "Quote VALUE as data, escaping native ASCII controls with three octal digits."
  ;; Search for the small ASCII escape alphabet rather than walking every byte
  ;; of a possibly huge ordinary UTF-8 field in the interpreted evaluator.
  (let ((positions nil) (code 0) (start 0) (pieces (list "\"")))
    (while (< code 128)
      (when (or (< code 32) (= code 127) (= code 34) (= code 92))
        (let ((needle (char-to-string code)) (offset 0) hit)
          (while (setq hit (string-search needle value offset))
            (push hit positions)
            (setq offset (1+ hit)))))
      (setq code (1+ code)))
    (dolist (pos (sort positions #'<))
      (push (substring value start pos) pieces)
      (let ((ch (aref value pos)))
        (push (if (or (= ch 34) (= ch 92))
                  (concat "\\" (char-to-string ch))
                (concat "\\" (char-to-string (+ 48 (logand (ash ch -6) 7)))
                        (char-to-string (+ 48 (logand (ash ch -3) 7)))
                        (char-to-string (+ 48 (logand ch 7))))) pieces))
      (setq start (1+ pos)))
    (push (substring value start) pieces)
    (push "\"" pieces)
    (apply #'concat (nreverse pieces))))

;;;###autoload
(defun host-native-engine-dictionary-reply (reply)
  "Convert REPLY to the exact engine LIST wire string, without evaluating data."
  (if (not (string-prefix-p "1" reply)) "LIST nil"
    (let ((start 1) slash (pieces nil))
      (while (setq slash (string-search "/" reply start))
        (when (> slash start)
          (push (concat (host-native-quote-engine-string
                         (substring reply start slash)) " ") pieces))
        (setq start (1+ slash)))
      (concat "LIST (" (apply #'concat (nreverse pieces)) ")"))))

(provide 'host-native-skk)
;;; host-native-skk.el ends here
