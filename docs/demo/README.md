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

## 注意（撮影時の制約）

- **OAuth トークン・ホストの実パス（`$HOME` 配下の個人情報が分かるパス）を写さない。**
  スクリプトは中立な一時ディレクトリ（`/tmp/aidock-demo-workspace.*`）へ移動してから
  `aidock` を起動する。
- `aidock login` の OAuth フローと `aidock run` の Claude Code 対話画面は自動録画の対象外。
  必要なら手動で `asciinema rec -c './bin/aidock run' docs/demo/aidock-run.cast` のように録り、
  トークンやコードが写っていないことを確認してから公開する。
- 生成後は内容を目視確認し、問題なければ `.cast` / `.gif` をコミットして
  README のデモブロックの画像行を有効化する（README 内の TODO コメント参照）。
