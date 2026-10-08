;;; host-policy.el --- Private HP1 shadow decisions -*- lexical-binding: t; -*-
;; This process has no engine, public pipe, publication or learning API.
;; Inputs are bounded decimal value fields; never read/eval IPC as Lisp.

(defun host-policy-decision (kind a b c)
  "Compute a shadow decision from copied native policy inputs."
  (cond ((= kind 1) (if (or (= a 0) (= b 1)) a 0)) ; runner availability
        ((= kind 2) (if (= a 0) 0 (if (= b 0) 2 1))) ; file before server
        ((= kind 3) (if (= b 1) 1000 (min 30000 (* a 2))))
        ((= kind 4) (if (>= b (if (= a 1) 60000 2000)) 1 0))
        ((= kind 5) (if (and (= a 1) (= b 1) (= c 1)) 1 0))
        (t -1)))

(defun host-policy-serve ()
  "Serve private numeric HP1 frames with strict byte and field bounds."
  (nelisp--write-stdout-bytes "HP1 READY\n")
  (let ((pending "") (running t))
    (while running
      (let ((bytes (read-stdin-bytes 4096)))
        (if (not bytes) (setq running nil)
          (setq pending (concat pending bytes))
          (let ((newline (string-match "\n" pending)))
            (while newline
              (let* ((line (substring pending 0 newline))
                     (fields (split-string line " " t)))
                (unless (and (<= (length line) 4096) (= (length fields) 11)
                             (equal (nth 0 fields) "HP1") (equal (nth 1 fields) "Q"))
                  (error "HP1 framing"))
                (let ((i 2))
                  (while (< i 10)
                    (unless (string-match "\\`[0-9]+\\'" (nth i fields))
                      (error "HP1 numeric field"))
                    (setq i (1+ i))))
                (unless (or (equal (nth 10 fields) "-")
                            (and (<= (length (nth 10 fields)) 2048)
                                 (= (% (length (nth 10 fields)) 2) 0)
                                 (string-match "\\`[0-9a-f]+\\'" (nth 10 fields))))
                  (error "HP1 context"))
                (unless (and (>= (string-to-number (nth 6 fields)) 1)
                             (<= (string-to-number (nth 6 fields)) 5))
                  (error "HP1 kind"))
                (let ((decision (host-policy-decision
                                 (string-to-number (nth 6 fields))
                                 (string-to-number (nth 7 fields))
                                 (string-to-number (nth 8 fields))
                                 (string-to-number (nth 9 fields)))))
                  ;; Private qualification only. A 3 s Lisp-side pause on
                  ;; publication intents overlaps native publish/TSF callbacks.
                  (when (and (equal (getenv "DDSKK_HARNESS_DIAGNOSTICS") "1")
                             (string-match "\\`Software\\\\NativeIME-test-"
                                           (or (getenv "NATIVEIME_REGISTRY_KEY") ""))
                             (equal (getenv "DDSKK_HOST_POLICY_TEST_PAUSE_KIND")
                                    (nth 6 fields)))
                    ;; This Windows image has current-time/float-time but no
                    ;; sleep-for. Block only this process's policy event loop.
                    (let ((until (+ (float-time) 3)))
                      (while (< (float-time) until))))
                  (nelisp--write-stdout-bytes
                   (concat "HP1 R " (mapconcat #'identity (list (nth 2 fields) (nth 3 fields)
                           (nth 4 fields) (nth 5 fields) (nth 6 fields)) " ")
                           " " (number-to-string decision) "\n"))))
              (setq pending (substring pending (1+ newline)))
              (setq newline (string-match "\n" pending))))
          (when (> (length pending) 4096) (error "HP1 size")))))))

(unless (getenv "DDSKK_HOST_POLICY_UNIT_ONLY") (host-policy-serve))
