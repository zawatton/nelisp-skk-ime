;;; skk-input-rules.el --- User kana input rules -*- lexical-binding: t; coding: utf-8; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(defvar skk-input-rules-config nil)
(defvar skk-input-rules--base nil)
(defvar skk-input-rules--base-saved nil)
(defvar skk-input-rules--base-tree nil)
(defvar skk-input-rules--tree nil)
(defvar ddskk-engine--rule-tree-cache nil)
(defvar skk-input-rules--bindings nil)
(defvar skk-input-rules--export-key nil)
(defvar skk-input-rules--export-value nil)

(defun skk-input-rules-export (tree)
  "Cache the wire export while TREE and punctuation settings stay unchanged."
  (let ((key (list tree skk-input-rules-config
                   (and (boundp 'skk-kutouten-type) skk-kutouten-type)
                   (and (boundp 'skk-current-kuten) skk-current-kuten)
                   (and (boundp 'skk-current-touten) skk-current-touten))))
    (unless (equal key skk-input-rules--export-key)
      (setq skk-input-rules--export-value
            (concat "RULES 1 " (mapconcat #'identity
                                          (ddskk-engine--romaji-walk tree) " ")
                    " " (skk-input-rules-metadata))
            skk-input-rules--export-key key))
    skk-input-rules--export-value))

(defun skk-input-rules--without (key rows)
  "Remove KEY without mutating shared default rows."
  (let (result)
    (dolist (row rows) (unless (equal key (car row)) (push row result)))
    (nreverse result)))

(defun skk-input-rules--patch-tree (tree key output index)
  "Copy only the path to KEY; share untouched immutable branches."
  (if (= index (length key))
      (list (car tree) (nth 1 tree) nil output (nth 4 tree))
    (let* ((ch (aref key index)) (old (assq ch (nth 4 tree)))
           (child (skk-input-rules--patch-tree
                   (or old (list ch (substring key 0 (1+ index)) nil nil nil))
                   key output (1+ index)))
           branches)
      (dolist (branch (nth 4 tree))
        (push (if (eq branch old) child branch) branches))
      (unless old (push child branches))
      (list (car tree) (nth 1 tree) (nth 2 tree) (nth 3 tree) (nreverse branches)))))

(defun skk-input-rules-defaults ()
  "Return fresh defaults matching the user's DDSKK configuration."
  (list :width "hankaku" :auto-pair t :errors nil
        :tables (list
                 (cons "symbols-hankaku" '(("!" "!") ("," ", ") ("." ". ")
                                          (":" ":") (";" ";") ("?" "?") ("z " " ")))
                 (cons "symbols-zenkaku" '(("!" "！") ("," "、") ("." "。")
                                          (":" "：") (";" "；") ("?" "？") ("z " "　")))
                 (cons "pairs-hankaku" '(("(" "(" ")") ("[" "「" "」") ("{" "{" "}")))
                 (cons "pairs-zenkaku" '(("(" "(" ")") ("[" "「" "」") ("{" "｛" "｝")))
                 (cons "pairs" '(("「" "「" "」") ("『" "『" "』") ("（" "（" "）")
                                  ("【" "【" "】") ("〈" "〈" "〉") ("《" "《" "》")
                                  ("〔" "〔" "〕") ("［" "［" "］") ("｛" "｛" "｝")
                                  ("(" "(" ")") ("{" "{" "}") ("[" "[" "]")
                                  ("\"" "\"" "\"") ("“" "“" "”") ("`" "`" "'"))))))

(defun skk-input-rules-path ()
  "Resolve the environment override or the inherited roaming AppData."
  (let ((override (getenv "NELISP_IME_INPUT_RULES")) (appdata (getenv "APPDATA")))
    (cond ((and override (> (length override) 0)) override)
          ((and appdata (> (length appdata) 0))
           (expand-file-name "NativeIME/input-rules.conf" appdata)))))

(defun skk-input-rules--tokens (line)
  "Tokenize LINE without evaluating Lisp; preserve quoted whitespace."
  (let ((i 0) (n (length line)) tokens)
    (while (< i n)
      (let ((ch (aref line i)))
        (cond
         ((memq ch '(32 9 13 65279)) (setq i (1+ i)))
         ((= ch 35) (setq i n))
         ((= ch 61) (push (cons "=" nil) tokens) (setq i (1+ i)))
         ((= ch 34)
          (setq i (1+ i))
          (let ((value "") (closed nil))
            (while (and (< i n) (not closed))
              (setq ch (aref line i) i (1+ i))
              (cond ((= ch 34) (setq closed t))
                    ((= ch 92)
                     (when (>= i n) (error "unfinished escape"))
                     (setq ch (aref line i) i (1+ i))
                     (unless (memq ch '(34 92)) (error "unsupported escape"))
                     (setq value (concat value (string ch))))
                    (t (setq value (concat value (string ch))))))
            (unless closed (error "unterminated string"))
            (push (cons value t) tokens)))
         (t (let ((start i))
              (while (and (< i n) (not (memq (aref line i) '(32 9 13 35 61 34))))
                (setq i (1+ i)))
              (push (cons (substring line start i) nil) tokens))))))
    (nreverse tokens)))

(defun skk-input-rules-parse (text)
  "Parse TEXT, skipping invalid lines and collecting numbered errors."
  (let ((config (skk-input-rules-defaults)) (section nil) (number 0))
    ;; Table cells are fresh; row replacement is non-destructive.
    (dolist (line (split-string text "\n"))
      (setq number (1+ number))
      (condition-case err
          (let* ((tokens (skk-input-rules--tokens line))
                 (head (car (car tokens))))
            (cond
             ((null tokens))
             ((and (= (length tokens) 1) (string-match "\\`\\[\\([^]]+\\)\\]\\'" head))
              (setq section (match-string 1 head))
              (unless (assoc section (plist-get config :tables))
                (error "unknown section %s" section)))
             (t
              (unless (and (>= (length tokens) 3) (equal (car (nth 1 tokens)) "="))
                (error "expected key = value"))
              (cond
               ((null section)
                (unless (= (length tokens) 3) (error "expected one option value"))
                (let ((value (car (nth 2 tokens))))
                  (cond ((equal head "width")
                         (unless (member value '("hankaku" "zenkaku")) (error "invalid width"))
                         (setq config (plist-put config :width value)))
                        ((equal head "auto-pair")
                         (unless (member value '("yes" "no")) (error "invalid auto-pair"))
                         (setq config (plist-put config :auto-pair (equal value "yes"))))
                        (t (error "unknown option %s" head)))))
               (t
                (let* ((table (assoc section (plist-get config :tables)))
                       (values (nthcdr 2 tokens))
                       (count (if (string-match "\\`symbols-" section) 1 2)))
                  (unless table (error "unknown section %s" section))
                  (unless (= (length values) count) (error "wrong number of quoted values"))
                  (dolist (value values)
                    (unless (cdr value) (error "values must be quoted")))
                  (when (= (length head) 0) (error "empty key"))
                  (when (and (= count 1) (string-match "[^ -~]" head))
                    (error "symbol keys must be ASCII"))
                  (when (and (= count 2) (or (equal (car (car values)) "")
                                            (equal (car (nth 1 values)) "")))
                    (error "empty opener or closer"))
                  (setcdr table (append (skk-input-rules--without head (cdr table))
                                        (list (cons head (mapcar #'car values)))))))))))
        (error (setq config (plist-put config :errors
                                       (append (plist-get config :errors)
                                               (list (format "line %d: %s" number
                                                             (error-message-string err)))))))))
    config))

(defun skk-input-rules-active-table (kind)
  (cdr (assoc (concat kind "-" (plist-get skk-input-rules-config :width))
              (plist-get skk-input-rules-config :tables))))

(defun skk-input-rules-prefix-p (key)
  "Whether KEY starts a configured rule in the current kana mode."
  (and skk-input-rules-config
       (boundp 'skk-j-mode) skk-j-mode
       (not skk-latin-mode) (not skk-jisx0208-latin-mode) (not skk-abbrev-mode)
       (let ((found nil))
         (dolist (row (append (skk-input-rules-active-table "symbols")
                              (skk-input-rules-active-table "pairs")))
           (when (= key (aref (car row) 0)) (setq found t)))
         found)))

(defun skk-input-rules-pairs ()
  "Return effective opener/closer entries, excluding special midashi."
  (let ((pairs (cdr (assoc "pairs" (plist-get skk-input-rules-config :tables)))))
    (dolist (row (skk-input-rules-active-table "pairs"))
      (setq pairs (append (skk-input-rules--without (nth 1 row) pairs)
                          (list (list (nth 1 row) (nth 1 row) (nth 2 row))))))
    (let (result)
      (dolist (row pairs)
        (unless (and (= (length (nth 1 row)) 1)
                     (memq (aref (nth 1 row) 0) skk-special-midashi-char-list))
          (push row result)))
      (nreverse result))))

(defun skk-input-rules-apply (config)
  "Install CONFIG idempotently and rebuild DDSKK's effective rule tree."
  (unless skk-input-rules--base-saved
    (setq skk-input-rules--base (copy-sequence skk-rom-kana-rule-list)
          skk-input-rules--base-saved t)
    (unless ddskk-engine--rule-tree-cache
      (ignore-errors (load (expand-file-name "engine/skk-rule-tree-cache.el"))))
    (setq skk-input-rules--base-tree
          (or (and ddskk-engine--rule-tree-cache
                   (equal (plist-get ddskk-engine--rule-tree-cache :base-hash)
                          (sxhash-equal skk-rom-kana-base-rule-list))
                   (equal (plist-get ddskk-engine--rule-tree-cache :extra-hash)
                          (sxhash-equal skk-rom-kana-rule-list))
                   (plist-get ddskk-engine--rule-tree-cache :tree))
              (skk-compile-rule-list skk-rom-kana-base-rule-list skk-rom-kana-rule-list))))
  (setq skk-input-rules-config config
        skk-rom-kana-rule-list skk-input-rules--base
        skk-input-rules--tree skk-input-rules--base-tree)
  (dolist (binding skk-input-rules--bindings)
    (define-key skk-j-mode-map (car binding) (cdr binding)))
  (dolist (row (append (skk-input-rules-active-table "symbols")
                       (skk-input-rules-active-table "pairs")))
    ;; DDSKK's initial map does not send newly introduced prefixes such as
    ;; ! through the tree. Latin's separate keymap stays untouched.
    (let ((first (substring (car row) 0 1)))
      (unless (assoc first skk-input-rules--bindings)
        (push (cons first (lookup-key skk-j-mode-map first)) skk-input-rules--bindings))
      (define-key skk-j-mode-map first 'skk-insert))
    (setq skk-rom-kana-rule-list
          (append (skk-input-rules--without (car row) skk-rom-kana-rule-list)
                  (list (list (car row) nil (nth 1 row)))))
    ;; Rebuild changed paths without traversing/copying every DDSKK node.
    (setq skk-input-rules--tree
          (skk-input-rules--patch-tree skk-input-rules--tree (car row) (nth 1 row) 0)))
  ;; Pairing belongs to the application's commit session, not the engine
  ;; buffer: engine point movement cannot position an application's caret.
  (setq skk-auto-insert-paren nil
        skk-rule-tree skk-input-rules--tree))

(defun skk-input-rules-load ()
  (let ((path (skk-input-rules-path)) (text "") errors)
    (when path
      (condition-case err
          ;; The standalone runtime's file-exists-p is a compatibility
          ;; stub. Use its nil-on-missing UTF-8 reader, as user-jisyo does.
          (if (fboundp 'nelisp--syscall-read-file)
              (setq text (or (nelisp--syscall-read-file path) ""))
            (when (file-exists-p path)
              (with-temp-buffer
                (let ((coding-system-for-read 'utf-8)) (insert-file-contents path))
                (setq text (buffer-string)))))
        (error (setq errors (list (format "file: %s" (error-message-string err)))))))
    (let ((config (skk-input-rules-parse text)))
      (when errors (setq config (plist-put config :errors errors)))
      (skk-input-rules-apply config))))

(defun skk-input-rules-metadata ()
  "Append pair metadata to RULES 1 using its existing scalar-hex fields.
Reserved SOH-prefixed keys never enter the matcher. The sixth field is
the closer; the command field identifies metadata rather than a rule."
  (let ((index 0)
        (records (list (mapconcat #'ddskk-engine--hex
                                 (list "\1options" "" (plist-get skk-input-rules-config :width)
                                       (if (plist-get skk-input-rules-config :auto-pair) "yes" "no")
                                       "input-options") ":"))))
    (when (plist-get skk-input-rules-config :auto-pair)
      (dolist (row (skk-input-rules-pairs))
        (push (mapconcat #'ddskk-engine--hex
                         (list (format "\1pair%d" index) "" (nth 1 row) (nth 1 row)
                               "input-pair" (nth 2 row)) ":") records)
        (setq index (1+ index))))
    (dolist (error (plist-get skk-input-rules-config :errors))
      (push (mapconcat #'ddskk-engine--hex
                       (list (format "\1error%d" index) "" error "" "input-error") ":") records)
      (setq index (1+ index)))
    (mapconcat #'identity (nreverse records) " ")))

(provide 'skk-input-rules)
