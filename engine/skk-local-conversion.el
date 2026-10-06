;;; skk-local-conversion.el --- Local conversion metadata and learning -*- lexical-binding: t; -*-
;; GPL-3.0-or-later

;; The engine alone writes the personal jisyo. Local learning does not
;; activate, reset, restore or feed an editing session.
(defvar ddskk-local-operations (make-hash-table :test 'equal))
(defvar ddskk-local-operations-loaded nil)

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

(defun ddskk-local-capability ()
  "Certify only the two-source ordinary plan implemented by the core."
  (and (equal skk-search-prog-list
              '((ddskk-user-jisyo-search) (ddskk-engine-server-search)))
       (eq skk-update-jisyo-function 'ddskk-user-jisyo--update)
       (not ddskk-user-jisyo-learning-disabled)
       (not (and (boundp 'skk-search-end-function) skk-search-end-function))
       (not (and (boundp 'skk-search-hook) skk-search-hook))
       (not (and (boundp 'skk-kakutei-hook) skk-kakutei-hook))))

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
    (concat "OVERLAY " (ddskk-engine--hex (ddskk-user-jisyo--serialize))))
   ((and (> (length line) 12) (equal (substring line 0 12) "LOCAL LEARN "))
    (ddskk-local-learn line))
   (t "ERR LOCAL")))

(provide 'skk-local-conversion)
(ddskk-local-load-operations)
;;; skk-local-conversion.el ends here
