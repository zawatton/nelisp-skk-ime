;;; test-replay-equivalence.el --- Full replay state oracle -*- lexical-binding: t; -*-
;; Run after ddskk-engine.el; caller must supply a private DDSKK_USER_JISYO.
(defun ddskk-engine--server-request (midasi)
  "Read-only public fixture oracle; no live dictionary/server access."
  (or (cdr (assoc midasi '(("かな" . "1/仮名/哉/金/加奈/佳奈/香奈/")
                           ("か" . "1/蚊/")
                           ("きえr" . "1/消え/[る/消え/]/")))) "4"))
;; Independent round-1 checkpoint implementation. Keep this oracle in the
;; test so it cannot silently skip comparisons on a fresh build directory.
(defun skk-ime-session--capture-reference ()
  (let (state)
    (dolist (symbol skk-ime-session--native-state-symbols (nreverse state))
      (when (boundp symbol)
        (let ((value (symbol-value symbol)))
          (push (cons symbol
                      (if (markerp value)
                          (cons 'skk-ime-session--marker (marker-position value))
                        value))
                state))))))

(defun ddskk-replay--check-capture ()
  (unless (equal (skk-ime-session--capture-native-state)
                 (skk-ime-session--capture-reference))
    (error "Generated checkpoint differs from round-1 capture")))
(let ((keys-list '("" "a" "ai" "Kana" "Kanji" "Nihon" "Ka" "KaKu" "YoMu"
                   "KieRu" "tya" "tyu" "tyo" "tta" "nn" "n'" "nka"
                   "z." "z/" "z0" "z*" "zL" "Kanaq" "qKanaq" "KanaQ"
                   "Kanal" "KanaL" "/abc" "lABC" "Labc" "Qkana" "Kana "
                   "Kana\b" "Kana\177" "Ka1" "Ka!" "abc😀" "Kana\r"))
      (checks 0))
  (ddskk-engine-start)
  (dolist (keys keys-list)
    (skk-ime-session-reset ddskk-engine--session)
    (let ((initial (skk-ime-session-checkpoint ddskk-engine--session))
          reference-error actual-error)
      (condition-case err
          (dolist (key (string-to-list keys))
            (skk-ime-session-feed-key ddskk-engine--session key)
            )
        (error (setq reference-error (car err))))
      (let ((reference (skk-ime-session-checkpoint ddskk-engine--session))
            (state (skk-ime-session-snapshot ddskk-engine--session)))
	(ddskk-replay--check-capture)
	(skk-ime-session-restore ddskk-engine--session initial)
	(progn
          (condition-case err
              (skk-ime-session-feed-string ddskk-engine--session keys)
            (error (setq actual-error (car err))))
          (unless (eq reference-error actual-error)
            (error "Replay error differs: %S" keys))
          (ddskk-replay--check-capture)
          (unless (equal reference (skk-ime-session-checkpoint ddskk-engine--session))
            (let ((actual (skk-ime-session-checkpoint ddskk-engine--session)))
              (dolist (entry (plist-get reference :native-state))
                (unless (equal (cdr entry) (cdr (assq (car entry) (plist-get actual :native-state))))
                  (nelisp--write-stdout-bytes
                   (concat "DIFFER " (symbol-name (car entry)) " "
                           (prin1-to-string (cdr entry)) " -> "
                           (prin1-to-string (cdr (assq (car entry) (plist-get actual :native-state)))) "\n")))))
            (error "Replay checkpoint differs: %S" keys))
          (unless (equal state (skk-ime-session-snapshot ddskk-engine--session))
            (error "Replay snapshot differs: %S" keys))
          (setq checks (1+ checks))))))
  (nelisp--write-stdout-bytes
   (concat "Replay full checkpoint/snapshot: " (number-to-string checks)
           "/" (number-to-string (length keys-list)) " sequences PASS\n")))
(skk-ime-session--with-buffer ddskk-engine--session
			      (let ((saved (and (boundp 'skk-echo) skk-echo))
				    (was-bound (boundp 'skk-echo))
				    (previous skk-previous-point))
				(unwind-protect
				    (progn
				      (makunbound 'skk-echo)
				      (ddskk-replay--check-capture)
				      (setq skk-previous-point (copy-marker 1))
				      (ddskk-replay--check-capture))
				  (setq skk-previous-point previous)
				  (if was-bound (setq skk-echo saved) (makunbound 'skk-echo)))))
(nelisp--write-stdout-bytes "Checkpoint unbound/marker parity: 2 checks PASS\n")
