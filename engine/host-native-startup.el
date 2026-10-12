;;; host-native-startup.el --- Pure startup policy -*- lexical-binding: t; -*-

;; Snapshot is a plist, supplied by the native adapter. No OS access occurs here.
;; :inherited is a list of (NAME VALUE UTF16-UNITS), retaining present-empty.
;; :registry is an alist (NAME . VALUE-PLIST); VALUE-PLIST contains :present,
;; :type, :size (raw bytes), :text (zero-filled UTF-16 buffer through first NUL),
;; and :dword (the zero-filled four-byte unsigned value). Native conversion owns
;; these views; :type is retained but QueryValueEx with a null type accepts it.
;; Other fields: :registry-present, :framework-available, :expansion-ok,
;; :expanded-path, :native-entry (bounded native-entry flag read),
;; :requested-present/:requested-id and :prior-imported (ordered bridge names).
;; Requested presence distinguishes an explicit empty ID from configuration.
;; Results contain enums/data only. The adapter builds and sorts the child block.

;;;###autoload
(defun host-native-select-engine (snapshot)
  "Return runner enum, entry enum and unchanged child engine ID for SNAPSHOT.
An inherited empty/overlong engine falls through to registry/default. Missing
framework changes the runner, never the selected child ID. Native entry uses
the DDSKK runner, including its missing-framework fallback, as in StartChild."
  (let* ((inherited (assoc "NELISP_IME_ENGINE" (plist-get snapshot :inherited)))
         (value (cadr inherited))
         (units (nth 2 inherited))
         (registry (cdr (assoc "Engine" (plist-get snapshot :registry))))
         (id (cond
              ((plist-get snapshot :requested-present)
               (plist-get snapshot :requested-id))
              ((and inherited (> units 0) (< units 64)) value)
              ((and (plist-get snapshot :registry-present)
                    (plist-get registry :present)
                    (<= (plist-get registry :size) 126)
                    (not (string= (plist-get registry :text) "")))
               (plist-get registry :text))
              (t "ddskk")))
         (ddskk (or (string= id "")
                    (member (downcase id) '("ddskk" "passthrough"))))
         (runner (if (or ddskk (not (plist-get snapshot :framework-available)))
                     'ddskk 'framework)))
    (list :runner runner :child-engine-id id
          :entry (if (and (eq runner 'ddskk)
                          (plist-get snapshot :native-entry)) 'native 'load))))

;;;###autoload
(defun host-native-child-env-plan (snapshot)
  "Return allowlisted ordered set/remove operations and imported provenance.
Refresh prior registry imports before reading new bridge values. An explicit
inherited value, including empty, stays pinned. Operations target only bridge
variables and the child-only NELISP_IME_ENGINE; the host ID stays untouched."
  (let* ((bridges '(("UserJisyoPath" "DDSKK_USER_JISYO")
                    ("UserJisyoBatch" "DDSKK_USER_JISYO_SAVE_BATCH_SIZE")
                    ("BehaviorOkuriStrictly" "DDSKK_OKURI_STRICTLY")
                    ("BehaviorDeleteOkuriOnCancel" "DDSKK_DELETE_OKURI_ON_CANCEL")
                    ("BehaviorAddKatakanaCand" "DDSKK_SEARCH_KATAKANA")
                    ("BehaviorLearnDisabled" "DDSKK_LEARN_DISABLED")))
         (allowed (mapcar #'cadr bridges))
         (prior (plist-get snapshot :prior-imported))
         (inherited (plist-get snapshot :inherited))
         (registry (plist-get snapshot :registry))
         (id (plist-get (host-native-select-engine snapshot) :child-engine-id))
         (ops nil) (imported nil))
    (dolist (name prior)
      (unless (member name allowed) (error "Non-bridge provenance: %S" name))
      (push (list 'remove name) ops))
    (when (plist-get snapshot :registry-present)
      (dolist (bridge bridges)
        (let* ((key (car bridge)) (name (cadr bridge))
               (value (cdr (assoc key registry)))
               (path (string= key "UserJisyoPath")))
          (when (and (or (member name prior) (not (assoc name inherited)))
                     (plist-get value :present)
                     (<= (plist-get value :size) (if path 65536 4))
                     (or (not path) (not (string= (plist-get value :text) ""))))
            (push (list 'set name
                        (if path
                            (if (plist-get snapshot :expansion-ok)
                                (plist-get snapshot :expanded-path)
                              (plist-get value :text))
                          (number-to-string (plist-get value :dword)))) ops)
            (push name imported)))))
    (push (list 'set "NELISP_IME_ENGINE" id) ops)
    (list :child-engine-id id :ops (nreverse ops) :imported (nreverse imported))))

(provide 'host-native-startup)
;;; host-native-startup.el ends here
