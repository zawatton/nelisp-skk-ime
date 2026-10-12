"""Compile exact current host function bodies, with snapshot-only OS inputs."""
from pathlib import Path
import re
import sys


def function(source, name):
    match = re.search(r"(?m)^(?:bool|void|std::(?:w?string)) " + name + r"\(", source)
    if not match:
        raise ValueError(f"production function missing: {name}")
    end = source.index("\n}", match.start()) + 2
    return source[match.start():end]


def arguments(source, kind, operation="Decide"):
    marker = f"native_adapter::{operation}(native_adapter::PolicyKind::{kind},"
    results = []
    offset = 0
    while (start := source.find(marker, offset)) != -1:
        start += len(marker)
        depth, quoted, escaped = 0, False, False
        parts, last = [], start
        for i in range(start, len(source)):
            ch = source[i]
            if quoted:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    quoted = False
                continue
            if ch == '"':
                quoted = True
            elif ch in "({[":
                depth += 1
            elif ch in ")}]":
                if depth == 0:
                    parts.append(source[last:i].strip())
                    offset = i + 1
                    break
                depth -= 1
            elif ch == "," and depth == 0:
                parts.append(source[last:i].strip())
                last = i + 1
        else:
            raise ValueError(f"unterminated call: {kind}")
        if len(parts) < 4:
            raise ValueError(f"missing fallback: {kind}")
        results.append(parts[3])
    if not results:
        raise ValueError(f"production decision missing: {kind}")
    return results


def main():
    source = Path(sys.argv[1]).read_text(encoding="utf-8")
    names = ("UseNativeEntry", "ConfiguredEngineId", "IsDdskkEngineId",
             "FileExists", "EngineRunnerScript", "ApplyEngineEnvFromRegistry",
             "StripDictionaryLineBreaks", "ParseSkkJisyo", "LoadDictionaryFile",
             "MergeBuiltinCandidates", "MergeServerReply", "QuoteEngineString",
             "EngineDictionaryReply")
    bodies = [function(source, name) for name in names]
    begin = source.index("  std::vector<std::wstring> entries;", source.index("bool StartChild("))
    end = source.index("  const BOOL started =", begin)
    bodies.append("std::vector<wchar_t> ChildEnvironment(const std::wstring& id) {\n"
                  "  std::vector<wchar_t> output; const auto build = [&]() -> bool {\n"
                  "  HANDLE stdin_read=nullptr, stdin_write=nullptr, stdout_read=nullptr, stdout_write=nullptr;\n"
                  + source[begin:end] + "  output=environment; return true; }; if (!build()) throw std::runtime_error(\"environment unavailable\"); return output;\n}")
    def declaration(name):
        matches = re.findall(r"(?m)^\s*(const (?:auto|bool) " + name + r"\s*=.*?;)", source, re.S)
        if len(matches) != 1:
            raise ValueError(f"ambiguous native initializer: {name}")
        return matches[0]

    # Locals reproduce call-site input snapshots, never policy algorithms.
    setups = {
        "Sources": "struct { bool enabled; std::wstring dictionary_files; } config{a != 0, b ? L\"synthetic\" : L\"\"};",
        "CacheTtl": "const bool hit=a != 0;",
        "Cache": "const bool hit=a != 0; const auto age=b; " + declaration("native_ttl"),
        "Capacity": "std::vector<int> cache_(static_cast<size_t>(a)); auto victim=b ? cache_.begin() : cache_.end();",
        "Order": "const std::string files=a ? \"/synthetic/\" : \"\";",
        "Restart": "const DWORD backoff=static_cast<DWORD>(a);",
        "Replacement": "std::vector<int> g_composing_sessions(b ? 1 : 0); const ULONGLONG deadline=c ? 0 : 1; snapshot::tick=0; " + declaration("swap_due"),
        "Learning": "const bool ready=a != 0;",
        "Intent": "const bool have_rules=a != 0, have_status=a != 0; ddskk::local::PublicationWindow window; window.Published(\"same\",\"base\"); window.Changed(0); const std::string identity=b ? \"changed\" : \"same\", previous=\"same\", published_base=\"base\", base_identity=c==1 ? \"new-base\" : \"base\"; snapshot::tick=c==2 ? 200 : 0; " + declaration("due_at"),
        "Payload": "const bool have_rules=a != 0, have_status=a != 0, immediate=b != 0; const std::string identity=c ? \"changed\" : \"same\", previous=\"same\";",
        "Config": "snapshot::framework=b != 0; const std::wstring id=a ? L\"synthetic\" : L\"ddskk\", repository=L\"fixture\";",
    }
    for kind, setup in setups.items():
        observation = kind in ("Cache", "Config")
        expressions = arguments(source, kind, "Observe" if observation else "Decide")
        expected = 2 if kind == "Restart" else 1
        if len(expressions) != expected:
            raise ValueError(f"production call count changed: {kind}: expected {expected}, got {len(expressions)}")
        for i, expression in enumerate(expressions):
            if not observation:
                if not expression.startswith("[&]"):
                    raise ValueError(f"production lazy fallback missing: {kind}")
                expression = f"({expression})()"
            bodies.append(f"uint64_t Fallback{kind}{i}(uint64_t a,uint64_t b,uint64_t c) {{ {setup} return {expression}; }}")
    output = Path(sys.argv[2])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("// Generated from current production; do not edit.\n" + "\n\n".join(bodies) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
