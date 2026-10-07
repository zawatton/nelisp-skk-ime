;;; session-v2.el --- Bounded persistent DDSKK sessions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(defvar ddskk-engine--session-limit 64
  "Maximum retained editing contexts, including legacy contexts.")
(defvar ddskk-engine--session-clock 0)
(defvar ddskk-engine--prepared-state nil
  "Snapshot captured by preparation or its first live conversion.")
(defvar ddskk-engine--prepared-keys nil
  "Exact reading keys already installed in the active context.")

(defun ddskk-engine--evict-session ()
  "Evict the least recently used context before allocating a new one."
  (when (>= (hash-table-count ddskk-engine--sessions)
            (max 1 ddskk-engine--session-limit))
    (let (victim age)
      (maphash (lambda (id record)
                 (when (or (not age) (< (aref record 7) age))
                   (setq victim id age (aref record 7))))
               ddskk-engine--sessions)
      (when victim
        (skk-ime-session-destroy
         (aref (gethash victim ddskk-engine--sessions) 0))
        (remhash victim ddskk-engine--sessions)
        (when (equal victim ddskk-engine--active-session-id)
          (setq ddskk-engine--active-session-id nil))))))

(defun ddskk-engine--prepare-reading (keys)
  "Feed only the unread suffix of KEYS; recover by replay on mismatch.
The complete reading is a recovery checkpoint, not a request to replay it.
Non-prefix edits, eviction and engine replacement use the same recovery path."
  (let ((offset 0))
    (if (and (stringp ddskk-engine--prepared-keys)
             (<= (length ddskk-engine--prepared-keys) (length keys))
             (equal ddskk-engine--prepared-keys
                    (substring keys 0 (length ddskk-engine--prepared-keys))))
        (setq offset (length ddskk-engine--prepared-keys))
      (ddskk-engine--end-registration)
      (skk-ime-session-reset ddskk-engine--session t))
    (when (< offset (length keys))
      (skk-ime-session-feed-string ddskk-engine--session (substring keys offset)))
    (setq ddskk-engine--prepared-keys keys)
    (setq ddskk-engine--prepared-state
          (skk-ime-session-snapshot ddskk-engine--session))))

(defun ddskk-engine--dispatch-v2 (line)
  "Handle version 2 reading preparation or conversion on the live context."
  (let* ((convert (equal (substring line 0 (min 15 (length line)))
                         "CONVERT-LIVE 2 "))
         (prefix (if convert 15 10))
         (keys (ddskk-engine--request-keys line prefix)))
    (if (not keys) "ERR SESSION KEYS"
      (condition-case err
          (let ((state (ddskk-engine--prepare-reading keys)))
            (if (and convert
                     (not (memq (plist-get state :mode) '(candidate registration))))
                (ddskk-engine--convert-or-register state)
              (ddskk-engine--state-line state)))
        (error (setq ddskk-engine--prepared-keys nil)
               (ddskk-engine--error-token "ERR SESSION" err))))))

(provide 'session-v2)
