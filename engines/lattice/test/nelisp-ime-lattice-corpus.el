;;; nelisp-ime-lattice-corpus.el --- Controlled conversion regression corpus  -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Each case supplies a deliberately small dictionary and its current expected
;; best conversion.  This isolates the converter from changes in the bundled
;; SKK data while giving future scoring work a stable quality baseline.
;;
;; The corpus does not claim that a rank-only dictionary engine can resolve
;; semantic homophones from context.  Such cases are included only when their
;; expected result is determined by the supplied lexical costs; contextual
;; disambiguation belongs to the later connection-cost milestone.

;;; Code:

(defconst nelisp-ime-lattice-regression-corpus
  '((:name simple-particle
     :reading "きょうは"
     :dictionary (("きょう" (:surface "今日" :cost 80))
                  ("は" (:surface "は" :cost 10))
                  ("きょうは" (:surface "教派" :cost 500)))
     :preedit "今日は"
     :segments ("きょう" "は"))
    (:name lexical-homophone-ranking
     :reading "はしをわたる"
     :dictionary (("はし" (:surface "橋" :cost 30)
                          (:surface "箸" :cost 100))
                  ("を" (:surface "を" :cost 10))
                  ("わたる" (:surface "渡る" :cost 20)))
     :preedit "橋を渡る"
     :segments ("はし" "を" "わたる")
     :first-candidates ("橋" "箸"))
    (:name compound-beats-shorter-path
     :reading "きょうと"
     :dictionary (("きょう" (:surface "今日" :cost 100))
                  ("と" (:surface "と" :cost 100))
                  ("きょうと" (:surface "京都" :cost 20)))
     :preedit "京都"
     :segments ("きょうと"))
    (:name proper-noun-compound
     :reading "とうきょうと"
     :dictionary (("とうきょう" (:surface "東京" :cost 100))
                  ("と" (:surface "と" :cost 100))
                  ("とうきょうと" (:surface "東京都" :cost 20)))
     :preedit "東京都"
     :segments ("とうきょうと"))
    (:name common-noun
     :reading "にほんご"
     :dictionary (("にほん" (:surface "日本" :cost 100))
                  ("ご" (:surface "語" :cost 100))
                  ("にほんご" (:surface "日本語" :cost 20)))
     :preedit "日本語"
     :segments ("にほんご"))
    (:name polite-sentence
     :reading "ねこです"
     :dictionary (("ねこ" (:surface "猫" :cost 20))
                  ("です" (:surface "です" :cost 10)))
     :preedit "猫です"
     :segments ("ねこ" "です"))
    (:name inspection-domain-phrase
     :reading "でんきのてんけん"
     :dictionary (("でんき" (:surface "電気" :cost 20)
                           (:surface "電器" :cost 100))
                  ("の" (:surface "の" :cost 10))
                  ("てんけん" (:surface "点検" :cost 20)))
     :preedit "電気の点検"
     :segments ("でんき" "の" "てんけん")
     :first-candidates ("電気" "電器"))
    (:name longer-domain-compound
     :reading "じゅでんせつび"
     :dictionary (("じゅでん" (:surface "充電" :cost 100))
                  ("せつび" (:surface "設備" :cost 100))
                  ("じゅでんせつび" (:surface "充電設備" :cost 20)))
     :preedit "充電設備"
     :segments ("じゅでんせつび"))
    (:name unknown-kana-fallback
     :reading "ねこですぞ"
     :dictionary (("ねこ" (:surface "猫" :cost 20))
                  ("です" (:surface "です" :cost 10)))
     :preedit "猫ですぞ"
     :segments ("ねこ" "です" "ぞ"))
    (:name all-unknown-kana-fallback
     :reading "あいう"
     :dictionary nil
     :preedit "あいう"
     :segments ("あ" "い" "う"))
    (:name lexical-cost-overrides-source-order
     :reading "こうしょう"
     :dictionary (("こうしょう" (:surface "高尚" :cost 200)
                            (:surface "交渉" :cost 20)))
     :preedit "交渉"
     :segments ("こうしょう")
     :first-candidates ("交渉" "高尚"))
    (:name connection-cost-overrides-lexical-cost
     :reading "あい"
     :dictionary (("あ" (:surface "亜" :cost 10 :right-id alpha)
                        (:surface "阿" :cost 20 :right-id beta))
                  ("い" (:surface "伊" :cost 10 :left-id terminal
                                      :right-id terminal)))
     :connection-costs ((alpha terminal 100) (beta terminal 0))
     :preedit "阿伊"
     :segments ("あ" "い"))
    (:name mixed-kanji-and-kana
     :reading "でんきをみる"
     :dictionary (("でんき" (:surface "電気" :cost 20))
                  ("を" (:surface "を" :cost 10))
                  ("みる" (:surface "見る" :cost 20)))
     :preedit "電気を見る"
     :segments ("でんき" "を" "みる")))
  "Controlled cases used to detect conversion regressions.

Each entry contains :reading, :dictionary, :preedit, and :segments.  Optional
:connection-costs supplies (RIGHT-ID LEFT-ID COST) entries; :first-candidates
asserts the candidate order for the first segment.")

(provide 'nelisp-ime-lattice-corpus)
;;; nelisp-ime-lattice-corpus.el ends here
