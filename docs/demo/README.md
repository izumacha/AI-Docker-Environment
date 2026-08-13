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
終了する（壊れた録画を README に貼らないため）。原因調査用に `.cast` は残し、`.gif` は
`.cast` と食い違うので削除する。

削除された `.gif` の**由来はスクリプトが報告する**（復元できるかどうかが由来で変わるため）。

| 由来 | どの段階で失敗したか | 復元 |
| --- | --- | --- |
| 前回の実行の成果物 | `agg` に到達する前（録画自体の失敗・状態ファイル欠落・録画対象の失敗） | コミット済みなら `git restore` で戻せる |
| 今回の実行が生成 | `agg` が正常終了した後の検査で不合格（空・非 GIF・上限超過） | git には無いので `git restore` しない |
| 判別できない | `agg` が失敗した（書きかけかもしれないし、出力を開く前に落ちただけかもしれない） | コミット済みだった場合のみ `git restore` で戻せる |

**「今回の実行が生成」と報告された `.gif` に `git restore` を使わないこと。** 未コミットの
ファイルに対して実行すると、古いコミット済みの GIF が復活して `.cast` と食い違う（この
削除処理が防ごうとしている状態そのもの）。

**録画中の 3 つの確認は「見せるだけ」ではなく表明（assertion）である。**
`example.com` へ**到達できてしまった**場合（default-deny の退行）、`api.anthropic.com` へ
**到達できない**場合（許可リスト / DNS の退行）、そして `whoami` が `agent` **以外**を返した
場合（`gosu` 降格の退行 / SEC-7・AC-3）は、いずれもその場で失敗させる。ここを
`|| echo` や `curl | head` で受け流したり、結果を表示するだけにすると、サンドボックスが
壊れていても成功扱いになり、「安全に隔離されている」と誤って宣伝する GIF ができてしまう
（降格確認を表示だけにしていた期間は、`whoami` が `root` と出ている GIF が
「`agent` へ降格している証拠」として生成されうる状態だった）。

GIF の幅を撮影者の端末幅に依存させないよう、録画前に端末を 120 桁 × 30 行へ固定し、
終了時に元のサイズへ戻す（`RECORD_COLS` / `RECORD_ROWS`）。ただし**元に戻せないときは
固定しない**: 標準入力・標準出力のどちらかが端末でない場合や、`stty size` が復元に使える値
（「行 桁」の正の整数 2 つ）を返さない場合（winsize 未設定の pty は `0 0` を返す）は、
リサイズを行わずに警告を出す。この場合だけ GIF の幅が撮影環境に依存するので、README へ
貼る録画はこの警告が出ていない環境で撮ること。録画中に画面へ出る文言は ASCII に揃えてある —
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
