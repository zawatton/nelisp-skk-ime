;;; stub-core.el --- stub NativeImeCoreApi core DLL for the shim tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Builds a stub core DLL implementing the NativeImeCoreApi of
;; windows/src/core_abi.h with counters the tests can read.  Exports:
;;
;;   NativeImeGetCoreApi(abi, size, NativeImeCoreApi*)   the core entry point
;;   StubCoreCounter(index)                              counter readout
;;
;; Counters (u64): 0 create, 1 destroy, 2 activate, 3 deactivate,
;; 4+op invoke per NativeImeOperation (op 0..15 -> 4..19), 20 last wparam,
;; 21 activate saw a non-null thread manager, 22 last client id,
;; 23 callbacks table valid (size 72, version 1), 24 eaten decisions,
;; 25 publication_sequence() result seen in activate, 26 query_service(
;; ITfKeyEventSink) HRESULT in activate (0xFFFFFFFF = not called),
;; 27 AddRef result on the thread manager in activate, 28 last lparam.
;;
;; Key policy: TEST_DOWN/DOWN eat the keys A..Z (VK 0x41..0x5A) only; all other
;; operations leave *eaten FALSE.
;;
;; Build hook (environment, `stub-core-build-from-env'):
;;   NELISP_STUB_CORE_BAD_ABI=1   report ABI version 999 (NATIVEIME_CORE_BAD_ABI)

;;; Code:

(require 'cl-lib)
(require 'ddskk-shim)

(defconst stub-core-imports
  '(("kernel32.dll" "GetProcessHeap" "HeapAlloc" "HeapFree")))
(defconst stub-core-exports '("NativeImeGetCoreApi" "StubCoreCounter"))

(defun stub-core--cnt (i) `(+ (data-addr sc_cnt) ,(* 8 i)))
(defun stub-core--inc (i) `(atomic-fetch-add ,(stub-core--cnt i) 1))
(defun stub-core--set (i v) `(ptr-write-u64 ,(stub-core--cnt i) 0 ,v))

