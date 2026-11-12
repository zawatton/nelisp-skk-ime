;;; ddskk-realtime.el --- local romaji->kana preedit (RealtimeFrontend)  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sub-stage S3g of the native TSF DLL project.  AOT forms (restricted NeLisp
;; subset) porting windows/src/realtime_frontend.{h,cpp}.  The core (S3h/S3j)
;; links `ddskk-realtime-forms' (and `ddskk-realtime-blobs', and the imports in
;; `ddskk-realtime-imports') into its image; nothing here is DLL specific.
;;
;; Rule table.  The rules are read at build time from the very array the C++
;; uses (`kRules' in windows/src/realtime_frontend.cpp), so the two cannot
;; drift.  They are laid out as an open-addressing hash table (linear probing,
;; 1024 slots of 16 bytes, hash = djb2 over the ASCII key masked to 32 bits)
;; in a read-only data blob.  One table serves both std::unordered_map
;; (flag 1: exact rule, value = kana) and std::unordered_set (flag 2: the key
;; is a prefix of some rule).  Slot layout:
;;   +0 key length (0 = empty)  +1 flags  +2 value length (units)  +3 pad
;;   +4..9 key bytes            +10,11 pad  +12 value unit 0  +14 value unit 1
;; Build hook: env DDSKK_REALTIME_MUTATE="KEY=KANA" replaces one rule's kana
;; (negative control for test/realtime-e2e.sh).
;;
;; API.  OBJ is a heap RtFrontend (`rtf_new' / `rtf_free').  Every operation
;; that returns std::optional<EngineState> returns 1 when it produced a state
;; (readable through the rtf_out_* accessors until the next operation) and 0
;; for std::nullopt; RestorePreedit and ToHiragana always return 1.
;;   rtf_new () -> obj            rtf_free (obj)
;;   rtf_set_continuous (obj, v)  SetContinuousPreedit
;;   rtf_feed (obj, key)          Feed(char32_t)
;;   rtf_backspace / rtf_commit / rtf_quit / rtf_to_katakana /
;;   rtf_commit_katakana (obj)    Backspace / Commit / Quit / ToKatakana /
;;                                CommitKatakana
;;   rtf_restore_preedit / rtf_to_hiragana (obj)
;;   rtf_reset (obj)
;;   rtf_composing / rtf_preedit / rtf_katakana / rtf_latin / rtf_wide_latin
;;   rtf_raw_len (obj), rtf_raw_at (obj, i)             raw_keys()
;;   rtf_preview_len (obj), rtf_preview_ptr (obj)       preview_reading()
;;   rtf_out_mode (0 hiragana 1 katakana 2 latin 3 wide-latin 4 preedit),
;;   rtf_out_cstart (-1 or 0), rtf_out_text_ptr/len (UTF-16 units),
;;   rtf_out_pend_ptr/len (ASCII bytes)
;;
;; Differences from the C++ (deliberate, all unreachable by normal typing):
;;  * text, pending and raw-key buffers are fixed (1024 units / 16 bytes /
;;    1024 keys); a push into a full buffer is dropped instead of reallocating.
;;  * Only the lower/upper ASCII letters are folded (std::tolower of the C
;;    locale); Feed rejects everything but 0x20..0x7e like the C++.

;;; Code:

(require 'cl-lib)
(require 'nelisp-com-dsl)

(defconst ddskk-realtime-imports
  '(("kernel32.dll" "GetProcessHeap" "HeapAlloc" "HeapFree"))
  "Imports needed by `ddskk-realtime-forms'.")

(defconst ddskk-realtime--cap 1024 "Hash table slots (power of two).")
(defconst ddskk-realtime--tcap 1024)
(defconst ddskk-realtime--rcap 1024)

(defconst ddskk-realtime--cpp
  (expand-file-name "../src/realtime_frontend.cpp"
                    (file-name-directory (or load-file-name buffer-file-name
                                             default-directory)))
  "The C++ source whose `kRules' array is the rule source.")

(nelisp-com-defstruct RtFrontend
  (preedit u32) (katakana u32) (latin u32) (wide u32) (okuri u32) (cont u32)
  (tlen u64) (plen u64) (rlen u64) (rtlen u64) (nlen u64)
  (out_mode u64) (out_cstart i64) (out_tlen u64) (out_plen u64)
  (pend (array u8 16)) (nxt (array u8 16)) (out_pend (array u8 16))
  (text (array u16 1024)) (out_text (array u16 1032))
  (raw (array u32 1024)) (rawtmp (array u32 1024)))

(defun rtf--f (f) (nelisp-com-field 'f 'RtFrontend f))
(defun rtf--s (f v) (nelisp-com-set-field 'f 'RtFrontend f v))
(defun rtf--a (f) (nelisp-com-field-addr 'f 'RtFrontend f))

;;;; Build-time rule table

(defun ddskk-realtime-read-rules ()
  "Return the list (ROMAN . KANA-STRING) from `kRules' of the C++ source.
Duplicate keys keep the first entry, as std::unordered_map::emplace does."
  (let (rules)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents ddskk-realtime--cpp))
      (goto-char (point-min))
      (unless (re-search-forward "kRules{" nil t)
        (error "kRules not found in %s" ddskk-realtime--cpp))
      (let ((end (save-excursion (re-search-forward "};" nil t) (point))))
        (while (re-search-forward "Rule{\"\\([^\"]+\\)\", L\"\\([^\"]+\\)\"}" end t)
          (let ((k (match-string 1)) (v (match-string 2)))
            (unless (assoc k rules) (push (cons k v) rules))))))
    (setq rules (nreverse rules))
    (when (< (length rules) 100) (error "Too few rules extracted: %d" (length rules)))
    (let ((m (getenv "DDSKK_REALTIME_MUTATE")))
      (when (and m (string-match "\\`\\([^=]+\\)=\\(.+\\)\\'" m))
        (let ((cell (assoc (match-string 1 m) rules)))
          (unless cell (error "DDSKK_REALTIME_MUTATE: no rule %S" (match-string 1 m)))
          (setcdr cell (match-string 2 m)))))
    rules))

