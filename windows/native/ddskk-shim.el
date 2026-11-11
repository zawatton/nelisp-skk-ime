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
;; The text service object is a placeholder: ITfTextInputProcessor with the
;; ITfTextInputProcessorEx alias; Activate/ActivateEx/Deactivate return S_OK
;; (S3d fills it in).
;;
;; Build hooks (environment, read by `ddskk-shim-build-from-env'):
;;   NELISP_COM_HIVE=hkcr       register the class under HKEY_CLASSES_ROOT
;;                              (wine's CoCreateInstance ignores HKCU classes)
;;   NELISP_SHIM_DROP_CATEGORY=1  negative control: do not register the last
;;                              category (GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT)
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
     "GetFileAttributesW" "GetProcessHeap" "HeapAlloc" "HeapFree" "HeapReAlloc")
    ("advapi32.dll" "RegCreateKeyExW" "RegSetValueExW" "RegQueryValueExW"
     "RegCloseKey" "RegDeleteTreeW")
    ("ole32.dll" "CoCreateInstance"))
  "Imports of the shim DLL.")

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
              CLSID_TF_CategoryMgr IID_ITfCategoryMgr)
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
              (w_nelisp_exe "nelisp.exe"))
            collect (nelisp-com-wstr-blob name str))
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

(defun ddskk-shim--tip-forms ()
  "Placeholder text service (ITfTextInputProcessor + Ex alias) and factory."
  (append
   (nelisp-com-class-forms
    'tip :state-size 0
    :interfaces `((:iid ,(nelisp-com-msctf-guid 'IID_ITfTextInputProcessor)
                   :methods (tip_activate tip_deactivate tip_activateex)))
    :extra-iids `((:iid ,(nelisp-com-msctf-guid 'IID_ITfTextInputProcessorEx)
                   :iface 0)))
   (nelisp-com-factory-forms 'tip)
   '((defun tip_activate (this ptim tid) 0)
     (defun tip_deactivate (this) 0)
     (defun tip_activateex (this ptim tid flags) 0))))

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

(cl-defun ddskk-shim-forms (&key hive drop-category langid)
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
            (ddskk-shim--tip-forms)
            (ddskk-shim--export-forms))))

(cl-defun ddskk-shim-build (path &key hive drop-category langid)
  "Build the shim DLL at PATH."
  ;; nelisp-link--copy-aot-value recurses along every reloc list (proposed
  ;; nelisp fix: iterate); large units need a raised depth limit.
  (setq max-lisp-eval-depth (max max-lisp-eval-depth 100000))
  (nelisp-com-build-dll
   path (ddskk-shim-forms :hive hive :drop-category drop-category :langid langid)
   :exports ddskk-shim-exports
   :imports (append ddskk-shim-imports nil)
   :dll-name "ddskk-ime.dll"))

(defun ddskk-shim-build-from-env (path)
  "Build the shim DLL at PATH, taking the test hooks from the environment."
  (ddskk-shim-build
   path
   :drop-category (equal (getenv "NELISP_SHIM_DROP_CATEGORY") "1")
   :langid (and (equal (getenv "NELISP_SHIM_BAD_LANGID") "1") #x0409)))

(provide 'ddskk-shim)
;;; ddskk-shim.el ends here
