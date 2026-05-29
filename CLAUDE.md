# CLAUDE.md

このファイルは、本リポジトリで作業する AI アシスタント（Claude Code など）向けのガイドです。詳細なユーザー向け説明は `README.md` を参照してください。

> **正本（Source of Truth）は `docs/requirements.md`**。
> 実装・ドキュメント・新機能の提案はすべて要件定義書に従うこと。
> 要件と実装が衝突したら、**先に要件定義書を改訂してから実装を変更する**。
> 変更時は同 PR 内で `docs/requirements.md` の §3 / §4 / §6 を更新する。

## プロジェクト概要

`AI-Docker-Environment` は Linux ホスト上で **Claude Code (`@anthropic-ai/claude-code`)** を安全に実行するための Docker サンドボックスです。Anthropic 公式 devcontainer のセキュリティモデルを踏襲し、次の防御層を組み合わせています。

- **デフォルト拒否の egress ファイアウォール**（iptables + ipset 許可リスト）
- **最小権限モデル**（`cap_drop: ALL`、`no-new-privileges`、root 起動 → `gosu` で agent 降格・sudo 不使用）
- **ファイルシステム分離**（read-only rootfs + tmpfs、`$PWD` のみ bind mount）
- **リソース上限**（メモリ 4G、CPU 2 コア、PID 1024）
- **OAuth 資格情報の隔離**（名前付きボリューム `claude-home` に保存）

ホストの `~/.ssh` や `~/.aws`、`~/.config/aws`、`~/.config/gcloud` 等を **追加 bind mount しません**。ただし `$PWD` は `/workspace:rw` として渡されるため、機密ディレクトリ配下では `aidock` は起動を機械的に拒否する（詳細は `docs/requirements.md` SEC-8）。Linux 専用（macOS/Windows 非対応）。

## リポジトリ構成

```
.
├── bin/aidock              # CLI ラッパー (bash)
├── docker/
│   ├── Dockerfile          # node:22-slim ベース、claude-code を npm -g
│   ├── init-firewall.sh    # iptables + ipset の許可リスト構築
│   └── entrypoint.sh       # firewall 初期化 → exec
├── compose.yaml            # サービス定義 + セキュリティオプション
├── docs/
│   └── requirements.md     # 要件定義書（正本 / Source of Truth）
├── README.md               # 日本語の詳細ドキュメント
├── .dockerignore / .gitignore
└── CLAUDE.md               # このファイル
```

ソースコードは bash スクリプトと Docker 関連ファイルのみ。アプリケーションコード（Python/JS 等）はありません。

## 主要コマンド

すべて `bin/aidock` 経由で実行します。テストランナー・Makefile・npm scripts はありません。

| コマンド | 用途 |
|---|---|
| `./bin/aidock build` | イメージビルド（`HOST_UID`/`HOST_GID` を `id -u`/`id -g` で注入） |
| `./bin/aidock login` | 初回 OAuth ログイン（`AIDOCK_PROFILE=login` で許可リスト一時拡張） |
| `./bin/aidock` / `./bin/aidock run [args]` | `$PWD` を `/workspace` に bind mount して Claude Code 起動（デフォルト） |
| `./bin/aidock shell` | デバッグ用の bash シェル |
| `./bin/aidock firewall-refresh` | 稼働中コンテナ内で `init-firewall.sh` を再実行（DNS ローテーション対応） |
| `./bin/aidock logout` | `claude-home` ボリュームを削除し OAuth 資格情報を破棄 |

`bin/aidock` には `$HOME` および `/` を `/workspace` としてマウントしないガードが組み込まれています。これは削除してはいけません（`bin/aidock` の `guard_workspace()` 参照）。

## セキュリティ不変条件（編集時に必ず守る）

以下は脆弱化につながるため **変更禁止**、または変更する場合は必ず影響を検討してください。

- `compose.yaml`:
  - `cap_drop: ALL` / `cap_add: [NET_ADMIN, NET_RAW, SETUID, SETGID]` のみ（`SETUID`/`SETGID` は entrypoint の `gosu` による root→agent 降格用）
  - `security_opt: no-new-privileges:true`
  - `read_only: true` + 必要最小限の `tmpfs`
  - `mem_limit`, `pids_limit`, `cpus` の上限
  - ホストパスの追加 bind mount は原則禁止（特に `~/.ssh`、`~/.aws`、`~/.gitconfig` 等）
  - `/workspace` マウントの `HOST_WORKSPACE` に**デフォルト値を付けない**（`${HOST_WORKSPACE:?...}`）。`bin/aidock` 非経由の直接 `docker compose run` を fail-closed にする SEC-8 一次防御 (a)。`bin/aidock` の `compose()` ラッパーが必ず値を供給する
- `docker/Dockerfile` / `docker/entrypoint.sh`:
  - コンテナに `sudo` を含めない。entrypoint を root で起動し firewall 初期化後に `gosu agent` で降格する（setuid 昇格を使わない）
  - ワークロード（claude-code）は `agent` で実行する。root では実行しない
