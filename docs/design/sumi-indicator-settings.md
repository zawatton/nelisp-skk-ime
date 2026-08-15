# Sumi mode indicator and settings UI

Status: DRAFT (Phase 1 in progress)
Requested: 2026-08-15 — "CorvusSKK のようにインジケータへ現在の入力モードの
状態の表示兼設定を変更出来るものが欲しい。UI は Sumi で作成して。設定の内容も
CorvusSKK を倣って。"

## Goal

A CorvusSKK-style companion UI for this IME, built on the Sumi renderer
(`dev/sumi`, cairo-elisp AOT + GTK4):

1. **Mode indicator** — a small always-visible window showing the current
   input mode (color + label), which can also *switch* the mode and launch
   the settings window.
2. **Settings window** — CorvusSKK-modeled configuration pages backed by
   the IME's existing registry store (`HKCU\Software\NativeIME`).

## Background: CorvusSKK behavior (researched 2026-08-15)

Key findings from the corvusskk sources (imcrvcnf/imcrvtip):

- Config tool is a flat 15-tab property sheet; settings live in
  `%APPDATA%\CorvusSKK\config.xml`; **changes apply only when the IME is
  toggled off/on** (`_KeyboardOpenCloseChanged()` reloads everything).
- Tray icon: 6 mode states (OFF / ひらがな / カタカナ / 半角ｶﾅ / 全英 /
  ASCII) × normal/private variants. Left click toggles IME; right click
  shows a menu with radio-checked mode items (［かな］［カナ］［－ｶﾅ］
  ［全英］［SKK］［－－］), CAPS/KANA lock toggles, private-mode toggle,
  and 設定 (launches the config tool).
- Caret popup: a small square in the mode's color with the mode icon,
  auto-hides after a configurable timeout (default 3000 ms).

This IME already implements the caret popup (mode_indicator.cpp) with
per-mode colors. The new work is the persistent indicator + settings UI.

## Architecture

```
+------------------+   \\.\pipe\ddskk-ime-v1    +--------------+
| sumi-skk-ui.exe  | <------------------------> | engine host  |
| (GTK4, cairo-    |   STATUS (read mode)       |  + NeLisp    |
|  elisp AOT)      |   KEY/CONTROL (set mode)   |    engine    |
+------------------+                            +--------------+
        |  read/write
        v
 HKCU\Software\NativeIME   <-- read by ddskk-ime.dll at Activate()
```

- The engine session is shared by all clients, so the UI app can both
  observe and drive the input mode over the same pipe the TSF DLL uses.
- Settings writes go to the registry. Like CorvusSKK, they take effect
  when the DLL next runs `LoadSettings()` (IME off/on or app focus
  change). The settings window states this explicitly.

### New engine verb: `STATUS`