(defun stub-core-forms (&optional bad-abi)
  "Return the AOT forms of the stub core; BAD-ABI reports version 999."
  (let ((api-size (nelisp-com-struct-size 'NativeImeCoreApi))
        (u32 ddskk-shim--u32))
    (append
     (list (nelisp-com-zero-blob 'sc_cnt (* 8 40))
           (nelisp-com-ascii-blob 'sc_diag "stub-core 0.1")
           (nelisp-com-guid-blob 'sc_iid_sink
                                 (nelisp-com-msctf-guid 'IID_ITfKeyEventSink))
           (nelisp-com-zero-blob 'sc_out 16))
     `((defun NativeImeGetCoreApi (abi size out)
         (if (or (/= (logand abi ,u32) 1) (/= (logand size ,u32) ,api-size) (= out 0))
             ,nelisp-com-e-invalidarg
           (seq ,(nelisp-com-set-field 'out 'NativeImeCoreApi 'size api-size)
                ,(nelisp-com-set-field 'out 'NativeImeCoreApi 'version (if bad-abi 999 1))
                ,(nelisp-com-set-field 'out 'NativeImeCoreApi 'diagnostic_version '(data-addr sc_diag))
                ,@(cl-loop for (f fn) in '((create sc_create) (destroy sc_destroy)
                                           (activate sc_activate) (deactivate sc_deactivate)
                                           (invoke sc_invoke) (quiescent sc_quiescent)
                                           (export_state sc_notimpl) (import_state sc_notimpl)
                                           (can_unload sc_quiescent) (prepare_unload sc_quiescent))
                           collect (nelisp-com-set-field 'out 'NativeImeCoreApi f `(addr-of ,fn)))
                0)))
       (defun StubCoreCounter (i) (ptr-read-u64 (data-addr sc_cnt) (* 8 (logand i 63))))
       (defun sc_quiescent (st) 1)
       (defun sc_notimpl (st x) ,nelisp-com-e-notimpl)
       ;; state: +0 owner +8 query_service +16 publication_sequence
       (defun sc_create (cb pstate)
         (let ((s (extern-call HeapAlloc (extern-call GetProcessHeap) 8 64)))
           (if (= s 0) ,nelisp-com-e-outofmemory
             (seq ,(stub-core--inc 0)
                  ,(stub-core--set 23 `(if (and (= ,(nelisp-com-field 'cb 'NativeImeCallbacks 'size)
                                                   ,(nelisp-com-struct-size 'NativeImeCallbacks))
                                                (= ,(nelisp-com-field 'cb 'NativeImeCallbacks 'version) 1))
                                           1 0))
                  (ptr-write-u64 s 0 ,(nelisp-com-field 'cb 'NativeImeCallbacks 'owner))
                  (ptr-write-u64 s 8 ,(nelisp-com-field 'cb 'NativeImeCallbacks 'query_service))
                  (ptr-write-u64 s 16 ,(nelisp-com-field 'cb 'NativeImeCallbacks 'publication_sequence))
                  (ptr-write-u64 pstate 0 s)
                  0))))
       (defun sc_destroy (st)
         (seq ,(stub-core--inc 1)
              (extern-call HeapFree (extern-call GetProcessHeap) 0 st)
              0))
       ;; Exercise the callbacks table and the thread manager pointer.
       (defun sc_activate (st tm id)
         (seq ,(stub-core--inc 2)
              ,(stub-core--set 21 '(if (= tm 0) 0 1))
              ,(stub-core--set 22 `(logand id ,u32))
              ,(stub-core--set 25 '(call-ptr (ptr-read-u64 st 16) (ptr-read-u64 st 0)))
              ,(stub-core--set 26 4294967295)
              (let ((hr (call-ptr (ptr-read-u64 st 8) (ptr-read-u64 st 0)
                                  (data-addr sc_iid_sink) (data-addr sc_out))))
                (seq ,(stub-core--set 26 `(logand hr ,u32))
                     (if (= (logand hr 2147483648) 0)
                         ,(nelisp-com-call '(ptr-read-u64 (data-addr sc_out) 0) 2)
                       0)))
              ,(stub-core--set 27 (nelisp-com-call 'tm 1))
              ,(nelisp-com-call 'tm 2)
              0))
       (defun sc_deactivate (st) (seq ,(stub-core--inc 3) 0))
       (defun sc_invoke (st op call)
         (let ((pe ,(nelisp-com-field 'call 'NativeImeCall 'eaten))
               (wp ,(nelisp-com-field 'call 'NativeImeCall 'wparam))
               (e 0))
           (seq (atomic-fetch-add (+ (data-addr sc_cnt) (* 8 (+ 4 (logand op 15)))) 1)
                ,(stub-core--set 20 'wp)
                ,(stub-core--set 28 (nelisp-com-field 'call 'NativeImeCall 'lparam))
                (if (or (= op 1) (= op 2))
                    (if (and (>= wp 65) (<= wp 90)) (setq e 1) 0)
                  0)
                (if (= pe 0) 0 (seq (ptr-write-u32 pe 0 e) (if (= e 1) ,(stub-core--inc 24) 0) 0))
                0)))))))

(defun stub-core-build (path &optional bad-abi)
  "Build the stub core DLL PATH; BAD-ABI builds the version-999 mutant."
  (setq max-lisp-eval-depth (max max-lisp-eval-depth 100000))
  (nelisp-com-build-dll path (stub-core-forms bad-abi)
                        :exports stub-core-exports :imports stub-core-imports
                        :dll-name (file-name-nondirectory path))
  path)

(defun stub-core-build-from-env (path)
  "Build the stub core PATH, taking the mutant hook from the environment."
  (stub-core-build path (equal (getenv "NELISP_STUB_CORE_BAD_ABI") "1")))

(provide 'stub-core)
;;; stub-core.el ends here
