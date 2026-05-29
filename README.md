# AI-Docker-Environment

> 本リポジトリの **要件定義書（正本）** は [`docs/requirements.md`](docs/requirements.md)。
> 実装・ドキュメントは必ず要件定義に従うこと。要件を変える際は先に同書を改訂する。

Linux 上で **Claude Code (`@anthropic-ai/claude-code`)** をサンドボックス化した
Docker コンテナで動かすための一式。MulmoClaude のワークスペース分離と、
Anthropic 公式 devcontainer の `iptables`+`ipset` ベースの default-deny
allowlist を組み合わせている。

ユーザー自身の Claude アカウントで OAuth ログインし、その認証情報は
コンテナ内の名前付きボリュームに閉じる。ホストの `~/.ssh` や クラウド SDK の
資格情報は明示的に追加 bind mount しない。ただし `$PWD` は `/workspace:rw` として
渡されるため、`~/.ssh`、`~/.aws`、`~/.config/aws`、`~/.config/gcloud`、`~/.config/gh`、`~/.kube` 等の機密ディレクトリ
配下では `aidock` の起動を機械的に拒否する。

## クイックスタート

```bash
./bin/aidock build         # 自分の UID/GID でイメージを作成
./bin/aidock login         # 一度だけ OAuth ログイン (URLをブラウザで開いてコード貼り戻し)
cd ~/some-project
/path/to/AI-Docker-Environment/bin/aidock   # 対話セッション開始
```

`bin/aidock` を `PATH` に通しておくと便利。

## サブコマンド

| コマンド | 説明 |
| --- | --- |
| `aidock build` | ホストの UID/GID をビルド引数として渡しイメージを作成 |
| `aidock login` | `claude /login` を起動。OAuth 用に allowlist を一時的に広げる (`AIDOCK_PROFILE=login`) |
| `aidock` / `aidock run [args]` | 通常起動。`$PWD` を `/workspace` に bind mount |
| `aidock shell` | デバッグ用 bash シェル |
| `aidock firewall-refresh` | 起動中コンテナで firewall を再初期化 (DNS再解決) |
| `aidock logout` | OAuth 資格情報の名前付きボリュームを破棄 |

`$PWD` が `$HOME` または `/` のとき、ラッパーは起動を拒否する
(うっかり広域マウントの事故防止)。

`compose.yaml` の `HOST_WORKSPACE` にはデフォルト値がないため、`bin/aidock` を
経由せず `docker compose run claude` を**直接実行すると起動に失敗する**
(カレントディレクトリの暗黙マウント防止 / fail-closed)。直接実行する場合は
`HOST_WORKSPACE` を明示的に設定すること (例: `HOST_WORKSPACE="$PWD" docker compose ... run claude`)。
ただし `guard_workspace()` のガードは `bin/aidock` 経由でのみ働くため、通常は
`bin/aidock` の利用を推奨する。

## 脅威モデル / 設計の意図

| リスク | 対策 |
| --- | --- |
| ホスト FS の破壊 | bind mount は `$PWD` のみ。`read_only` rootfs + `tmpfs`。`HOST_WORKSPACE` はデフォルト値なし → `bin/aidock` 非経由の直接 `docker compose run` は fail-closed で起動失敗 |
| ホスト資格情報の流出 | `~/.ssh` / `~/.aws` / `gcloud` / `~/.gitconfig` 等を追加 bind mount しない。`$HOME` と `/` は起動拒否。ただし機密ディレクトリ配下からの起動は禁止（機械的拒否は follow-up） |
| 任意外部送信 | iptables 既定 DROP + ipset allowlist (api.anthropic.com, npm, GitHub等のみ) |
| 暴走プロセス | `mem_limit=4g`, `pids_limit=1024`, `cpus=2.0`, `tini` で reap |
| 権限昇格 | `cap_drop: ALL` → `NET_ADMIN`/`NET_RAW`（+ 降格用 `SETUID`/`SETGID`）のみ復帰、`no-new-privileges`、entrypoint は root 起動 → `gosu` で agent 降格 (sudo 不使用) |

### Allowlist 構成

`docker/init-firewall.sh` の `CORE_HOSTS` / `LOGIN_EXTRA_HOSTS` を編集して
ホストを増減できる。GitHub の CIDR ブロックは `https://api.github.com/meta`
から動的取得して ipset に追加 (jq + 正規表現の形式検証に加え、各 octet 0-255 / prefix 0-32 の範囲検証を実施。範囲外はスキップ)。

## 防げないもの (既知の限界)

- **`/workspace` 内**はAIが書き換え自由。`.git` を含む。ホストの個人ホーム直下では起動しないこと。
- **IP 回転**: ipset は IP 単位なので CloudFront 等の CDN で IP が変わると
  接続が落ちる。`aidock firewall-refresh` で再解決。
- **デフォルト seccomp のみ**。カスタムプロファイル / AppArmor / user
  namespace remap は v1 では入れていない。
- **Linux 専用**。macOS/Windows 非対応 (Keychain 連携を入れていない)。
- **OAuth トークン**は `claude-home` 名前付きボリュームに保持。共有マシンでは
  使い終わったら `aidock logout` で破棄。

## CI

GitHub Actions で次を実行する。

- **`ci.yml`**
  - **type-check**: `shellcheck`（全シェルスクリプト）/ `hadolint`（`docker/Dockerfile`）/ `docker compose config`（`compose.yaml` 妥当性検証）。
  - **e2e**: イメージをビルドし、GitHub-hosted runner 上で受け入れ基準を実機検証する（`$HOME` / `/` 起動拒否、firewall プローブ、`agent` 権限・`sudo` 不在・capability 制限、資格情報ボリューム所有権）。
- **`post-ci-verify.yml`**: CI 成功後に Claude Code Action（`anthropics/claude-code-action@v1`）が起動し、結果を検証・要約して PR にコメントする。認証は Claude GitHub App + `CLAUDE_CODE_OAUTH_TOKEN` secret。`workflow_run` の仕様上 `main` マージ後に有効。

詳細・受け入れ基準は `docs/requirements.md` の FR-8 / FR-9 / AC-8 / AC-9 を参照。

## ファイル構成

```
.
├── .github/
│   └── workflows/
│       ├── ci.yml              # 型チェック + e2e
│       └── post-ci-verify.yml  # CI 後に Claude が結果を検証・要約して PR コメント
├── docker/
│   ├── Dockerfile          # node:22-slim ベース、agent ユーザー
│   ├── init-firewall.sh    # default-deny + ipset allowlist
│   └── entrypoint.sh       # firewall init -> exec
├── compose.yaml            # cap_drop / read_only / tmpfs / 制限
├── bin/aidock              # ラッパー CLI
├── docs/
│   └── requirements.md     # 要件定義書（正本 / Source of Truth）
├── .hadolint.yaml          # hadolint 設定（DL3008 除外）
├── .dockerignore
└── .gitignore
```

## カスタマイズ

- **メモリ上限**: `compose.yaml` の `mem_limit` / `NODE_OPTIONS`
- **CPU 上限**: 同 `cpus`
- **allowlist 追加**: `docker/init-firewall.sh` の `CORE_HOSTS` 配列
- **テレメトリ無効化**: `CORE_HOSTS` から `statsig.anthropic.com` / `sentry.io` を削除
- **Claude Code バージョン固定**: `docker/Dockerfile` の `ARG CLAUDE_CODE_VERSION`
