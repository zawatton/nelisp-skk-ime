;;; test-registration-nested-oracle.el --- Vendored DDSKK oracle -*- lexical-binding: t; -*-
(setq native-comp-enable-subr-trampolines nil)
(require 'ert)
(require 'cl-lib)
(defvar rg1-oracle-home (make-temp-file "rg1-oracle-" t))
(setenv "HOME" rg1-oracle-home)
(setq user-emacs-directory (expand-file-name ".emacs.d/" rg1-oracle-home)
      skk-jisyo (expand-file-name "private.jisyo" rg1-oracle-home)
      skk-large-jisyo nil)
(make-directory user-emacs-directory t)
(require 'skk-ime-session)
(remove-hook 'kill-emacs-hook #'skk-save-jisyo)
(remove-hook 'kill-emacs-hook #'skk-record-jisyo-data)
(add-hook 'kill-emacs-hook (lambda () (delete-directory rg1-oracle-home t)))
(defun rg1-oracle-session ()
  (with-temp-file skk-jisyo
    (insert ";; okuri-ari entries.\nかk /書/\n;; okuri-nasi entries.\nあい /愛/\nぱぱぱ /既存/\n"))
  (let ((session (skk-ime-session-create)))
    (skk-ime-session--with-buffer session
      (setq-local skk-jisyo (expand-file-name "private.jisyo" rg1-oracle-home))
      (setq-local skk-jisyo-code 'utf-8)
      (setq-local skk-search-prog-list '((skk-search-jisyo-file skk-jisyo 0 t)))
      (setq-local skk-current-search-prog-list nil))
    session))
(ert-deftest rg1-stock-nested-ret-and-following-key ()
  ;; Exercise DDSKK's exit-minibuffer advice itself. Batch Emacs has no
  ;; active minibuffer; its primitive signals only AFTER the advice confirms.
  (dolist (keys '("Ai" "KaKu"))
    (dolist (following '(nil t))
      (let ((session (rg1-oracle-session)))
        (unwind-protect
            (progn
              (skk-ime-session-feed-string session "te")
              (skk-ime-session-feed-string session keys)
              (when (equal keys "Ai") (skk-ime-session-control session 'convert))
              (when following (skk-ime-session-feed-string session "suto"))
              (skk-ime-session--with-buffer session
                (let ((skk-egg-like-newline nil))
                  (condition-case nil (exit-minibuffer) (error nil))))
              (let ((state (skk-ime-session-snapshot session)))
                (should-not (plist-get state :composition-start))
                (should (equal (plist-get state :text)
                               (concat "て" (if (equal keys "Ai") "愛" "書く")
                                       (if following "すと" ""))))))
          (skk-ime-session-destroy session))))))
(ert-deftest rg1-stock-nested-cancel-levels ()
  (let ((session (rg1-oracle-session)))
    (unwind-protect
        (progn
          (skk-ime-session-feed-string session "teAi")
          (skk-ime-session-control session 'convert)
          (skk-ime-session--with-buffer session (abort-recursive-edit))
          (should (equal (plist-get (skk-ime-session-snapshot session) :text) "て▽あい"))
          (skk-ime-session--with-buffer session (abort-recursive-edit))
          (should (equal (plist-get (skk-ime-session-snapshot session) :text) "て"))
          (skk-ime-session-feed-string session "k")
          (skk-ime-session--with-buffer session (abort-recursive-edit))
          (should (equal (plist-get (skk-ime-session-snapshot session) :pending-romaji) "")))
      (skk-ime-session-destroy session))))
(ert-deftest rg1-stock-registration-miss-and-exhaustion ()
  (dolist (exhaust '(nil t))
    (let ((outer (rg1-oracle-session)) (entered nil))
      (unwind-protect
          (cl-letf (((symbol-function 'read-from-minibuffer)
                     (lambda (&rest _)
                       (setq entered t)
                       (let ((inner (rg1-oracle-session)))
                         (unwind-protect
                             (progn
                               (skk-ime-session-feed-string inner "teAi")
                               (skk-ime-session-control inner 'convert)
                               (skk-ime-session-feed-string inner "suto")
                               (plist-get (skk-ime-session-snapshot inner) :text))
                           (skk-ime-session-destroy inner))))))
            (skk-ime-session-feed-string outer (if exhaust "Papapa" "Papapi"))
            (skk-ime-session-control outer 'convert)
            (when exhaust (skk-ime-session-control outer 'convert))
            (should entered)
            (skk-ime-session-control outer 'commit)
            (should (equal (plist-get (skk-ime-session-snapshot outer) :text) "て愛すと")))
        (skk-ime-session-destroy outer)))))
(ert-deftest rg1-stock-outer-cancel ()
  (dolist (exhaust '(nil t))
    (let ((outer (rg1-oracle-session)))
      (unwind-protect
          (cl-letf (((symbol-function 'read-from-minibuffer)
                     (lambda (&rest _) (signal 'quit nil))))
            (skk-ime-session-feed-string outer (if exhaust "Papapa" "Papapi"))
            (skk-ime-session-control outer 'convert)
            (when exhaust (skk-ime-session-control outer 'convert))
            (let ((state (skk-ime-session-snapshot outer)))
              (message "STOCK OUTER CANCEL exhaust=%S state=%S" exhaust state)
              (should (equal (plist-get state :text) (if exhaust "▼既存" "▽ぱぱぴ")))))
        (skk-ime-session-destroy outer)))))
(ert-deftest rg1-stock-completed-registration-cancel ()
  "Completed kana is idle: first C-g exits registration, second clears outer reading."
  (let ((outer (rg1-oracle-session)) (exited nil))
    (unwind-protect
        (cl-letf (((symbol-function 'read-from-minibuffer)
                   (lambda (&rest _)
                     (let ((inner (rg1-oracle-session)))
                       (unwind-protect
                           (progn
                             (skk-ime-session-feed-string inner "te")
                             (skk-ime-session--with-buffer inner
                               (should-not skk-henkan-mode)
                               (should (equal skk-prefix ""))
                               ;; In batch, the primitive has no recursive
                               ;; edit to abort. Map its error to the quit
                               ;; that it raises in a real minibuffer AFTER
                               ;; executing the stock advice unchanged.
                               (condition-case nil (abort-recursive-edit)
                                 (error (setq exited t) (signal 'quit nil)))))
                         (skk-ime-session-destroy inner))))))
          (skk-ime-session-feed-string outer "Papapi")
          (skk-ime-session-control outer 'convert)
          (should exited)
          (should (equal (plist-get (skk-ime-session-snapshot outer) :text) "▽ぱぱぴ"))
          (skk-ime-session--with-buffer outer (keyboard-quit))
          (should (equal (plist-get (skk-ime-session-snapshot outer) :text) "")))
      (skk-ime-session-destroy outer))))

(ert-deftest rg1-stock-recursive-registration ()
  ;; Batch has no recursive command loop. Substitute only the input primitive;
  ;; every level still runs stock skk-henkan-in-minibuff and skk-kakutei.
  (dolist (exhaust '(nil t))
    (dolist (cancel '(nil t))
      (let ((buffer (get-buffer " *private.jisyo*")))
        (when buffer
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (let ((outer (rg1-oracle-session)) (rg1-depth 0) (maximum 0))
        (unwind-protect
            (cl-letf (((symbol-function 'minibuffer-depth) (lambda () rg1-depth))
                      ((symbol-function 'read-from-minibuffer)
                       (lambda (&rest _)
                         (let ((inner (rg1-oracle-session)))
                           (setq rg1-depth (1+ rg1-depth))
                           (setq maximum (max maximum rg1-depth))
                           (unwind-protect
                               (progn
                                 (skk-ime-session-feed-string inner
                                                             (if (= rg1-depth 1) "te" "su"))
                                 (when (< rg1-depth 3)
                                   (skk-ime-session-feed-string inner
                                                               (if exhaust "Papapa" "Pipipi"))
                                   (skk-ime-session-control inner 'convert)
                                   (when exhaust (skk-ime-session-control inner 'convert)))
                                 (when cancel (signal 'quit nil))
                                 (skk-ime-session-control inner 'commit)
                                 (plist-get (skk-ime-session-snapshot inner) :text))
                             (setq rg1-depth (1- rg1-depth))
                             (skk-ime-session-destroy inner))))))
              (skk-ime-session-feed-string outer (if exhaust "Papapa" "Pipipi"))
              (skk-ime-session-control outer 'convert)
              (when exhaust (skk-ime-session-control outer 'convert))
              (should (= maximum 3))
              (if cancel
                  (should (equal (plist-get (skk-ime-session-snapshot outer) :text)
                                 (if exhaust "▼既存" "▽ぴぴぴ")))
                (progn
                  (skk-ime-session-control outer 'commit)
                  (should (equal (plist-get (skk-ime-session-snapshot outer) :text)
                                 "てすす")))))
          (skk-ime-session-destroy outer))))))
