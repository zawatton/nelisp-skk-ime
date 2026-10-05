;;; bench-wire.el --- Private live-runtime wire microbenchmark -*- lexical-binding: t; -*-
(load (expand-file-name "engine/ddskk-engine.el" (getenv "DDSKK_BENCH_ROOT")) nil t)
(let* ((state '(:mode candidate :cursor 4 :composition-start 0
               :text "かな /;😀" :pending-romaji "" :candidate-index 0
               :candidates ("仮名 /;😀" "かな" "加奈" "カナ")))
       (keys "75,97,110,97")
       (iterations 100))
  (dolist (kind '(legacy-reply cached-reply utf8-reply decimal-request utf8-request))
    (nelisp--write-stdout-bytes (concat "READY " (symbol-name kind) "\n"))
    (read-stdin-bytes 8192)
    (dotimes (i iterations)
      (cond
       ((eq kind 'legacy-reply)
        ;; Measure character encoding rather than cached identical content.
        (clrhash ddskk-engine--hex-cache)
        (let ((ddskk-engine--utf8-wire nil)) (ddskk-engine--raw-state-line state)))
       ((eq kind 'utf8-reply)
        (let ((ddskk-engine--utf8-wire t)) (ddskk-engine--raw-state-line state)))
       ((eq kind 'cached-reply)
        (let ((ddskk-engine--utf8-wire nil)) (ddskk-engine--raw-state-line state)))
       ((eq kind 'decimal-request) (ddskk-engine--decode-codepoints keys))
       ((eq kind 'utf8-request)
        (let ((ddskk-engine--utf8-wire t))
          (ddskk-engine--request-keys "CONTROL CONVERT-UTF8 Kana" 21)))))
    (nelisp--write-stdout-bytes (concat "DONE " (symbol-name kind) "\n")))
  ;; Keep the process blocked while the caller obtains its final CPU delta.
  (read-stdin-bytes 8192))
