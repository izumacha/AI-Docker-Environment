# AI-Docker-Environment 要件定義書

本書は `AI-Docker-Environment` における **すべての実装が従うべき正本（Source of Truth）** である。
コード（`bin/aidock` / `compose.yaml` / `docker/**`）・ドキュメント（`README.md` / `CLAUDE.md`）・新機能の提案は、本書と矛盾してはならない。
変更が必要な場合は **先に本書を改訂し、PR 内で根拠を述べた上で実装に着手する**。

- **対象バージョン**: v1 系（Linux 専用、Claude Code 公式 CLI を Docker でサンドボックス化）
- **最終更新**: 2026-05-19
- **位置づけ**: 要件 ＞ 設計 ＞ 実装。本書未記載の事項は CLAUDE.md / README.md の記述に従う。

---

## 0. 用語

| 用語 | 定義 |
| --- | --- |
| ホスト | `aidock` を実行する Linux マシン。 |
| サンドボックス | `aidock/claude:local` イメージから起動するコンテナ。 |
| `agent` ユーザー | コンテナ内の非 root 実行ユーザー。UID/GID はホストと一致。 |
| allowlist | iptables + ipset で許可する egress 宛先集合（既定は拒否）。 |
| プロファイル | `AIDOCK_PROFILE` 環境変数。`run`（既定）か `login`。 |
| `claude-home` | OAuth 資格情報を保持する Docker 名前付きボリューム。 |

---

## 1. 目的とスコープ

### 1.1 目的
- ホスト OS を保護したまま、`@anthropic-ai/claude-code` をユーザー自身の Claude アカウントで実行できる **再現可能なサンドボックス** を提供する。
- 既定で外部送信を遮断し、明示的に許可した宛先のみ通信させる。
- ホスト上の秘匿情報（SSH 鍵、クラウド資格情報、git 設定など）を **一切コンテナへ渡さない**。

### 1.2 スコープ内
- Docker コンテナ定義（`compose.yaml` / `Dockerfile`）。
- egress ファイアウォール初期化（`init-firewall.sh`）。
- CLI ラッパー（`bin/aidock`）。
- OAuth 資格情報の隔離（名前付きボリューム）。

### 1.3 スコープ外（v1 では非対応）
- macOS / Windows サポート。
- カスタム seccomp / AppArmor プロファイル、user namespace remap。
- マルチユーザー / マルチプロジェクト同時実行のためのオーケストレーション。
- Claude Code 以外の AI CLI（Gemini CLI 等）のサポート。
- CI/CD パイプライン、pre-commit フック、テストランナー。

---

## 2. ステークホルダーと利用シナリオ

### 2.1 想定ユーザー
- Linux を業務利用する個人開発者およびセキュリティ意識の高いエンジニア。
- 複数プロジェクトを `cd` で切り替えながら Claude Code を使う想定。

### 2.2 主要ユースケース
1. **初回セットアップ**: `aidock build` → `aidock login` → OAuth コード貼付。
2. **日常利用**: 任意のプロジェクトディレクトリで `aidock` を起動し対話。
3. **デバッグ**: `aidock shell` でコンテナ内に入り環境を点検。
4. **CDN IP 変動への対処**: `aidock firewall-refresh` で allowlist を再構築。
5. **資格情報破棄**: `aidock logout` で `claude-home` ボリュームを削除。

---

## 3. 機能要件（FR）

### FR-1: CLI サブコマンド
`bin/aidock` は以下を提供する。実装変更時は `usage()` と README の表を必ず同期させる。

| ID | コマンド | 必須挙動 |
| --- | --- | --- |
| FR-1.1 | `build` | `HOST_UID`/`HOST_GID` を build args として `docker compose build` を実行。 |
| FR-1.2 | `login` | `AIDOCK_PROFILE=login` を立て、`compose run --rm claude claude /login` を実行。 |
| FR-1.3 | `run [args...]` / 引数なし | `$PWD` を `/workspace` に bind mount して Claude Code を起動。`run` は既定サブコマンド。 |
| FR-1.4 | `shell` / `bash` | 同マウントで bash を起動。 |
| FR-1.5 | `firewall-refresh` | 稼働中コンテナ内で `init-firewall.sh` を再実行（DNS 再解決）。 |
| FR-1.6 | `logout` | `compose down -v` 後に `aidock_claude-home` ボリュームを `docker volume rm`。 |
| FR-1.7 | `help` / `-h` / `--help` | `usage` を表示。 |
| FR-1.8 | 未知のサブコマンド | エラーメッセージを stderr に出力し exit code 1。 |