(defun ddskk-realtime--hash (key)
  (let ((h 5381))
    (dolist (b (append key nil) h)
      (setq h (logand (+ (* h 33) b) #xffffffff)))))

(defun ddskk-realtime-table-bytes (rules)
  "Return the byte list of the hash table for RULES."
  (let* ((cap ddskk-realtime--cap)
         (tab (make-vector (* 16 cap) 0)))
    (cl-flet ((slot-for (key)
                (let ((i (logand (ddskk-realtime--hash key) (1- cap))) found)
                  (while (not found)
                    (let ((o (* 16 i)))
                      (if (or (= (aref tab o) 0)
                              (and (= (aref tab o) (length key))
                                   (cl-loop for j below (length key)
                                            always (= (aref tab (+ o 4 j)) (aref key j)))))
                          (setq found o)
                        (setq i (logand (1+ i) (1- cap))))))
                  (when (> (length key) 6) (error "Key too long: %s" key))
                  (unless (= (aref tab found) (length key))
                    (aset tab found (length key))
                    (dotimes (j (length key)) (aset tab (+ found 4 j) (aref key j))))
                  found)))
      (dolist (r rules)
        (let ((k (car r)) (v (cdr r)))
          (when (> (length v) 2) (error "Value too long for %s" k))
          (let ((o (slot-for k)))
            (aset tab (+ o 1) (logior (aref tab (+ o 1)) 1))
            (aset tab (+ o 2) (length v))
            (dotimes (j (length v))
              (aset tab (+ o 12 (* 2 j)) (logand (aref v j) 255))
              (aset tab (+ o 13 (* 2 j)) (ash (aref v j) -8))))
          (cl-loop for n from 1 to (length k)
                   do (let ((o (slot-for (substring k 0 n))))
                        (aset tab (+ o 1) (logior (aref tab (+ o 1)) 2))))))
      (append tab nil))))

(defun ddskk-realtime-blobs ()
  "Data blobs of the RealtimeFrontend port (the rule table)."
  (list `(data-blob rtf_tab ,(ddskk-realtime-table-bytes (ddskk-realtime-read-rules))
                    rodata)))

;;;; AOT forms

(defun ddskk-realtime-forms ()
  "Return the AOT forms of the RealtimeFrontend port."
  (let ((tcap ddskk-realtime--tcap) (rcap ddskk-realtime--rcap)
        (mask (1- ddskk-realtime--cap)))
    (append
     (nelisp-com-struct-forms 'RtFrontend)
     `(;; ---- hash lookup ----
       (defun rtf_hash (p n)
         (let ((h 5381) (i 0))
           (seq (while (< i n)
                  (seq (setq h (logand (+ (* h 33) (ptr-read-u8 p i)) 4294967295))
                       (setq i (+ i 1))))
                h)))
       (defun rtf_keyeq (s p n)
         (let ((i 0) (ok 1))
           (seq (while (and (< i n) (= ok 1))
                  (seq (if (/= (ptr-read-u8 s (+ 4 i)) (ptr-read-u8 p i)) (setq ok 0) 0)
                       (setq i (+ i 1))))
                ok)))
       ;; Slot address of the key at P (N bytes), or 0.
       (defun rtf_find (p n)
         (if (or (< n 1) (> n 6)) 0
           (let ((i (logand (rtf_hash p n) ,mask)) (res 0) (done 0))
             (seq (while (= done 0)
                    (let ((s (+ (data-addr rtf_tab) (* i 16))))
                      (if (= (ptr-read-u8 s 0) 0) (setq done 1)
                        (if (and (= (ptr-read-u8 s 0) n) (= (rtf_keyeq s p n) 1))
                            (seq (setq res s) (setq done 1))
                          (setq i (logand (+ i 1) ,mask))))))
                  res))))
       ;; ---- buffers ----
       (defun rtf_tpush (f u)
         (let ((n ,(rtf--f 'tlen)))
           (if (< n ,tcap)
               (seq (ptr-write-u16 ,(rtf--a 'text) (* 2 n) u) ,(rtf--s 'tlen '(+ n 1)) 0)
             0)))
       (defun rtf_rpush (f k)
         (let ((n ,(rtf--f 'rlen)))
           (if (< n ,rcap)
               (seq (ptr-write-u32 ,(rtf--a 'raw) (* 4 n) k) ,(rtf--s 'rlen '(+ n 1)) 0)
             0)))
       (defun rtf_reset (f)
         (seq ,(rtf--s 'preedit 0) ,(rtf--s 'okuri 0) ,(rtf--s 'tlen 0)
              ,(rtf--s 'plen 0) ,(rtf--s 'rlen 0) 0))
       ;; Katakana(): hiragana U+3041..U+3096 -> +0x60 (one unit)
       (defun rtf_kana1 (u) (if (and (>= u 12353) (<= u 12438)) (+ u 96) u))
       (defun rtf_kata_text (f)
         (let ((i 0) (n ,(rtf--f 'tlen)))
           (seq (while (< i n)
                  (seq (ptr-write-u16 ,(rtf--a 'text) (* 2 i)
                                      (rtf_kana1 (ptr-read-u16 ,(rtf--a 'text) (* 2 i))))
                       (setq i (+ i 1))))
                0)))
       ;; pending_ appended to text_ and cleared
       (defun rtf_flush_pending (f)
         (let ((i 0) (n ,(rtf--f 'plen)))
           (seq (while (< i n)
                  (seq (rtf_tpush f (ptr-read-u8 ,(rtf--a 'pend) i)) (setq i (+ i 1))))
                ,(rtf--s 'plen 0) 0)))
       ;; text_ += (katakana_ ? kata : hira)
       (defun rtf_tpush_k (f hira)
         (rtf_tpush f (if (/= ,(rtf--f 'katakana) 0) (+ hira 96) hira)))
       (defun rtf_pending_is_n (f)
         (if (and (= ,(rtf--f 'plen) 1) (= (ptr-read-u8 ,(rtf--a 'pend) 0) 110)) 1 0))
       ;; ---- Snapshot(terminal) into the out_* fields ----
       (defun rtf_snapshot (f term)
         (let ((pre (if (and (/= ,(rtf--f 'preedit) 0) (= term 0)) 1 0))
               (i 0) (o 0))
           (seq ,(rtf--s 'out_mode
                         `(if (= pre 1) 4
                            (if (/= ,(rtf--f 'latin) 0) 2
                              (if (/= ,(rtf--f 'wide) 0) 3
                                (if (/= ,(rtf--f 'katakana) 0) 1 0)))))
                ,(rtf--s 'out_cstart '(if (= pre 1) 0 (- 0 1)))
                (if (= pre 1)
                    (seq (ptr-write-u16 ,(rtf--a 'out_text) 0 9661) (setq o 1)) 0)
                (while (< i ,(rtf--f 'tlen))
                  (seq (ptr-write-u16 ,(rtf--a 'out_text) (* 2 (+ o i))
                                      (ptr-read-u16 ,(rtf--a 'text) (* 2 i)))
                       (setq i (+ i 1))))
                ,(rtf--s 'out_tlen '(+ o i))
                (setq i 0)
                (while (< i ,(rtf--f 'plen))
                  (seq (ptr-write-u8 ,(rtf--a 'out_pend) i
                                     (ptr-read-u8 ,(rtf--a 'pend) i))
                       (setq i (+ i 1))))
                ,(rtf--s 'out_plen (rtf--f 'plen))
                1)))
       (defun rtf_set_out_one (f u)
         (seq (ptr-write-u16 ,(rtf--a 'out_text) 0 u) ,(rtf--s 'out_tlen 1) 1))
       ;; ---- Feed ----
       (defun rtf_is_consonant (c)
         (if (and (>= c 97) (<= c 122) (/= c 97) (/= c 105) (/= c 117)
                  (/= c 101) (/= c 111) (/= c 110)) 1 0))
       ;; The letter branch.  Returns 2 to continue with the common tail, or
       ;; the (0/1) result of the n-fallthrough recursion.
       (defun rtf_letter (f lower)
         (let ((nl ,(rtf--f 'plen)) (i 0) (res 2))
           (seq (while (< i nl)
                  (seq (ptr-write-u8 ,(rtf--a 'nxt) i (ptr-read-u8 ,(rtf--a 'pend) i))
                       (setq i (+ i 1))))
                (ptr-write-u8 ,(rtf--a 'nxt) nl lower)
                (setq nl (+ nl 1))
                (if (and (= nl 2)
                         (= (ptr-read-u8 ,(rtf--a 'nxt) 0) (ptr-read-u8 ,(rtf--a 'nxt) 1))
                         (= (rtf_is_consonant (ptr-read-u8 ,(rtf--a 'nxt) 0)) 1))
                    (seq (rtf_tpush_k f 12387)
                         (ptr-write-u8 ,(rtf--a 'nxt) 0 (ptr-read-u8 ,(rtf--a 'nxt) 1))
                         (setq nl 1))
                  0)
                (let ((slot (rtf_find ,(rtf--a 'nxt) nl)))
                  (if (and (/= slot 0) (/= (logand (ptr-read-u8 slot 1) 1) 0))
                      (seq (let ((j 0) (vl (ptr-read-u8 slot 2)))
                             (while (< j vl)
                               (seq (rtf_tpush f
                                               (if (/= ,(rtf--f 'katakana) 0)
                                                   (rtf_kana1 (ptr-read-u16 slot (+ 12 (* 2 j))))
                                                 (ptr-read-u16 slot (+ 12 (* 2 j)))))
                                    (setq j (+ j 1)))))
                           ,(rtf--s 'plen 0))
                    (if (and (/= slot 0) (/= (logand (ptr-read-u8 slot 1) 2) 0))
                        (seq (let ((j 0))
                               (while (< j nl)
                                 (seq (ptr-write-u8 ,(rtf--a 'pend) j
                                                    (ptr-read-u8 ,(rtf--a 'nxt) j))
                                      (setq j (+ j 1)))))
                             ,(rtf--s 'plen 'nl))
                      (if (and (> nl 1) (= (ptr-read-u8 ,(rtf--a 'nxt) 0) 110))
                          (seq (rtf_tpush_k f 12435)
                               ,(rtf--s 'plen 0)
                               (setq res (rtf_feed1 f lower 0)))
                        (seq (rtf_tpush f (ptr-read-u8 ,(rtf--a 'nxt) 0))
                             (let ((j 1))
                               (while (< j nl)
                                 (seq (ptr-write-u8 ,(rtf--a 'pend) (- j 1)
                                                    (ptr-read-u8 ,(rtf--a 'nxt) j))
                                      (setq j (+ j 1)))))
                             ,(rtf--s 'plen '(- nl 1)))))))
                res)))
       ;; FeedAscii(key, record) -> 1 with out_* set, or 0 (nullopt)
       (defun rtf_feed1 (f key record)
         (let* ((upper (if (and (>= key 65) (<= key 90)) 1 0))
                (lower (if (= upper 1) (+ key 32) key))
                (free (if (and (= ,(rtf--f 'cont) 0) (= ,(rtf--f 'preedit) 0)
                               (= ,(rtf--f 'plen) 0)) 1 0)))
           (seq
            (if (/= record 0) (rtf_rpush f key) 0)
            (if (and (= free 1) (= key 76))
                (seq ,(rtf--s 'wide 1) ,(rtf--s 'latin 0) ,(rtf--s 'rlen 0)
                     (rtf_snapshot f 0))
              (if (and (= free 1) (= key 108))
                  (seq ,(rtf--s 'latin 1) ,(rtf--s 'wide 0) ,(rtf--s 'rlen 0)
                       (rtf_snapshot f 0))
                (if (/= ,(rtf--f 'latin) 0) 0
                  (if (/= ,(rtf--f 'wide) 0)
                      (seq (rtf_snapshot f 1)
                           (rtf_set_out_one f (if (= key 32) 12288 (+ key 65248)))
                           ,(rtf--s 'rlen 0)
                           1)
                    (if (and (= free 1) (or (= key 113) (= key 81)))
                        (seq ,(rtf--s 'katakana `(if (= ,(rtf--f 'katakana) 0) 1 0))
                             (if (/= record 0) ,(rtf--s 'rlen 0) 0)
                             (rtf_snapshot f 0))
                      (seq
                       (if (and (/= ,(rtf--f 'cont) 0) (= ,(rtf--f 'preedit) 0))
                           ,(rtf--s 'preedit 1)
                         (if (and (= upper 1) (= ,(rtf--f 'preedit) 0))
                             ,(rtf--s 'preedit 1)
                           (if (and (= ,(rtf--f 'cont) 0) (= upper 1)
                                    (/= ,(rtf--f 'preedit) 0)
                                    (= ,(rtf--f 'okuri) 0) (> ,(rtf--f 'tlen) 0))
                               (seq (rtf_tpush f 42) ,(rtf--s 'okuri 1))
                             0)))
                       (let ((r 2))
                         (seq
                          (if (or (< lower 97) (> lower 122))
                              (seq (rtf_flush_pending f)
                                   (if (= key 46) (rtf_tpush f 12290)
                                     (if (= key 44) (rtf_tpush f 12289)
                                       (if (= key 45) (rtf_tpush f 12540)
                                         (if (= key 91) (rtf_tpush f 12300)
                                           (if (= key 93) (rtf_tpush f 12301)
                                             (rtf_tpush f key)))))))
                            (setq r (rtf_letter f lower)))
                          (if (/= r 2) r
                            (seq (rtf_snapshot f 0)
                                 (if (and (= ,(rtf--f 'preedit) 0) (= ,(rtf--f 'plen) 0))
                                     (seq ,(rtf--s 'tlen 0) ,(rtf--s 'rlen 0))
                                   0)
                                 1)))))))))))))
       (defun rtf_feed (f key)
         (if (or (< key 32) (> key 126)) 0 (rtf_feed1 f key 1)))
       (defun rtf_set_continuous (f v) (seq ,(rtf--s 'cont '(if (/= v 0) 1 0)) 0))
       (defun rtf_composing (f)
         (if (or (/= ,(rtf--f 'preedit) 0) (> ,(rtf--f 'plen) 0)) 1 0))
       (defun rtf_preedit (f) (if (/= ,(rtf--f 'preedit) 0) 1 0))
       (defun rtf_katakana (f) (if (/= ,(rtf--f 'katakana) 0) 1 0))
       (defun rtf_latin (f) (if (/= ,(rtf--f 'latin) 0) 1 0))
       (defun rtf_wide_latin (f) (if (/= ,(rtf--f 'wide) 0) 1 0))
       (defun rtf_raw_len (f) ,(rtf--f 'rlen))
       (defun rtf_raw_at (f i) (ptr-read-u32 ,(rtf--a 'raw) (* 4 i)))
       (defun rtf_preview_len (f)
         (if (and (/= ,(rtf--f 'preedit) 0) (= ,(rtf--f 'plen) 0) (= ,(rtf--f 'okuri) 0))
             ,(rtf--f 'tlen) 0))
       (defun rtf_preview_ptr (f) ,(rtf--a 'text))
       (defun rtf_out_mode (f) ,(rtf--f 'out_mode))
       (defun rtf_out_cstart (f) ,(rtf--f 'out_cstart))
       (defun rtf_out_text_ptr (f) ,(rtf--a 'out_text))
       (defun rtf_out_text_len (f) ,(rtf--f 'out_tlen))
       (defun rtf_out_pend_ptr (f) ,(rtf--a 'out_pend))
       (defun rtf_out_pend_len (f) ,(rtf--f 'out_plen))
       (defun rtf_new () (RtFrontend_alloc))
       (defun rtf_free (f) (RtFrontend_free f))
       ;; RebuildPreedit: replay a copy of raw_keys_ through FeedAscii(.., true)
       (defun rtf_rebuild (f)
         (let ((n ,(rtf--f 'rlen)) (i 0))
           (seq (while (< i n)
                  (seq (ptr-write-u32 ,(rtf--a 'rawtmp) (* 4 i)
                                      (ptr-read-u32 ,(rtf--a 'raw) (* 4 i)))
                       (setq i (+ i 1))))
                ,(rtf--s 'preedit 0) ,(rtf--s 'okuri 0) ,(rtf--s 'tlen 0)
                ,(rtf--s 'plen 0) ,(rtf--s 'rlen 0)
                (setq i 0)
                (while (< i n)
                  (seq (rtf_feed1 f (ptr-read-u32 ,(rtf--a 'rawtmp) (* 4 i)) 1)
                       (setq i (+ i 1))))
                0)))
       (defun rtf_backspace (f)
         (if (or (= (rtf_composing f) 0) (= ,(rtf--f 'rlen) 0)) 0
           (seq ,(rtf--s 'rlen `(- ,(rtf--f 'rlen) 1))
                (if (/= ,(rtf--f 'preedit) 0)
                    (seq (rtf_rebuild f)
                         (if (= ,(rtf--f 'rlen) 0) (rtf_reset f) 0)
                         (rtf_snapshot f 0))
                  (seq (if (> ,(rtf--f 'plen) 0) ,(rtf--s 'plen `(- ,(rtf--f 'plen) 1)) 0)
                       (rtf_snapshot f 0))))))
       (defun rtf_commit (f)
         (if (= (rtf_composing f) 0) 0
           (seq (if (= (rtf_pending_is_n f) 1) (seq (rtf_tpush_k f 12435) ,(rtf--s 'plen 0))
                  (rtf_flush_pending f))
                (rtf_snapshot f 1)
                (rtf_reset f)
                1)))
       (defun rtf_quit (f)
         (if (= (rtf_composing f) 0) 0
           (seq ,(rtf--s 'out_mode `(if (/= ,(rtf--f 'katakana) 0) 1 0))
                ,(rtf--s 'out_cstart '(- 0 1))
                ,(rtf--s 'out_tlen 0) ,(rtf--s 'out_plen 0)
                (rtf_reset f)
                1)))
       (defun rtf_restore_preedit (f) (rtf_snapshot f 0))
       (defun rtf_to_katakana (f)
         (if (= ,(rtf--f 'preedit) 0) 0
           (seq (rtf_kata_text f) ,(rtf--s 'katakana 1) (rtf_snapshot f 0))))
       (defun rtf_commit_katakana (f)
         (if (= ,(rtf--f 'preedit) 0) 0
           (seq (if (= (rtf_pending_is_n f) 1) (seq (rtf_tpush f 12435) ,(rtf--s 'plen 0))
                  (rtf_flush_pending f))
                (rtf_kata_text f)
                (rtf_snapshot f 1)
                (rtf_reset f)
                1)))
       (defun rtf_to_hiragana (f)
         (let ((i 0) (n ,(rtf--f 'tlen)))
           (seq (if (/= ,(rtf--f 'preedit) 0) (rtf_kata_text f) 0)
                (while (< i n)
                  (let ((u (ptr-read-u16 ,(rtf--a 'text) (* 2 i))))
                    (seq (if (and (>= u 12449) (<= u 12534))
                             (ptr-write-u16 ,(rtf--a 'text) (* 2 i) (- u 96)) 0)
                         (setq i (+ i 1)))))
                ,(rtf--s 'katakana 0) ,(rtf--s 'latin 0) ,(rtf--s 'wide 0)
                (rtf_snapshot f 0))))))))

(provide 'ddskk-realtime)
;;; ddskk-realtime.el ends here
