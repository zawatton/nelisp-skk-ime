;;; nelisp-ime-protocol-test.el --- Tests for NeLisp IME JSON-RPC -*- lexical-binding: t; -*-

(require 'ert)
(require 'nelisp-ime-protocol)

(defun nelisp-ime-protocol-test--request (id method &optional params)
  (nelisp-json-encode
   (nelisp-ime-protocol--object
    "jsonrpc" "2.0" "id" id "method" method
    "params" (or params (make-hash-table :test 'equal)))))

(ert-deftest nelisp-ime-protocol-test-initialize-version ()
  (let* ((params (nelisp-ime-protocol--object "protocolVersion" 1))
         (json (nelisp-ime-protocol-handle-json
                (nelisp-ime-protocol-test--request 1 "ime/initialize" params)))
         (response (nelisp-json-parse-string json))
         (result (gethash "result" response)))
    (should (= (gethash "id" response) 1))
    (should (= (gethash "protocolVersion" result) 1))
    (should (equal (gethash "engine" result) "nelisp-ime"))
    (let* ((providers (gethash "providers" result))
           (dictionary (aref providers 0)))
      (should (equal (gethash "id" dictionary) "dictionary"))
      (should (member "conversion"
                      (append (gethash "capabilities" dictionary) nil)))
      (should (equal (append (gethash "settings" dictionary) nil)
                     '("initial-kana-mode"))))))

(ert-deftest nelisp-ime-protocol-test-session-round-trip ()
  (let ((nelisp-ime-sessions (make-hash-table :test 'equal))
        (nelisp-ime-dictionary '(("かな" "仮名")))
        (nelisp-ime-converter-function #'nelisp-ime-dictionary-convert))
    (let ((open (nelisp-ime-protocol--object
                 "sessionId" "mac:1" "inputStyle" "kana")))
      (nelisp-ime-protocol-handle-json
       (nelisp-ime-protocol-test--request 1 "ime/session.open" open)))
    (let* ((event (nelisp-ime-protocol--object
                   "op" "insert" "text" "かな"))
           (params (nelisp-ime-protocol--object
                    "sessionId" "mac:1" "event" event))
           (response (nelisp-json-parse-string
                      (nelisp-ime-protocol-handle-json
                       (nelisp-ime-protocol-test--request
                        2 "ime/session.feed" params))))
           (result (gethash "result" response)))
      ;; Typing shows the kana that were typed; conversion is a separate
      ;; request, so the preedit is still the reading here.
      (should (equal (gethash "reading" result) "かな"))
      (should (equal (gethash "preedit" result) "かな")))
    (let* ((event (nelisp-ime-protocol--object "op" "convert"))
           (params (nelisp-ime-protocol--object
                    "sessionId" "mac:1" "event" event))
           (response (nelisp-json-parse-string
                      (nelisp-ime-protocol-handle-json
                       (nelisp-ime-protocol-test--request
                        3 "ime/session.feed" params))))
           (result (gethash "result" response)))
      (should (equal (gethash "preedit" result) "仮名")))))

(ert-deftest nelisp-ime-protocol-test-rejects-version-and-method ()
  (let* ((params (nelisp-ime-protocol--object "protocolVersion" 99))
         (response (nelisp-json-parse-string
                    (nelisp-ime-protocol-handle-json
                     (nelisp-ime-protocol-test--request
                      1 "ime/initialize" params)))))
    (should (hash-table-p (gethash "error" response))))
  (let ((response (nelisp-json-parse-string
                   (nelisp-ime-protocol-handle-json
                    (nelisp-ime-protocol-test--request 2 "ime/missing")))))
    (should (hash-table-p (gethash "error" response)))))

(ert-deftest nelisp-ime-protocol-test-learning-import-export ()
  (let ((nelisp-ime-learning (make-hash-table :test 'equal)))
    (let* ((rows [["かな" "仮名" 4]])
           (params (nelisp-ime-protocol--object "rows" rows))
           (imported (nelisp-ime-protocol-dispatch
                      "ime/learning.import" params)))
      (should (= (plist-get imported :rows) 1)))
    (let* ((exported (nelisp-ime-protocol-dispatch
                      "ime/learning.export"
                      (make-hash-table :test 'equal)))
           (rows (plist-get exported :rows)))
      (should (vectorp rows))
      ;; Four fields since learning started recording recency: the count is
      ;; still third, and a row imported without a fourth field (as above)
      ;; exports with recency 0 -- never chosen through this table.
      (should (equal (aref rows 0) '("かな" "仮名" 4 0))))))

(ert-deftest nelisp-ime-protocol-test-learning-import-accepts-both-shapes ()
  "Three-field rows keep loading, so an older saved table still imports."
  (let ((nelisp-ime-learning (make-hash-table :test 'equal)))
    (should (= (nelisp-ime-learning-import '(("かな" "仮名" 4))) 1))
    (should (= (nelisp-ime-learning-count "かな" "仮名") 4))
    (should (= (nelisp-ime-learning-recency "かな" "仮名") 0))
    (should (= (nelisp-ime-learning-import '(("かな" "仮名" 4 9))) 1))
    (should (= (nelisp-ime-learning-recency "かな" "仮名") 9))))

(ert-deftest nelisp-ime-protocol-test-candidates-are-json-arrays ()
  (let ((nelisp-ime-sessions (make-hash-table :test 'equal))
        (nelisp-ime-dictionary '(("はし" "橋" "箸" "端" "嘴")))
        (nelisp-ime-converter-function #'nelisp-ime-dictionary-convert))
    (nelisp-ime-session-open "array")
    (nelisp-ime-feed "array" '(:op :insert :text "はし"))
    (let* ((event (nelisp-ime-protocol--object "op" "convert"))
           (params (nelisp-ime-protocol--object
                    "sessionId" "array" "event" event))
           (response (nelisp-json-parse-string
                      (nelisp-ime-protocol-handle-json
                       (nelisp-ime-protocol-test--request
                        1 "ime/session.feed" params))))
           (result (gethash "result" response))
           (segments (gethash "segments" result)))
      (should (vectorp (gethash "candidates" result)))
      (should (vectorp (gethash "candidates" (aref segments 0)))))))

(provide 'nelisp-ime-protocol-test)
;;; nelisp-ime-protocol-test.el ends here
