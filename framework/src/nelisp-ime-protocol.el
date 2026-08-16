;;; nelisp-ime-protocol.el --- Versioned JSON-RPC protocol for NeLisp IME -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A line-delimited JSON-RPC boundary shared by native platform adapters.

;;; Code:

(require 'nelisp-json)
(require 'nelisp-ime)

(declare-function nelisp-ime-dictionary-load-skk "nelisp-ime-lattice"
                  (file &optional coding expand-okuri))

(defconst nelisp-ime-protocol-version 1)

(defun nelisp-ime-protocol--object (&rest pairs)
  "Build a JSON object from alternating PAIRS."
  (let ((object (make-hash-table :test 'equal)))
    (while pairs
      (puthash (car pairs) (cadr pairs) object)
      (setq pairs (cddr pairs)))
    object))

(defun nelisp-ime-protocol--input-style (value)
  "Validate and translate JSON input style VALUE."
  (cond ((or (equal value "kana") (eq value 'kana)) 'kana)
        ((or (equal value "romaji") (eq value 'romaji)) 'romaji)
        (t (error "nelisp-ime: unsupported input style %S" value))))

(defun nelisp-ime-protocol--operation (value)
  "Validate and translate JSON operation VALUE."
  (let ((entry (assoc value '(("key" . :key) ("insert" . :insert)
                              ("backspace" . :backspace)
                              ("select-segment" . :select-segment)
                              ("select-candidate" . :select-candidate)
                              ("commit" . :commit) ("cancel" . :cancel)))))
    (or (cdr entry) (error "nelisp-ime: unsupported operation %S" value))))

(defun nelisp-ime-protocol--detail (value)
  "Translate JSON snapshot detail VALUE, or nil to leave it unset."
  (cond ((or (null value) (eq value :null)) nil)
        ((equal value "full") 'full)
        ((equal value "compact") 'compact)
        (t (error "nelisp-ime: unsupported snapshot detail %S" value))))

(defun nelisp-ime-protocol--event (object)
  "Translate JSON event OBJECT into the core event plist."
  (list :op (nelisp-ime-protocol--operation (gethash "op" object))
        :text (gethash "text" object)
        :key (gethash "key" object)
        :code (gethash "code" object)
        :shift (eq (gethash "shift" object) t)
        :index (gethash "index" object)))

(defun nelisp-ime-protocol-dispatch (method params)
  "Dispatch protocol METHOD with JSON object PARAMS."
  (cond
   ((equal method "ime/initialize")
    (let ((requested (gethash "protocolVersion" params)))
      (unless (= requested nelisp-ime-protocol-version)
        (error "nelisp-ime: unsupported protocol version %S" requested))
      (list :protocolVersion nelisp-ime-protocol-version
            :engine "nelisp-ime"
            :engines (vconcat (mapcar #'symbol-name
                                      (nelisp-ime-engine-names)))
            :modes (vconcat (mapcar #'symbol-name nelisp-ime-modes))
            :capabilities ["kana" "romaji" "live-conversion" "learning"
                           "multi-session" "engine-select" "mode-report"
                           "session-reset" "maintenance" "compact-snapshot"])))
   ((equal method "ime/health") (list :ok t))
   ((equal method "ime/dictionary.load")
    ;; SKK dictionary loading belongs to the bundled lattice engine; keep
    ;; the protocol loadable without it and fail with a clear message.
    (unless (fboundp 'nelisp-ime-dictionary-load-skk)
      (error "nelisp-ime: dictionary.load requires the lattice engine"))
    (list :entries
          (nelisp-ime-dictionary-load-skk
           (gethash "file" params)
           (and (equal (gethash "coding" params) "utf-8") 'utf-8))))
   ((equal method "ime/session.open")
    (let ((engine (gethash "engine" params)))
      (nelisp-ime-session-open
       (gethash "sessionId" params)
       (list :input-style
             (nelisp-ime-protocol--input-style (gethash "inputStyle" params))
             :context (gethash "context" params)
             :engine (and (stringp engine) (> (length engine) 0)
                          (intern engine))
             :detail (nelisp-ime-protocol--detail
                      (gethash "detail" params))))))
   ((equal method "ime/session.close")
    (list :closed (nelisp-ime-session-close (gethash "sessionId" params))))
   ((equal method "ime/session.feed")
    (nelisp-ime-feed (gethash "sessionId" params)
                     (nelisp-ime-protocol--event (gethash "event" params))))
   ((equal method "ime/session.status")
    (nelisp-ime-session-status (gethash "sessionId" params)
                               (nelisp-ime-protocol--detail
                                (gethash "detail" params))))
   ((equal method "ime/session.reset")
    (nelisp-ime-session-reset (gethash "sessionId" params)))
   ((equal method "ime/maintenance")
    (let ((operation (gethash "operation" params))
          (engine (gethash "engine" params)))
      (unless (stringp operation)
        (error "nelisp-ime: maintenance requires an operation"))
      (list :operation operation
            :result (nelisp-ime-maintain
                     (intern operation)
                     (and (stringp engine) (> (length engine) 0)
                          (intern engine))))))
   ((equal method "ime/learning.compact")
    (list :rows (nelisp-ime-learning-compact (gethash "file" params))))
   ((equal method "ime/learning.load")
    (list :rows (nelisp-ime-learning-load (gethash "file" params))))
   ((equal method "ime/learning.save")
    (list :file (nelisp-ime-learning-save (gethash "file" params))))
   ((equal method "ime/learning.export")
    (list :rows (vconcat (nelisp-ime-learning-export))))
   ((equal method "ime/learning.import")
    (list :rows (nelisp-ime-learning-import (gethash "rows" params))))
   (t (error "nelisp-ime: unknown method %S" method))))

(defun nelisp-ime-protocol--response (id result)
  "Encode successful RESULT for request ID."
  ;; A plist, not a hash table: both encode to the same JSON, but building a
  ;; hash table and walking it with `maphash' costs ~340ms per response on
  ;; the standalone runtime regardless of payload size -- measured as the
  ;; entire cost of encoding a snapshot.
  (nelisp-json-encode (list :jsonrpc "2.0" :id id :result result)))

(defun nelisp-ime-protocol--error (id error-data)
  "Encode ERROR-DATA for request ID."
  (nelisp-json-encode
   (list :jsonrpc "2.0" :id id
         :error (list :code -32603 :message (format "%S" error-data)))))

(defun nelisp-ime-protocol-handle-json (line)
  "Handle one line-delimited JSON-RPC request LINE and return JSON."
  (let (id)
    (condition-case err
      (let* ((request (nelisp-json-parse-string line))
             (_ (setq id (gethash "id" request)))
             (params (or (gethash "params" request)
                         (make-hash-table :test 'equal))))
        (nelisp-ime-protocol--response
         id (nelisp-ime-protocol-dispatch (gethash "method" request) params)))
      (error (nelisp-ime-protocol--error id err)))))

(provide 'nelisp-ime-protocol)
;;; nelisp-ime-protocol.el ends here
