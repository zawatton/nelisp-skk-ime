"""Extract auditable source anchors, inputs, error literals and deadline sites."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
sources = []
for directory in ('windows/host', 'windows/src', 'windows/keymap', 'sumi-ui',
                  'emacs', 'framework/src', 'engine', 'windows/test-host'):
    for p in sorted((ROOT / directory).rglob('*')):
        if p.suffix in ('.cpp', '.h', '.c', '.el', '.ps1', '.py') and p.name not in (
                'inventory-host-contracts.py', 'host-contracts.py'):
            sources.append(p)
inputs, errors, deadlines, commands, hashes = [], [], [], [], {}
for p in sources:
    data = p.read_bytes()
    name = p.relative_to(ROOT).as_posix()
    hashes[name] = hashlib.sha256(data).hexdigest()
    for n, line in enumerate(data.decode('utf-8-sig', errors='replace').splitlines(), 1):
        anchor = f'{name}:{n}'
        for token in re.findall(r'\b(?:DDSKK|NATIVEIME|NELISP_IME)_[A-Z0-9_]+\b', line):
            inputs.append(dict(name=token, source=anchor, declaration=line.strip()))
        if re.search(r'Reg(Query|Get|Open)|registry_name|DwordBridge', line):
            inputs.append(dict(kind='registry', source=anchor, declaration=line.strip()))
        for token in re.findall(r'"(ERR [^"\n]*)"', line):
            errors.append(dict(token=token, source=anchor))
        if re.search(r'timeout|Timeout|deadline|Deadline|CancelIo|WaitForSingleObject|WaitForExit|\.Wait\(|\.Connect\(|CallNamedPipe|WaitNamedPipe|accept-process-output|kInteractiveTimeout|kConversionTimeout|kModeReplayTimeout', line):
            deadlines.append(dict(source=anchor, declaration=line.strip()))
        if p.parent.name == 'host' or p.name in ('ddskk-engine.el', 'skk-local-conversion.el', 'nelisp-ime-stateline.el'):
            for token in re.findall(r'"((?:CONTROL|LOCAL|ENGINE|WIRE|SESSION|PREVIEW|ROMAJI|HELLO|DIAG|KEY|REGISTER|STATE|LEARNING|PHASE|SERVER|OK)[^"\n]*)"', line):
                commands.append(dict(literal=token, source=anchor))
output = dict(version=1, source_sha256=hashes, inputs=inputs, error_tokens=errors,
              command_literals=commands, caller_deadline_sites=deadlines,
              note='Sites include declarations and test callers. Semantic caller summary is deadlines-v1.json; unbounded sites remain explicit.')
path = ROOT / 'docs/contracts/source-inventory-v1.json'
path.write_text(json.dumps(output, indent=2, ensure_ascii=True) + '\n', encoding='utf-8')
print(f'PASS inventory sources={len(hashes)} inputs={len(inputs)} errors={len(errors)} deadlines={len(deadlines)} commands={len(commands)}')
