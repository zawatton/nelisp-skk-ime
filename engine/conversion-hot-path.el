;;; conversion-hot-path.el --- Literal DDSKK marker transition -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; QPC attributed ~18 ms self time to stock skk-change-marker on the
;; standalone runtime. Its literal predicate avoids regexp scaffolding here.
;; No reachable caller consumes this predicate's match data. GNU Emacs
;; keeps stock DDSKK; the native engine already uses static numeric markers.
(defun ddskk-engine--change-marker ()
  "Change the literal preedit marker, preserving stock command sequencing."
  (skk-save-point
   (goto-char (1- skk-henkan-start-point))
   (unless (eq (char-after) #x25bd)
     (skk-kakutei)
     (skk-error "▽がありません" "It seems that you have deleted ▽"))
   (cancel-undo-boundary)
   (let ((buffer-undo-list t))
     (insert-and-inherit "▼")
     (delete-char 1))
   (setq skk-henkan-mode 'active)))
(when (fboundp 'nelisp-generate-new-buffer)
  (defalias 'skk-change-marker #'ddskk-engine--change-marker))

(provide 'conversion-hot-path)
