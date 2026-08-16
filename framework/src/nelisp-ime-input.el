;;; nelisp-ime-input.el --- Portable Japanese key normalization  -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Converts platform-neutral physical key codes or roman letters to kana.
;; Native adapters are responsible only for mapping native scan codes to the
;; code names used here.

;;; Code:

(defconst nelisp-ime-jis-kana-map
  '(("Digit1" . "ぬ") ("Digit2" . "ふ") ("Digit3" . "あ")
    ("Digit4" . "う") ("Digit5" . "え") ("Digit6" . "お")
    ("Digit7" . "や") ("Digit8" . "ゆ") ("Digit9" . "よ")
    ("Digit0" . "わ") ("Minus" . "ほ") ("Equal" . "へ")
    ("KeyQ" . "た") ("KeyW" . "て") ("KeyE" . "い")
    ("KeyR" . "す") ("KeyT" . "か") ("KeyY" . "ん")
    ("KeyU" . "な") ("KeyI" . "に") ("KeyO" . "ら")
    ("KeyP" . "せ") ("BracketLeft" . "゛")
    ("BracketRight" . "゜") ("KeyA" . "ち") ("KeyS" . "と")
    ("KeyD" . "し") ("KeyF" . "は") ("KeyG" . "き")
    ("KeyH" . "く") ("KeyJ" . "ま") ("KeyK" . "の")
    ("KeyL" . "り") ("Semicolon" . "れ") ("Quote" . "け")
    ("KeyZ" . "つ") ("KeyX" . "さ") ("KeyC" . "そ")
    ("KeyV" . "ひ") ("KeyB" . "こ") ("KeyN" . "み")
    ("KeyM" . "も") ("Comma" . "ね") ("Period" . "る")
    ("Slash" . "め") ("Backslash" . "む")
    ("IntlYen" . "ー") ("IntlRo" . "ろ"))
  "JIS X 6002 kana labels keyed by portable physical key code.")

(defconst nelisp-ime-jis-kana-shift-map
  '(("Digit3" . "ぁ") ("Digit4" . "ぅ") ("Digit5" . "ぇ")
    ("Digit6" . "ぉ") ("Digit7" . "ゃ") ("Digit8" . "ゅ")
    ("Digit9" . "ょ") ("Digit0" . "を") ("KeyE" . "ぃ")
    ("KeyZ" . "っ") ("BracketLeft" . "「")
    ("BracketRight" . "」") ("Comma" . "、")
    ("Period" . "。") ("Slash" . "・"))
  "Shifted JIS kana labels that differ from the unshifted map.")

(defconst nelisp-ime-dakuten-map
  '((?う . ?ゔ) (?か . ?が) (?き . ?ぎ) (?く . ?ぐ) (?け . ?げ)
    (?こ . ?ご) (?さ . ?ざ) (?し . ?じ) (?す . ?ず) (?せ . ?ぜ)
    (?そ . ?ぞ) (?た . ?だ) (?ち . ?ぢ) (?つ . ?づ) (?て . ?で)
    (?と . ?ど) (?は . ?ば) (?ひ . ?び) (?ふ . ?ぶ) (?へ . ?べ)
    (?ほ . ?ぼ))
  "Precomposed voiced kana mapping.")

(defconst nelisp-ime-handakuten-map
  '((?は . ?ぱ) (?ひ . ?ぴ) (?ふ . ?ぷ) (?へ . ?ぺ) (?ほ . ?ぽ))
  "Precomposed semi-voiced kana mapping.")

