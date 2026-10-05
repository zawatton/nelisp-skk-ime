;; settings-window.el --- Settings logic in NeLisp AOT. -*- lexical-binding: t; -*-
;; C retains ABI primitives; struct offsets are checked in settings-abi.inc.
;; String blobs are padded to 8 bytes: RegGetValueW/RegSetKeyValueW require
;; aligned UTF-16 names. Removing unused blobs must preserve this padding.
;; _done/_result express early returns while freeing each scratch allocation.
;; C/NeLisp layout contracts are checked by settings-abi.inc on every build.
(seq
 (data-blob sn_host_empty "\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 
 (data-blob sn_host_exe "\x45\x00\x6e\x00\x67\x00\x69\x00\x6e\x00\x65\x00\x48\x00\x6f\x00\x73\x00\x74\x00\x00\x00\x00\x00" rodata) ; UTF-16 EngineHost
 (data-blob sn_host_runner "\x45\x00\x6e\x00\x67\x00\x69\x00\x6e\x00\x65\x00\x45\x00\x78\x00\x65\x00\x63\x00\x75\x00\x74\x00\x61\x00\x62\x00\x6c\x00\x65\x00\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 EngineExecutable
 (data-blob sn_host_repo "\x52\x00\x65\x00\x70\x00\x6f\x00\x73\x00\x69\x00\x74\x00\x6f\x00\x72\x00\x79\x00\x00\x00\x00\x00" rodata) ; UTF-16 Repository
 (data-blob sn_str_0 "\x25\x75\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 %u
 (data-blob sn_str_1 "\x25\x75\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 %u
 (data-blob sn_str_2 "\x64\x00\x64\x00\x73\x00\x6b\x00\x6b\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 ddskk
 (data-blob sn_str_3 "\xe9\x80\x81\xe3\x82\x8a\xe4\xbb\xae\xe5\x90\x8d\xe3\x81\x8c\xe4\xb8\x80\xe8\x87\xb4\xe3\x81\x97\xe3\x81\x9f\xe5\x80\x99\xe8\xa3\x9c\xe3\x82\x92\xe5\x84\xaa\xe5\x85\x88\xe3\x81\x99\xe3\x82\x8b\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 送り仮名が一致した候補を優先する
 (data-blob sn_str_4 "\xe5\x8f\x96\xe6\xb6\x88\xe3\x81\xae\xe3\x81\xa8\xe3\x81\x8d\xe9\x80\x81\xe3\x82\x8a\xe4\xbb\xae\xe5\x90\x8d\xe3\x82\x92\xe5\x89\x8a\xe9\x99\xa4\xe3\x81\x99\xe3\x82\x8b\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 取消のとき送り仮名を削除する
 (data-blob sn_str_5 "\xe5\x80\x99\xe8\xa3\x9c\xe3\x81\xab\xe7\x89\x87\xe4\xbb\xae\xe5\x90\x8d\xe5\xa4\x89\xe6\x8f\x9b\xe3\x82\x92\xe8\xbf\xbd\xe5\x8a\xa0\xe3\x81\x99\xe3\x82\x8b\x00" rodata) ; UTF-8 候補に片仮名変換を追加する
 (data-blob sn_str_6 "\xe5\xad\xa6\xe7\xbf\x92\xe3\x81\x97\xe3\x81\xaa\xe3\x81\x84\xef\xbc\x88\xe3\x83\x97\xe3\x83\xa9\xe3\x82\xa4\xe3\x83\x99\xe3\x83\xbc\xe3\x83\x88\xe3\x83\xa2\xe3\x83\xbc\xe3\x83\x89\xef\xbc\x89\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 学習しない（プライベートモード）
 (data-blob sn_str_7 "\xe3\x81\x93\xe3\x81\xae\xe5\x87\xa6\xe7\x90\x86\xe7\xb3\xbb\xe3\x81\xab\xe8\xbf\xbd\xe5\x8a\xa0\xe3\x81\xae\xe8\xa8\xad\xe5\xae\x9a\xe3\x81\xaf\xe3\x81\x82\xe3\x82\x8a\xe3\x81\xbe\xe3\x81\x9b\xe3\x82\x93\xe3\x80\x82\x00\x00" rodata) ; UTF-8 この処理系に追加の設定はありません。
 (data-blob sn_str_8 "\x25\x75\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 %u
 (data-blob sn_str_9 "\x6e\x6f\x74\x69\x66\x79\x3a\x3a\x73\x65\x6c\x65\x63\x74\x65\x64\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 notify::selected
 (data-blob sn_str_10 "\xe3\x82\xa8\xe3\x83\xb3\xe3\x82\xb8\xe3\x83\xb3\x00\x00\x00\x00" rodata) ; UTF-8 エンジン
 (data-blob sn_str_11 "\xe3\x81\x8b\xe3\x81\xaa\x00\x00" rodata) ; UTF-8 かな
 (data-blob sn_str_12 "\xe8\x8b\xb1\xe6\x95\xb0\x00\x00" rodata) ; UTF-8 英数
 (data-blob sn_str_13 "\xe5\x88\x9d\xe6\x9c\x9f\xe5\x85\xa5\xe5\x8a\x9b\xe3\x83\xa2\xe3\x83\xbc\xe3\x83\x89\x00\x00\x00" rodata) ; UTF-8 初期入力モード
 (data-blob sn_str_14 "\x25\x75\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 %u
 (data-blob sn_str_15 "\xe5\x85\xa5\xe5\x8a\x9b\xe3\x83\xa2\xe3\x83\xbc\xe3\x83\x89\xe3\x82\x92\xe8\xa1\xa8\xe7\xa4\xba\xe3\x81\x99\xe3\x82\x8b\x00\x00" rodata) ; UTF-8 入力モードを表示する
 (data-blob sn_str_16 "\xe8\xa1\xa8\xe7\xa4\xba\xe6\x99\x82\xe9\x96\x93\x20\x28\x6d\x73\x29\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 表示時間 (ms)
 (data-blob sn_str_17 "\xe8\xa1\xa8\xe7\xa4\xba\xe5\x80\x8d\xe7\x8e\x87\x20\x28\x25\x29\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 表示倍率 (%)
 (data-blob sn_str_18 "\xe3\x81\x8b\xe3\x81\xaa\xe8\x89\xb2\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 かな色
 (data-blob sn_str_19 "\xe3\x82\xab\xe3\x83\x8a\xe8\x89\xb2\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 カナ色
 (data-blob sn_str_20 "\xe5\x85\xa8\xe8\x8b\xb1\xe8\x89\xb2\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 全英色
 (data-blob sn_str_21 "\xe8\x8b\xb1\xe6\x95\xb0\xe8\x89\xb2\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 英数色
 (data-blob sn_str_22 "\x41\x62\x62\x72\x65\x76\xe8\x89\xb2\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 Abbrev色
 (data-blob sn_str_23 "\xe3\x83\xa6\xe3\x83\xbc\xe3\x82\xb6\xe3\x83\xbc\xe8\xbe\x9e\xe6\x9b\xb8\xe3\x83\x95\xe3\x82\xa1\xe3\x82\xa4\xe3\x83\xab\xe3\x82\x92\xe9\x81\xb8\xe6\x8a\x9e\x00" rodata) ; UTF-8 ユーザー辞書ファイルを選択
 (data-blob sn_str_24 "\xe8\xbe\x9e\xe6\x9b\xb8\xe3\x82\xb5\xe3\x83\xbc\xe3\x83\x90\xe3\x82\x92\xe4\xbd\xbf\xe7\x94\xa8\xe3\x81\x99\xe3\x82\x8b\x00\x00" rodata) ; UTF-8 辞書サーバを使用する
 (data-blob sn_str_25 "\xe3\x83\x9b\xe3\x82\xb9\xe3\x83\x88\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 ホスト
 (data-blob sn_str_26 "\xe3\x83\x9d\xe3\x83\xbc\xe3\x83\x88\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 ポート
 (data-blob sn_str_27 "\xe5\x8f\x82\xe7\x85\xa7\x00\x00" rodata) ; UTF-8 参照
 (data-blob sn_str_28 "\x63\x6c\x69\x63\x6b\x65\x64\x00" rodata) ; UTF-8 clicked
 (data-blob sn_str_29 "\xe3\x83\xa6\xe3\x83\xbc\xe3\x82\xb6\xe3\x83\xbc\xe8\xbe\x9e\xe6\x9b\xb8\xe3\x83\x91\xe3\x82\xb9\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 ユーザー辞書パス
 (data-blob sn_str_30 "\xe4\xbf\x9d\xe5\xad\x98\xe9\x96\x93\xe9\x9a\x94\x20\x28\xe7\xa2\xba\xe5\xae\x9a\xe6\x95\xb0\x29\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 保存間隔 (確定数)
 (data-blob sn_str_31 "\x64\x00\x64\x00\x73\x00\x6b\x00\x6b\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-16 ddskk
 (data-blob sn_str_32 "\x70\x00\x61\x00\x73\x00\x73\x00\x74\x00\x68\x00\x72\x00\x6f\x00\x75\x00\x67\x00\x68\x00\x00\x00" rodata) ; UTF-16 passthrough
 (data-blob sn_str_33 "\xe3\x83\x91\xe3\x82\xb9\xe3\x82\xb9\xe3\x83\xab\xe3\x83\xbc\xe3\x81\xaf\xe8\xbe\x9e\xe6\x9b\xb8\xe3\x82\x92\xe4\xbd\xbf\xe7\x94\xa8\xe3\x81\x97\xe3\x81\xbe\xe3\x81\x9b\xe3\x82\x93\xe3\x80\x82\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 パススルーは辞書を使用しません。
 (data-blob sn_str_34 "\xe3\x81\x93\xe3\x81\xae\xe5\x87\xa6\xe7\x90\x86\xe7\xb3\xbb\xe3\x81\xae\xe8\xbe\x9e\xe6\x9b\xb8\xe8\xa8\xad\xe5\xae\x9a\xe3\x81\xaf\xe3\x80\x81\xe3\x81\xbe\xe3\x81\xa0\xe8\xa8\xad\xe5\xae\x9a\xe7\x94\xbb\xe9\x9d\xa2\xe3\x81\x8b\xe3\x82\x89\xe5\xa4\x89\xe6\x9b\xb4\xe3\x81\xa7\xe3\x81\x8d\xe3\x81\xbe\xe3\x81\x9b\xe3\x82\x93\xe3\x80\x82\x00\x00\x00\x00" rodata) ; UTF-8 この処理系の辞書設定は、まだ設定画面から変更できません。
 (data-blob sn_str_35 "\x25\x75\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 %u
 (data-blob sn_str_36 "\x25\x75\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 %u
 (data-blob sn_str_37 "\xe3\x82\xa2\xe3\x82\xa4\xe3\x83\x89\xe3\x83\xab\x47\x43\xe9\x96\x93\xe9\x9a\x94\x20\x28\x6d\x73\x29\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 アイドルGC間隔 (ms)
 (data-blob sn_str_38 "\xe3\x83\x87\xe3\x83\x90\xe3\x83\x83\xe3\x82\xb0\xe3\x83\xad\xe3\x82\xb0\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 デバッグログ
 (data-blob sn_str_39 "\x74\x65\x78\x74\x2d\x61\x63\x74\x69\x6f\x6e\x00\x00\x00\x00\x00" rodata) ; UTF-8 text-action
 (data-blob sn_str_40 "\xe3\x83\x95\xe3\x82\xa1\xe3\x82\xa4\xe3\x83\xab\xe3\x81\xbe\xe3\x81\x9f\xe3\x81\xaf\xe7\xb7\xa8\xe9\x9b\x86\xe7\x94\xbb\xe9\x9d\xa2\xe3\x82\x92\xe9\x96\x8b\xe3\x81\x91\xe3\x81\xbe\xe3\x81\x9b\xe3\x82\x93\xe3\x81\xa7\xe3\x81\x97\xe3\x81\x9f\x00\x00\x00\x00" rodata) ; UTF-8 ファイルまたは編集画面を開けませんでした
 (data-blob sn_str_41 "\x74\x65\x78\x74\x2d\x61\x63\x74\x69\x6f\x6e\x00\x00\x00\x00\x00" rodata) ; UTF-8 text-action
 (data-blob sn_str_42 "\x63\x6c\x69\x63\x6b\x65\x64\x00" rodata) ; UTF-8 clicked
 (data-blob sn_str_43 "\xe5\x8d\x8a\xe8\xa7\x92\x00\x00" rodata) ; UTF-8 半角
 (data-blob sn_str_44 "\xe5\x85\xa8\xe8\xa7\x92\x00\x00" rodata) ; UTF-8 全角
 (data-blob sn_str_45 "\xe8\xa8\x98\xe5\x8f\xb7\xe3\x81\xae\xe5\xb9\x85\x00\x00\x00\x00" rodata) ; UTF-8 記号の幅
 (data-blob sn_str_46 "\xe6\x8b\xac\xe5\xbc\xa7\xe3\x82\x92\xe8\x87\xaa\xe5\x8b\x95\xe3\x81\xa7\xe9\x96\x89\xe3\x81\x98\xe3\x82\x8b\x00\x00\x00\x00\x00" rodata) ; UTF-8 括弧を自動で閉じる
 (data-blob sn_str_47 "\xe3\x82\xad\xe3\x83\xbc\xe7\xbd\xae\xe3\x81\x8d\xe6\x8f\x9b\xe3\x81\x88\xe3\x82\x92\xe6\x9c\x89\xe5\x8a\xb9\xe3\x81\xab\xe3\x81\x99\xe3\x82\x8b\x00\x00\x00\x00" rodata) ; UTF-8 キー置き換えを有効にする
 (data-blob sn_str_48 "\x4f\x53\xe3\x81\xae\xe3\x81\xbe\xe3\x81\xbe\x00\x00\x00\x00\x00" rodata) ; UTF-8 OSのまま
 (data-blob sn_str_49 "\x55\x53\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 US
 (data-blob sn_str_50 "\x4a\x49\x53\x00\x00\x00\x00\x00" rodata) ; UTF-8 JIS
 (data-blob sn_str_51 "\xe9\x85\x8d\xe5\x88\x97\x00\x00" rodata) ; UTF-8 配列
 (data-blob sn_str_52 "\xe8\xa8\x98\xe5\x8f\xb7\xe3\x81\xa8\xe6\x8b\xac\xe5\xbc\xa7\xe3\x81\xae\xe8\xa1\xa8\xe3\x82\x92\xe7\xb7\xa8\xe9\x9b\x86\x2e\x2e\x2e\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 記号と括弧の表を編集...
 (data-blob sn_str_53 "\xe3\x82\xad\xe3\x83\xbc\xe7\xbd\xae\xe3\x81\x8d\xe6\x8f\x9b\xe3\x81\x88\xe3\x83\xbb\xe3\x82\xad\xe3\x83\xbc\xe3\x81\xae\xe7\xa2\xba\xe8\xaa\x8d\xe3\x82\x92\xe9\x96\x8b\xe3\x81\x8f\x2e\x2e\x2e\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 キー置き換え・キーの確認を開く...
 (data-blob sn_str_54 "\xe3\x83\x86\xe3\x82\xad\xe3\x82\xb9\xe3\x83\x88\xe3\x83\x95\xe3\x82\xa1\xe3\x82\xa4\xe3\x83\xab\xe3\x82\x92\xe9\x96\x8b\xe3\x81\x8f\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 テキストファイルを開く
 (data-blob sn_str_55 "\xe9\x81\xa9\xe7\x94\xa8\xe3\x81\x99\xe3\x82\x8b\xe3\x81\xa8\xe5\xb8\xb8\xe9\xa7\x90\xe3\x83\x97\xe3\x83\xad\xe3\x82\xb0\xe3\x83\xa9\xe3\x83\xa0\xe3\x81\x8c\xe8\x87\xaa\xe5\x8b\x95\xe3\x81\xa7\xe8\xaa\xad\xe3\x81\xbf\xe7\x9b\xb4\xe3\x81\x97\xe3\x81\xbe\xe3\x81\x99\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 適用すると常駐プログラムが自動で読み直します
 (data-blob sn_str_56 "\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 
 (data-blob sn_str_57 "\xe7\x8a\xb6\xe6\x85\x8b\xe3\x82\x92\xe6\x9b\xb4\xe6\x96\xb0\x00" rodata) ; UTF-8 状態を更新
 (data-blob sn_str_58 "\x63\x6c\x69\x63\x6b\x65\x64\x00" rodata) ; UTF-8 clicked
 (data-blob sn_str_59 "\x53\x54\x41\x54\x55\x53\x0a\x00" rodata) ; UTF-8 STATUS\n
 (data-blob sn_str_60 "\xe3\x82\xa8\xe3\x83\xb3\xe3\x82\xb8\xe3\x83\xb3\xe3\x82\x92\xe5\x88\x87\xe6\x9b\xbf\xe3\x81\x88\xe3\x81\xbe\xe3\x81\x97\xe3\x81\x9f\xe3\x80\x82\xe5\x85\xa5\xe5\x8a\x9b\xe3\x81\xa7\xe3\x81\x8d\xe3\x81\xbe\xe3\x81\x99\x00\x00" rodata) ; UTF-8 エンジンを切替えました。入力できます
 (data-blob sn_str_61 "\xe3\x82\xa8\xe3\x83\xb3\xe3\x82\xb8\xe3\x83\xb3\xe3\x81\x8c\xe5\xbf\x9c\xe7\xad\x94\xe3\x81\x97\xe3\x81\xbe\xe3\x81\x9b\xe3\x82\x93\xe3\x80\x82\xe3\x82\x82\xe3\x81\x86\xe4\xb8\x80\xe5\xba\xa6\xe9\x81\xa9\xe7\x94\xa8\xe3\x81\x97\xe3\x81\xa6\xe3\x81\x8f\xe3\x81\xa0\xe3\x81\x95\xe3\x81\x84\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 エンジンが応答しません。もう一度適用してください
 (data-blob sn_str_62 "\x53\x48\x55\x54\x44\x4f\x57\x4e\x0a\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 SHUTDOWN\n
 (data-blob sn_str_63 "\xe3\x82\xa8\xe3\x83\xb3\xe3\x82\xb8\xe3\x83\xb3\xe3\x82\x92\xe8\xb5\xb7\xe5\x8b\x95\xe4\xb8\xad\xe3\x81\xa7\xe3\x81\x99\xe2\x80\xa6\xef\xbc\x88\xe6\x95\xb0\xe7\xa7\x92\xe3\x81\x8b\xe3\x81\x8b\xe3\x82\x8a\xe3\x81\xbe\xe3\x81\x99\xef\xbc\x89\x00\x00\x00\x00" rodata) ; UTF-8 エンジンを起動中です…（数秒かかります）
 (data-blob sn_str_64 "\xe4\xb8\x80\xe9\x83\xa8\xe3\x81\xae\xe8\xa8\xad\xe5\xae\x9a\xe3\x81\xae\xe4\xbf\x9d\xe5\xad\x98\xe3\x81\xab\xe5\xa4\xb1\xe6\x95\x97\xe3\x81\x97\xe3\x81\xbe\xe3\x81\x97\xe3\x81\x9f\x00\x00\x00" rodata) ; UTF-8 一部の設定の保存に失敗しました
 (data-blob sn_str_65 "\xe3\x82\xa8\xe3\x83\xb3\xe3\x82\xb8\xe3\x83\xb3\xe3\x82\x92\xe5\x88\x87\xe6\x9b\xbf\xe3\x81\x88\xe3\x81\xa6\xe5\x86\x8d\xe8\xb5\xb7\xe5\x8b\x95\xe3\x81\x97\xe3\x81\xbe\xe3\x81\x97\xe3\x81\x9f\xe3\x80\x82\xe6\xac\xa1\xe3\x81\xae\xe5\x85\xa5\xe5\x8a\x9b\xe3\x81\x8b\xe3\x82\x89\xe6\x9c\x89\xe5\x8a\xb9\xe3\x81\xa7\xe3\x81\x99\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 エンジンを切替えて再起動しました。次の入力から有効です
 (data-blob sn_str_66 "\xe5\x8f\x8d\xe6\x98\xa0\xe3\x81\xab\xe3\x81\xaf\x20\x49\x4d\x45\x20\xe3\x81\xae\xe5\x88\x87\xe6\x9b\xbf\xef\xbc\x88\xe3\x81\xbe\xe3\x81\x9f\xe3\x81\xaf\xe3\x82\xa8\xe3\x83\xb3\xe3\x82\xb8\xe3\x83\xb3\xe5\x86\x8d\xe8\xb5\xb7\xe5\x8b\x95\xef\xbc\x89\xe3\x81\x8c\xe5\xbf\x85\xe8\xa6\x81\xe3\x81\xa7\xe3\x81\x99\x00\x00\x00" rodata) ; UTF-8 反映には IME の切替（またはエンジン再起動）が必要です
 (data-blob sn_str_67 "\x53\x48\x55\x54\x44\x4f\x57\x4e\x0a\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 SHUTDOWN\n
 (data-blob sn_str_68 "\xe3\x82\xa8\xe3\x83\xb3\xe3\x82\xb8\xe3\x83\xb3\xe3\x81\xab\xe5\x86\x8d\xe8\xb5\xb7\xe5\x8b\x95\xe3\x82\x92\xe8\xa6\x81\xe6\xb1\x82\xe3\x81\x97\xe3\x81\xbe\xe3\x81\x97\xe3\x81\x9f\x00\x00\x00" rodata) ; UTF-8 エンジンに再起動を要求しました
 (data-blob sn_str_70 "\x73\x77\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 sw
 (data-blob sn_str_71 "\x63\x6c\x6f\x73\x65\x2d\x72\x65\x71\x75\x65\x73\x74\x00\x00\x00" rodata) ; UTF-8 close-request
 (data-blob sn_str_72 "\xe5\x8b\x95\xe4\xbd\x9c\x00\x00" rodata) ; UTF-8 動作
 (data-blob sn_str_73 "\xe8\xa1\xa8\xe7\xa4\xba\x00\x00" rodata) ; UTF-8 表示
 (data-blob sn_str_74 "\xe8\xbe\x9e\xe6\x9b\xb8\x00\x00" rodata) ; UTF-8 辞書
 (data-blob sn_str_75 "\xe8\xaa\xbf\xe6\x95\xb4\x00\x00" rodata) ; UTF-8 調整
 (data-blob sn_str_76 "\xe5\x85\xa5\xe5\x8a\x9b\xe8\xa6\x8f\xe5\x89\x87\x00\x00\x00\x00" rodata) ; UTF-8 入力規則
 (data-blob sn_str_77 "\xe3\x82\xad\xe3\x83\xbc\xe7\xbd\xae\xe3\x81\x8d\xe6\x8f\x9b\xe3\x81\x88\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 キー置き換え
 (data-blob sn_str_78 "\x00\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 
 (data-blob sn_str_79 "\xe3\x82\xa8\xe3\x83\xb3\xe3\x82\xb8\xe3\x83\xb3\xe5\x86\x8d\xe8\xb5\xb7\xe5\x8b\x95\x00\x00\x00" rodata) ; UTF-8 エンジン再起動
 (data-blob sn_str_80 "\x63\x6c\x69\x63\x6b\x65\x64\x00" rodata) ; UTF-8 clicked
 (data-blob sn_str_81 "\xe9\x81\xa9\xe7\x94\xa8\x00\x00" rodata) ; UTF-8 適用
 (data-blob sn_str_82 "\x63\x6c\x69\x63\x6b\x65\x64\x00" rodata) ; UTF-8 clicked
 (data-blob sn_str_83 "\xe9\x96\x89\xe3\x81\x98\xe3\x82\x8b\x00\x00\x00\x00\x00\x00\x00" rodata) ; UTF-8 閉じる
 (data-blob sn_str_84 "\x63\x6c\x69\x63\x6b\x65\x64\x00" rodata) ; UTF-8 clicked
 (defun engine_choice_index (id)
   (let ((_done 0) (_result 0) (i 0))
     (progn
       (if (= _done 0) (progn (progn (setq i 0)) (while (and (= _done 0) (< i 4)) (progn
										    (if (= _done 0) (if (= (extern-call wcscmp (ptr-read-u64 (+ (extern-call skkui_engine_choices) (* i 32)) 0) id) 0) (progn (setq _result i) (setq _done 1)) 0) 0)) (let ((_old i)) (setq i (+ i 1)) _old))) 0)
       (if (= _done 0) (progn (setq _result 0) (setq _done 1)) 0))

     _result))
 (defun engine_visible_init (sw)
   (let ((_done 0) (_result 0) (experimental 0) (current 0) (i 0))
     (progn
       (if (= _done 0) (setq experimental (extern-call settings_experimental_engines )) 0)
       (if (= _done 0) (setq current (extern-call engine_choice_index (+ (+ (ptr-read-u64 sw 0) 1096) 0))) 0)
       (if (= _done 0) (ptr-write-u32 sw 72 0) 0)
       (if (= _done 0) (progn (progn (setq i 0)) (while (and (= _done 0) (< i 4)) (progn
										    (if (= _done 0) (if (or (or (= (ptr-read-u32 (+ (extern-call skkui_engine_choices) (* i 32)) 24) 0) experimental) (= i current)) (ptr-write-u32 (+ sw 40) (* (let ((_old (ptr-read-u32 sw 72))) (ptr-write-u32 sw 72 (+ (ptr-read-u32 sw 72) 1)) _old) 4) i) 0) 0)) (let ((_old i)) (setq i (+ i 1)) _old))) 0))

     _result))
 (defun engine_visible_position (sw choice)
   (let ((_done 0) (_result 0) (i 0))
     (progn
       (if (= _done 0) (progn (progn (setq i 0)) (while (and (= _done 0) (< i (ptr-read-u32 sw 72))) (progn
												       (if (= _done 0) (if (= (ptr-read-u32 (+ sw 40) (* i 4)) choice) (progn (setq _result i) (setq _done 1)) 0) 0)) (let ((_old i)) (setq i (+ i 1)) _old))) 0)
       (if (= _done 0) (progn (setq _result 0) (setq _done 1)) 0))

     _result))
 (defun on_engine_changed (dropdown pspec user_data)
   (let ((_done 0) (_result 0) (sw 0) (selected 0) (index 0) (choice 0) (name (extern-call g_malloc0 32)))
     (progn
       (if (= _done 0) (setq sw user_data) 0)
       (if (= _done 0) (setq selected (extern-call gtk_drop_down_get_selected dropdown)) 0)
       (if (= _done 0) (if (>= selected (ptr-read-u32 sw 72)) (progn (setq _result 0) (setq _done 1)) 0) 0)
       (if (= _done 0) (setq index (ptr-read-u32 (+ sw 40) (* selected 4))) 0)
       (if (= _done 0) (setq choice (+ (extern-call skkui_engine_choices) (* index 32))) 0)
       (if (= _done 0) (extern-call wcsncpy (+ (+ (ptr-read-u64 sw 0) 1096) 0) (ptr-read-u64 choice 0) (- 260 1)) 0)
       (if (= _done 0) (ptr-write-u16 (+ (+ (ptr-read-u64 sw 0) 1096) 0) (* (- 260 1) 2) 0) 0)
       (if (= _done 0) (extern-call settings_load_engine_scope (+ (ptr-read-u64 sw 0) 1096) (ptr-read-u64 choice 0)) 0)
       (if (= _done 0) (if (ptr-read-u64 sw 80) (progn
						  (if (= _done 0) (extern-call gtk_check_button_set_active (ptr-read-u64 sw 80) (/= (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 520) 0)) 0)) 0) 0)
       (if (= _done 0) (if (ptr-read-u64 sw 88) (progn
						  (if (= _done 0) (extern-call gtk_spin_button_set_value (ptr-read-u64 sw 88) (:f64 (i64-to-f64 (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 524)))) 0)) 0) 0)
       (if (= _done 0) (if (ptr-read-u64 sw 96) (progn
						  (if (= _done 0) (extern-call gtk_check_button_set_active (ptr-read-u64 sw 96) (/= (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 528) 0)) 0)) 0) 0)
       (if (= _done 0) (if (ptr-read-u64 sw 24) (progn
						  (if (= _done 0) (extern-call snprintf name 32 (data-addr sn_str_0) index (:varargs)) 0)
						  (if (= _done 0) (extern-call gtk_stack_set_visible_child_name (ptr-read-u64 sw 24) name) 0)) 0) 0)
       (if (= _done 0) (if (ptr-read-u64 sw 32) (progn
						  (if (= _done 0) (extern-call snprintf name 32 (data-addr sn_str_1) index (:varargs)) 0)
						  (if (= _done 0) (extern-call gtk_stack_set_visible_child_name (ptr-read-u64 sw 32) name) 0)) 0) 0))
     (extern-call g_free name)
     _result))
 (defun build_engine_pages (sw)
   (let ((_done 0) (_result 0) (stack 0) (i 0) (page 0) (note 0) (none 0) (name (extern-call g_malloc0 32)))
     (progn
       (if (= _done 0) (setq stack (extern-call gtk_stack_new )) 0)
       (if (= _done 0) (progn (progn (setq i 0)) (while (and (= _done 0) (< i 4)) (progn
										    (if (= _done 0) (setq page (extern-call gtk_box_new 1 6)) 0)
										    (if (= _done 0) (setq note (extern-call gtk_label_new (ptr-read-u64 (+ (extern-call skkui_engine_choices) (* i 32)) 16))) 0)
										    (if (= _done 0) (extern-call gtk_label_set_xalign note (:f32 0.0)) 0)
										    (if (= _done 0) (extern-call gtk_label_set_wrap note 1) 0)
										    (if (= _done 0) (extern-call gtk_box_append page note) 0)
										    (if (= _done 0) (if (= (extern-call wcscmp (ptr-read-u64 (+ (extern-call skkui_engine_choices) (* i 32)) 0) (data-addr sn_str_2)) 0) (progn
																											   (if (= _done 0) (ptr-write-u64 sw 120 (extern-call gtk_check_button_new_with_label (data-addr sn_str_3))) 0)
																											   (if (= _done 0) (extern-call gtk_check_button_set_active (ptr-read-u64 sw 120) (/= (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 536) 0)) 0)
																											   (if (= _done 0) (extern-call gtk_box_append page (ptr-read-u64 sw 120)) 0)
																											   (if (= _done 0) (ptr-write-u64 sw 128 (extern-call gtk_check_button_new_with_label (data-addr sn_str_4))) 0)
																											   (if (= _done 0) (extern-call gtk_check_button_set_active (ptr-read-u64 sw 128) (/= (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 540) 0)) 0)
																											   (if (= _done 0) (extern-call gtk_box_append page (ptr-read-u64 sw 128)) 0)
																											   (if (= _done 0) (ptr-write-u64 sw 136 (extern-call gtk_check_button_new_with_label (data-addr sn_str_5))) 0)
																											   (if (= _done 0) (extern-call gtk_check_button_set_active (ptr-read-u64 sw 136) (/= (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 544) 0)) 0)
																											   (if (= _done 0) (extern-call gtk_box_append page (ptr-read-u64 sw 136)) 0)
																											   (if (= _done 0) (ptr-write-u64 sw 144 (extern-call gtk_check_button_new_with_label (data-addr sn_str_6))) 0)
																											   (if (= _done 0) (extern-call gtk_check_button_set_active (ptr-read-u64 sw 144) (/= (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 548) 0)) 0)
																											   (if (= _done 0) (extern-call gtk_box_append page (ptr-read-u64 sw 144)) 0)) (progn
																											   (if (= _done 0) (setq none (extern-call gtk_label_new (data-addr sn_str_7))) 0)
																											   (if (= _done 0) (extern-call gtk_label_set_xalign none (:f32 0.0)) 0)
																											   (if (= _done 0) (extern-call gtk_box_append page none) 0))) 0)
										    (if (= _done 0) (extern-call snprintf name 32 (data-addr sn_str_8) i (:varargs)) 0)
										    (if (= _done 0) (extern-call gtk_stack_add_named stack page name) 0)) (let ((_old i)) (setq i (+ i 1)) _old))) 0)
       (if (= _done 0) (progn (setq _result stack) (setq _done 1)) 0))
     (extern-call g_free name)
     _result))
 (defun build_tab_behavior (sw)
   (let ((_done 0) (_result 0) (grid 0) (engine_labels (extern-call g_malloc0 40)) (i 0) (radio_box 0) (row 0) (name (extern-call g_malloc0 32)))
     (progn
       (if (= _done 0) (setq grid (extern-call gtk_grid_new )) 0)
       (if (= _done 0) (extern-call gtk_grid_set_row_spacing grid 6) 0)
       (if (= _done 0) (extern-call gtk_grid_set_column_spacing grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_top grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_bottom grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_start grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_end grid 12) 0)
       (if (= _done 0) (extern-call engine_visible_init sw) 0)
       (if (= _done 0) (progn (progn (setq i 0)) (while (and (= _done 0) (< i (ptr-read-u32 sw 72))) (progn
												       (if (= _done 0) (ptr-write-u64 engine_labels (* i 8) (ptr-read-u64 (+ (extern-call skkui_engine_choices) (* (ptr-read-u32 (+ sw 40) (* i 4)) 32)) 8)) 0)) (let ((_old i)) (setq i (+ i 1)) _old))) 0)
       (if (= _done 0) (ptr-write-u64 engine_labels (* (ptr-read-u32 sw 72) 8) 0) 0)
       (if (= _done 0) (ptr-write-u64 sw 16 (extern-call gtk_drop_down_new_from_strings engine_labels)) 0)
       (if (= _done 0) (extern-call gtk_drop_down_set_selected (ptr-read-u64 sw 16) (extern-call engine_visible_position sw (extern-call engine_choice_index (+ (+ (ptr-read-u64 sw 0) 1096) 0)))) 0)
       (if (= _done 0) (extern-call g_signal_connect_data (ptr-read-u64 sw 16) (data-addr sn_str_9) (extern-call skkui_callback_address 0) sw 0 0) 0)
       (if (= _done 0) (extern-call grid_add_row grid 0 (data-addr sn_str_10) (ptr-read-u64 sw 16)) 0)
       (if (= _done 0) (setq radio_box (extern-call gtk_box_new 0 12)) 0)
       (if (= _done 0) (ptr-write-u64 sw 104 (extern-call gtk_check_button_new_with_label (data-addr sn_str_11))) 0)
       (if (= _done 0) (ptr-write-u64 sw 112 (extern-call gtk_check_button_new_with_label (data-addr sn_str_12))) 0)
       (if (= _done 0) (extern-call gtk_check_button_set_group (ptr-read-u64 sw 112) (ptr-read-u64 sw 104)) 0)
       (if (= _done 0) (extern-call gtk_check_button_set_active (if (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 532) (ptr-read-u64 sw 104) (ptr-read-u64 sw 112)) 1) 0)
       (if (= _done 0) (extern-call gtk_box_append radio_box (ptr-read-u64 sw 104)) 0)
       (if (= _done 0) (extern-call gtk_box_append radio_box (ptr-read-u64 sw 112)) 0)
       (if (= _done 0) (extern-call grid_add_row grid 1 (data-addr sn_str_13) radio_box) 0)
       (if (= _done 0) (setq row 2) 0)
       (if (= _done 0) (ptr-write-u64 sw 24 (extern-call build_engine_pages sw)) 0)
       (if (= _done 0) (progn
			 (if (= _done 0) (extern-call snprintf name 32 (data-addr sn_str_14) (extern-call engine_choice_index (+ (+ (ptr-read-u64 sw 0) 1096) 0)) (:varargs)) 0)
			 (if (= _done 0) (extern-call gtk_stack_set_visible_child_name (ptr-read-u64 sw 24) name) 0)) 0)
       (if (= _done 0) (extern-call gtk_grid_attach grid (ptr-read-u64 sw 24) 0 (let ((_old row)) (setq row (+ row 1)) _old) 2 1) 0)
       (if (= _done 0) (progn (setq _result grid) (setq _done 1)) 0))
     (extern-call g_free engine_labels)
     (extern-call g_free name)
     _result))
 (defun build_tab_display (sw)
   (let ((_done 0) (_result 0) (grid 0) (row 0))
     (progn
       (if (= _done 0) (setq grid (extern-call gtk_grid_new )) 0)
       (if (= _done 0) (extern-call gtk_grid_set_row_spacing grid 6) 0)
       (if (= _done 0) (extern-call gtk_grid_set_column_spacing grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_top grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_bottom grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_start grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_end grid 12) 0)
       (if (= _done 0) (setq row 0) 0)
       (if (= _done 0) (ptr-write-u64 sw 152 (extern-call gtk_check_button_new_with_label (data-addr sn_str_15))) 0)
       (if (= _done 0) (extern-call gtk_check_button_set_active (ptr-read-u64 sw 152) (/= (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 552) 0)) 0)
       (if (= _done 0) (extern-call gtk_grid_attach grid (ptr-read-u64 sw 152) 0 row 2 1) 0)
       (if (= _done 0) (let ((_old row)) (setq row (+ row 1)) _old) 0)
       (if (= _done 0) (ptr-write-u64 sw 160 (extern-call gtk_spin_button_new_with_range (:f64 1.0) (:f64 60000.0) (:f64 100.0))) 0)
       (if (= _done 0) (extern-call gtk_spin_button_set_value (ptr-read-u64 sw 160) (:f64 (i64-to-f64 (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 556)))) 0)
       (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_16) (ptr-read-u64 sw 160)) 0)
       (if (= _done 0) (ptr-write-u64 sw 168 (extern-call gtk_spin_button_new_with_range (:f64 50.0) (:f64 300.0) (:f64 5.0))) 0)
       (if (= _done 0) (extern-call gtk_spin_button_set_value (ptr-read-u64 sw 168) (:f64 (i64-to-f64 (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 560)))) 0)
       (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_17) (ptr-read-u64 sw 168)) 0)
       (if (= _done 0) (ptr-write-u64 sw 176 (extern-call make_color_button (ptr-read-u64 (+ (ptr-read-u64 sw 0) 1096) 568))) 0)
       (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_18) (ptr-read-u64 sw 176)) 0)
       (if (= _done 0) (ptr-write-u64 sw 184 (extern-call make_color_button (ptr-read-u64 (+ (ptr-read-u64 sw 0) 1096) 576))) 0)
       (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_19) (ptr-read-u64 sw 184)) 0)
       (if (= _done 0) (ptr-write-u64 sw 192 (extern-call make_color_button (ptr-read-u64 (+ (ptr-read-u64 sw 0) 1096) 584))) 0)
       (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_20) (ptr-read-u64 sw 192)) 0)
       (if (= _done 0) (ptr-write-u64 sw 200 (extern-call make_color_button (ptr-read-u64 (+ (ptr-read-u64 sw 0) 1096) 592))) 0)
       (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_21) (ptr-read-u64 sw 200)) 0)
       (if (= _done 0) (ptr-write-u64 sw 208 (extern-call make_color_button (ptr-read-u64 (+ (ptr-read-u64 sw 0) 1096) 600))) 0)
       (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_22) (ptr-read-u64 sw 208)) 0)
       (if (= _done 0) (progn (setq _result grid) (setq _done 1)) 0))

     _result))
 (defun on_jisyo_chosen (source result user_data)
   (let ((_done 0) (_result 0) (entry 0) (error (extern-call g_malloc0 8)) (file 0) (path 0))
     (progn
       (if (= _done 0) (setq entry user_data) 0)
       (if (= _done 0) (ptr-write-u64 error 0 0) 0)
       (if (= _done 0) (setq file (extern-call gtk_file_dialog_open_finish source result (+ error 0))) 0)
       (if (= _done 0) (if file (progn
				  (if (= _done 0) (setq path (extern-call g_file_get_path file)) 0)
				  (if (= _done 0) (if path (progn
							     (if (= _done 0) (extern-call gtk_editable_set_text entry path) 0)
							     (if (= _done 0) (extern-call g_free path) 0)) 0) 0)
				  (if (= _done 0) (extern-call g_object_unref file) 0)) 0) 0)
       (if (= _done 0) (extern-call skkui_clear_error (+ error 0)) 0))
     (extern-call g_free error)
     _result))
 (defun on_jisyo_browse_clicked (button user_data)
   (let ((_done 0) (_result 0) (entry 0) (root 0) (dialog 0))
     (progn
       (if (= _done 0) (setq entry user_data) 0)
       (if (= _done 0) (setq root (extern-call gtk_widget_get_root button)) 0)
       (if (= _done 0) (setq dialog (extern-call gtk_file_dialog_new )) 0)
       (if (= _done 0) (extern-call gtk_file_dialog_set_title dialog (data-addr sn_str_23)) 0)
       (if (= _done 0) (extern-call gtk_file_dialog_open dialog root 0 (extern-call skkui_callback_address 1) entry) 0)
       (if (= _done 0) (extern-call g_object_unref dialog) 0))

     _result))
 (defun build_ddskk_dictionary_page (sw)
   (let ((_done 0) (_result 0) (grid 0) (row 0) (host_utf8 0) (jisyo_box 0) (path_utf8 0) (browse_button 0))
     (progn
       (if (= _done 0) (setq grid (extern-call gtk_grid_new )) 0)
       (if (= _done 0) (extern-call gtk_grid_set_row_spacing grid 6) 0)
       (if (= _done 0) (extern-call gtk_grid_set_column_spacing grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_top grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_bottom grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_start grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_end grid 12) 0)
       (if (= _done 0) (setq row 0) 0)
       (if (= _done 0) (ptr-write-u64 sw 216 (extern-call gtk_check_button_new_with_label (data-addr sn_str_24))) 0)
       (if (= _done 0) (extern-call gtk_check_button_set_active (ptr-read-u64 sw 216) (/= (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 608) 0)) 0)
       (if (= _done 0) (extern-call gtk_grid_attach grid (ptr-read-u64 sw 216) 0 row 2 1) 0)
       (if (= _done 0) (let ((_old row)) (setq row (+ row 1)) _old) 0)
       (if (= _done 0) (ptr-write-u64 sw 224 (extern-call gtk_entry_new )) 0)
       (if (= _done 0) (progn
			 (if (= _done 0) (setq host_utf8 (extern-call wide_to_utf8_alloc (+ (+ (ptr-read-u64 sw 0) 1096) 612))) 0)
			 (if (= _done 0) (extern-call gtk_editable_set_text (ptr-read-u64 sw 224) host_utf8) 0)
			 (if (= _done 0) (extern-call g_free host_utf8) 0)) 0)
       (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_25) (ptr-read-u64 sw 224)) 0)
       (if (= _done 0) (ptr-write-u64 sw 232 (extern-call gtk_spin_button_new_with_range (:f64 1.0) (:f64 65535.0) (:f64 1.0))) 0)
       (if (= _done 0) (extern-call gtk_spin_button_set_value (ptr-read-u64 sw 232) (:f64 (i64-to-f64 (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 1132)))) 0)
       (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_26) (ptr-read-u64 sw 232)) 0)
       (if (= _done 0) (setq jisyo_box (extern-call gtk_box_new 0 6)) 0)
       (if (= _done 0) (ptr-write-u64 sw 240 (extern-call gtk_entry_new )) 0)
       (if (= _done 0) (extern-call gtk_widget_set_hexpand (ptr-read-u64 sw 240) 1) 0)
       (if (= _done 0) (progn
			 (if (= _done 0) (setq path_utf8 (extern-call wide_to_utf8_alloc (+ (+ (ptr-read-u64 sw 0) 1096) 1136))) 0)
			 (if (= _done 0) (extern-call gtk_editable_set_text (ptr-read-u64 sw 240) path_utf8) 0)
			 (if (= _done 0) (extern-call g_free path_utf8) 0)) 0)
       (if (= _done 0) (setq browse_button (extern-call gtk_button_new_with_label (data-addr sn_str_27))) 0)
       (if (= _done 0) (extern-call g_signal_connect_data browse_button (data-addr sn_str_28) (extern-call skkui_callback_address 2) (ptr-read-u64 sw 240) 0 0) 0)
       (if (= _done 0) (extern-call gtk_box_append jisyo_box (ptr-read-u64 sw 240)) 0)
       (if (= _done 0) (extern-call gtk_box_append jisyo_box browse_button) 0)
       (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_29) jisyo_box) 0)
       (if (= _done 0) (ptr-write-u64 sw 248 (extern-call gtk_spin_button_new_with_range (:f64 1.0) (:f64 100.0) (:f64 1.0))) 0)
       (if (= _done 0) (extern-call gtk_spin_button_set_value (ptr-read-u64 sw 248) (:f64 (i64-to-f64 (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 1656)))) 0)
       (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_30) (ptr-read-u64 sw 248)) 0)
       (if (= _done 0) (progn (setq _result grid) (setq _done 1)) 0))

     _result))
 (defun build_tab_dictionary (sw)
   (let ((_done 0) (_result 0) (i 0) (page 0) (message 0) (label 0) (name (extern-call g_malloc0 32)) (current (extern-call g_malloc0 32)))
     (progn
       (if (= _done 0) (ptr-write-u64 sw 32 (extern-call gtk_stack_new )) 0)
       (if (= _done 0) (progn (progn (setq i 0)) (while (and (= _done 0) (< i 4)) (progn
										    (if (= _done 0) (setq page 0) 0)
										    (if (= _done 0) (if (= (extern-call wcscmp (ptr-read-u64 (+ (extern-call skkui_engine_choices) (* i 32)) 0) (data-addr sn_str_31)) 0) (progn
																											    (if (= _done 0) (setq page (extern-call build_ddskk_dictionary_page sw)) 0)) (progn
																											    (if (= _done 0) (setq page (extern-call gtk_box_new 1 6)) 0)
																											    (if (= _done 0) (extern-call gtk_widget_set_margin_top page 12) 0)
																											    (if (= _done 0) (extern-call gtk_widget_set_margin_bottom page 12) 0)
																											    (if (= _done 0) (extern-call gtk_widget_set_margin_start page 12) 0)
																											    (if (= _done 0) (extern-call gtk_widget_set_margin_end page 12) 0)
																											    (if (= _done 0) (setq message (if (= (extern-call wcscmp (ptr-read-u64 (+ (extern-call skkui_engine_choices) (* i 32)) 0) (data-addr sn_str_32)) 0) (data-addr sn_str_33) (data-addr sn_str_34))) 0)
																											    (if (= _done 0) (setq label (extern-call gtk_label_new message)) 0)
																											    (if (= _done 0) (extern-call gtk_label_set_xalign label (:f32 0.0)) 0)
																											    (if (= _done 0) (extern-call gtk_label_set_wrap label 1) 0)
																											    (if (= _done 0) (extern-call gtk_box_append page label) 0))) 0)
										    (if (= _done 0) (extern-call snprintf name 32 (data-addr sn_str_35) i (:varargs)) 0)
										    (if (= _done 0) (extern-call gtk_stack_add_named (ptr-read-u64 sw 32) page name) 0)) (let ((_old i)) (setq i (+ i 1)) _old))) 0)
       (if (= _done 0) (extern-call snprintf current 32 (data-addr sn_str_36) (extern-call engine_choice_index (+ (+ (ptr-read-u64 sw 0) 1096) 0)) (:varargs)) 0)
       (if (= _done 0) (extern-call gtk_stack_set_visible_child_name (ptr-read-u64 sw 32) current) 0)
       (if (= _done 0) (progn (setq _result (ptr-read-u64 sw 32)) (setq _done 1)) 0))
     (extern-call g_free name)
     (extern-call g_free current)
     _result))
 (defun build_tab_maintenance (sw)
   (let ((_done 0) (_result 0) (grid 0) (row 0))
     (progn
       (if (= _done 0) (setq grid (extern-call gtk_grid_new )) 0)
       (if (= _done 0) (extern-call gtk_grid_set_row_spacing grid 6) 0)
       (if (= _done 0) (extern-call gtk_grid_set_column_spacing grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_top grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_bottom grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_start grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_end grid 12) 0)
       (if (= _done 0) (setq row 0) 0)
       (if (= _done 0) (ptr-write-u64 sw 256 (extern-call gtk_spin_button_new_with_range (:f64 100.0) (:f64 60000.0) (:f64 100.0))) 0)
       (if (= _done 0) (extern-call gtk_spin_button_set_value (ptr-read-u64 sw 256) (:f64 (i64-to-f64 (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 1660)))) 0)
       (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_37) (ptr-read-u64 sw 256)) 0)
       (if (= _done 0) (ptr-write-u64 sw 264 (extern-call gtk_check_button_new_with_label (data-addr sn_str_38))) 0)
       (if (= _done 0) (extern-call gtk_check_button_set_active (ptr-read-u64 sw 264) (/= (ptr-read-u32 (+ (ptr-read-u64 sw 0) 1096) 1664) 0)) 0)
       (if (= _done 0) (extern-call gtk_grid_attach grid (ptr-read-u64 sw 264) 0 row 2 1) 0)
       (if (= _done 0) (progn (setq _result grid) (setq _done 1)) 0))

     _result))
 (defun on_text_open (button user_data)
   (let ((_done 0) (_result 0) (sw 0) (action 0))
     (progn
       (if (= _done 0) (setq sw user_data) 0)
       (if (= _done 0) (setq action (extern-call g_object_get_data button (data-addr sn_str_39))) 0)
       (if (= _done 0) (if (= (extern-call text_settings_open (/= (logand action 1) 0) (/= (logand action 2) 0)) 0) (extern-call gtk_label_set_text (ptr-read-u64 sw 328) (data-addr sn_str_40)) 0) 0))

     _result))
 (defun on_text_status (button user_data)
   (let ((_done 0) (_result 0) (sw 0) (status 0))
     (progn
       (if (= _done 0) (setq sw user_data) 0)
       (if (= _done 0) (setq status (extern-call text_settings_status )) 0)
       (if (= _done 0) (extern-call gtk_label_set_text (ptr-read-u64 sw 320) status) 0)
       (if (= _done 0) (extern-call g_free status) 0))

     _result))
 (defun text_button (sw label action)
   (let ((_done 0) (_result 0) (b 0))
     (progn
       (if (= _done 0) (setq b (extern-call gtk_button_new_with_label label)) 0)
       (if (= _done 0) (extern-call g_object_set_data b (data-addr sn_str_41) action) 0)
       (if (= _done 0) (extern-call g_signal_connect_data b (data-addr sn_str_42) (extern-call skkui_callback_address 3) sw 0 0) 0)
       (if (= _done 0) (progn (setq _result b) (setq _done 1)) 0))

     _result))
 (defun build_tab_text (sw rules)
   (let ((_done 0) (_result 0) (grid 0) (row 0) (box 0) (full 0) (choices (extern-call g_malloc0 64)) (note 0) (scroll 0) (refresh 0))
     (progn
       (if (= _done 0) (setq grid (extern-call gtk_grid_new )) 0)
       (if (= _done 0) (extern-call gtk_grid_set_row_spacing grid 6) 0)
       (if (= _done 0) (extern-call gtk_grid_set_column_spacing grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_top grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_bottom grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_start grid 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_end grid 12) 0)
       (if (= _done 0) (setq row 0) 0)
       (if (= _done 0) (if rules (progn
				   (if (= _done 0) (setq box (extern-call gtk_box_new 0 12)) 0)
				   (if (= _done 0) (ptr-write-u64 sw 288 (extern-call gtk_check_button_new_with_label (data-addr sn_str_43))) 0)
				   (if (= _done 0) (setq full (extern-call gtk_check_button_new_with_label (data-addr sn_str_44))) 0)
				   (if (= _done 0) (extern-call gtk_check_button_set_group full (ptr-read-u64 sw 288)) 0)
				   (if (= _done 0) (extern-call gtk_check_button_set_active (if (ptr-read-u32 (+ sw 272) 0) full (ptr-read-u64 sw 288)) 1) 0)
				   (if (= _done 0) (extern-call gtk_box_append box (ptr-read-u64 sw 288)) 0)
				   (if (= _done 0) (extern-call gtk_box_append box full) 0)
				   (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_45) box) 0)
				   (if (= _done 0) (ptr-write-u64 sw 296 (extern-call gtk_check_button_new_with_label (data-addr sn_str_46))) 0)
				   (if (= _done 0) (extern-call gtk_check_button_set_active (ptr-read-u64 sw 296) (ptr-read-u32 (+ sw 272) 4)) 0)
				   (if (= _done 0) (extern-call gtk_grid_attach grid (ptr-read-u64 sw 296) 0 (let ((_old row)) (setq row (+ row 1)) _old) 2 1) 0)) (progn
				   (if (= _done 0) (ptr-write-u64 sw 304 (extern-call gtk_check_button_new_with_label (data-addr sn_str_47))) 0)
				   (if (= _done 0) (extern-call gtk_check_button_set_active (ptr-read-u64 sw 304) (ptr-read-u32 (+ sw 272) 8)) 0)
				   (if (= _done 0) (extern-call gtk_grid_attach grid (ptr-read-u64 sw 304) 0 (let ((_old row)) (setq row (+ row 1)) _old) 2 1) 0)
				   (if (= _done 0) (progn (ptr-write-u64 choices 0 (data-addr sn_str_48)) (ptr-write-u64 choices 8 (data-addr sn_str_49)) (ptr-write-u64 choices 16 (data-addr sn_str_50)) (ptr-write-u64 choices 24 0)) 0)
				   (if (= _done 0) (ptr-write-u64 sw 312 (extern-call gtk_drop_down_new_from_strings choices)) 0)
				   (if (= _done 0) (extern-call gtk_drop_down_set_selected (ptr-read-u64 sw 312) (ptr-read-u32 (+ sw 272) 12)) 0)
				   (if (= _done 0) (extern-call grid_add_row grid (let ((_old row)) (setq row (+ row 1)) _old) (data-addr sn_str_51) (ptr-read-u64 sw 312)) 0))) 0)
       (if (= _done 0) (extern-call gtk_grid_attach grid (extern-call text_button sw (if rules (data-addr sn_str_52) (data-addr sn_str_53)) (if rules 3 2)) 0 (let ((_old row)) (setq row (+ row 1)) _old) 2 1) 0)
       (if (= _done 0) (extern-call gtk_grid_attach grid (extern-call text_button sw (data-addr sn_str_54) (if rules 1 0)) 0 (let ((_old row)) (setq row (+ row 1)) _old) 2 1) 0)
       (if (= _done 0) (setq note (extern-call gtk_label_new (data-addr sn_str_55))) 0)
       (if (= _done 0) (extern-call gtk_label_set_wrap note 1) 0)
       (if (= _done 0) (extern-call gtk_grid_attach grid note 0 (let ((_old row)) (setq row (+ row 1)) _old) 2 1) 0)
       (if (= _done 0) (if (= rules 0) (progn
					 (if (= _done 0) (ptr-write-u64 sw 320 (extern-call gtk_label_new (data-addr sn_str_56))) 0)
					 (if (= _done 0) (extern-call gtk_label_set_xalign (ptr-read-u64 sw 320) (:f32 0.0)) 0)
					 (if (= _done 0) (extern-call gtk_label_set_wrap (ptr-read-u64 sw 320) 1) 0)
					 (if (= _done 0) (extern-call gtk_label_set_selectable (ptr-read-u64 sw 320) 1) 0)
					 (if (= _done 0) (setq scroll (extern-call gtk_scrolled_window_new )) 0)
					 (if (= _done 0) (extern-call gtk_widget_set_vexpand scroll 1) 0)
					 (if (= _done 0) (extern-call gtk_scrolled_window_set_min_content_height scroll 80) 0)
					 (if (= _done 0) (extern-call gtk_scrolled_window_set_child scroll (ptr-read-u64 sw 320)) 0)
					 (if (= _done 0) (extern-call gtk_grid_attach grid scroll 0 (let ((_old row)) (setq row (+ row 1)) _old) 2 1) 0)
					 (if (= _done 0) (setq refresh (extern-call gtk_button_new_with_label (data-addr sn_str_57))) 0)
					 (if (= _done 0) (extern-call g_signal_connect_data refresh (data-addr sn_str_58) (extern-call skkui_callback_address 4) sw 0 0) 0)
					 (if (= _done 0) (extern-call gtk_grid_attach grid refresh 0 (let ((_old row)) (setq row (+ row 1)) _old) 2 1) 0)
					 (if (= _done 0) (extern-call on_text_status 0 sw) 0)) 0) 0)
       (if (= _done 0) (progn (setq _result grid) (setq _done 1)) 0))
     (extern-call g_free choices)
     _result))
 (defun settings_read_from_widgets (sw out)
   (let ((_done 0) (_result 0) (selected 0))
     (progn
       (if (= _done 0) (extern-call memcpy (+ out 0) (+ (ptr-read-u64 sw 0) 1096) 1672) 0)
       (if (= _done 0) (setq selected (extern-call gtk_drop_down_get_selected (ptr-read-u64 sw 16))) 0)
       (if (= _done 0) (if (< selected (ptr-read-u32 sw 72)) (progn
							       (if (= _done 0) (extern-call wcsncpy (+ out 0) (ptr-read-u64 (+ (extern-call skkui_engine_choices) (* (ptr-read-u32 (+ sw 40) (* selected 4)) 32)) 0) (- 260 1)) 0)
							       (if (= _done 0) (ptr-write-u16 (+ out 0) (* (- 260 1) 2) 0) 0)) 0) 0)
       (if (= _done 0) (if (ptr-read-u64 sw 80) (progn
						  (if (= _done 0) (ptr-write-u32 out 520 (if (extern-call gtk_check_button_get_active (ptr-read-u64 sw 80)) 1 0)) 0)) 0) 0)
       (if (= _done 0) (if (ptr-read-u64 sw 88) (progn
						  (if (= _done 0) (ptr-write-u32 out 524 (extern-call gtk_spin_button_get_value_as_int (ptr-read-u64 sw 88))) 0)) 0) 0)
       (if (= _done 0) (if (ptr-read-u64 sw 96) (progn
						  (if (= _done 0) (ptr-write-u32 out 528 (if (extern-call gtk_check_button_get_active (ptr-read-u64 sw 96)) 1 0)) 0)) 0) 0)
       (if (= _done 0) (ptr-write-u32 out 532 (if (extern-call gtk_check_button_get_active (ptr-read-u64 sw 104)) 1 0)) 0)
       (if (= _done 0) (ptr-write-u32 out 536 (if (extern-call gtk_check_button_get_active (ptr-read-u64 sw 120)) 1 0)) 0)
       (if (= _done 0) (ptr-write-u32 out 540 (if (extern-call gtk_check_button_get_active (ptr-read-u64 sw 128)) 1 0)) 0)
       (if (= _done 0) (ptr-write-u32 out 544 (if (extern-call gtk_check_button_get_active (ptr-read-u64 sw 136)) 1 0)) 0)
       (if (= _done 0) (ptr-write-u32 out 548 (if (extern-call gtk_check_button_get_active (ptr-read-u64 sw 144)) 1 0)) 0)
       (if (= _done 0) (ptr-write-u32 out 552 (if (extern-call gtk_check_button_get_active (ptr-read-u64 sw 152)) 1 0)) 0)
       (if (= _done 0) (ptr-write-u32 out 556 (extern-call gtk_spin_button_get_value_as_int (ptr-read-u64 sw 160))) 0)
       (if (= _done 0) (ptr-write-u32 out 560 (extern-call gtk_spin_button_get_value_as_int (ptr-read-u64 sw 168))) 0)
       (if (= _done 0) (ptr-write-u64 out 568 (extern-call rgba_to_packed (ptr-read-u64 sw 176))) 0)
       (if (= _done 0) (ptr-write-u64 out 576 (extern-call rgba_to_packed (ptr-read-u64 sw 184))) 0)
       (if (= _done 0) (ptr-write-u64 out 584 (extern-call rgba_to_packed (ptr-read-u64 sw 192))) 0)
       (if (= _done 0) (ptr-write-u64 out 592 (extern-call rgba_to_packed (ptr-read-u64 sw 200))) 0)
       (if (= _done 0) (ptr-write-u64 out 600 (extern-call rgba_to_packed (ptr-read-u64 sw 208))) 0)
       (if (= _done 0) (ptr-write-u32 out 608 (if (extern-call gtk_check_button_get_active (ptr-read-u64 sw 216)) 1 0)) 0)
       (if (= _done 0) (extern-call utf8_to_wide (extern-call gtk_editable_get_text (ptr-read-u64 sw 224)) (+ out 612) 260) 0)
       (if (= _done 0) (ptr-write-u32 out 1132 (extern-call gtk_spin_button_get_value_as_int (ptr-read-u64 sw 232))) 0)
       (if (= _done 0) (extern-call utf8_to_wide (extern-call gtk_editable_get_text (ptr-read-u64 sw 240)) (+ out 1136) 260) 0)
       (if (= _done 0) (ptr-write-u32 out 1656 (extern-call gtk_spin_button_get_value_as_int (ptr-read-u64 sw 248))) 0)
       (if (= _done 0) (ptr-write-u32 out 1660 (extern-call gtk_spin_button_get_value_as_int (ptr-read-u64 sw 256))) 0)
       (if (= _done 0) (ptr-write-u32 out 1664 (if (extern-call gtk_check_button_get_active (ptr-read-u64 sw 264)) 1 0)) 0))

     _result))
 (defun skkui_restart_poll (user_data)
   (let ((_done 0) (_result 0) (rp 0) (response (extern-call g_malloc0 8192)))
     (progn
       (if (= _done 0) (setq rp user_data) 0)
       (if (/= (ptr-read-u64 (ptr-read-u64 (ptr-read-u64 rp 0) 0) 48) (ptr-read-u64 rp 16))
	   (progn (extern-call g_object_unref (ptr-read-u64 rp 16))
		  (extern-call g_free rp) (setq _result 0) (setq _done 1)) 0)
       (if (= _done 0) (if (extern-call pipe_client_transact (+ (ptr-read-u64 (ptr-read-u64 rp 0) 0) 56) (data-addr sn_str_59) response 8192) (progn
																		(if (= _done 0) (extern-call gtk_label_set_text (ptr-read-u64 (ptr-read-u64 rp 0) 328) (data-addr sn_str_60)) 0)
																		(if (= _done 0) (progn (extern-call g_object_unref (ptr-read-u64 rp 16)) (extern-call g_free rp)) 0)
																		(if (= _done 0) (progn (setq _result 0) (setq _done 1)) 0)) 0) 0)
       (if (= _done 0) (ptr-write-u32 rp 8 (+ (ptr-read-u32 rp 8) 400)) 0)
       (if (= _done 0) (if (>= (ptr-read-u32 rp 8) 20000) (progn
							    (if (= _done 0) (extern-call gtk_label_set_text (ptr-read-u64 (ptr-read-u64 rp 0) 328) (data-addr sn_str_61)) 0)
							    (if (= _done 0) (progn (extern-call g_object_unref (ptr-read-u64 rp 16)) (extern-call g_free rp)) 0)
							    (if (= _done 0) (progn (setq _result 0) (setq _done 1)) 0)) 0) 0)
       (if (= _done 0) (progn (setq _result 1) (setq _done 1)) 0))
     (extern-call g_free response)
     _result))
 (defun skkui_restart_engine_and_wait (sw)
   (let ((_done 0) (_result 0) (response (extern-call g_malloc0 64)) (rp 0))
     (progn
       (if (= _done 0) (extern-call pipe_client_transact (+ (ptr-read-u64 sw 0) 56) (data-addr sn_str_62) response 64) 0)
       (if (= _done 0) (extern-call skkui_spawn_engine_host ) 0)
       (if (= _done 0) (extern-call gtk_label_set_text (ptr-read-u64 sw 328) (data-addr sn_str_63)) 0)
       (if (= _done 0) (setq rp (extern-call g_malloc0 24)) 0)
       (if (= _done 0) (ptr-write-u64 rp 0 sw) 0)
       (if (= _done 0) (ptr-write-u64 rp 16 (extern-call g_object_ref (ptr-read-u64 sw 8))) 0)
       (if (= _done 0) (extern-call g_timeout_add 400 (extern-call skkui_callback_address 5) rp) 0))
     (extern-call g_free response)
     _result))
 (defun on_apply_clicked (button user_data)
   (let ((_done 0) (_result 0) (sw 0) (s (extern-call g_malloc0 1672)) (engine_changed 0) (text (extern-call g_malloc0 16)) (files_ok 0) (ok 0))
     (progn
       (if (= _done 0) (setq sw user_data) 0)
       (if (= _done 0) (extern-call settings_read_from_widgets sw (+ s 0)) 0)
       (if (= _done 0) (setq engine_changed (/= (extern-call wcscmp (+ (+ (ptr-read-u64 sw 0) 1096) 0) (+ (+ s 0) 0)) 0)) 0)
       (if (= _done 0) (progn (ptr-write-u32 text 0 (= (extern-call gtk_check_button_get_active (ptr-read-u64 sw 288)) 0)) (ptr-write-u32 text 4 (extern-call gtk_check_button_get_active (ptr-read-u64 sw 296))) (ptr-write-u32 text 8 (extern-call gtk_check_button_get_active (ptr-read-u64 sw 304))) (ptr-write-u32 text 12 (extern-call gtk_drop_down_get_selected (ptr-read-u64 sw 312)))) 0)
       (if (= _done 0) (setq files_ok (extern-call text_settings_save (+ text 0) (+ sw 272))) 0)
       (if (= _done 0) (setq ok (and (extern-call settings_save (+ s 0)) files_ok)) 0)
       (if (= _done 0) (extern-call on_text_status 0 sw) 0)
       (if (= _done 0) (extern-call memcpy (+ (ptr-read-u64 sw 0) 1096) (+ s 0) 1672) 0)
       (if (= _done 0) (extern-call app_sync_pill_visibility (ptr-read-u64 sw 0)) 0)
       (if (= _done 0) (if (ptr-read-u64 (ptr-read-u64 sw 0) 16) (extern-call gtk_widget_queue_draw (ptr-read-u64 (ptr-read-u64 sw 0) 16)) 0) 0)
       (if (= _done 0) (if engine_changed (extern-call skkui_restart_engine_and_wait sw) 0) 0)
       (if (= _done 0) (if (and engine_changed ok) (progn (setq _result 0) (setq _done 1)) 0) 0)
       (if (= _done 0) (extern-call gtk_label_set_text (ptr-read-u64 sw 328) (if (= ok 0) (data-addr sn_str_64) (if engine_changed (data-addr sn_str_65) (data-addr sn_str_66)))) 0))
     (extern-call g_free s)
     (extern-call g_free text)
     _result))
 (defun on_restart_engine_clicked (button user_data)
   (let ((_done 0) (_result 0) (sw 0) (response (extern-call g_malloc0 64)))
     (progn
       (if (= _done 0) (setq sw user_data) 0)
       (if (= _done 0) (extern-call pipe_client_transact (+ (ptr-read-u64 sw 0) 56) (data-addr sn_str_67) response 64) 0)
       (if (= _done 0) (extern-call gtk_label_set_text (ptr-read-u64 sw 328) (data-addr sn_str_68)) 0))
     (extern-call g_free response)
     _result))
 (defun close_settings_window (app)
   (let ((_done 0) (_result 0) (settings_only 0) (window 0))
     (progn
       (if (= _done 0) (if (= (ptr-read-u64 app 48) 0) (progn (setq _result 0) (setq _done 1)) 0) 0)
       (if (= _done 0) (setq settings_only (ptr-read-u32 app 2796)) 0)
       (if (= _done 0) (setq window (ptr-read-u64 app 48)) 0)
       (if (= _done 0) (ptr-write-u64 app 48 0) 0)
       (if (= _done 0) (extern-call gtk_window_destroy window) 0)
       (if (= _done 0) (if (and settings_only (ptr-read-u64 app 0)) (extern-call g_application_quit (ptr-read-u64 app 0)) 0) 0))

     _result))
 (defun on_close_clicked (button user_data)
   (let ((_done 0) (_result 0) (sw 0))
     (progn
       (if (= _done 0) (setq sw user_data) 0)
       (if (= _done 0) (extern-call close_settings_window (ptr-read-u64 sw 0)) 0))

     _result))
 (defun on_settings_close_request (window user_data)
   (let ((_done 0) (_result 0) (sw 0))
     (progn
       (if (= _done 0) (setq sw user_data) 0)
       (if (= _done 0) (extern-call close_settings_window (ptr-read-u64 sw 0)) 0)
       (if (= _done 0) (progn (setq _result 1) (setq _done 1)) 0))

     _result))
 (defun open_settings_window (app)
   (let ((_done 0) (_result 0) (sw 0) (window 0) (root_box 0) (notebook 0) (button_box 0) (restart_button 0) (apply_button 0) (close_button 0))
     (progn
       (if (= _done 0) (if (ptr-read-u64 app 48) (progn
						   (if (= _done 0) (extern-call gtk_window_present (ptr-read-u64 app 48)) 0)
						   (if (= _done 0) (progn (setq _result 0) (setq _done 1)) 0)) 0) 0)
       (if (= _done 0) (setq sw (extern-call g_malloc0 336)) 0)
       (if (= _done 0) (ptr-write-u64 sw 0 app) 0)
       (if (= _done 0) (extern-call text_settings_load (+ sw 272)) 0)
       (if (= _done 0) (setq window (if (and (ptr-read-u32 app 2796) (ptr-read-u64 app 0)) (extern-call gtk_application_window_new (ptr-read-u64 app 0)) (extern-call gtk_window_new ))) 0)
       (if (= _done 0) (ptr-write-u64 sw 8 window) 0)
       (if (= _done 0) (ptr-write-u64 app 48 window) 0)
       (if (= _done 0) (extern-call skkui_set_settings_title window) 0)
       (if (= _done 0) (extern-call gtk_window_set_default_size window 480 360) 0)
       (if (= _done 0) (extern-call g_object_set_data_full window (data-addr sn_str_70) sw (extern-call skkui_callback_address 6)) 0)
       (if (= _done 0) (extern-call g_signal_connect_data window (data-addr sn_str_71) (extern-call skkui_callback_address 7) sw 0 0) 0)
       (if (= _done 0) (setq root_box (extern-call gtk_box_new 1 0)) 0)
       (if (= _done 0) (extern-call gtk_window_set_child window root_box) 0)
       (if (= _done 0) (setq notebook (extern-call gtk_notebook_new )) 0)
       (if (= _done 0) (extern-call gtk_widget_set_vexpand notebook 1) 0)
       (if (= _done 0) (extern-call gtk_notebook_append_page notebook (extern-call build_tab_behavior sw) (extern-call gtk_label_new (data-addr sn_str_72))) 0)
       (if (= _done 0) (extern-call gtk_notebook_append_page notebook (extern-call build_tab_display sw) (extern-call gtk_label_new (data-addr sn_str_73))) 0)
       (if (= _done 0) (extern-call gtk_notebook_append_page notebook (extern-call build_tab_dictionary sw) (extern-call gtk_label_new (data-addr sn_str_74))) 0)
       (if (= _done 0) (extern-call gtk_notebook_append_page notebook (extern-call build_tab_maintenance sw) (extern-call gtk_label_new (data-addr sn_str_75))) 0)
       (if (= _done 0) (extern-call gtk_notebook_append_page notebook (extern-call build_tab_text sw 1) (extern-call gtk_label_new (data-addr sn_str_76))) 0)
       (if (= _done 0) (extern-call gtk_notebook_append_page notebook (extern-call build_tab_text sw 0) (extern-call gtk_label_new (data-addr sn_str_77))) 0)
       (if (= _done 0) (extern-call gtk_box_append root_box notebook) 0)
       (if (= _done 0) (ptr-write-u64 sw 328 (extern-call gtk_label_new (data-addr sn_str_78))) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_start (ptr-read-u64 sw 328) 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_end (ptr-read-u64 sw 328) 12) 0)
       (if (= _done 0) (extern-call gtk_label_set_wrap (ptr-read-u64 sw 328) 1) 0)
       (if (= _done 0) (extern-call gtk_box_append root_box (ptr-read-u64 sw 328)) 0)
       (if (= _done 0) (setq button_box (extern-call gtk_box_new 0 6)) 0)
       (if (= _done 0) (extern-call gtk_widget_set_halign button_box 2) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_top button_box 6) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_bottom button_box 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_start button_box 12) 0)
       (if (= _done 0) (extern-call gtk_widget_set_margin_end button_box 12) 0)
       (if (= _done 0) (setq restart_button (extern-call gtk_button_new_with_label (data-addr sn_str_79))) 0)
       (if (= _done 0) (extern-call g_signal_connect_data restart_button (data-addr sn_str_80) (extern-call skkui_callback_address 8) sw 0 0) 0)
       (if (= _done 0) (setq apply_button (extern-call gtk_button_new_with_label (data-addr sn_str_81))) 0)
       (if (= _done 0) (extern-call g_signal_connect_data apply_button (data-addr sn_str_82) (extern-call skkui_callback_address 9) sw 0 0) 0)
       (if (= _done 0) (setq close_button (extern-call gtk_button_new_with_label (data-addr sn_str_83))) 0)
       (if (= _done 0) (extern-call g_signal_connect_data close_button (data-addr sn_str_84) (extern-call skkui_callback_address 10) sw 0 0) 0)
       (if (= _done 0) (extern-call gtk_box_append button_box restart_button) 0)
       (if (= _done 0) (extern-call gtk_box_append button_box apply_button) 0)
       (if (= _done 0) (extern-call gtk_box_append button_box close_button) 0)
       (if (= _done 0) (extern-call gtk_box_append root_box button_box) 0)
       (if (= _done 0) (if (ptr-read-u32 app 2788) (extern-call skkui_window_selftest app sw notebook) (extern-call gtk_window_present window)) 0))

     _result))

 ;; Load the configured engine host, and launch only when both executable
 ;; fields are present. Win32 command quoting/process handles are primitives.
 (defun skkui_spawn_engine_host ()
   (let ((key (extern-call g_malloc0 1024))
         (host (extern-call g_malloc0 65536))
         (runner (extern-call g_malloc0 65536))
         (repo (extern-call g_malloc0 65536)))
     (extern-call settings_registry_path key 512)
     (extern-call reg_get_sz key (data-addr sn_host_exe) (data-addr sn_host_empty) host 32768)
     (extern-call reg_get_sz key (data-addr sn_host_runner) (data-addr sn_host_empty) runner 32768)
     (extern-call reg_get_sz key (data-addr sn_host_repo) (data-addr sn_host_empty) repo 32768)
     (if (and (/= (ptr-read-u16 host 0) 0) (/= (ptr-read-u16 runner 0) 0))
         (extern-call skkui_create_host host runner repo) 0)
     (extern-call g_free key)
     (extern-call g_free host)
     (extern-call g_free runner)
     (extern-call g_free repo)
     0))
 )