`STATUS\n` returns the same `STATE ...` line as a key event **without
mutating the session**. Needed because the wire protocol currently has
only mutating verbs; the indicator must not fabricate keystrokes to learn
the mode. The host treats it like any other request (its STATE reply also
feeds the host's composing tracker, which is accurate).

### Mode switching from the indicator

| Menu item | Wire action                                   |
|-----------|-----------------------------------------------|
| かな      | `CONTROL CANCEL` (same as Ctrl+J)             |
| カタカナ  | `CONTROL CANCEL` then `KEY 113` (`q`)         |
| 全英      | `CONTROL CANCEL` then `KEY 76` (`L`)          |
| SKK/ASCII | `CONTROL CANCEL` then `KEY 108` (`l`)         |

Only offered while the engine reports no active composition (mode is not
preedit/candidate) — same guard ToggleInputMode() uses in the DLL. The
TSF DLL's cached `kana_mode_` refreshes on its next key event; the DLL
derives it from every STATE it receives, so an externally driven switch
converges on the first keystroke.

## Settings schema (CorvusSKK tab → NativeIME registry)

Only settings the engine/DLL actually honors are shown in the UI. Items
CorvusSKK has but this IME does not yet support are listed as future
work, not rendered as dead controls.

### Tab 動作 (behavior)

| Setting                        | Registry value                | Type  | Default | CorvusSKK analog |
|--------------------------------|--------------------------------|-------|---------|------------------|
| エンジン                       | `Engine`                       | SZ    | ddskk   | —                |
| 初期入力モード                 | `InitialKanaMode`              | DWORD | 1       | ValueDefaultMode |
| 送り仮名が一致した候補を優先する | `BehaviorOkuriStrictly`        | DWORD | 0       | ValuePrecedeOkuri |
| 取消のとき送り仮名を削除する   | `BehaviorDeleteOkuriOnCancel`  | DWORD | 0       | ValueDelOkuriCncl |
| 候補に片仮名変換を追加する     | `BehaviorAddKatakanaCand`      | DWORD | 0       | ValueAddCandKtkn |
| プライベートモード (学習しない) | `BehaviorLearnDisabled`        | DWORD | 0       | private mode     |

### Tab 表示 (display)

| Setting                    | Registry value       | Type  | Default  | CorvusSKK analog   |
|----------------------------|----------------------|-------|----------|--------------------|
| 入力モードを表示する       | `ModeIndicator`      | DWORD | 1        | ValueShowModeInl   |
| 表示時間 (ms)              | `ModeIndicatorMs`    | DWORD | 3000     | ValueShowModeInlTm |
| 表示倍率 (%)               | `ModeIndicatorScale` | DWORD | 100      | —                  |
| かな色                     | `ModeColorKana`      | DWORD | C02020   | ValueColorHR       |
| カナ色                     | `ModeColorKatakana`  | DWORD | 00C000   | ValueColorKT       |
| 全英色                     | `ModeColorWideLatin` | DWORD | 8000C0   | ValueColorJL       |
| SKK(英数)色                | `ModeColorLatin`     | DWORD | 1E5AA8   | ValueColorAC       |
| Abbrev色                   | `ModeColorAbbrev`    | DWORD | —        | —                  |

### Tab 辞書 (dictionary)

| Setting                       | Registry value              | Type  | Default   | CorvusSKK analog   |
|--------------------------------|-----------------------------|-------|-----------|--------------------|
| 辞書サーバを使用する          | `SkkServEnable`              | DWORD | 1         | ValueServerServ    |
| ホスト                        | `SkkServHost`                | SZ    | 127.0.0.1 | ValueServerHost    |
| ポート                        | `SkkServPort`                | DWORD | 1179      | ValueServerPort    |
| 辞書サーバ起動コマンド        | `SkkServStartCommand` (new)  | SZ    | (empty)   | —                  |
| 内蔵辞書ファイル (`;`区切り)  | `DictionaryFiles` (new)      | SZ    | (empty)   | —                  |
| ユーザー辞書パス              | `UserJisyoPath` (new)        | SZ    | %LOCALAPPDATA%\DDSKK\user-jisyo.utf8 | — |
| 保存間隔 (確定数)             | `UserJisyoBatch` (new)       | DWORD | 10        | —                  |

(`UserJisyoPath`/`UserJisyoBatch` require the host to export the values
as `DDSKK_USER_JISYO` / `DDSKK_USER_JISYO_SAVE_BATCH_SIZE` when spawning
the engine — a small host change bundled with Phase 3.)

`SkkServStartCommand` lets the host self-heal a dead external dictionary
server: on a failed connection attempt it spawns this command line
(`CreateProcessW`, no shell interpretation, rate-limited to once per 30s)
and retries once — field incident: the external skkserv (an Emacs daemon
owned by the user's own session) died twice after a re-logon and was not
restarted by the user's startup hooks, so every conversion returned
nothing and compositions never closed.

`DictionaryFiles` answers a follow-up user question directly —
「辞書サーバー無しで変換出来ないのでしょうか？」 — by moving the
dictionary itself into the host: one or more local SKK-JISYO format files
(UTF-8, `;`-separated absolute paths, priority order), loaded on a
background thread at host startup. `LookupDictionary()` merges candidates
from every configured file (SKK semantics: union across files in
first-occurrence order, not first-file-wins) *before* ever touching the
external server, so conversion works with no dictionary server running at
all; the external server, if still configured, only fills in words none
of the local files have. The engine's own NeLisp heap deliberately does
not hold this data — its semispace GC copies all live data on every
collection, and a multi-MB dictionary there would push GC pauses into the
seconds — so this lives in the host process instead.

Both new values, like `UserJisyoPath`/`UserJisyoBatch`, are bridged to
the engine host's own environment with env-wins-over-registry precedence
(`DDSKK_SKKSERV_START_COMMAND`, `DDSKK_DICTIONARY_FILES`), mainly so a
test harness can exercise them without a registry write. The host also
honors `DDSKK_SKKSERV_HOST`/`DDSKK_SKKSERV_PORT` env overrides for the
same testability reason (pointing the external-server probe at a
deliberately unreachable target); these two have no registry-writable UI
of their own to layer onto.

### Tab 調整 (maintenance — no CorvusSKK analog)

| Setting                  | Registry value | Type  | Default |
|--------------------------|----------------|-------|---------|
| アイドルGC間隔 (ms)      | `IdleGcMs`     | DWORD | 800     |
| デバッグログ             | `DllDebug`     | DWORD | 0       |

### Future work (CorvusSKK features without engine support yet)

Completion (動作2), candidate-window fonts/colors/paging (表示1), display
attributes (▽表示/▼表示), selection keys, key maps, conversion-point and
kana tables, and a proper dictionary-file list editor (v1 exposes
`DictionaryFiles` as a single hand-edited `;`-separated registry string,
not an add/remove/reorder list control — the underlying host-side
multi-file merge lookup itself is already implemented, see the 辞書 tab
above). Each of the others needs engine-side support first; the schema
above deliberately stays honest about what works today.

## UI design (Sumi)

One executable, `sumi-skk-ui.exe`, two window states:

1. **Indicator** (default): a compact strip — mode swatch (color square) +
   label (あ / ア / Ａ / SKK). Click → mode menu (list rendered in the
   same window); gear glyph → settings state. Refresh: `STATUS` poll every
   500 ms while visible; pipe reconnect with backoff when the host is
   down (shows ―― like CorvusSKK's Default/OFF state).
2. **Settings**: tab strip (動作/表示/辞書/調整) + rows of controls.
   Control kinds needed from the sumi sprite vocabulary: label, checkbox,
   number field (click ± steppers, no free text in v1), text field
   (v1: read-only display + "エクスプローラで開く/既定に戻す" actions
   where editing is risky), color swatch (click cycles a fixed palette in
   v1; full picker later). 適用 writes the registry and shows the
   CorvusSKK-style note: 反映には IME の切替が必要です.

Rendering/input follow the existing sumi-sprite-live protocol (frame
stream out, EVENT stream back, per `dev/nelisp-sumi/protocol/frame-v1.org`);
the app is a NeLisp AOT module in the same restricted dialect as
`nelisp-sumi/src/*.el`.

## Phases

- **Phase 1 — engine `STATUS` verb** (engine/ddskk-engine.el + tests;
  host needs no change). Ships independently; also useful for probes.
- **Phase 2 — indicator MVP**: window, STATUS poll, mode display, click
  menu that switches modes, settings launch stub.
- **Phase 3 — settings tabs** 動作/表示/辞書/調整 with registry I/O, plus
  the host env-export change for the two new dictionary values.
- **Phase 4 — polish**: color picker, DPI scaling, autostart option.
