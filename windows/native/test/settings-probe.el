;;; settings-probe.el --- probe DLL around ddskk-core-settings.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Test DLL for sub-stage S3e: links `ddskk-core-settings-forms' with thin
;; exported probes (settings_probe = ProbeLoad, watcher and publication hooks).
;; Exports (all Win64 integer ABI):
;;   ProbeNew() -> s              ProbeFree(s)            ProbeLoad(s)
;;   ProbeGet(s, idx) -> u64      numeric state, see `settings-probe-get'
;;   ProbeEngine(s) ProbeOpenMode(s) ProbeAppName(s) -> wide string pointer
;;   ProbeSetActivated(s, v) ProbeSetOpen(s, v) ProbeSetMode(s, wptr)
;;   ProbeSetFlushed(s, v) ProbeQueue(s, comp) ProbeFlush(s) ProbeRemove(s)
;;   ProbeTrace(s, i) ProbeRing(s, i, field) ProbeConcurrent(s, n) ProbeYield(v)
;;   ProbeFp(include_core) -> fingerprint of HKCU\<NativeIME key>
;;   ProbeWkNew(ic) ProbeWkStart(w) ProbeWkGet(w, idx) ProbeWkTake(w)
;;   ProbeWkStop(w, ms) ProbeWkFree(w)
;; Build hook: NELISP_SETTINGS_NOLOCK=1 builds the per-service lock as a no-op.

;;; Code:

