# SnippetMenu

クリップボードを使わずに定型文を入力できる、macOSのメニューバーアプリです。コピーした内容はそのまま残るので、定型文を入れたあとも`⌘V`で貼り付けられます。

配布ページ: https://neuvecom.github.io/snippet-menu/

## 機能

- メニューバーのアイコンから定型文を入力
- `⌥`+右クリック、または`⌃⌥V`でカーソル位置にメニューを表示
- タイトルを`分類/名前`にするとサブメニューに整理
- 日本語入力がオンのままでも入力可能

## 動作環境

- macOS 13以降
- Apple Siliconで動作確認済み

## インストール

1. [最新版のSnippetMenu.zip](https://github.com/neuvecom/snippet-menu/releases/latest/download/SnippetMenu.zip)をダウンロードして展開します。
2. `SnippetMenu.app`を「アプリケーション」フォルダへ移動して開きます。
3. Appleの公証を受けていないため、ブロックされた場合は「システム設定」→「プライバシーとセキュリティ」→「このまま開く」を選びます。
4. 「アクセシビリティ」でSnippetMenuを許可します。

## ソースからビルド

Xcodeのコマンドラインツールが必要です。

```bash
./build.sh
```

`~/Applications`にインストールされ、そのまま起動します。

## 仕組み

入力欄へアクセシビリティ機能で直接挿入します。対応していないアプリでは、キー入力として送ります。どちらの方法でもクリップボードは使いません。

キー入力で送るときの改行は、チャットアプリでの誤送信を防ぐため`Shift+Return`です。シェルでは改行で行が実行される場合があるため、複数行の定型文には注意してください。

定型文は`~/Library/Application Support/SnippetMenu/snippets.json`に保存され、外部には送信されません。

## ライセンス

[MIT](LICENSE)
