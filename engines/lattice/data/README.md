# Bundled dictionary

`SKK-JISYO.M` defines the medium dictionary footprint; `SKK-JISYO.S` is
retained as a smaller option. Both EUC-JP dictionaries come from
[skk-dev/dict](https://github.com/skk-dev/dict), with license notices intact.
The original large SKK dictionary supplies richer genuine candidates.

Regenerate from the repository root using the recipe also recorded beside
`generate-skk-data.el`. Save the HEAD portable dictionary before writing:

```sh
git show HEAD:engines/lattice/data/nelisp-ime-dictionary-data.el > before.el
NELISP_IME_SKK_INPUT=engines/lattice/data/SKK-JISYO.M \
NELISP_IME_SKK_OUTPUT=engines/lattice/data/nelisp-ime-dictionary-data.el \
NELISP_IME_SKK_RANKING=/path/to/SKK-JISYO.L \
NELISP_IME_SKK_RANKING_DATA=before.el \
NELISP_IME_VERB_CLASSES=/path/to/ipadic/Verb.csv \
emacs -Q --batch -L framework/src -L engines/lattice/src \
  -l engines/lattice/data/generate-skk-data.el
```

`NELISP_IME_SKK_CODING` and `NELISP_IME_SKK_RANKING_CODING` override the
EUC-JP source codings. IPAdic Verb.csv and its sibling Adj.csv/Adverb.csv/Noun*.csv/Suffix.csv are EUC-JP
and used only for generation-time class attestation; costs are not read.
The IPAdic license is retained in `IPADIC-COPYING`. Runtime and bundled-data
ERT tests require no MeCab installation.

The portable reference supplies ordering only. A reference candidate can
survive only if the raw SKK sources and IPAdic attestation admit it. Verb
spelling, reading, and class must match; ambiguous classes generate nothing.
Non-verb row expansions require IPAdic spelling/reading attestation. An
adjective must match the spelling and reading of a basic form of 形容詞・アウオ段,
形容詞・イ段 or 形容詞・イイ. Every attested adjective entry generates the complete paradigm:
い, く, くない, かった, くて, ければ, さ, そう, regardless of its okuri code.
Identical trailing kana may be omitted from the SKK spelling and reading:
おおk /大/ matches 大きい/おおきい and retains き in every generated form.
Pairs are deduplicated, and forms retain SKK candidate order. Adjective
そう is not a verb volitional. Attested adjective paradigms from the large
source also add their readings outside the old medium row footprint.
Other row suffixes are not adjective forms. Attested na-adjective stems
also admit そう; noun/adverb row forms require an exact full surface/reading
match. This retains 賄い without admitting bare verb onbin stems such as
聞い, 咲い and 弄い. No IPAdic costs are read.

Valid legacy expansions retain their HEAD placement ahead of genuine words;
newly attested forms retain the append-after-existing behavior used for
ichidan additions. Among competing legacy entries, the code matching the
first generated okurigana kana wins; SKK candidate order remains stable.
Generated volitionals follow genuine okuri-nasi words. Dictionary-form う
is distinguished from a volitional: 囲う is still a dictionary-form verb.
Learning can promote any candidate at runtime.

The ranking SKK source has SHA-256
`aae6e2e4cb178de68afe706f053723a6d061d97bed7978008892eedd11c72ca6`.
