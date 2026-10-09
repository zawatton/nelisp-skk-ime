"""Pure source checks: no runtime, host, subprocess, socket or registry access."""
import argparse
import ast
import json
from pathlib import Path


def forms(source):
    """Read the policy's list/string/comment syntax, including generated probes."""
    root, stack = [], []
    current = root
    i = 0
    while i < len(source):
        char = source[i]
        if char.isspace(): i += 1; continue
        if char == ';':
            end = source.find('\n', i)
            i = len(source) if end < 0 else end+1
            continue
        if char == '(':
            child = []
            current.append(child)
            stack.append(current)
            current = child
            i += 1
        elif char == ')':
            assert stack, 'unexpected closing parenthesis'
            current = stack.pop()
            i += 1
        elif char == '"':
            start = i
            i += 1
            while i < len(source) and source[i] != '"':
                i += 2 if source[i] == '\\' else 1
            assert i < len(source), 'unterminated string'
            i += 1
            current.append(source[start:i])
        else:
            start = i
            while i < len(source) and not source[i].isspace() and source[i] not in '();"': i += 1
            assert i > start, 'unexpected character'
            current.append(source[start:i])
    assert not stack, 'unclosed list'
    return root


def calls(tree):
    if isinstance(tree, list):
        if tree and isinstance(tree[0], str): yield tree[0]
        for child in tree: yield from calls(child)


def check(source):
    tree = forms(source)
    functions = {form[1]: form for form in tree if isinstance(form, list) and form and form[0] == 'defun'}
    allocators = {'concat', 'substring', 'make-string', 'make-vector', 'cons',
                  'list', 'split-string', 'mapconcat', 'format', 'number-to-string'}
    counts = {}
    for name in ('host-policy-frame-into', 'host-policy-serve', 'host-policy-write-reply'):
        found = list(calls(functions[name][3:]))
        counts[name] = {key: found.count(key) for key in sorted(allocators) if key in found}
    assert counts['host-policy-frame-into'] == {'make-string': 1}, counts
    assert counts['host-policy-serve'] == {'make-string': 2, 'make-vector': 2}, counts
    assert counts['host-policy-write-reply'] == {'number-to-string': 1, 'substring': 1}, counts
    assert 'host-policy-frame' not in list(calls(functions['host-policy-serve'])), 'allocating compatibility parser on hot path'
    assert list(calls(functions['host-policy-frame-into'])).count('string-to-number') == 1
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[2]/'engine/host-policy.el')
    args = parser.parse_args()
    source = args.source.read_text('utf-8')
    counts = check(source)
    # Negative controls: balanced but forbidden allocation, and broken syntax.
    controls = [source.replace('(setq used 0)', '(setq used 0) (concat "bad" "allocation")'), source+')']
    for bad in controls:
        try: check(bad)
        except AssertionError: pass
        else: raise AssertionError('negative allocation/syntax control accepted')
    # Compile only the generator function and TRACE assignment, never import
    # the runtime runner (which owns subprocess/Win32 transport capabilities).
    generator = Path(__file__).with_name('diagnose-policy-ipc.py')
    parsed = ast.parse(generator.read_text('utf-8'))
    selected = [node for node in parsed.body
                if (isinstance(node, ast.FunctionDef) and node.name == 'source') or
                (isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == 'TRACE' for target in node.targets))]
    namespace = {'ROOT': Path(__file__).resolve().parents[2]}
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(generator), 'exec'), namespace)
    for mode in ('stream', 'framing', 'policy', 'allocation', 'echo', 'parse',
                 'match', 'split', 'validate', 'cond', 'format', 'timed-echo'):
        forms(namespace['source'](mode))
    print('PASS policy static allocation sites '+json.dumps(counts, sort_keys=True))
    print('PASS controls=2; reusable_storage=4; decimal_cache_miss_site=1; exact_reply_slice=1')
    print('PASS generated Lisp syntax modes=12; generator AST only; runtime processes=0')
    print('STATIC ONLY: interpreter binding/number/read-buffer allocations and GC tails require exact-runtime measurement')


if __name__ == '__main__': main()
