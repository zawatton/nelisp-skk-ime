;;; bench-eg1.el --- Private high resolution parser benchmark -*- lexical-binding: t; -*-
(load "engine/ddskk-engine.el" nil t)
(defun eg1-clock ()
  (if (fboundp 'nl-unix-time-usec) (nl-unix-time-usec)
    (* 1000000 (float-time))))
;; Unchanged baseline sanitizer for alternating A/B samples in one runtime.
(defun eg1-original-clean (candidate)
  (when (stringp candidate)
    (let ((index 0) (visible nil) (eol nil) chars)
      (while (< index (length candidate))
        (let ((ch (aref candidate index)))
          (if (memq ch '(10 13)) (setq eol t) (push ch chars))
          (unless (or (<= ch 32) (and (>= ch 127) (<= ch 159))
                      (memq ch '(160 5760 8192 8193 8194 8195 8196 8197
                                 8198 8199 8200 8201 8202 8232 8233 8239
                                 8287 12288 65279)))
            (setq visible t)))
        (setq index (1+ index)))
      (when visible (if eol (apply #'string (nreverse chars)) candidate)))))
(defvar eg1-optimized-clean (symbol-function 'ddskk-user-jisyo--clean-candidate))
(let* ((slash "1/仮名/哉/金/加奈/佳奈/香奈/漢字;annotation with spaces, quotes \" and backslash \\/")
       (expected (ddskk-engine--parse-server-reply slash))
       (quoted (concat "LIST " (prin1-to-string expected)))
       (ddskk-engine--utf8-wire t))
  (dolist (reply (list slash quoted))
    (unless (equal expected (ddskk-engine--parse-server-reply reply))
      (error "Parser parity"))
    (dotimes (_ 10) (ddskk-engine--parse-server-reply reply))
    (dotimes (sample 5)
      (dolist (variant '(original optimized))
      (fset 'ddskk-user-jisyo--clean-candidate
            (if (eq variant 'original) (symbol-function 'eg1-original-clean)
              eg1-optimized-clean))
      (unless (equal expected (ddskk-engine--parse-server-reply reply)) (error "A/B parser parity"))
      (nelisp--write-stdout-bytes (format "READY %s-%s %d\n" (if (eq reply slash) "slash" "list") variant sample))
      (read-stdin-bytes 8192)
      (let ((start (eg1-clock)))
        (dotimes (_ 100) (ddskk-engine--parse-server-reply reply))
        (nelisp--write-stdout-bytes
         (format "DONE parser=%s sample=%d n=100 total_us=%.0f\n"
                 (if (eq reply slash) "slash" "list") sample
                 (- (eg1-clock) start))))))))
