;;; nelisp-session-smoke.el --- Standalone NeLisp DDSKK smoke test -*- lexical-binding: t; -*-

;; Load order is explicit while standalone NeLisp's `require' remains a stub.
(load "../nelisp/src/nelisp-buffer.el")
(load "engine/skk-nelisp-compat.el")
(provide 'skk)
(load "vendor/ddskk/skk-vars.el")
(load "vendor/ddskk/skk-macs.el")
(load "vendor/ddskk/skk-emacs.el")

;; `skk-macs.el' defines this via `encode-coding-string' inside
;; `ignore-errors', which signals on this runtime and therefore silently
;; yields nil for every character.  `skk.el' builds all four minor-mode
;; keymaps at load time using this function, so the broken version would
;; bind every key to nil and make `lookup-key' useless.  Override it here,
;; after `skk-macs.el' has been loaded but before `skk.el' runs.
(defun skk-char-to-unibyte-string (char) (string char))

(load "vendor/ddskk/skk.el")
(load "engine/skk-ime-session.el")

;; Native hosts do not need Emacs keymaps, modelines, hooks, or cursor changes.
(defun skk-ime-session--initialize-native-buffer ()
  (setq skk-mode t
        skk-j-mode t
        skk-abbrev-mode nil
        skk-latin-mode nil
        skk-jisx0208-latin-mode nil
        skk-jisx0201-mode nil
        skk-katakana nil
        skk-echo nil
        skk-prefix ""
        skk-current-rule-tree nil
        skk-henkan-mode nil
        skk-henkan-start-point nil
        skk-henkan-end-point nil
        skk-kana-start-point nil
        skk-okurigana nil
        skk-insert-keysequence nil
        buffer-undo-list t
        overwrite-mode nil
        auto-fill-function nil
        current-prefix-arg nil)
  (unless skk-rule-tree
    (setq skk-rule-tree
          (skk-compile-rule-list skk-rom-kana-base-rule-list
                                 skk-rom-kana-rule-list))))

(defun ddskk-nelisp-smoke-assert (condition label state)
  (unless condition
    (error "DDSKK NeLisp smoke failed (%s): %S" label state)))

(let ((direct (skk-ime-session-create))
      (preedit (skk-ime-session-create))
      (reset (skk-ime-session-create))
      (pending (skk-ime-session-create)))
  (let ((state (skk-ime-session-feed-string direct "kana")))
    (ddskk-nelisp-smoke-assert
     (and (eq (plist-get state :mode) 'hiragana)
          (equal (plist-get state :text) "かな")
          (equal (plist-get state :pending-romaji) ""))
     "direct hiragana" state))
  (let ((state (skk-ime-session-feed-string preedit "Kana")))
    (ddskk-nelisp-smoke-assert
     (and (eq (plist-get state :mode) 'preedit)
          (equal (plist-get state :text) "▽かな")
          (= (plist-get state :composition-start) 1))
     "uppercase preedit" state))
  (skk-ime-session-feed-string reset "kana")
  (let ((state (skk-ime-session-reset reset)))
    (ddskk-nelisp-smoke-assert
     (and (eq (plist-get state :mode) 'hiragana)
          (equal (plist-get state :text) "")
          (= (plist-get state :cursor) 0))
     "reset" state))
  ;; Run the incomplete-rule case last: standalone NeLisp does not yet provide
  ;; true buffer-local variable cells, so an unfinished rule-tree state would
  ;; otherwise leak into the next test buffer.
  (skk-ime-session--with-buffer pending
    (skk-ime-session--initialize-native-buffer))
  (let ((state (skk-ime-session-feed-key pending ?n)))
    (ddskk-nelisp-smoke-assert
     (and (equal (plist-get state :text) "")
          (equal (plist-get state :pending-romaji) "n"))
     "pending romaji" state))
  (skk-ime-session-destroy direct)
  (ddskk-nelisp-smoke-assert
   (not (skk-ime-session-live-p direct)) "destroy" nil)
  'ddskk-nelisp-session-smoke-ok)
