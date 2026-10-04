;;; test-live-input.el --- DDSKK batch replay and mode-key oracles -*- lexical-binding: t; -*-

(require 'ert)
(require 'skk-ime-session)

;; Tests own and remove their temporary dictionaries; never save a profile
;; dictionary or record its statistics when this batch Emacs exits.
(remove-hook 'kill-emacs-hook #'skk-save-jisyo)
(remove-hook 'kill-emacs-hook #'skk-record-jisyo-data)

(defun live-input--log-stock-state (label state)
  "Log the oracle in ASCII so Windows console encodings cannot obscure it."
  (message "STOCK %s: mode=%s text=%s composition-start=%S"
           label (plist-get state :mode)
           (mapconcat (lambda (char) (format "%06x" char))
                      (string-to-list (plist-get state :text)) "")
           (plist-get state :composition-start)))

(defmacro live-input--isolated (&rest body)
  `(let ((skk-jisyo (expand-file-name "stock-jisyo" temporary-file-directory))
         (skk-backup-jisyo nil) (skk-server-host nil)
         (skk-search-prog-list nil))
     ,@body))

(ert-deftest live-input-batch-equals-individual-keys ()
  (live-input--isolated
   (dolist (keys '("tya" "tyu" "tyo" "tta" "nn" "n'" "nka"
                   "z." "z/" "z0" "z*" "zL" "Kanaq" "qKanaq"
                   "KanaQ" "Kanal" "KanaL"))
     (let ((batch (skk-ime-session-create))
           (individual (skk-ime-session-create)))
       (unwind-protect
           (progn
             (dolist (key (string-to-list keys))
               (skk-ime-session-feed-key individual key))
             (should (equal (skk-ime-session-feed-string batch keys)
                            (skk-ime-session-snapshot individual))))
         (skk-ime-session-destroy batch)
         (skk-ime-session-destroy individual))))))

(ert-deftest live-input-preedit-mode-key-oracle ()
  (live-input--isolated
   (dolist (sample '(("Kanaq" hiragana "カナ")
                     ("qKanaq" katakana "かな")
                     ("KanaQ" preedit "かな▽")
                     ("Kanal" latin "かな")
                     ("KanaL" wide-latin "かな")))
     (let ((session (skk-ime-session-create)))
       (unwind-protect
           (let ((state (skk-ime-session-feed-string session (car sample))))
             (should (eq (plist-get state :mode) (nth 1 sample)))
             (should (equal (plist-get state :text) (nth 2 sample))))
         (skk-ime-session-destroy session))))
   (let ((session (skk-ime-session-create)))
     (unwind-protect
         (progn
           (skk-ime-session-feed-string session "Kana")
           (let ((before (skk-ime-session-snapshot session)))
             (should-error (skk-ime-session-feed-key session ?/))
             (should (equal before (skk-ime-session-snapshot session)))))
       (skk-ime-session-destroy session)))))

(ert-deftest live-input-suite-mode-prefix-oracle ()
  "Derive the TSF suite's changed prefixes using stock DDSKK commands."
  (let* ((fixture (expand-file-name "windows/test-host/data/behavior-jisyo.utf8"
                                   default-directory))
         (skk-jisyo (make-temp-file "live-input-stock-"))
         (skk-jisyo-code 'utf-8)
         (skk-backup-jisyo nil) (skk-server-host nil)
         (skk-search-prog-list '((skk-search-jisyo-file skk-jisyo 0 t)))
         session)
    (copy-file fixture skk-jisyo t)
    (unwind-protect
        (progn
          (setq session (skk-ime-session-create))
          (skk-ime-session--with-buffer session
            ;; First-use skk-mode selects its default dictionary. Set the
            ;; isolated fixture search after initialization has completed.
            (setq-local skk-search-prog-list
                        '((skk-search-jisyo-file skk-jisyo 0 t)))
            (setq-local skk-current-search-prog-list nil)
            (let ((skk-henkan-key "かな") (skk-henkan-okurigana nil)
                  (skk-okuri-char nil))
              (should (equal (skk-search-jisyo-file skk-jisyo 0 t)
                             '("仮名" "哉" "金" "加奈" "佳奈" "香奈"))))
            (insert "蚊消える"))
          (let ((state (skk-ime-session-feed-string session "KanaQ")))
            (should (equal (plist-get state :text) "蚊消えるかな▽"))
            (should (eq (plist-get state :mode) 'preedit))
            (should (= (plist-get state :composition-start) 7))
            (live-input--log-stock-state "Q" state))
          (let ((state (skk-ime-session-control session 'commit)))
            (should (equal (plist-get state :text) "蚊消えるかな"))
            (should (eq (plist-get state :mode) 'hiragana))
            (live-input--log-stock-state "Q then Enter" state))
          (let ((state (skk-ime-session-feed-string session "Kanaq")))
            (should (equal (plist-get state :text) "蚊消えるかなカナ"))
            (should (eq (plist-get state :mode) 'hiragana))
            (live-input--log-stock-state "q" state))
          (skk-ime-session-feed-string session "Kana     ")
          (let ((state (skk-ime-session-control session 'commit)))
            (should (equal (plist-get state :text) "蚊消えるかなカナ佳奈"))
            (live-input--log-stock-state "candidate five" state))
          (let ((state (skk-ime-session-feed-string session "Kana ")))
            (should (equal (plist-get state :text) "蚊消えるかなカナ佳奈▼佳奈"))
            (live-input--log-stock-state "learned candidate" state))
          (let ((state (skk-ime-session-control session 'quit)))
            (should (equal (plist-get state :text) "蚊消えるかなカナ佳奈▽かな"))
            (live-input--log-stock-state "cancelled candidate" state)))
      (when session (skk-ime-session-destroy session))
      (let ((buffer (get-buffer (concat " *" (file-name-nondirectory skk-jisyo) "*"))))
        (when buffer (kill-buffer buffer)))
      (delete-file skk-jisyo))))
