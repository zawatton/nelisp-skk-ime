;;; test-server-reader.el --- Host list reader oracle -*- lexical-binding: t; -*-
(let ((ddskk-engine--utf8-wire t))
  (unless
      (equal
       (ddskk-engine--parse-server-reply
        "LIST (\" /;😀\" \"quote\\\"slash\\\\\" \"\\000\\011\\012\\015\\177\")")
       '(" /;😀" "quote\"slash\\"))
    (error "Host LIST reader character parity"))
  (dolist (reply '("LIST nil" "LIST ()" "LIST (4)" "LIST broken" "LIST ("))
    (when (ddskk-engine--parse-server-reply reply)
      (error "Host LIST malformed/empty parity"))))
(nelisp--write-stdout-bytes "Host LIST reader: 6 checks PASS\n")
