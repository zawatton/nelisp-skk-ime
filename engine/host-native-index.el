;;; host-native-index.el --- Bounded SKK line parsing -*- lexical-binding: t; -*-

;; Native code owns source IO, bounds, accumulation and index publication.
;; The supplied NeLisp search primitive returns BYTE offsets. Use it only for
;; unibyte strings, whose substring offsets are bytes too. Multibyte strings
;; and GNU Emacs use the public character-indexed operations unchanged.

(defvar host-native-index-reclaim-bytes (* 256 1024)
  "Input bytes processed between explicit builder collections.")

(defvar host-native-index--reclaim-bytes 0
  "Input bytes processed since the last builder collection.")

(defun host-native-index-note-batch (bytes)
  "Account for BYTES of batch input; return non-nil iff garbage was collected."
  (setq host-native-index--reclaim-bytes
        (+ host-native-index--reclaim-bytes bytes))
  (when (>= host-native-index--reclaim-bytes host-native-index-reclaim-bytes)
    (garbage-collect)
    (setq host-native-index--reclaim-bytes 0)
    t))

(defun host-native-index-reset-reclaim ()
  "Reset the builder reclamation counter at the start of a generation."
  (setq host-native-index--reclaim-bytes 0))

;;;###autoload
(defun host-native-parse-jisyo-line (line &optional first-line)
  "Return (MIDASI . TAIL) from complete LINE, or nil for a skipped line.
When FIRST-LINE is non-nil, strip one leading UTF-8 BOM like LoadDictionaryFile.
Otherwise preserve BOM bytes like ParseSkkJisyo. Accept UTF-8 or unibyte data;
annotations, okuri blocks and even empty keys are copied verbatim."
  (when first-line
    (cond ((string-prefix-p (char-to-string 65279) line) (setq line (substring line 1)))
          ((string-prefix-p (unibyte-string 239 187 191) line)
           (setq line (substring line 3)))))
  (let* ((search (if (and (fboundp 'nelisp--string-search)
                          (fboundp 'nelisp--native-substring)
                          (not (multibyte-string-p line)))
                     #'nelisp--string-search #'string-search))
         (slice (if (eq search #'nelisp--string-search)
                    #'nelisp--native-substring #'substring)))
    ;; Search once for each delimiter. The usual trailing CR, LF or CRLF needs
    ;; only one slice; embedded/repeated breaks take the general search path.
    (let ((cr (funcall search "\r" line 0)) (lf (funcall search "\n" line 0)))
      (cond
       ((and cr (not lf) (= cr (1- (length line))))
        (setq line (funcall slice line 0 cr)))
       ((and lf (not cr) (= lf (1- (length line))))
        (setq line (funcall slice line 0 lf)))
       ((and cr lf (= cr (- (length line) 2)) (= lf (1- (length line))))
        (setq line (funcall slice line 0 cr)))
       ((or cr lf)
        (dolist (break '("\r" "\n"))
          (let ((start 0) (pieces nil) hit)
            (while (setq hit (funcall search break line start))
              (push (funcall slice line start hit) pieces)
              (setq start (1+ hit)))
            (when pieces
              (push (funcall slice line start) pieces)
              (setq line (apply #'concat (nreverse pieces)))))))))
    (unless (if (eq search #'nelisp--string-search)
                  (eq (funcall search ";;" line 0) 0)
                (string-prefix-p ";;" line))
      (let* ((space (funcall search " " line 0))
             (slash (and space (funcall search "/" line space))))
        (when slash (cons (funcall slice line 0 space) (funcall slice line slash)))))))

;;;###autoload
(defun host-native-parse-jisyo-batch (lines &optional first-line)
  "Parse bounded complete LINES in order, returning only midasi/tail records.
FIRST-LINE marks the first line of the file, not every batch. Duplicates remain
ordered records; accumulation, serialization and publication belong to native."
  (let ((records nil) record)
    (when (and first-line lines)
      (setq record (host-native-parse-jisyo-line (car lines) t))
      (when record (push record records))
      (setq lines (cdr lines)))
    (while lines
      (setq record (host-native-parse-jisyo-line (car lines)))
      (when record (push record records))
      (setq lines (cdr lines)))
    (nreverse records)))

(defun host-native-index--get (bytes offset width)
  "Read a bounded little-endian unsigned field from BYTES."
  (unless (<= (+ offset width) (length bytes)) (error "builder field bound"))
  (let ((value 0) (shift 0))
    (while (> width 0)
      (setq value (+ value (ash (aref bytes offset) shift))
            offset (1+ offset) shift (+ shift 8) width (1- width)))
    value))

(defvar host-native-index--u32-cache (make-vector 65537 nil)
  "Encoded u32 strings for line, key and tail lengths up to 64 KiB.")

(defun host-native-index--put (value width)
  "Encode VALUE in WIDTH (2 or 4) little-endian bytes."
  ;; Interpreted framing runs once per key and tail; avoid list building and
  ;; reuse the immutable length strings, which concat always copies.
  (if (= width 2)
      (unibyte-string (logand value 255) (logand (ash value -8) 255))
    (if (< value 65537)
        (or (aref host-native-index--u32-cache value)
            (aset host-native-index--u32-cache value
                  (unibyte-string (logand value 255) (logand (ash value -8) 255)
                                  (logand (ash value -16) 255) (logand (ash value -24) 255))))
      (unibyte-string (logand value 255) (logand (ash value -8) 255)
                      (logand (ash value -16) 255) (logand (ash value -24) 255)))))

(defun host-native-index--reply (frame)
  "Validate and parse one HNBQ FRAME; native has already stripped the BOM."
  (unless (and (>= (length frame) 40)
               (equal (substring frame 0 4) "HNBQ")
               (= (host-native-index--get frame 4 4) (- (length frame) 8))
               (= (host-native-index--get frame 8 2) 1)
               (= (host-native-index--get frame 10 2) 0))
    (error "builder header"))
  (let ((slice (if (and (fboundp 'nelisp--native-substring)
                        (not (multibyte-string-p frame)))
                   #'nelisp--native-substring #'substring))
        (payload (host-native-index--get frame 36 4))
        (count (host-native-index--get frame 32 4))
        (flags (host-native-index--get frame 28 4))
        (seq (host-native-index--get frame 24 4))
        (at 40) (lines nil) (pieces nil) (records nil) (size 0) (status 0))
    (unless (and (<= payload 262144) (= payload (- (length frame) 40))
                 (<= count 65536)) (error "builder payload bound"))
    (while (> count 0)
      (let ((n (host-native-index--get frame at 4)))
        (setq at (+ at 4))
        (unless (and (<= n 65536) (<= n (- (length frame) at)))
          (error "builder line bound"))
        ;; Native byte slicing copies only this line, without walking FRAME's
        ;; prefix again for each character-indexed substring.
        (let ((line (funcall slice frame at (+ at n))))
          ;; Use the byte primitive for unibyte lines, like the parser.
          (when (if (and (fboundp 'nelisp--string-search) (not (multibyte-string-p line)))
                    (nelisp--string-search "\n" line 0)
                  (string-search "\n" line))
            (error "builder incomplete line"))
          (push line lines))
        (setq at (+ at n) count (1- count))))
    (unless (= at (length frame)) (error "builder trailing bytes"))
    ;; The flag validates file boundaries only; a second BOM remains data.
    (if (/= flags (if (= seq 0) 1 0)) (setq status 1)
      (setq records (host-native-parse-jisyo-batch (nreverse lines) nil))
      (dolist (record records)
        (let ((key (car record)) (tail (cdr record)))
          (setq size (+ size 8 (length key) (length tail)))
          (push (host-native-index--put (length key) 4) pieces)
          (push key pieces)
          (push (host-native-index--put (length tail) 4) pieces)
          (push tail pieces)))
      (when (> size 524288) (setq status 2)))
    (when (/= status 0) (setq pieces nil records nil size 0))
    ;; Join headers and record fields together once; no intermediate record
    ;; strings or separately flattened payload are needed.
    (apply #'concat
           (append (list "HNBR" (host-native-index--put (+ 32 size) 4)
                         (host-native-index--put 1 2) (host-native-index--put status 2)
                         (funcall slice frame 12 28) (host-native-index--put 0 4)
                         (host-native-index--put (length records) 4)
                         (host-native-index--put size 4))
                   (nreverse pieces)))))

;;;###autoload
(defun host-native-index-serve ()
  "Serve the private HNB v1 stream. Loading this file never starts IO."
  (let* ((pending nil) (pending-length 0) (frame-size nil)
         (slice (if (fboundp 'nelisp--native-substring)
                    #'nelisp--native-substring #'substring))
         (generation nil) (bytes nil)
         (key (or (getenv "NATIVEIME_REGISTRY_KEY") ""))
         (harness (and (equal (getenv "DDSKK_HARNESS_DIAGNOSTICS") "1")
                       (string-prefix-p "Software\\NativeIME-test-" key)))
         (fault (and harness (getenv "DDSKK_HOST_BUILDER_TEST_FAULT")))
         (replied nil))
    (nelisp--write-stdout-bytes "HNB READY version=1\n")
    (while (setq bytes (read-stdin-bytes 4096))
      ;; Match the policy stream's recovery of byte IO from multibyte strings.
      (when (multibyte-string-p bytes)
        (setq bytes (encode-coding-string bytes 'utf-8)))
      (let ((at 0) (end (length bytes)))
        (while (< at end)
          ;; First collect only the eight-byte envelope. Once its bound is
          ;; known, retain body chunks until the entire frame can be joined.
          (let* ((need (- (or frame-size 8) pending-length))
                 (take (min need (- end at)))
                 (next (+ at take)))
            (push (if (and (= at 0) (= next end)) bytes
                    (funcall slice bytes at next)) pending)
            (setq pending-length (+ pending-length take) at next))
          (when (and (not frame-size) (= pending-length 8))
            (let ((header (apply #'concat (nreverse pending))))
              (unless (equal (funcall slice header 0 4) "HNBQ")
                (error "builder magic"))
              (setq frame-size (+ 8 (host-native-index--get header 4 4)))
              (unless (and (>= frame-size 40) (<= frame-size (+ 40 262144)))
                (error "builder frame bound"))
              (setq pending (list header))))
          (when (and frame-size (= pending-length frame-size))
              (let* ((frame (apply #'concat (nreverse pending)))
                     (current (funcall slice frame 12 20)))
                ;; Keep the opaque u64 as bytes, including values above fixnum.
                (unless (equal current generation)
                  (setq generation current)
                  (host-native-index-reset-reclaim))
                (let ((reply (host-native-index--reply frame)))
                  ;; Midstream dies after one complete reply, mid-generation.
                  (when (and replied (equal fault "midstream")) (error "builder test midstream"))
                  (when (equal fault "timeout")
                    (let ((until (+ (float-time) 20)))
                      (while (< (float-time) until))))
                  (nelisp--write-stdout-bytes reply)
                  (setq replied t))
                (host-native-index-note-batch (- frame-size 40)))
              (setq pending nil pending-length 0 frame-size nil))))
      (setq bytes nil))
    (unless (= pending-length 0) (error "builder truncated"))))

(provide 'host-native-index)
;;; host-native-index.el ends here
