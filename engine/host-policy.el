;;; host-policy.el --- Private HP2 policy decisions -*- lexical-binding: t; -*-
;; This process has no engine, public pipe, publication or learning API.
;; Inputs are bounded decimal value fields; never read/eval IPC as Lisp.

(defun host-policy-decision (kind a b c)
  "Compute a policy decision from copied native policy inputs."
  (cond ((= kind 1) (if (or (= a 0) (= b 1)) a 0)) ; runner availability
        ((= kind 2) (if (= a 0) 0 (if (= b 0) 2 1))) ; file before server
        ((= kind 3) (if (= b 1) 1000 (min 30000 (* a 2))))
        ((= kind 4) (if (>= b (if (= a 1) 60000 2000)) 1 0))
        ((= kind 5) (if (and (= a 1) (= b 1) (= c 1)) 1 0))
        ((= kind 6) (if (and (= a 1) (= b 1)) 1 0)) ; ready FIFO head, or drain
        ((= kind 7) (if (and (= a 1) (or (= b 0) (= c 1))) 1 0)) ; safe swap
        ((= kind 8) (if (or (< a 256) (= b 1)) 1 0)) ; cache admission
        ((= kind 9) (if (and (= a 1) (= b 1) (> c 0)) 1 0)) ; valid changed intent
        ((= kind 10) (if (= a 1) (if (= b 1) 1 0) (if (= b 1) 2 0))) ; files then server
        ((= kind 11) (if (= a 0) 0 (if (= b 1) 2 (if (= c 1) 1 0)))) ; base or overlay payload
        ((= kind 12) (if (= a 1) 60000 2000)) ; SK1 hit/miss duration
        (t -1)))

(defun host-policy-frame-into (line size numbers numeric)
  "Validate SIZE bytes in LINE, reusing NUMBERS and decimal strings in NUMERIC.
Metadata slots 8..10 hold prefix end and the raw kind's start/end indices."
  (let ((pos 6) (field 0))
    (unless (and (<= size 4096) (> size 6)
                 (= (aref line 0) 72) (= (aref line 1) 80)
                 (= (aref line 2) 49) (= (aref line 3) 32)
                 (= (aref line 4) 81) (= (aref line 5) 32))
      (error "HP1 framing"))
    (while (< field 8)
      (let ((start pos) (digit 0))
        (while (and (< pos size) (/= (aref line pos) 32))
          (let ((char (aref line pos)))
            (unless (and (>= char 48) (<= char 57)) (error "HP1 numeric field")))
          (setq digit (1+ digit) pos (1+ pos)))
        (unless (and (> pos start) (< pos size)) (error "HP1 numeric field"))
        ;; Cache exact-length decimal strings. Padding changes the runtime's
        ;; integer fast path and overflow semantics; arithmetic accumulation
        ;; would also change them. Allocate once per observed field length.
        (let ((scratch (or (aref numeric digit)
                           (aset numeric digit (make-string digit 48))))
              (copy 0))
          (while (< copy digit)
            (aset scratch copy (aref line (+ start copy)))
            (setq copy (1+ copy)))
          (aset numbers field (string-to-number scratch)))
        (when (= field 4)
          (aset numbers 8 pos) (aset numbers 9 start) (aset numbers 10 pos))
        (setq pos (1+ pos) field (1+ field))))
    (let ((context-size (- size pos)))
      (unless (or (and (= context-size 1) (= (aref line pos) 45))
                  (and (> context-size 0) (<= context-size 2048)
                       (= (% context-size 2) 0)
                       (let ((valid t))
                         (while (and valid (< pos size))
                           (let ((char (aref line pos)))
                             (unless (or (and (>= char 48) (<= char 57))
                                         (and (>= char 97) (<= char 102)))
                               (setq valid nil)))
                           (setq pos (1+ pos)))
                         valid)))
        (error "HP1 context")))
    (unless (and (>= (aref numbers 4) 1) (<= (aref numbers 4) 12))
      (error "HP1 kind"))
    numbers))

(defun host-policy-frame (line)
  "Compatibility entry point for finite framing probes; not used by the loop."
  (let* ((numbers (host-policy-frame-into line (length line)
                                         (make-vector 11 0) (make-vector 4097 nil)))
         (prefix (substring line 6 (aref numbers 8)))
         (kind (substring line (aref numbers 9) (aref numbers 10))))
    (aset numbers 8 kind)
    (cons numbers prefix)))

(defun host-policy-range-equal (text start end other)
  "Compare an indexed byte range without allocating a substring."
  (and other (= (- end start) (length other))
       (let ((i 0) (same t))
         (while (and same (< start end))
           (unless (= (aref text start) (aref other i)) (setq same nil))
           (setq start (1+ start) i (1+ i)))
         same)))

