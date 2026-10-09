;;; windows-runtime-s6.el --- Exact image discovery and Unicode bytes -*- lexical-binding: t; -*-
;; Discovery is not OS qualification. Native boundary gates remain mandatory.
(let* ((text (string #x304b #x306a #x1f600 #x65 #x301))
       (bytes (encode-coding-string text 'utf-8)))
  (unless (equal text (decode-coding-string bytes 'utf-8))
    (error "S6 Unicode roundtrip"))
  (nelisp--write-stdout-bytes (concat "S6 UNICODE " bytes "\n")))
(dolist (name '(make-network-process open-network-stream mmap munmap
               rename-file write-region start-process process-send-string
               accept-process-output run-at-time garbage-collect))
  (nelisp--write-stdout-bytes
   (format "S6 DISCOVERY %s %s\n" name (if (fboundp name) "present" "absent"))))
(load "engine/host-policy.el")
