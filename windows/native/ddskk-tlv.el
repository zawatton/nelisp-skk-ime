;;; ddskk-tlv.el --- restricted-Elisp decoder of the engine TLV reply  -*- lexical-binding: t; -*-

;;; Commentary:

;; Stage S4.1/S3f of the native TSF DLL project.  AOT forms (restricted
;; NeLisp subset, COM DSL) decoding the binary reply defined in
;; docs/design/engine-tlv.md; the C++ reference is windows/src/engine_tlv.h
;; (`Decode').  The decoder does not copy: strings are (byte offset, byte
;; length) pairs into the caller's buffer, which must outlive the use of the
;; DdskkTlv object.
;;
;;   tlv_new ()               heap DdskkTlv object (0 on OOM)
;;   tlv_free (t)
;;   tlv_decode (buf size m)  0 on success, else an error code:
;;       1 size  2 magic  3 total!=size  4 version  5 kind  6 truncated record
;;       7 bad value width / odd UTF-16 length  8 size limit  9 missing tag
;;
;; Decode errors never read outside [buf, buf+size).  The decoder mirrors the
;; C++ rules exactly (last duplicate wins, unknown tags skipped).

;;; Code:

(require 'cl-lib)
(require 'nelisp-com-dsl)

(defconst ddskk-tlv-imports
  '(("kernel32.dll" "GetProcessHeap" "HeapAlloc" "HeapFree"))
  "Imports needed by `ddskk-tlv-forms'.")

(defconst ddskk-tlv-max-cands 512)

(nelisp-com-defstruct DdskkTlv
  (kind i64) (seen i64) (cursor i64) (comp i64) (idx i64) (seqn i64) (has_seq i64)
  (has_reg i64) (mode_off i64) (mode_len i64) (text_off i64) (text_len i64)
  (pend_off i64) (pend_len i64) (reg_off i64) (reg_len i64) (raw_off i64)
  (raw_len i64) (ncand i64)
  (cand_off (array i64 512)) (cand_len (array i64 512)))

(defun ddskk-tlv--f (p f) (nelisp-com-field p 'DdskkTlv f))
(defun ddskk-tlv--s (p f v) (nelisp-com-set-field p 'DdskkTlv f v))

(defun ddskk-tlv--field-chain ()
  "Nested IF form handling record TAG (returns 0 or an error code)."
  (let* ((str-ok `(if (or (/= (logand len 1) 0) (> len 16384)) 7))
         (specs
          `((1 . (if ,(cadr str-ok) 7
                   (seq ,(ddskk-tlv--s 'm 'mode_off 'voff) ,(ddskk-tlv--s 'm 'mode_len 'len)
                        ,(ddskk-tlv--s 'm 'seen `(logior ,(ddskk-tlv--f 'm 'seen) 1)) 0)))
            (2 . (if (/= len 4) 7
                   (seq ,(ddskk-tlv--s 'm 'cursor '(tlv_i32 buf voff))
                        ,(ddskk-tlv--s 'm 'seen `(logior ,(ddskk-tlv--f 'm 'seen) 2)) 0)))
            (3 . (if (/= len 4) 7
                   (seq ,(ddskk-tlv--s 'm 'comp '(tlv_i32 buf voff))
                        ,(ddskk-tlv--s 'm 'seen `(logior ,(ddskk-tlv--f 'm 'seen) 4)) 0)))
            (4 . (if ,(cadr str-ok) 7
                   (seq ,(ddskk-tlv--s 'm 'text_off 'voff) ,(ddskk-tlv--s 'm 'text_len 'len) 0)))
            (5 . (if ,(cadr str-ok) 7
                   (seq ,(ddskk-tlv--s 'm 'pend_off 'voff) ,(ddskk-tlv--s 'm 'pend_len 'len) 0)))
            (6 . (if (/= len 4) 7
                   (seq ,(ddskk-tlv--s 'm 'idx '(tlv_i32 buf voff))
                        ,(ddskk-tlv--s 'm 'seen `(logior ,(ddskk-tlv--f 'm 'seen) 8)) 0)))
            (7 . (if ,(cadr str-ok) 7
                   (let ((n ,(ddskk-tlv--f 'm 'ncand)))
                     (if (>= n ,ddskk-tlv-max-cands) 8
                       (seq (ptr-write-u64 (+ ,(nelisp-com-field-addr 'm 'DdskkTlv 'cand_off) (* 8 n)) 0 voff)
                            (ptr-write-u64 (+ ,(nelisp-com-field-addr 'm 'DdskkTlv 'cand_len) (* 8 n)) 0 len)
                            ,(ddskk-tlv--s 'm 'ncand '(+ n 1)) 0)))))
            (8 . (if ,(cadr str-ok) 7
                   (seq ,(ddskk-tlv--s 'm 'reg_off 'voff) ,(ddskk-tlv--s 'm 'reg_len 'len)
                        ,(ddskk-tlv--s 'm 'has_reg 1) 0)))
            (9 . (if (/= len 4) 7
                   (seq ,(ddskk-tlv--s 'm 'seqn '(ptr-read-u32 buf voff))
                        ,(ddskk-tlv--s 'm 'has_seq 1) 0)))
            (32 . (if (> len 16384) 8
                    (seq ,(ddskk-tlv--s 'm 'raw_off 'voff) ,(ddskk-tlv--s 'm 'raw_len 'len)
                         ,(ddskk-tlv--s 'm 'seen `(logior ,(ddskk-tlv--f 'm 'seen) 16)) 0))))))
    (let ((chain 0))
      (dolist (e (reverse specs) chain)
        (setq chain `(if (= tag ,(car e)) ,(cdr e) ,chain))))))

(defun ddskk-tlv-forms ()
  "Return the AOT forms of the TLV decoder."
  (append
   (nelisp-com-struct-forms 'DdskkTlv)
   `((defun tlv_i32 (buf off)
       (let ((v (ptr-read-u32 buf off)))
         (if (>= v 2147483648) (- v 4294967296) v)))
     ;; Handles one record; BUF-relative VOFF/LEN are already bounds-checked.
     (defun tlv_field (buf tag voff len m)
       ,(ddskk-tlv--field-chain))
     (defun tlv_new ()
       (DdskkTlv_alloc))
     (defun tlv_free (m) (extern-call HeapFree (extern-call GetProcessHeap) 0 m))
     (defun tlv_decode (buf size m)
       (let ((err 0) (pos 12) (kind 0))
         (seq
          (if (or (< size 12) (> size 65536)) (setq err 1) 0)
          (if (= err 0) (if (/= (ptr-read-u32 buf 0) #x56545344) (setq err 2) 0) 0)
          (if (= err 0) (if (/= (ptr-read-u32 buf 4) size) (setq err 3) 0) 0)
          (if (= err 0)
              (if (or (= (ptr-read-u8 buf 8) 0) (> (ptr-read-u8 buf 8) 1)) (setq err 4) 0)
            0)
          (if (= err 0)
              (seq (setq kind (ptr-read-u8 buf 9))
                   (if (and (/= kind 1) (/= kind 2)) (setq err 5) 0))
            0)
          (while (and (= err 0) (< pos size))
            (if (< (- size pos) 6) (setq err 6)
              (let ((tag (ptr-read-u16 buf pos)) (len (ptr-read-u32 buf (+ pos 2))))
                (seq (setq pos (+ pos 6))
                     (if (> len (- size pos)) (setq err 6)
                       (seq (setq err (tlv_field buf tag pos len m))
                            (setq pos (+ pos len)))))))) 
          (if (= err 0)
              (seq ,(ddskk-tlv--s 'm 'kind 'kind)
                   (if (= kind 1)
                       (if (/= (logand ,(ddskk-tlv--f 'm 'seen) 15) 15) (setq err 9) 0)
                     (if (= (logand ,(ddskk-tlv--f 'm 'seen) 16) 0) (setq err 9) 0)))
            0)
          err))))))

(provide 'ddskk-tlv)
;;; ddskk-tlv.el ends here
