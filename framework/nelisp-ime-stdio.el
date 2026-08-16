;;; nelisp-ime-stdio.el --- nelisp-ime native-host stdio runner -*- lexical-binding: t; -*-

;; Copyright (C) 2026 nelisp-skk-ime contributors

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied
;; warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
;; PURPOSE.  See the GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; The counterpart of engine/ddskk-engine-stdio.el for the nelisp-ime
;; framework: same line protocol, same host, different conversion.  The
;; C++ host launches one of the two runners and cannot tell them apart,
;; which is the point -- `ENGINE LIST' and `ENGINE SET' then select among
;; whatever engines the loaded runner registered.
;;
;; Load order matters: the framework core first, then every engine, since
;; an engine registers itself with the core as it loads.

(load "framework/src/nelisp-json.el")
(load "framework/src/nelisp-ime-input.el")
(load "framework/src/nelisp-ime.el")
(load "framework/src/nelisp-ime-protocol.el")
(load "framework/src/nelisp-ime-stateline.el")

;; Engines.  The lattice engine brings the generated SKK-derived
;; dictionary with it; loading the data file is what fills its index.
(load "engines/lattice/src/nelisp-ime-lattice.el")
(load "engines/lattice/data/nelisp-ime-dictionary-data.el")

;; The host expects the engine it configured to be the one answering, so
;; honour NELISP_IME_ENGINE when the host sets it; otherwise the wire's
;; `ENGINE SET' still applies at runtime.
(let ((requested (getenv "NELISP_IME_ENGINE")))
  (when (and requested (> (length requested) 0))
    (let ((name (intern requested)))
      (when (nelisp-ime-engine-get name)
        (setq nelisp-ime-default-engine name)))))

(defvar nelisp-ime-stdio--pending ""
  "Bytes read from stdin that do not yet form a complete line.

`read-stdin-bytes' returns whatever is available, not one line: piping
several requests at once delivers them in a single read.  The host writes
one line per request so this rarely matters in production, but a reader
that assumed one-read-one-line dropped every request after the first.")

(defun nelisp-ime-stdio--take-line ()
  "Return the next complete line from the buffer, or nil if none yet."
  (let ((newline (nelisp-ime-stdio--index-of-newline
                  nelisp-ime-stdio--pending)))
    (when newline
      (let ((line (substring nelisp-ime-stdio--pending 0 newline)))
        (setq nelisp-ime-stdio--pending
              (substring nelisp-ime-stdio--pending (1+ newline)))
        ;; A CRLF sender leaves the carriage return behind.
        (let ((length (length line)))
          (while (and (> length 0) (= (aref line (1- length)) 13))
            (setq length (1- length)))
          (substring line 0 length))))))

(defun nelisp-ime-stdio--index-of-newline (text)
  "Return the index of the first newline in TEXT, or nil."
  (let ((index 0)
        (count (length text))
        (found nil))
    (while (and (null found) (< index count))
      (when (= (aref text index) 10) (setq found index))
      (setq index (1+ index)))
    found))

(defun nelisp-ime-stdio-read-line ()
  "Return the next protocol line, reading more input when needed.
Returns nil at end of input."
  (let ((line (nelisp-ime-stdio--take-line))
        (eof nil))
    (while (and (null line) (not eof))
      (let ((chunk (read-stdin-bytes 8192)))
        (if (or (null chunk) (= (length chunk) 0))
            (setq eof t)
          (setq nelisp-ime-stdio--pending
                (concat nelisp-ime-stdio--pending chunk))
          (setq line (nelisp-ime-stdio--take-line)))))
    ;; At end of input a final request without its newline is still valid.
    (when (and (null line) (> (length nelisp-ime-stdio--pending) 0))
      (setq line nelisp-ime-stdio--pending)
      (setq nelisp-ime-stdio--pending ""))
    line))

(defun nelisp-ime-stdio-run ()
  "Serve the STATE line protocol on stdin/stdout until EOF or QUIT."
  (let ((running t)
        line)
    (while running
      (setq line (nelisp-ime-stdio-read-line))
      (if (not line)
          (setq running nil)
        (nelisp--write-stdout-bytes
         (concat (nelisp-ime-stateline-dispatch line) "\n"))
        (when (equal line "QUIT") (setq running nil))))))

(nelisp-ime-stdio-run)
