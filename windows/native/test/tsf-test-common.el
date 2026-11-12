;;; tsf-test-common.el --- shared pieces of the nelisp-built TSF test hosts  -*- lexical-binding: t; -*-

;;; Commentary:

;; Common code for host-wine.el (real msctf under wine) and host-mock.el
;; (mock TSF).  Everything here returns forms in the restricted AOT integer
;; subset of NeLisp, to be linked with `nelisp-com-build-exe'.
;;
;; Locating NeLisp: set NELISP_ROOT, else a sibling checkout named "nelisp"
;; next to this repository, else fail with a clear message.
;;
;; The host loads a TIP DLL from DDSKK_HARNESS_DLL_PATH exactly like
;; windows/test-host/tsf_host.cpp (LoadLibraryW + DllGetClassObject +
;; IClassFactory::CreateInstance(IID_ITfTextInputProcessor)), calls
;; Activate, obtains the TIP's ITfKeyEventSink by QueryInterface and feeds
;; the key script (command-line tokens, grammar of tsf_host.cpp TokenToKey)
;; into the sink.  After each token it prints
;;   AFTER <token> text=<utf8 hex of the buffer> comp=<0/1>
;; All output is buffered and flushed to stdout at exit.
;;
;; Shared document model (globals in blob `hg'): a UTF-16 buffer with one
;; selection and a composition-active flag.  Both hosts keep it there, so
;; one `print_after' serves both.

;;; Code:

(require 'cl-lib)

(defun tsf-find-nelisp-lisp-dir ()
  "Return NeLisp's lisp directory (NELISP_ROOT, else a sibling checkout)."
  (let* ((here (file-name-directory (or load-file-name buffer-file-name
                                        default-directory)))
         (repo (expand-file-name "../../../" here))
         (root (or (getenv "NELISP_ROOT")
                   (let ((sib (expand-file-name "../nelisp" repo)))
                     (and (file-directory-p sib) sib)))))
    (unless (and root (file-exists-p (expand-file-name "lisp/nelisp-com-dsl.el" root)))
      (error "NeLisp not found: set NELISP_ROOT to a checkout with lisp/nelisp-com-dsl.el"))
    (expand-file-name "lisp" root)))

(let ((d (tsf-find-nelisp-lisp-dir)))
  (add-to-list 'load-path d))
(require 'nelisp-com-dsl)
(require 'nelisp-com-wstr-lib)

(defconst tsf-clsid-ddskk "{80b44b14-b866-4ef4-a394-4ff1d87d5185}"
  "CLSID_DdskkTextService (windows/src/guids.h).")
(defconst tsf-iid-ifactory nelisp-com-iid-iclassfactory)

(defconst tsf-host-imports
  '(("kernel32.dll" "ExitProcess" "GetProcessHeap" "HeapAlloc" "HeapFree"
     "WriteFile" "GetStdHandle" "LoadLibraryW" "GetProcAddress" "GetLastError"
     "GetEnvironmentVariableW" "GetCommandLineW" "WideCharToMultiByte" "Sleep")
    ("user32.dll" "MapVirtualKeyW" "GetKeyboardState" "SetKeyboardState"
     "PeekMessageW" "TranslateMessage" "DispatchMessageW")
    ("ole32.dll" "CoInitializeEx" "CoCreateInstance")))

;;;; literal strings and globals

(defvar tsf--lits nil "Alist (STRING . BLOB-SYMBOL) collected while generating.")

(defun tsf/s (str)
  "Return a form giving the address of the NUL-terminated ASCII STR."
  (let ((e (assoc str tsf--lits)))
    (unless e
      (setq e (cons str (intern (format "tl_%d" (length tsf--lits)))))
      (push e tsf--lits))
    `(data-addr ,(cdr e))))

