;;; host-mock.el --- mock TSF host (fake thread manager, context, range, ...)  -*- lexical-binding: t; -*-

;;; Commentary:

;; host-mock.exe runs the shared TIP loader/key-script runner of
;; tsf-test-common.el against fake TSF objects built with nelisp, because the
;; composition path (ITfContextComposition, ITfRange::SetText, display
;; attribute properties, caret rect) is not usable on wine's msctf.
;;
;; Fake objects (all COM classes from `nelisp-com-class-forms'):
;;   tm   one object answering ITfThreadMgr, ITfKeystrokeMgr, ITfCompartmentMgr,
;;        ITfUIElementMgr, ITfSource, ITfLangBarItemMgr, ITfCategoryMgr.  The
;;        last two are mock-only routes: a production TIP obtains them through
;;        CoCreateInstance, which this host cannot intercept (see S3d notes).
;;   ctx  ITfContext + ITfInsertAtSelection + ITfContextComposition
;;   rng  ITfRange {start,end}      cmp  ITfComposition (range + sink)
;;   prop ITfProperty               view ITfContextView
;;   cpt  ITfCompartment (VARIANT store)
;; The document is the shared UTF-16 buffer of tsf-test-common.el.
;;
;; Trace: every method prints one line `Interface::Method arg ...' (QueryInterface,
;; AddRef and Release are not traced).  Arguments are rendered deterministically:
;; integers as hex (u32), pointers as `P' or `0', GUIDs as their first dword,
;; ranges as r[start,end], text as "<utf8 hex>", VARIANTs as vt=.. val=..;
;; out-parameters are not printed.  Unimplemented methods return E_NOTIMPL
;; after tracing, so a TIP touching new surface shows up in the trace.
;;
;; Extending: add a spec `(Name (params) (kinds) [body])' to the relevant
;; table below.  Kinds: x u32 hex, p pointer, g GUID, r range object, v VARIANT,
;; (w CCH-VAR) wide text whose length is the parameter CCH-VAR, - not printed.

;;; Code:

(require 'cl-lib)
(require 'tsf-test-common)

(defconst hm/e-notimpl 2147500033)
(defconst hm/e-oom 2147942414)
(defconst hm/ec 4097 "Edit cookie handed to edit sessions.")

(defun hm/arg (kind v)
  (pcase kind
    ('x `(seq (ob_ch 32) (ob_hex (logand ,v 4294967295))))
    ('p `(seq (ob_ch 32) (ob_ch (if (= ,v 0) 48 80))))
    ('g `(seq (ob_ch 32) (if (= ,v 0) (ob_ch 48) (ob_hexn (ptr-read-u32 ,v 0) 8))))
    ('r `(seq (ob_ch 32) (hm_pr ,v)))
    ('v `(seq (ob_ch 32) (if (= ,v 0) (ob_ch 48)
                           (seq ,(tsf/p "vt=") (ob_hex (ptr-read-u16 ,v 0)) ,(tsf/p ",val=")
                                (ob_hex (logand (ptr-read-u32 ,v 8) 4294967295))))))
    (`(w ,c) `(seq (ob_ch 32) (ob_wtext ,v ,c)))
    (_ 0)))

(defun hm/method (prefix iface self spec)
  (let* ((name (nth 0 spec)) (params (nth 1 spec)) (kinds (nth 2 spec))
         (body (or (nth 3 spec) hm/e-notimpl))
         (sym (intern (format "%s_%s" prefix (downcase name)))))
    `(defun ,sym (this ,@params)
       (seq ,(tsf/p (format "%s::%s" iface name))
            ,@(if self '((ob_ch 32) (hm_pr this)) nil)
            ,@(cl-mapcar #'hm/arg kinds params)
            (ob_nl)
            ,body))))

(defun hm/iface (prefix iface specs &optional self)
  "Return (METHOD-SYMS . DEFUNS) for SPECS of interface IFACE."
  (cons (mapcar (lambda (s) (intern (format "%s_%s" prefix (downcase (car s))))) specs)
        (mapcar (lambda (s) (hm/method prefix iface self s)) specs)))

(defun hm/class (class ifaces &rest keys)
  "Forms for CLASS from IFACES, a list of (IID-NAME PREFIX IFACE SPECS &optional SELF)."
  (let (defuns ifdefs)
    (dolist (i ifaces)
      (let ((r (let ((prefix (nth 1 i)) (iface (nth 2 i)) (specs (nth 3 i)) (self (nth 4 i)))
                 (hm/iface prefix iface specs self))))
        (push `(:iid ,(nelisp-com-msctf-guid (nth 0 i)) :methods ,(car r)) ifdefs)
        (setq defuns (append defuns (cdr r)))))
    (append (apply #'nelisp-com-class-forms class :interfaces (nreverse ifdefs) keys)
            defuns)))

