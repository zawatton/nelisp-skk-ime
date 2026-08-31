;;; gen-rule-tree.el --- regenerate engine/skk-rule-tree-cache.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 nelisp-skk-ime contributors
;;
;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied
;; warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
;; PURPOSE.  See the GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; `skk-compile-rule-list' turns two constant rule lists into the romaji
;; tree, and on standalone NeLisp that costs ~1.7-2.3s -- the largest
;; single item left on the path the TSF host's first keystroke has to
;; walk (docs/design/201 in the nelisp tree, §6.8).  The inputs do not
;; change between runs, so the result is generated here once and loaded as
;; data instead: measured 1.738s to build, 0.008s to load, and the two
;; trees compare `equal'.
;;
;; Run it from this repository's root:
;;
;;   ../nelisp/target/nelisp.exe --load engine/gen-rule-tree.el
;;
;; and commit the `engine/skk-rule-tree-cache.el' it writes.  Regenerate
;; whenever `skk-rom-kana-base-rule-list' or `skk-rom-kana-rule-list'
;; changes -- though you do not have to remember to: the cache carries
;; `sxhash-equal' of both lists and `ddskk-engine--rule-tree' checks them
;; before using it, falling back to computing the tree when they differ.
;; A stale cache therefore costs the time it was meant to save, never a
;; wrong answer.

;;; Code:

(load "engine/ddskk-engine.el")

(let* ((tree (skk-compile-rule-list skk-rom-kana-base-rule-list
                                    skk-rom-kana-rule-list))
       (out "engine/skk-rule-tree-cache.el")
       (text (concat
              ";;; skk-rule-tree-cache.el --- GENERATED, do not edit"
              "  -*- lexical-binding: t; -*-\n"
              ";;\n"
              ";; Regenerate with:\n"
              ";;   ../nelisp/target/nelisp.exe --load engine/gen-rule-tree.el\n"
              ";; The signatures below are `sxhash-equal' of the two rule\n"
              ";; lists this tree was built from; `ddskk-engine--rule-tree'\n"
              ";; recomputes rather than trust a cache whose inputs moved.\n"
              "\n(setq ddskk-engine--rule-tree-cache\n      (list :base-hash "
              (number-to-string (sxhash-equal skk-rom-kana-base-rule-list))
              "\n            :extra-hash "
              (number-to-string (sxhash-equal skk-rom-kana-rule-list))
              "\n            :tree '"
              (prin1-to-string tree)
              "))\n")))
  (nl-write-file out text)
  (princ (format "wrote %s (%d bytes)\n" out (length text))))

;;; gen-rule-tree.el ends here