(defconst nelisp-ime-romaji-map
  '(("a" . "あ") ("i" . "い") ("u" . "う") ("e" . "え") ("o" . "お")
    ("ka" . "か") ("ki" . "き") ("ku" . "く") ("ke" . "け") ("ko" . "こ")
    ("kya" . "きゃ") ("kyu" . "きゅ") ("kyo" . "きょ")
    ("sa" . "さ") ("shi" . "し") ("si" . "し") ("su" . "す")
    ("se" . "せ") ("so" . "そ") ("sha" . "しゃ") ("shu" . "しゅ")
    ("sho" . "しょ") ("sya" . "しゃ") ("syu" . "しゅ") ("syo" . "しょ")
    ("ta" . "た") ("chi" . "ち") ("ti" . "ち") ("tsu" . "つ")
    ("tu" . "つ") ("te" . "て") ("to" . "と")
    ("cha" . "ちゃ") ("chu" . "ちゅ") ("cho" . "ちょ")
    ("na" . "な") ("ni" . "に") ("nu" . "ぬ") ("ne" . "ね") ("no" . "の")
    ("nya" . "にゃ") ("nyu" . "にゅ") ("nyo" . "にょ")
    ("ha" . "は") ("hi" . "ひ") ("fu" . "ふ") ("hu" . "ふ")
    ("he" . "へ") ("ho" . "ほ") ("hya" . "ひゃ") ("hyu" . "ひゅ")
    ("hyo" . "ひょ") ("ma" . "ま") ("mi" . "み") ("mu" . "む")
    ("me" . "め") ("mo" . "も") ("mya" . "みゃ") ("myu" . "みゅ")
    ("myo" . "みょ") ("ya" . "や") ("yu" . "ゆ") ("yo" . "よ")
    ("ra" . "ら") ("ri" . "り") ("ru" . "る") ("re" . "れ") ("ro" . "ろ")
    ("rya" . "りゃ") ("ryu" . "りゅ") ("ryo" . "りょ")
    ("wa" . "わ") ("wo" . "を")
    ("ga" . "が") ("gi" . "ぎ") ("gu" . "ぐ") ("ge" . "げ") ("go" . "ご")
    ("gya" . "ぎゃ") ("gyu" . "ぎゅ") ("gyo" . "ぎょ")
    ("za" . "ざ") ("ji" . "じ") ("zi" . "じ") ("zu" . "ず")
    ("ze" . "ぜ") ("zo" . "ぞ") ("ja" . "じゃ") ("ju" . "じゅ")
    ("jo" . "じょ") ("da" . "だ") ("di" . "ぢ") ("du" . "づ")
    ("de" . "で") ("do" . "ど") ("ba" . "ば") ("bi" . "び")
    ("bu" . "ぶ") ("be" . "べ") ("bo" . "ぼ")
    ("bya" . "びゃ") ("byu" . "びゅ") ("byo" . "びょ")
    ("pa" . "ぱ") ("pi" . "ぴ") ("pu" . "ぷ") ("pe" . "ぺ") ("po" . "ぽ")
    ("pya" . "ぴゃ") ("pyu" . "ぴゅ") ("pyo" . "ぴょ")
    ("fa" . "ふぁ") ("fi" . "ふぃ") ("fe" . "ふぇ") ("fo" . "ふぉ")
    ("va" . "ゔぁ") ("vi" . "ゔぃ") ("vu" . "ゔ") ("ve" . "ゔぇ")
    ("vo" . "ゔぉ") ("xa" . "ぁ") ("xi" . "ぃ") ("xu" . "ぅ")
    ("xe" . "ぇ") ("xo" . "ぉ") ("xya" . "ゃ") ("xyu" . "ゅ")
    ("xyo" . "ょ") ("xtu" . "っ") ("ltsu" . "っ") ("nn" . "ん")
    ("n'" . "ん"))
  "Common Hepburn and Kunrei romanization sequences.")

(defun nelisp-ime--apply-mark (reading mark)
  "Apply dakuten or handakuten MARK to the end of READING."
  (if (= (length reading) 0)
      mark
    (let* ((last (aref reading (1- (length reading))))
           (table (if (equal mark "゛") nelisp-ime-dakuten-map
                    nelisp-ime-handakuten-map))
           (replacement (cdr (assq last table))))
      (if replacement
          (concat (substring reading 0 (1- (length reading)))
                  (char-to-string replacement))
        (concat reading mark)))))

(defun nelisp-ime-jis-kana-key (code shift)
  "Return kana for physical key CODE, using SHIFT variant when present."
  (or (and shift (cdr (assoc code nelisp-ime-jis-kana-shift-map)))
      (cdr (assoc code nelisp-ime-jis-kana-map))))

(defun nelisp-ime--romaji-prefix-p (pending)
  "Return non-nil when PENDING begins at least one romanization rule."
  (let ((rules nelisp-ime-romaji-map)
        found)
    (while (and rules (not found))
      (when (string-prefix-p pending (caar rules)) (setq found t))
      (setq rules (cdr rules)))
    found))

(defun nelisp-ime-romaji-step (pending key)
  "Consume roman KEY after PENDING and return (:text TEXT :pending REST)."
  (let ((next (concat pending (downcase key)))
        emitted)
    (when (and (= (length next) 2)
               (= (aref next 0) (aref next 1))
               (not (memq (aref next 0) '(?a ?i ?u ?e ?o ?n))))
      (setq emitted "っ"
            next (substring next 1)))
    (let ((exact (cdr (assoc next nelisp-ime-romaji-map))))
      (cond
       ((and exact (not (nelisp-ime--romaji-prefix-p
                         (concat next "a"))))
        (list :text (concat emitted exact) :pending ""))
       (exact
        ;; Only `n' style ambiguous rules should wait; current exact multi-key
        ;; rules are terminal despite potentially sharing a synthetic prefix.
        (list :text (concat emitted exact) :pending ""))
       ((nelisp-ime--romaji-prefix-p next)
        (list :text emitted :pending next))
       ((and (> (length next) 1) (= (aref next 0) ?n))
        (let ((tail (nelisp-ime-romaji-step "" (substring next 1))))
          (list :text (concat emitted "ん" (plist-get tail :text))
                :pending (plist-get tail :pending))))
       (t (list :text (concat emitted (substring next 0 1))
                :pending (substring next 1)))))))

(defun nelisp-ime-romaji-flush (pending)
  "Return text used when an incomplete romanization PENDING is committed."
  (if (equal pending "n") "ん" pending))

(provide 'nelisp-ime-input)
;;; nelisp-ime-input.el ends here
