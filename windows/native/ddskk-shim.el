;;; ddskk-shim.el --- native TSF shim DLL (COM skeleton + registration)  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sub-stage S3c of the native TSF DLL project: the COM skeleton and the full
;; registration of ddskk-shim, written in the restricted AOT subset of NeLisp
;; and linked with the COM DSL (lisp/nelisp-com-dsl.el of the NeLisp checkout).
;; It mirrors windows/src/dllmain.cpp of the C++ shim:
;;
;;   exports (as ddskk-ime.def)  DllGetClassObject DllCanUnloadNow
;;                               DllRegisterServer DllUnregisterServer
;;   CLSID_DdskkTextService      {80b44b14-b866-4ef4-a394-4ff1d87d5185}
;;   DllCanUnloadNow             always S_FALSE (like dllmain.cpp)
;;   DllRegisterServer           COM class (default HKCU\Software\Classes,
;;                               HKCR with NELISP_COM_HIVE=hkcr), the
;;                               HKCU\Software\NativeIME values, the TSF
;;                               profile (langid 0x0411) and six categories;
;;                               rolled back on partial failure
;;   DllUnregisterServer         exact mirror of the TSF part and the class
;;                               key (the NativeIME settings are kept, as in
;;                               dllmain.cpp)
;;
;; Sub-stage S3d adds the ShimService object (shim_service.cpp): the QI table
;; ITfTextInputProcessor(+Ex alias), ITfKeyEventSink, ITfCompositionSink,
;; ITfCompartmentEventSink, ITfDisplayAttributeProvider, ITfFunctionProvider,
;; ITfFnConfigure(+ITfFunction alias); Activate/Deactivate with the core DLL
;; loader (registry CoreDll else sibling ddskk-ime-core.dll, ABI validation,
;; module cache), the NativeImeCallbacks table, key forwarding with the
;; key_pair logic, the composition tracking list, compartment advise and the
;; message-only window with a 50 ms timer.  Language-bar buttons, the registry
;; watcher and hot-swap (TrySwap) belong to later stages.
;;
;; Build hooks (environment, read by `ddskk-shim-build-from-env'):
;;   NELISP_COM_HIVE=hkcr       register the class under HKEY_CLASSES_ROOT
;;                              (wine's CoCreateInstance ignores HKCU classes)
;;   NELISP_SHIM_DROP_CATEGORY=1  negative control: do not register the last
;;                              category (GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT)
;;   NELISP_SHIM_WRONG_SLOT=1   negative control: OnKeyDown forwards the
;;                              OnTestKeyDown operation to the core
;;   NELISP_SHIM_TEST_EXPORTS=1 also export DdskkShimStat (test counters) and
;;                              DdskkShimPubLock (the publication lock callback)
;;   NELISP_SHIM_NOLOCK=1       negative control: publication_lock is a no-op
;;   NELISP_SHIM_BAD_LANGID=1   negative control: AddLanguageProfile with
;;                              langid 0x0409 instead of 0x0411

;;; Code:

(require 'cl-lib)

(defun ddskk-shim--setup-load-path ()
  "Put NeLisp's lisp directory on `load-path' (NELISP_ROOT or a sibling)."
  (let* ((here (file-name-directory (or load-file-name buffer-file-name
                                        default-directory)))
         (repo (expand-file-name "../../" here))
         (root (or (getenv "NELISP_ROOT")
                   (let ((sib (expand-file-name "../nelisp" repo)))
                     (and (file-directory-p sib) sib)))))
    (unless (and root (file-exists-p
                       (expand-file-name "lisp/nelisp-com-dsl.el" root)))
      (error "NeLisp not found: set NELISP_ROOT to a checkout with lisp/nelisp-com-dsl.el"))
    (add-to-list 'load-path (expand-file-name "lisp" root))))

(ddskk-shim--setup-load-path)
(require 'nelisp-com-dsl)
(require 'nelisp-com-wstr-lib)

(defconst ddskk-shim-clsid "{80b44b14-b866-4ef4-a394-4ff1d87d5185}"
  "CLSID_DdskkTextService (windows/src/guids.h).")
(defconst ddskk-shim-profile-guid "{ee0012d5-8306-4388-b071-5c3c3e38f7ce}"
  "GUID_DdskkProfile (windows/src/guids.h).")
(defconst ddskk-shim-langid #x0411 "MAKELANGID(LANG_JAPANESE, SUBLANG_DEFAULT).")
(defconst ddskk-shim-description "NeLisp IME" "Profile and class description.")
(defconst ddskk-shim-categories
  '(GUID_TFCAT_TIP_KEYBOARD GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER
    GUID_TFCAT_TIPCAP_UIELEMENTENABLED GUID_TFCAT_TIPCAP_INPUTMODECOMPARTMENT
    GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT)
  "The six categories of dllmain.cpp RegisterCategories, in order.")

(defconst ddskk-shim-imports
  `(("kernel32.dll" "GetModuleHandleExW" "GetModuleFileNameW" "GetLastError"
     "GetFileAttributesW" "GetProcessHeap" "HeapAlloc" "HeapFree" "HeapReAlloc"
     "LoadLibraryExW" "GetProcAddress" "FreeLibrary" "InitializeCriticalSection"
     "EnterCriticalSection" "LeaveCriticalSection" "Sleep")
    ("advapi32.dll" "RegCreateKeyExW" "RegSetValueExW" "RegQueryValueExW"
     "RegCloseKey" "RegDeleteTreeW" "RegOpenKeyExW")
    ("ole32.dll" "CoCreateInstance")
    ("oleaut32.dll" "SysAllocString")
    ("user32.dll" "RegisterClassW" "CreateWindowExW" "DestroyWindow" "SetTimer"
     "DefWindowProcW" "SetWindowLongPtrW" "GetWindowLongPtrW"))
  "Imports of the shim DLL.")

;; ITfFnConfigure (ctffunc.h) is not in the NeLisp msctf table yet (local
;; workaround; GUID taken from memory of the SDK header, not cross-checked).
(unless (assq 'IID_ITfFnConfigure nelisp-com-msctf-guids)
  (setq nelisp-com-msctf-guids
        (append nelisp-com-msctf-guids
                '((IID_ITfFnConfigure "{88f567c6-1757-49f8-a1b2-89234c1eeff9}")))))

(defconst ddskk-shim-exports
  '("DllGetClassObject" "DllCanUnloadNow" "DllRegisterServer"
    "DllUnregisterServer")
  "Exports, identical to windows/src/ddskk-ime.def.")

(defconst ddskk-shim--u32 4294967295)
;; HRESULT_FROM_WIN32 facility bits: 0x80070000.
(defconst ddskk-shim--hr-win32 2147942400)

(defun ddskk-shim--call (obj slot &rest args)
  (apply #'nelisp-com-call obj slot args))

(defun ddskk-shim--blobs ()
  "Return the data blobs of the shim."
  (append
   (nelisp-com-msctf-blobs
    (append '(CLSID_TF_InputProcessorProfiles IID_ITfInputProcessorProfiles
              CLSID_TF_CategoryMgr IID_ITfCategoryMgr
              IID_ITfKeystrokeMgr IID_ITfCompartmentMgr IID_ITfSource
              IID_ITfCompartmentEventSink GUID_COMPARTMENT_KEYBOARD_OPENCLOSE)
            ddskk-shim-categories))
   (list (nelisp-com-guid-blob 'g_clsid ddskk-shim-clsid)
         (nelisp-com-guid-blob 'g_profile ddskk-shim-profile-guid))
   (cl-loop for (name str) in
            `((w_desc ,ddskk-shim-description)
              (w_native "Software\\NativeIME")
              (w_tm "ThreadingModel") (w_apartment "Apartment")
              (w_host "EngineHost") (w_exe "EngineExecutable")
              (w_repo "Repository") (w_kana "InitialKanaMode")
              (w_empty "")
              (w_host_name "ddskk-engine-host.exe")
              (w_standalone_name "nelisp-ddskk.exe")
              (w_nelisp "nelisp") (w_target "target")
              (w_nelisp_exe "nelisp.exe")
              (w_corevalue "CoreDll") (w_core_name "ddskk-ime-core.dll")
              (w_winclass "NativeImeStableShim")
              (w_fn_desc "NeLisp IME settings"))
            collect (nelisp-com-wstr-blob name str))
   (list (nelisp-com-ascii-blob 'a_getcore "NativeImeGetCoreApi")
         (nelisp-com-zero-blob 'shim_stats 64)
         (nelisp-com-zero-blob 'svc_wc (nelisp-com-struct-size 'WNDCLASSW)))
   (list (nelisp-com-zero-blob 'com_hmod 8)
         (nelisp-com-zero-blob 'com_hkey 8)
         (nelisp-com-zero-blob 'com_hkey2 8)
         (nelisp-com-zero-blob 'com_hkey3 8)
         (nelisp-com-zero-blob 'com_dw 8)
         (nelisp-com-zero-blob 'com_type 8)
         (nelisp-com-zero-blob 'com_size 8)
         (nelisp-com-zero-blob 'com_obj 8)
         (nelisp-com-zero-blob 'com_path 1040))))

(defun ddskk-shim--path-forms ()
  "UTF-16 path math replacing std::filesystem in dllmain.cpp."
  '((defun p_sep (c) (if (= c 92) 1 (if (= c 47) 1 0)))
    ;; In-place parent_path(): drop the last component; roots stay roots.
    (defun p_parent (w)
      (let ((i (- (wbuf_len w) 1)) (p (wbuf_ptr w)) (n 0))
        (seq (while (and (>= i 0)
                         (= (p_sep (ptr-read-u16 (+ p (* 2 i)) 0)) 0))
               (setq i (- i 1)))
             (setq n (if (< i 0) 0
                       (if (= i 0) 1
                         (if (and (= i 2) (= (ptr-read-u16 (+ p 2) 0) 58)) 3 i))))
             (ptr-write-u64 (+ w 8) 0 n)
             (ptr-write-u16 (+ p (* 2 n)) 0 0)
             0)))
    ;; In-place operator/: add a separator unless one ends the path.
    (defun p_join (w name)
      (let ((n (wbuf_len w)))
        (seq (if (> n 0)
                 (if (= (p_sep (wbuf_get w (- n 1))) 0) (wbuf_append_char w 92) 0)
               0)
             (wbuf_append_w w name)
             0)))))

(defun ddskk-shim--registry-forms (hive)
  "Forms registering/unregistering the COM class and settings in HIVE."
  (let* ((root (pcase hive
                 ('hkcu nelisp-com-hkey-current-user)
                 ('hkcr nelisp-com-hkey-classes-root)
                 (_ (error "Unknown hive %S" hive))))
         (prefix (if (eq hive 'hkcu) "Software\\Classes\\" ""))
         (u32 ddskk-shim--u32))
    (append
     (list (nelisp-com-wstr-blob
            'w_key_class (concat prefix "CLSID\\" ddskk-shim-clsid))
           (nelisp-com-wstr-blob 'w_key_inproc "InprocServer32"))
     `((defun hrw (st)
         (if (= st 0) 0 (logior (logand st 65535) ,ddskk-shim--hr-win32)))
       (defun reg_sz (hk name wp)
         (extern-call RegSetValueExW hk name 0 1 wp (* 2 (+ 1 (wbuf_wcslen wp)))))
       ;; Software\NativeIME values (dllmain.cpp ~100-145).  Needs com_path.
       (defun shim_reg_settings ()
         (let ((parent (wbuf_from_w (data-addr com_path)))
               (host (wbuf_from_w (data-addr com_path)))
               (sa (wbuf_from_w (data-addr com_path)))
               (repo (wbuf_from_w (data-addr com_path)))
               (nel (wbuf_from_w (data-addr com_path))))
           (if (or (= parent 0) (= host 0) (= sa 0) (= repo 0) (= nel 0))
               (seq (wbuf_free parent) (wbuf_free host) (wbuf_free sa)
                    (wbuf_free repo) (wbuf_free nel) ,nelisp-com-e-outofmemory)
             (seq
              (p_parent parent)
              (p_parent host) (p_join host (data-addr w_host_name))
              (p_parent sa) (p_join sa (data-addr w_standalone_name))
              (p_parent repo) (p_parent repo) (p_parent repo) (p_parent repo)
              (p_parent nel) (p_parent nel) (p_parent nel) (p_parent nel)
              (p_parent nel)
              (p_join nel (data-addr w_nelisp)) (p_join nel (data-addr w_target))
              (p_join nel (data-addr w_nelisp_exe))
              (if (= (logand (extern-call RegCreateKeyExW ,nelisp-com-hkey-current-user
                                          (data-addr w_native) 0 0 0 131078 0
                                          (data-addr com_hkey3) 0)
                             ,u32)
                     0)
                  (let ((hk (ptr-read-u64 (data-addr com_hkey3) 0)))
                    (seq
                     (reg_sz hk (data-addr w_host) (wbuf_ptr host))
                     (if (/= (logand (extern-call GetFileAttributesW (wbuf_ptr sa))
                                     ,u32)
                             ,u32)
                         (seq (reg_sz hk (data-addr w_exe) (wbuf_ptr sa))
                              (reg_sz hk (data-addr w_repo) (data-addr w_empty)))
                       (seq (reg_sz hk (data-addr w_exe) (wbuf_ptr nel))
                            (reg_sz hk (data-addr w_repo) (wbuf_ptr repo))))
                     ;; InitialKanaMode only if absent.
                     (ptr-write-u32 (data-addr com_dw) 0 1)
                     (ptr-write-u64 (data-addr com_size) 0 4)
                     (if (/= (logand (extern-call RegQueryValueExW hk (data-addr w_kana)
                                                  0 (data-addr com_type)
                                                  (data-addr com_dw)
                                                  (data-addr com_size))
                                     ,u32)
                             0)
                         (seq (ptr-write-u32 (data-addr com_dw) 0 1)
                              (extern-call RegSetValueExW hk (data-addr w_kana) 0 4
                                           (data-addr com_dw) 4))
                       0)
                     (extern-call RegCloseKey hk)))
                0)
              (wbuf_free parent) (wbuf_free host) (wbuf_free sa)
              (wbuf_free repo) (wbuf_free nel)
              0))))
       ;; RegisterComServer (dllmain.cpp ~72-150).
       (defun shim_reg_com ()
         (seq
          (extern-call GetModuleHandleExW 6 (addr-of shim_reg_com)
                       (data-addr com_hmod))
          (let ((n (extern-call GetModuleFileNameW
                                (ptr-read-u64 (data-addr com_hmod) 0)
                                (data-addr com_path) 519)))
            (if (= (logand n ,u32) 0)
                (hrw (logand (extern-call GetLastError) ,u32))
              (let ((st (logand (extern-call RegCreateKeyExW ,root
                                             (data-addr w_key_class) 0 0 0 131078 0
                                             (data-addr com_hkey) 0)
                                ,u32)))
                (if (/= st 0) (hrw st)
                  (let ((ck (ptr-read-u64 (data-addr com_hkey) 0)))
                    (seq
                     (reg_sz ck 0 (data-addr w_desc))
                     (let ((st2 (logand (extern-call RegCreateKeyExW ck
                                                     (data-addr w_key_inproc) 0 0 0
                                                     131078 0 (data-addr com_hkey2) 0)
                                        ,u32)))
                       (seq
                        (if (= st2 0)
                            (let ((sk (ptr-read-u64 (data-addr com_hkey2) 0)))
                              (seq (reg_sz sk 0 (data-addr com_path))
                                   (reg_sz sk (data-addr w_tm) (data-addr w_apartment))
                                   (extern-call RegCloseKey sk)))
                          0)
                        (extern-call RegCloseKey ck)
                        (if (= st2 0) (shim_reg_settings) 0)
                        (hrw st2)))))))))))
       (defun shim_unreg_com ()
         (seq (extern-call RegDeleteTreeW ,root (data-addr w_key_class)) 0))))))

(defun ddskk-shim--tsf-forms (langid categories)
  "Forms for the TSF profile and category registration with LANGID."
  (let* ((cch (length ddskk-shim-description))
         (n (length categories)))
    (append
     `((defun shim_reg_profile ()
         (let ((hr (extern-call CoCreateInstance
                                (data-addr CLSID_TF_InputProcessorProfiles) 0 1
                                (data-addr IID_ITfInputProcessorProfiles)
                                (data-addr com_obj))))
           (if ,(nelisp-com-failed 'hr) hr
             (let ((p (ptr-read-u64 (data-addr com_obj) 0)))
               ,(nelisp-com-try
                 `((h1 ,(ddskk-shim--call 'p 3 '(data-addr g_clsid)))
                   (h2 ,(ddskk-shim--call 'p 5 '(data-addr g_clsid) langid
                                          '(data-addr g_profile)
                                          '(data-addr w_desc) cch 0 0 0))
                   (h3 ,(ddskk-shim--call 'p 17 '(data-addr g_clsid) langid
                                          '(data-addr g_profile) 1)))
                 `(seq ,(ddskk-shim--call 'p 2) 0)
                 (ddskk-shim--call 'p 2))))))
       (defun shim_unreg_profile ()
         (let ((hr (extern-call CoCreateInstance
                                (data-addr CLSID_TF_InputProcessorProfiles) 0 1
                                (data-addr IID_ITfInputProcessorProfiles)
                                (data-addr com_obj))))
           (if ,(nelisp-com-failed 'hr) 0
             (let ((p (ptr-read-u64 (data-addr com_obj) 0)))
               (seq ,(ddskk-shim--call 'p 17 '(data-addr g_clsid) langid
                                       '(data-addr g_profile) 0)
                    ,(ddskk-shim--call 'p 6 '(data-addr g_clsid) langid
                                       '(data-addr g_profile))
                    ,(ddskk-shim--call 'p 4 '(data-addr g_clsid))
                    ,(ddskk-shim--call 'p 2)
                    0)))))
       (defun shim_reg_categories ()
         (let ((hr (extern-call CoCreateInstance (data-addr CLSID_TF_CategoryMgr) 0 1
                                (data-addr IID_ITfCategoryMgr) (data-addr com_obj))))
           (if ,(nelisp-com-failed 'hr) hr
             (let ((cm (ptr-read-u64 (data-addr com_obj) 0)))
               ,(nelisp-com-try
                 (cl-loop for c in categories for i from 0
                          collect (list (intern (format "c%d" i))
                                        (ddskk-shim--call
                                         'cm 3 '(data-addr g_clsid)
                                         `(data-addr ,c) '(data-addr g_clsid))))
                 `(seq ,(ddskk-shim--call 'cm 2) 0)
                 (ddskk-shim--call 'cm 2))))))
       ;; Unregistration always tries every category, ignoring failures.
       (defun shim_unreg_categories ()
         (let ((hr (extern-call CoCreateInstance (data-addr CLSID_TF_CategoryMgr) 0 1
                                (data-addr IID_ITfCategoryMgr) (data-addr com_obj))))
           (if ,(nelisp-com-failed 'hr) 0
             (let ((cm (ptr-read-u64 (data-addr com_obj) 0)))
               (seq ,@(cl-loop for c in ddskk-shim-categories
                               collect (ddskk-shim--call
                                        'cm 4 '(data-addr g_clsid)
                                        `(data-addr ,c) '(data-addr g_clsid)))
                    ,(ddskk-shim--call 'cm 2)
                    0))))))
     (ignore n))))

;;;; S3d: ShimService (TIP object), core loader, callbacks, window

;; Struct layouts of windows/src/core_abi.h (Win64).
(nelisp-com-defstruct NativeImeCallbacks
  (size u32) (version u32) (owner ptr) (query_service ptr) (notify_mode ptr)
  (track_ending ptr) (publication_sequence ptr) (publisher_delta ptr)
  (publication_lock ptr) (publication_flushed ptr))
(nelisp-com-defstruct NativeImeCoreApi
  (size u32) (version u32) (diagnostic_version ptr) (create ptr) (destroy ptr)
  (activate ptr) (deactivate ptr) (invoke ptr) (quiescent ptr)
  (export_state ptr) (import_state ptr) (can_unload ptr) (prepare_unload ptr))
(nelisp-com-defstruct NativeImeCall
  (context ptr) (wparam u64) (lparam i64) (eaten ptr) (guid ptr) (text ptr)
  (narrow ptr) (label (array u16 32)) (palette (array u32 3)))
(nelisp-com-defstruct WNDCLASSW
  (style u32) (lpfnWndProc ptr) (cbClsExtra i32) (cbWndExtra i32)
  (hInstance ptr) (hIcon ptr) (hCursor ptr) (hbrBackground ptr)
  (lpszMenuName ptr) (lpszClassName ptr))

(defconst ddskk-shim-op
  '((focus . 0) (test-down . 1) (down . 2) (test-up . 3) (up . 4) (preserved . 5)
    (composition-end . 6) (compartment . 7) (engine . 8) (engine-id . 9)
    (reload . 10) (toggle . 11) (settings . 12) (mode . 13) (label . 14)
    (palette . 15))
  "NativeImeOperation values of core_abi.h.")

(defconst ddskk-shim--mod-entry 1152
  "Module cache entry: handle@0, NativeImeCoreApi@8 (96 bytes), path@104.")
(defconst ddskk-shim--mod-max 4)
(defconst ddskk-shim--iface-count 7)
(defconst ddskk-shim--max-ending 16)

(defun ddskk-shim--f (b field) (nelisp-com-class-field 'tip b field))
(defun ddskk-shim--s (b field value) (nelisp-com-class-set-field 'tip b field value))
(defun ddskk-shim--fa (b field)
  "Address form of state FIELD of the object B."
  (nelisp-com-field-addr `(+ ,b ,(nelisp-com-state-offset ddskk-shim--iface-count))
                         'tip_state field))
(defun ddskk-shim--api (m field)
  "Read form of NativeImeCoreApi FIELD in the module cache entry M."
  (nelisp-com-field `(+ ,m 8) 'NativeImeCoreApi field))
(defun ddskk-shim--and (forms)
  "Nest FORMS into binary `and' forms."
  (if (null (cdr forms)) (car forms)
    `(and ,(car forms) ,(ddskk-shim--and (cdr forms)))))
(defun ddskk-shim--op (name) (cdr (assq name ddskk-shim-op)))

(defun ddskk-shim--stat-inc (i) `(atomic-fetch-add (+ (data-addr shim_stats) ,(* 8 i)) 1))

(defun ddskk-shim--loader-forms ()
  "Core path resolution, LoadCore with ABI validation and the module cache."
  (let ((u32 ddskk-shim--u32)
        (valid (ddskk-shim--and
                (append
                 (list `(= ,(ddskk-shim--api 'e 'size) ,(nelisp-com-struct-size 'NativeImeCoreApi))
                       `(= ,(ddskk-shim--api 'e 'version) 1))
                 (mapcar (lambda (f) `(/= ,(ddskk-shim--api 'e f) 0))
                         '(diagnostic_version create destroy activate deactivate
                           invoke quiescent export_state import_state can_unload
                           prepare_unload))))))
    `((data-blob mod_tab ,(make-list (* ddskk-shim--mod-max ddskk-shim--mod-entry) 0) data)
      (data-blob mod_n ,(make-list 8 0) data)
      ;; std::filesystem::path::is_absolute: "X:\" or "\\".
      (defun mod_isabs (p)
        (let ((c0 (ptr-read-u16 p 0)) (c1 (ptr-read-u16 p 2)))
          (if (and (= c1 58)
                   (and (= (p_sep (ptr-read-u16 p 4)) 1)
                        (or (and (>= c0 65) (<= c0 90)) (and (>= c0 97) (<= c0 122)))))
              1
            (if (and (= c0 92) (= c1 92)) 1 0))))
      ;; Case-insensitive wide-string equality: 1 or 0.
      (defun mod_ieq (a b)
        (let ((i 0) (r 2))
          (seq (while (= r 2)
                 (let ((x (ptr-read-u16 a (* 2 i))) (y (ptr-read-u16 b (* 2 i))))
                   (seq (if (and (>= x 65) (<= x 90)) (setq x (+ x 32)) 0)
                        (if (and (>= y 65) (<= y 90)) (setq y (+ y 32)) 0)
                        (if (/= x y) (setq r 0)
                          (if (= x 0) (setq r 1) (setq i (+ i 1)))))))
               r)))
      ;; Open the library H as cache entry N, validate the ABI table.
      (defun mod_open (h path n pout)
        (let ((e (+ (data-addr mod_tab) (* n ,ddskk-shim--mod-entry)))
              (ent (extern-call GetProcAddress h (data-addr a_getcore))))
          (let ((hr (if (= ent 0) ,nelisp-com-e-nointerface
                      (call-ptr ent 1 ,(nelisp-com-struct-size 'NativeImeCoreApi) (+ e 8)))))
            (if (or ,(nelisp-com-failed 'hr) (= ,valid 0))
                (seq (extern-call FreeLibrary h)
                     (let ((i 0)) (while (< i ,(/ ddskk-shim--mod-entry 8))
                                    (seq (ptr-write-u64 e (* 8 i) 0) (setq i (+ i 1)))))
                     ,nelisp-com-e-nointerface)
              (seq (ptr-write-u64 e 0 h)
                   (let ((i 0))
                     (while (<= i (wbuf_wcslen path))
                       (seq (ptr-write-u16 (+ e 104) (* 2 i) (ptr-read-u16 path (* 2 i)))
                            (setq i (+ i 1)))))
                   (ptr-write-u64 (data-addr mod_n) 0 (+ n 1))
                   (ptr-write-u64 pout 0 e)
                   0)))))
      ;; LoadCore (shim_service.cpp): absolute path, cache, LoadLibraryExW with
      ;; LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|DEFAULT_DIRS, NativeImeGetCoreApi, ABI check.
      (defun mod_load (path pout)
        (if (or (= (mod_isabs path) 0) (>= (wbuf_wcslen path) 519))
            ,nelisp-com-e-invalidarg
          (let ((n (ptr-read-u64 (data-addr mod_n) 0)) (i 0) (found 0))
            (seq (while (< i n)
                   (let ((e (+ (data-addr mod_tab) (* i ,ddskk-shim--mod-entry))))
                     (if (= (mod_ieq (+ e 104) path) 1)
                         (seq (ptr-write-u64 pout 0 e) (setq found 1) (setq i n))
                       (setq i (+ i 1)))))
                 (if (= found 1) 0
                   (if (>= n ,ddskk-shim--mod-max) ,nelisp-com-e-outofmemory
                     (let ((h (extern-call LoadLibraryExW path 0 4352)))
                       (if (= h 0) (hrw (logand (extern-call GetLastError) ,u32))
                         (mod_open h path n pout)))))))))
      ;; Sibling ddskk-ime-core.dll of the shim module; a wbuf or 0.
      (defun svc_sibling_path ()
        (seq (extern-call GetModuleHandleExW 6 (addr-of svc_sibling_path) (data-addr com_hmod))
             (let ((n (logand (extern-call GetModuleFileNameW
                                           (ptr-read-u64 (data-addr com_hmod) 0)
                                           (data-addr com_path) 519)
                              ,u32)))
               (if (= n 0) 0
                 (let ((w (wbuf_from_w (data-addr com_path))))
                   (if (= w 0) 0
                     (seq (p_parent w) (p_join w (data-addr w_core_name)) w)))))))
      ;; RequestedPath(): registry HKCU\Software\NativeIME\CoreDll, else sibling.
      (defun svc_req_path ()
        (seq
         (ptr-write-u64 (data-addr com_size) 0 1036)
         (if (= (logand (extern-call RegOpenKeyExW ,nelisp-com-hkey-current-user
                                     (data-addr w_native) 0 131097 (data-addr com_hkey3))
                        ,u32)
                0)
             (let ((hk (ptr-read-u64 (data-addr com_hkey3) 0)))
               (let ((st (logand (extern-call RegQueryValueExW hk (data-addr w_corevalue) 0
                                              (data-addr com_type) (data-addr com_path)
                                              (data-addr com_size))
                                 ,u32)))
                 (seq (extern-call RegCloseKey hk)
                      (ptr-write-u16 (data-addr com_path) 1038 0)
                      (if (and (= st 0)
                               (and (= (ptr-read-u32 (data-addr com_type) 0) 1)
                                    (/= (ptr-read-u16 (data-addr com_path) 0) 0)))
                          (wbuf_from_w (data-addr com_path))
                        (svc_sibling_path)))))
           (svc_sibling_path)))))))

(defvar ddskk-shim--no-lock nil
  "Non-nil builds the publication lock callback as a no-op (negative control).")

(defun ddskk-shim--callback-forms ()
  "NativeImeCallbacks implementations (called by the core, Win64 ABI)."
  (let ((u32 ddskk-shim--u32) (maxn ddskk-shim--max-ending))
    `((data-blob pub_seq ,(make-list 8 0) data)
      (data-blob pub_cnt ,(make-list 8 0) data)
      (data-blob pub_flushed ,(make-list 8 0) data)
      (data-blob trk_tmp ,(make-list 8 0) data)
      (data-blob pub_cs_flag ,(make-list 8 0) data)
      (data-blob pub_cs ,(make-list 48 0) data)
      ;; Index of IDENTITY in the ending list of B, or 99.
      (defun end_find (b identity)
        (let ((i 0) (r 99) (n ,(ddskk-shim--f 'b 'nending)))
          (seq (while (< i n)
                 (if (= (ptr-read-u64 ,(ddskk-shim--fa 'b 'ending) (* 8 i)) identity)
                     (seq (setq r i) (setq i n))
                   (setq i (+ i 1))))
               r)))
      ;; Remove entry I (already released by the caller).
      (defun end_remove (b i)
        (let ((n ,(ddskk-shim--f 'b 'nending)) (a ,(ddskk-shim--fa 'b 'ending)))
          (seq (while (< (+ i 1) n)
                 (seq (ptr-write-u64 a (* 8 i) (ptr-read-u64 a (* 8 (+ i 1))))
                      (setq i (+ i 1))))
               ,(ddskk-shim--s 'b 'nending '(- n 1))
               0)))
      (defun cb_query (owner guid ppv) (tip_qi owner guid ppv))
      (defun cb_notify (owner) 0)
      ;; TrackEnding: keep an identity reference per ending composition.
      (defun cb_track (owner comp track)
        (if (= comp 0) 0
          (if (/= ,nelisp-com-s-ok
                  (logand ,(nelisp-com-call 'comp 0 '(data-addr tip_iid_unk) '(data-addr trk_tmp))
                          ,u32))
              0
            (let ((identity (ptr-read-u64 (data-addr trk_tmp) 0))
                  (tr (logand track ,u32)))
              (let ((i (end_find owner identity)))
                (if (and (/= tr 0) (= i 99))
                    (if (< ,(ddskk-shim--f 'owner 'nending) ,maxn)
                        (seq (ptr-write-u64 ,(ddskk-shim--fa 'owner 'ending)
                                            (* 8 ,(ddskk-shim--f 'owner 'nending)) identity)
                             ,(ddskk-shim--s 'owner 'nending
                                             `(+ 1 ,(ddskk-shim--f 'owner 'nending)))
                             0)
                      ,(nelisp-com-call 'identity 2))
                  (seq ,(nelisp-com-call 'identity 2)
                       (if (and (= tr 0) (/= i 99))
                           (seq ,(nelisp-com-call `(ptr-read-u64 ,(ddskk-shim--fa 'owner 'ending) (* 8 i)) 2)
                                (end_remove owner i))
                         0)
                       0)))))))
      (defun cb_pubseq (owner) (+ 1 (atomic-fetch-add (data-addr pub_seq) 1)))
      (defun cb_pubdelta (owner delta)
        (let ((d (logand delta ,u32)))
          (if (and (> d 0) (< d 2147483648))
              (+ 1 (atomic-fetch-add (data-addr pub_cnt) 1))
            (- (atomic-fetch-add (data-addr pub_cnt) -1) 1))))
            ;; The C++ shim takes a process-wide std::mutex.  The critical section
      ;; is initialised on first use (the shim has no DllMain); a thread that
      ;; loses the race spins until the winner has finished the initialisation.
      (defun pub_cs_init ()
        (if (= (ptr-read-u64 (data-addr pub_cs_flag) 0) 2) 0
          (if (= (atomic-compare-exchange (data-addr pub_cs_flag) 0 1) 1)
              (seq (extern-call InitializeCriticalSection (data-addr pub_cs))
                   (ptr-write-u64 (data-addr pub_cs_flag) 0 2)
                   0)
            (seq (while (/= (ptr-read-u64 (data-addr pub_cs_flag) 0) 2)
                   (extern-call Sleep 0))
                 0))))
      (defun cb_publock (owner lock)
        ,(if ddskk-shim--no-lock 0
           `(seq (pub_cs_init)
                 (if (/= (logand lock ,u32) 0)
                     (extern-call EnterCriticalSection (data-addr pub_cs))
                   (extern-call LeaveCriticalSection (data-addr pub_cs)))
                 0)))
      ;; Test export: the same callback, callable from a test client.
      (defun DdskkShimPubLock (lock) (cb_publock 0 lock))
      (defun cb_pubflushed (owner value)
        (let ((v (logand value ,u32)))
          (seq (if (/= v 0) (ptr-write-u64 (data-addr pub_flushed) 0 v) 0)
               (ptr-read-u64 (data-addr pub_flushed) 0)))))))

(defun ddskk-shim--service-forms (wrong-slot)
  "Methods of the ShimService object (class `tip').
WRONG-SLOT builds the negative-control mutant that forwards OnKeyDown with
the OnTestKeyDown operation."
  (let ((u32 ddskk-shim--u32)
        (op-down (if wrong-slot (ddskk-shim--op 'test-down) (ddskk-shim--op 'down))))
    `(;; ---- core invocation (Invoke / Key) ----
      (defun tip_new_call ()
        (extern-call HeapAlloc (extern-call GetProcessHeap) 8
                     ,(nelisp-com-struct-size 'NativeImeCall)))
      (defun tip_free_call (a)
        (seq (extern-call HeapFree (extern-call GetProcessHeap) 0 a) 0))
      (defun tip_invoke (b op a)
        (if (or (= ,(ddskk-shim--f 'b 'state) 0) (/= ,(ddskk-shim--f 'b 'switching) 0))
            ,nelisp-com-e-unexpected
          (seq ,(ddskk-shim--s 'b 'calls `(+ 1 ,(ddskk-shim--f 'b 'calls)))
               (let ((hr (call-ptr ,(ddskk-shim--api (ddskk-shim--f 'b 'module) 'invoke)
                                   ,(ddskk-shim--f 'b 'state) op a)))
                 (seq ,(ddskk-shim--s 'b 'calls `(- ,(ddskk-shim--f 'b 'calls) 1))
                      hr)))))
      ;; One NativeImeCall round trip: context, wparam, lparam, eaten, guid.
      (defun tip_dispatch (b op ctx wp lp pe guid)
        (let ((a (tip_new_call)))
          (if (= a 0) ,nelisp-com-e-outofmemory
            (seq ,(nelisp-com-set-field 'a 'NativeImeCall 'context 'ctx)
                 ,(nelisp-com-set-field 'a 'NativeImeCall 'wparam 'wp)
                 ,(nelisp-com-set-field 'a 'NativeImeCall 'lparam 'lp)
                 ,(nelisp-com-set-field 'a 'NativeImeCall 'eaten 'pe)
                 ,(nelisp-com-set-field 'a 'NativeImeCall 'guid 'guid)
                 (let ((hr (tip_invoke b op a)))
                   (seq (tip_free_call a) hr))))))
      ;; Key(): the key_pair_ logic of shim_service.cpp.
      (defun tip_key (b op ctx wp lp pe)
        (seq (if (or (= op 1) (= op 2)) ,(ddskk-shim--s 'b 'key_pair 1) 0)
             (let ((hr (tip_dispatch b op ctx wp lp pe 0)))
               (seq (if (or (= op 4)
                            (and (or (= op 3) (= op 1))
                                 (or (= pe 0) (= (ptr-read-u32 pe 0) 0))))
                        ,(ddskk-shim--s 'b 'key_pair 0)
                      0)
                    hr))))
      ;; ---- ITfKeyEventSink (interface 1, this = base + 16) ----
      (defun tip_setfocus (this focus)
        (tip_dispatch (- this 16) 0 0 (logand focus ,u32) 0 0 0))
      (defun tip_testkd (this ctx wp lp pe) (tip_key (- this 16) 1 ctx wp lp pe))
      (defun tip_testku (this ctx wp lp pe) (tip_key (- this 16) 3 ctx wp lp pe))
      (defun tip_keydown (this ctx wp lp pe) (tip_key (- this 16) ,op-down ctx wp lp pe))
      (defun tip_keyup (this ctx wp lp pe) (tip_key (- this 16) 4 ctx wp lp pe))
      (defun tip_preserved (this ctx guid pe) (tip_dispatch (- this 16) 5 ctx 0 0 pe guid))
      ;; ---- ITfCompositionSink (interface 2, this = base + 24) ----
      (defun tip_term (this ec comp)
        (let ((b (- this 24)))
          (if (and (/= comp 0)
                   (= 0 (logand ,(nelisp-com-call 'comp 0 '(data-addr tip_iid_unk)
                                                  '(data-addr trk_tmp))
                                ,u32)))
              (let ((identity (ptr-read-u64 (data-addr trk_tmp) 0)))
                (let ((i (end_find b identity)))
                  (seq ,(nelisp-com-call 'identity 2)
                       (if (/= i 99)
                           (seq ,(nelisp-com-call `(ptr-read-u64 ,(ddskk-shim--fa 'b 'ending) (* 8 i)) 2)
                                (end_remove b i)
                                0)
                         (tip_dispatch b 6 comp (logand ec ,u32) 0 0 0)))))
            (tip_dispatch b 6 comp (logand ec ,u32) 0 0 0))))
      ;; ---- ITfCompartmentEventSink (interface 3, this = base + 32) ----
      (defun tip_change (this guid) (tip_dispatch (- this 32) 7 0 0 0 0 guid))
      ;; ---- ITfDisplayAttributeProvider (interface 4): attribute info objects
      ;; (display_attribute.cpp) arrive with the composition stages.
      (defun tip_enumdai (this ppenum)
        (if (= ppenum 0) ,nelisp-com-e-pointer
          (seq (ptr-write-u64 ppenum 0 0) ,nelisp-com-e-notimpl)))
      (defun tip_getdai (this guid ppinfo)
        (if (= ppinfo 0) ,nelisp-com-e-pointer
          (seq (ptr-write-u64 ppinfo 0 0) ,nelisp-com-e-notimpl)))
      ;; ---- ITfFunctionProvider (interface 5, this = base + 48) ----
      (defun tip_gettype (this pguid)
        (if (= pguid 0) ,nelisp-com-e-pointer
          (seq (ptr-write-u64 pguid 0 (ptr-read-u64 (data-addr g_clsid) 0))
               (ptr-write-u64 pguid 8 (ptr-read-u64 (data-addr g_clsid) 8))
               0)))
      (defun tip_getdesc (this pbstr)
        (if (= pbstr 0) ,nelisp-com-e-pointer
          (let ((s (extern-call SysAllocString (data-addr w_fn_desc))))
            (seq (ptr-write-u64 pbstr 0 s)
                 (if (= s 0) ,nelisp-com-e-outofmemory 0)))))
      (defun tip_getfunc (this guid riid ppunk)
        (tip_qi (- this 48) riid ppunk))
      ;; ---- ITfFnConfigure (interface 6, this = base + 56) ----
      (defun tip_getdispname (this pbstr) (tip_getdesc this pbstr))
      (defun tip_show (this hwnd langid guid)
        (seq (tip_dispatch (- this 56) 12 0 0 0 0 0) 0))
      ;; ---- teardown ----
      (defun tip_unadvise_keys (b)
        (let ((tm ,(ddskk-shim--f 'b 'tm)))
          (if (= ,(nelisp-com-call 'tm 0 '(data-addr IID_ITfKeystrokeMgr)
                                   (ddskk-shim--fa 'b 'tmp0))
                 0)
              (let ((km ,(ddskk-shim--f 'b 'tmp0)))
                (seq ,(nelisp-com-call 'km 4 (ddskk-shim--f 'b 'id))
                     ,(nelisp-com-call 'km 2)
                     0))
            0)))
      ;; Deactivate(): the teardown order of shim_service.cpp.
      (defun tip_deact (b)
        (seq
         ,(ddskk-shim--s 'b 'switching 1)
         (if (/= ,(ddskk-shim--f 'b 'window) 0)
             (seq (extern-call DestroyWindow ,(ddskk-shim--f 'b 'window))
                  ,(ddskk-shim--s 'b 'window 0) 0)
           0)
         (let ((i 0))
           (while (< i ,(ddskk-shim--f 'b 'nending))
             (seq ,(nelisp-com-call `(ptr-read-u64 ,(ddskk-shim--fa 'b 'ending) (* 8 i)) 2)
                  (setq i (+ i 1)))))
         ,(ddskk-shim--s 'b 'nending 0)
         (if (/= ,(ddskk-shim--f 'b 'comp_src) 0)
             (let ((src ,(ddskk-shim--f 'b 'comp_src)))
               (seq (if (/= ,(ddskk-shim--f 'b 'cookie) ,u32)
                        ,(nelisp-com-call 'src 4 (ddskk-shim--f 'b 'cookie))
                      0)
                    ,(nelisp-com-call 'src 2)
                    ,(ddskk-shim--s 'b 'comp_src 0)
                    ,(ddskk-shim--s 'b 'cookie u32)
                    0))
           0)
         (if (/= ,(ddskk-shim--f 'b 'state) 0)
             (let ((m ,(ddskk-shim--f 'b 'module)) (st ,(ddskk-shim--f 'b 'state)))
               (seq (call-ptr ,(ddskk-shim--api 'm 'deactivate) st)
                    (call-ptr ,(ddskk-shim--api 'm 'destroy) st)
                    ,(ddskk-shim--s 'b 'state 0)
                    0))
           0)
         (if (/= ,(ddskk-shim--f 'b 'tm) 0)
             (let ((tm ,(ddskk-shim--f 'b 'tm)))
               (seq (tip_unadvise_keys b)
                    ,(nelisp-com-call 'tm 2)
                    ,(ddskk-shim--s 'b 'tm 0)
                    0))
           0)
         ,(ddskk-shim--s 'b 'module 0)
         ,(ddskk-shim--s 'b 'key_pair 0)
         ,(ddskk-shim--s 'b 'switching 0)
         0))
      (defun tip_deactivate (this) (tip_deact this))
      (defun tip_on_free (b)
        (seq (tip_deact b)
             (if (= (ptr-read-u64 (data-addr shim_stats) 56) b)
                 (ptr-write-u64 (data-addr shim_stats) 56 0)
               0)
             0))
      ;; ---- Activate ----
      ;; CreateCore: load, fill the callbacks table, core.create.
      (defun tip_create_core (b path)
        (let ((hr (mod_load path ,(ddskk-shim--fa 'b 'module))))
          (if ,(nelisp-com-failed 'hr) hr
            (let ((cb ,(ddskk-shim--fa 'b 'cb)) (m ,(ddskk-shim--f 'b 'module)))
              (seq ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'size
                                          (nelisp-com-struct-size 'NativeImeCallbacks))
                   ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'version 1)
                   ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'owner 'b)
                   ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'query_service '(addr-of cb_query))
                   ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'notify_mode '(addr-of cb_notify))
                   ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'track_ending '(addr-of cb_track))
                   ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'publication_sequence '(addr-of cb_pubseq))
                   ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'publisher_delta '(addr-of cb_pubdelta))
                   ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'publication_lock '(addr-of cb_publock))
                   ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'publication_flushed '(addr-of cb_pubflushed))
                   (let ((hr2 (call-ptr ,(ddskk-shim--api 'm 'create) cb
                                        ,(ddskk-shim--fa 'b 'state))))
                     (if (or ,(nelisp-com-failed 'hr2) (= ,(ddskk-shim--f 'b 'state) 0))
                         (if ,(nelisp-com-failed 'hr2) hr2 ,nelisp-com-e-fail)
                       0)))))))
      ;; Path + CreateCore + core.activate; clears `switching' either way.
      (defun tip_open_core (b)
        (let ((p (svc_req_path)))
          (let ((hr (if (= p 0) ,nelisp-com-e-outofmemory (tip_create_core b (wbuf_ptr p)))))
            (seq (wbuf_free p)
                 (let ((hr2 (if ,(nelisp-com-failed 'hr) hr
                              (call-ptr ,(ddskk-shim--api (ddskk-shim--f 'b 'module) 'activate)
                                        ,(ddskk-shim--f 'b 'state) ,(ddskk-shim--f 'b 'tm)
                                        ,(ddskk-shim--f 'b 'id)))))
                   (seq ,(ddskk-shim--s 'b 'switching 0) hr2))))))
      (defun tip_advise_keys (b)
        (let ((tm ,(ddskk-shim--f 'b 'tm)))
          (let ((h1 ,(nelisp-com-call 'tm 0 '(data-addr IID_ITfKeystrokeMgr)
                                      (ddskk-shim--fa 'b 'tmp0))))
            (if ,(nelisp-com-failed 'h1) h1
              (let ((km ,(ddskk-shim--f 'b 'tmp0)))
                (let ((h2 ,(nelisp-com-call 'km 3 (ddskk-shim--f 'b 'id) '(+ b 16) 1)))
                  (seq ,(nelisp-com-call 'km 2) h2)))))))
      ;; GUID_COMPARTMENT_KEYBOARD_OPENCLOSE advise; failures are ignored (C++).
      (defun tip_advise_comp (b)
        (let ((tm ,(ddskk-shim--f 'b 'tm)))
          (if ,(nelisp-com-succeeded
                (nelisp-com-call 'tm 0 '(data-addr IID_ITfCompartmentMgr)
                                 (ddskk-shim--fa 'b 'tmp0)))
              (let ((cm ,(ddskk-shim--f 'b 'tmp0)))
                (seq ,(ddskk-shim--s 'b 'tmp1 0)
                     (if ,(nelisp-com-succeeded
                           (nelisp-com-call 'cm 3 '(data-addr GUID_COMPARTMENT_KEYBOARD_OPENCLOSE)
                                            (ddskk-shim--fa 'b 'tmp1)))
                         (let ((c ,(ddskk-shim--f 'b 'tmp1)))
                           (seq ,(ddskk-shim--s 'b 'tmp0 0)
                                (if ,(nelisp-com-succeeded
                                      (nelisp-com-call 'c 0 '(data-addr IID_ITfSource)
                                                       (ddskk-shim--fa 'b 'tmp0)))
                                    (let ((src ,(ddskk-shim--f 'b 'tmp0)))
                                      (seq ,(ddskk-shim--s 'b 'comp_src 'src)
                                           ,(ddskk-shim--s 'b 'cookie u32)
                                           ,(nelisp-com-call 'src 3 '(data-addr IID_ITfCompartmentEventSink)
                                                             '(+ b 32) (ddskk-shim--fa 'b 'cookie))
                                           0))
                                  0)
                                ,(nelisp-com-call 'c 2)
                                0))
                       0)
                     ,(nelisp-com-call 'cm 2)
                     0))
            0)))
      ;; Message-only window + 50 ms timer; 1 on success.
      (defun tip_make_window (b)
        (let ((wc (data-addr svc_wc)))
          (seq (extern-call GetModuleHandleExW 6 (addr-of tip_make_window) (data-addr com_hmod))
               ,(nelisp-com-set-field 'wc 'WNDCLASSW 'lpfnWndProc '(addr-of shim_wndproc))
               ,(nelisp-com-set-field 'wc 'WNDCLASSW 'hInstance '(ptr-read-u64 (data-addr com_hmod) 0))
               ,(nelisp-com-set-field 'wc 'WNDCLASSW 'lpszClassName '(data-addr w_winclass))
               (extern-call RegisterClassW wc)
               (let ((w (extern-call CreateWindowExW 0 (data-addr w_winclass) (data-addr w_empty)
                                     0 0 0 0 0 (- 0 3) 0
                                     (ptr-read-u64 (data-addr com_hmod) 0) b)))
                 (if (= w 0) 0
                   (seq ,(ddskk-shim--s 'b 'window 'w)
                        (if (= (extern-call SetTimer w 1 50 0) 0) 0 1)))))))
      (defun shim_wndproc (hwnd msg wp lp)
        (let ((m (logand msg ,u32)))
          (if (= m 129)
              (seq (extern-call SetWindowLongPtrW hwnd (- 0 21) (ptr-read-u64 lp 0))
                   (extern-call DefWindowProcW hwnd msg wp lp))
            (if (= m 1)
                (seq ,(ddskk-shim--stat-inc 0) (extern-call DefWindowProcW hwnd msg wp lp))
              (if (= m 2)
                  (seq ,(ddskk-shim--stat-inc 1) (extern-call DefWindowProcW hwnd msg wp lp))
                (if (= m 275)
                    (let ((s (extern-call GetWindowLongPtrW hwnd (- 0 21))))
                      (seq ,(ddskk-shim--stat-inc 2)
                           (if (/= s 0) (seq (tip_addref s) (tip_release s) 0) 0)
                           0))
                  (extern-call DefWindowProcW hwnd msg wp lp)))))))
      (defun tip_activate (this ptm tid)
        (if (or (= ptm 0) (/= ,(ddskk-shim--f 'this 'tm) 0))
            ,nelisp-com-e-invalidarg
          (seq ,(ddskk-shim--s 'this 'tm 'ptm)
               ,(nelisp-com-call 'ptm 1)
               ,(ddskk-shim--s 'this 'id `(logand tid ,u32))
               ,(ddskk-shim--s 'this 'switching 1)
               (let ((hr (tip_open_core this)))
                 (if ,(nelisp-com-failed 'hr) (seq (tip_deact this) hr)
                   (let ((hr2 (tip_advise_keys this)))
                     (if (progn (ptr-write-u64 (data-addr shim_stats) 48 (logand hr2 ,u32))
                                ,(nelisp-com-failed 'hr2)) (seq (tip_deact this) hr2)
                       (seq (tip_advise_comp this)
                            (if (= (tip_make_window this) 0)
                                (seq (tip_deact this) ,nelisp-com-e-fail)
                              (seq (ptr-write-u64 (data-addr shim_stats) 56 this)
                                   0))))))))))
      (defun tip_activateex (this ptm tid flags) (tip_activate this ptm tid))
      ;; Test-only export (built with :test-exports): counters of the shim.
      ;; 0 windows created, 1 destroyed, 2 timer ticks, 3 key_pair of the last
      ;; activated service, 4 its ITfKeyEventSink, 5 comp_src != 0, 6 HRESULT of the
      ;; last AdviseKeyEventSink.
      (defun DdskkShimStat (i)
        (let ((s (ptr-read-u64 (data-addr shim_stats) 56)))
          (if (= i 6) (ptr-read-u64 (data-addr shim_stats) 48)
          (if (< i 3) (ptr-read-u64 (data-addr shim_stats) (* 8 i))
            (if (= s 0) 0
              (if (= i 3) ,(ddskk-shim--f 's 'key_pair)
                (if (= i 4) (+ s 16)
                  (if (= i 5) (if (= ,(ddskk-shim--f 's 'comp_src) 0) 0 1) 0)))))))))))

(defun ddskk-shim--tip-forms (&optional wrong-slot)
  "ShimService text service (class `tip') and factory."
  (let* ((g #'nelisp-com-msctf-guid)
         (classes
          (nelisp-com-class-forms
           'tip
           :fields `((tm ptr) (id u32) (cookie u32) (comp_src ptr) (window ptr)
                     (module ptr) (state ptr) (key_pair u32) (switching u32)
                     (calls u32) (nending u32) (tmp0 ptr) (tmp1 ptr)
                     (ending (array ptr ,ddskk-shim--max-ending))
                     (cb (struct NativeImeCallbacks)))
           :on-free 'tip_on_free
           :interfaces
           `((:iid ,(funcall g 'IID_ITfTextInputProcessor)
              :methods (tip_activate tip_deactivate tip_activateex))
             (:iid ,(funcall g 'IID_ITfKeyEventSink)
              :methods (tip_setfocus tip_testkd tip_testku tip_keydown tip_keyup
                                     tip_preserved))
             (:iid ,(funcall g 'IID_ITfCompositionSink) :methods (tip_term))
             (:iid ,(funcall g 'IID_ITfCompartmentEventSink) :methods (tip_change))
             (:iid ,(funcall g 'IID_ITfDisplayAttributeProvider)
              :methods (tip_enumdai tip_getdai))
             (:iid ,(funcall g 'IID_ITfFunctionProvider)
              :methods (tip_gettype tip_getdesc tip_getfunc))
             (:iid ,(funcall g 'IID_ITfFnConfigure)
              :methods (tip_getdispname tip_show)))
           :extra-iids `((:iid ,(funcall g 'IID_ITfTextInputProcessorEx) :iface 0)
                         (:iid ,(funcall g 'IID_ITfFunction) :iface 6)))))
    (append
     classes
     (nelisp-com-factory-forms 'tip)
     (ddskk-shim--loader-forms)
     (ddskk-shim--callback-forms)
     (ddskk-shim--service-forms wrong-slot))))

(defun ddskk-shim--export-forms ()
  "The four exports."
  `((defun DllGetClassObject (rclsid riid ppv)
      (if (= ppv 0) ,nelisp-com-e-pointer
        (if ,(nelisp-com-guid= 'rclsid 'g_clsid)
            (tip_f_qi (data-addr tip_fac) riid ppv)
          (seq (ptr-write-u64 ppv 0 0) ,nelisp-com-class-e-classnotavailable))))
    ;; Stable shim and escaped core callbacks are process-lifetime: S_FALSE.
    (defun DllCanUnloadNow () 1)
    (defun DllRegisterServer ()
      (let ((a (shim_reg_com)))
        (if ,(nelisp-com-failed 'a) a
          ,(nelisp-com-try
            '((b (shim_reg_profile)) (c (shim_reg_categories)))
            0
            '(shim_unreg_categories) '(shim_unreg_profile) '(shim_unreg_com)))))
    (defun DllUnregisterServer ()
      (seq (shim_unreg_categories) (shim_unreg_profile) (shim_unreg_com) 0))))

(cl-defun ddskk-shim-forms (&key hive drop-category langid wrong-slot)
  "Return all AOT forms of the shim DLL.
HIVE is `hkcu' (default, parity) or `hkcr' (wine).  DROP-CATEGORY and LANGID
are negative-control hooks."
  (let* ((hive (or hive (nelisp-com-default-hive)))
         (cats (if drop-category (butlast ddskk-shim-categories)
                 ddskk-shim-categories)))
    (append (ddskk-shim--blobs)
            (nelisp-com-wstr-lib-forms)
            (ddskk-shim--path-forms)
            (ddskk-shim--registry-forms hive)
            (ddskk-shim--tsf-forms (or langid ddskk-shim-langid) cats)
            (ddskk-shim--tip-forms wrong-slot)
            (ddskk-shim--export-forms))))

(cl-defun ddskk-shim-build (path &key hive drop-category langid wrong-slot test-exports no-lock)
  "Build the shim DLL at PATH."
  ;; nelisp-link--copy-aot-value recurses along every reloc list (proposed
  ;; nelisp fix: iterate); large units need a raised depth limit.
  (setq max-lisp-eval-depth (max max-lisp-eval-depth 100000))
  (setq ddskk-shim--no-lock no-lock)
  (nelisp-com-build-dll
   path (ddskk-shim-forms :hive hive :drop-category drop-category :langid langid
                          :wrong-slot wrong-slot)
   :exports (if test-exports
                (append ddskk-shim-exports '("DdskkShimStat" "DdskkShimPubLock"))
              ddskk-shim-exports)
   :imports (append ddskk-shim-imports nil)
   :dll-name "ddskk-ime.dll"))

(defun ddskk-shim-build-from-env (path)
  "Build the shim DLL at PATH, taking the test hooks from the environment."
  (ddskk-shim-build
   path
   :drop-category (equal (getenv "NELISP_SHIM_DROP_CATEGORY") "1")
   :langid (and (equal (getenv "NELISP_SHIM_BAD_LANGID") "1") #x0409)
   :wrong-slot (equal (getenv "NELISP_SHIM_WRONG_SLOT") "1")
   :test-exports (equal (getenv "NELISP_SHIM_TEST_EXPORTS") "1")
   :no-lock (equal (getenv "NELISP_SHIM_NOLOCK") "1")))

(provide 'ddskk-shim)
;;; ddskk-shim.el ends here
