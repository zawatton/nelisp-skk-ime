;;; skk-local-conversion.el --- Local conversion metadata and learning -*- lexical-binding: t; -*-
;; GPL-3.0-or-later

;; The engine alone writes the personal jisyo. Local learning does not
;; activate, reset, restore or feed an editing session.
(defvar ddskk-local-operations (make-hash-table :test 'equal))
(defvar ddskk-local-operations-loaded nil)

(defconst ddskk-local-literal-annotations
  '("(-肉)" "(<galley)" "(<蘭語)" "(=すすg)「汚名を-ぐ」(cf.「雪辱」)"
    "([中国史])" "([二十四節気]2.19頃)" "([二十四節気]4.5頃)"
    "([二十四節気]9.8頃)" "([八卦]陽陰陽)" "([日本史]=年序)" "([部首]=貝偏)"
    "(attract)" "(difficult)" "(enlarge)" "(feel)" "(generic)" "(most)"
    "(order)" "(send)" "(sorrow)" "(worry)")
  "Bounded public-L annotation vocabulary shared with the native parser.
The snapshot certifies these exact components only while the actual
DDSKK reader and engine function bindings establish that they are inert.
Change the profile hash/version in both implementations when changing it.")
(defconst ddskk-local-literal-profile-marker
  ";; local-literal-profile 1 879b04a00ff3ffa629025a330ece9b65488fc9494e9b883d4dda104f0751edc8")

(defun ddskk-local-literal-annotations-safe-p ()
  "Check stock's expression predicate and current bindings without eval.
Unexpected reader/predicate errors fail closed.  Stock's predicate itself
returns nil for unreadable or partially consumed strings, which are literal."
  (condition-case nil
      (and (fboundp 'skk-lisp-prog-p)
           (catch 'callable
             (dolist (form ddskk-local-literal-annotations)
               (when (skk-lisp-prog-p form)
                 (let ((parsed (car (read-from-string form))))
                   (when (and (listp parsed) (functionp (car parsed)))
                     (throw 'callable nil)))))
             t))
    (error nil)))

(defun ddskk-local-load-operations ()
  "Read durable operation identities before accepting a retry."
  (unless ddskk-local-operations-loaded
    (setq ddskk-local-operations-loaded t)
    (let* ((path (ddskk-user-jisyo-path))
           (bytes (and path (nelisp--syscall-read-file path))))
      (when bytes
        (dolist (line (split-string bytes "\n" t))
          (when (and (> (length line) 13) (equal (substring line 0 13) ";; local-ack "))
            (let* ((fields (split-string line " " t))
                   (id (nth 2 fields)) (operation (string-to-number (nth 3 fields)))
                   (sequence (string-to-number (nth 4 fields))))
              (puthash id (cons operation sequence) ddskk-local-operations)
              (setq ddskk-user-jisyo-local-revision
                    (max sequence ddskk-user-jisyo-local-revision)))))))))

(defun ddskk-local-metadata ()
  "Store identities in the same verified checkpoint as candidate order."
  (let (lines)
    (maphash (lambda (id watermark)
               (push (concat ";; local-ack " id " " (number-to-string (car watermark))
                             " " (number-to-string (cdr watermark)) "\n") lines))
             ddskk-local-operations)
    (apply #'concat lines)))

(defun ddskk-local-capability-reason ()
  "Return the provider-only plan reason, or nil for ordinary lookup.
This is a plan check, not a reading check.  The published index certifies
each reading and its candidates separately.  Custom candidate/commit
functions can change plain lookup results and must run in the provider."
  (cond
   ((not (equal skk-search-prog-list
                '((ddskk-user-jisyo-search) (ddskk-engine-server-search))))
    'search-plan)
   ((not (eq skk-update-jisyo-function 'ddskk-user-jisyo--update)) 'update-function)
   (ddskk-user-jisyo-learning-disabled 'learning-disabled)
   ((and (boundp 'skk-search-end-function) skk-search-end-function) 'search-end-function)
   ((and (boundp 'skk-search-hook) skk-search-hook) 'search-hook)
   ((and (boundp 'skk-kakutei-hook) skk-kakutei-hook) 'kakutei-hook)
   ((and (boundp 'skk-treat-candidate-appearance-function)
         skk-treat-candidate-appearance-function) 'candidate-function)
   ((and (boundp 'skk-insert-new-word-function) skk-insert-new-word-function) 'insert-function)
   ((and (boundp 'skk-kakutei-end-function) skk-kakutei-end-function) 'commit-function)
   ((and (boundp 'skk-search-excluding-word-pattern-function)
         skk-search-excluding-word-pattern-function) 'learning-filter)
   ((and (boundp 'skk-learn-combined-word) skk-learn-combined-word) 'combined-learning)
   ((not (ddskk-local-literal-annotations-safe-p)) 'literal-annotation-profile)))

(defun ddskk-local-capability ()
  "Certify only the ordinary plan implemented by the core."
  (not (ddskk-local-capability-reason)))

(defun ddskk-local-okuri-capability ()
  "Certify complete-kana okuri; advanced okuri options stay on the provider."
  (and (ddskk-local-capability)
       (not (and (boundp 'skk-process-okuri-early) skk-process-okuri-early))
       (not (and (boundp 'skk-auto-okuri-process) skk-auto-okuri-process))
       (not (and (boundp 'skk-henkan-okuri-strictly) skk-henkan-okuri-strictly))
       (not (and (boundp 'skk-henkan-strict-okuri-precedence) skk-henkan-strict-okuri-precedence))
       (not (and (boundp 'skk-delete-okuri-when-quit) skk-delete-okuri-when-quit))))

(defun ddskk-local-save ()
  "Verify a separate checkpoint, then ask the host to flush and replace it.
The runtime's rename-file is not usable on Windows. No ACK is issued
until the native host has flushed the checkpoint and atomically replaced
the configured personal dictionary. The engine still owns its contents."
  (condition-case err
      (let* ((path (ddskk-user-jisyo-path))
             (temporary (concat path ".local-checkpoint"))
             (content (ddskk-user-jisyo--serialize))
             (coding-system-for-write 'utf-8-unix))
        (ignore-errors (write-region content nil temporary))
        (unless (equal (nelisp--syscall-read-file temporary) content)
          (error "Local checkpoint verification failed"))
        (nelisp--write-stdout-bytes "LOCAL-PUBLISH\n")
        (unless (equal (ddskk-engine-read-stdio-line) "LOCAL-PUBLISHED")
          (error "Local checkpoint publication failed"))
        t)
    (error (setq ddskk-user-jisyo--last-save-error err) nil)))

(defun ddskk-local-learn (line)
  "Handle an idempotent ordinary confirmation; ACK only verified storage."
  (condition-case err
      (let* ((fields (split-string line " " t))
             (id (nth 2 fields))
             (identity (and id (split-string id "\\.")))
             (client (car identity))
             (operation (and (nth 1 identity) (string-to-number (nth 1 identity))))
             (key (ddskk-engine--unhex (nth 3 fields)))
             (word (ddskk-engine--unhex (nth 4 fields)))
             (okuri (and (nth 5 fields) (ddskk-engine--unhex (nth 5 fields))))
             (path (ddskk-user-jisyo-path)))
        (ddskk-local-load-operations)
        (cond
         ((or (not (memq (length fields) '(5 6))) (not id) (> (length id) 96)
              (/= (length identity) 2) (/= (length client) 32)
              (not operation) (<= operation 0)
              (string-match "[^a-zA-Z0-9.-]" id) (not key) (not word)
              (not (ddskk-local-capability))
              (and (nth 5 fields) (or (not okuri) (not (ddskk-local-okuri-capability))))) "ERR LOCAL LEARN")
         ((and (gethash client ddskk-local-operations)
               (<= operation (car (gethash client ddskk-local-operations))))
          (concat "ACK " id " " (number-to-string (cdr (gethash client ddskk-local-operations)))))
         ((or (not path) (and (not (gethash client ddskk-local-operations))
                              (>= (hash-table-count ddskk-local-operations) 4096)))
          "ERR LOCAL STORAGE")
         (t
          (let ((skk-henkan-key key) (skk-henkan-okurigana okuri))
            (ddskk-user-jisyo--update word))
          ;; Candidate order and idempotency identity share one checkpoint.
          ;; Verification remains off the typing path; ACKs cannot change
          ;; an editing session, visible selection or committed text.
          (let ((old (gethash client ddskk-local-operations)))
            (puthash client (cons operation ddskk-user-jisyo-local-revision) ddskk-local-operations)
            (if (not (ddskk-local-save))
                (progn (if old (puthash client old ddskk-local-operations)
                         (remhash client ddskk-local-operations)) "ERR LOCAL STORAGE")
              (concat "ACK " id " " (number-to-string ddskk-user-jisyo-local-revision)))))))
    (error (ddskk-engine--error-token "ERR LOCAL" err))))

(defun ddskk-local-dispatch (line)
  "Return metadata without changing any input session."
  (cond
   ((equal line "LOCAL STATUS")
    (ddskk-local-load-operations)
    (concat "LOCAL " (cond ((ddskk-local-okuri-capability) "3 ")
                          ((ddskk-local-capability) "1 ") (t "0 "))
            (number-to-string ddskk-user-jisyo-local-revision)))
   ((equal line "LOCAL SNAPSHOT")
    ;; This certification is transient metadata, never personal-jisyo data.
    ;; Old engines emit no marker; a native reader then keeps Lisp-shaped
    ;; annotations on the provider. The ordinary STATUS bits stay unchanged.
    (concat "OVERLAY "
            (ddskk-engine--hex
             (concat (ddskk-user-jisyo--serialize)
                     (if (ddskk-local-capability)
                         (concat ddskk-local-literal-profile-marker "\n") "")))))
   ((and (> (length line) 12) (equal (substring line 0 12) "LOCAL LEARN "))
    (ddskk-local-learn line))
   (t "ERR LOCAL")))

(provide 'skk-local-conversion)
(ddskk-local-load-operations)
;;; skk-local-conversion.el ends here
