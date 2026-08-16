# Bundled dictionary

`SKK-JISYO.M` is the medium dictionary used by default. `SKK-JISYO.S` is kept
as a reduced-footprint option. Both are distributed by the official
[skk-dev/dict](https://github.com/skk-dev/dict) project. Its copyright and
license notice is retained in each file. The sources are EUC-JP. The medium
dictionary was selected because it converts common phrases correctly while
remaining practical for the current standalone NeLisp loader; the large
dictionary currently exceeds its comfortable startup footprint.

`nelisp-ime-dictionary-data.el` is the generated UTF-8 representation loaded
by standalone NeLisp. Regenerate it from the repository root with:

```sh
emacs --batch -Q -L ../nelisp-ime/packages/nelisp-ime/src -L src \
  -l data/generate-skk-data.el
```

A larger SKK dictionary can be converted by setting `NELISP_IME_SKK_INPUT`
and `NELISP_IME_SKK_OUTPUT`. The checked-in generated dictionary uses the
medium dictionary as its entry set and the official large dictionary for
candidate ordering:

```sh
NELISP_IME_SKK_RANKING=/path/to/SKK-JISYO.L \
  emacs --batch -Q -L ../nelisp-ime/packages/nelisp-ime/src -L src \
  -l data/generate-skk-data.el
```

The ranking source used for the checked-in artifact was official
`SKK-JISYO.L` with SHA-256
`c791f578d1b4040fce282db29bc22b2cc7ea46f83e269fab2e0fa779e2967e40`.

Okuri-ari entries are expanded into conservative common conjugations during
generation, so the runtime does not need an external morphological process.
