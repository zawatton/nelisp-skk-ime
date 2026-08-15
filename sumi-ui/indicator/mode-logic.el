;; mode-logic.el --- SKK mode-indicator decision logic (NeLisp AOT, object mode).
;;
;; A NeLisp AOT source module in the same restricted dialect as
;; dev/nelisp-sumi/src/*.el: a `seq' of `defun' forms, compiled with
;; `nelisp-aot-compile-to-object' (see sumi-ui/build.el) directly to a
;; COFF `.o' and linked into indicator/main.c's executable.  Every
;; function here is a pure, side-effect-free integer function -- no
;; `extern-call', no pointers, no strings -- so it stays inside the
;; parts of the dialect object-mode compilation is known to support
;; (see nelisp/lisp/nelisp-aot-compiler.el's `:object-mode-no-strings'
;; gate, which this module never touches because it never references a
;; string literal).
;;
;; Division of labour with main.c (per docs/design/sumi-indicator-
;; settings.md and the Phase 2 task brief): main.c owns I/O (named-pipe
;; transactions, GTK/cairo rendering primitives) and reduces the wire
;; reply's mode token to a small integer via plain C `strcmp'; this
;; module owns the *decisions* -- mode -> color, mode -> label, whether
;; the mode-switch menu should be offered, and which key code a menu
;; selection sends -- so the CorvusSKK-style behaviour table lives in
;; one auditable place instead of scattered through C.
;;
;; Mode encoding (MODE arg, shared with main.c's `SkkMode' enum):
;;   0 hiragana   1 katakana   2 wide-latin   3 latin
;;   4 preedit    5 candidate  6 abbrev       7 unreachable/ERR
;; (engine/skk-ime-session.el's `skk-ime-session-snapshot' is the
;; source of truth for the wire strings "hiragana"/"katakana"/
;; "wide-latin"/"latin"/"abbrev"/"preedit"/"candidate"; 7 is main.c's
;; own bucket for a dead pipe, a non-"STATE " reply, or any token this
;; module doesn't recognize.)
;;
;; PREVIOUS_BASE is main.c's most recently observed *base* mode (0/1/
;; 2/3/6 -- never 4/5/7): preedit/candidate are compositions in
;; progress, not modes of their own, so the CorvusSKK-modeled spec
;; (task brief step 3) says to keep showing whichever base mode was
;; active before the composition started rather than inventing a
;; preedit/candidate color.  main.c is responsible for only updating
;; its stored previous-base value when a fresh STATUS reply's mode is
;; itself a base mode; this module just consumes whatever it is given.
(seq

 ;; The four spec'd colors (docs/design/sumi-indicator-settings.md's
 ;; "Tab 表示" registry defaults, echoed verbatim in the task brief) plus
 ;; two MVP fallbacks: abbrev has no assigned color yet in that table
 ;; (`ModeColorAbbrev' default is literally "--"/TBD), and 7
 ;; (unreachable/ERR) is the brief's own #808080 "――" bucket. Reusing
 ;; #808080 for both keeps the palette to what is actually spec'd
 ;; today rather than inventing a seventh color no design doc asked
 ;; for; sumi-ui/README.md calls this out as a Phase 3 follow-up once
 ;; ModeColorAbbrev gets a real default.
 (defun skkui_base_color (m)
   (cond
    ((= m 0) #xC02020)  ; hiragana - red
    ((= m 1) #x00C000)  ; katakana - green
    ((= m 2) #x8000C0)  ; wide-latin - purple
    ((= m 3) #x1E5AA8)  ; latin - blue
    (t #x808080)))       ; abbrev (6) or anything else - gray

 ;; Label codes main.c maps to glyphs: 0=あ 1=ア 2=Ａ 3=SKK 4=―― 5=Ab.
 (defun skkui_base_label (m)
   (cond
    ((= m 0) 0)
    ((= m 1) 1)
    ((= m 2) 2)
    ((= m 3) 3)
    ((= m 6) 5)
    (t 4)))

 ;; preedit(4)/candidate(5) resolve to whatever base mode was active
 ;; before the composition started; every other mode (including 7,
 ;; unreachable/ERR, which is never a "previous base") resolves to
 ;; itself. Two thin wrappers around the base tables above rather than
 ;; one self-recursive function: object-mode compilation only supports
 ;; calling a *previously* defun'd function (see
 ;; nelisp-aot-compiler.el's "(NAME ARG...) -> call previously-defun'd
 ;; function"), so a defun calling itself is avoided on principle here.
 (defun skkui_color_for (mode previous_base)
   (if (or (= mode 4) (= mode 5))
       (skkui_base_color previous_base)
     (skkui_base_color mode)))

 (defun skkui_label_for (mode previous_base)
   (if (or (= mode 4) (= mode 5))
       (skkui_base_label previous_base)
     (skkui_base_label mode)))

 ;; Composition marker main.c draws next to the label: 0 none, 1 ▽
 ;; (preedit), 2 ▼ (candidate). Task brief step 3's "add a small ▽/▼
 ;; marker if easy" -- cairo_show_text makes it easy (real C, no FFI
 ;; double-marshaling gap), so it is wired rather than skipped.
 (defun skkui_composing_marker (mode)
   (cond
    ((= mode 4) 1)
    ((= mode 5) 2)
    (t 0)))

 ;; Menu policy (task brief step 4 / design doc's "Mode switching from
 ;; the indicator" table): the menu is a no-op while a composition is
 ;; in progress, same guard ToggleInputMode() uses in the DLL
 ;; (dev/nelisp-skk-ime/windows/src/text_service.cpp) and the design
 ;; doc's "Mode switching from the indicator" section documents
 ;; explicitly. Returns 1 (offer the menu) or 0 (suppress it).
 (defun skkui_menu_visible (mode)
   (if (or (= mode 4) (= mode 5)) 0 1))

 ;; Item order is fixed: 0=かな 1=カタカナ 2=全英 3=SKK, matching the
 ;; design doc's mode-switch table column order exactly. Every item
 ;; sends `CONTROL CANCEL' first (main.c always does that unconditionally
 ;; before consulting this table); the return value here is the
 ;; *optional* follow-up KEY code -- 0 means "CONTROL CANCEL alone is
 ;; enough" (the かな item), a positive value is the codepoint main.c
 ;; sends as `KEY <n>' right after. -1 is an out-of-range sentinel
 ;; main.c treats as "do nothing" defensively; it should never occur
 ;; since main.c only ever calls this with item indices 0..3.
 (defun skkui_menu_item_keycode (item)
   (cond
    ((= item 0) 0)     ; かな:  CONTROL CANCEL only (Ctrl+J)
    ((= item 1) 113)   ; カタカナ: + KEY 113 ("q")
    ((= item 2) 76)    ; 全英:  + KEY 76  ("L")
    ((= item 3) 108)   ; SKK:   + KEY 108 ("l")
    (t -1))))