- `docker/init-firewall.sh`:
  - `iptables -P OUTPUT DROP`（デフォルト拒否）を維持
  - 終端の検証プローブ（`example.com` ブロック確認、`api.anthropic.com` 到達確認）を維持
  - 許可ホスト追加は `CORE_HOSTS` / `LOGIN_EXTRA_HOSTS` に追記。新規ホストを追加する際は最小限に留め、PR の説明で理由を述べる
- `bin/aidock`:
  - `guard_workspace()` の `/` および `$HOME` 拒否を維持

OAuth トークンは必ず名前付きボリューム `claude-home` に置き、ホスト FS や Docker イメージ層に書き出さないこと。

## 設定とカスタマイズ

環境変数（`bin/aidock` または `compose.yaml` 経由）:

- `AIDOCK_PROFILE` — `run`（デフォルト）または `login`。`login` 時のみ `claude.ai` 等の OAuth ホストを許可
- `HOST_UID` / `HOST_GID` — `bin/aidock` が自動検出
- `HOST_WORKSPACE` — `/workspace` にマウントするホストディレクトリ。`compose.yaml` 側にデフォルト値はなく（`${HOST_WORKSPACE:?...}`）、`bin/aidock` が設定する（run/login/shell は guard 通過後の `$PWD`、build/logout/firewall-refresh は非機密プレースホルダ）。`bin/aidock` 非経由の直接 `docker compose run` は fail-closed で起動失敗する（SEC-8 一次防御 (a)）
- `AIDOCK_SKIP_FIREWALL=1` — ファイアウォール初期化をスキップ（デバッグ用途のみ）

主な調整箇所:

- リソース上限: `compose.yaml` の `mem_limit` / `cpus` / `pids_limit` / `NODE_OPTIONS`
- Claude Code バージョン: `docker/Dockerfile` の `ARG CLAUDE_CODE_VERSION`
- テレメトリ抑制: `docker/init-firewall.sh` の `CORE_HOSTS` から `statsig.anthropic.com` / `sentry.io` を削除

## コーディング規約

- 全スクリプトは Bash、先頭で `set -euo pipefail`
- ログは stderr に出力（`init-firewall.sh` の `log()` 関数を参照）
- インデントは 4 スペース、タブは使わない
- リンター/フォーマッターの設定ファイルは未配置（手動レビューに依存）
- 日本語のユーザー向けドキュメントを更新する場合は `README.md` を、AI 向け規約を更新する場合はこの `CLAUDE.md` を編集

## 既知の制約

- **Linux 専用**: iptables/ipset/cap_add に依存。macOS Docker Desktop では動作しません
- `/workspace` 配下の `.git` を含むファイルは AI 側から書き換え可能（コミット内容は要レビュー）
- CDN の IP ローテーションで疎通が壊れた場合は `./bin/aidock firewall-refresh`
- seccomp はデフォルトのみ（カスタムプロファイル、AppArmor、user namespace remap は未設定）
- 共有マシンでは作業終了時に `./bin/aidock logout` を必須化

## Git ワークフロー

- CI は GitHub Actions（`.github/workflows/ci.yml`）で **型チェック**（shellcheck / hadolint / `docker compose config`）と **e2e**（受け入れ基準 AC-1〜AC-4 / AC-7 の実機検証）を実行する。詳細は `docs/requirements.md` の FR-8 / AC-8。CI（`ci.yml`）から codex へコメント投稿はしない（FR-7）
- CI 成功後、`.github/workflows/post-ci-verify.yml` が Claude Code Action（`anthropics/claude-code-action@v1`）を起動し、type-check / e2e 結果を検証・要約して PR にコメントする（FR-9 / AC-9）。認証は Claude GitHub App + `CLAUDE_CODE_OAUTH_TOKEN` secret。`workflow_run` の仕様上 `main` マージ後に有効。codex（コードレビュー）とは別物
- pre-commit フックは未設定
- コミットメッセージは英語・命令形・1 行要約（既存履歴に倣う）
- 開発は機能ブランチで行い、`main` への直 push は避ける
- **codex 自動レビュー** は `chatgpt-codex-connector[bot]` がリポジトリレベルで有効化されているが、トリガとして使える経路は限られる:
  - **PR を draft → ready に変える**（誰の操作でも発火する）
  - **Codex 接続済みアカウントから `@codex review` コメントを投稿**
  - `github-actions[bot]` / 一般の bot 名義の `@codex review` コメントは **拒否される** ため、workflow による自動投稿は機能しない。
  - Claude の GitHub MCP 操作が izumacha 名義（OWNER）で記録される実行環境では、Claude が投稿する `@codex review` も Codex に受理される（実証済み）。**運用ルール: Claude は差分 push を伴う報告コメントの末尾に `@codex review` を追記し、再レビューを発火させる**（質問返信や再レビュー不要な状況報告には付けない）。初回レビューは draft → ready 化で発火。Claude の操作が bot 名義になる環境では従来どおり izumacha の手動 ready 化 / `@codex review` が必要。
