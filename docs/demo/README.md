# デモ録画（asciinema / GIF）

README 冒頭のデモブロックに載せる端末録画の置き場所と生成手順。

## 生成物

| ファイル | 説明 |
| --- | --- |
| `aidock-demo.cast` | asciinema 形式の録画（asciinema.org にアップロードも可） |
| `aidock-demo.gif` | README 埋め込み用 GIF（10MB 以下に最適化） |

## 生成手順

Docker デーモンが動く **Linux ホスト**で、リポジトリルートから:

```bash
./docs/demo/record-demo.sh
```

依存: [asciinema](https://asciinema.org/)（例: `pipx install asciinema`）と
[agg](https://github.com/asciinema/agg)（cast → GIF 変換）。

録画される代表フロー（CLAUDE.md「見せ方（§15 の具体化）」に対応）:

1. `aidock build` — イメージビルド（`HOST_UID`/`HOST_GID` 注入）
2. `aidock shell` — コンテナ起動 → ファイアウォール初期化 → `agent` ユーザー確認、
   許可外ホスト（`example.com`）の遮断確認と `api.anthropic.com` への到達確認

録画は**失敗したら止まる**（fail-closed）。`asciinema rec` は録画対象コマンドの終了コードを
引き継がないため、スクリプトはステップ側の終了コードを別途受け取り、非ゼロなら GIF を作らずに
終了する（壊れた録画を README に貼らないため）。原因調査用に `.cast` は残し、前回の実行で
できた `.gif` は `.cast` と食い違うので削除する（`git restore` で戻せる）。

**録画中の 2 つの確認は「見せるだけ」ではなく表明（assertion）である。**
`example.com` へ**到達できてしまった**場合（default-deny の退行）と、`api.anthropic.com` へ
**到達できない**場合（許可リスト / DNS の退行）は、いずれもその場で失敗させる。ここを
`|| echo` や `curl | head` で受け流すと、サンドボックスが壊れていても成功扱いになり、
「安全に隔離されている」と誤って宣伝する GIF ができてしまう。

GIF の幅を撮影者の端末幅に依存させないよう、録画前に端末を 120 桁 × 30 行へ固定する
（`RECORD_COLS` / `RECORD_ROWS`）。録画中に画面へ出る文言は ASCII に揃えてある —
`agg` の既定フォントは日本語グリフを持たず、CJK を混ぜると豆腐（□）になるため。

## 注意（撮影時の制約）

- **OAuth トークン・ホストの実パス（`$HOME` 配下の個人情報が分かるパス）を写さない。**
  スクリプトは中立な一時ディレクトリ（`/tmp/aidock-demo-workspace.*`）へ移動してから
  `aidock` を起動する。
- `aidock login` の OAuth フローと `aidock run` の Claude Code 対話画面は自動録画の対象外。
  必要なら手動で `asciinema rec -c './bin/aidock run' docs/demo/aidock-run.cast` のように録り、
  トークンやコードが写っていないことを確認してから公開する。
- 生成後は内容を目視確認し、問題なければ `.cast` / `.gif` をコミットして
  README のデモブロックの TODO コメントを画像行へ置き換える（手順は README 内の
  TODO コメント本文に書いてある）。
