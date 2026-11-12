;;; ddskk-engine-client.el --- named-pipe engine client for the native TSF DLL  -*- lexical-binding: t; -*-

;;; Commentary:

;; Stage S3f of the native TSF DLL project.  Restricted-Elisp (AOT) port of
;; windows/src/engine_client.cpp + engine_protocol.cpp, plus the TLV reply
;; path of docs/design/engine-tlv.md (decoder: ddskk-tlv.el) and
;; TextService::EnsureEngineHost (text_service.cpp 1349).
;;
;; Objects (process heap, zero-initialised):
;;   DdskkEc  client: pipe handle, TLV flag, needs_resync, session id,
;;            OVERLAPPED + event, 64 KiB+ receive buffer, request buffers.
;;   DdskkEs  decoded EngineState: a DdskkTlv object (field layout and string
;;            (offset,length) pairs of ddskk-tlv.el) plus DATA, a private copy
;;            of the string bytes (for a TLV reply: the received message; for
;;            a text STATE reply: UTF-16 units decoded from the hex fields).
;;            Strings are UTF-16 units at DATA+offset (ec_state_* accessors).
;;
;; Threading: a DdskkEc is NOT thread-safe.  Exactly one thread may be inside
;; ec_txn/ec_send_* of one client at a time (S3j: the UI thread, synchronous,
;; as in the C++ TextService).  A second thread (S3k provider) must own its own
;; client (ec_new gives each its own pipe and session id).  The receive buffer
;; is owned by the client and valid until the next transaction; callers get
;; EngineState copies (free them with ec_state_free).
;;
;; Deliberate differences from the C++ client:
;;  * HELLO TLV 1 is sent on every new connection (S4.1); any answer but
;;    exactly "OK TLV 1" keeps the text protocol.  Its timeout is at least 50 ms
;;    even for the 1 ms probe of EnsureEngineHost.
;;  * The receive buffer is 65536 bytes (the C++ text client read 8191).
;;  * A TLV decode failure is a hard failure like a pipe error: disconnect and
;;    needs_resync (RESET first on the next transaction).  A well-formed
;;    reply that is not a state (RAW) just returns no state, like
;;    ParseStateResponse failing, without resync.
;;  * ec_ensure_host has a spawn throttle (min interval argument); the C++
;;    function has none.  Spawn test hook = the registry values themselves
;;    (EngineHost pointing at a stub) and NELISP_IME_DISABLE_HOST_SPAWN.
;;  * Not ported: PreviewCandidates, ListEngines, CurrentEngine.  The C++
;;    client has no session export/restore, so there is nothing to port;
;;    hot-swap handle hand-over is deferred (see the S3f report).
;;
;; Last failure (ec_status): 0 ok  1 connect/HELLO failed  2 timeout
;;   3 pipe I/O error  4 TLV decode error (ec_derr = decoder code)
;;   5 reply is not a state  6 request could not be encoded

;;; Code:

(require 'cl-lib)
(require 'nelisp-com-dsl)
(require 'nelisp-com-wstr-lib)
(require 'ddskk-tlv)

(defconst ddskk-engine-client-imports
  '(("kernel32.dll" "GetProcessHeap" "HeapAlloc" "HeapFree" "HeapReAlloc"
     "WaitNamedPipeW" "CreateFileW" "SetNamedPipeHandleState" "CloseHandle"
     "CreateEventW" "ResetEvent" "WriteFile" "ReadFile" "GetLastError"
     "WaitForSingleObject" "GetOverlappedResult" "CancelIoEx" "GetTickCount64"
     "GetCurrentProcessId" "GetEnvironmentVariableW" "CreateProcessW")
    ("advapi32.dll" "RegOpenKeyExW" "RegQueryValueExW" "RegCloseKey"))
  "Imports needed by `ddskk-engine-client-forms'.")

(defconst ddskk-engine-client-controls
  '("BACKSPACE" "CONVERT" "PREVIOUS" "COMMIT" "CANCEL" "QUIT" "SEGMENT-PREV"
    "SEGMENT-NEXT" "SEGMENT-SHRINK" "SEGMENT-EXTEND" "TO-HIRAGANA" "TO-KATAKANA"
    "TO-HALF-KATAKANA" "TO-WIDE-LATIN" "TO-LATIN" "LEFT" "RIGHT" "HOME" "END"
    "DELETE")
  "EngineControl enumerators in declaration order (engine_protocol.h).")

(nelisp-com-defstruct DdskkEc
  (pipe i64) (tlv i64) (resync i64) (ev i64) (status i64) (io i64) (mode i64)
  (ovl (array i64 4)) (sess (array i64 4)) (sess_n i64)
  (rbuf i64) (rlen i64) (line i64) (lpos i64) (lover i64) (req i64) (rst i64)
  (wname i64) (last_spawn i64) (skip_reset i64) (derr i64) (l_off i64) (l_len i64)
  (tok (array i64 2)) (pok i64))

(nelisp-com-defstruct DdskkEs (tlv i64) (data i64) (size i64))

(defvar ddskk-engine-client--lits nil)

(defun ddskk-engine-client--lit (str)
  (let ((e (assoc str ddskk-engine-client--lits)))
    (unless e
      (setq e (cons str (intern (format "ecl_%d" (length ddskk-engine-client--lits)))))
      (push e ddskk-engine-client--lits))
    `(data-addr ,(cdr e))))

(defun ddskk-engine-client--walk (f)
  "Expand the (@ P F) (@= P F V) (@& P F) (@s ..) (@t ..) (L STR) sugar in F."
  (cond
   ((not (consp f)) f)
   ((eq (car f) '@) (nelisp-com-field (ddskk-engine-client--walk (nth 1 f)) 'DdskkEc (nth 2 f)))
   ((eq (car f) '@=) (nelisp-com-set-field (ddskk-engine-client--walk (nth 1 f)) 'DdskkEc (nth 2 f)
                                           (ddskk-engine-client--walk (nth 3 f))))
   ((eq (car f) '@&) (nelisp-com-field-addr (ddskk-engine-client--walk (nth 1 f)) 'DdskkEc (nth 2 f)))
   ((eq (car f) '@s) (nelisp-com-field (ddskk-engine-client--walk (nth 1 f)) 'DdskkEs (nth 2 f)))
   ((eq (car f) '@s=) (nelisp-com-set-field (ddskk-engine-client--walk (nth 1 f)) 'DdskkEs (nth 2 f)
                                            (ddskk-engine-client--walk (nth 3 f))))
   ((eq (car f) '@t) (ddskk-tlv--f (ddskk-engine-client--walk (nth 1 f)) (nth 2 f)))
   ((eq (car f) '@t=) (ddskk-tlv--s (ddskk-engine-client--walk (nth 1 f)) (nth 2 f)
                                    (ddskk-engine-client--walk (nth 3 f))))
   ((eq (car f) '@t&) (nelisp-com-field-addr (ddskk-engine-client--walk (nth 1 f)) 'DdskkTlv (nth 2 f)))
   ((eq (car f) 'L) (ddskk-engine-client--lit (nth 1 f)))
   (t (cons (ddskk-engine-client--walk (car f)) (ddskk-engine-client--walk (cdr f))))))

(defun ddskk-engine-client--control-chain ()
  (let ((chain 0) (i (length ddskk-engine-client-controls)))
    (dolist (name (reverse ddskk-engine-client-controls) chain)
      (setq i (1- i))
      (setq chain `(if (= ctl ,i) (ec_put_s ec (L ,(concat "CONTROL " name))) ,chain)))))

