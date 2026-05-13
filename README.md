# AI-Docker-Environment

Linux 上で **Claude Code (`@anthropic-ai/claude-code`)** をサンドボックス化した
Docker コンテナで動かすための一式。MulmoClaude のワークスペース分離と、
Anthropic 公式 devcontainer の `iptables`+`ipset` ベースの default-deny
allowlist を組み合わせている。

ユーザー自身の Claude アカウントで OAuth ログインし、その認証情報は
コンテナ内の名前付きボリュームに閉じる。ホストの `~/.ssh` や クラウド SDK の
資格情報は一切マウントしない。

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

## 脅威モデル / 設計の意図

| リスク | 対策 |
| --- | --- |
| ホスト FS の破壊 | bind mount は `$PWD` のみ。`read_only` rootfs + `tmpfs` |
| ホスト資格情報の流出 | `~/.ssh` / `~/.aws` / `gcloud` / `~/.gitconfig` を一切マウントしない |
| 任意外部送信 | iptables 既定 DROP + ipset allowlist (api.anthropic.com, npm, GitHub等のみ) |
| 暴走プロセス | `mem_limit=4g`, `pids_limit=1024`, `cpus=2.0`, `tini` で reap |
| 権限昇格 | `cap_drop: ALL` → `NET_ADMIN`/`NET_RAW` のみ復帰、`no-new-privileges`、scoped sudo (firewall script 1本のみ) |

### Allowlist 構成

`docker/init-firewall.sh` の `CORE_HOSTS` / `LOGIN_EXTRA_HOSTS` を編集して
ホストを増減できる。GitHub の CIDR ブロックは `https://api.github.com/meta`
から動的取得して ipset に追加 (jq + 正規表現で形式検証)。

## 防げないもの (既知の限界)

- **`/workspace` 内**はAIが書き換え自由。`.git` を含む。ホストの個人ホーム直下では起動しないこと。
- **IP 回転**: ipset は IP 単位なので CloudFront 等の CDN で IP が変わると
  接続が落ちる。`aidock firewall-refresh` で再解決。
- **デフォルト seccomp のみ**。カスタムプロファイル / AppArmor / user
  namespace remap は v1 では入れていない。
- **Linux 専用**。macOS/Windows 非対応 (Keychain 連携を入れていない)。
- **OAuth トークン**は `claude-home` 名前付きボリュームに保持。共有マシンでは
  使い終わったら `aidock logout` で破棄。

## ファイル構成

```
.
├── docker/
│   ├── Dockerfile          # node:22-slim ベース、agent ユーザー
│   ├── init-firewall.sh    # default-deny + ipset allowlist
│   └── entrypoint.sh       # firewall init -> exec
├── compose.yaml            # cap_drop / read_only / tmpfs / 制限
├── bin/aidock              # ラッパー CLI
├── .dockerignore
└── .gitignore
```

## カスタマイズ

- **メモリ上限**: `compose.yaml` の `mem_limit` / `NODE_OPTIONS`
- **CPU 上限**: 同 `cpus`
- **allowlist 追加**: `docker/init-firewall.sh` の `CORE_HOSTS` 配列
- **テレメトリ無効化**: `CORE_HOSTS` から `statsig.anthropic.com` / `sentry.io` を削除
- **Claude Code バージョン固定**: `docker/Dockerfile` の `ARG CLAUDE_CODE_VERSION`