(require 'cl-lib)
(require 'ddskk-core-settings)

(defconst settings-probe-exports
  '("ProbeNew" "ProbeFree" "ProbeLoad" "ProbeGet" "ProbeEngine" "ProbeOpenMode"
    "ProbeAppName" "ProbeSetActivated" "ProbeSetOpen" "ProbeSetMode"
    "ProbeSetFlushed" "ProbeQueue" "ProbeFlush" "ProbeRemove" "ProbeTrace"
    "ProbeRing" "ProbeConcurrent" "ProbeYield" "ProbeFp" "ProbeWkNew"
    "ProbeWkStart" "ProbeWkGet" "ProbeWkTake" "ProbeWkStop" "ProbeWkFree" "ProbeSeq"))

(defun settings-probe-forms (&optional no-lock)
  (let ((u32 ddskk-core-settings-u32)
        (hkcu nelisp-com-hkey-current-user)
        (ring ddskk-core-settings-ring-entry))
    (cl-subst
     'cs_mod '%
     (append
     (nelisp-com-wstr-lib-forms)
     (ddskk-core-settings-forms :no-lock no-lock)
     `((defun ProbeNew () (cs_new))
       (defun ProbeFree (s) (cs_free s))
       (defun ProbeLoad (s) (cs_load s))
       ;; idx: 0 kana 1 ddskk 2 debug 3 ms 4 enabled 5 scale 6 publish
       ;; 7 registered 8 active 9 queued 10 trace_n 11 ring_count 12-16 colors
       ;; 17 activated 18 process publisher count 19 flushed sequence
       (defun ProbeGet (s idx)
         (if (= idx 0) ,(cs--f 's 'kana)
         (if (= idx 1) ,(cs--f 's 'ddskk)
         (if (= idx 2) ,(cs--f 's 'debug)
         (if (= idx 3) ,(cs--f 's 'ms)
         (if (= idx 4) ,(cs--f 's 'enabled)
         (if (= idx 5) ,(cs--f 's 'scale)
         (if (= idx 6) ,(cs--f 's 'publish)
         (if (= idx 7) ,(cs--f 's 'registered)
         (if (= idx 8) ,(cs--f 's 'active)
         (if (= idx 9) ,(cs--f 's 'queued)
         (if (= idx 10) ,(cs--f 's 'trace_n)
         (if (= idx 11) ,(cs--f 's 'ring_count)
         (if (and (>= idx 12) (<= idx 16))
             (ptr-read-u32 ,(cs--a 's 'colors) (* 4 (- idx 12)))
         (if (= idx 17) ,(cs--f 's 'activated)
         (if (= idx 18) (ptr-read-u64 (data-addr cs_proc_pubs) 0)
         (if (= idx 19) (cs_flushed_get s)
           99999)))))))))))))))))
       (defun ProbeEngine (s) ,(cs--a 's 'engine))
       (defun ProbeOpenMode (s) (wbuf_ptr ,(cs--f 's 'open_mode)))
       (defun ProbeAppName (s) (wbuf_ptr ,(cs--f 's 'app_name)))
       (defun ProbeSetActivated (s v) (seq ,(cs--s 's 'activated 'v) 0))
       (defun ProbeSetOpen (s v) (seq ,(cs--s 's 'open 'v) 0))
       (defun ProbeSetMode (s p) (cs_wassign ,(cs--a 's 'last_mode) p (wbuf_wcslen p)))
       (defun ProbeSetFlushed (s v) (cs_flushed_set s v))
       (defun ProbeQueue (s c) (cs_queue s c))
       (defun ProbeFlush (s) (cs_flush s))
       (defun ProbeRemove (s) (cs_remove s))
       (defun ProbeTrace (s i) (ptr-read-u32 ,(cs--a 's 'trace) (* 4 i)))
       ;; Entry I of the ring in queue order; FIELD 0 seq 1 open 2 composing.
       (defun ProbeRing (s i field)
         (let ((e (+ ,(cs--f 's 'ring)
                      (* ,ring (% (+ ,(cs--f 's 'ring_head) i) ,(cs--f 's 'ring_cap))))))
           (ptr-read-u32 e (* 4 field))))
       (defun ProbeYield (v) (seq (ptr-write-u64 (data-addr cs_race_yield) 0 v) 0))
       ;; ---- two producer threads pushing N unique transitions each ----
       (defun pc_thread (tid)
         (let ((s (ptr-read-u64 (data-addr cs_probe_hk) 8)) (n (ptr-read-u64 (data-addr cs_probe_hk) 16))
               (i 0))
           (seq (while (< i n)
                  (seq (cs_pub_push s (data-addr w_cs_hiragana) tid (+ i 1))
                       (setq i (+ i 1))))
                0)))
       (defun ProbeConcurrent (s n)
         (let ((heap (extern-call GetProcessHeap)))
           (let ((blk (extern-call HeapAlloc heap 8 64)))
             (seq
              (ptr-write-u64 (data-addr cs_probe_hk) 8 s) (ptr-write-u64 (data-addr cs_probe_hk) 16 n)
              (ptr-write-u64 blk 0 (extern-call CreateThread 0 0 (addr-of pc_thread) 1 0 0))
              (ptr-write-u64 blk 8 (extern-call CreateThread 0 0 (addr-of pc_thread) 2 0 0))
              (ptr-write-u64 blk 24 (logand (extern-call WaitForMultipleObjects 2 blk 1 60000) 4294967295))
              (extern-call CloseHandle (ptr-read-u64 blk 0))
              (extern-call CloseHandle (ptr-read-u64 blk 8))
              (let ((r (ptr-read-u64 blk 24)))
                (seq (extern-call HeapFree heap 0 blk) r))))))
       (defun ProbeSeq (s n)
         (seq (ptr-write-u64 (data-addr cs_probe_hk) 8 s) (ptr-write-u64 (data-addr cs_probe_hk) 16 n)
              (pc_thread 1) (pc_thread 2) 0))
       (defun ProbeFp (ic)
         (let ((kw (cs_regkey)) (r 0))
           (seq (if (= kw 0) 0
                  (if (= (logand (extern-call RegOpenKeyExW ,hkcu (wbuf_ptr kw) 0 131097
                                               (data-addr cs_probe_hk))
                                 ,u32)
                         0)
                      (seq (setq r (cs_fp (ptr-read-u64 (data-addr cs_probe_hk) 0) 1 ic))
                           (extern-call RegCloseKey (ptr-read-u64 (data-addr cs_probe_hk) 0))
                           0)
                    0))
                (wbuf_free kw)
                r)))
       (defun ProbeWkNew (ic) (cs_wk_new ic))
       (defun ProbeWkStart (w) (cs_wk_start w))
       ;; idx: 0 dirty 1 wakeups 2 ready 3 exited 4 thread 5 stop 6 fingerprint
       (defun ProbeWkGet (w idx)
         (if (= idx 0) ,(cs--wf 'w 'dirty)
         (if (= idx 1) ,(cs--wf 'w 'wakeups)
         (if (= idx 2) ,(cs--wf 'w 'ready)
         (if (= idx 3) ,(cs--wf 'w 'exited)
         (if (= idx 4) ,(cs--wf 'w 'thread)
         (if (= idx 5) ,(cs--wf 'w 'stop)
         (if (= idx 6) ,(cs--wf 'w 'fingerprint)
           99999))))))))
       (defun ProbeWkTake (w) (cs_wk_take w))
       (defun ProbeWkStop (w ms) (cs_wk_stop_ms w (logand ms ,u32)))
       (defun ProbeWkFree (w) (DdskkWatcher_free w)))
     (list (nelisp-com-zero-blob 'cs_probe_hk 32))))))

(defun settings-probe-build (path &optional no-lock)
  "Build the probe DLL PATH; NO-LOCK builds the lock-disabled mutant."
  (setq max-lisp-eval-depth (max max-lisp-eval-depth 100000))
  (nelisp-com-build-dll path (settings-probe-forms no-lock)
                        :exports settings-probe-exports
                        :imports ddskk-core-settings-imports
                        :dll-name (file-name-nondirectory path))
  path)

(defun settings-probe-build-from-env (path)
  (settings-probe-build path (equal (getenv "NELISP_SETTINGS_NOLOCK") "1")))

(provide 'settings-probe)
;;; settings-probe.el ends here
