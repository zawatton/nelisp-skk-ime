"""Prepare disposable HP1 compiler inputs; never writes to the runtime checkout.

Compile the generated compile.el with host Emacs and the runtime's compiler
source directories on -L. Execute outputs only with the exact Windows image.
"""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FOOTER = '(unless (getenv "DDSKK_HOST_POLICY_UNIT_ONLY") (host-policy-serve))'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-directory', type=Path, required=True)
    args = parser.parse_args()
    destination = args.output_directory.resolve()
    assert destination.is_relative_to(ROOT/'build'), 'disposable artifacts must stay under build'
    destination.mkdir(parents=True, exist_ok=True)
    source = (ROOT/'engine/host-policy.el').read_text('utf-8')
    assert source.count(FOOTER) == 1, 'policy entry changed; review the prototype'
    prefix = ';;; -*- lexical-binding: t; -*-\n(nelisp--debug-switch 24)\n'
    (destination/'policy-bytecode.el').write_text(prefix+source, encoding='utf-8')
    # .neln installs native dispatch after module initialization. Call serve
    # as the CLI FORM afterwards, so the prototype cannot bypass installation.
    (destination/'policy-native.el').write_text(prefix+source.replace(FOOTER, ''), encoding='utf-8')
    (destination/'compiled-smoke.el').write_text(
        ';;; -*- lexical-binding: t; -*-\n(defun s6-compiled-smoke (x) (+ x 1))\n', encoding='utf-8')
    driver = ''';;; -*- lexical-binding: t; -*-
(let ((default-directory (file-name-directory load-file-name)))
  (byte-compile-file "compiled-smoke.el")
  (require 'nelisp-artifact)
  (dolist (name '("compiled-smoke" "policy-bytecode"))
    (nelisp-artifact-compile-file (concat name ".el") (concat name ".nelc")
                                 nil "x86_64-w64-mingw32"))
  (dolist (name '("compiled-smoke" "policy-native"))
    (nelisp-artifact-compile-file (concat name ".el") (concat name ".neln")
                                 nil "x86_64-w64-mingw32" nil nil nil 'neln 'required)))
'''
    (destination/'compile.el').write_text(driver, encoding='utf-8')
    print('PREPARED compiler inputs (not executed):', destination)


if __name__ == '__main__':
    main()
