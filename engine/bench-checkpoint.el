;;; bench-checkpoint.el --- Interleaved baseline checkpoint probe -*- lexical-binding: t; -*-
(load "engine/ddskk-engine.el" nil t)
;; Generated from HEAD by the command in the round-2 report, never vendor.
(load "build/w/capture-reference.el" nil t)
(defun ddskk-bench-checkpoint-map ()
  ;; mapcar preserves the declaration order and avoids an interpreted
  ;; push/reverse loop. Keep boundp and marker copying for stock Emacs and
  ;; variables introduced by lazily loaded DDSKK modules.
  (delq nil
        (mapcar
         (lambda (symbol)
           (when (boundp symbol)
             (let ((value (symbol-value symbol)))
          ;; A live marker is not a snapshot: `erase-buffer' in restore moves
          ;; even a copied marker to point-min.  Store its numeric position
          ;; behind a private tag and allocate a fresh marker only after the
          ;; saved text has been inserted again.
               (cons symbol
                      (if (markerp value)
                          (cons 'skk-ime-session--marker
                                (marker-position value))
                        value)))))
         skk-ime-session--native-state-symbols)))


(ddskk-engine-start)
(eval
 `(defun ddskk-bench-checkpoint-direct ()
    (let ((missing nil))
      (let ((state
             (list
              ,@(mapcar
                 (lambda (symbol)
                   `(if (boundp ',symbol)
                        (let ((value ,symbol))
                          (cons ',symbol
                                (if (markerp value)
                                    (cons 'skk-ime-session--marker
                                          (marker-position value))
                                  value)))
                      (progn (setq missing t) nil)))
                 skk-ime-session--native-state-symbols))))
        (if missing (delq nil state) state)))))
(unless (equal (ddskk-bench-checkpoint-map)
               (skk-ime-session--capture-reference))
  (error "Checkpoint capture differs"))
(unless (equal (ddskk-bench-checkpoint-direct)
               (skk-ime-session--capture-reference))
  (error "Direct checkpoint capture differs"))
(dolist (kind '(checkpoint-reference checkpoint-map checkpoint-direct))
  (nelisp--write-stdout-bytes (concat "READY " (symbol-name kind) "\n"))
  (read-stdin-bytes 8192)
  (dotimes (i 100)
    (cond
     ((eq kind 'checkpoint-reference) (skk-ime-session--capture-reference))
     ((eq kind 'checkpoint-map) (ddskk-bench-checkpoint-map))
     (t (ddskk-bench-checkpoint-direct))))
  (nelisp--write-stdout-bytes (concat "DONE " (symbol-name kind) "\n")))
(read-stdin-bytes 8192)
