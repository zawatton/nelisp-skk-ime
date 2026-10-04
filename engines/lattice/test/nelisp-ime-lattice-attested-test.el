;;; nelisp-ime-lattice-attested-test.el --- Bundled provenance regressions -*- lexical-binding: t; -*-
(require 'nelisp-ime-lattice-test)
(defvar nelisp-ime-lattice-attested-test-data
  (expand-file-name "../data/nelisp-ime-dictionary-data.el"
                    (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest nelisp-ime-lattice-attested-first-candidates ()
  (nelisp-ime-lattice-test--isolated
    (load nelisp-ime-lattice-attested-test-data nil t)
    (dolist (pair '(("りそう" . "理想") ("わしつ" . "和室")
                    ("よのう" . "予納") ("よとう" . "与党")
                    ("わこう" . "和光") ("よぼう" . "予防")))
      (ert-info ((format "%s -> %s" (car pair) (cdr pair)))
        (should (equal (car (gethash (car pair) nelisp-ime-dictionary-index)) (cdr pair)))
        (should (equal (car (plist-get (nelisp-ime-lattice-convert (car pair) nil)
                                      :candidates)) (cdr pair)))))))

(ert-deftest nelisp-ime-lattice-attested-head-order ()
  (nelisp-ime-lattice-test--isolated
    (load nelisp-ime-lattice-attested-test-data nil t)
    (dolist (pair '(("ぬすむ" . "盗む") ("まなぶ" . "学ぶ") ("つぶす" . "潰す")
                    ("よい" . "良い") ("こんだ" . "込んだ") ("しいた" . "敷いた")
                    ("はやめて" . "早めて") ("きりとる" . "切り取る")
                    ("さしだす" . "差し出す") ("くみあう" . "組み合う")
                    ("とりださない" . "取り出さない") ("とった" . "取った")
                    ("かかない" . "書かない") ("たち" . "達") ("まかない" . "賄い")))
      (ert-info ((format "Required first %s -> %s" (car pair) (cdr pair)))
        (should (equal (car (gethash (car pair) nelisp-ime-dictionary-index)) (cdr pair)))
        (should (equal (car (plist-get (nelisp-ime-lattice-convert (car pair) nil) :candidates))
                       (cdr pair)))))))

(ert-deftest nelisp-ime-lattice-attested-no-invented-words ()
  (nelisp-ime-lattice-test--isolated
    (load nelisp-ime-lattice-attested-test-data nil t)
    (maphash (lambda (reading candidates)
               (dolist (surface '("利そう" "儂つ" "読のう" "酔とう" "分こう" "起こう" "来ります" "聞い" "咲い" "弄い"))
                 (ert-info ((format "Forbidden anywhere: %s in %s" surface reading))
                   (should-not (member surface candidates)))))
             nelisp-ime-dictionary-index)))

(ert-deftest nelisp-ime-lattice-attested-retains-real-forms ()
  (nelisp-ime-lattice-test--isolated
    (load nelisp-ime-lattice-attested-test-data nil t)
    (dolist (pair '(("よまない" . "読まない") ("よんだ" . "読んだ")
                    ("よもう" . "読もう") ("よぼう" . "呼ぼう")
                    ("かかない" . "書かない") ("かえらない" . "帰らない")
                    ("できない" . "出来ない") ("みない" . "見ない")
                    ("かえない" . "変えない") ("わかい" . "若い") ("かつごう" . "担ごう")))
      (ert-info ((format "Retained %s -> %s" (car pair) (cdr pair)))
        (should (member (cdr pair) (gethash (car pair) nelisp-ime-dictionary-index)))
        (should (member (cdr pair) (plist-get (nelisp-ime-lattice-convert (car pair) nil)
                                             :candidates)))))
    (should (member "呼ぼう" (cdr (gethash "よぼう" nelisp-ime-dictionary-index))))))

(ert-deftest nelisp-ime-lattice-attested-learning-promotes-generated-form ()
  (nelisp-ime-lattice-test--isolated
    (load nelisp-ime-lattice-attested-test-data nil t)
    (should (equal (car (gethash "よぼう" nelisp-ime-dictionary-index)) "予防"))
    (nelisp-ime-learning-import '(("よぼう" "呼ぼう" 1 1)))
    (should (equal (car (plist-get (nelisp-ime-lattice-convert "よぼう" nil) :candidates))
                   "呼ぼう"))))

(defvar nelisp-ime-generate-library-only)
(let ((nelisp-ime-generate-library-only t))
  (load (expand-file-name "../data/generate-skk-data.el"
                         (file-name-directory (or load-file-name buffer-file-name))) nil t))

(ert-deftest nelisp-ime-lattice-attested-generator-class-controls-row ()
  "Synthetic classifier records exercise generation without MeCab."
  (let ((classes (make-hash-table :test 'equal))
        (table (make-hash-table :test 'equal))
        (file (make-temp-file "ime-attested-")))
    (unwind-protect
        (progn
          (dolist (record '(("読む" "よむ" "五段・マ行")
                            ("酔う" "よう" "五段・ワ行促音便")
                            ("呼ぶ" "よぶ" "五段・バ行")
                            ("分かる" "わかる" "五段・ラ行")
                            ("食べる" "たべる" "一段")
                            ("有る" "ある" "五段・ラ行特殊")
                            ("行く" "いく" "五段・カ行促音便")))
            (puthash (cons (nth 0 record) (nth 1 record)) (list (nth 2 record)) classes))
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file file
              (insert "よn /読/\nよt /酔/\nよb /呼/\nわk /分/\nたb /食/\nいk /行/\nあr /有/\nわしt /儂/\nりs /利/\n")))
          (puthash "よぼう" '("予防") table)
          (nelisp-ime-generate--conjugations
           file 'utf-8 (nelisp-ime-generate--attestations classes) table)
          (dolist (pair '(("よまない" . "読まない") ("よんだ" . "読んだ")
                          ("よもう" . "読もう") ("よった" . "酔った")
                          ("わからない" . "分からない") ("たべない" . "食べない")
                          ("あります" . "有ります") ("いった" . "行った")))
            (should (member (cdr pair) (gethash (car pair) table))))
          (should (equal (gethash "よぼう" table) '("予防" "呼ぼう")))
          (dolist (reading '("よのう" "よとう" "わこう" "わしつ" "りそう" "いいた" "あらない"))
            (should-not (gethash reading table)))
          (maphash (lambda (_ candidates)
                     (dolist (candidate candidates)
                       (should-not (text-properties-at 0 candidate)))) table))
      (delete-file file))))

(ert-deftest nelisp-ime-lattice-attested-generator-rejects-ambiguous-classes ()
  (let ((classes (make-hash-table :test 'equal)))
    (puthash '("かえる" . "かえる") '("一段" "五段・ラ行") classes)
    (puthash '("帰る" . "かえる") '("五段・ラ行") classes)
    (puthash '("架える" . "かいる") '("一段") classes)
    (let ((attested (nelisp-ime-generate--attestations classes)))
      (should-not (gethash '("かえ" . "かえ") attested))
      (should-not (gethash '("架" . "か") attested))
      (should (gethash '("帰" . "かえ") attested)))))
(ert-deftest nelisp-ime-lattice-attested-classifier-rejects-shared-surface ()
  "A dictionary form also used by another verb class is ambiguous."
  (let ((file (make-temp-file "ime-verb-classes-")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'euc-jp))
            (with-temp-file file
              (insert "利す,0,0,0,動詞,自立,*,*,五段・サ行,基本形,利す,リス,リス\n")
              (insert "利す,0,0,0,動詞,自立,*,*,サ変・−スル,文語基本形,利する,リス,リス\n")
              (insert "見る,0,0,0,動詞,自立,*,*,一段,基本形,見る,ミル,ミル\n")
              (insert "みる,0,0,0,名詞,一般,*,*,*,*,みる,ミル,ミル\n")))
          (let* ((classes (nelisp-ime-generate--verb-classes file))
                 (attested (nelisp-ime-generate--attestations classes)))
            (should (= (length (gethash '("利す" . "りす") classes)) 2))
            (should-not (gethash '("利" . "り") attested))
            (should (gethash '("見" . "み") attested))
            (should-not (gethash '("み" . "み") attested))))
      (delete-file file))))
(ert-deftest nelisp-ime-lattice-attested-provenance-ranking ()
  "Code preference, volitional demotion, and validation preserve SKK order."
  (let ((table (make-hash-table :test 'equal))
        (plain (make-hash-table :test 'equal))
        (provenance (make-hash-table :test 'equal))
        (reference (make-hash-table :test 'equal)))
    (puthash "とった" '("問った" "訪った" "取った" "採った") table)
    (puthash "とった" '("問った" "禁った" "訪った" "取った" "採った") reference)
    (dolist (surface '("問った" "訪った"))
      (puthash (cons "とった" surface) '((:legacy t :matching nil)) provenance))
    (dolist (surface '("取った" "採った"))
      (puthash (cons "とった" surface) '((:legacy t :matching t)) provenance))
    (puthash "よぼう" '("呼ぼう" "予防" "輿望") table)
    (puthash "よぼう" '("呼ぼう" "予防" "輿望") reference)
    (puthash "よぼう" '("予防" "輿望") plain)
    (puthash '("よぼう" . "呼ぼう") '((:legacy t :matching t :volitional t)) provenance)
    (nelisp-ime-generate--rank table plain provenance reference)
    (should (equal (gethash "とった" table) '("取った" "採った" "問った" "訪った")))
    (should (equal (gethash "よぼう" table) '("予防" "輿望" "呼ぼう")))
    (should-not (member "禁った" (gethash "とった" table)))))

(ert-deftest nelisp-ime-lattice-attested-literal-code-is-not-onbin-evidence ()
  (let ((file (make-temp-file "ime-adjectives-"))
        (skk (make-temp-file "ime-onbin-"))
        (table (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'euc-jp))
            (with-temp-file file
              (insert "良い,0,0,0,形容詞,自立,*,*,形容詞・アウオ段,基本形,良い,ヨイ,ヨイ\n")
              (insert "若い,0,0,0,形容詞,自立,*,*,形容詞・アウオ段,基本形,若い,ワカイ,ワカイ\n")
              (insert "賄い,0,0,0,名詞,一般,*,*,*,*,賄い,マカナイ,マカナイ\n")
              (insert "聞い,0,0,0,動詞,自立,*,*,五段・カ行イ音便,連用タ接続,聞く,キイ,キイ\n")))
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file skk (insert "よi /良/\nわかi /若/\nまかなi /賄/\nきi /聞/\nさi /咲/\nいらi /弄/\n")))
          (nelisp-ime-generate--conjugations skk 'utf-8 (make-hash-table :test 'equal)
            table nil (nelisp-ime-generate--literal-spellings file))
          (should (equal (gethash "よい" table) '("良い")))
          (should (equal (gethash "わかい" table) '("若い")))
          (should (equal (gethash "まかない" table) '("賄い")))
          (dolist (reading '("きい" "さい" "いらい")) (should-not (gethash reading table))))
      (delete-file file) (delete-file skk))))


(ert-deftest nelisp-ime-lattice-attested-adjective-first-candidates ()
  (nelisp-ime-lattice-test--isolated
    (load nelisp-ime-lattice-attested-test-data nil t)
    (dolist (pair '(("あつく" . "熱く") ("ながく" . "長く") ("たかく" . "高く")
                    ("かたく" . "固く") ("しろく" . "白く") ("つよく" . "強く")
                    ("はやく" . "早く") ("よく" . "良く")))
      (ert-info ((format "Adjective first %s -> %s" (car pair) (cdr pair)))
        (should (equal (car (gethash (car pair) nelisp-ime-dictionary-index)) (cdr pair)))
        (should (equal (car (plist-get (nelisp-ime-lattice-convert (car pair) nil) :candidates))
                       (cdr pair)))))))

(ert-deftest nelisp-ime-lattice-attested-adjective-forms ()
  (nelisp-ime-lattice-test--isolated
    (load nelisp-ime-lattice-attested-test-data nil t)
    (dolist (pair '(("あおかった" . "青かった") ("あおくて" . "青くて")
                    ("あおければ" . "青ければ") ("あつくない" . "暑くない")
                    ("にがそう" . "苦そう") ("かたそう" . "硬そう")
                    ("からそう" . "辛そう") ("つよそう" . "強そう")
                    ("うまそう" . "上手そう")))
      (should (member (cdr pair) (gethash (car pair) nelisp-ime-dictionary-index))))
    (maphash (lambda (_ candidates)
               (dolist (surface '("仰かった" "扇くない"))
                 (should-not (member surface candidates)))) nelisp-ime-dictionary-index)))


(ert-deftest nelisp-ime-lattice-attested-nonverb-row-forms ()
  "Only adjective paradigms, na-adjective そう, and exact non-verbs survive."
  (let ((csv (make-temp-file "ime-nonverbs-")) (skk (make-temp-file "ime-adjective-"))
        (table (make-hash-table :test 'equal)) (provenance (make-hash-table :test 'equal))
        (adjectives (make-hash-table :test 'equal)) (na-adjectives (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'euc-jp))
            (with-temp-file csv
              (insert "青い,0,0,0,形容詞,自立,*,*,形容詞・アウオ段,基本形,青い,アオイ,アオイ\n")
              (insert "上手,0,0,0,名詞,形容動詞語幹,*,*,*,*,上手,ジョウズ,ジョーズ\n")
              (insert "能く,0,0,0,副詞,一般,*,*,*,*,能く,ヨク,ヨク\n")
              (insert "仰い,0,0,0,動詞,自立,*,*,五段・ガ行,連用タ接続,仰ぐ,アオイ,アオイ\n")))
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file skk
              (insert "あおi /青/仰/\nあおk /青/\nあおs /青/\nおうぎi /扇/\nじょうずs /上手/\nよk /能/\n")))
          (nelisp-ime-generate--conjugations
           skk 'utf-8 (make-hash-table :test 'equal) table provenance
           (nelisp-ime-generate--literal-spellings csv nil adjectives na-adjectives)
           adjectives na-adjectives)
          (dolist (suffix '("い" "く" "くない" "かった" "くて" "ければ" "そう"))
            (should (equal (gethash (concat "あお" suffix) table) (list (concat "青" suffix)))))
          (should (equal (gethash "じょうずそう" table) '("上手そう")))
          (should (equal (gethash "よく" table) '("能く")))
          (should (= (hash-table-count table) 9))
          (should (plist-get (car (gethash '("あおく" . "青く") provenance)) :matching))
          (dolist (reading '("あおかない" "あおきます" "あおいた" "あおす" "じょうずす" "おうぎくない"))
            (should-not (gethash reading table))))
      (delete-file csv) (delete-file skk))))

(provide 'nelisp-ime-lattice-attested-test)
