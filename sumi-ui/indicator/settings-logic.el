;; settings-logic.el --- Settings logic in NeLisp AOT. -*- lexical-binding: t; -*-
;; C retains ABI primitives; struct offsets are checked in settings-abi.inc.
;; String blobs are padded to 8 bytes: RegGetValueW/RegSetKeyValueW require
;; aligned UTF-16 names. Removing unused blobs must preserve this padding.
;; _done/_result express early returns while freeing each scratch allocation.
;; C/NeLisp layout contracts are checked by settings-abi.inc on every build.
(seq
 (data-blob sn_str_85 "\x64\x00\x64\x00\x73\x00\x6b\x00\x6b\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 ddskk
 (data-blob sn_str_86 "\x31\x00\x32\x00\x37\x00\x2e\x00\x30\x00\x2e\x00\x30\x00\x2e\x00\x31\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 127.0.0.1
 (data-blob sn_str_87 "\x25\x00\x4c\x00\x4f\x00\x43\x00\x41\x00\x4c\x00\x41\x00\x50\x00\x50\x00\x44\x00\x41\x00\x54\x00\x41\x00\x25\x00\x5c\x00\x44\x00\x44\x00\x53\x00\x4b\x00\x4b\x00\x5c\x00\x75\x00\x73\x00\x65\x00\x72\x00\x2d\x00\x6a\x00\x69\x00\x73\x00\x79\x00\x6f\x00\x2e\x00\x75\x00\x74\x00\x66\x00\x38\x00\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 %LOCALAPPDATA%\DDSKK\user-jisyo.utf8
 (data-blob sn_str_88 "\x45\x00\x6e\x00\x67\x00\x69\x00\x6e\x00\x65\x00\x00\x00\x00\x00" rodata) ; UTF-16 Engine
 (data-blob sn_str_89 "\x49\x00\x6e\x00\x69\x00\x74\x00\x69\x00\x61\x00\x6c\x00\x4b\x00\x61\x00\x6e\x00\x61\x00\x4d\x00\x6f\x00\x64\x00\x65\x00\x00\x00" rodata) ; UTF-16 InitialKanaMode
 (data-blob sn_str_90 "\x42\x00\x65\x00\x68\x00\x61\x00\x76\x00\x69\x00\x6f\x00\x72\x00\x4f\x00\x6b\x00\x75\x00\x72\x00\x69\x00\x53\x00\x74\x00\x72\x00\x69\x00\x63\x00\x74\x00\x6c\x00\x79\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 BehaviorOkuriStrictly
 (data-blob sn_str_91 "\x42\x00\x65\x00\x68\x00\x61\x00\x76\x00\x69\x00\x6f\x00\x72\x00\x44\x00\x65\x00\x6c\x00\x65\x00\x74\x00\x65\x00\x4f\x00\x6b\x00\x75\x00\x72\x00\x69\x00\x4f\x00\x6e\x00\x43\x00\x61\x00\x6e\x00\x63\x00\x65\x00\x6c\x00\x00\x00" rodata) ; UTF-16 BehaviorDeleteOkuriOnCancel
 (data-blob sn_str_92 "\x42\x00\x65\x00\x68\x00\x61\x00\x76\x00\x69\x00\x6f\x00\x72\x00\x41\x00\x64\x00\x64\x00\x4b\x00\x61\x00\x74\x00\x61\x00\x6b\x00\x61\x00\x6e\x00\x61\x00\x43\x00\x61\x00\x6e\x00\x64\x00\x00\x00" rodata) ; UTF-16 BehaviorAddKatakanaCand
 (data-blob sn_str_93 "\x42\x00\x65\x00\x68\x00\x61\x00\x76\x00\x69\x00\x6f\x00\x72\x00\x4c\x00\x65\x00\x61\x00\x72\x00\x6e\x00\x44\x00\x69\x00\x73\x00\x61\x00\x62\x00\x6c\x00\x65\x00\x64\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 BehaviorLearnDisabled
 (data-blob sn_str_94 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x49\x00\x6e\x00\x64\x00\x69\x00\x63\x00\x61\x00\x74\x00\x6f\x00\x72\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 ModeIndicator
 (data-blob sn_str_95 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x49\x00\x6e\x00\x64\x00\x69\x00\x63\x00\x61\x00\x74\x00\x6f\x00\x72\x00\x4d\x00\x73\x00\x00\x00" rodata) ; UTF-16 ModeIndicatorMs
 (data-blob sn_str_96 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x49\x00\x6e\x00\x64\x00\x69\x00\x63\x00\x61\x00\x74\x00\x6f\x00\x72\x00\x53\x00\x63\x00\x61\x00\x6c\x00\x65\x00\x00\x00\x00\x00" rodata) ; UTF-16 ModeIndicatorScale
 (data-blob sn_str_97 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x43\x00\x6f\x00\x6c\x00\x6f\x00\x72\x00\x4b\x00\x61\x00\x6e\x00\x61\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 ModeColorKana
 (data-blob sn_str_98 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x43\x00\x6f\x00\x6c\x00\x6f\x00\x72\x00\x4b\x00\x61\x00\x74\x00\x61\x00\x6b\x00\x61\x00\x6e\x00\x61\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 ModeColorKatakana
 (data-blob sn_str_99 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x43\x00\x6f\x00\x6c\x00\x6f\x00\x72\x00\x57\x00\x69\x00\x64\x00\x65\x00\x4c\x00\x61\x00\x74\x00\x69\x00\x6e\x00\x00\x00\x00\x00" rodata) ; UTF-16 ModeColorWideLatin
 (data-blob sn_str_100 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x43\x00\x6f\x00\x6c\x00\x6f\x00\x72\x00\x4c\x00\x61\x00\x74\x00\x69\x00\x6e\x00\x00\x00\x00\x00" rodata) ; UTF-16 ModeColorLatin
 (data-blob sn_str_101 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x43\x00\x6f\x00\x6c\x00\x6f\x00\x72\x00\x41\x00\x62\x00\x62\x00\x72\x00\x65\x00\x76\x00\x00\x00" rodata) ; UTF-16 ModeColorAbbrev
 (data-blob sn_str_102 "\x53\x00\x6b\x00\x6b\x00\x53\x00\x65\x00\x72\x00\x76\x00\x45\x00\x6e\x00\x61\x00\x62\x00\x6c\x00\x65\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 SkkServEnable
 (data-blob sn_str_103 "\x53\x00\x6b\x00\x6b\x00\x53\x00\x65\x00\x72\x00\x76\x00\x48\x00\x6f\x00\x73\x00\x74\x00\x00\x00" rodata) ; UTF-16 SkkServHost
 (data-blob sn_str_104 "\x53\x00\x6b\x00\x6b\x00\x53\x00\x65\x00\x72\x00\x76\x00\x50\x00\x6f\x00\x72\x00\x74\x00\x00\x00" rodata) ; UTF-16 SkkServPort
 (data-blob sn_str_105 "\x55\x00\x73\x00\x65\x00\x72\x00\x4a\x00\x69\x00\x73\x00\x79\x00\x6f\x00\x50\x00\x61\x00\x74\x00\x68\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 UserJisyoPath
 (data-blob sn_str_106 "\x55\x00\x73\x00\x65\x00\x72\x00\x4a\x00\x69\x00\x73\x00\x79\x00\x6f\x00\x42\x00\x61\x00\x74\x00\x63\x00\x68\x00\x00\x00\x00\x00" rodata) ; UTF-16 UserJisyoBatch
 (data-blob sn_str_107 "\x49\x00\x64\x00\x6c\x00\x65\x00\x47\x00\x63\x00\x4d\x00\x73\x00\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 IdleGcMs
 (data-blob sn_str_108 "\x44\x00\x6c\x00\x6c\x00\x44\x00\x65\x00\x62\x00\x75\x00\x67\x00\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 DllDebug
 (data-blob sn_str_109 "\x45\x00\x78\x00\x70\x00\x65\x00\x72\x00\x69\x00\x6d\x00\x65\x00\x6e\x00\x74\x00\x61\x00\x6c\x00\x45\x00\x6e\x00\x67\x00\x69\x00\x6e\x00\x65\x00\x73\x00\x00\x00" rodata) ; UTF-16 ExperimentalEngines
 (data-blob sn_str_110 "\x4f\x00\x6b\x00\x75\x00\x72\x00\x69\x00\x41\x00\x75\x00\x74\x00\x6f\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 OkuriAuto
 (data-blob sn_str_111 "\x43\x00\x61\x00\x6e\x00\x64\x00\x69\x00\x64\x00\x61\x00\x74\x00\x65\x00\x4c\x00\x69\x00\x6d\x00\x69\x00\x74\x00\x00\x00\x00\x00" rodata) ; UTF-16 CandidateLimit
 (data-blob sn_str_112 "\x4c\x00\x65\x00\x61\x00\x72\x00\x6e\x00\x69\x00\x6e\x00\x67\x00\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 Learning
 (data-blob sn_str_113 "\x45\x00\x6e\x00\x67\x00\x69\x00\x6e\x00\x65\x00\x00\x00\x00\x00" rodata) ; UTF-16 Engine
 (data-blob sn_str_114 "\x49\x00\x6e\x00\x69\x00\x74\x00\x69\x00\x61\x00\x6c\x00\x4b\x00\x61\x00\x6e\x00\x61\x00\x4d\x00\x6f\x00\x64\x00\x65\x00\x00\x00" rodata) ; UTF-16 InitialKanaMode
 (data-blob sn_str_115 "\x42\x00\x65\x00\x68\x00\x61\x00\x76\x00\x69\x00\x6f\x00\x72\x00\x4f\x00\x6b\x00\x75\x00\x72\x00\x69\x00\x53\x00\x74\x00\x72\x00\x69\x00\x63\x00\x74\x00\x6c\x00\x79\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 BehaviorOkuriStrictly
 (data-blob sn_str_116 "\x42\x00\x65\x00\x68\x00\x61\x00\x76\x00\x69\x00\x6f\x00\x72\x00\x44\x00\x65\x00\x6c\x00\x65\x00\x74\x00\x65\x00\x4f\x00\x6b\x00\x75\x00\x72\x00\x69\x00\x4f\x00\x6e\x00\x43\x00\x61\x00\x6e\x00\x63\x00\x65\x00\x6c\x00\x00\x00" rodata) ; UTF-16 BehaviorDeleteOkuriOnCancel
 (data-blob sn_str_117 "\x42\x00\x65\x00\x68\x00\x61\x00\x76\x00\x69\x00\x6f\x00\x72\x00\x41\x00\x64\x00\x64\x00\x4b\x00\x61\x00\x74\x00\x61\x00\x6b\x00\x61\x00\x6e\x00\x61\x00\x43\x00\x61\x00\x6e\x00\x64\x00\x00\x00" rodata) ; UTF-16 BehaviorAddKatakanaCand
 (data-blob sn_str_118 "\x42\x00\x65\x00\x68\x00\x61\x00\x76\x00\x69\x00\x6f\x00\x72\x00\x4c\x00\x65\x00\x61\x00\x72\x00\x6e\x00\x44\x00\x69\x00\x73\x00\x61\x00\x62\x00\x6c\x00\x65\x00\x64\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 BehaviorLearnDisabled
 (data-blob sn_str_119 "\x4f\x00\x6b\x00\x75\x00\x72\x00\x69\x00\x41\x00\x75\x00\x74\x00\x6f\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 OkuriAuto
 (data-blob sn_str_120 "\x43\x00\x61\x00\x6e\x00\x64\x00\x69\x00\x64\x00\x61\x00\x74\x00\x65\x00\x4c\x00\x69\x00\x6d\x00\x69\x00\x74\x00\x00\x00\x00\x00" rodata) ; UTF-16 CandidateLimit
 (data-blob sn_str_121 "\x4c\x00\x65\x00\x61\x00\x72\x00\x6e\x00\x69\x00\x6e\x00\x67\x00\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 Learning
 (data-blob sn_str_122 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x49\x00\x6e\x00\x64\x00\x69\x00\x63\x00\x61\x00\x74\x00\x6f\x00\x72\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 ModeIndicator
 (data-blob sn_str_123 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x49\x00\x6e\x00\x64\x00\x69\x00\x63\x00\x61\x00\x74\x00\x6f\x00\x72\x00\x4d\x00\x73\x00\x00\x00" rodata) ; UTF-16 ModeIndicatorMs
 (data-blob sn_str_124 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x49\x00\x6e\x00\x64\x00\x69\x00\x63\x00\x61\x00\x74\x00\x6f\x00\x72\x00\x53\x00\x63\x00\x61\x00\x6c\x00\x65\x00\x00\x00\x00\x00" rodata) ; UTF-16 ModeIndicatorScale
 (data-blob sn_str_125 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x43\x00\x6f\x00\x6c\x00\x6f\x00\x72\x00\x4b\x00\x61\x00\x6e\x00\x61\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 ModeColorKana
 (data-blob sn_str_126 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x43\x00\x6f\x00\x6c\x00\x6f\x00\x72\x00\x4b\x00\x61\x00\x74\x00\x61\x00\x6b\x00\x61\x00\x6e\x00\x61\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 ModeColorKatakana
 (data-blob sn_str_127 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x43\x00\x6f\x00\x6c\x00\x6f\x00\x72\x00\x57\x00\x69\x00\x64\x00\x65\x00\x4c\x00\x61\x00\x74\x00\x69\x00\x6e\x00\x00\x00\x00\x00" rodata) ; UTF-16 ModeColorWideLatin
 (data-blob sn_str_128 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x43\x00\x6f\x00\x6c\x00\x6f\x00\x72\x00\x4c\x00\x61\x00\x74\x00\x69\x00\x6e\x00\x00\x00\x00\x00" rodata) ; UTF-16 ModeColorLatin
 (data-blob sn_str_129 "\x4d\x00\x6f\x00\x64\x00\x65\x00\x43\x00\x6f\x00\x6c\x00\x6f\x00\x72\x00\x41\x00\x62\x00\x62\x00\x72\x00\x65\x00\x76\x00\x00\x00" rodata) ; UTF-16 ModeColorAbbrev
 (data-blob sn_str_130 "\x53\x00\x6b\x00\x6b\x00\x53\x00\x65\x00\x72\x00\x76\x00\x45\x00\x6e\x00\x61\x00\x62\x00\x6c\x00\x65\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 SkkServEnable
 (data-blob sn_str_131 "\x53\x00\x6b\x00\x6b\x00\x53\x00\x65\x00\x72\x00\x76\x00\x48\x00\x6f\x00\x73\x00\x74\x00\x00\x00" rodata) ; UTF-16 SkkServHost
 (data-blob sn_str_132 "\x53\x00\x6b\x00\x6b\x00\x53\x00\x65\x00\x72\x00\x76\x00\x50\x00\x6f\x00\x72\x00\x74\x00\x00\x00" rodata) ; UTF-16 SkkServPort
 (data-blob sn_str_133 "\x55\x00\x73\x00\x65\x00\x72\x00\x4a\x00\x69\x00\x73\x00\x79\x00\x6f\x00\x50\x00\x61\x00\x74\x00\x68\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 UserJisyoPath
 (data-blob sn_str_134 "\x55\x00\x73\x00\x65\x00\x72\x00\x4a\x00\x69\x00\x73\x00\x79\x00\x6f\x00\x42\x00\x61\x00\x74\x00\x63\x00\x68\x00\x00\x00\x00\x00" rodata) ; UTF-16 UserJisyoBatch
 (data-blob sn_str_135 "\x49\x00\x64\x00\x6c\x00\x65\x00\x47\x00\x63\x00\x4d\x00\x73\x00\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 IdleGcMs
 (data-blob sn_str_136 "\x44\x00\x6c\x00\x6c\x00\x44\x00\x65\x00\x62\x00\x75\x00\x67\x00\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 DllDebug
 (defun settings_defaults (s)
   (let ((_done 0) (_result 0))
     (progn
       (if (= _done 0) (extern-call wcsncpy (+ s 0) (data-addr sn_str_85) (- 260 1)) 0)
       (if (= _done 0) (ptr-write-u16 (+ s 0) (* (- 260 1) 2) 0) 0)
       (if (= _done 0) (ptr-write-u32 s 520 1) 0)
       (if (= _done 0) (ptr-write-u32 s 524 9) 0)
       (if (= _done 0) (ptr-write-u32 s 528 1) 0)
       (if (= _done 0) (ptr-write-u32 s 532 1) 0)
       (if (= _done 0) (ptr-write-u32 s 536 0) 0)
       (if (= _done 0) (ptr-write-u32 s 540 0) 0)
       (if (= _done 0) (ptr-write-u32 s 544 0) 0)
       (if (= _done 0) (ptr-write-u32 s 548 0) 0)
       (if (= _done 0) (ptr-write-u32 s 552 1) 0)
       (if (= _done 0) (ptr-write-u32 s 556 3000) 0)
       (if (= _done 0) (ptr-write-u32 s 560 100) 0)
       (if (= _done 0) (ptr-write-u64 s 568 2105536) 0)
       (if (= _done 0) (ptr-write-u64 s 576 3899163) 0)
       (if (= _done 0) (ptr-write-u64 s 592 13149696) 0)
       (if (= _done 0) (ptr-write-u64 s 584 11033118) 0)
       (if (= _done 0) (ptr-write-u64 s 600 9514090) 0)
       (if (= _done 0) (ptr-write-u32 s 608 1) 0)
       (if (= _done 0) (extern-call wcsncpy (+ s 612) (data-addr sn_str_86) (- 260 1)) 0)
       (if (= _done 0) (ptr-write-u16 (+ s 612) (* (- 260 1) 2) 0) 0)
       (if (= _done 0) (ptr-write-u32 s 1132 1179) 0)
       (if (= _done 0) (extern-call wcsncpy (+ s 1136) (data-addr sn_str_87) (- 260 1)) 0)
       (if (= _done 0) (ptr-write-u16 (+ s 1136) (* (- 260 1) 2) 0) 0)
       (if (= _done 0) (ptr-write-u32 s 1656 10) 0)
       (if (= _done 0) (ptr-write-u32 s 1660 10000) 0)
       (if (= _done 0) (ptr-write-u32 s 1664 0) 0))

     _result))
 (defun settings_load (s)
   (let ((_done 0) (_result 0) (key (extern-call g_malloc0 1024)) (d (extern-call g_malloc0 1672)) (v (extern-call g_malloc0 8)))
     (progn
       (if (= _done 0) (extern-call settings_registry_path key 512) 0)
       (if (= _done 0) (extern-call settings_defaults (+ d 0)) 0)
       (if (= _done 0) (extern-call reg_get_sz key (data-addr sn_str_88) (+ (+ d 0) 0) (+ s 0) 260) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_89) (ptr-read-u32 (+ d 0) 532) (+ s 532)) 0)
       (if (= _done 0) (extern-call settings_load_engine_scope s (+ s 0)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_90) (ptr-read-u32 (+ d 0) 536) (+ s 536)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_91) (ptr-read-u32 (+ d 0) 540) (+ s 540)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_92) (ptr-read-u32 (+ d 0) 544) (+ s 544)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_93) (ptr-read-u32 (+ d 0) 548) (+ s 548)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_94) (ptr-read-u32 (+ d 0) 552) (+ s 552)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_95) (ptr-read-u32 (+ d 0) 556) (+ s 556)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_96) (ptr-read-u32 (+ d 0) 560) (+ s 560)) 0)
       (if (= _done 0) (progn
			 (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_97) (ptr-read-u64 (+ d 0) 568) (+ v 0)) 0)
			 (if (= _done 0) (ptr-write-u64 s 568 (ptr-read-u32 v 0)) 0)
			 (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_98) (ptr-read-u64 (+ d 0) 576) (+ v 0)) 0)
			 (if (= _done 0) (ptr-write-u64 s 576 (ptr-read-u32 v 0)) 0)
			 (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_99) (ptr-read-u64 (+ d 0) 584) (+ v 0)) 0)
			 (if (= _done 0) (ptr-write-u64 s 584 (ptr-read-u32 v 0)) 0)
			 (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_100) (ptr-read-u64 (+ d 0) 592) (+ v 0)) 0)
			 (if (= _done 0) (ptr-write-u64 s 592 (ptr-read-u32 v 0)) 0)
			 (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_101) (ptr-read-u64 (+ d 0) 600) (+ v 0)) 0)
			 (if (= _done 0) (ptr-write-u64 s 600 (ptr-read-u32 v 0)) 0)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_102) (ptr-read-u32 (+ d 0) 608) (+ s 608)) 0)
       (if (= _done 0) (extern-call reg_get_sz key (data-addr sn_str_103) (+ (+ d 0) 612) (+ s 612) 260) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_104) (ptr-read-u32 (+ d 0) 1132) (+ s 1132)) 0)
       (if (= _done 0) (extern-call reg_get_sz key (data-addr sn_str_105) (+ (+ d 0) 1136) (+ s 1136) 260) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_106) (ptr-read-u32 (+ d 0) 1656) (+ s 1656)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_107) (ptr-read-u32 (+ d 0) 1660) (+ s 1660)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_108) (ptr-read-u32 (+ d 0) 1664) (+ s 1664)) 0)
       (if (= _done 0) (progn (setq _result 1) (setq _done 1)) 0))
     (extern-call g_free key)
     (extern-call g_free d)
     (extern-call g_free v)
     _result))
 (defun settings_experimental_engines ()
   (let ((_done 0) (_result 0) (key (extern-call g_malloc0 1024)) (enabled (extern-call g_malloc0 8)))
     (progn
       (if (= _done 0) (extern-call settings_registry_path key 512) 0)
       (if (= _done 0) (ptr-write-u32 enabled 0 0) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_109) 0 (+ enabled 0)) 0)
       (if (= _done 0) (progn (setq _result (/= (ptr-read-u32 enabled 0) 0)) (setq _done 1)) 0))
     (extern-call g_free key)
     (extern-call g_free enabled)
     _result))
 (defun settings_load_engine_scope (s engine_id)
   (let ((_done 0) (_result 0) (key (extern-call g_malloc0 1024)) (d (extern-call g_malloc0 1672)))
     (progn
       (if (= _done 0) (extern-call engine_key_path key 512 engine_id) 0)
       (if (= _done 0) (extern-call settings_defaults (+ d 0)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_110) (ptr-read-u32 (+ d 0) 520) (+ s 520)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_111) (ptr-read-u32 (+ d 0) 524) (+ s 524)) 0)
       (if (= _done 0) (extern-call reg_get_dword key (data-addr sn_str_112) (ptr-read-u32 (+ d 0) 528) (+ s 528)) 0))
     (extern-call g_free key)
     (extern-call g_free d)
     _result))
 (defun settings_save (s)
   (let ((_done 0) (_result 0) (key (extern-call g_malloc0 1024)) (ok 0) (engine_key (extern-call g_malloc0 1024)) (d (extern-call g_malloc0 1672)))
     (progn
       (if (= _done 0) (extern-call settings_registry_path key 512) 0)
       (if (= _done 0) (setq ok 1) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_sz key (data-addr sn_str_113) (+ s 0)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_114) (ptr-read-u32 s 532)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_115) (ptr-read-u32 s 536)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_116) (ptr-read-u32 s 540)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_117) (ptr-read-u32 s 544)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_118) (ptr-read-u32 s 548)) ok)) 0)
       (if (= _done 0) (extern-call engine_key_path engine_key 512 (+ s 0)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword engine_key (data-addr sn_str_119) (ptr-read-u32 s 520)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword engine_key (data-addr sn_str_120) (ptr-read-u32 s 524)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword engine_key (data-addr sn_str_121) (ptr-read-u32 s 528)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_122) (ptr-read-u32 s 552)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_123) (ptr-read-u32 s 556)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_124) (ptr-read-u32 s 560)) ok)) 0)
       (if (= _done 0) (progn
			 (if (= _done 0) (extern-call settings_defaults (+ d 0)) 0)
			 (if (= _done 0) (setq ok (and (extern-call reg_set_color key (data-addr sn_str_125) (ptr-read-u64 s 568) (ptr-read-u64 (+ d 0) 568)) ok)) 0)
			 (if (= _done 0) (setq ok (and (extern-call reg_set_color key (data-addr sn_str_126) (ptr-read-u64 s 576) (ptr-read-u64 (+ d 0) 576)) ok)) 0)
			 (if (= _done 0) (setq ok (and (extern-call reg_set_color key (data-addr sn_str_127) (ptr-read-u64 s 584) (ptr-read-u64 (+ d 0) 584)) ok)) 0)
			 (if (= _done 0) (setq ok (and (extern-call reg_set_color key (data-addr sn_str_128) (ptr-read-u64 s 592) (ptr-read-u64 (+ d 0) 592)) ok)) 0)
			 (if (= _done 0) (setq ok (and (extern-call reg_set_color key (data-addr sn_str_129) (ptr-read-u64 s 600) (ptr-read-u64 (+ d 0) 600)) ok)) 0)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_130) (ptr-read-u32 s 608)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_sz key (data-addr sn_str_131) (+ s 612)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_132) (ptr-read-u32 s 1132)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_sz key (data-addr sn_str_133) (+ s 1136)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_134) (ptr-read-u32 s 1656)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_135) (ptr-read-u32 s 1660)) ok)) 0)
       (if (= _done 0) (setq ok (and (extern-call reg_set_dword key (data-addr sn_str_136) (ptr-read-u32 s 1664)) ok)) 0)
       (if (= _done 0) (progn (setq _result ok) (setq _done 1)) 0))
     (extern-call g_free key)
     (extern-call g_free engine_key)
     (extern-call g_free d)
     _result))
 )