(defun tsf/p (str) "Form printing the literal STR." `(ob_s ,(tsf/s str)))

(defun tsf/lit-blobs ()
  (mapcar (lambda (e) (nelisp-com-ascii-blob (cdr e) (car e)))
          (reverse tsf--lits)))

(defconst tsf/gofs
  '((heap . 0) (ob . 8) (oblen . 16) (scratch . 24) (text . 32) (tlen . 40)
    (sels . 48) (sele . 56) (comp . 64) (comps . 72) (compe . 80) (tip . 88)
    (sink . 96) (tid . 104) (ctx . 112) (tm . 120) (stdout . 128)
    (written . 136) (kbs . 144) (kbsave . 152) (store-sink . 160)
    (n-lock . 168) (n-settext . 176) (n-getsel . 184) (n-gettext . 192)
    (n-ins . 200) (cookie . 208) (atom . 216) (uiid . 224) (rc . 232)
    (kbscratch . 240) (tmp . 248) (ctxo . 256) (viewo . 264))
  "Offsets of the 8-byte global slots in blob `hg'.")

(defun tsf/g (k) `(ptr-read-u64 (data-addr hg) ,(cdr (assq k tsf/gofs))))
(defun tsf/gs (k v) `(ptr-write-u64 (data-addr hg) ,(cdr (assq k tsf/gofs)) ,v))
(defun tsf/ga (k) `(+ (data-addr hg) ,(cdr (assq k tsf/gofs))))
(defun tsf/ginc (k) (tsf/gs k `(+ 1 ,(tsf/g k))))

;;;; Core forms

(defconst tsf/ob-cap 262144)

