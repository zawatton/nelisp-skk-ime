;;; tlv-hosts.el --- test EXEs for the engine TLV decoder  -*- lexical-binding: t; -*-

;;; Commentary:

;; Builds, with nelisp, two Windows EXEs for tlv-e2e.sh:
;;
;;  tlv-client.exe  env TLV_MODE=file  TLV_FILE=<path>: decode one .bin with
;;                  ddskk-tlv.el and print the canonical dump line (same format
;;                  as ddskk::tlv::Dump in windows/src/engine_tlv.h), or
;;                  "DECODE-ERR <n>".
;;                  env TLV_MODE=pipe  DDSKK_PIPE_NAME=\\.\pipe\...: connect,
;;                  send "HELLO TLV 1", then KEY/CONTROL/RESET/PING; decode TLV
;;                  replies (or print text replies when the host refused TLV).
;;  tlv-stub-host.exe  named-pipe server (message mode, one client) replaying
;;                  golden .bin files from TLV_GOLDEN_DIR.  env TLV_STUB_NOTLV=1
;;                  makes it behave like a host without TLV support.

;;; Code:

(require 'cl-lib)
(let ((root (or (getenv "NELISP_ROOT")
                (error "set NELISP_ROOT to a NeLisp checkout"))))
  (add-to-list 'load-path (expand-file-name "lisp" root)))
(require 'nelisp-com-dsl)
(require 'nelisp-com-wstr-lib)
(add-to-list 'load-path (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))
(require 'ddskk-tlv)

(defconst th-imports
  '(("kernel32.dll" "ExitProcess" "GetProcessHeap" "HeapAlloc" "HeapFree"
     "WriteFile" "ReadFile" "GetStdHandle" "GetEnvironmentVariableW" "CreateFileW"
     "CloseHandle" "Sleep" "CreateNamedPipeW" "ConnectNamedPipe"
     "DisconnectNamedPipe" "SetNamedPipeHandleState" "GetLastError")))

(defvar th--lits nil)
(defun th/s (str)
  "Form giving the address of the NUL-terminated ASCII literal STR."
  (let ((e (assoc str th--lits)))
    (unless e
      (setq e (cons str (intern (format "thl_%d" (length th--lits)))))
      (push e th--lits))
    `(data-addr ,(cdr e))))
(defun th/p (str) `(o_s ,(th/s str)))
(defun th/lit-blobs () (mapcar (lambda (e) (nelisp-com-ascii-blob (cdr e) (car e))) (reverse th--lits)))

(defun th/common ()
  `((defun o_ch (c)
      (let ((n (ptr-read-u64 (data-addr ostate) 0)))
        (if (< n 65000)
            (seq (ptr-write-u8 (data-addr obuf) n c) (ptr-write-u64 (data-addr ostate) 0 (+ n 1)) 0)
          0)))
    (defun o_s (p)
      (let ((i 0)) (while (/= (ptr-read-u8 p i) 0) (seq (o_ch (ptr-read-u8 p i)) (setq i (+ i 1))))))
    (defun o_nl () (o_ch 10))
    (defun o_nib (d) (o_ch (if (< d 10) (+ 48 d) (+ 87 d))))
    (defun o_hexn (v n)
      (let ((p 1) (i 1))
        (seq (while (< i n) (seq (setq p (* p 16)) (setq i (+ i 1))))
             (while (> p 0)
               (seq (o_nib (logand (/ v p) 15)) (setq p (/ p 16))))
             0)))
    (defun o_dec (v0)
      (let ((v v0) (p 1))
        (seq (if (< v 0) (seq (o_ch 45) (setq v (- 0 v))) 0)
             (while (<= (* p 10) v) (setq p (* p 10)))
             (while (> p 0)
               (seq (o_ch (+ 48 (/ v p))) (setq v (- v (* (/ v p) p))) (setq p (/ p 10))))
             0)))
    (defun o_flush ()
      (seq (extern-call WriteFile (extern-call GetStdHandle (- 0 11)) (data-addr obuf)
                        (ptr-read-u64 (data-addr ostate) 0) (+ (data-addr ostate) 8) 0)
           (ptr-write-u64 (data-addr ostate) 0 0) 0))
    ;; UTF-16 units of BUF[off,off+len) as 4-digit hex, "-" when empty.
    (defun o_units (buf off len)
      (if (= len 0) (o_ch 45)
        (let ((i 0)) (while (< i (/ len 2)) (seq (o_hexn (ptr-read-u16 buf (+ off (* 2 i))) 4) (setq i (+ i 1)))))))
    (defun o_bytes (buf off len)
      (if (= len 0) (o_ch 45)
        (let ((i 0)) (while (< i len) (seq (o_hexn (ptr-read-u8 buf (+ off i)) 2) (setq i (+ i 1)))))))
    ;; Same format as ddskk::tlv::Dump.
    (defun dump_msg (buf m)
      (if (= ,(ddskk-tlv--f 'm 'kind) 2)
          (seq ,(th/p "kind=2 raw=") (o_bytes buf ,(ddskk-tlv--f 'm 'raw_off) ,(ddskk-tlv--f 'm 'raw_len)))
        (seq ,(th/p "kind=1 mode=") (o_units buf ,(ddskk-tlv--f 'm 'mode_off) ,(ddskk-tlv--f 'm 'mode_len))
             ,(th/p " cursor=") (o_dec ,(ddskk-tlv--f 'm 'cursor))
             ,(th/p " comp=") (o_dec ,(ddskk-tlv--f 'm 'comp))
             ,(th/p " text=") (o_units buf ,(ddskk-tlv--f 'm 'text_off) ,(ddskk-tlv--f 'm 'text_len))
             ,(th/p " pending=") (o_units buf ,(ddskk-tlv--f 'm 'pend_off) ,(ddskk-tlv--f 'm 'pend_len))
             ,(th/p " idx=") (o_dec ,(ddskk-tlv--f 'm 'idx))
             ,(th/p " ncand=") (o_dec ,(ddskk-tlv--f 'm 'ncand))
             ,(th/p " cands=")
             (if (= ,(ddskk-tlv--f 'm 'ncand) 0) (o_ch 45)
               (let ((i 0))
                 (while (< i ,(ddskk-tlv--f 'm 'ncand))
                   (seq (if (> i 0) (o_ch 44) 0)
                        (o_units buf (ptr-read-u64 (+ ,(nelisp-com-field-addr 'm 'DdskkTlv 'cand_off) (* 8 i)) 0)
                                 (ptr-read-u64 (+ ,(nelisp-com-field-addr 'm 'DdskkTlv 'cand_len) (* 8 i)) 0))
                        (setq i (+ i 1))))))
             ,(th/p " reg=")
             (if (= ,(ddskk-tlv--f 'm 'has_reg) 0) ,(th/p "none")
               (o_units buf ,(ddskk-tlv--f 'm 'reg_off) ,(ddskk-tlv--f 'm 'reg_len)))
             ,(th/p " seq=")
             (if (= ,(ddskk-tlv--f 'm 'has_seq) 0) ,(th/p "none") (o_dec ,(ddskk-tlv--f 'm 'seqn))))))
    ;; Decode BUF[0,size) and print the dump or DECODE-ERR n.
    (defun decode_print (buf size)
      (let ((m (tlv_new)))
        (if (= m 0) ,(th/p "OOM")
          (let ((err (tlv_decode buf size m)))
            (seq (if (= err 0) (dump_msg buf m) (seq ,(th/p "DECODE-ERR ") (o_dec err)))
                 (tlv_free m) 0)))))
    (defun heap_new (n) (extern-call HeapAlloc (extern-call GetProcessHeap) 8 n))
    ;; ReadFile whole file at wide PATH into BUF (cap bytes); returns size or -1.
    (defun read_file (path buf cap)
      (let ((h (extern-call CreateFileW path 2147483648 1 0 3 128 0)))
        (if (= h (- 0 1)) (- 0 1)
          (seq (ptr-write-u64 (data-addr ostate) 16 0)
               (extern-call ReadFile h buf cap (+ (data-addr ostate) 16) 0)
               (extern-call CloseHandle h)
               (logand (ptr-read-u64 (data-addr ostate) 16) 4294967295)))))
    (defun env_w (name buf cap) (logand (extern-call GetEnvironmentVariableW name buf cap) 4294967295))))

(defun th/blobs ()
  (list (nelisp-com-zero-blob 'obuf 65536) (nelisp-com-zero-blob 'ostate 32)
        (nelisp-com-zero-blob 'wbuf1 1040) (nelisp-com-zero-blob 'wbuf2 1040)
        (nelisp-com-wstr-blob 'w_mode "TLV_MODE") (nelisp-com-wstr-blob 'w_file "TLV_FILE")
        (nelisp-com-wstr-blob 'w_pipe "DDSKK_PIPE_NAME")
        (nelisp-com-wstr-blob 'w_gdir "TLV_GOLDEN_DIR")
        (nelisp-com-wstr-blob 'w_notlv "TLV_STUB_NOTLV")))

;;;; client

(defun th/client-forms ()
  (let ((reqs '(("KEY 97" . 6) ("CONTROL CONVERT" . 15) ("RESET" . 5) ("PING" . 4))))
    `((defun txn (h req n buf)
        ;; Returns the reply size (0 on failure); reply lands in BUF.
        (seq (extern-call WriteFile h req n (+ (data-addr ostate) 24) 0)
             (ptr-write-u64 (data-addr ostate) 16 0)
             (if (= (extern-call ReadFile h buf 65536 (+ (data-addr ostate) 16) 0) 0) 0
               (logand (ptr-read-u64 (data-addr ostate) 16) 4294967295))))
      (defun connect_pipe ()
        (let ((i 0) (h (- 0 1)))
          (seq (env_w (data-addr w_pipe) (data-addr wbuf1) 520)
               (while (and (< i 100) (= h (- 0 1)))
                 (seq (setq h (extern-call CreateFileW (data-addr wbuf1) 3221225472 0 0 3 0 0))
                      (if (= h (- 0 1)) (extern-call Sleep 100) 0)
                      (setq i (+ i 1))))
               h)))
      (defun pipe_main ()
        (let ((h (connect_pipe)) (buf (heap_new 131072)) (tlv 0))
          (if (= h (- 0 1)) (seq ,(th/p "FAIL connect") (o_nl) 3)
            (seq (ptr-write-u32 (data-addr ostate) 28 2)
                 (extern-call SetNamedPipeHandleState h (+ (data-addr ostate) 28) 0 0)
                 (let ((n (txn h ,(th/s "HELLO TLV 1") 11 buf)))
                   (seq (if (and (= n 8) (= (ptr-read-u8 buf 0) 79) (= (ptr-read-u8 buf 1) 75)) (setq tlv 1) 0)
                        ,(th/p "HELLO tlv=") (o_dec tlv) (o_nl)))
                 ,@(cl-loop for (r . n) in reqs collect
                            `(let ((n (txn h ,(th/s r) ,n buf)))
                               (seq ,(th/p (concat "REPLY " r ": "))
                                    (if (= n 0) ,(th/p "NO-REPLY")
                                      (if (= tlv 1) (decode_print buf n)
                                        (seq ,(th/p "TEXT ") (let ((i 0)) (while (< i n) (seq (o_ch (ptr-read-u8 buf i)) (setq i (+ i 1))))))))
                                    (o_nl))))
                 (txn h ,(th/s "SHUTDOWN") 8 buf)
                 0)))))))

(defun th/client-main ()
  `(defun _start ()
     (seq (let ((n (env_w (data-addr w_mode) (data-addr wbuf2) 8)))
            (if (and (>= n 1) (= (ptr-read-u16 (data-addr wbuf2) 0) 112)) ; "p"
                (seq (pipe_main) 0)
              (let ((buf (heap_new 131072)))
                (if (= (env_w (data-addr w_file) (data-addr wbuf1) 520) 0) ,(th/p "FAIL TLV_FILE")
                  (let ((sz (read_file (data-addr wbuf1) buf 131072)))
                    (if (< sz 0) ,(th/p "FAIL read")
                      (decode_print buf sz)))))))
          (o_nl) (o_flush) (extern-call ExitProcess 0))))

;;;; stub host

(defun th/stub-forms ()
  `((defun pfx (req n lit len)
      (let ((i 0) (ok (if (>= n len) 1 0)))
        (seq (while (and (= ok 1) (< i len))
               (seq (if (/= (ptr-read-u8 req i) (ptr-read-u8 lit i)) (setq ok 0) 0) (setq i (+ i 1))))
             ok)))
    ;; Build wide "<dir>\<name>.bin" in wbuf1.
    (defun golden_path (name nlen)
      (let ((n (env_w (data-addr w_gdir) (data-addr wbuf1) 520)) (i 0))
        (seq (ptr-write-u16 (data-addr wbuf1) (* 2 n) 92) (setq n (+ n 1))
             (while (< i nlen)
               (seq (ptr-write-u16 (data-addr wbuf1) (* 2 (+ n i)) (ptr-read-u8 name i)) (setq i (+ i 1))))
             (setq n (+ n nlen))
             (setq i 0)
             (while (< i 4)
               (seq (ptr-write-u16 (data-addr wbuf1) (* 2 (+ n i)) (ptr-read-u8 ,(th/s ".bin") i)) (setq i (+ i 1))))
             (ptr-write-u16 (data-addr wbuf1) (* 2 (+ n 4)) 0)
             0)))
    (defun send (pipe p n)
      (extern-call WriteFile pipe p n (+ (data-addr ostate) 24) 0))
    (defun send_golden (pipe name nlen out)
      (seq (golden_path name nlen)
           (let ((sz (read_file (data-addr wbuf1) out 65536)))
             (if (< sz 0) (send pipe ,(th/s "ERR stub-missing-golden") 23) (send pipe out sz)))))
    (defun _start ()
      (let ((pipe 0) (req (heap_new 9000)) (out (heap_new 70000)) (tlv 0) (go 1)
            (notlv (if (> (env_w (data-addr w_notlv) (data-addr wbuf2) 8) 0) 1 0)))
        (seq (env_w (data-addr w_pipe) (data-addr wbuf2) 520)
             (setq pipe (extern-call CreateNamedPipeW (data-addr wbuf2) 3 6 1 65536 65536 0 0))
             (if (= pipe (- 0 1)) (extern-call ExitProcess 3) 0)
             (extern-call ConnectNamedPipe pipe 0)
             (while (= go 1)
               (seq (ptr-write-u64 (data-addr ostate) 16 0)
                    (if (= (extern-call ReadFile pipe req 9000 (+ (data-addr ostate) 16) 0) 0) (setq go 0)
                      (let ((n (logand (ptr-read-u64 (data-addr ostate) 16) 4294967295)))
                        (if (pfx req n ,(th/s "SHUTDOWN") 8) (seq (send pipe ,(th/s "OK") 2) (setq go 0))
                          (if (pfx req n ,(th/s "HELLO TLV") 9)
                              (if (= notlv 1) (send pipe ,(th/s "ERR unknown-request") 19)
                                (seq (setq tlv 1) (send pipe ,(th/s "OK TLV 1") 8)))
                            (if (= tlv 0) (send pipe ,(th/s "STATE hiragana 0 -1 - - -1 -") 28)
                              (if (pfx req n ,(th/s "KEY ") 4) (send_golden pipe ,(th/s "state_preedit") 13 out)
                                (if (pfx req n ,(th/s "CONTROL CONVERT") 15) (send_golden pipe ,(th/s "state_candidate") 15 out)
                                  (if (pfx req n ,(th/s "RESET") 5) (send_golden pipe ,(th/s "state_idle") 10 out)
                                    (send_golden pipe ,(th/s "raw_ok") 6 out)))))))))))
             (extern-call DisconnectNamedPipe pipe)
             (extern-call ExitProcess 0))))))

(defun th-build (path kind)
  "Build the EXE of KIND (client or stub) at PATH."
  (let ((th--lits nil))
    (setq max-lisp-eval-depth (max max-lisp-eval-depth 100000))
    (let* ((forms (append (th/common)
                          (if (eq kind 'client)
                              (append (th/client-forms) (list (th/client-main)))
                            (th/stub-forms))
                          (ddskk-tlv-forms))))
      (nelisp-com-build-exe
       path (append (th/lit-blobs) (th/blobs) forms)
       (list (cons "kernel32.dll"
                   (delete-dups (append (cdr (assoc "kernel32.dll" th-imports))
                                        (cdr (assoc "kernel32.dll" ddskk-tlv-imports))))))))))

(provide 'tlv-hosts)
;;; tlv-hosts.el ends here
