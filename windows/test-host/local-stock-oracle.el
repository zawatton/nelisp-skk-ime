;;; local-stock-oracle.el --- Stock DDSKK ordinary source oracle -*- lexical-binding: t; -*-
;; GPL-3.0-or-later
;; Caller provides LOCAL_ORACLE_DIR, exclusively a private build directory.
(require 'skk)
(let* ((directory (getenv "LOCAL_ORACLE_DIR"))
       (personal (expand-file-name "stock-user.jisyo" directory))
       (shared (expand-file-name "stock-shared.jisyo" directory))
       (skk-jisyo personal)
       (skk-jisyo-code 'utf-8)
       (skk-jisyo-save-count nil)
       (skk-large-jisyo (cons shared 'utf-8))
       (skk-share-private-jisyo nil)
       (skk-num-convert-code nil)
       (skk-numeric-conversion nil)
       (skk-search-prog-list '((skk-search-jisyo-file skk-jisyo 0 t)
                               (skk-search-jisyo-file skk-large-jisyo 0 t)))
       (skk-update-jisyo-function 'skk-update-jisyo-original)
       (output ""))
  (make-directory directory t)
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file personal
      (insert ";; okuri-ari entries.\n;; okuri-nasi entries.\nかな /佳奈/仮名/\n"))
    (with-temp-file shared
      (insert ";; okuri-ari entries.\n;; okuri-nasi entries.\n"
              "かな /仮名;first/哉/金/加奈/佳奈/香奈/可奈/\n"
              "か /蚊/\nかんじ /漢字/幹事/感じ/\nにほん /日本/二本/\n")))
  (cl-labels
      ((hex (value) (mapconcat (lambda (c) (format "%06x" c)) value ""))
       (collect (reading)
         (let ((skk-henkan-key reading) (skk-okuri-char nil)
               (skk-henkan-okurigana nil)
               (skk-current-search-prog-list (copy-tree skk-search-prog-list))
               words)
           (while skk-current-search-prog-list
             (setq words (skk-nunion words (skk-search))))
           (unless words (error "Stock corpus reading has no candidates: %s" reading))
           (let* ((selected (car (last words)))
                  (text (car (skk-treat-strip-note-from-word selected))))
             (setq output (concat output (hex reading) " "
                                  (hex (concat "/" (mapconcat #'identity words "/") "/"))
                                  " " (hex text) "\n"))))))
    (with-temp-buffer
      (dolist (reading '("かな" "かんじ" "にほん" "か")) (collect reading))
      ;; Use stock's actual learning writer, not the engine's narrower one.
      (let ((skk-henkan-key "かな") (skk-henkan-okurigana nil)
            (skk-okuri-char nil) (skk-okuri-index-min -1))
        (skk-update-jisyo-original "哉" nil))
      (dolist (reading '("かな" "かんじ" "にほん" "か")) (collect reading))))
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file (expand-file-name "stock.oracle" directory) (insert output)))
  (princ "PASS stock DDSKK oracle: 8 rows, 4 readings before/after learning\n"))
