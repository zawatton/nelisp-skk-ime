#!/usr/bin/env python3
"""Build a private offline policy cache; never starts an IME/host stack."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ('host-policy.el', 'host-native-skk.el', 'host-native-startup.el')
DIRS = ('lisp', 'src', 'scripts', 'packages/nl-ffi/src', 'packages/nl-prelude/src')


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def literal(value):
    return json.dumps(str(value).replace('\\', '/'), ensure_ascii=False)


def validate_counts(native, total, refused):
    names = [r['name'] for r in refused]
    if native < 1 or native + len(refused) != total or len(set(names)) != len(names):
        raise ValueError('invalid bundle counts or zero native functions')


def self_test():
    validate_counts(1, 2, [dict(name='fixture-refused', error='template refusal')])
    try:
        validate_counts(0, 2, [dict(name=n, error='refused') for n in ('a', 'b')])
    except ValueError:
        pass
    else:
        raise AssertionError('all-refused bundle accepted')
    emacs = shutil.which('emacs')
    if not emacs:
        print('PASS HN bundle counts all-refused rejected; SKIP stub driver: no Emacs')
        return
    with tempfile.TemporaryDirectory(prefix='hn-bundle-self-') as directory:
        work = Path(directory)
        for name in SOURCES:
            (work / name).write_text('', encoding='utf-8')
        driver = work / 'driver.el'
        driver.write_text(driver_source(work, work, {SOURCES[0]: ['fixture-native', 'fixture-refused']}),
                          encoding='utf-8', newline='\n')
        stub = work / 'stub.el'
        stub.write_text("""(provide 'nelisp-native-cache)
(provide 'nelisp-bytecode-native-consumer)
(provide 'nelisp-native-template-stencils)
(defvar nelisp-native-template--library-path load-file-name)
(defun nelisp-native-template-select-target () nil)
(defun fixture-native () 'interpreted)
(defun fixture-refused () 'interpreted)
(defun nelisp-bytecode-native-consumer-read-elc-functions (_) '((fixture-native . fixture-native) (fixture-refused . fixture-refused)))
(defun nelisp-native-cache-compile (f)
  (when (or (getenv "HN_STUB_ALL_REFUSED") (eq f 'fixture-refused))
    (error "Template fixture refusal")))
(defun nelisp-native-cache-load (_) (unless (getenv "HN_STUB_LOAD_FAIL") (lambda () 'native)))
""", encoding='utf-8', newline='\n')
        env = dict(os.environ, HOME=str(work))
        for key in ('HN_STUB_ALL_REFUSED', 'HN_STUB_LOAD_FAIL'):
            env.pop(key, None)

        def run(mode, extra_env=None, assertion=None):
            command = [emacs, '-Q', '--batch', '--init-directory', str(work), '-l', str(stub),
                       '--eval', f'(setq hn-bundle-{mode}-mode t)', '-l', str(driver)]
            if assertion:
                command += ['--eval', assertion]
            return subprocess.run(command, env=dict(env, **(extra_env or {})),
                                  capture_output=True, timeout=20)

        compiled = run('compile')
        assert compiled.returncode == 0, compiled.stderr.decode('utf-8', 'replace')
        assert b'HN-BUNDLE-REFUSED fixture-refused\t' in compiled.stdout
        refusal = re.search(rb'HN-BUNDLE-REFUSED fixture-refused\t([^\r\n]*)', compiled.stdout)[1]
        assert ''.join(chr(int(c)) for c in refusal.split(b',')) == 'Template fixture refusal'
        loaded = run('verify', assertion="(unless (and (eq (fixture-native) 'native) (eq (fixture-refused) 'interpreted) host-policy-native-p) (error \"installation mismatch\"))")
        assert loaded.returncode == 0, loaded.stderr.decode('utf-8', 'replace')
        assert b'HN-BUNDLE-LOADED native=1' in loaded.stdout
        assert run('verify', {'HN_STUB_LOAD_FAIL': '1'}).returncode != 0
        all_refused = run('compile', {'HN_STUB_ALL_REFUSED': '1'})
        assert all_refused.returncode != 0 and b'Zero native functions compiled' in all_refused.stderr
    print('PASS HN bundle self-test partial native/interpreted install; all-refused and fresh-load failure rejected; stacks=0 compiler=stub')


def driver_source(work, src, functions):
    state = work / 'compiled.el'
    setup = ";;; -*- lexical-binding: t; -*-\n"
    setup += '(defvar hn-bundle-compile-mode nil)\n(defvar hn-bundle-verify-mode nil)\n'
    setup += f'(setenv "NELISP_NATIVE_CACHE" {literal(work / "cache")})\n'
    setup += f'(setenv "HN_NELISP_SRC" {literal(src)})\n'
    setup += '(setenv "DDSKK_HOST_POLICY_UNIT_ONLY" "1")\n'
    setup += ''.join(f'(load {literal(work / name)} nil t t)\n' for name in SOURCES)
    setup += """(require 'nelisp-native-cache)
(require 'nelisp-bytecode-native-consumer)
(require 'nelisp-native-template-stencils)
(nelisp-native-template-select-target)
(unless (file-exists-p nelisp-native-template--library-path)
  (setq nelisp-native-template--library-path
        (expand-file-name "templates/nelisp-native-template-win64.nelst" (getenv "HN_NELISP_SRC"))))
(setq nelisp-native-cache-backend 'template)
"""
    setup += "(defvar hn-bundle-compiled nil)\n(defvar hn-bundle-native-count 0)\n"
    setup += f'(unless hn-bundle-compile-mode (load {literal(state)} nil t t))\n'
    for name, names in functions.items():
        setup += f"(let ((functions (nelisp-bytecode-native-consumer-read-elc-functions {literal(work / Path(name).with_suffix('.elc'))})))\n"
        setup += "  (dolist (name '(" + ' '.join(names) + "))\n"
        setup += """    (let ((f (cdr (assq name functions))))
      (unless f (error "Missing bytecode: %S" name))
      (if hn-bundle-compile-mode
          (condition-case err
              (progn (nelisp-native-cache-compile f)
                     (push name hn-bundle-compiled))
            (error (princ (format "HN-BUNDLE-REFUSED %s\\t%s\\n" name
                         (mapconcat #'number-to-string (string-to-list (error-message-string err)) ",")))))
        (when (memq name hn-bundle-compiled)
          (fset name (or (nelisp-native-cache-load f)
                         (error "Missing native callable: %S" name)))
          (setq hn-bundle-native-count (1+ hn-bundle-native-count)))))))
"""
    setup += f"""(if hn-bundle-compile-mode
    (progn
      (unless hn-bundle-compiled (error "Zero native functions compiled"))
      (with-temp-file {literal(state)}
        (prin1 (list 'setq 'hn-bundle-compiled (list 'quote hn-bundle-compiled)) (current-buffer)))
      (princ "HN-BUNDLE-COMPILED\\n"))
  (unless (> hn-bundle-native-count 0) (error "Zero native callables installed"))
  (setq host-policy-native-p t)
  (if hn-bundle-verify-mode
      (princ (format "HN-BUNDLE-LOADED native=%s\\n" hn-bundle-native-count))
    (host-policy-serve)))
"""
    return setup


def build(destination):
    runtime = Path(os.environ['HN_NATIVE_RUNTIME']).resolve(strict=True)
    emacs = Path(shutil.which('emacs') or 'emacs').resolve(strict=True)
    src = Path(os.environ['HN_NELISP_SRC']).resolve(strict=True)
    cold = Path(str(runtime) + '.cold').resolve(strict=True)
    startup = Path(str(runtime) + '.native-startup.el').resolve(strict=True)
    local = Path(os.environ['LOCALAPPDATA']).resolve(strict=True)
    work = Path(destination).resolve()
    if not work.is_relative_to(local):
        raise ValueError('bundle must be a fresh directory under LOCALAPPDATA')
    work.mkdir(parents=True, exist_ok=False)
    (work / 'emacs').mkdir()
    deadline = time.monotonic() + 330
    env = dict(os.environ, NELISP_NATIVE_CACHE=str(work / 'cache'),
               XDG_CONFIG_HOME=str(work), TEMP=str(work), TMP=str(work), TMPDIR=str(work))

    def run(command, environment=env):
        result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True,
                                timeout=max(.01, deadline - time.monotonic()))
        if result.returncode:
            raise RuntimeError((result.stdout + result.stderr).decode('utf-8', 'replace')[-6000:])
        return result.stdout

    functions = {}
    for name in SOURCES:
        path = work / name
        path.write_bytes((ROOT / 'engine' / name).read_bytes())
        functions[name] = [f for f in re.findall(r'^\(defun ([^\s()]+)', path.read_text('utf-8'), re.M)
                           if f != 'host-policy-serve']
    expression = """(progn
      (require 'nelisp-bytecode-compiler-input-dialect)
      (unless (eq (plist-get (nelisp-bytecode-compiler-input-dialect) :status) 'pinned)
        (error "Requires pinned GNU bytecode dialect"))
      (require 'bytecomp)
      %s
      (princ (format "HN-BUNDLE-GNU-LIB %%s\\n" (locate-library "bytecomp")))
      (princ (format "HN-BUNDLE-GNU-LIB %%s\\n" (locate-library "byte-opt")))
      (princ "HN-BUNDLE-DIALECT pinned\\n"))""" % '\n'.join(
          f'(unless (byte-compile-file {literal(work / name)}) (error "Byte compilation failed"))'
          for name in SOURCES)
    output = run([str(emacs), '-Q', '--batch', '--init-directory', str(work), '-L', str(src / 'lisp'),
                  '--eval', expression], dict(env, HOME=str(work), DDSKK_HOST_POLICY_UNIT_ONLY='1'))
    if b'HN-BUNDLE-DIALECT pinned' not in output:
        raise RuntimeError('missing pinned dialect evidence')
    gnu_libraries = [Path(name.rstrip('\r')).resolve(strict=True) for name in re.findall(
        r'^HN-BUNDLE-GNU-LIB (.+)$', output.decode('utf-8', 'strict'), re.M)]
    if len(gnu_libraries) != 2:
        raise RuntimeError('missing GNU byte compiler identity')
    # One immutable filename in compiler and every reader: #$ recipe identity.
    driver = work / 'driver.el'
    state = work / 'compiled.el'
    setup = driver_source(work, src, functions)
    driver.write_text(setup, encoding='utf-8', newline='\n')
    command = [str(runtime), '--cold-load-from', str(cold)]
    load_dirs = [src / d for d in DIRS]
    for directory in load_dirs:
        command += ['-L', str(directory)]
    refused = []
    native_count = 0
    for mode, marker in [('compile', b'HN-BUNDLE-COMPILED'), ('verify', b'HN-BUNDLE-LOADED')]:
        output = run(command + ['--eval', f'(setq hn-bundle-{mode}-mode t)', '-l', str(driver)])
        if marker not in output:
            raise RuntimeError('missing ' + marker.decode())
        if mode == 'compile':
            refused = [dict(name=name, error=''.join(chr(int(c)) for c in error.split(',') if c))
                       for name, error in re.findall(
                r'^HN-BUNDLE-REFUSED ([^\s]+)\t([^\r\n]*)', output.decode('utf-8', 'strict'), re.M)]
        else:
            native_count = int(re.search(rb'HN-BUNDLE-LOADED native=(\d+)', output)[1])
    total = sum(map(len, functions.values()))
    validate_counts(native_count, total, refused)
    summary = f"HN-BUNDLE native={native_count} interpreted={len(refused)} refused=" + (
        ','.join(r['name'] for r in refused) or '-')
    report = work / 'bundle-report.txt'
    report.write_text(summary + '\n' + json.dumps(refused, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    pins = [('R', runtime), ('C', cold), ('S', startup), ('D', driver), ('B', report), ('H', state)]
    pins += [('H', ROOT / 'engine' / name) for name in SOURCES]
    pins += [('H', work / name) for name in SOURCES]
    pins += [('H', (work / name).with_suffix('.elc')) for name in SOURCES]
    pins += [('H', emacs), ('H', src / 'templates/nelisp-native-template-win64.nelst')]
    pins += [('H', path) for path in gnu_libraries]
    pins += [('H', p) for p in sorted((src / 'lisp').rglob('nelisp*')) if p.is_file()]
    manifest = dict(version=1, dialect='pinned', backend='template', generation=work.name,
                    gnu_emacs_version=run([str(emacs), '--version']).decode('utf-8', 'replace').splitlines()[0],
                    native_count=native_count, interpreted_count=len(refused), refused=refused,
                    cache=str(work / 'cache'), load_dirs=list(map(str, load_dirs)), functions=functions,
                    pins=[dict(role=r, path=str(p), sha256=digest(p)) for r, p in pins])
    meta = work / 'manifest.json'
    meta.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8', newline='\n')
    pins.append(('H', meta))
    rows = ['HN-BUNDLE-1'] + [f'{r}\t{digest(p)}\t{p}' for r, p in pins]
    rows += [f'L\t-\t{p}' for p in load_dirs]
    if any('\n' in str(p) or '\t' in str(p) or '"' in str(p) for _, p in pins):
        raise ValueError('unsafe manifest path')
    (work / 'manifest.tsv').write_text('\n'.join(rows) + '\n', encoding='utf-8', newline='\n')
    print(summary)
    print('PASS HN bundle ' + json.dumps(dict(bundle=str(work), functions=sum(map(len, functions.values())),
                                             generation=work.name, dialect='pinned', fresh_load=True, refused=refused)))
    return work


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', help='fresh directory under LOCALAPPDATA')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        raise SystemExit(0)
    try:
        build(args.output or str(Path(os.environ['LOCALAPPDATA']) / ('hn-policy-' + uuid.uuid4().hex)))
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print('FAIL HN bundle: ' + str(error))
        raise SystemExit(1)
