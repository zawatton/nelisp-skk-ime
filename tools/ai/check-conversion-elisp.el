;;; check-conversion-elisp.el --- Source structure check -*- lexical-binding: t; -*-
(dolist (file '("engine/ddskk-engine.el" "engine/skk-ime-session.el"))
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (check-parens)
    (goto-char (point-min))
    (condition-case nil
        (while t (read (current-buffer)))
      (end-of-file nil))))
(princ "Elisp structure: 2 files PASS\n")