### FR-2: ワークスペースマウント
- `$PWD` を `/workspace:rw` に bind mount する（`compose.yaml` の `HOST_WORKSPACE`）。
- FR-2.1: **`/` を `/workspace` としてマウントしてはならない**。検知時は exit code 2 で拒否（`guard_workspace`）。
- FR-2.2: **`$HOME` を `/workspace` としてマウントしてはならない**。同上。
- FR-2.3: `$HOME` / `/` 以外への追加 bind mount を勝手に増やさない（特に `~/.ssh`・`~/.aws`・`~/.gitconfig`・`~/.config/gh` 等）。

### FR-3: OAuth 資格情報
- `claude-home` という名前付きボリュームを `/home/agent/.claude` にマウントする。
- FR-3.1: 資格情報はホスト FS にも Docker イメージ層にも書き出さない。
- FR-3.2: `logout` で同ボリュームを破棄できる。

### FR-4: ファイアウォール初期化
- コンテナ起動時、`AIDOCK_SKIP_FIREWALL=1` でない限り `init-firewall.sh` を実行する。
- FR-4.1: 既定で `INPUT`/`FORWARD`/`OUTPUT` を `DROP`。
- FR-4.2: loopback、`ESTABLISHED,RELATED`、DNS(53/udp,tcp) のみ恒久許可。
- FR-4.3: `CORE_HOSTS` 全件を DNS 解決し ipset `allowed-hosts` に投入。
- FR-4.4: `AIDOCK_PROFILE=login` の場合のみ `LOGIN_EXTRA_HOSTS` も投入。
- FR-4.5: GitHub `https://api.github.com/meta` から CIDR を取得し ipset へ追加（取得失敗時は warn のみで継続）。CIDR 文字列は `^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$` で検証してから追加。
- FR-4.6: 最後に検証プローブを実行。
  - `https://example.com` が **到達不能であること**（到達したら exit 1）。
  - `https://api.anthropic.com` が **TCP/TLS ハンドシェイク可能であること**（4xx は許容）。

### FR-5: ログ出力
- `init-firewall.sh` のログは `[firewall]` プレフィックスで **stderr** に出力する。
- 解決した IP・追加した CIDR・成功/失敗ステータスをユーザーが追跡できること。

### FR-6: ドキュメント整合
- `README.md` は利用者向け、`CLAUDE.md` は AI 向け、本書は要件の正本。
- 機能を追加・削除・変更したら、**同じ PR 内で関連 doc を更新**する。

---

## 4. 非機能要件（NFR）

### NFR-1: セキュリティ不変条件（**絶対遵守 / Hard Constraints**）

以下を弱める変更は不可。やむを得ず変更する場合は本書を改訂し PR 説明で理由・代替策・残存リスクを明記する。

| ID | 内容 | 根拠ファイル |
| --- | --- | --- |
| SEC-1 | `cap_drop: ALL` を維持。追加 cap は `NET_ADMIN`/`NET_RAW` のみ（ファイアウォール用）。 | `compose.yaml` |
| SEC-2 | `security_opt: no-new-privileges:true` を維持。 | `compose.yaml` |
| SEC-3 | `read_only: true` を維持。書き込み領域は明示的な `tmpfs` と `claude-home` ボリュームのみ。 | `compose.yaml` |
| SEC-4 | `mem_limit`・`pids_limit`・`cpus` の上限を撤廃しない（既定: 4G / 1024 / 2.0）。 | `compose.yaml` |
| SEC-5 | `iptables -P OUTPUT DROP`（既定拒否）と終端の検証プローブを維持。 | `init-firewall.sh` |
| SEC-6 | sudo の許可対象は `/usr/local/bin/init-firewall.sh` のみ NOPASSWD。他に NOPASSWD を追加しない。 | `Dockerfile` |
| SEC-7 | コンテナの最終 `USER` は `agent`。root で実行しない。 | `Dockerfile` |
| SEC-8 | ホストの `~/.ssh`・`~/.aws`・`~/.gcloud`・`~/.gitconfig`・`~/.config/gh` 等を bind mount しない。 | `compose.yaml` |
| SEC-9 | `guard_workspace()` の `/` および `$HOME` 拒否を撤去・回避しない。 | `bin/aidock` |
| SEC-10 | OAuth 資格情報はイメージ層・ホスト FS に書き出さない（名前付きボリュームのみ）。 | `compose.yaml` |
| SEC-11 | allowlist に新規ホストを足すときは PR で必要性を述べる。テレメトリ系（statsig / sentry）は **削除可** だが追加は最小限に。 | `init-firewall.sh` |
| SEC-12 | CIDR を ipset に追加する前に必ず正規表現で検証する（任意文字列を ipset に流さない）。 | `init-firewall.sh` |