(defun host-policy-write-reply (line numbers decision reply)
  "Reuse REPLY storage; the byte writer requires one exact-length string."
  (let ((src 6) (dst 6)
        (value (cond ((= decision 0) "0") ((= decision 1) "1")
                     ((= decision 2) "2") ((= decision 1000) "1000")
                     ((= decision 2000) "2000") ((= decision 60000) "60000")
                     (t (number-to-string decision))))
        (i 0))
    (while (< src (aref numbers 8))
      (aset reply dst (aref line src))
      (setq src (1+ src) dst (1+ dst)))
    (aset reply dst 32) (setq dst (1+ dst))
    (while (< i (length value))
      (aset reply dst (aref value i))
      (setq i (1+ i) dst (1+ dst)))
    (aset reply dst 10)
    (nelisp--write-stdout-bytes (substring reply 0 (1+ dst)))))

(defun host-policy-hp2-number (frame offset)
  "Decode one bounded three-digit base-64 value without scanning."
  (let ((a (- (aref frame offset) 32))
        (b (- (aref frame (+ offset 1)) 32))
        (c (- (aref frame (+ offset 2)) 32)))
    (unless (and (>= (min a b c) 0) (<= (max a b c) 63))
      (error "HP2 digit"))
    (+ (* a 4096) (* b 64) c)))

(defun host-policy-hp2-reply (frame pause-kind)
  "Validate the fixed envelope and return its copied ID and numeric decision."
  (unless (and (= (length frame) 23)
               (equal (substring frame 0 4) "HP2Q")
               (= (aref frame 22) 10)
               (>= (aref frame 15) 33) (<= (aref frame 15) 44))
    (error "HP2 framing"))
  (let* ((kind (- (aref frame 15) 32))
         (decision (host-policy-decision kind
                     (if (or (= kind 3) (= kind 8))
                         (host-policy-hp2-number frame 19) (- (aref frame 16) 32))
                     (if (= kind 4) (host-policy-hp2-number frame 19) (- (aref frame 17) 32))
                     (- (aref frame 18) 32))))
    (when (and pause-kind (= kind pause-kind))
      (let ((until (+ (float-time) 3)))
        (while (< (float-time) until))))
    (concat "HP2R" (substring frame 4 15)
            (cond ((= decision 0) "   \n")
                  ((= decision 1) "  !\n")
                  ((= decision 2) "  \"\n")
                  ((= decision 1000) " /H\n")
                  ((= decision 2000) " ?0\n")
                  ((= decision 60000) ".I@\n")
                  (t (string (+ 32 (/ decision 4096))
                             (+ 32 (% (/ decision 64) 64))
                             (+ 32 (% decision 64)) 10))))))

(defun host-policy-serve ()
  "Serve HP2; framing loops advance by complete frames, never characters."
  (let* ((pending "") (bytes nil)
         (key (or (getenv "NATIVEIME_REGISTRY_KEY") ""))
         (pause-kind (and (equal (getenv "DDSKK_HARNESS_DIAGNOSTICS") "1")
                          (>= (length key) 24)
                          (equal (substring key 0 24) "Software\\NativeIME-test-")
                          (getenv "DDSKK_HOST_POLICY_TEST_PAUSE_KIND")
                          (string-to-number (getenv "DDSKK_HOST_POLICY_TEST_PAUSE_KIND")))))
    ;; Initialize every codec/decision branch before READY. The runtime lazily
    ;; allocates evaluator caches on first use; startup GC must follow that
    ;; initialization, rather than moving its growth collection into traffic.
    (let ((kind 1))
      (while (<= kind 12)
        (host-policy-hp2-reply
         (concat "HP2Q           " (string (+ 32 kind)) "!!\"___\n") nil)
        (setq kind (1+ kind))))
    (when (fboundp 'garbage-collect) (garbage-collect))
    (nelisp--write-stdout-bytes "HP2 READY\n")
    ;; A bounded read avoids the old 4096-byte scratch allocation. The native
    ;; adapter owns one outstanding correlation ID and retires timed-out IPC.
    (while (setq bytes (read-stdin-bytes 23))
      (setq pending (if (= (length pending) 0) bytes (concat pending bytes)))
      (while (>= (length pending) 23)
        (nelisp--write-stdout-bytes
         (host-policy-hp2-reply (if (= (length pending) 23) pending
                                 (substring pending 0 23)) pause-kind))
        (setq pending (if (= (length pending) 23) "" (substring pending 23)))))
    (unless (= (length pending) 0) (error "HP2 truncated"))))

(unless (getenv "DDSKK_HOST_POLICY_UNIT_ONLY") (host-policy-serve))