(defmacro hm/g (k) `(tsf/g ',k))
(defmacro hm/gs (k v) `(tsf/gs ',k ,v))

;;;; method tables

(defun hm/tm-specs ()
  `(("Activate" (ptid) (-) (seq (ptr-write-u32 ptid 0 7) 0))
    ("Deactivate" () ())
    ("CreateDocumentMgr" (pp) (-))
    ("EnumDocumentMgrs" (pp) (-))
    ("GetFocus" (pp) (-))
    ("SetFocus" (pdim) (p) 0)
    ("AssociateFocus" (hwnd pdim pprev) (x p -))
    ("IsThreadFocus" (pf) (-) (seq (ptr-write-u32 pf 0 1) 0))
    ("GetFunctionProvider" (clsid pp) (g -))
    ("EnumFunctionProviders" (pp) (-))
    ("GetGlobalCompartment" (pp) (-))))

(defun hm/ks-specs ()
  `(("AdviseKeyEventSink" (tid sink fg) (x p x) (seq ,(tsf/gs 'store-sink 'sink) 0))
    ("UnadviseKeyEventSink" (tid) (x) 0)
    ("GetForeground" (pclsid) (-))
    ("TestKeyDown" (wp lp pf) (x x -) (seq (ptr-write-u32 pf 0 0) 0))
    ("TestKeyUp" (wp lp pf) (x x -) (seq (ptr-write-u32 pf 0 0) 0))
    ("KeyDown" (wp lp pf) (x x -) (seq (ptr-write-u32 pf 0 0) 0))
    ("KeyUp" (wp lp pf) (x x -) (seq (ptr-write-u32 pf 0 0) 0))
    ("GetPreservedKey" (pic pkey pguid) (p - -))
    ("IsPreservedKey" (guid pkey pf) (g - -))
    ("PreserveKey" (tid guid pkey pch cch) (x g - - x) 0)
    ("UnpreserveKey" (guid pkey) (g -) 0)
    ("SetPreservedKeyDescription" (guid pch cch) (g (w cch) x) 0)
    ("GetPreservedKeyDescription" (guid pbstr) (g -))
    ("SimulatePreservedKey" (pic guid pf) (p g -))))

(defun hm/cm-specs ()
  `(("GetCompartment" (guid pp) (g -)
     (let ((c (cpt_new)))
       (if (= c 0) ,hm/e-oom (seq (ptr-write-u64 pp 0 c) 0))))
    ("ClearCompartment" (tid guid) (x g) 0)
    ("EnumCompartments" (pp) (-))))

(defun hm/cpt-specs ()
  `(("SetValue" (tid pvar) (x v)
     (seq (ptr-write-u64 this 16 (ptr-read-u64 pvar 0))
          (ptr-write-u64 this 24 (ptr-read-u64 pvar 8)) 0))
    ("GetValue" (pvar) (-)
     (seq (ptr-write-u64 pvar 0 (ptr-read-u64 this 16))
          (ptr-write-u64 pvar 8 (ptr-read-u64 this 24)) 0))))

(defun hm/um-specs ()
  `(("BeginUIElement" (pel pbshow pid) (p - -)
     (seq ,(tsf/ginc 'uiid) (ptr-write-u32 pbshow 0 1) (ptr-write-u32 pid 0 ,(tsf/g 'uiid)) 0))
    ("UpdateUIElement" (id) (x) 0)
    ("EndUIElement" (id) (x) 0)
    ("GetUIElement" (id pp) (x -))
    ("EnumUIElements" (pp) (-))))

(defun hm/src-specs ()
  `(("AdviseSink" (riid punk pcookie) (g p -)
     (seq ,(tsf/ginc 'cookie) (ptr-write-u32 pcookie 0 (+ 100 ,(tsf/g 'cookie))) 0))
    ("UnadviseSink" (cookie) (x) 0)))

