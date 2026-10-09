;;; host-policy.el --- Private HP1 policy decisions -*- lexical-binding: t; -*-
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

(defun host-policy-newline (bytes start)
  "Find the next literal newline without the runtime regexp matcher."
  (let ((end (length bytes)))
    (while (and (< start end) (/= (aref bytes start) 10))
      (setq start (1+ start)))
    (if (< start end) start nil)))

(defun host-policy-frame (line)
  "Validate an HP1 frame, returning numeric fields and the copied reply prefix.
Scan the bounded ASCII grammar once; never parse IPC as Lisp."
  (let ((size (length line)) (pos 6) (field 0)
        (numbers (make-vector 9 0)) (prefix-end 0))
    (unless (and (<= size 4096) (> size 6)
                 (equal (substring line 0 6) "HP1 Q "))
      (error "HP1 framing"))
    (while (< field 8)
      (let ((start pos))
        (while (and (< pos size) (/= (aref line pos) 32))
          (let ((char (aref line pos)))
            (unless (and (>= char 48) (<= char 57)) (error "HP1 numeric field")))
          (setq pos (1+ pos)))
        (unless (and (> pos start) (< pos size)) (error "HP1 numeric field"))
        ;; Keep the image's existing integer conversion/overflow semantics.
        (aset numbers field (string-to-number (substring line start pos)))
        (when (= field 4)
          (setq prefix-end pos)
          (aset numbers 8 (substring line start pos)))
        (setq pos (1+ pos))
        (setq field (1+ field))))
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
    (cons numbers (substring line 6 prefix-end))))

(defun host-policy-serve ()
  "Serve private numeric HP1 frames with strict byte and field bounds."
  (nelisp--write-stdout-bytes "HP1 READY\n")
  (let ((pending "") (running t) (scan 0)
        (pause-kind (getenv "DDSKK_HOST_POLICY_TEST_PAUSE_KIND"))
        (private-key (or (getenv "NATIVEIME_REGISTRY_KEY") "")))
    (while running
      (let ((bytes (read-stdin-bytes 4096)))
        (if (not bytes) (setq running nil)
          (setq pending (concat pending bytes))
          (let ((newline (host-policy-newline pending scan)))
            (while newline
              (let* ((line (substring pending 0 newline))
                     (frame (host-policy-frame line))
                     (numbers (car frame)))
                (let ((decision (host-policy-decision
                                 (aref numbers 4) (aref numbers 5)
                                 (aref numbers 6) (aref numbers 7))))
                  ;; Private qualification only. A 3 s Lisp-side pause on
                  ;; publication intents overlaps native publish/TSF callbacks.
                  (when (and (equal (getenv "DDSKK_HARNESS_DIAGNOSTICS") "1")
                             (>= (length private-key) 24)
                             (equal (substring private-key 0 24) "Software\\NativeIME-test-")
                             (equal pause-kind (aref numbers 8)))
                    ;; This Windows image has current-time/float-time but no
                    ;; sleep-for. Block only this process's policy event loop.
                    (let ((until (+ (float-time) 3)))
                      (while (< (float-time) until))))
                  (nelisp--write-stdout-bytes
                   (concat "HP1 R " (cdr frame)
                           " " (number-to-string decision) "\n"))))
              (setq pending (substring pending (1+ newline)))
              (setq newline (host-policy-newline pending 0))))
          (setq scan (length pending))
          (when (> (length pending) 4096) (error "HP1 size")))))))

(unless (getenv "DDSKK_HOST_POLICY_UNIT_ONLY") (host-policy-serve))
