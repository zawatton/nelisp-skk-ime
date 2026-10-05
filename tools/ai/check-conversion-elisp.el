;;; check-conversion-elisp.el --- Source structure check -*- lexical-binding: t; -*-
(dolist (file '("engine/ddskk-engine.el" "engine/skk-ime-session.el"
               "engine/test-conversion-round2.el" "engine/test-replay-equivalence.el"
               "engine/test-server-reader.el" "engine/bench-wire.el"
               "engine/bench-checkpoint.el" "engine/bench-server-reader.el"))
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (check-parens)
    (goto-char (point-min))
    (condition-case nil
        (while t (read (current-buffer)))
      (end-of-file nil))))
(princ "Elisp structure: 8 files PASS\n")
