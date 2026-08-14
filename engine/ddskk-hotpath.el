;;; ddskk-hotpath.el --- Native-compilation probes for DDSKK IME -*- lexical-binding: t; -*-

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

(defun ddskk-hotpath-ascii-vowel-p (codepoint)
  "Return 1 when CODEPOINT is a lowercase ASCII vowel, otherwise 0."
  (if (or (= codepoint 97)
          (= codepoint 105)
          (= codepoint 117)
          (= codepoint 101)
          (= codepoint 111))
      1
    0))

(defun ddskk-hotpath-decimal-step (value digit)
  "Append decimal DIGIT to VALUE."
  (+ (* value 10) (- digit 48)))

;;; ddskk-hotpath.el ends here
