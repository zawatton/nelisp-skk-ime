;; colors.el --- Settings -> mode-logic colour array, in NeLisp (AOT).
;;
;; `fill_configured_colors' moved from main.c.  It is the first module
;; here to read a C struct's fields, which needs byte offsets into
;; `Settings' -- and hand-computed offsets are only acceptable because
;; main.c carries a `_Static_assert' for every one of them against
;; `offsetof'.  Get one wrong and the build stops on that assert, naming
;; the field.  Without that, a wrong offset is invisible: settings.c's
;; own round-trip selftest compares a struct against itself, so a
;; consistently wrong pair of offsets still passes.
;;
;; Keep SKKCOL_OFF_* below and main.c's assert block in step.  They are
;; two halves of one contract; the asserts exist so the compiler notices
;; when they drift.
;;
;; Offsets (x86_64, SETTINGS_STR_LEN 260, so wchar_t[260] = 520 bytes):
;;   engine[260]                0
;;   engine_okuri_auto        520   ... nine more int32 fields ...
;;   mode_indicator_scale     560
;;   (4 bytes of padding to 8-align the int64 block)
;;   color_kana               568
;;   color_katakana           576
;;   color_wide_latin         584
;;   color_latin              592
;;   color_abbrev             600
;;
;; The 7-slot output array is mode-logic.el's COLORS_PTR contract.  Slots
;; 4/5 (preedit/candidate) stay 0: `skkui_base_color_configured' never
;; reads them, because preedit/candidate are redirected to previous_base
;; before indexing, and slot 7's unreachable/ERR keeps its own hardcoded
;; grey.  Slot 6 is abbrev.

(seq
 ;; void fill_configured_colors(const Settings *s, int64_t out[7])
 (defun fill_configured_colors (s out)
   (ptr-write-u64 out 0 (ptr-read-u64 s 568))    ; color_kana
   (ptr-write-u64 out 8 (ptr-read-u64 s 576))    ; color_katakana
   (ptr-write-u64 out 16 (ptr-read-u64 s 584))   ; color_wide_latin
   (ptr-write-u64 out 24 (ptr-read-u64 s 592))   ; color_latin
   (ptr-write-u64 out 32 0)                      ; preedit  (unread)
   (ptr-write-u64 out 40 0)                      ; candidate (unread)
   (ptr-write-u64 out 48 (ptr-read-u64 s 600))   ; color_abbrev
   0))
