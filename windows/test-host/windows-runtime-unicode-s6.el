;;; windows-runtime-unicode-s6.el --- Exact image byte probe -*- lexical-binding: t; -*-
;; No policy loop or resource measurement is loaded by this OS1 gate.
(let* ((text (string #x304b #x306a #x1f600 #x65 #x301))
       (bytes (encode-coding-string text 'utf-8)))
  (unless (equal text (decode-coding-string bytes 'utf-8))
    (error "S6 Unicode roundtrip"))
  (nelisp--write-stdout-bytes (concat "S6 UNICODE " bytes "\n")))
