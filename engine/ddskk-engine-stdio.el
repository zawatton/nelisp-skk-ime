;;; ddskk-engine-stdio.el --- DDSKK native-host stdio runner -*- lexical-binding: t; -*-

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

;; Line protocol (UTF-8, one request/response per line):
;;   HELLO 1                  -> OK 1
;;   KEY <decimal-codepoint>  -> STATE <mode> <cursor> <start|-1> <hex-text> <hex-prefix>
;;   RESET                    -> STATE ...
;;   QUIT                     -> OK BYE
;;   malformed request        -> ERR <ASCII-token>
;; Strings are UTF-8 bytes represented as lowercase hex, keeping framing
;; independent from whitespace, newline, and future candidate annotations.

(load "engine/ddskk-engine.el")

;; The host gives each blue-green child its own selection. DDSKK used to
;; require an ENGINE SET from the first client even for passthrough startup.
(when (equal (getenv "NELISP_IME_ENGINE") "passthrough")
  (ddskk-engine-dispatch-line "ENGINE SET passthrough"))

(defun ddskk-engine-read-stdio-line ()
  "Read one protocol line from NeLisp stdin, or return nil at EOF."
  (let ((line (read-stdin-bytes 8192)))
    (when line
      (let ((length (length line)))
        (while (and (> length 0)
                    (or (= (aref line (1- length)) 10)
                        (= (aref line (1- length)) 13)))
          (setq length (1- length)))
        (substring line 0 length)))))

(defun ddskk-engine-run-stdio ()
  (let ((running t)
        request)
    (while running
      (setq request (ddskk-engine-read-stdio-line))
      (if (not request)
          (setq running nil)
        (progn
          ;; Keep every request on the session dispatcher. A separate KEY
          ;; path bypasses modal registration and legacy session ownership.
          (ddskk-engine-dispatch-line-to-stdout request)
          (when (equal request "QUIT") (setq running nil)))))
    (ddskk-engine-stop)))

(ddskk-engine-run-stdio)