(defun ddskk-engine-client--raw-forms ()
  `(;; ---- byte helpers ----
    (defun ec_copy (dst dpos src spos n)
      (let ((i 0))
        (seq (while (< i n)
               (seq (ptr-write-u8 dst (+ dpos i) (ptr-read-u8 src (+ spos i))) (setq i (+ i 1))))
             n)))
    ;; 1 when BUF[off,off+n) equals the NUL-terminated ASCII LIT.
    (defun ec_match (buf off n lit)
      (let ((i 0) (ok 1))
        (seq (while (and (= ok 1) (/= (ptr-read-u8 lit i) 0))
               (seq (if (= (ptr-read-u8 buf (+ off i)) (ptr-read-u8 lit i)) 0 (setq ok 0))
                    (setq i (+ i 1))))
             (if (= ok 1) (if (= i n) 1 0) 0))))
    ;; ---- request line builder (ec.line, ASCII) ----
    (defun ec_begin (ec) (seq (@= ec lpos 0) (@= ec lover 0) 0))
    (defun ec_put_c (ec c)
      (let ((p (@ ec lpos)))
        (if (>= p 8000) (@= ec lover 1)
          (seq (ptr-write-u8 (@ ec line) p c) (@= ec lpos (+ p 1))))))
    (defun ec_put_s (ec s)
      (let ((i 0))
        (seq (while (/= (ptr-read-u8 s i) 0) (seq (ec_put_c ec (ptr-read-u8 s i)) (setq i (+ i 1)))) 0)))
    (defun ec_put_dec (ec v)
      (let ((p 1) (x v))
        (seq (while (<= (* p 10) x) (setq p (* p 10)))
             (while (> p 0)
               (seq (ec_put_c ec (+ 48 (/ x p))) (setq x (- x (* (/ x p) p))) (setq p (/ p 10))))
             0)))
    (defun ec_end (ec)
      (seq (ec_put_c ec 10) (if (/= (@ ec lover) 0) 0 (@ ec lpos))))
    ;; ---- request encoders (engine_protocol.cpp); each returns the length of
    ;; the line left in ec.line (including the newline) or 0 when the request
    ;; cannot be encoded ----
    (defun ec_enc_key (ec cp)
      (if (> cp 1114111) 0
        (seq (ec_begin ec) (ec_put_s ec (L "KEY ")) (ec_put_dec ec cp) (ec_end ec))))
    (defun ec_enc_keys (ec prefix keys n)
      (if (= n 0) 0
        (let ((i 0) (bad 0))
          (seq (ec_begin ec) (ec_put_s ec prefix)
               (while (and (= bad 0) (< i n))
                 (let ((k (ptr-read-u32 keys (* 4 i))))
                   (seq (if (> k 1114111) (setq bad 1) 0)
                        (if (and (>= k 55296) (<= k 57343)) (setq bad 1) 0)
                        (if (> i 0) (ec_put_c ec 44) 0)
                        (ec_put_dec ec k)
                        (setq i (+ i 1)))))
               (if (= bad 1) 0 (ec_end ec))))))
    (defun ec_enc_convert_keys (ec keys n) (ec_enc_keys ec (L "CONTROL CONVERT-KEYS ") keys n))
    (defun ec_enc_feed_keys (ec keys n) (ec_enc_keys ec (L "CONTROL FEED-KEYS ") keys n))
    (defun ec_enc_control (ec ctl)
      (if (or (< ctl 0) (>= ctl ,(length ddskk-engine-client-controls))) 0
        (seq (ec_begin ec) ,(ddskk-engine-client--control-chain) (ec_end ec))))
    (defun ec_enc_lit (ec lit) (seq (ec_begin ec) (ec_put_s ec lit) (ec_end ec)))
    ;; ---- session wrapping ----
    ;; "SESSION <id> <line>" into ec.req from the N-byte line in ec.line.
    (defun ec_session_req (ec n)
      (let ((req (@ ec req)) (sn (@ ec sess_n)))
        (seq (ec_copy req 0 (L "SESSION ") 0 8)
             (ec_copy req 8 (@& ec sess) 0 sn)
             (ptr-write-u8 req (+ 8 sn) 32)
             (ec_copy req (+ 9 sn) (@ ec line) 0 n)
             (+ (+ 9 sn) n))))
    (defun ec_build_reset (ec)
      (let ((rst (@ ec rst)) (sn (@ ec sess_n)))
        (seq (ec_copy rst 0 (L "SESSION ") 0 8)
             (ec_copy rst 8 (@& ec sess) 0 sn)
             (ec_copy rst (+ 8 sn) (L " RESET") 0 6)
             (ptr-write-u8 rst (+ 14 sn) 10)
             (+ 15 sn))))
    ;; ---- connection / overlapped I/O (engine_client.cpp RawTransact) ----
    (defun ec_disconnect (ec)
      (let ((p (@ ec pipe)))
        (seq (@= ec pipe 0) (@= ec tlv 0)
             (if (/= p 0) (extern-call CloseHandle p) 0)
             0)))
    (defun ec_ovl_init (ec)
      (let ((o (@& ec ovl)))
        (seq (ptr-write-u64 o 0 0) (ptr-write-u64 o 8 0) (ptr-write-u64 o 16 0)
             (ptr-write-u64 o 24 (@ ec ev))
             (extern-call ResetEvent (@ ec ev))
             (@= ec io 0)
             0)))
    ;; cancel_pending_and_fail (PENDING = 1) / fail_immediately (0)
    (defun ec_fail (ec pending status)
      (let ((pipe (@ ec pipe)) (o (@& ec ovl)))
        (seq (if (/= pending 0)
                 (seq (extern-call CancelIoEx pipe o)
                      (extern-call GetOverlappedResult pipe o (@& ec io) 1))
               0)
             (ec_disconnect ec)
             (@= ec resync 1)
             (@= ec status status)
             0)))
    ;; 1 completed, 0 timeout, 2 error
    (defun ec_io_wait (ec timeout)
      (let ((w (logand (extern-call WaitForSingleObject (@ ec ev) timeout) 4294967295)))
        (if (/= w 0) 0
          (let ((r (logand (extern-call GetOverlappedResult (@ ec pipe) (@& ec ovl) (@& ec io) 0)
                           4294967295)))
            (if (= r 0) 2 1)))))
    ;; Writes N bytes of P and reads one reply into ec.rbuf; reply size or -1.
    (defun ec_raw (ec p n timeout)
      (let ((pipe (@ ec pipe)))
        (if (= pipe 0) (seq (@= ec status 1) (- 0 1))
          (seq
           (ec_ovl_init ec)
           (let ((ok (logand (extern-call WriteFile pipe p n (@& ec io) (@& ec ovl)) 4294967295))
                 (err (logand (extern-call GetLastError) 4294967295)))
             (if (and (= ok 0) (/= err 997))
                 (seq (ec_fail ec 0 3) (- 0 1))
               (let ((r (ec_io_wait ec timeout)))
                 (if (or (/= r 1) (/= (@ ec io) n))
                     (seq (ec_fail ec 1 (if (= r 0) 2 3)) (- 0 1))
                   (seq
                    (extern-call ResetEvent (@ ec ev))
                    (@= ec io 0)
                    (let ((ok2 (logand (extern-call ReadFile pipe (@ ec rbuf) 65536 (@& ec io) (@& ec ovl))
                                       4294967295))
                          (err2 (logand (extern-call GetLastError) 4294967295)))
                      (if (and (= ok2 0) (/= err2 997))
                          (seq (ec_fail ec 0 3) (- 0 1))
                        (let ((r2 (ec_io_wait ec timeout)))
                          (if (/= r2 1)
                              (seq (ec_fail ec 1 (if (= r2 0) 2 3)) (- 0 1))
                            (seq (@= ec rlen (@ ec io)) (@= ec status 0) (@ ec io)))))))))))))))
    ;; Pipe name: DDSKK_PIPE_NAME (1..255 chars) or the default, into ec.wname.
    (defun ec_load_name (ec)
      (let ((w (@ ec wname)) (tmp (extern-call HeapAlloc (extern-call GetProcessHeap) 8 1024)))
        (if (= tmp 0) 0
          (let ((n (logand (extern-call GetEnvironmentVariableW (data-addr ec_w_pipeenv) tmp 256)
                           4294967295)))
            (seq (wbuf_clear w)
                 (if (and (> n 0) (< n 256)) (wbuf_append_w w tmp)
                   (wbuf_append_w w (data-addr ec_w_pipedef)))
                 (extern-call HeapFree (extern-call GetProcessHeap) 0 tmp)
                 1)))))
    ;; Connect(timeout): 1 when connected (HELLO TLV 1 negotiated or refused).
    ;; Uses ec.rst for the HELLO so a pending request line in ec.line survives.
    (defun ec_connect (ec timeout)
      (if (/= (@ ec pipe) 0) 1
        (seq
         (ec_load_name ec)
         (let ((name (wbuf_ptr (@ ec wname))))
           (let ((ok (logand (extern-call WaitNamedPipeW name timeout) 4294967295)))
             (if (= ok 0) (seq (@= ec status 1) 0)
               (let ((h (extern-call CreateFileW name 3221225472 0 0 3 1073741952 0)))
                 (if (= h (- 0 1)) (seq (@= ec status 1) 0)
                   (seq
                    (@= ec pipe h)
                    (@= ec mode 2)
                    (if (= (logand (extern-call SetNamedPipeHandleState h (@& ec mode) 0 0) 4294967295) 0)
                        (seq (ec_disconnect ec) (@= ec status 1) 0)
                      (let ((to (if (< timeout 50) 50 timeout)))
                        (seq (ec_copy (@ ec rst) 0 (L "HELLO TLV 1\n") 0 12)
                             (let ((rn (ec_raw ec (@ ec rst) 12 to)))
                               (if (< rn 0) (seq (@= ec status 1) 0)
                                 (seq (@= ec tlv (ec_match (@ ec rbuf) 0 rn (L "OK TLV 1")))
                                      1)))))))))))))))
    ;; RESET first when a previous transaction failed; 1 = clear to proceed.
    (defun ec_pre_reset (ec timeout)
      (if (= (@ ec resync) 0) 1
        (if (/= (@ ec skip_reset) 0) (seq (@= ec resync 0) 1)
          (let ((rn (ec_build_reset ec)))
            (if (< (ec_raw ec (@ ec rst) rn timeout) 0) 0
              (seq (@= ec resync 0) 1))))))
    ;; Transact: N = length of the bare line in ec.line.  Reply size or -1.
    (defun ec_txn (ec n timeout)
      (if (= n 0) (seq (@= ec status 6) (- 0 1))
        (if (= (ec_connect ec timeout) 0) (- 0 1)
          (let ((rn (ec_session_req ec n)))
            (if (= (ec_pre_reset ec timeout) 0) (- 0 1)
              (ec_raw ec (@ ec req) rn timeout))))))))

(defun ddskk-engine-client--text-forms ()
  `(;; ---- text STATE parser (ParseStateResponse) ----
    ;; k-th whitespace-delimited token of BUF[0,n) -> ec.tok; 1 when found.
    (defun tx_tok (ec buf n k)
      (let ((i 0) (cnt 0) (found 0) (s 0))
        (seq (while (and (= found 0) (< i n))
               (seq (while (and (< i n) (<= (ptr-read-u8 buf i) 32)) (setq i (+ i 1)))
                    (if (< i n)
                        (seq (setq s i)
                             (while (and (< i n) (> (ptr-read-u8 buf i) 32)) (setq i (+ i 1)))
                             (if (= cnt k)
                                 (seq (setq found 1)
                                      (ptr-write-u64 (@& ec tok) 0 s)
                                      (ptr-write-u64 (@& ec tok) 8 i))
                               (setq cnt (+ cnt 1))))
                      0)))
             found)))
    (defun tx_ts (ec) (ptr-read-u64 (@& ec tok) 0))
    (defun tx_te (ec) (ptr-read-u64 (@& ec tok) 8))
    (defun tx_hexd (c)
      (if (and (>= c 48) (<= c 57)) (- c 48)
        (if (and (>= c 97) (<= c 102)) (- c 87)
          (if (and (>= c 65) (<= c 70)) (- c 55) (- 0 1)))))
    ;; Decimal int (optional '-') of BUF[s,e); sets ec.pok.
    (defun tx_int (ec buf s e)
      (let ((i s) (neg 0) (v 0) (ok 1))
        (seq (if (and (< i e) (= (ptr-read-u8 buf i) 45)) (seq (setq neg 1) (setq i (+ i 1))) 0)
             (if (or (>= i e) (> (- e i) 10)) (setq ok 0) 0)
             (while (and (= ok 1) (< i e))
               (let ((d (- (ptr-read-u8 buf i) 48)))
                 (seq (if (or (< d 0) (> d 9)) (setq ok 0) (setq v (+ (* v 10) d)))
                      (setq i (+ i 1)))))
             (@= ec pok ok)
             (if (= neg 1) (- 0 v) v))))
    ;; Scalar-hex string BUF[s,e) -> UTF-16 units appended to DATA at byte DP;
    ;; "-" = empty.  Returns the new DP or -1.
    (defun tx_hex (buf s e data dp)
      (let ((len (- e s)))
        (if (= len 0) dp
          (if (and (= len 1) (= (ptr-read-u8 buf s) 45)) dp
            (if (/= (- len (* 6 (/ len 6))) 0) (- 0 1)
              (let ((i s) (out dp) (bad 0))
                (seq (while (and (= bad 0) (< i e))
                       (let ((v 0) (j 0))
                         (seq (while (and (= bad 0) (< j 6))
                                (let ((d (tx_hexd (ptr-read-u8 buf (+ i j)))))
                                  (seq (if (< d 0) (setq bad 1) (setq v (+ (* v 16) d)))
                                       (setq j (+ j 1)))))
                              (if (or (> v 1114111) (and (>= v 55296) (<= v 57343))) (setq bad 1) 0)
                              (if (= bad 0)
                                  (if (<= v 65535)
                                      (seq (ptr-write-u16 data out v) (setq out (+ out 2)))
                                    (let ((w (- v 65536)))
                                      (seq (ptr-write-u16 data out (+ 55296 (/ w 1024)))
                                           (ptr-write-u16 data (+ out 2)
                                                          (+ 56320 (- w (* 1024 (/ w 1024)))))
                                           (setq out (+ out 4)))))
                                0)
                              (setq i (+ i 6)))))
                     (if (= bad 1) (- 0 1) out))))))))
    ;; Parses the N-byte text STATE reply in BUF into M (DdskkTlv) and DATA.
    ;; 1 on success.
    (defun tx_parse (ec buf n m data)
      (let ((ok 1) (dp 0) (nf 0))
        (seq
         (if (= (tx_tok ec buf n 0) 1)
             (if (/= (ec_match buf (tx_ts ec) (- (tx_te ec) (tx_ts ec)) (L "STATE")) 1) (setq ok 0) 0)
           (setq ok 0))
         ;; field count: 8 or 9
         (if (= ok 1) (if (= (tx_tok ec buf n 7) 1) 0 (setq ok 0)) 0)
         (if (= ok 1) (if (= (tx_tok ec buf n 9) 1) (setq ok 0) 0) 0)
         (if (= ok 1) (if (= (tx_tok ec buf n 8) 1) (setq nf 9) (setq nf 8)) 0)
         ;; mode (field 1)
         (if (= ok 1)
             (seq (tx_tok ec buf n 1)
                  (let ((s (tx_ts ec)) (e (tx_te ec)) (i 0))
                    (seq (if (and (= nf 9) (/= (ec_match buf s (- e s) (L "registration")) 1)) (setq ok 0) 0)
                         (@t= m mode_off dp)
                         (while (< (+ s i) e)
                           (seq (ptr-write-u16 data dp (ptr-read-u8 buf (+ s i)))
                                (setq dp (+ dp 2)) (setq i (+ i 1))))
                         (@t= m mode_len (* 2 i)))))
           0)
         ;; cursor, comp_start, candidate index
         (if (= ok 1)
             (seq (tx_tok ec buf n 2)
                  (@t= m cursor (tx_int ec buf (tx_ts ec) (tx_te ec)))
                  (if (= (@ ec pok) 0) (setq ok 0) 0)
                  (tx_tok ec buf n 3)
                  (@t= m comp (tx_int ec buf (tx_ts ec) (tx_te ec)))
                  (if (= (@ ec pok) 0) (setq ok 0) 0)
                  (tx_tok ec buf n 6)
                  (@t= m idx (tx_int ec buf (tx_ts ec) (tx_te ec)))
                  (if (= (@ ec pok) 0) (setq ok 0) 0))
           0)
         ;; text, pending
         (if (= ok 1)
             (seq (tx_tok ec buf n 4)
                  (@t= m text_off dp)
                  (setq dp (tx_hex buf (tx_ts ec) (tx_te ec) data dp))
                  (if (< dp 0) (setq ok 0) (@t= m text_len (- dp (@t m text_off)))))
           0)
         (if (= ok 1)
             (seq (tx_tok ec buf n 5)
                  (@t= m pend_off dp)
                  (setq dp (tx_hex buf (tx_ts ec) (tx_te ec) data dp))
                  (if (< dp 0) (setq ok 0) (@t= m pend_len (- dp (@t m pend_off)))))
           0)
         ;; candidates (field 7): "-" or comma separated hex strings
         (if (= ok 1)
             (seq (tx_tok ec buf n 7)
                  (let ((s (tx_ts ec)) (e (tx_te ec)))
                    (if (and (= (- e s) 1) (= (ptr-read-u8 buf s) 45)) 0
                      (let ((a s) (b s) (done 0) (cnt 0))
                        (seq
                         (while (and (= ok 1) (= done 0))
                           (seq (setq b a)
                                (while (and (< b e) (/= (ptr-read-u8 buf b) 44)) (setq b (+ b 1)))
                                (if (>= cnt ,ddskk-tlv-max-cands) (setq ok 0)
                                  (let ((start dp))
                                    (seq (setq dp (tx_hex buf a b data dp))
                                         (if (< dp 0) (setq ok 0)
                                           (seq (ptr-write-u64 (+ (@t& m cand_off) (* 8 cnt)) 0 start)
                                                (ptr-write-u64 (+ (@t& m cand_len) (* 8 cnt)) 0 (- dp start))
                                                (setq cnt (+ cnt 1)))))))
                                (if (>= b e) (setq done 1) (setq a (+ b 1)))))
                         (@t= m ncand cnt))))))
           0)
         ;; registration reading
         (if (and (= ok 1) (= nf 9))
             (seq (tx_tok ec buf n 8)
                  (@t= m reg_off dp)
                  (setq dp (tx_hex buf (tx_ts ec) (tx_te ec) data dp))
                  (if (< dp 0) (setq ok 0) (seq (@t= m reg_len (- dp (@t m reg_off))) (@t= m has_reg 1))))
           0)
         (@t= m kind 1)
         ok)))))

