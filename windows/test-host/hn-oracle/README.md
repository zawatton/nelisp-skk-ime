# HN2 C++ oracle

Run from the repository root:

```
python tools/ai/check-hn-oracle.py
```

The test-only CMake target `hn-oracle` compiles exact current function bodies
extracted from `windows/host/main.cpp`. It does not copy implementations into
maintained test code or change production files. This follows the existing
production-source extraction tests. Extraction fails if functions/calls vanish;
CMake regenerates the include whenever production source changes.

Startup Win32 calls use only an in-memory snapshot. Registry type/buffer-size
behavior follows `RegQueryValueExW`: a null type argument does not reject types.
Environment strings are UTF-16LE, and the current `StartChild` environment block
construction is extracted unchanged inside a test wrapper. The harness never
calls `StartChild`, accesses a registry key, runs a policy child, or opens a
dictionary other than the explicitly supplied public synthetic fixture.

`oracle.jsonl` stores input/output byte strings as hex. `parsed.bin` stores the
parsed map sorted by key, using uint32 little-endian lengths followed by key and
tail bytes. The production built-in parser creates no serialized index; these
records freeze its map bytes, not a local-index publication. Raw parser and
file-loader cases distinguish BOM handling. The only CRLF bytes are intentional
synthetic dictionary inputs, stored as binary test data.

Five decision groups cover current Sources/Order, CacheTtl/Capacity plus the
Cache expiry observation, Restart/Replacement, Intent/Payload and Learning.
Config is also captured. The legacy numeric Publication kind has no production
call site; current publication fallback answers are Intent/Payload. Expressions
come directly from each current native fallback argument. Input setup supplies
the corresponding native local variables; it does not invoke managed policies.
TTL, replacement eligibility and publication `due` initializers are also
extracted from production. Intent uses the actual native PublicationWindow with
fixed snapshot timestamps, including its 200 ms boundary.

The manifest hashes the synthetic input and both outputs, with the production
source hash retained as capture provenance (not a pin on unrelated host edits).
Normal checking never refreshes fixtures. For an intentional reviewed recapture,
run `python tools/ai/check-hn-oracle.py --freeze` and review the resulting bytes.
The checker runs the same comparison in child processes against a temporary
one-byte-corrupted golden, first with its original hash, then with an updated
hash. Both must exit 1. Only the private oracle executable and comparator children
are run; no live IME, host, registry or user dictionaries are involved.

HN3 transport contracts and real host/engine/TSF replay remain separate gates.
