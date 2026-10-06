;;; test-local-conversion-oracle.el --- Stock DDSKK lookup oracle -*- lexical-binding: t; -*-
;; GPL-3.0-or-later. Only synthetic files under the runner's private HOME.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'skk)
(require 'skk-user-jisyo)

(defun nelisp--syscall-read-file (path)
  (when (file-readable-p path)
    (with-temp-buffer (insert-file-contents path) (buffer-string))))
(require 'skk-local-conversion)

(defun lfd1-oracle--source (name content)
  (let ((path (expand-file-name name (getenv "LOCAL_ORACLE_DIR")))
        (coding-system-for-write 'utf-8-unix))
    (with-temp-file path (insert content))
    path))

(defun lfd1-oracle--hex (value)
  (if (string-empty-p value) "-"
    (mapconcat (lambda (c) (format "%06x" c)) value "")))

(defun lfd1-oracle--unhex (value)
  (if (equal value "-") ""
    (should (= (% (length value) 6) 0))
    (apply #'string (cl-loop for n from 0 below (length value) by 6
                            collect (string-to-number (substring value n (+ n 6)) 16)))))

(defun ddskk-engine--hex (value) (lfd1-oracle--hex value))
(defun lfd1-oracle--profile-overlay (name)
  "Produce metadata using the engine's actual snapshot, without a real jisyo."
  (let ((skk-search-prog-list '((ddskk-user-jisyo-search) (ddskk-engine-server-search)))
        (skk-update-jisyo-function 'ddskk-user-jisyo--update)
        (ddskk-user-jisyo-learning-disabled nil)
        (ddskk-user-jisyo--table (make-hash-table :test 'equal))
        (ddskk-user-jisyo--okuri-blocks (make-hash-table :test 'equal))
         (ddskk-user-jisyo--sections (make-hash-table :test 'equal))
        (ddskk-local-operations (make-hash-table :test 'equal)))
    (should (ddskk-local-capability))
    (lfd1-oracle--source name
      (lfd1-oracle--unhex (substring (ddskk-local-dispatch "LOCAL SNAPSHOT") 8)))))

(defun lfd1-oracle--lookup (overlay sources reading &optional okuri)
  (with-temp-buffer
    (insert (lfd1-oracle--hex reading) " " (lfd1-oracle--hex (or okuri "")) "\n")
    (should (= (apply #'call-process-region (point-min) (point-max)
                      (getenv "LOCAL_ORACLE_BINARY") t '(t nil) nil "--lookup"
                      (or overlay "-") sources) 0))
    (let* ((fields (split-string (string-trim (buffer-string)) "\t"))
           (candidates (nth 2 fields)))
      (should (= (length fields) 4))
      (list (car fields) (nth 1 fields)
            (unless (equal candidates "-")
              (mapcar #'lfd1-oracle--unhex (split-string candidates ",")))
            (lfd1-oracle--unhex (nth 3 fields))))))

(defun lfd1-oracle--stock (sources reading &optional okuri)
  ;; Run the real stock source functions and lazy search union. Limit 0 is
  ;; intentional: stock linear lookup supports unsorted fixture dictionaries.
  (with-temp-buffer
    (let* ((skk-jisyo-code 'utf-8)
           (skk-use-numeric-conversion nil)
           (skk-search-end-function nil)
           (skk-henkan-okuri-strictly nil)
           (skk-henkan-strict-okuri-precedence nil)
           (skk-henkan-key reading)
           (skk-henkan-okurigana okuri)
           (skk-okuri-char nil)
           (skk-current-search-prog-list
            (mapcar (lambda (file)
                      (list 'skk-search-jisyo-file (list 'quote (cons file 'utf-8)) 0 t)) sources))
           words)
      (while skk-current-search-prog-list
        (setq words (skk-nunion words (skk-search))))
      words)))

(defconst lfd1-oracle--headers
  ";; okuri-ari entries.\nかk /書/掛/[く/掛/書/]/\n>わたs /渡/\n;; okuri-nasi entries.\n")

(ert-deftest lfd1-stock-two-source-plain-order-and-annotations ()
  (let* ((first (lfd1-oracle--source
                 "plain-first.jisyo"
                 (concat lfd1-oracle--headers
                         "いどう /移動/異動;†「人事-」/\n"
                         "おーむ /Ω/オーム/\n"
                         "かさ /笠/笠/傘/\n"
                         "ちゅうしゃく /値/\nぎゃく /値;first/\n"
                         "りてらる /(笑)/(Ω)/(text) suffix/#literal/\n"
                         "かっこ /[literal/]/\nSKK /Simple Kana to Kanji/\nskk /Simple Kana to Kanji lowercase/[literal/]/\n"
                         "C++ /C Plus Plus/\nオーム /Ω/\n移動 /移動/\n>おーむ /Ω/\nおーむ< /Ω/\n/ /／/÷/\n"
                         "みどり /緑/\nいどう /井道/\n")))
         (second (lfd1-oracle--source
                  "plain-second.jisyo"
                  (concat lfd1-oracle--headers
                          "おーむ /Ω/王蟲/\n"
                          "いどう /移動/異動;later/異同;†difference.「諸写本の-」/医道/\n"
                          "かさ /傘/笠/嵩/\n"
                          "ちゅうしゃく /値;later/価;price/\nぎゃく /値/値;later/価/\n")))
         (sources (list first second))
         (rows 0))
    (dolist (request '(("おーむ") ("いどう") ("かさ") ("ちゅうしゃく") ("ぎゃく")
                       ("りてらる") ("かっこ") ("SKK") ("skk") ("みどり") ("かk" "く")
                       (">わたs" "す") ("C++") ("オーム") ("移動") (">おーむ") ("おーむ<") ("/")))
      (let* ((reading (car request)) (okuri (cadr request))
             (stock (lfd1-oracle--stock sources reading okuri))
             (local (lfd1-oracle--lookup nil sources reading okuri)))
        (ert-info ((format "reading=%s okuri=%s local=%S" reading okuri local))
          (should stock)
          (should (equal (car local) "OK"))
          (should (equal (nth 2 local) stock))
          (should (equal (nth 3 local)
                         (concat (car (skk-treat-strip-note-from-word (car stock))) okuri))))
        (setq rows (1+ rows))))
    (message "PASS stock two-source oracle: %d rows, order/annotations/commit" rows)))

(ert-deftest lfd1-stock-overlay-after-engine-learning ()
  (let* ((personal (lfd1-oracle--source "learn-stock.jisyo"
                                     (concat lfd1-oracle--headers "おーむ /Ω/オーム/\n")))
         (shared (lfd1-oracle--source "learn-shared.jisyo"
                                   (concat lfd1-oracle--headers "おーむ /Ω/王蟲/\n")))
         (ddskk-user-jisyo--table (make-hash-table :test 'equal))
         (ddskk-user-jisyo--okuri-blocks (make-hash-table :test 'equal))
         (ddskk-user-jisyo--sections (make-hash-table :test 'equal))
         (ddskk-user-jisyo-learning-disabled nil)
         (ddskk-user-jisyo-local-revision 0)
         (ddskk-user-jisyo--load-dirty nil))
    (ddskk-user-jisyo--parse-into-table "おーむ /Ω/オーム/\n" ddskk-user-jisyo--table)
    (dolist (word '(nil "王蟲"))
      (when word
        (let ((skk-henkan-key "おーむ") (skk-henkan-okurigana nil)
              (skk-okuri-char nil) (skk-okuri-index-min -1)
              (skk-jisyo personal) (skk-jisyo-code 'utf-8)
              (skk-jisyo-save-count nil) (skk-share-private-jisyo nil))
          (skk-update-jisyo-original word nil)
          (ddskk-user-jisyo--update word)))
      (let* ((overlay (lfd1-oracle--source "learn-overlay.jisyo" (ddskk-user-jisyo--serialize)))
             (stock (lfd1-oracle--stock (list personal shared) "おーむ"))
             (local (lfd1-oracle--lookup overlay (list shared) "おーむ")))
        (should (equal (car local) "OK"))
        (should (equal (nth 2 local) stock))
        (should (equal (nth 3 local) (car stock)))))
    (message "PASS stock overlay oracle: 2 rows before/after engine learning")))

(ert-deftest lfd1-stock-dynamic-cases-remain-provider-owned ()
  (let ((source (lfd1-oracle--source
                 "dynamic.jisyo"
                 (concat lfd1-oracle--headers
                         "どうてき /(concat \"word\")/\n"
                         "ちゅうどうてき /語;(concat \"note\")/\n"
                         "しゅうどうてき /語;plain;(concat \"note\")/\n"
                         "ねすと /((lambda () \"word\"))/\n"
                         "ちゅうねすと /語;((lambda () \"note\"))/\n"
                         "ほしちゅう /語;*(concat \"note\")/\n"
                         "すうじ1 /数字/\nすうじ# /第#0/\n"))))
    (dolist (reading '("どうてき" "ちゅうどうてき" "しゅうどうてき" "ねすと" "ちゅうねすと" "ほしちゅう" "すうじ1" "すうじ#"))
      (should (lfd1-oracle--stock (list source) reading))
      (should (equal (car (lfd1-oracle--lookup nil (list source) reading)) "NO")))
    (should (equal (skk-eval-string "語;(concat \"note\")") "語;note"))
    (should (equal (skk-eval-string "((lambda () \"word\"))") "word"))
    (require 'skk-annotation)
    (should (equal (skk-eval-string (skk-annotation-get "*(concat \"note\")")) "note"))
    (message "PASS stock dynamic oracle: 8 provider-owned rows")))

(ert-deftest lfd1-stock-source-rejection-is-sticky ()
  ;; Independent sources must never repair each other's malformed blocks or
  ;; hide an expression while compiling a shared frontier.
  (let ((first (lfd1-oracle--source "broken-first.jisyo"
                                   ";; okuri-ari entries.\nかk /A/[く/B/\n;; okuri-nasi entries.\n"))
        (second (lfd1-oracle--source "broken-second.jisyo"
                                    ";; okuri-ari entries.\nかk /(symbol-name 'x)/]/\n;; okuri-nasi entries.\n")))
    (should (equal (car (lfd1-oracle--lookup nil (list first second) "かk" "く")) "NO")))
  (let ((ambiguous (lfd1-oracle--source "ambiguous.jisyo"
                   ";; okuri-ari entries.\nかk /書/\n;; okuri-nasi entries.\nかk /literal/\n")))
    (should (equal (lfd1-oracle--stock (list ambiguous) "かk") '("literal")))
    (should (equal (lfd1-oracle--stock (list ambiguous) "かk" "く") '("書")))
    (dolist (okuri '(nil "く"))
      (let ((local (lfd1-oracle--lookup nil (list ambiguous) "かk" okuri)))
        (should (equal (car local) "OK"))
        (should (equal (nth 2 local) (lfd1-oracle--stock (list ambiguous) "かk" okuri))))))
  (message "PASS stock source isolation: 1 malformed rejection, 2 distinct section rows"))

(ert-deftest lfd1-stock-headerless-source-order ()
  (let* ((raw "いどう /移動/異動;first/\nおーむ /Ω/オーム/\nおーむ /後発/\n")
         (first (lfd1-oracle--source "headerless.jisyo" raw))
         ;; Stock DDSKK requires section headers. This private fixture copy
         ;; adds only those headers, preserving every entry and its order.
         (stock-first (lfd1-oracle--source "headerless-stock-copy.jisyo"
                                         (concat lfd1-oracle--headers raw)))
         (second (lfd1-oracle--source "sectioned-second.jisyo"
                                    (concat lfd1-oracle--headers "おーむ /Ω/王蟲/\nいどう /異同;later/\n"))))
    (dolist (reading '("おーむ" "いどう"))
      (let ((local (lfd1-oracle--lookup nil (list first second) reading)))
        (should (equal (car local) "OK"))
        (should (equal (nth 2 local) (lfd1-oracle--stock (list stock-first second) reading)))))
    (message "PASS headerless source order: 2 stock-normalized fixture rows")))

(ert-deftest lfd1-stock-overlay-only-reading ()
  (let* ((personal (lfd1-oracle--source "overlay-only.jisyo"
                                      (concat lfd1-oracle--headers "おーむ /Ω/オーム/\n")))
         (shared (lfd1-oracle--source "empty-shared.jisyo" lfd1-oracle--headers))
         (local (lfd1-oracle--lookup personal (list shared) "おーむ")))
    (should (equal (car local) "OK"))
    (should (equal (nth 2 local) (lfd1-oracle--stock (list personal shared) "おーむ")))
    (message "PASS overlay-only source: 1 stock row")))

(ert-deftest lfd1-stock-loaded-duplicate-personal-overlay ()
  (let* ((raw (concat ";; okuri-ari entries.\nかk /書/掛/[く/掛/書/]/後/\n;; okuri-nasi entries.\n"
                     "おーむ /Ω/オーム/\nいどう /移動/異動;first/\n"
                     "おーむ /後一/\nいどう /後一/\nおーむ /後二/\nいどう /後二/\n"
                     "おーむ /後三/\nいどう /後三/\nかっこ /[literal/]/後/\nskk /[literal/]/後/\n"))
         (personal (lfd1-oracle--source "duplicates-stock.jisyo" raw))
         (shared (lfd1-oracle--source "duplicates-shared.jisyo"
                   (concat lfd1-oracle--headers "おーむ /Ω/王蟲/\nいどう /異同;later/医道/\n")))
         (ddskk-user-jisyo--table (make-hash-table :test 'equal))
         (ddskk-user-jisyo--okuri-blocks (make-hash-table :test 'equal))
         (ddskk-user-jisyo--sections (make-hash-table :test 'equal))
         (ddskk-user-jisyo--load-dirty nil))
    (cl-letf (((symbol-function 'ddskk-user-jisyo-path) (lambda () personal)))
      (ddskk-user-jisyo-load))
    (let ((overlay (lfd1-oracle--source "duplicates-overlay.jisyo" (ddskk-user-jisyo--serialize))))
      (dolist (request '(("おーむ") ("いどう") ("かっこ") ("skk") ("かk" "く")))
        (let* ((reading (car request)) (okuri (cadr request))
               (local (lfd1-oracle--lookup overlay (list personal shared) reading okuri)))
          (should (equal (car local) "OK"))
          (should (equal (nth 2 local) (lfd1-oracle--stock (list personal shared) reading okuri))))))
    (message "PASS loaded duplicate overlay: 5 stock rows, 6 distinct duplicate entries, nasi brackets and okuri suffix")))

(ert-deftest lfd1-stock-lowercase-abbrev-learning ()
  (let* ((personal (lfd1-oracle--source "abbrev-stock.jisyo"
                                      (concat lfd1-oracle--headers "skk /first/\n")))
         (shared (lfd1-oracle--source "abbrev-shared.jisyo"
                                    (concat lfd1-oracle--headers "skk /second/\n")))
         (ddskk-user-jisyo--table (make-hash-table :test 'equal))
         (ddskk-user-jisyo--okuri-blocks (make-hash-table :test 'equal))
         (ddskk-user-jisyo--sections (make-hash-table :test 'equal))
         (ddskk-user-jisyo-learning-disabled nil)
         (ddskk-user-jisyo-local-revision 0)
         (ddskk-user-jisyo--load-dirty nil))
    (ddskk-user-jisyo--parse-into-table "skk /first/\n" ddskk-user-jisyo--table)
    (dolist (word '(nil "second"))
      (when word
        (let ((skk-henkan-key "skk") (skk-henkan-okurigana nil)
              (skk-okuri-char nil) (skk-okuri-index-min -1)
              (skk-jisyo personal) (skk-jisyo-code 'utf-8)
              (skk-jisyo-save-count nil) (skk-share-private-jisyo nil))
          (skk-update-jisyo-original word nil)
          (ddskk-user-jisyo--update word)))
      (let* ((overlay (lfd1-oracle--source "abbrev-overlay.jisyo" (ddskk-user-jisyo--serialize)))
             (local (lfd1-oracle--lookup overlay (list shared) "skk")))
        (should (equal (car local) "OK"))
        (should (equal (nth 2 local) (lfd1-oracle--stock (list personal shared) "skk")))))
    (message "PASS lowercase abbrev learning: 2 stock rows")))

(ert-deftest lfd1-stock-certified-literal-annotations ()
  (require 'skk-annotation)
  (let* ((overlay (lfd1-oracle--profile-overlay "literal-profile.jisyo"))
         (source nil)
         (content lfd1-oracle--headers)
         (readings nil)
         (n 0))
    (dolist (form ddskk-local-literal-annotations)
      (let ((reading (concat "ちゅう" (string (+ #x3041 n)))))
        (push (cons reading form) readings)
        (setq content (concat content reading " /候補;" form "/\n")))
      (setq n (1+ n)))
    (setq source (lfd1-oracle--source "literal-annotations.jisyo" content))
    (with-temp-buffer
      (should (= (call-process (getenv "LOCAL_ORACLE_BINARY") nil '(t nil) nil "--profile") 0))
      (should (equal (mapcar #'lfd1-oracle--unhex (split-string (string-trim (buffer-string)) ","))
                     ddskk-local-literal-annotations)))
    (dolist (row readings)
      (let* ((reading (car row)) (form (cdr row))
             (stock (lfd1-oracle--stock (list source) reading))
             (local (lfd1-oracle--lookup overlay (list source) reading)))
        (should (equal (skk-eval-string (skk-annotation-get form)) form))
        (should (equal (car (lfd1-oracle--lookup nil (list source) reading)) "NO"))
        (should (equal (car local) "OK"))
        (should (equal (nth 2 local) stock))
        (should (equal (nth 3 local) "候補"))))
    (let ((forged (lfd1-oracle--source "forged-profile.jisyo"
                    (concat lfd1-oracle--headers ddskk-local-literal-profile-marker "\nかな /語;(most)/\n")))
          (expressions (lfd1-oracle--source "profile-expressions.jisyo"
                         (concat lfd1-oracle--headers
                                 "かな /(most)/\nことば /語;(lfd1-unknown-function)/\n"))))
      (should (equal (car (lfd1-oracle--lookup nil (list forged) "かな")) "NO"))
      (dolist (reading '("かな" "ことば"))
        (should (equal (car (lfd1-oracle--lookup overlay (list expressions) reading)) "NO"))))
    (let ((star (lfd1-oracle--source "star-profile.jisyo"
                  (concat lfd1-oracle--headers "ほし /語;*(most)/語;plain;(order)/\n"))))
      (should (equal (nth 2 (lfd1-oracle--lookup overlay (list star) "ほし"))
                     (lfd1-oracle--stock (list star) "ほし"))))
    (message "PASS stock literal profile: 21 guarded rows, 24 markerless/forged/expression negatives")))

;;; test-local-conversion-oracle.el ends here