(defun ddskk-engine-client--state-forms ()
  `(;; ---- EngineState ----
    (defun ec_state_free (es)
      (if (= es 0) 0
        (let ((h (extern-call GetProcessHeap)))
          (seq (if (/= (@s es tlv) 0) (tlv_free (@s es tlv)) 0)
               (if (/= (@s es data) 0) (extern-call HeapFree h 0 (@s es data)) 0)
               (extern-call HeapFree h 0 es)
               0))))
    (defun ec_state_new ()
      (let ((es (DdskkEs_alloc)))
        (if (= es 0) 0
          (let ((m (tlv_new)))
            (if (= m 0) (seq (ec_state_free es) 0)
              (seq (@s= es tlv m) es))))))
    ;; accessors: strings are UTF-16 units at (ec_state_data es)+offset
    (defun ec_state_tlv (es) (@s es tlv))
    (defun ec_state_data (es) (@s es data))
    (defun ec_state_cursor (es) (@t (@s es tlv) cursor))
    (defun ec_state_comp (es) (@t (@s es tlv) comp))
    (defun ec_state_idx (es) (@t (@s es tlv) idx))
    (defun ec_state_ncand (es) (@t (@s es tlv) ncand))
    (defun ec_state_text_ptr (es) (+ (@s es data) (@t (@s es tlv) text_off)))
    (defun ec_state_text_len (es) (/ (@t (@s es tlv) text_len) 2))
    (defun ec_state_mode_ptr (es) (+ (@s es data) (@t (@s es tlv) mode_off)))
    (defun ec_state_mode_len (es) (/ (@t (@s es tlv) mode_len) 2))
    (defun ec_state_pend_ptr (es) (+ (@s es data) (@t (@s es tlv) pend_off)))
    (defun ec_state_pend_len (es) (/ (@t (@s es tlv) pend_len) 2))
    ;; Builds a private EngineState from the N-byte reply in ec.rbuf, or 0 with
    ;; ec.status set (4 decode error + resync, 5 not a state).
    (defun ec_make_state (ec n)
      (let ((es (ec_state_new)))
        (if (= es 0) (seq (@= ec status 3) 0)
          (let ((m (@s es tlv)) (h (extern-call GetProcessHeap)))
            (let ((data (extern-call HeapAlloc h 8 (+ (* 2 n) 64))))
              (if (= data 0) (seq (ec_state_free es) (@= ec status 3) 0)
                (seq
                 (@s= es data data)
                 (@s= es size n)
                 (if (/= (@ ec tlv) 0)
                     (let ((err (tlv_decode (@ ec rbuf) n m)))
                       (if (/= err 0)
                           (seq (@= ec derr err) (ec_state_free es) (ec_disconnect ec)
                                (@= ec resync 1) (@= ec status 4) 0)
                         (if (/= (@t m kind) 1)
                             (seq (ec_state_free es) (@= ec status 5) 0)
                           (seq (ec_copy data 0 (@ ec rbuf) 0 n) (@= ec status 0) es))))
                   (if (= (tx_parse ec (@ ec rbuf) n m data) 1)
                       (seq (@= ec status 0) es)
                     (seq (ec_state_free es) (@= ec status 5) 0))))))))))
    ;; txn + state
    (defun ec_state_txn (ec n timeout)
      (let ((rn (ec_txn ec n timeout)))
        (if (< rn 0) 0 (ec_make_state ec rn))))
    (defun ec_send_key (ec cp timeout)
      (let ((n (ec_enc_key ec cp))) (ec_state_txn ec n timeout)))
    (defun ec_send_keys (ec keys cnt timeout)
      (let ((n (ec_enc_feed_keys ec keys cnt))) (ec_state_txn ec n timeout)))
    (defun ec_convert_keys (ec keys cnt timeout)
      (let ((n (ec_enc_convert_keys ec keys cnt))) (ec_state_txn ec n timeout)))
    (defun ec_send_control (ec ctl timeout)
      (let ((n (ec_enc_control ec ctl))) (ec_state_txn ec n timeout)))
    ;; RESET is the recovery primitive: failure leaves needs_resync set.
    (defun ec_reset (ec timeout)
      (let ((es (ec_state_txn ec (ec_enc_lit ec (L "RESET")) timeout)))
        (seq (if (= es 0) (@= ec resync 1) 0) es)))
    ;; Reply line (RAW kind or text) of the N-byte reply -> ec.l_off/l_len; 1/0.
    (defun ec_reply_line (ec n)
      (if (= (@ ec tlv) 0) (seq (@= ec l_off 0) (@= ec l_len n) 1)
        (let ((m (tlv_new)))
          (if (= m 0) 0
            (let ((err (tlv_decode (@ ec rbuf) n m)))
              (let ((ok (if (= err 0) (if (= (@t m kind) 2) 1 0) 0)))
                (seq (if (= ok 1) (seq (@= ec l_off (@t m raw_off)) (@= ec l_len (@t m raw_len))) 0)
                     (tlv_free m)
                     ok)))))))
    (defun ec_id_ok (id)
      (let ((i 0) (ok 1))
        (seq (if (= (ptr-read-u8 id 0) 0) (setq ok 0) 0)
             (while (and (= ok 1) (/= (ptr-read-u8 id i) 0))
               (let ((c (ptr-read-u8 id i)))
                 (seq (if (or (and (>= c 97) (<= c 122)) (and (>= c 65) (<= c 90))
                              (and (>= c 48) (<= c 57)) (= c 45) (= c 95))
                          0 (setq ok 0))
                      (setq i (+ i 1)))))
             ok)))
    ;; SelectEngine: ID is a NUL-terminated ASCII string.
    (defun ec_select_engine (ec id timeout)
      (if (= (ec_id_ok id) 0) 0
        (let ((n (seq (ec_begin ec) (ec_put_s ec (L "ENGINE SET ")) (ec_put_s ec id) (ec_end ec))))
          (let ((rn (ec_txn ec n timeout)))
            (if (< rn 0) 0
              (if (= (ec_reply_line ec rn) 0) 0
                (let ((off (@ ec l_off)) (len (@ ec l_len)))
                  (seq (ec_begin ec) (ec_put_s ec (L "OK ENGINE ")) (ec_put_s ec id)
                       (ptr-write-u8 (@ ec line) (@ ec lpos) 0)
                       (ec_match (@ ec rbuf) off len (@ ec line))))))))))
    ;; Ping: any reply to GC within the timeout.
    (defun ec_ping (ec timeout)
      (if (< (ec_txn ec (ec_enc_lit ec (L "GC")) timeout) 0) 0 1))))

(defun ddskk-engine-client--host-forms ()
  `(;; ---- EnsureEngineHost ----
    ;; Reads registry value NAME (REG_SZ) into the zeroed 64 KiB DEST; length in
    ;; UTF-16 units (0 when missing).
    (defun ec_reg_read (hk name dest)
      (let ((bp (extern-call HeapAlloc (extern-call GetProcessHeap) 8 8)))
        (if (= bp 0) 0
          (seq (ptr-write-u32 bp 0 65534)
               (let ((rc (logand (extern-call RegQueryValueExW hk name 0 0 dest bp) 4294967295)))
                 (seq (extern-call HeapFree (extern-call GetProcessHeap) 0 bp)
                      (if (= rc 0) (wbuf_wcslen dest) 0)))))))
    (defun ec_spawn (ec)
      (let ((h (extern-call GetProcessHeap)) (hk (extern-call HeapAlloc (extern-call GetProcessHeap) 8 8)))
        (if (= (logand (extern-call RegOpenKeyExW 2147483649 (data-addr ec_w_key) 0 131097 hk) 4294967295) 0)
            (let ((key (ptr-read-u64 hk 0))
                  (host (extern-call HeapAlloc h 8 65536)) (exe (extern-call HeapAlloc h 8 65536))
                  (repo (extern-call HeapAlloc h 8 65536)) (cmd (wbuf_new 300))
                  (sinfo (extern-call HeapAlloc h 8 104)) (pinfo (extern-call HeapAlloc h 8 24)))
              (let ((nh (ec_reg_read key (data-addr ec_w_host) host))
                    (ne (ec_reg_read key (data-addr ec_w_exe) exe)))
                (seq
                 (if (= ne 0) (setq ne (ec_reg_read key (data-addr ec_w_nelisp) exe)) 0)
                 (let ((nr (ec_reg_read key (data-addr ec_w_repo) repo)) (started 0))
                   (seq
                    (extern-call RegCloseKey key)
                    (if (and (> nh 0) (> ne 0))
                        (seq (wbuf_append_char cmd 34) (wbuf_append_w cmd host) (wbuf_append_char cmd 34)
                             (wbuf_append_char cmd 32)
                             (wbuf_append_char cmd 34) (wbuf_append_w cmd exe) (wbuf_append_char cmd 34)
                             (if (> nr 0)
                                 (seq (wbuf_append_char cmd 32) (wbuf_append_char cmd 34)
                                      (wbuf_append_w cmd repo) (wbuf_append_char cmd 34))
                               0)
                             (ptr-write-u32 sinfo 0 104)
                             (ptr-write-u32 sinfo 60 1)
                             (ptr-write-u16 sinfo 64 0)
                             (let ((cwd (if (> nr 0) repo 0)))
                               (if (/= (logand (extern-call CreateProcessW 0 (wbuf_ptr cmd) 0 0 0 0 0
                                                            cwd sinfo pinfo)
                                               4294967295) 0)
                                   (seq (extern-call CloseHandle (ptr-read-u64 pinfo 0))
                                        (extern-call CloseHandle (ptr-read-u64 pinfo 8))
                                        (setq started 1))
                                 0)))
                      0)
                    (wbuf_free cmd)
                    (extern-call HeapFree h 0 host) (extern-call HeapFree h 0 exe)
                    (extern-call HeapFree h 0 repo) (extern-call HeapFree h 0 sinfo)
                    (extern-call HeapFree h 0 pinfo) (extern-call HeapFree h 0 hk)
                    started)))))
          (seq (extern-call HeapFree h 0 hk) 0))))
    ;; Spawns the engine host described by HKCU\Software\NativeIME (EngineHost,
    ;; EngineExecutable or NeLisp, Repository) unless the host is already
    ;; reachable, spawning is disabled by NELISP_IME_DISABLE_HOST_SPAWN=1, or
    ;; the previous spawn was less than MIN-INTERVAL ms ago.  1 = CreateProcessW
    ;; succeeded.
    (defun ec_ensure_host (ec min_interval)
      (if (/= (ec_connect ec 1) 0) 0
        (let ((h (extern-call GetProcessHeap)) (dis (extern-call HeapAlloc (extern-call GetProcessHeap) 8 16)))
          (let ((dn (logand (extern-call GetEnvironmentVariableW (data-addr ec_w_disable) dis 2) 4294967295)))
            (let ((off (if (> dn 0) (if (= (ptr-read-u16 dis 0) 49) 1 0) 0))
                  (now (extern-call GetTickCount64)))
              (seq (extern-call HeapFree h 0 dis)
                   (if (= off 1) 0
                     (if (and (/= (@ ec last_spawn) 0) (< (- now (@ ec last_spawn)) min_interval)) 0
                       (seq (@= ec last_spawn (if (= now 0) 1 now))
                            (ec_spawn ec))))))))))))