(defun tsf/key-table ()
  "Named tokens of tsf_host.cpp TokenToKey: (NAME VK SHIFT CTRL)."
  '(("SPACE" #x20 0 0) ("ENTER" #x0D 0 0) ("BS" #x08 0 0) ("ESC" #x1B 0 0)
    ("LEFT" #x25 0 0) ("RIGHT" #x27 0 0) ("SLEFT" #x25 1 0) ("SRIGHT" #x27 1 0)
    ("F6" #x75 0 0) ("F7" #x76 0 0) ("F8" #x77 0 0) ("F9" #x78 0 0)
    ("F10" #x79 0 0) ("UP" #x26 0 0) ("DOWN" #x28 0 0) ("DEL" #x2E 0 0)
    ("HOME" #x24 0 0) ("END" #x23 0 0)))

(defun tsf/core-forms ()
  "Output buffer, hex/utf8 printing, document model, key tokens."
  (let ((g #'tsf/g) (gs #'tsf/gs))
    (append
     (list
      `(data-blob hg ,(make-list 320 0) data)
      `(data-blob hexbuf ,(make-list 32 0) data)
      `(data-blob pathbuf ,(make-list 1040 0) data)
      `(data-blob tmpbuf ,(make-list 64 0) data)
      `(data-blob msgbuf ,(make-list 64 0) data)
      (nelisp-com-wstr-blob 'w_envdll "DDSKK_HARNESS_DLL_PATH")
      (nelisp-com-wstr-blob 'w_envdirect "DDSKK_HARNESS_DIRECT_KEYDOWN")
      (nelisp-com-guid-blob 'g_clsid_tip tsf-clsid-ddskk)
      (nelisp-com-guid-blob 'g_iid_factory tsf-iid-ifactory)
      (nelisp-com-ascii-blob 'a_dgco "DllGetClassObject"))
     (nelisp-com-msctf-blobs '(IID_ITfTextInputProcessor IID_ITfKeyEventSink
                               IID_ITfKeystrokeMgr))
     (cl-loop for (name) in (tsf/key-table)
              collect (nelisp-com-ascii-blob (intern (format "tk_%s" name)) name))
     `(;; ---- output buffer ----
       (defun ob_ch (c)
         (let ((n ,(funcall g 'oblen)))
           (if (< n ,(- tsf/ob-cap 8))
               (seq (ptr-write-u8 ,(funcall g 'ob) n c)
                    ,(funcall gs 'oblen '(+ n 1)) 0)
             0)))
       (defun ob_s (p)
         (let ((i 0))
           (while (/= (ptr-read-u8 p i) 0) (seq (ob_ch (ptr-read-u8 p i)) (setq i (+ i 1))))))
       (defun ob_nl () (ob_ch 10))
       (defun ob_nibble (d) (ob_ch (if (< d 10) (+ 48 d) (+ 87 d))))
       (defun ob_hexn (v n)
         (let ((i 0) (x v))
           (seq (while (< i n)
                  (seq (ptr-write-u8 (data-addr hexbuf) i (logand x 15))
                       (setq x (/ x 16)) (setq i (+ i 1))))
                (while (> i 0)
                  (seq (setq i (- i 1)) (ob_nibble (ptr-read-u8 (data-addr hexbuf) i))))
                0)))
       (defun ob_hex (v)
         (let ((n 1) (x (/ v 16)))
           (seq (while (> x 0) (seq (setq n (+ n 1)) (setq x (/ x 16))))
                (ob_hexn v n))))
       (defun ob_flush ()
         (seq (extern-call WriteFile ,(funcall g 'stdout) ,(funcall g 'ob)
                           ,(funcall g 'oblen) ,(funcall g 'written) 0)
              ,(funcall gs 'oblen 0) 0))
       (defun ob_wascii (p n)
         (let ((i 0)) (while (< i n) (seq (ob_ch (logand (ptr-read-u16 p (* 2 i)) 255)) (setq i (+ i 1))))))
       (defun ob_u8hex (p n)
         (let ((i 0)) (while (< i n) (seq (ob_hexn (ptr-read-u8 p i) 2) (setq i (+ i 1))))))
       ;; UTF-16 -> UTF-8 hex (WideCharToMultiByte CP_UTF8)
       (defun ob_utf8hex (wp n)
         (if (<= n 0) 0
           (let ((len (extern-call WideCharToMultiByte 65001 0 wp n ,(funcall g 'scratch) 16000 0 0)))
             (ob_u8hex ,(funcall g 'scratch) len))))
       (defun ob_wtext (wp n)
         (seq (ob_ch 34) (ob_utf8hex wp n) (ob_ch 34)))
       ;; ---- document model: UTF-16 buffer + selection + composition flag ----
       (defun buf_init ()
         (let ((h (extern-call GetProcessHeap)))
           (seq ,(funcall gs 'heap 'h)
                ,(funcall gs 'ob `(extern-call HeapAlloc h 8 ,tsf/ob-cap))
                ,(funcall gs 'scratch '(extern-call HeapAlloc h 8 16384))
                ,(funcall gs 'text '(extern-call HeapAlloc h 8 16384))
                ,(funcall gs 'written '(extern-call HeapAlloc h 8 16))
                ,(funcall gs 'kbs '(extern-call HeapAlloc h 8 512))
                ,(funcall gs 'stdout '(extern-call GetStdHandle (- 0 11)))
                (if (or (= ,(funcall g 'ob) 0) (= ,(funcall g 'text) 0)) 1 0))))
       ;; Replace units [s,e) by N units at P (P may be 0 when N = 0).
       ;; Returns 0, or 1 when the fixed-size buffer would overflow.
       (defun buf_replace (s0 e0 p n)
         (let* ((len ,(funcall g 'tlen)) (tb ,(funcall g 'text))
                (e (if (> e0 len) len e0))
                (s (if (> s0 e) e s0))
                (tail (- len e)) (newlen (+ (- len (- e s)) n)))
           (if (> newlen 7000) 1
             (seq (if (> n (- e s))
                      (let ((j tail))
                        (while (> j 0)
                          (seq (setq j (- j 1))
                               (ptr-write-u16 tb (* 2 (+ s n j)) (ptr-read-u16 tb (* 2 (+ e j)))))))
                    (let ((j 0))
                      (while (< j tail)
                        (seq (ptr-write-u16 tb (* 2 (+ s n j)) (ptr-read-u16 tb (* 2 (+ e j))))
                             (setq j (+ j 1))))))
                  (let ((i 0))
                    (while (< i n)
                      (seq (ptr-write-u16 tb (* 2 (+ s i)) (ptr-read-u16 p (* 2 i)))
                           (setq i (+ i 1)))))
                  ,(funcall gs 'tlen 'newlen)
                  (ptr-write-u16 tb (* 2 newlen) 0)
                  0))))
       (defun print_after (tok n)
         (seq ,(tsf/p "AFTER ") (ob_wascii tok n) ,(tsf/p " text=")
              (ob_utf8hex ,(funcall g 'text) ,(funcall g 'tlen))
              ,(tsf/p " comp=") (ob_ch (+ 48 ,(funcall g 'comp))) (ob_nl)))
       ;; ---- key tokens ----
       (defun tok_is (p n a)
         (let ((i 0) (ok 1))
           (seq (while (and (< i n) (= ok 1))
                  (seq (if (/= (ptr-read-u16 p (* 2 i)) (ptr-read-u8 a i)) (setq ok 0) 0)
                       (setq i (+ i 1))))
                (if (/= (ptr-read-u8 a n) 0) 0 ok))))
       ;; Returns vk | shift<<8 | ctrl<<9, or 0 for an unknown token.
       (defun tok_to_key (p n)
         ,(let ((chain
                 `(if (= n 1)
                      (let ((c (ptr-read-u16 p 0)))
                        (if (and (>= c 97) (<= c 122)) (- c 32)
                          (if (and (>= c 48) (<= c 57)) c
                            (if (and (>= c 65) (<= c 90)) (+ c 256) 0))))
                    (if (and (= n 5) (tok_is p 4 ,(tsf/s "CTRL"))
                             (>= (ptr-read-u16 p 8) 65) (<= (ptr-read-u16 p 8) 90))
                        (+ (ptr-read-u16 p 8) 512)
                      (if (and (= n 2) (= (ptr-read-u16 p 0) 83)
                               (>= (ptr-read-u16 p 2) 48) (<= (ptr-read-u16 p 2) 57))
                          (+ (ptr-read-u16 p 2) 256)
                        0)))))
            (dolist (e (reverse (tsf/key-table)) chain)
              (setq chain
                    `(if (tok_is p n (data-addr ,(intern (format "tk_%s" (car e)))))
                         ,(+ (nth 1 e) (* 256 (nth 2 e)) (* 512 (nth 3 e)))
                       ,chain))))))
     (list
      `(defun pump ()
         (let ((more 1))
           (while (= more 1)
             (if (= (extern-call PeekMessageW (data-addr msgbuf) 0 0 0 1) 0) (setq more 0)
               (seq (extern-call TranslateMessage (data-addr msgbuf))
                    (extern-call DispatchMessageW (data-addr msgbuf)))))))
      `(defun env_is_one (wname)
         (let ((n (extern-call GetEnvironmentVariableW wname (data-addr tmpbuf) 8)))
           (if (and (= n 1) (= (ptr-read-u16 (data-addr tmpbuf) 0) 49)) 1 0)))
      ;; One scripted key through the TIP's ITfKeyEventSink (SendScriptedKey).
      `(defun send_key (sink ctx code)
         (let* ((vk (logand code 255)) (shift (logand (/ code 256) 1))
                (ctrl (logand (/ code 512) 1))
                (kb ,(funcall g 'kbs))
                (scan (extern-call MapVirtualKeyW vk 0))
                (lpd (+ (* scan 65536) 1))
                (lpu (+ lpd 3221225472))
                (eaten (data-addr tmpbuf)))
           (seq (extern-call GetKeyboardState kb)
                (if (= shift 1) (ptr-write-u8 kb 16 (logior (ptr-read-u8 kb 16) 128)) 0)
                (if (= ctrl 1) (ptr-write-u8 kb 17 (logior (ptr-read-u8 kb 17) 128)) 0)
                (extern-call SetKeyboardState kb)
                (ptr-write-u32 eaten 0 0)
                (if (= (env_is_one (data-addr w_envdirect)) 1)
                    (seq (ptr-write-u32 eaten 0 1) 0)
                  ,(nelisp-com-call 'sink 4 'ctx 'vk 'lpd 'eaten))
                (if (= (ptr-read-u32 eaten 0) 0) 0
                  ,(nelisp-com-call 'sink 6 'ctx 'vk 'lpd 'eaten))
                (ptr-write-u32 eaten 0 0)
                ,(nelisp-com-call 'sink 5 'ctx 'vk 'lpu 'eaten)
                (if (= (ptr-read-u32 eaten 0) 0) 0
                  ,(nelisp-com-call 'sink 7 'ctx 'vk 'lpu 'eaten))
                (pump)
                (ptr-write-u8 kb 16 0) (ptr-write-u8 kb 17 0)
                (extern-call SetKeyboardState kb)
                0)))
      ;; Tokenise GetCommandLineW (after the program name) and run each token.
      `(defun run_script (sink ctx)
         (let* ((cl (extern-call GetCommandLineW)) (i 0) (done 0))
           (seq (if (= (ptr-read-u16 cl 0) 34)
                    (seq (setq i 1)
                         (while (and (/= (ptr-read-u16 cl (* 2 i)) 34) (/= (ptr-read-u16 cl (* 2 i)) 0))
                           (setq i (+ i 1)))
                         (if (= (ptr-read-u16 cl (* 2 i)) 34) (setq i (+ i 1)) 0))
                  (while (and (/= (ptr-read-u16 cl (* 2 i)) 32) (/= (ptr-read-u16 cl (* 2 i)) 0))
                    (setq i (+ i 1))))
                (while (= done 0)
                  (seq (while (or (= (ptr-read-u16 cl (* 2 i)) 32) (= (ptr-read-u16 cl (* 2 i)) 9))
                         (setq i (+ i 1)))
                       (if (= (ptr-read-u16 cl (* 2 i)) 0) (setq done 1)
                         (let ((st i))
                           (seq (while (and (/= (ptr-read-u16 cl (* 2 i)) 32)
                                            (/= (ptr-read-u16 cl (* 2 i)) 9)
                                            (/= (ptr-read-u16 cl (* 2 i)) 0))
                                  (setq i (+ i 1)))
                                (let* ((tp (+ cl (* 2 st))) (tn (- i st)) (code (tok_to_key tp tn)))
                                  (seq (if (= code 0)
                                           (seq ,(tsf/p "HR UnknownToken:") (ob_wascii tp tn)
                                                ,(tsf/p "=80070057") (ob_nl))
                                         (send_key sink ctx code))
                                       (print_after tp tn))))))))
                0)))
      ;; Load the TIP DLL from DDSKK_HARNESS_DLL_PATH; returns the TIP or 0.
      `(defun load_tip ()
         (let ((n (extern-call GetEnvironmentVariableW (data-addr w_envdll) (data-addr pathbuf) 520)))
           (if (or (= n 0) (>= n 520)) 0
             (let ((m (extern-call LoadLibraryW (data-addr pathbuf))))
               (if (= m 0)
                   (seq ,(tsf/p "HR LoadLibraryW(DDSKK_HARNESS_DLL_PATH)=")
                        (ob_hexn (extern-call GetLastError) 8) (ob_nl) 0)
                 (let ((gco (extern-call GetProcAddress m (data-addr a_dgco))))
                   (if (= gco 0) (extern-call ExitProcess 90)
                     (let ((hr (call-ptr gco (data-addr g_clsid_tip) (data-addr g_iid_factory)
                                         (data-addr tmpbuf))))
                       (if (/= (logand hr 2147483648) 0)
                           (seq ,(tsf/p "HR DllGetClassObject(DDSKK_HARNESS_DLL_PATH)=")
                                (ob_hexn hr 8) (ob_nl) 0)
                         (let ((fac (ptr-read-u64 (data-addr tmpbuf) 0)))
                           (seq (ptr-write-u64 (data-addr tmpbuf) 8 0)
                                (let ((hr2 ,(nelisp-com-call 'fac 3 0 '(data-addr IID_ITfTextInputProcessor)
                                                             '(+ (data-addr tmpbuf) 8))))
                                  (seq ,(nelisp-com-call 'fac 2)
                                       (if (/= (logand hr2 2147483648) 0)
                                           (seq ,(tsf/p "HR IClassFactory::CreateInstance(DDSKK_HARNESS_DLL_PATH)=")
                                                (ob_hexn hr2 8) (ob_nl) 0)
                                         (seq ,(tsf/p "TIP_DIRECT loaded from DDSKK_HARNESS_DLL_PATH") (ob_nl)
                                              (ptr-read-u64 (data-addr tmpbuf) 8))))))))))))))))
      ;; Common host flow once the host objects exist.  Returns the exit code.
      `(defun host_run (tm tid ctx)
         (let ((tip (load_tip)))
           (if (= tip 0) (seq ,(tsf/p "FAIL no TIP loaded") (ob_nl) 3)
             (seq ,(tsf/gs 'tip 'tip)
                  (let ((hr ,(nelisp-com-call 'tip 3 'tm 'tid)))
                    (seq ,(tsf/p "HR Activate=") (ob_hexn hr 8) (ob_nl)
                         (ptr-write-u64 (data-addr tmpbuf) 16 0)
                         (let ((hr2 ,(nelisp-com-call 'tip 0 '(data-addr IID_ITfKeyEventSink)
                                                      '(+ (data-addr tmpbuf) 16))))
                           (if (/= (logand hr2 2147483648) 0)
                               (seq ,(tsf/p "FAIL no ITfKeyEventSink") (ob_nl) 4)
                             (let ((sink (ptr-read-u64 (data-addr tmpbuf) 16)))
                               (seq ,(tsf/gs 'sink 'sink)
                                    (run_script sink ctx)
                                    ,(nelisp-com-call 'sink 2)
                                    (let ((hr3 ,(nelisp-com-call 'tip 4)))
                                      (seq ,(tsf/p "HR Deactivate=") (ob_hexn hr3 8) (ob_nl)))
                                    ,(nelisp-com-call 'tip 2)
                                    0))))))))))))))

(defun tsf-build-exe (path forms)
  "Link FORMS (host forms + core + literal blobs) into PATH."
  ;; nelisp-link--copy-aot-value recurses along every reloc list; big hosts
  ;; exceed the default depth (proposed nelisp fix: iterate).
  (setq max-lisp-eval-depth (max max-lisp-eval-depth 100000))
  (nelisp-com-build-exe path forms tsf-host-imports))

(provide 'tsf-test-common)
;;; tsf-test-common.el ends here