(defun hm/lb-specs ()
  `(("EnumItems" (pp) (-))
    ("GetItem" (guid pp) (g -))
    ("AddItem" (pitem) (p) 0)
    ("RemoveItem" (pitem) (p) 0)
    ("AdviseItemSink" (psink pcookie guid) (p - g)
     (seq ,(tsf/ginc 'cookie) (ptr-write-u32 pcookie 0 (+ 200 ,(tsf/g 'cookie))) 0))
    ("UnadviseItemSink" (cookie) (x) 0)
    ("GetItemFloatingRect" (tid guid prc) (x g -))
    ("GetItemsStatus" (ul pguid pdw) (x - -))
    ("GetItemNum" (pul) (-) (seq (ptr-write-u32 pul 0 0) 0))
    ("GetItems" (ul pp pinfo pdw pf) (x - - - -))
    ("AdviseItemsSink" (ul ppunk pguid pdw) (x - - -))
    ("UnadviseItemsSink" (ul pdw) (x -))))

(defun hm/cat-specs ()
  `(("RegisterCategory" (clsid cat guid) (g g g) 0)
    ("UnregisterCategory" (clsid cat guid) (g g g) 0)
    ("EnumCategoriesInItem" (guid pp) (g -))
    ("EnumItemsInCategory" (cat pp) (g -))
    ("FindClosestCategory" (guid pcat plist ul) (g - - x))
    ("RegisterGUIDDescription" (clsid guid pch cch) (g g (w cch) x) 0)
    ("UnregisterGUIDDescription" (clsid guid) (g g) 0)
    ("GetGUIDDescription" (guid pbstr) (g -))
    ("RegisterGUIDDWORD" (clsid guid dw) (g g x) 0)
    ("UnregisterGUIDDWORD" (clsid guid) (g g) 0)
    ("GetGUIDDWORD" (guid pdw) (g -))
    ("RegisterGUID" (guid patom) (g -)
     (seq ,(tsf/ginc 'atom) (ptr-write-u32 patom 0 (+ 256 ,(tsf/g 'atom))) 0))
    ("GetGUID" (atom pguid) (x -))
    ("IsEqualTfGuidAtom" (atom guid pf) (x g -) (seq (ptr-write-u32 pf 0 1) 0))))

(defun hm/ctx-specs ()
  `(("RequestEditSession" (tid pes flags phr) (x p x -)
     (let ((hrs ,(nelisp-com-call 'pes 3 hm/ec)))
       (seq (if (= phr 0) 0 (ptr-write-u32 phr 0 hrs)) 0)))
    ("InWriteSession" (tid pf) (x -))
    ("GetSelection" (ec idx cnt psel pfetched) (x x x - -)
     (let ((r (rng_new)))
       (if (= r 0) ,hm/e-oom
         (seq (ptr-write-u64 r 16 ,(tsf/g 'sels)) (ptr-write-u64 r 24 ,(tsf/g 'sele))
              (ptr-write-u64 psel 0 r) (ptr-write-u32 psel 8 2) (ptr-write-u32 psel 12 0)
              (ptr-write-u32 pfetched 0 1) 0))))
    ("SetSelection" (ec cnt psel) (x x -)
     (let ((r (ptr-read-u64 psel 0)))
       (seq ,(tsf/gs 'sels '(ptr-read-u64 r 16)) ,(tsf/gs 'sele '(ptr-read-u64 r 24)) 0)))
    ("GetStart" (ec pp) (x -)
     (let ((r (rng_new)))
       (if (= r 0) ,hm/e-oom (seq (ptr-write-u64 pp 0 r) 0))))
    ("GetEnd" (ec pp) (x -)
     (let ((r (rng_new)))
       (if (= r 0) ,hm/e-oom
         (seq (ptr-write-u64 r 16 ,(tsf/g 'tlen)) (ptr-write-u64 r 24 ,(tsf/g 'tlen))
              (ptr-write-u64 pp 0 r) 0))))
    ("GetActiveView" (pp) (-)
     (let ((v ,(tsf/g 'viewo)))
       (seq (view_addref v) (ptr-write-u64 pp 0 v) 0)))
    ("EnumViews" (pp) (-))
    ("GetStatus" (pdcs) (-) (seq (ptr-write-u32 pdcs 0 0) (ptr-write-u32 pdcs 4 0) 0))
    ("GetProperty" (guid pp) (g -)
     (let ((p (prop_new))) (if (= p 0) ,hm/e-oom (seq (ptr-write-u64 pp 0 p) 0))))
    ("GetAppProperty" (guid pp) (g -))
    ("TrackProperties" (prg cprop papp capp pp) (- x - x -))
    ("EnumProperties" (pp) (-))
    ("GetDocumentMgr" (pp) (-))
    ("CreateRangeBackup" (ec pp) (x -))))

(defun hm/ias-specs ()
  `(("InsertTextAtSelection" (ec flags pch cch pprange) (x x (w cch) x -)
     (let ((s ,(tsf/g 'sels)) (e ,(tsf/g 'sele)))
       (if (/= (logand flags 2) 0)
           (seq (if (= pprange 0) 0
                  (let ((r (rng_new)))
                    (seq (ptr-write-u64 r 16 s) (ptr-write-u64 r 24 e)
                         (ptr-write-u64 pprange 0 r))))
                0)
         (if (/= (buf_replace s e pch cch) 0) ,hm/e-oom
           (seq ,(tsf/gs 'sels '(+ s cch)) ,(tsf/gs 'sele '(+ s cch))
                (if (= pprange 0) 0
                  (let ((r (rng_new)))
                    (seq (ptr-write-u64 r 16 s) (ptr-write-u64 r 24 (+ s cch))
                         (ptr-write-u64 pprange 0 r))))
                0)))))
    ("InsertEmbeddedAtSelection" (ec flags pobj pprange) (x x p -))))