(defun ddskk-engine-client--life-forms ()
  `(;; ---- life cycle ----
    (defun ec_free (ec)
      (if (= ec 0) 0
        (let ((h (extern-call GetProcessHeap)))
          (seq (ec_disconnect ec)
               (if (/= (@ ec ev) 0) (extern-call CloseHandle (@ ec ev)) 0)
               (if (/= (@ ec rbuf) 0) (extern-call HeapFree h 0 (@ ec rbuf)) 0)
               (if (/= (@ ec line) 0) (extern-call HeapFree h 0 (@ ec line)) 0)
               (if (/= (@ ec req) 0) (extern-call HeapFree h 0 (@ ec req)) 0)
               (if (/= (@ ec rst) 0) (extern-call HeapFree h 0 (@ ec rst)) 0)
               (if (/= (@ ec wname) 0) (wbuf_free (@ ec wname)) 0)
               (extern-call HeapFree h 0 ec)
               0))))
    (defun ec_new ()
      (let ((ec (DdskkEc_alloc)) (h (extern-call GetProcessHeap)))
        (if (= ec 0) 0
          (seq
           (@= ec ev (extern-call CreateEventW 0 1 0 0))
           (@= ec rbuf (extern-call HeapAlloc h 8 65544))
           (@= ec line (extern-call HeapAlloc h 8 8200))
           (@= ec req (extern-call HeapAlloc h 8 8400))
           (@= ec rst (extern-call HeapAlloc h 8 128))
           (@= ec wname (wbuf_new 300))
           (if (or (= (@ ec ev) 0) (= (@ ec rbuf) 0) (= (@ ec line) 0) (= (@ ec req) 0)
                   (= (@ ec rst) 0) (= (@ ec wname) 0))
               (seq (ec_free ec) 0)
             (let ((ctr (+ (ptr-read-u64 (data-addr ec_ctr) 0) 1)))
               (seq (ptr-write-u64 (data-addr ec_ctr) 0 ctr)
                    ;; session id "<pid>-<n>"
                    (ec_begin ec)
                    (ec_put_dec ec (logand (extern-call GetCurrentProcessId) 4294967295))
                    (ec_put_c ec 45)
                    (ec_put_dec ec ctr)
                    (@= ec sess_n (@ ec lpos))
                    (ec_copy (@& ec sess) 0 (@ ec line) 0 (@ ec lpos))
                    ec)))))))
    (defun ec_status (ec) (@ ec status))
    (defun ec_line_ptr (ec) (@ ec line))
    (defun ec_derr (ec) (@ ec derr))
    (defun ec_needs_resync (ec) (@ ec resync))
    (defun ec_is_tlv (ec) (@ ec tlv))
    (defun ec_set_skip_reset (ec v) (@= ec skip_reset v))
    ;; ---- hook adapters for ddskk-core (hook slots engine-connect/engine-select) ----
    (defun ec_global ()
      (let ((ec (ptr-read-u64 (data-addr ec_g) 0)))
        (if (/= ec 0) ec
          (let ((n (ec_new))) (seq (ptr-write-u64 (data-addr ec_g) 0 n) n)))))
    ;; kInteractiveTimeoutMs = 350
    (defun ec_hook_connect (ts)
      (let ((ec (ec_global))) (if (= ec 0) 0 (ec_connect ec 350))))
    ;; target: engine kind 0 ddskk 1 lattice 2 dictionary 3 passthrough
    (defun ec_hook_select (ts target)
      (let ((ec (ec_global)))
        (if (= ec 0) 0
          (if (= target 0) (ec_select_engine ec (L "ddskk") 1000)
            (if (= target 1) (ec_select_engine ec (L "lattice") 1000)
              (if (= target 2) (ec_select_engine ec (L "dictionary") 1000)
                (if (= target 3) (ec_select_engine ec (L "passthrough") 1000) 0)))))))))

(defun ddskk-engine-client-forms ()
  "Return the AOT forms (functions and data blobs) of the engine client."
  (let ((ddskk-engine-client--lits nil))
    (let ((forms (ddskk-engine-client--walk
                  (append (ddskk-engine-client--raw-forms)
                          (ddskk-engine-client--text-forms)
                          (ddskk-engine-client--state-forms)
                          (ddskk-engine-client--host-forms)
                          (ddskk-engine-client--life-forms)))))
      (append
       (nelisp-com-struct-forms 'DdskkEc)
       (nelisp-com-struct-forms 'DdskkEs)
       (list (nelisp-com-zero-blob 'ec_ctr 8) (nelisp-com-zero-blob 'ec_g 8)
             (nelisp-com-wstr-blob 'ec_w_pipeenv "DDSKK_PIPE_NAME")
             (nelisp-com-wstr-blob 'ec_w_pipedef "\\\\.\\pipe\\ddskk-ime-v1")
             (nelisp-com-wstr-blob 'ec_w_disable "NELISP_IME_DISABLE_HOST_SPAWN")
             (nelisp-com-wstr-blob 'ec_w_key "Software\\NativeIME")
             (nelisp-com-wstr-blob 'ec_w_host "EngineHost")
             (nelisp-com-wstr-blob 'ec_w_exe "EngineExecutable")
             (nelisp-com-wstr-blob 'ec_w_nelisp "NeLisp")
             (nelisp-com-wstr-blob 'ec_w_repo "Repository"))
       (mapcar (lambda (e) (nelisp-com-ascii-blob (cdr e) (car e)))
               (reverse ddskk-engine-client--lits))
       forms))))

(defun ddskk-engine-client-all-forms ()
  "Engine client forms with the TLV decoder and wbuf library they depend on."
  (append (nelisp-com-wstr-lib-forms) (ddskk-tlv-forms) (ddskk-engine-client-forms)))

(defun ddskk-engine-client-all-imports ()
  "Merged import alist of the client, the TLV decoder and the wbuf library."
  (let ((acc nil))
    (dolist (src (list ddskk-engine-client-imports ddskk-tlv-imports
                       nelisp-com-wstr-lib-imports))
      (dolist (e src)
        (let ((cell (assoc (car e) acc)))
          (if cell (setcdr cell (delete-dups (append (cdr cell) (cdr e))))
            (push (cons (car e) (copy-sequence (cdr e))) acc)))))
    (nreverse acc)))

(provide 'ddskk-engine-client)
;;; ddskk-engine-client.el ends here
