;;; ddskk-core-edit.el --- edit sessions, composition, display attributes (S3i)  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sub-stage S3i (session 1) of the native TSF DLL project: the edit-session
;; side of the core (windows/src/text_service.cpp).  AOT forms in the restricted
;; NeLisp subset, linked into ddskk-core.el by `ddskk-core-forms' (:edit).
;;
;;   StateEditSession (class `ces')       ts.cpp 74-103
;;   TerminateCompositionEditSession (`cts') ts.cpp 105-165
;;   ced_apply                            TextService::ApplyEngineState 2919-3105
;;   ced_display_attr                     ApplyDisplayAttribute 3168-3188
;;   ced_caret_rect                       CaptureCaretRect 207-240 (capture half)
;;   ced_on_term                          OnCompositionTerminated 2835-2890
;;   ced_reset_abandoned                  ResetAbandonedComposition 2448-2475
;;   ced_terminate_composition            ForceCancel/settle tail 2485-2582
;;   ced_request_state                    RequestStateEdit 2747-2765 (no candidate UI yet)
;;
;; Object lifetimes.  An edit session is a heap COM object (class-forms layout)
;; with reference count 1 at creation.  It holds one reference on the context
;; (AddRef at creation, Release in the on-free hook) and one on the core state
;; `DdskkTs' (the `refs' field; `ts_destroy' drops the shim's reference and the
;; state is freed when the last session lets go).  The engine state is COPIED
;; into the session (text + pending in one wbuf, a private DdskkView), so the
;; caller's buffers may die right after RequestEditSession.  A session that runs
;; after Deactivate finds ts.tm = 0 and returns S_FALSE (ts.cpp 2926).
;; The composition (ts.composition) is the reference returned by
;; StartComposition and is released by EndComposition handling /
;; OnCompositionTerminated / reset; a TerminateCompositionEditSession holds its
;; own reference on the composition it ends.
;;
;; Deliberate differences from the C++ source:
;;  * The ITfCategoryMgr is first asked from the thread manager (a mock-only
;;    route of the test host, the real ThreadMgr answers E_NOINTERFACE) and then
;;    from CoCreateInstance(CLSID_TF_CategoryMgr) as C++ does.
;;  * No ITfCompositionSink `this' fallback: the sink comes from the shim's
;;    query_service callback only (always set on the shim path).
;;  * The engine state is a DdskkView (cand flag, has-composition-start flag,
;;    text/pending, active-segment triple), not the EngineState heap object;
;;    `ced_view_from_es' converts one.  Segments are not carried by the TLV
;;    decoder of S3f yet, so production always passes nseg = 0 until the segment
;;    tags are decoded (S3l); the segment branch is exercised by the test only.
;;  * PublishCaretRect (shared-memory caret map) is NOT ported yet (session 2);
;;    only the capture half runs (ts.caret_valid / caret_rect).
;;  * AcknowledgeEndingComposition runs in the shim (ShimService::
;;    OnCompositionTerminated) before the core is invoked; the core only
;;    calls track_ending on the callbacks table.
;;
;; Mutants (NELISP_CORE_MUTANT): skip-end (never calls EndComposition) and
;; wrong-guid (preedit text gets the candidate attribute GUID).

;;; Code:

(require 'cl-lib)
(require 'ddskk-core)

(defconst ddskk-core-edit-test-exports
  '("CoreApplyState" "CoreTerminate" "CoreEditProbe" "CoreEditSizes"))

(nelisp-com-defstruct DdskkView
  (cand i64) (hascomp i64) (tptr ptr) (tlen i64) (pptr ptr) (plen i64)
  (nseg i64) (sstart i64) (slen i64))

(defun ced--v (p f) (nelisp-com-field p 'DdskkView f))
(defun ced--vs (p f v) (nelisp-com-set-field p 'DdskkView f v))

(defconst ced--e-fail 2147500037)
(defconst ced--es-sync-rw 7)
(defconst ced--es-async-rw 14)

(defun ced--blobs ()
  (append
   (nelisp-com-msctf-blobs '(IID_ITfEditSession IID_ITfContextComposition
                             IID_ITfCompositionSink IID_ITfCategoryMgr
                             CLSID_TF_CategoryMgr GUID_PROP_ATTRIBUTE))
   (list (nelisp-com-guid-blob 'g_ced_preedit "{d20e1086-bb65-46c3-8815-4456451be3b4}")
         (nelisp-com-guid-blob 'g_ced_candidate "{937f739e-7bf9-4860-9ceb-0ee3f36916a9}")
         (nelisp-com-guid-blob 'g_ced_converted "{3a99e525-d473-49c8-b2ca-2a6116f0c9da}")
         (nelisp-com-wstr-blob 'w_ced_empty "")
         (nelisp-com-wstr-blob 'w_ced_candidate "candidate")
         (nelisp-com-zero-blob 'ced_last 16))))

;;; ---- small helpers ---------------------------------------------------------

(defun ced--util-forms ()
  `((defun ced_f (hr) (if (= (logand hr 2147483648) 0) 0 1))
    (defun ced_weq_n (p n lit)
      (let ((i 0) (ok 1))
        (seq (while (and (= ok 1) (< i n))
               (if (= (ptr-read-u16 p (* 2 i)) (ptr-read-u16 lit (* 2 i)))
                   (setq i (+ i 1))
                 (setq ok 0)))
             (if (and (= ok 1) (= (ptr-read-u16 lit (* 2 n)) 0)) 1 0))))
    (defun ced_wlen (p) (if (= p 0) 0 (wbuf_wcslen p)))
    ;; ITfRange slots: GetText 3 SetText 4 ShiftStart 8 ShiftEnd 9 Collapse 15 Clone 23
    (defun ced_release (p) (if (= p 0) 0 (seq ,(nelisp-com-call 'p 2) 0)))
    ;; Calls the shim's track_ending callback (TrackEndingComposition /
    ;; UntrackEndingComposition).
    (defun ced_track (ts comp flag)
      (let ((cb ,(ct--f 'ts 'cb)))
        (call-ptr ,(nelisp-com-field 'cb 'NativeImeCallbacks 'track_ending)
                  ,(nelisp-com-field 'cb 'NativeImeCallbacks 'owner) comp flag)))
    ;; TF_SELECTION at SC+16 (range, ase = TF_AE_NONE, fInterimChar = FALSE);
    ;; SetSelection(ec, 1, &sel) -> hr.
    (defun ced_set_sel (ec ctx range sc)
      (seq (ptr-write-u64 sc 16 range) (ptr-write-u32 sc 24 0) (ptr-write-u32 sc 28 0)
           ,(nelisp-com-call 'ctx 6 'ec 1 '(+ sc 16))))
    ;; CaptureCaretRect: ts.caret_valid / caret_rect (publish half: session 2).
    (defun ced_caret_rect (ts ec ctx range sc)
      (seq ,(ct--s 'ts 'caret_valid 0)
           (if (or (= ctx 0) (= range 0)) 0
             (seq (ptr-write-u64 sc 112 0)
                  (let ((hr ,(nelisp-com-call 'ctx 9 '(+ sc 112))))
                    (let ((view (ptr-read-u64 sc 112)))
                      (if (or (/= (ced_f hr) 0) (= view 0)) 0
                        (let ((hr2 ,(nelisp-com-call 'view 4 'ec 'range '(+ sc 120) '(+ sc 136))))
                          (seq ,(nelisp-com-call 'view 2)
                               (if (/= (ced_f hr2) 0) 0
                                 (seq ,(ct--s 'ts 'caret_valid 1)
                                      ,@(cl-loop for i below 4
                                                 collect `(ptr-write-u32 ,(ct--a 'ts 'caret_rect) ,(* 4 i)
                                                                         (ptr-read-u32 sc ,(+ 120 (* 4 i)))))
                                      0))))))))
             0)
           0))))

;;; ---- display attribute -----------------------------------------------------

(defun ced--attr-forms ()
  `((defun ced_category (ts sc)
      (let ((tm ,(ct--f 'ts 'tm)))
        (seq (ptr-write-u64 sc 64 0)
             (let ((hr ,(nelisp-com-call 'tm 0 '(data-addr IID_ITfCategoryMgr) '(+ sc 64))))
               (if (= (ced_f hr) 0) hr
                 (extern-call CoCreateInstance (data-addr CLSID_TF_CategoryMgr) 0 1
                              (data-addr IID_ITfCategoryMgr) (+ sc 64)))))))
    ;; ApplyDisplayAttribute: RegisterGUID(guid) + GetProperty(GUID_PROP_ATTRIBUTE)
    ;; + SetValue(range, VARIANT{VT_I4, atom}).  VARIANT is 24 bytes at SC+88.
    (defun ced_display_attr (ts ec ctx range guid sc)
      (let ((hr (ced_category ts sc)))
        (let ((cm (ptr-read-u64 sc 64)))
          (seq (ptr-write-u32 sc 72 4294967295)
               (let ((hr1 (if (/= (ced_f hr) 0) hr
                            (if (= cm 0) ,ced--e-fail ,(nelisp-com-call 'cm 14 'guid '(+ sc 72))))))
                 (seq (ced_release cm)
                      (if (/= (ced_f hr1) 0) hr1
                        (seq (ptr-write-u64 sc 80 0)
                             (let ((hr2 ,(nelisp-com-call 'ctx 12 '(data-addr GUID_PROP_ATTRIBUTE) '(+ sc 80))))
                               (let ((prop (ptr-read-u64 sc 80)))
                                 (if (or (/= (ced_f hr2) 0) (= prop 0)) hr2
                                   (seq (ptr-write-u64 sc 88 0) (ptr-write-u64 sc 96 0) (ptr-write-u64 sc 104 0)
                                        (ptr-write-u16 sc 88 3)
                                        (ptr-write-u32 sc 96 (ptr-read-u32 sc 72))
                                        (let ((hr3 ,(nelisp-com-call 'prop 9 'ec 'range '(+ sc 88))))
                                          (seq ,(nelisp-com-call 'prop 2) hr3))))))))))))))))

;;; ---- ApplyEngineState ------------------------------------------------------

(defun ced--apply-forms (mutant)
  (let ((preedit-guid (if (eq mutant 'wrong-guid) 'g_ced_candidate 'g_ced_preedit)))
    `((defun ced_attr_guid (v)
        (if (> ,(ced--v 'v 'nseg) 0) (data-addr g_ced_converted)
          (if (/= ,(ced--v 'v 'cand) 0) (data-addr g_ced_candidate) (data-addr ,preedit-guid))))
      ;; Active-segment attribute + caret selection (ts.cpp 3042-3075).
      (defun ced_caret_tail (ts ec ctx range v sc)
        (seq
         (if (> ,(ced--v 'v 'nseg) 0)
             (seq (ptr-write-u64 sc 160 0)
                  (if (/= (ced_f ,(nelisp-com-call 'range 23 '(+ sc 160))) 0) 0
                    (let ((tg (ptr-read-u64 sc 160)))
                      (seq ,(nelisp-com-call 'tg 15 'ec 0)
                           ,(nelisp-com-call 'tg 9 'ec `(+ ,(ced--v 'v 'sstart) ,(ced--v 'v 'slen)) '(+ sc 176) 0)
                           ,(nelisp-com-call 'tg 8 'ec (ced--v 'v 'sstart) '(+ sc 176) 0)
                           (ced_display_attr ts ec ctx tg (data-addr g_ced_candidate) sc)
                           (ced_release tg)
                           0))))
           0)
         (ptr-write-u64 sc 168 0)
         (if (/= (ced_f ,(nelisp-com-call 'range 23 '(+ sc 168))) 0) 0
           (let ((caret (ptr-read-u64 sc 168))
                 (rel (if (> ,(ced--v 'v 'nseg) 0)
                          (+ ,(ced--v 'v 'sstart) ,(ced--v 'v 'slen))
                        (+ ,(ced--v 'v 'tlen) ,(ced--v 'v 'plen)))))
             (seq ,(nelisp-com-call 'caret 15 'ec 0)
                  ,(nelisp-com-call 'caret 9 'ec 'rel '(+ sc 176) 0)
                  ,(nelisp-com-call 'caret 15 'ec 1)
                  (ced_set_sel ec ctx caret sc)
                  (ced_caret_rect ts ec ctx caret sc)
                  (ced_release caret)
                  0)))
         0))
      (defun ced_clear_reg (ts)
        (seq (ct_release_ptr ,(ct--a 'ts 'registration_range))
             ,(ct--s 'ts 'reg_commit 0) 0))
      ;; Tail of ApplyEngineState (ts.cpp 3077-3103).
      (defun ced_finish (ts ec v)
        (if (and (= ,(ced--v 'v 'hascomp) 0) (= ,(ced--v 'v 'plen) 0)
                 (/= ,(ct--f 'ts 'composition) 0))
            (let ((comp ,(ct--f 'ts 'composition)) (end 0))
              (seq (ced_track ts comp 1)
                   ,(if (eq mutant 'skip-end) 0
                      `(seq (setq end ,(nelisp-com-call 'comp 6 'ec))
                            (if (/= (ced_f end) 0) (ced_track ts comp 0) 0)))
                   (ct_release_ptr ,(ct--a 'ts 'composition))
                   (ced_clear_reg ts)
                   end))
          (seq (ced_clear_reg ts) 0)))
      ;; Range known (sc+0): SetText display, attributes, caret.
      (defun ced_with_range (ts ec ctx v sc dlen)
        (let ((range (ptr-read-u64 sc 0)))
          (let ((hr ,(nelisp-com-call 'range 4 'ec 0 (ced--v 'v 'tptr) 'dlen)))
            (seq
             (if (/= (ced_f hr) 0) 0
               (seq (if (/= ,(ct--f 'ts 'composition) 0)
                        (let ((comp ,(ct--f 'ts 'composition)))
                          (seq ,(nelisp-com-call 'comp 4 'ec 'range)
                               ,(nelisp-com-call 'comp 5 'ec 'range) 0))
                      0)
                    (ced_display_attr ts ec ctx range (ced_attr_guid v) sc)
                    (ced_caret_tail ts ec ctx range v sc)
                    0))
             (ced_release range)
             (if (/= (ced_f hr) 0) hr (ced_finish ts ec v))))))
      ;; commit text at the selection, collapse to its end, select it (ts.cpp 2988-3005)
      (defun ced_commit (ec ctx range tptr tlen sc)
        (let ((hr ,(nelisp-com-call 'range 4 'ec 0 'tptr 'tlen)))
          (if (/= (ced_f hr) 0) (seq (ced_release range) hr)
            (seq ,(nelisp-com-call 'range 15 'ec 1)
                 (let ((hr2 (ced_set_sel ec ctx range sc)))
                   (if (/= (ced_f hr2) 0) (seq (ced_release range) hr2) 0))))))
      ;; StartComposition on SC+0's range (ts.cpp 3010-3036); stores ts.composition.
      (defun ced_start (ts ec ctx range sc)
        (seq (ptr-write-u64 sc 32 0) (ptr-write-u64 sc 40 0) (ptr-write-u64 sc 48 0)
             (let ((hr ,(nelisp-com-call 'ctx 0 '(data-addr IID_ITfContextComposition) '(+ sc 32))))
               (if (/= (ced_f hr) 0) hr
                 (let ((cc (ptr-read-u64 sc 32)) (cb ,(ct--f 'ts 'cb)))
                   (seq (call-ptr ,(nelisp-com-field 'cb 'NativeImeCallbacks 'query_service)
                                  ,(nelisp-com-field 'cb 'NativeImeCallbacks 'owner)
                                  (data-addr IID_ITfCompositionSink) (+ sc 40))
                        (let ((sink (ptr-read-u64 sc 40)))
                          (let ((hr2 ,(nelisp-com-call 'cc 3 'ec 'range 'sink '(+ sc 48))))
                            (seq (ced_release sink) (ced_release cc)
                                 (if (/= (ced_f hr2) 0) hr2
                                   (seq ,(ct--s 'ts 'composition '(ptr-read-u64 sc 48)) 0)))))))))))
      ;; No composition and no registration target: selection path (ts.cpp 2979-3037).
      (defun ced_select_path (ts ec ctx v sc ctlen dlen)
        (seq
         (ptr-write-u64 sc 8 0) (ptr-write-u64 sc 16 0)
         (let ((hr ,(nelisp-com-call 'ctx 5 'ec 4294967295 1 '(+ sc 16) '(+ sc 8))))
           (if (/= (ced_f hr) 0) hr
             (if (/= (ptr-read-u32 sc 8) 1) ,ced--e-fail
               (let ((range (ptr-read-u64 sc 16)))
                 (seq
                  (ptr-write-u64 sc 0 range)
                  (let ((chr (if (> ctlen 0) (ced_commit ec ctx range ,(ced--v 'v 'tptr) ctlen sc) 0)))
                    (if (/= (ced_f chr) 0) chr
                      (if (= dlen 0)
                          (seq (ced_caret_rect ts ec ctx range sc) (ced_release range) 0)
                        (let ((shr (ced_start ts ec ctx range sc)))
                          (if (/= (ced_f shr) 0) (seq (ced_release range) shr)
                            (ced_with_range ts ec ctx v sc dlen)))))))))))))
      (defun ced_apply0 (ts ec ctx v sc)
        (if (= ,(ct--f 'ts 'tm) 0) 1
          (let* ((tl ,(ced--v 'v 'tlen)) (pl ,(ced--v 'v 'plen))
                 (regt (if (and (/= ,(ct--f 'ts 'reg_commit) 0)
                                (/= ,(ct--f 'ts 'registration_range) 0)) 1 0))
                 (direct (if (and (= ,(ced--v 'v 'hascomp) 0) (= pl 0)
                                  (= ,(ct--f 'ts 'composition) 0) (= regt 0)) 1 0))
                 (ctlen (if (= direct 1) tl 0))
                 (dlen (if (= direct 1) 0 (+ tl pl))))
            (seq
             (ptr-write-u64 sc 0 0)
             (if (/= ,(ct--f 'ts 'composition) 0)
                 (let ((comp ,(ct--f 'ts 'composition)))
                   (let ((hr ,(nelisp-com-call 'comp 3 'sc)))
                     (if (/= (ced_f hr) 0) hr (ced_with_range ts ec ctx v sc dlen))))
               (if (= regt 1)
                   (let ((rr ,(ct--f 'ts 'registration_range)))
                     (seq (ptr-write-u64 sc 0 rr) ,(nelisp-com-call 'rr 1)
                          (ced_with_range ts ec ctx v sc dlen)))
                 (ced_select_path ts ec ctx v sc ctlen dlen)))))))
      ;; ApplyEngineState entry: private scratch block (no stack arrays in the AOT).
      (defun ced_apply (ts ec ctx v)
        (let ((h (extern-call GetProcessHeap)))
          (let ((sc (extern-call HeapAlloc h 8 256)))
            (if (= sc 0) 2147942414
              (let ((r (ced_apply0 ts ec ctx v sc)))
                (seq (extern-call HeapFree h 0 sc) (logand r 4294967295)))))))
      ;; ---- StateEditSession (class ces) ----
      (defun ces_do (this ec)
        (ced_apply ,(nelisp-com-class-field 'ces 'this 'ts) ec
                   ,(nelisp-com-class-field 'ces 'this 'ctx)
                   ,(nelisp-com-class-field 'ces 'this 'view)))
      (defun ces_on_free (base)
        (seq (ced_release ,(nelisp-com-class-field 'ces 'base 'ctx))
             (if (= ,(nelisp-com-class-field 'ces 'base 'ts) 0) 0
               (ct_ts_release ,(nelisp-com-class-field 'ces 'base 'ts)))
             (if (= ,(nelisp-com-class-field 'ces 'base 'view) 0) 0
               (DdskkView_free ,(nelisp-com-class-field 'ces 'base 'view)))
             (if (= ,(nelisp-com-class-field 'ces 'base 'buf) 0) 0
               (wbuf_free ,(nelisp-com-class-field 'ces 'base 'buf)))
             0))
      ;; Copies the caller's view V (text and pending are joined into one wbuf).
      (defun ced_new_session (ts ctx v)
        (let ((s (ces_new)))
          (if (= s 0) 0
            (let ((nv (DdskkView_alloc))
                  (w (wbuf_new (+ ,(ced--v 'v 'tlen) ,(ced--v 'v 'plen) 8))))
              (if (or (= nv 0) (= w 0))
                  (seq (if (= nv 0) 0 (DdskkView_free nv)) (if (= w 0) 0 (wbuf_free w)) 0)
                (seq (wbuf_append_wn w ,(ced--v 'v 'tptr) ,(ced--v 'v 'tlen))
                     (wbuf_append_wn w ,(ced--v 'v 'pptr) ,(ced--v 'v 'plen))
                     ,(ced--vs 'nv 'cand (ced--v 'v 'cand))
                     ,(ced--vs 'nv 'hascomp (ced--v 'v 'hascomp))
                     ,(ced--vs 'nv 'tptr '(wbuf_ptr w))
                     ,(ced--vs 'nv 'tlen (ced--v 'v 'tlen))
                     ,(ced--vs 'nv 'pptr `(+ (wbuf_ptr w) (* 2 ,(ced--v 'v 'tlen))))
                     ,(ced--vs 'nv 'plen (ced--v 'v 'plen))
                     ,(ced--vs 'nv 'nseg (ced--v 'v 'nseg))
                     ,(ced--vs 'nv 'sstart (ced--v 'v 'sstart))
                     ,(ced--vs 'nv 'slen (ced--v 'v 'slen))
                     ,(nelisp-com-class-set-field 'ces 's 'buf 'w)
                     ,(nelisp-com-class-set-field 'ces 's 'view 'nv)
                     ,(nelisp-com-class-set-field 'ces 's 'ts 'ts)
                     (ct_ts_addref ts)
                     ,(nelisp-com-class-set-field 'ces 's 'ctx 'ctx)
                     ,(nelisp-com-call 'ctx 1)
                     s))))))
      ;; RequestEditSession; the edit-session result is left in ced_last[0].
      (defun ced_request (ts ctx es flags)
        (seq (ptr-write-u64 (data-addr ced_last) 0 ,ced--e-fail)
             ,(nelisp-com-call 'ctx 3 (ct--f 'ts 'client_id) 'es 'flags '(data-addr ced_last))))
      ;; RequestStateEdit: copy the state into a session and request it.
      (defun ced_request_state (ts ctx v flags)
        (if (= ctx 0) 2147549183
          (let ((es (ced_new_session ts ctx v)))
            (if (= es 0) 2147942414
              (let ((r (ced_request ts ctx es flags)))
                (seq ,(nelisp-com-call 'es 2) r))))))
      ;; View from an engine-client EngineState (S3f), no segments yet.
      (defun ced_view_fill (v cand comp_start tptr tlen pptr plen)
        (seq ,(ced--vs 'v 'cand 'cand) ,(ced--vs 'v 'hascomp '(if (>= comp_start 0) 1 0))
             ,(ced--vs 'v 'tptr 'tptr) ,(ced--vs 'v 'tlen 'tlen)
             ,(ced--vs 'v 'pptr 'pptr) ,(ced--vs 'v 'plen 'plen)
             ,(ced--vs 'v 'nseg 0) ,(ced--vs 'v 'sstart 0) ,(ced--vs 'v 'slen 0) 0)))))

;;; ---- composition termination ------------------------------------------------

(defun ced--term-forms ()
  `(;; ResetAbandonedComposition, core-owned part (engine/realtime/provider parts: S3f/S3g/S3k).
    (defun ced_reset_abandoned (ts)
      (seq ,(ct--s 'ts 'needs_resync 1)
           (ct_release_ptr ,(ct--a 'ts 'composition))
           (ct_release_ptr ,(ct--a 'ts 'registration_range))
           ,(ct--s 'ts 'reg_commit 0) ,(ct--s 'ts 'registration_mode 0)
           ,(ct--s 'ts 'engine_pending 0) ,(ct--s 'ts 'provider_active 0)
           ,(ct--s 'ts 'kana_mode 1)
           (ct_set_last_mode ts (data-addr w_cs_hiragana))
           0))
    ;; Reads RANGE's text (<= 4095 units) and rewrites it without the leading
    ;; marker (U+25BD / U+25BC); BUF is a 8192-byte scratch, SC the scratch block.
    (defun ced_settle_range (ec range buf sc)
      (seq (ptr-write-u64 sc 184 0)
           (let ((hr ,(nelisp-com-call 'range 3 'ec 0 'buf 4095 '(+ sc 184))))
             (if (/= (ced_f hr) 0) hr
               (let ((n (ptr-read-u32 sc 184)))
                 (let ((mk (if (and (> n 0) (or (= (ptr-read-u16 buf 0) 9661) (= (ptr-read-u16 buf 0) 9660))) 1 0)))
                   ,(nelisp-com-call 'range 4 'ec 0 '(+ buf (* 2 mk)) '(- n mk))))))))
    (defun ced_term0 (ts ec comp sc buf)
      (let ((owned (if (/= comp 0) comp ,(ct--f 'ts 'composition))))
        (seq
         (ptr-write-u64 sc 0 0)
         (if (/= ,(ct--f 'ts 'registration_mode) 0)
             ;; modal registration: drop the provisional range, keep the engine registration
             (seq (if (and (/= owned 0) (= (ced_f ,(nelisp-com-call 'owned 3 'sc)) 0))
                      (let ((range (ptr-read-u64 sc 0)))
                        (seq ,(nelisp-com-call 'range 4 'ec 0 '(data-addr w_ced_empty) 0)
                             (ced_release range) 0))
                    0)
                  (ct_release_ptr ,(ct--a 'ts 'composition))
                  ,(ct--s 'ts 'engine_pending 1)
                  0)
           (seq (if (and (/= owned 0) (= (ced_f ,(nelisp-com-call 'owned 3 'sc)) 0))
                    (let ((range (ptr-read-u64 sc 0)))
                      (seq (ced_settle_range ec range buf sc)
                           (ced_release range) 0))
                  0)
                (ct_release_ptr ,(ct--a 'ts 'composition))
                (ced_reset_abandoned ts)
                0)))))
    ;; OnCompositionTerminated (hook for NI_COMPOSITION_END; the shim has already
    ;; acknowledged compositions this core ended itself).
    (defun ced_on_term (ts ec comp)
      (let ((h (extern-call GetProcessHeap)))
        (let ((sc (extern-call HeapAlloc h 8 256)) (buf (extern-call HeapAlloc h 8 8200)))
          (seq (if (or (= sc 0) (= buf 0)) 0 (ced_term0 ts (logand ec 4294967295) comp sc buf))
               (if (= sc 0) 0 (extern-call HeapFree h 0 sc))
               (if (= buf 0) 0 (extern-call HeapFree h 0 buf))
               0))))
    ;; ---- TerminateCompositionEditSession (class cts) ----
    (defun cts_do (this ec)
      (let ((comp ,(nelisp-com-class-field 'cts 'this 'comp))
            (settle ,(nelisp-com-class-field 'cts 'this 'settle))
            (h (extern-call GetProcessHeap)))
        (let ((sc (extern-call HeapAlloc h 8 256)) (buf (extern-call HeapAlloc h 8 8200)))
          (if (or (= sc 0) (= buf 0))
              (seq (if (= sc 0) 0 (extern-call HeapFree h 0 sc))
                   (if (= buf 0) 0 (extern-call HeapFree h 0 buf))
                   2147942414)
            (seq
             (ptr-write-u64 sc 0 0)
             (let ((r (let ((hr ,(nelisp-com-call 'comp 3 'sc)))
                        (if (/= (ced_f hr) 0) hr
                          (let ((range (ptr-read-u64 sc 0)))
                            (let ((r2 (if (/= settle 0)
                                          (ced_settle_range ec range buf sc)
                                        ,(nelisp-com-call 'range 4 'ec 0 '(data-addr w_ced_empty) 0))))
                              (seq (ced_release range) r2)))))))
               (let ((out (if (/= (ced_f r) 0) r ,(nelisp-com-call 'comp 6 'ec))))
                 (seq (extern-call HeapFree h 0 sc) (extern-call HeapFree h 0 buf)
                      (logand out 4294967295)))))))))
    (defun cts_on_free (base) (ced_release ,(nelisp-com-class-field 'cts 'base 'comp)))
    ;; Ends the current composition through a sync (else async) edit session on
    ;; CTX (ts.cpp 2485-2538 / 2545-2582).  Returns 1 when cleared.
    (defun ced_terminate_composition (ts ctx settle)
      (let ((comp ,(ct--f 'ts 'composition)) (cleared 1))
        (seq
         (if (= comp 0) 0
           (seq
            (setq cleared 0)
            (if (= ctx 0) 0
              (seq
               (ced_track ts comp 1)
               (let ((es (cts_new)))
                 (if (= es 0) 0
                   (seq ,(nelisp-com-class-set-field 'cts 'es 'settle 'settle)
                        ,(nelisp-com-call 'comp 1)
                        ,(nelisp-com-class-set-field 'cts 'es 'comp 'comp)
                        (let ((rq (ced_request ts ctx es ,ced--es-sync-rw)))
                          (seq
                           (if (or (/= (ced_f rq) 0) (/= (ced_f (ptr-read-u64 (data-addr ced_last) 0)) 0))
                               (seq (setq rq (ced_request ts ctx es ,ced--es-async-rw)) 0)
                             0)
                           ,(nelisp-com-call 'es 2)
                           (if (and (= (ced_f rq) 0) (= (ced_f (ptr-read-u64 (data-addr ced_last) 0)) 0))
                               (setq cleared 1)
                             0)))))
                 0)
               (if (and (= cleared 1) (= ,(ct--f 'ts 'composition) comp))
                   (ct_release_ptr ,(ct--a 'ts 'composition))
                 0)
               (if (= cleared 0) (ced_track ts comp 0) 0)
               0))
            (if (= cleared 0) (ced_reset_abandoned ts) 0)
            0))
         (ct_release_ptr ,(ct--a 'ts 'registration_range))
         ,(ct--s 'ts 'reg_commit 0) ,(ct--s 'ts 'registration_mode 0)
         ,(ct--s 'ts 'engine_pending 0) ,(ct--s 'ts 'provider_active 0)
         ,(ct--s 'ts 'kana_mode 1)
         (ct_set_last_mode ts (data-addr w_cs_hiragana))
         cleared)))))

;;; ---- test exports ------------------------------------------------------------

(defun ced--test-forms ()
  `(;; spec: u64 words [mode_w comp_start text_w pend_w nseg sstart slen]
    (defun CoreApplyState (tm ctx spec)
      (let ((ts (ptr-read-u64 (data-addr core_last) 0)))
        (if (= ts 0) 4294967295
          (let ((v (DdskkView_alloc)))
            (if (= v 0) 2147942414
              (seq
               (if (= ,(ct--f 'ts 'tm) 0)
                   (seq ,(nelisp-com-call 'tm 1) ,(ct--s 'ts 'tm 'tm)) 0)
               (ced_view_fill v
                              (if (= (ptr-read-u64 spec 0) 0) 0
                                (ced_weq_n (ptr-read-u64 spec 0) (ced_wlen (ptr-read-u64 spec 0)) (data-addr w_ced_candidate)))
                              (ptr-read-u64 spec 8)
                              (ptr-read-u64 spec 16) (ced_wlen (ptr-read-u64 spec 16))
                              (ptr-read-u64 spec 24) (ced_wlen (ptr-read-u64 spec 24)))
               ,(ced--vs 'v 'nseg '(ptr-read-u64 spec 32))
               ,(ced--vs 'v 'sstart '(ptr-read-u64 spec 40))
               ,(ced--vs 'v 'slen '(ptr-read-u64 spec 48))
               (let ((r (ced_request_state ts ctx v ,ced--es-sync-rw)))
                 (seq (DdskkView_free v) (logand r 4294967295)))))))))
    (defun CoreTerminate (ctx settle)
      (let ((ts (ptr-read-u64 (data-addr core_last) 0)))
        (if (= ts 0) 4294967295 (ced_terminate_composition ts ctx settle))))
    ;; 0 composition set  1 last edit-session result  2 caret_valid  3..6 caret rect
    ;; 7 composition pointer  8 ts.refs
    (defun CoreEditProbe (idx)
      (let ((ts (ptr-read-u64 (data-addr core_last) 0)))
        (if (= ts 0) 4294967295
          (if (= idx 0) (if (= ,(ct--f 'ts 'composition) 0) 0 1)
            (if (= idx 1) (ptr-read-u32 (data-addr ced_last) 0)
              (if (= idx 2) ,(ct--f 'ts 'caret_valid)
                (if (and (>= idx 3) (<= idx 6)) (ptr-read-u32 ,(ct--a 'ts 'caret_rect) (* 4 (- idx 3)))
                  (if (= idx 7) ,(ct--f 'ts 'composition)
                    (if (= idx 8) ,(ct--f 'ts 'refs) 4294967294)))))))))
    ;; struct sizes: 0 TF_SELECTION 1 TF_SELECTIONSTYLE 2 VARIANT(raw) 3 TF_DISPLAYATTRIBUTE
    (defun CoreEditSizes (idx)
      (if (= idx 0) ,(nelisp-com-struct-size 'TF_SELECTION)
        (if (= idx 1) ,(nelisp-com-struct-size 'TF_SELECTIONSTYLE)
          (if (= idx 2) 24
            (if (= idx 3) ,(nelisp-com-struct-size 'TF_DISPLAYATTRIBUTE) 4294967294)))))))

(cl-defun ddskk-core-edit-forms (&key test-exports mutant)
  "Return the AOT forms of the S3i edit-session module."
  (append
   (ced--blobs)
   (nelisp-com-struct-forms 'DdskkView)
   (nelisp-com-class-forms
    'ces :fields '((ts ptr) (ctx ptr) (view ptr) (buf ptr)) :on-free 'ces_on_free
    :interfaces `((:iid ,(nelisp-com-msctf-guid 'IID_ITfEditSession) :methods (ces_do))))
   (nelisp-com-class-forms
    'cts :fields '((comp ptr) (settle i64)) :on-free 'cts_on_free
    :interfaces `((:iid ,(nelisp-com-msctf-guid 'IID_ITfEditSession) :methods (cts_do))))
   (ced--util-forms)
   (ced--attr-forms)
   (ced--apply-forms mutant)
   (ced--term-forms)
   (and test-exports (ced--test-forms))))

(provide 'ddskk-core-edit)
;;; ddskk-core-edit.el ends here
