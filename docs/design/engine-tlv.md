# Engine reply TLV (stage S4.1)

Status: spec v1. Reference implementation: `windows/src/engine_tlv.h` (C++, portable),
`windows/native/ddskk-tlv.el` (restricted-Elisp decoder for the native TSF DLL).
Golden vectors: `windows/test/golden/tlv/*.bin` (+ `.hex`, `.dump`).

Scope: only the DLL <-> host named pipe (`\\.\pipe\ddskk-ime-v1`). The host <-> NeLisp
engine stdio link stays text. The text protocol is unchanged and remains the default.

## Negotiation

TLV is opt-in per pipe connection. The client sends the text request `HELLO TLV 1`.
- A TLV-capable host answers the text line `OK TLV 1` and from the next reply on
  sends every reply as TLV (including the reply to `SHUTDOWN`).
- A host without TLV forwards the unknown request to the engine and answers with some
  other text (`ERR ...`, `STATE ...`). The client treats anything but exactly `OK TLV 1`
  as "no TLV" and keeps using text. No state is changed by a refused HELLO.
- Requests stay text in both modes. One pipe message = one reply (message mode).

## Framing

All integers are little-endian. One TLV message is exactly one pipe message.

| offset | size | field |
|---|---|---|
| 0 | 4 | magic `DSTV` (44 53 54 56) |
| 4 | 4 | total: byte length of the whole message, header included |
| 8 | 1 | version (1) |
| 9 | 1 | kind: 1 = STATE, 2 = RAW |
| 10 | 2 | flags (0; ignored by v1 readers) |
| 12 | ... | records |

Record: `tag u16`, `len u32` (value bytes), `value`. Records follow back to back; the last
one ends exactly at `total`. Strings are UTF-16LE without terminator (surrogate pairs
kept as units; offsets in `CURSOR`/`COMP_START` are UTF-16 units, as in the text STATE).
`i32` is two's complement.

## Tags

| tag | name | type | text STATE field | notes |
|---|---|---|---|---|
| 0x0001 | MODE | utf16 | `<mode>` (field 1) | required |
| 0x0002 | CURSOR | i32 | `<cursor>` | required |
| 0x0003 | COMP_START | i32 | `<comp_start>` | required, -1 = none |
| 0x0004 | TEXT | utf16 | `<text-hex>` | absent = empty |
| 0x0005 | PENDING | utf16 | `<pending-hex>` | pending romaji; absent = empty |
| 0x0006 | CAND_INDEX | i32 | `<cand_idx>` | required, -1 = none |
| 0x0007 | CANDIDATE | utf16 | `<cands,>` | repeatable, in order, max 512 |
| 0x0008 | REG_READING | utf16 | 9th field of `STATE registration` | presence marks the nine-field form (may be empty) |
| 0x0009 | SEQUENCE | u32 | (none) | optional per-connection reply counter; v1 host does not emit it |
| 0x0020 | RAW_LINE | utf8 | any non-STATE reply | kind 2, required |

Kind 2 (RAW) carries `OK`/`ERR`/`ENGINES`/... lines verbatim, without the trailing newline,
so the DLL never parses text. A STATE line the host cannot parse, or that exceeds a limit,
is sent as RAW as well.

Reserved for later versions (v1 readers skip them, v1 hosts do not emit them): 0x0010
SEGMENT (i32 start, i32 end, u32 attr; repeatable), 0x0011 ACTIVE_SEGMENT (i32), 0x0012 OPEN
(u8), 0x0013 COMMIT_TEXT (utf16), 0x0014 STATUS (u32), 0x0015 ERROR_TEXT (utf8), 0x0016
NEEDS_RESYNC (u8). The current text STATE has no segment, commit, status or resync fields:
needs-resync stays a client-side condition (timeout/pipe error), as today.

## Rules

- Decoder must reject: bad magic; `total` != received bytes; version 0 or > 1; kind not 1/2;
  a record header or value running past `total`; fixed-width tag with wrong `len`
  (4 for the i32/u32 tags); odd length for a utf16 tag; missing required tag; any limit
  below exceeded. Rejection is a hard failure (client treats it like a pipe error and
  resyncs with `RESET`); never partial state.
- Unknown tags (any value not in the table, incl. reserved) are skipped using `len`.
  Unknown flag bits are ignored. A newer minor addition is a new tag; an incompatible
  change bumps `version`.
- A repeated singular tag: last one wins. Candidate order = record order.
- Limits: total <= 65536; one string value <= 16384 bytes; candidates <= 512. The encoder
  fails (host falls back to RAW `ERR tlv-reply-too-large`) instead of truncating. Clients
  must read with a buffer of at least 65536 bytes (the text client uses 8192).
- UTF-16 well-formedness (lone surrogates) is not validated by the wire layer.

## Examples

`state_preedit.hex`: mode=`preedit`, cursor 1, comp_start 0, text `あ`, pending `k`.
The canonical one-line field dump (`*.dump`) is produced by `ddskk::tlv::Dump` and by the
Elisp test client; both must agree byte for byte.

## Tests

- `windows/test/engine_tlv_test.cpp` (g++ -std=c++17 -Wall -Wextra -Werror): round trip,
  golden bytes, unknown-tag skipping, every truncation, corrupted fields, limits.
- `windows/native/test/tlv-e2e.sh` (wine): Elisp decoder vs the same goldens, negative
  controls, named-pipe session against `tlv-stub-host.exe`.
