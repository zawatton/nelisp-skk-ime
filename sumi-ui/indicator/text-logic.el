;; text-logic.el --- Comment-preserving file settings in NeLisp AOT. -*- lexical-binding: t; -*-
;; File/registry/shell syscalls remain C primitives; parsing and merge policy live here.
;; String blobs are padded to 8 bytes: RegGetValueW/RegSetKeyValueW require
;; aligned UTF-16 names. Removing unused blobs must preserve this padding.
;; _done/_result express early returns while freeing each scratch allocation.
;; C/NeLisp layout contracts are checked by settings-abi.inc on every build.
(seq
 (data-blob sn_str_0 "\xef\xbb\xbf\x00\x00\x00\x00\x00" rodata) ; UTF-8 ﻿
 (data-blob sn_str_1 "\x0d\x0a\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 \r\n
 (data-blob sn_str_2 "\x0d\x0a\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 \r\n
 (data-blob sn_str_3 "\x0a\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 \n
 (data-blob sn_str_4 "\xef\xbb\xbf\x00\x00\x00\x00\x00" rodata) ; UTF-8 ﻿
 (data-blob sn_str_5 "\x25\x73\x20\x3d\x20\x25\x73\x25\x73\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 %s = %s%s
 (data-blob sn_str_6 "\x77\x69\x64\x74\x68\x00\x00\x00" rodata) ; UTF-8 width
 (data-blob sn_str_7 "\x61\x75\x74\x6f\x2d\x70\x61\x69\x72\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 auto-pair
 (data-blob sn_str_8 "\x65\x6e\x61\x62\x6c\x65\x64\x00" rodata) ; UTF-8 enabled
 (data-blob sn_str_9 "\x6c\x61\x79\x6f\x75\x74\x00\x00" rodata) ; UTF-8 layout
 (data-blob sn_str_10 "\x77\x69\x64\x74\x68\x00\x00\x00" rodata) ; UTF-8 width
 (data-blob sn_str_11 "\x65\x6e\x61\x62\x6c\x65\x64\x00" rodata) ; UTF-8 enabled
 (data-blob sn_str_12 "\x61\x75\x74\x6f\x2d\x70\x61\x69\x72\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 auto-pair
 (data-blob sn_str_13 "\x6c\x61\x79\x6f\x75\x74\x00\x00" rodata) ; UTF-8 layout
 (data-blob sn_str_14 "\x5c\x00\x4b\x00\x65\x00\x79\x00\x6d\x00\x61\x00\x70\x00\x00\x00" rodata) ; UTF-16 \Keymap
 (data-blob sn_str_15 "\x45\x00\x78\x00\x65\x00\x63\x00\x75\x00\x74\x00\x61\x00\x62\x00\x6c\x00\x65\x00\x00\x00\x00\x00" rodata) ; UTF-16 Executable
 (data-blob sn_str_16 "\x6f\x00\x70\x00\x65\x00\x6e\x00\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 open
 (data-blob sn_str_17 "\x2d\x00\x2d\x00\x72\x00\x75\x00\x6c\x00\x65\x00\x73\x00\x00\x00" rodata) ; UTF-16 --rules
 (data-blob sn_str_18 "\x2d\x00\x2d\x00\x65\x00\x64\x00\x69\x00\x74\x00\x6f\x00\x72\x00\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 --editor
 (data-blob sn_str_20 "\x5c\x00\x4b\x00\x65\x00\x79\x00\x6d\x00\x61\x00\x70\x00\x00\x00" rodata) ; UTF-16 \Keymap
 (data-blob sn_str_21 "\x53\x00\x74\x00\x61\x00\x74\x00\x75\x00\x73\x00\x00\x00\x00\x00" rodata) ; UTF-16 Status
 (data-blob sn_str_22 "\x45\x00\x72\x00\x72\x00\x6f\x00\x72\x00\x73\x00\x00\x00\x00\x00" rodata) ; UTF-16 Errors
 (data-blob sn_str_23 "\x53\x74\x61\x74\x75\x73\x3a\x20\x25\x73\x0a\x45\x72\x72\x6f\x72\x73\x3a\x20\x25\x73\x00\x00\x00" rodata) ; UTF-8 Status: %s\nErrors: %s
 (data-blob sn_str_24 "\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 
 (data-blob sn_str_25 "\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 
 (defun option_span (data key start end insert)
   (let ((_break 0) (_done 0) (_result 0) (p 0) (line_end 0) (q 0) (len 0))
     (progn
       (if (and (= _done 0) (= _break 0)) (setq p data) 0)
       (if (and (= _done 0) (= _break 0)) (if (extern-call g_str_has_prefix p (data-addr sn_str_0)) (setq p (+ p 3)) 0) 0)
       (if (and (= _done 0) (= _break 0)) (ptr-write-u64 insert 0 (extern-call strlen data)) 0)
       (if (and (= _done 0) (= _break 0)) (progn (setq _break 0) (while (and (= _done 0) (= _break 0) (ptr-read-u8 p 0)) (progn
															   (if (and (= _done 0) (= _break 0)) (setq line_end (extern-call strchr p 10)) 0)
															   (if (and (= _done 0) (= _break 0)) (if (= line_end 0) (setq line_end (+ p (extern-call strlen p))) 0) 0)
															   (if (and (= _done 0) (= _break 0)) (setq q p) 0)
															   (if (and (= _done 0) (= _break 0)) (progn (setq _break 0) (while (and (= _done 0) (= _break 0) (and (< q line_end) (or (= (ptr-read-u8 q 0) 32) (= (ptr-read-u8 q 0) 9)))) (let ((_old q)) (setq q (+ q 1)) _old))) 0)
															   (if (and (= _done 0) (= _break 0)) (if (= (ptr-read-u8 q 0) 91) (progn
																							     (if (and (= _done 0) (= _break 0)) (ptr-write-u64 insert 0 (- p data)) 0)
																							     (if (and (= _done 0) (= _break 0)) (progn (setq _result 0) (setq _done 1)) 0)) 0) 0)
															   (if (and (= _done 0) (= _break 0)) (setq len (extern-call strlen key)) 0)
															   (if (and (= _done 0) (= _break 0)) (if (and (>= (- line_end q) len) (= (extern-call strncmp q key len) 0)) (progn
																													(if (and (= _done 0) (= _break 0)) (setq q (+ q len)) 0)
																													(if (and (= _done 0) (= _break 0)) (progn (setq _break 0) (while (and (= _done 0) (= _break 0) (and (< q line_end) (or (= (ptr-read-u8 q 0) 32) (= (ptr-read-u8 q 0) 9)))) (let ((_old q)) (setq q (+ q 1)) _old))) 0)
																													(if (and (= _done 0) (= _break 0)) (if (and (< q line_end) (= (ptr-read-u8 q 0) 61)) (progn
																																							       (if (and (= _done 0) (= _break 0)) (let ((_old q)) (setq q (+ q 1)) _old) 0)
																																							       (if (and (= _done 0) (= _break 0)) (progn (setq _break 0) (while (and (= _done 0) (= _break 0) (and (< q line_end) (or (= (ptr-read-u8 q 0) 32) (= (ptr-read-u8 q 0) 9)))) (let ((_old q)) (setq q (+ q 1)) _old))) 0)
																																							       (if (and (= _done 0) (= _break 0)) (ptr-write-u64 start 0 (- q data)) 0)
																																							       (if (and (= _done 0) (= _break 0)) (progn (setq _break 0) (while (and (= _done 0) (= _break 0) (and (and (and (and (< q line_end) (/= (ptr-read-u8 q 0) 35)) (/= (ptr-read-u8 q 0) 13)) (/= (ptr-read-u8 q 0) 32)) (/= (ptr-read-u8 q 0) 9))) (let ((_old q)) (setq q (+ q 1)) _old))) 0)
																																							       (if (and (= _done 0) (= _break 0)) (ptr-write-u64 end 0 (- q data)) 0)
																																							       (if (and (= _done 0) (= _break 0)) (progn (setq _result 1) (setq _done 1)) 0)) 0) 0)) 0) 0)
															   (if (and (= _done 0) (= _break 0)) (setq p (if (ptr-read-u8 line_end 0) (+ line_end 1) line_end)) 0)))) 0)
       (if (and (= _done 0) (= _break 0)) (progn (setq _result 0) (setq _done 1)) 0))

     _result))
 (defun patch (data key value)
   (let ((_break 0) (_done 0) (_result 0) (a (extern-call g_malloc0 8)) (b (extern-call g_malloc0 8)) (insertion (extern-call g_malloc0 8)) (found 0) (out 0) (nl 0))
     (progn
       (if (and (= _done 0) (= _break 0)) (setq found (extern-call option_span data key (+ a 0) (+ b 0) (+ insertion 0))) 0)
       (if (and (= _done 0) (= _break 0)) (setq out (extern-call g_string_new 0)) 0)
       (if (and (= _done 0) (= _break 0)) (if found (progn
						      (if (and (= _done 0) (= _break 0)) (extern-call g_string_append_len out data (ptr-read-u64 a 0)) 0)
						      (if (and (= _done 0) (= _break 0)) (extern-call g_string_append out value) 0)
						      (if (and (= _done 0) (= _break 0)) (extern-call g_string_append out (+ data (ptr-read-u64 b 0))) 0)) (progn
						      (if (and (= _done 0) (= _break 0)) (setq nl (if (extern-call strstr data (data-addr sn_str_1)) (data-addr sn_str_2) (data-addr sn_str_3))) 0)
						      (if (and (= _done 0) (= _break 0)) (extern-call g_string_append_len out data (ptr-read-u64 insertion 0)) 0)
						      (if (and (= _done 0) (= _break 0)) (if (and (and (ptr-read-u64 insertion 0) (/= (ptr-read-u8 data (* (- (ptr-read-u64 insertion 0) 1) 1)) 10)) (= (and (= (ptr-read-u64 insertion 0) 3) (extern-call g_str_has_prefix data (data-addr sn_str_4))) 0)) (extern-call g_string_append out nl) 0) 0)
						      (if (and (= _done 0) (= _break 0)) (extern-call g_string_append_printf out (data-addr sn_str_5) key value nl) 0)
						      (if (and (= _done 0) (= _break 0)) (extern-call g_string_append out (+ data (ptr-read-u64 insertion 0))) 0))) 0)
       (if (and (= _done 0) (= _break 0)) (extern-call g_free data) 0)
       (if (and (= _done 0) (= _break 0)) (progn (setq _result (extern-call g_string_free out 0)) (setq _done 1)) 0))
     (extern-call g_free a)
     (extern-call g_free b)
     (extern-call g_free insertion)
     _result))
 (defun read_option (data key values fallback)
   (let ((_break 0) (_done 0) (_result 0) (a (extern-call g_malloc0 8)) (b (extern-call g_malloc0 8)) (i (extern-call g_malloc0 8)) (v 0))
     (progn
       (if (and (= _done 0) (= _break 0)) (if (and data (extern-call option_span data key (+ a 0) (+ b 0) (+ i 0))) (progn (progn (setq v 0)) (setq _break 0) (while (and (= _done 0) (= _break 0) (ptr-read-u64 values (* v 8))) (if (and (= (extern-call strlen (ptr-read-u64 values (* v 8))) (- (ptr-read-u64 b 0) (ptr-read-u64 a 0))) (= (extern-call strncmp (+ data (ptr-read-u64 a 0)) (ptr-read-u64 values (* v 8)) (- (ptr-read-u64 b 0) (ptr-read-u64 a 0))) 0)) (progn (setq _result v) (setq _done 1)) 0) (let ((_old v)) (setq v (+ v 1)) _old))) 0) 0)
       (if (and (= _done 0) (= _break 0)) (progn (setq _result fallback) (setq _done 1)) 0))
     (extern-call g_free a)
     (extern-call g_free b)
     (extern-call g_free i)
     _result))
 (defun text_settings_load (s)
   (let ((_break 0) (_done 0) (_result 0) (path (extern-call g_malloc0 65536)) (data 0))
     (progn
       (if (and (= _done 0) (= _break 0)) (setq data (if (extern-call config_path 1 path) (extern-call read_text path) 0)) 0)
       (if (and (= _done 0) (= _break 0)) (ptr-write-u32 s 0 (extern-call read_option data (data-addr sn_str_6) (extern-call skkui_text_values 0) 0)) 0)
       (if (and (= _done 0) (= _break 0)) (ptr-write-u32 s 4 (extern-call read_option data (data-addr sn_str_7) (extern-call skkui_text_values 1) 1)) 0)
       (if (and (= _done 0) (= _break 0)) (extern-call g_free data) 0)
       (if (and (= _done 0) (= _break 0)) (setq data (if (extern-call config_path 0 path) (extern-call read_text path) 0)) 0)
       (if (and (= _done 0) (= _break 0)) (ptr-write-u32 s 8 (extern-call read_option data (data-addr sn_str_8) (extern-call skkui_text_values 1) 0)) 0)
       (if (and (= _done 0) (= _break 0)) (ptr-write-u32 s 12 (extern-call read_option data (data-addr sn_str_9) (extern-call skkui_text_values 2) 0)) 0)
       (if (and (= _done 0) (= _break 0)) (extern-call g_free data) 0))
     (extern-call g_free path)
     _result))
 (defun save_file (rules change_a change_b a b)
   (let ((_break 0) (_done 0) (_result 0) (path (extern-call g_malloc0 65536)) (data 0) (missing 0) (attrs 0) (original 0) (ok 0))
     (progn
       (if (and (= _done 0) (= _break 0)) (if (= (extern-call config_path rules path) 0) (progn (setq _result 0) (setq _done 1)) 0) 0)
       (if (and (= _done 0) (= _break 0)) (setq data (extern-call read_text path)) 0)
       (if (and (= _done 0) (= _break 0)) (setq missing (= data 0)) 0)
       (if (and (= _done 0) (= _break 0)) (if (and (and data (= change_a 0)) (= change_b 0)) (progn
											       (if (and (= _done 0) (= _break 0)) (extern-call g_free data) 0)
											       (if (and (= _done 0) (= _break 0)) (progn (setq _result 1) (setq _done 1)) 0)) 0) 0)
       (if (and (= _done 0) (= _break 0)) (if (= data 0) (progn
							   (if (and (= _done 0) (= _break 0)) (setq attrs (extern-call GetFileAttributesW path)) 0)
							   (if (and (= _done 0) (= _break 0)) (if (or (/= attrs 4294967295) (and (/= (extern-call GetLastError ) 2) (/= (extern-call GetLastError ) 3))) (progn (setq _result 0) (setq _done 1)) 0) 0)
							   (if (and (= _done 0) (= _break 0)) (setq data (extern-call g_strdup (if rules (extern-call skkui_text_template 1) (extern-call skkui_text_template 0)))) 0)) 0) 0)
       (if (and (= _done 0) (= _break 0)) (setq original (extern-call g_strdup data)) 0)
       (if (and (= _done 0) (= _break 0)) (if change_a (setq data (extern-call patch data (if rules (data-addr sn_str_10) (data-addr sn_str_11)) (if rules (ptr-read-u64 (extern-call skkui_text_values 0) (* a 8)) (ptr-read-u64 (extern-call skkui_text_values 1) (* a 8))))) 0) 0)
       (if (and (= _done 0) (= _break 0)) (if change_b (setq data (extern-call patch data (if rules (data-addr sn_str_12) (data-addr sn_str_13)) (if rules (ptr-read-u64 (extern-call skkui_text_values 1) (* b 8)) (ptr-read-u64 (extern-call skkui_text_values 2) (* b 8))))) 0) 0)
       (if (and (= _done 0) (= _break 0)) (setq ok (or (and (= missing 0) (= (extern-call strcmp original data) 0)) (extern-call atomic_write path data))) 0)
       (if (and (= _done 0) (= _break 0)) (extern-call g_free original) 0)
       (if (and (= _done 0) (= _break 0)) (extern-call g_free data) 0)
       (if (and (= _done 0) (= _break 0)) (progn (setq _result ok) (setq _done 1)) 0))
     (extern-call g_free path)
     _result))
 (defun text_settings_save (s baseline)
   (let ((_break 0) (_done 0) (_result 0) (r 0) (k 0))
     (progn
       (if (and (= _done 0) (= _break 0)) (setq r (extern-call save_file 1 (/= (ptr-read-u32 s 0) (ptr-read-u32 baseline 0)) (/= (ptr-read-u32 s 4) (ptr-read-u32 baseline 4)) (ptr-read-u32 s 0) (ptr-read-u32 s 4))) 0)
       (if (and (= _done 0) (= _break 0)) (setq k (extern-call save_file 0 (/= (ptr-read-u32 s 8) (ptr-read-u32 baseline 8)) (/= (ptr-read-u32 s 12) (ptr-read-u32 baseline 12)) (ptr-read-u32 s 8) (ptr-read-u32 s 12))) 0)
       (if (and (= _done 0) (= _break 0)) (if r (progn
						  (if (and (= _done 0) (= _break 0)) (ptr-write-u32 baseline 0 (ptr-read-u32 s 0)) 0)
						  (if (and (= _done 0) (= _break 0)) (ptr-write-u32 baseline 4 (ptr-read-u32 s 4)) 0)) 0) 0)
       (if (and (= _done 0) (= _break 0)) (if k (progn
						  (if (and (= _done 0) (= _break 0)) (ptr-write-u32 baseline 8 (ptr-read-u32 s 8)) 0)
						  (if (and (= _done 0) (= _break 0)) (ptr-write-u32 baseline 12 (ptr-read-u32 s 12)) 0)) 0) 0)
       (if (and (= _done 0) (= _break 0)) (progn (setq _result (and r k)) (setq _done 1)) 0))

     _result))
 (defun text_settings_open (rules editor)
   (let ((_break 0) (_done 0) (_result 0) (path (extern-call g_malloc0 65536)) (key (extern-call g_malloc0 2048)) (bytes (extern-call g_malloc0 8)))
     (progn
       (if (and (= _done 0) (= _break 0)) (if editor (progn
						       (if (and (= _done 0) (= _break 0)) (extern-call settings_registry_path key 1000) 0)
						       (if (and (= _done 0) (= _break 0)) (extern-call wcscat key (data-addr sn_str_14)) 0)
						       (if (and (= _done 0) (= _break 0)) (ptr-write-u32 bytes 0 65536) 0)
						       (if (and (= _done 0) (= _break 0)) (if (or (/= (extern-call RegGetValueW 2147483649 key (data-addr sn_str_15) 2 0 path (+ bytes 0)) 0) (= (ptr-read-u16 path 0) 0)) (progn (setq _result 0) (setq _done 1)) 0) 0)) (progn
						       (if (and (= _done 0) (= _break 0)) (if (= (extern-call config_path rules path) 0) (progn (setq _result 0) (setq _done 1)) 0) 0)
						       (if (and (= _done 0) (= _break 0)) (if (and (= (extern-call GetFileAttributesW path) 4294967295) (= (extern-call atomic_write path (if rules (extern-call skkui_text_template 1) (extern-call skkui_text_template 0))) 0)) (progn (setq _result 0) (setq _done 1)) 0) 0))) 0)
       (if (and (= _done 0) (= _break 0)) (progn (setq _result (> (extern-call ShellExecuteW 0 (data-addr sn_str_16) path (if editor (if rules (data-addr sn_str_17) (data-addr sn_str_18)) 0) 0 1) 32)) (setq _done 1)) 0))
     (extern-call g_free path)
     (extern-call g_free key)
     (extern-call g_free bytes)
     _result))
 (defun text_settings_status ()
   (let ((_break 0) (_done 0) (_result 0) (key (extern-call g_malloc0 2048)) (status (extern-call g_malloc0 2048)) (errors (extern-call g_malloc0 16384)) (bytes (extern-call g_malloc0 8)) (i 0) (s 0) (e 0) (result 0))
     (progn
       (if (and (= _done 0) (= _break 0)) (extern-call memset status 0 2048) 0)
       (if (and (= _done 0) (= _break 0)) (progn (ptr-write-u16 errors 0 0)) 0)
       (if (and (= _done 0) (= _break 0)) (extern-call settings_registry_path key 1000) 0)
       (if (and (= _done 0) (= _break 0)) (extern-call wcscat key (data-addr sn_str_20)) 0)
       (if (and (= _done 0) (= _break 0)) (ptr-write-u32 bytes 0 2048) 0)
       (if (and (= _done 0) (= _break 0)) (extern-call RegGetValueW 2147483649 key (data-addr sn_str_21) 2 0 status (+ bytes 0)) 0)
       (if (and (= _done 0) (= _break 0)) (ptr-write-u32 bytes 0 16384) 0)
       (if (and (= _done 0) (= _break 0)) (extern-call RegGetValueW 2147483649 key (data-addr sn_str_22) 32 0 errors (+ bytes 0)) 0)
       (if (and (= _done 0) (= _break 0)) (ptr-write-u16 errors (* 8190 2) (ptr-write-u16 errors (* 8191 2) 0)) 0)
       (if (and (= _done 0) (= _break 0)) (progn (progn (setq i 0)) (setq _break 0) (while (and (= _done 0) (= _break 0) (< i 8190)) (progn
																       (if (and (= _done 0) (= _break 0)) (if (= (ptr-read-u16 errors (* i 2)) 0) (progn
																										    (if (and (= _done 0) (= _break 0)) (if (= (ptr-read-u16 errors (* (+ i 1) 2)) 0) (setq _break 1) 0) 0)
																										    (if (and (= _done 0) (= _break 0)) (ptr-write-u16 errors (* i 2) 10) 0)) 0) 0)) (let ((_old i)) (setq i (+ i 1)) _old))) 0)
       (setq _break 0)
       (if (and (= _done 0) (= _break 0)) (setq s (extern-call g_utf16_to_utf8 status (- 0 1) 0 0 0)) 0)
       (if (and (= _done 0) (= _break 0)) (setq e (extern-call g_utf16_to_utf8 errors (- 0 1) 0 0 0)) 0)
       (if (and (= _done 0) (= _break 0)) (setq result (extern-call g_strdup_printf (data-addr sn_str_23) (if s s (data-addr sn_str_24)) (if e e (data-addr sn_str_25)))) 0)
       (if (and (= _done 0) (= _break 0)) (extern-call g_free s) 0)
       (if (and (= _done 0) (= _break 0)) (extern-call g_free e) 0)
       (if (and (= _done 0) (= _break 0)) (progn (setq _result result) (setq _done 1)) 0))
     (extern-call g_free key)
     (extern-call g_free status)
     (extern-call g_free errors)
     (extern-call g_free bytes)
     _result))
 )
