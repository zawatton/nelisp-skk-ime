;; mode-logic.el --- SKK mode-indicator decision logic (NeLisp AOT, object mode).
;;
;; A NeLisp AOT source module in the same restricted dialect as
;; dev/nelisp-sumi/src/*.el: a `seq' of `defun' forms, compiled with
;; `nelisp-aot-compile-to-object' (see sumi-ui/build.el) directly to a
;; COFF `.o' and linked into indicator/main.c's executable.  Every
;; function here is a pure, side-effect-free function -- no
;; `extern-call', no strings -- so it stays inside the parts of the
;; dialect object-mode compilation is known to support (see
;; nelisp/lisp/nelisp-aot-compiler.el's `:object-mode-no-strings' gate,
;; which this module never touches because it never references a
;; string literal). `skkui_base_color_configured'/`skkui_color_for_configured'
;; use `ptr-read-u64' (Phase 3) -- the same primitive
;; dev/nelisp-sumi/src/nelisp-sumi-move.el's `nsum_move_note' etc.
;; already exercise in object-mode-compiled code -- to read a caller-
;; owned array rather than take 5+ separate color arguments: Win64 COFF
;; object-mode functions are called with the real Win64 ABI (4 GP
;; argument registers, not SysV's 6), and every function below stays at
;; 2-3 params specifically to avoid depending on 5+-argument stack-
;; argument support this module never needed to test.
;;
;; Division of labour with main.c (per docs/design/sumi-indicator-
;; settings.md and the Phase 2/3 task briefs): main.c owns I/O (named-
;; pipe transactions, registry reads, GTK/cairo rendering primitives)
;; and reduces the wire reply's mode token to a small integer via plain
;; C `strcmp'; this module owns the *decisions* -- mode -> color, mode
;; -> label, whether the mode-switch menu should be offered, and which
;; key code a menu selection sends -- so the CorvusSKK-style behaviour
;; table lives in one auditable place instead of scattered through C.
;; Phase 3 extends this without moving any decision into C: main.c now
;; reads the five configurable colors from the registry (or the same
;; design-doc defaults, when a value is absent -- see settings.c), but
;; this module still decides *which* of those colors applies to a given
;; MODE/PREVIOUS_BASE pair, exactly as it decided among the hardcoded
;; Phase 2 constants before.
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
;;
;; COLORS_PTR (new in Phase 3) points at a caller-owned, 7-slot,
;; 8-byte-per-slot (56-byte) array of packed 0xRRGGBB values that main.c
;; fills in from the current Settings (registry values, or the design-
;; doc default for any value absent from the registry -- see
;; settings.c's settings_defaults()). Only slots 0/1/2/3/6 (hiragana/
;; katakana/wide-latin/latin/abbrev -- the five registry-configurable
;; colors: ModeColorKana/Katakana/WideLatin/Latin/Abbrev) are ever read;
;; slots 4/5/7 exist only so the array can be indexed directly by MODE/
;; PREVIOUS_BASE without a remapping step, and main.c never has to
;; populate them. Mode 7 (unreachable/ERR) is deliberately NOT
;; configurable -- there is no ModeColorUnreachable in the design doc's
;; schema table -- so it keeps the Phase 2 hardcoded #808080 rather
;; than reading slot 7.
(seq

 ;; Reads COLORS_PTR[M] (an 8-byte-per-slot array; see the COLORS_PTR
 ;; paragraph above) for the four registry-configurable base colors
 ;; plus abbrev, falling back to the Phase 2 #808080 gray for mode 7
 ;; (unreachable/ERR -- never configurable, see above) or any other
 ;; unrecognized value.
 (defun skkui_base_color_configured (m colors_ptr)
   (cond
    ((= m 0) (ptr-read-u64 colors_ptr 0))    ; hiragana  (ModeColorKana)
    ((= m 1) (ptr-read-u64 colors_ptr 8))    ; katakana  (ModeColorKatakana)
    ((= m 2) (ptr-read-u64 colors_ptr 16))   ; wide-latin (ModeColorWideLatin)
    ((= m 3) (ptr-read-u64 colors_ptr 24))   ; latin     (ModeColorLatin)
    ((= m 6) (ptr-read-u64 colors_ptr 48))   ; abbrev    (ModeColorAbbrev)
    (t #x808080)))                            ; unreachable/ERR (7) or unknown

 ;; preedit(4)/candidate(5) resolve to whichever base mode was active
 ;; before the composition started, exactly like Phase 2's
 ;; skkui_color_for; every other mode (including 7, which is never a
 ;; "previous base") resolves to itself.
 (defun skkui_color_for_configured (mode previous_base colors_ptr)
   (if (or (= mode 4) (= mode 5))
       (skkui_base_color_configured previous_base colors_ptr)
     (skkui_base_color_configured mode colors_ptr)))

 ;; Label codes main.c maps to glyphs: 0=あ 1=ア 2=Ａ 3=SKK 4=―― 5=Ab.
 ;; Labels are not registry-configurable (no such column in the design
 ;; doc's schema tables), so these stay exactly as Phase 2 had them.
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
 ;; itself. A thin wrapper around the base label table above rather
 ;; than a self-recursive function: object-mode compilation only
 ;; supports calling a *previously* defun'd function (see
 ;; nelisp-aot-compiler.el's "(NAME ARG...) -> call previously-defun'd
 ;; function"), so a defun calling itself is avoided on principle here.
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
