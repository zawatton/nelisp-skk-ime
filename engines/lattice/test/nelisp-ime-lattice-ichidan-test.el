;;; nelisp-ime-lattice-ichidan-test.el --- Bundled verb regressions -*- lexical-binding: t; -*-

(require 'nelisp-ime-lattice-test)

(defconst nelisp-ime-lattice-ichidan-test--data
  (expand-file-name "../data/nelisp-ime-dictionary-data.el"
                    (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest nelisp-ime-lattice-ichidan-test-first-conversion ()
  "The requested examples convert directly, including a godan control."
  (nelisp-ime-lattice-test--isolated
    (load nelisp-ime-lattice-ichidan-test--data nil t)
    (dolist (pair '(("できない" . "出来ない") ("みない" . "見ない")
                    ("たべない" . "食べない") ("おきない" . "起きない")
                    ("かかない" . "書かない")))
      (should (equal (plist-get (nelisp-ime-lattice-convert (car pair) nil) :preedit)
                     (cdr pair))))))

(ert-deftest nelisp-ime-lattice-ichidan-test-required-negatives ()
  "Attested ichidan negatives and existing godan negatives convert without MeCab."
  (nelisp-ime-lattice-test--isolated
    (load nelisp-ime-lattice-ichidan-test--data nil t)
    (dolist (pair '(("できない" . "出来ない") ("みない" . "見ない")
                    ("たべない" . "食べない") ("おきない" . "起きない")
                    ("かえない" . "変えない") ("かえない" . "替えない")
                    ("きない" . "着ない") ("ねない" . "寝ない")
                    ("でない" . "出ない") ("かかない" . "書かない")
                    ("かえらない" . "帰らない") ("はいらない" . "入らない")
                    ("はしらない" . "走らない") ("しらない" . "知らない")))
      (ert-info ((format "Required %s -> %s" (car pair) (cdr pair)))
        (should (member (cdr pair) (gethash (car pair) nelisp-ime-dictionary-index)))
        (should (member (cdr pair)
                        (plist-get (nelisp-ime-lattice-convert (car pair) nil)
                                   :candidates)))))))

(ert-deftest nelisp-ime-lattice-ichidan-test-common-forms ()
  "Both full-stem r and omitted-stem-kana SKK entries expand common forms."
  (nelisp-ime-lattice-test--isolated
    (load nelisp-ime-lattice-ichidan-test--data nil t)
    (dolist (stem '(("でき" . "出来") ("み" . "見") ("たべ" . "食べ")
                    ("おき" . "起き") ("かえ" . "変え") ("かえ" . "替え")
                    ("き" . "着") ("ね" . "寝") ("で" . "出")))
      (dolist (suffix '("ない" "ます" "た" "て" "よう" "れば" "られる"))
        (let ((reading (concat (car stem) suffix))
              (surface (concat (cdr stem) suffix)))
          (ert-info ((format "Common form %s -> %s" reading surface))
            (should (member surface (gethash reading nelisp-ime-dictionary-index)))
            (should (member surface
                            (plist-get (nelisp-ime-lattice-convert reading nil)
                                       :candidates)))))))))

(ert-deftest nelisp-ime-lattice-ichidan-test-forbidden-godan-negatives ()
  "An ambiguous r code or vowel ending must not invent ichidan godan forms."
  (nelisp-ime-lattice-test--isolated
    (load nelisp-ime-lattice-ichidan-test--data nil t)
    (dolist (entry '(("かえない" "帰ない" "返ない" "換ない")
                     ("はいない" "入ない") ("はしない" "走ない")
                     ("しない" "知ない") ("ねない" "練ない")
                     ("まいない" "参ない") ("いない" "入ない" "要ない" "煎ない")))
      (dolist (surface (cdr entry))
        (ert-info ((format "Forbidden %s -> %s" (car entry) surface))
          (should-not (member surface (gethash (car entry) nelisp-ime-dictionary-index)))
          (should-not (member surface
                              (plist-get (nelisp-ime-lattice-convert (car entry) nil)
                                         :candidates))))))))

(provide 'nelisp-ime-lattice-ichidan-test)
;;; nelisp-ime-lattice-ichidan-test.el ends here
