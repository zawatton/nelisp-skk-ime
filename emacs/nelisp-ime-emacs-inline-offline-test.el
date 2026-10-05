;;; nelisp-ime-emacs-inline-offline-test.el --- Offline transport -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Supplementary validation for sandboxes that prohibit TCP sockets.
;; Real process objects carry filters, sentinels, and coding systems, while
;; an in-memory queue substitutes for connect/read/write.  This does not
;; qualify binding, listening, or actual TCP transport.  The main ERT file
;; uses real TCP by default and is not changed by loading this file alone.

;;; Code:
(require 'nelisp-ime-emacs)
(require 'ert)

(defun nelisp-ime-emacs-inline-test-run-offline (&optional selector log-file)
  "Run SELECTOR using a simulated transport, then exit with ERT's status."
  (let ((network-processes nil) queue stats
        (original-contact (symbol-function 'process-contact))
        (original-delete (symbol-function 'delete-process)))
    (cl-labels
        ((new-pipe (options)
           (let ((process (make-pipe-process
                           :name (plist-get options :name) :noquery t
                           :coding (or (plist-get options :coding) 'utf-8-unix)
                           :filter (plist-get options :filter)
                           :sentinel (plist-get options :sentinel))))
             (push process network-processes)
             (process-put process 'offline-options options)
             process))
         (connect (&rest options)
           (let ((process (new-pipe options)))
             (unless (plist-get options :server)
               (let* ((server nelisp-ime-emacs--inline-server)
                      (settings (process-get server 'offline-options))
                      (peer (new-pipe settings)))
                 (process-put process 'offline-peer peer)
                 (process-put peer 'offline-peer process)
                 (funcall (plist-get settings :log) server peer "offline accept")))
             process))
         (send (process string)
           (unless (process-live-p process) (error "Offline connection closed"))
           (setq queue
                 (nconc queue
                        (list (cons (process-get process 'offline-peer)
                                    (encode-coding-string
                                     string (cdr (process-coding-system process))))))))
         (receive (&rest _)
           (while queue
             (let* ((packet (pop queue)) (peer (car packet)))
               (when (process-live-p peer)
                 (let* ((bytes (concat (process-get peer 'offline-undecoded) (cdr packet)))
                        (text (decode-coding-string bytes (car (process-coding-system peer))))
                        (end (length text)))
                   ;; Retain an incomplete UTF-8 suffix across writes.  Bad
                   ;; bytes inside a complete line still reach the filter.
                   (while (and (> end 0) (> (aref text (1- end)) #x10ffff))
                     (cl-decf end))
                   (process-put peer 'offline-undecoded
                                (encode-coding-string (substring text end) 'binary))
                   (when (> end 0)
                     (funcall (process-filter peer) peer (substring text 0 end)))))))
           t)
         (close (process)
           (let ((peer (process-get process 'offline-peer)))
             (funcall original-delete process)
             (when (process-live-p peer) (funcall original-delete peer))))
         (contact (process &optional key)
           (if (memq process network-processes)
               (pcase key (:service 43123) (:local [127 0 0 1 43123])
                      (_ (funcall original-contact process key)))
             (funcall original-contact process key))))
      (unwind-protect
          (cl-letf (((symbol-function 'make-network-process) #'connect)
                    ((symbol-function 'process-contact) #'contact)
                    ((symbol-function 'process-send-string) #'send)
                    ((symbol-function 'accept-process-output) #'receive)
                    ((symbol-function 'delete-process) #'close))
            (message "OFFLINE transport: TCP binding/listening not exercised")
            (setq stats (ert-run-tests-batch selector)))
        (dolist (process network-processes) (funcall original-delete process)))
      (when log-file
        (with-current-buffer "*Messages*"
          (write-region (point-min) (point-max) log-file nil 'silent)))
      (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))))

;;; nelisp-ime-emacs-inline-offline-test.el ends here