(defun hm/cc-specs ()
  `(("StartComposition" (ec prange psink ppcomp) (x r p -)
     (if (/= ,(tsf/g 'comp) 0) 2147746312
       (let ((c (cmp_new)))
         (if (= c 0) ,hm/e-oom
           (seq ,(tsf/gs 'comp 1)
                ,(tsf/gs 'comps '(ptr-read-u64 prange 16))
                ,(tsf/gs 'compe '(ptr-read-u64 prange 24))
                (ptr-write-u64 c 16 psink) (ptr-write-u64 ppcomp 0 c) 0)))))
    ("EnumCompositions" (pp) (-))
    ("FindComposition" (ec prange pp) (x r -))
    ("TakeOwnership" (ec pcomp psink ppcomp) (x p p -))))

(defun hm/rng-specs ()
  `(("GetText" (ec flags pch cchmax pcch) (x x - x -)
     (let* ((s (ptr-read-u64 this 16)) (e (ptr-read-u64 this 24))
            (n (if (> (- e s) cchmax) cchmax (- e s))) (i 0))
       (seq (while (< i n)
              (seq (ptr-write-u16 pch (* 2 i) (ptr-read-u16 ,(tsf/g 'text) (* 2 (+ s i))))
                   (setq i (+ i 1))))
            (ptr-write-u32 pcch 0 n) 0)))
    ("SetText" (ec flags pch cch) (x x (w cch) x)
     (let ((s (ptr-read-u64 this 16)) (e (ptr-read-u64 this 24)))
       (if (/= (buf_replace s e pch cch) 0) ,hm/e-oom
         (seq (ptr-write-u64 this 24 (+ s cch))
              (if (and (/= ,(tsf/g 'comp) 0) (= s ,(tsf/g 'comps)))
                  ,(tsf/gs 'compe '(+ s cch)) 0)
              ,(tsf/gs 'sels '(+ s cch)) ,(tsf/gs 'sele '(+ s cch)) 0))))
    ("GetFormattedText" (ec pp) (x -))
    ("GetEmbedded" (ec guid riid pp) (x g g -))
    ("InsertEmbedded" (ec flags pobj) (x x p))
    ("ShiftStart" (ec cch pcch phalt) (x x - -)
     (let* ((s (ptr-read-u64 this 16)) (e (ptr-read-u64 this 24)) (ns (+ s cch)))
       (seq (if (< ns 0) (setq ns 0) 0) (if (> ns e) (setq ns e) 0)
            (ptr-write-u64 this 16 ns)
            (if (= pcch 0) 0 (ptr-write-u32 pcch 0 (- ns s))) 0)))
    ("ShiftEnd" (ec cch pcch phalt) (x x - -)
     (let* ((s (ptr-read-u64 this 16)) (e (ptr-read-u64 this 24)) (ne (+ e cch)))
       (seq (if (< ne s) (setq ne s) 0) (if (> ne ,(tsf/g 'tlen)) (setq ne ,(tsf/g 'tlen)) 0)
            (ptr-write-u64 this 24 ne)
            (if (= pcch 0) 0 (ptr-write-u32 pcch 0 (- ne e))) 0)))
    ("ShiftStartToRange" (ec prange pos) (x r x))
    ("ShiftEndToRange" (ec prange pos) (x r x))
    ("ShiftStartRegion" (ec dir pnoregion) (x x -))
    ("ShiftEndRegion" (ec dir pnoregion) (x x -))
    ("IsEmpty" (ec pf) (x -)
     (seq (ptr-write-u32 pf 0 (if (= (ptr-read-u64 this 16) (ptr-read-u64 this 24)) 1 0)) 0))
    ("Collapse" (ec apos) (x x)
     (seq (if (= apos 0) (ptr-write-u64 this 24 (ptr-read-u64 this 16))
            (ptr-write-u64 this 16 (ptr-read-u64 this 24))) 0))
    ("IsEqualStart" (ec pwith pos pf) (x r x -))
    ("IsEqualEnd" (ec pwith pos pf) (x r x -))
    ("CompareStart" (ec pwith pos pl) (x r x -))
    ("CompareEnd" (ec pwith pos pl) (x r x -))
    ("AdjustForInsert" (ec cch pok) (x x -))
    ("GetGravity" (pgs pge) (- -))
    ("SetGravity" (ec gs ge) (x x x) 0)
    ("Clone" (pp) (-)
     (let ((r (rng_new)))
       (if (= r 0) ,hm/e-oom
         (seq (ptr-write-u64 r 16 (ptr-read-u64 this 16)) (ptr-write-u64 r 24 (ptr-read-u64 this 24))
              (ptr-write-u64 pp 0 r) 0))))
    ("GetContext" (pp) (-)
     (let ((c ,(tsf/g 'ctxo))) (seq (ctx_addref c) (ptr-write-u64 pp 0 c) 0)))))

(defun hm/cmp-specs ()
  `(("GetRange" (pp) (-)
     (let ((r (rng_new)))
       (if (= r 0) ,hm/e-oom
         (seq (ptr-write-u64 r 16 ,(tsf/g 'comps)) (ptr-write-u64 r 24 ,(tsf/g 'compe))
              (ptr-write-u64 pp 0 r) 0))))
    ("ShiftStart" (ec pnew) (x r) (seq ,(tsf/gs 'comps '(ptr-read-u64 pnew 16)) 0))
    ("ShiftEnd" (ec pnew) (x r) (seq ,(tsf/gs 'compe '(ptr-read-u64 pnew 24)) 0))
    ("EndComposition" (ec) (x)
     (seq ,(tsf/gs 'comp 0)
          ;; DDSKK_HARNESS-style hosts call the sink synchronously (ts.cpp 2840).
          (let ((sk (ptr-read-u64 this 16)))
            (if (and (/= sk 0) (/= ,(tsf/g 'endsink) 0))
                ,(nelisp-com-call 'sk 3 'ec 'this)
              0))
          0))))

(defun hm/prop-specs ()
  `(("GetType" (pguid) (-))
    ("EnumRanges" (ec pp prange) (x - r))
    ("GetValue" (ec prange pvar) (x r -) (seq (ptr-write-u16 pvar 0 0) 0))
    ("GetContext" (pp) (-))
    ("FindRange" (ec prange pp pos) (x r - x))
    ("SetValueStore" (ec prange pstore) (x r p))
    ("SetValue" (ec prange pvar) (x r v) 0)
    ("Clear" (ec prange) (x r) 0)))

(defun hm/view-specs ()
  `(("GetRangeFromPoint" (ec ppt flags pp) (x - x -))
    ("GetTextExt" (ec prange prc pclip) (x r - -)
     (seq (ptr-write-u32 prc 0 10) (ptr-write-u32 prc 4 20) (ptr-write-u32 prc 8 30)
          (ptr-write-u32 prc 12 40) (ptr-write-u32 pclip 0 0) 0))
    ("GetScreenExt" (prc) (-))
    ("GetWnd" (phwnd) (-) (seq (ptr-write-u64 phwnd 0 0) 0))))

(defun hm/object-forms ()
  "Fake TSF objects (no entry point)."
  (append
   (list '(defun hm_pr (r)
            (if (= r 0) (ob_ch 48)
              (seq (ob_ch 114) (ob_ch 91) (ob_hex (ptr-read-u64 r 16)) (ob_ch 44)
                   (ob_hex (ptr-read-u64 r 24)) (ob_ch 93)))))
   (hm/class 'tm
             `((IID_ITfThreadMgr tmg "ITfThreadMgr" ,(hm/tm-specs))
               (IID_ITfKeystrokeMgr ksm "ITfKeystrokeMgr" ,(hm/ks-specs))
               (IID_ITfCompartmentMgr cmg "ITfCompartmentMgr" ,(hm/cm-specs))
               (IID_ITfUIElementMgr umg "ITfUIElementMgr" ,(hm/um-specs))
               (IID_ITfSource src "ITfSource" ,(hm/src-specs))
               (IID_ITfLangBarItemMgr lbm "ITfLangBarItemMgr" ,(hm/lb-specs))
               (IID_ITfCategoryMgr cat "ITfCategoryMgr" ,(hm/cat-specs))))
   (hm/class 'ctx
             `((IID_ITfContext cx "ITfContext" ,(hm/ctx-specs))
               (IID_ITfInsertAtSelection ias "ITfInsertAtSelection" ,(hm/ias-specs))
               (IID_ITfContextComposition ccm "ITfContextComposition" ,(hm/cc-specs))))
   (hm/class 'rng `((IID_ITfRange rg "ITfRange" ,(hm/rng-specs) t)) :state-size 16)
   (hm/class 'cmp `((IID_ITfComposition cp "ITfComposition" ,(hm/cmp-specs))) :state-size 16)
   (hm/class 'prop `((IID_ITfProperty pr "ITfProperty" ,(hm/prop-specs))))
   (hm/class 'view `((IID_ITfContextView vw "ITfContextView" ,(hm/view-specs))))
   (hm/class 'cpt `((IID_ITfCompartment cpt "ITfCompartment" ,(hm/cpt-specs))) :state-size 16)))

(defun hm/forms ()
  (append
   (hm/object-forms)
   `((defun st (n hr) (if (/= (logand hr 2147483648) 0)
                          (seq ,(tsf/p "FAIL step=") (ob_hex n) (ob_nl) (ob_flush) (extern-call ExitProcess n))
                        0))
     (defun _start ()
       (seq
        (if (/= (buf_init) 0) (extern-call ExitProcess 2) 0)
        (let ((tm (tm_new)) (cx (ctx_new)) (vw (view_new)))
          (if (or (= tm 0) (= cx 0) (= vw 0)) (extern-call ExitProcess 3)
            (seq ,(tsf/gs 'tm 'tm) ,(tsf/gs 'ctxo 'cx) ,(tsf/gs 'viewo 'vw)
                 (let ((rc (host_run tm 7 cx)))
                   (seq (ob_flush) (extern-call ExitProcess rc)))))))))))

(defun host-mock-forms ()
  (let ((tsf--lits nil))
    (let ((forms (append (tsf/core-forms) (hm/forms))))
      (append (tsf/lit-blobs)
              (cl-remove-if (lambda (b) (cl-find-if (lambda (f) (and (eq (car f) 'data-blob) (eq (nth 1 f) (nth 1 b)))) forms))
                            (nelisp-com-msctf-blobs nil))
              forms))))

(defun host-mock-build-all (dir)
  "Build host-mock.exe and the compose-mode stub-tip.dll into DIR."
  (require 'stub-tip)
  (make-directory dir t)
  (tsf-build-exe (expand-file-name "host-mock.exe" dir) (host-mock-forms))
  (stub-tip-build-from-env (expand-file-name "stub-tip.dll" dir) 'compose))

(provide 'host-mock)
;;; host-mock.el ends here
