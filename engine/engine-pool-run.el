;;; engine-pool-run.el --- Run conversion cases in one reused DDSKK engine -*- lexical-binding: t; -*-

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

;;; Commentary:

;; Engine-level conversion tests used to start one NeLisp engine per run,
;; and each start loads the engine and its dictionaries (34 CPU-seconds
;; on the IME runtime, measured 2026-10-09).  This runner loads the
;; engine once in a worker of NeLisp's nelisp-service pool (NeLisp Doc
;; 213) and replays every case in it, with RESET between cases.
;;
;; With ENGINE_POOL_FRESH_CHECK=1 it also replays each case in a fresh
;; engine and requires identical replies, so reuse cannot hide state
;; leaking from one case into the next.
;;
;; Started by windows/test-host/test-engine-pool.ps1 as
;; `nelisp --load engine/engine-pool-run.el' with the repository root as
;; the working directory.  Settings come from the environment the script
;; sets (the runner's own `getenv' sees it; its workers get theirs through
;; :init-forms, because the standalone reader does not pass `setenv' on):
;;
;;   ENGINE_POOL_PRIVATE      required: private directory for the user
;;                            dictionary and LOCALAPPDATA, so a test never
;;                            touches the real ones
;;   ENGINE_POOL_CASES        case file (default
;;                            windows/test-host/conversion-corpus.json)
;;   ENGINE_POOL_FRESH_CHECK  1 to compare against fresh engines
;;   NELISP_SERVICE_SRC       nelisp-service src directory (default: the
;;                            sibling ../nelisp checkout)
;;   ENGINE_POOL_SKIP_RESET   1 omits RESET between cases: the negative
;;                            control, which the fresh check must reject
;;
;; Output: one `case NAME ok|FAIL ...' line per case, timing lines, and a
;; final ENGINE-POOL-PASS or ENGINE-POOL-FAIL.

;;; Code:

(defun engine-pool-run--env (name &optional default)
  "Return environment variable NAME, or DEFAULT when unset or empty."
  (let ((value (getenv name)))
    (if (and value (> (length value) 0)) value default)))

(defvar engine-pool-run--root (expand-file-name default-directory))

(add-to-list 'load-path
             (expand-file-name
              (engine-pool-run--env
               "NELISP_SERVICE_SRC"
               (expand-file-name "../nelisp/packages/nelisp-service/src"
                                 engine-pool-run--root))))
(require 'nelisp-service-worker)

(defun engine-pool-run--find (needle haystack start)
  "Return the index of NEEDLE in HAYSTACK at or after START, or nil."
  (let ((n (length needle)) (limit (- (length haystack) (length needle)))
        (i start) (found nil))
    (while (and (not found) (<= i limit))
      (when (string= needle (substring haystack i (+ i n))) (setq found i))
      (setq i (1+ i)))
    found))

(defun engine-pool-run--string-after (text key start)
  "Return (VALUE . END) for the string value of \"KEY\" after START, or nil.
Case files hold plain ASCII key strings, so escapes are not decoded."
  (let ((at (engine-pool-run--find (concat "\"" key "\":\"") text start)))
    (when at
      (let* ((from (+ at (length key) 4))
             (to (engine-pool-run--find "\"" text from)))
        (cons (substring text from to) (1+ to))))))

(defun engine-pool-run--cases (file)
  "Return the cases in FILE as a list of (NAME . KEYS).
FILE is a JSON array of flat objects with string \"name\" and \"keys\"
fields, written name first, like conversion-corpus.json.  The standalone
reader has no `json-parse-string', so this reads that one shape."
  (let ((text (with-temp-buffer
                (insert-file-contents file)
                (buffer-string)))
        (pos 0) (cases nil) (name nil))
    (while (setq name (engine-pool-run--string-after text "name" pos))
      (let ((keys (engine-pool-run--string-after text "keys" (cdr name))))
        (push (cons (car name) (car keys)) cases)
        (setq pos (cdr keys))))
    (nreverse cases)))

(defun engine-pool-run--case-form (keys)
  "Return the form a worker evaluates to replay KEYS and convert."
  (let ((lines (unless (equal (engine-pool-run--env "ENGINE_POOL_SKIP_RESET") "1")
                 (list "RESET"))))
    (dotimes (i (length keys))
      (push (format "KEY %d" (aref keys i)) lines))
    (push "KEY 32" lines)
    `(mapcar #'ddskk-engine-dispatch-line ',(nreverse lines))))

(defun engine-pool-run--pool (private)
  "Return a one-worker pool whose engine keeps its files under PRIVATE."
  (nelisp-service-pool-create
   :name "ddskk-engine" :max-workers 1
   :init-forms
   `((setenv "DDSKK_USER_JISYO" ,(expand-file-name "user-jisyo" private))
     (setenv "LOCALAPPDATA" ,private)
     (setenv "DDSKK_SKKSERV_ENABLE" "0")
     (setenv "DDSKK_SKKSERV_START_COMMAND" "")
     (load ,(expand-file-name "engine/ddskk-engine.el" engine-pool-run--root) nil t)
     (ddskk-engine-dispatch-line "HELLO 1"))))

(defun engine-pool-run--replay (pool cases)
  "Replay CASES in POOL; return an alist (NAME . REPLIES)."
  (mapcar (lambda (c)
            (cons (car c)
                  (nelisp-service-pool-call
                   pool (engine-pool-run--case-form (cdr c)) 300)))
          cases))

(defun engine-pool-run-main ()
  "Run the cases and print the report.  Return 0."
  (let ((private (engine-pool-run--env "ENGINE_POOL_PRIVATE"))
        (failed nil))
    (unless private
      (error "ENGINE_POOL_PRIVATE must name a private directory"))
    (make-directory private t)
    (let* ((cases (engine-pool-run--cases
                   (expand-file-name
                    (engine-pool-run--env "ENGINE_POOL_CASES"
                                          "windows/test-host/conversion-corpus.json")
                    engine-pool-run--root)))
           (t0 (float-time))
           (pool (engine-pool-run--pool private))
           (pooled (unwind-protect (engine-pool-run--replay pool cases)
                     (setq failed (> (plist-get (nelisp-service-pool-stats pool) :spawned) 1))
                     (nelisp-service-pool-shutdown pool)))
           (pooled-secs (- (float-time) t0)))
      (princ (format "pooled cases=%d engine-starts=1 secs=%.1f\n"
                     (length cases) pooled-secs))
      (when (equal (engine-pool-run--env "ENGINE_POOL_FRESH_CHECK") "1")
        (let ((t1 (float-time)))
          (dolist (c cases)
            (let* ((fresh-pool (engine-pool-run--pool private))
                   (fresh (unwind-protect
                              (cdar (engine-pool-run--replay fresh-pool (list c)))
                            (nelisp-service-pool-shutdown fresh-pool)))
                   (same (equal fresh (cdr (assoc (car c) pooled)))))
              (unless same (setq failed t))
              (princ (format "case %s %s final=%s\n" (car c) (if same "ok" "FAIL")
                             (car (last (cdr (assoc (car c) pooled))))))))
          (princ (format "fresh cases=%d engine-starts=%d secs=%.1f\n"
                         (length cases) (length cases) (- (float-time) t1)))))
      (princ (if failed "ENGINE-POOL-FAIL\n" "ENGINE-POOL-PASS\n"))))
  0)

(engine-pool-run-main)

;;; engine-pool-run.el ends here