### NFR-2: 性能・リソース
- 既定リソース上限（mem 4G / cpus 2.0 / pids 1024）で Claude Code が通常運用可能であること。
- `NODE_OPTIONS=--max-old-space-size=4096` を維持し、Node ヒープと `mem_limit` を整合させる。

### NFR-3: 可搬性
- Linux + Docker Engine（+ Docker Compose v2）のみ前提。
- 追加の OS パッケージや GUI 依存を導入しない。
- iptables / ipset / cap_add に依存するため macOS Docker Desktop はサポート対象外。

### NFR-4: 監査性
- すべての shell スクリプトは Bash で書き、先頭に `set -euo pipefail` を付ける。
- インデントは 4 スペース、タブ禁止。
- 重要な分岐・例外には日本語コメントで意図を残す。

### NFR-5: 再現性
- `Dockerfile` の `ARG CLAUDE_CODE_VERSION` でバージョンを固定する。
- 依存パッケージは `--no-install-recommends` で最小化。

---

## 5. 制約と前提

- ホストは Linux であり、`iptables` / `ipset` が利用可能。
- ホストの UID/GID と `agent` ユーザの UID/GID が一致する（`bin/aidock` が自動注入）。
- Docker デーモンに対して `cap_add: NET_ADMIN, NET_RAW` を許可している。
- OAuth ログインに使うブラウザはホスト側で開く（コンテナ内にブラウザは無い）。

---

## 6. 受け入れ基準（Acceptance Criteria）

新規・修正 PR は以下をすべて満たした場合に限りマージ可能。

### AC-1: ビルド・起動
- `./bin/aidock build` が成功する。
- `./bin/aidock` 起動時に `init-firewall.sh` のプローブが両方とも成功する（example.com 拒否 / api.anthropic.com 到達）。

### AC-2: ガード
- `$HOME` で `./bin/aidock` を実行すると exit code 2 で拒否される。
- `/` で実行しても拒否される。

### AC-3: 権限
- コンテナ内 `whoami` が `agent`。
- `sudo -n /usr/local/bin/init-firewall.sh` のみ実行可能、他コマンドの sudo は失敗する。
- `cap_add` に列挙されていない capability を要求する操作（例: マウント追加）は失敗する。

### AC-4: ネットワーク
- `curl -fsS https://example.com` が失敗する。
- `curl -fsS https://api.anthropic.com` で TCP/TLS が成立する。
- `AIDOCK_PROFILE=login` のときに限り `curl -fsS https://claude.ai` の TCP/TLS が成立する。

### AC-5: 永続化
- `aidock login` 実行後、コンテナを再作成しても OAuth セッションが保持される。
- `aidock logout` 実行後、再度 `aidock` 起動時に未ログイン状態になる。

### AC-6: ドキュメント
- 機能変更時、本書 §3 / §4 と `README.md` の表 / `CLAUDE.md` のコマンド表が一致している。

---

## 7. 変更管理プロセス

1. **要件変更が必要になった場合**、まず本書（`docs/requirements.md`）を編集する。
2. PR の説明には次の 3 点を含める。
   - 影響する不変条件（NFR-1 の ID）。
   - 代替策の検討結果。
   - 残存リスクと緩和策。
3. レビュー観点は本書 §3〜§6 を網羅すること。
4. 実装変更（`bin/`・`docker/`・`compose.yaml`）と doc 更新は **同一 PR** にまとめる。
5. 本書と実装が乖離していると気付いた時点で `docs: align requirements with implementation` 等の修正 PR を即時起票する。

---

## 8. 改訂履歴

| 日付 | 改訂内容 | 担当 |
| --- | --- | --- |
| 2026-05-19 | 初版作成。既存実装をベースに要件を抽出。 | Claude Code |
