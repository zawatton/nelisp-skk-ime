;;; probe-conversion-native.el --- Compile hot functions -*- lexical-binding: t; -*-
;; emacs -Q --batch -L RUNTIME-REPO/lisp -L RUNTIME-REPO/src
;;   -l tools/ai/probe-conversion-native.el
;; Outputs only under build/w; does not alter runtime or vendor source.
(require 'nelisp-artifact)
(let ((wanted '(ddskk-engine--hex-uncached
                ddskk-engine--decode-codepoints
                ddskk-engine--parse-server-reply))
      forms)
  (with-temp-buffer
    (insert-file-contents "engine/ddskk-engine.el")
    (check-parens)
    (goto-char (point-min))
    (condition-case nil
        (while t
          (let ((form (read (current-buffer))))
            (when (and (eq (car-safe form) 'defun)
                       (memq (cadr form) wanted))
              (push form forms))))
      (end-of-file nil)))
  (unless (= (length forms) 3) (error "Expected exactly three probe functions"))
  (with-temp-file "build/w/conversion-native-probe.el"
    (dolist (form (nreverse forms)) (prin1 form (current-buffer)) (insert "\n")))
  (nelisp-artifact-compile-file
   "build/w/conversion-native-probe.el" "build/w/conversion-native-probe.neln"
   nil "x86_64-w64-mingw32" nil nil nil 'neln 'opportunistic 'eval-only)
  (princ "Native compilation probe: 3 functions; inspect build/w/conversion-native-probe.neln.manifest.el\n"))
