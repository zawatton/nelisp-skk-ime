;;; test-conversion-round2.el --- Private protocol/replay test entry point
(load "engine/ddskk-engine.el" nil t)
(load "engine/test-server-reader.el" nil t)
(load "engine/test-replay-equivalence.el" nil t)
(dolist (symbol '(gc-stats nelisp--arena-stats nelisp--debug-switch
                 nl-unix-time-usec nelisp-native-load--raw-symbol-addr))
  (nelisp--write-stdout-bytes
   (concat "Profile capability " (symbol-name symbol) "="
           (if (fboundp symbol) "available" "unavailable") "\n")))
