# AI-Docker-Environment 要件定義書

本書は `AI-Docker-Environment` における **すべての実装が従うべき正本（Source of Truth）** である。
コード（`bin/aidock` / `compose.yaml` / `docker/**`）・ドキュメント（`README.md` / `CLAUDE.md`）・新機能の提案は、本書と矛盾してはならない。
変更が必要な場合は **先に本書を改訂し、PR 内で根拠を述べた上で実装に着手する**。

- **対象バージョン**: v1 系（Linux 専用、Claude Code 公式 CLI を Docker でサンドボックス化）
- **最終更新**: 2026-05-24
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
- ホスト上の秘匿情報（SSH 鍵、クラウド資格情報、git 設定など）を **明示的に追加 bind mount しない**。ただし `$PWD` は `/workspace:rw` として渡るため、秘匿情報配下からの `aidock` 起動は `guard_workspace()` で機械的に拒否する（SEC-8 参照）。

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
- pre-commit フック、汎用テストランナー（unit テスト等）。ただし CI/CD は本書改訂によりスコープ内へ移行し、GitHub Actions による**型チェック**と **e2e** を提供する（FR-8 参照）。codex 自動レビューは引き続き bot ベースで、CI からは投稿しない（FR-7 参照）。

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
| FR-1.3 | `run [args...]` / 引数なし | `$PWD` を `/workspace` に bind mount して Claude Code を起動。`run` は既定サブコマンド。追加 `args` は `compose run --rm claude` に **位置引数として無変換で渡される**（SEC-14 参照）。 |
| FR-1.4 | `shell` / `bash` | 同マウントで bash を起動。 |
| FR-1.5 | `firewall-refresh` | 稼働中コンテナ内で `init-firewall.sh` を再実行（DNS 再解決）。 |
| FR-1.6 | `logout` | `compose down -v` でサービスと名前付きボリューム（`claude-home`）を破棄し、OAuth 資格情報を失わせる。**現状実装は補強として `docker volume rm aidock_claude-home` も実行する**。Compose プロジェクト名が `aidock` 以外では当該名のボリュームは別文脈（他チェックアウト・別プロジェクト等で作られた **同名グローバルボリューム**）を指しうるため、**意図せず他プロジェクトの資格情報を削除する破壊的副作用**がある（既知の defect。follow-up PR で `compose down -v` のみに集約予定）。 |
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
- FR-3.3: ボリューム配下のファイルは `build` 時の `HOST_UID:HOST_GID` で所有される。`agent` ユーザ自体も `Dockerfile` で同 UID/GID を持って生成されるため、ホストの UID/GID が変わった場合は **`aidock build` でイメージを再構築 → `aidock logout` でボリュームを破棄 → `aidock login`** の順で実施する（イメージを再ビルドせずにボリュームのみ作り直しても、`HOME=/home/agent` の所有者は古い UID/GID のままで AC-7 が失敗し続ける）。**マルチユーザー共用ホストでは利用終了時に必ず `aidock logout` を実行する**（資格情報がボリュームに残るため）。

### FR-4: ファイアウォール初期化
- コンテナ起動時、`AIDOCK_SKIP_FIREWALL=1` でない限り `init-firewall.sh` を実行する。entrypoint は **root** で起動して `init-firewall.sh` を直接実行し（sudo は使わない）、初期化後に `gosu agent` でワークロードを exec する（SEC-6 / SEC-7 参照）。
- FR-4.0: `AIDOCK_SKIP_FIREWALL=1` が設定されているときに限り初期化をスキップする。**デバッグ専用** であり、CI および共有ホストでは設定しない（SEC-13）。
- FR-4.1: 既定で `INPUT`/`FORWARD`/`OUTPUT` を `DROP`。
- FR-4.2: loopback、`ESTABLISHED,RELATED`、DNS(53/udp,tcp) のみ恒久許可。
- FR-4.3: `CORE_HOSTS` 全件を DNS 解決し ipset `allowed-hosts` に投入。DNS 解決に失敗したホストは **warn ログを残してスキップ**し、初期化は継続する。
- FR-4.4: `AIDOCK_PROFILE=login` の場合のみ `LOGIN_EXTRA_HOSTS` も投入。
- FR-4.5: GitHub `https://api.github.com/meta` から CIDR を取得し ipset へ追加。取得した CIDR は SEC-12.1 / SEC-12.2 の検証を通過した場合にのみ追加する。**現状実装は SEC-12.1（正規表現）のみ通過確認しており、SEC-12.2（octet/prefix 範囲）は要件先行で未実装** — follow-up PR で実装する。meta 取得自体が失敗した場合は **warn ログのみで継続**し、ホスト名解決で得た IP の範囲に縮退する。
- FR-4.6: 最後に検証プローブを実行する（AC-4 と同表現で揃える）。
  - `curl -fsS --max-time 3 https://example.com` が **non-zero exit** であること（接続拒否・タイムアウト・名前解決失敗のいずれも成功扱い）。到達した場合は exit 1。**実装済み**（`init-firewall.sh:98`）。
  - `curl -sS --max-time 8 -o /dev/null -w '%{http_code}\n' https://api.anthropic.com` の出力が `^[1-9][0-9]{2}$` に一致すること。`000`（curl の transport failure 印）は不合格扱い、4xx/5xx は合格。**実装済み**（`init-firewall.sh` の api.anthropic.com プローブを `^[1-9][0-9]{2}$` に修正し、`000` を不合格化）。
- FR-4.7: FR-4.3 / FR-4.5 のホスト解決と CIDR 取得は **best-effort**。個別ホストの失敗で初期化を中止しない。**終端プローブ（FR-4.6）が失敗した場合のみ `exit 1`** とする。

### FR-5: ログ出力
- `init-firewall.sh` のログは `[firewall]` プレフィックスで **stderr** に出力する。
- 解決した IP・追加した CIDR・成功/失敗ステータスをユーザーが追跡できること。

### FR-6: ドキュメント整合
- `README.md` は利用者向け、`CLAUDE.md` は AI 向け、本書は要件の正本。
- 機能を追加・削除・変更したら、**同じ PR 内で関連 doc を更新**する。

### FR-7: codex 自動レビュー
- `chatgpt-codex-connector[bot]`（codex 自動レビュー）がリポジトリレベルで有効化されている（OpenAI 側設定）。codex はコードレビュー担当であり、CI（`ci.yml`）から codex へコメント投稿（`@codex review`）は行わない。なお CI 成功後の**検証サマリ**は別途 Claude Code Action（FR-9）が PR にコメントする（codex とは別物）。
- レビューが発火する条件は次のいずれか:
  - PR を **draft → ready** に変える（誰の操作でも発火）。
  - **Codex 接続済み GitHub アカウント** から `@codex review` コメントを投稿。
- **`github-actions[bot]` 等の bot 名義の `@codex review` は拒否される**ため、ワークフローによる自動投稿は **採用しない**（過去に `.github/workflows/codex-review.yml` で試みたが codex 側が「create a Codex account」と返却するため撤去済み）。
- Claude は draft で PR を作る。**Claude は PR への実装変更を push した後、GitHub MCP（izumacha 認証＝Codex 接続済みアカウント名義）で `@codex review` を自動投稿してレビューを起動する**（workflow からの bot 名義投稿は上記のとおり拒否されるため、Claude セッション内での投稿で代替する）。izumacha が手動で ready 化または `@codex review` を投稿する運用も引き続き可能。

### FR-8: CI ワークフロー
`.github/workflows/ci.yml`（GitHub Actions）で**型チェック**と **e2e** を実行する。push（全ブランチ）および `main` への pull_request で発火し、`permissions: contents: read` のみを付与する（FR-7 に従い codex へのコメント投稿は行わない）。

- FR-8.1: **type-check ジョブ**は次の静的解析を実行し、いずれか失敗で CI を不合格とする。
  - `shellcheck`（v0.11.0、GitHub Releases から取得した固定版）を全シェルスクリプト（`bin/aidock`・`docker/init-firewall.sh`・`docker/entrypoint.sh`）に適用。
  - `bash -n` による構文チェック。
  - `hadolint`（v2.14.0、GitHub Releases から取得した固定版）で `docker/Dockerfile` を検査。`DL3008`（apt パッケージのバージョン固定）は `.hadolint.yaml` で除外する（理由は NFR-5.1: 再現性は `CLAUDE_CODE_VERSION` 固定と `--no-install-recommends` で担保し、OS ライブラリの逐一ピン留めは方針外）。
  - `docker compose -f compose.yaml config -q` による compose 定義の妥当性検証。
- FR-8.2: **e2e ジョブ**（type-check 成功後に実行）は GitHub-hosted runner 上で受け入れ基準を実機検証する。検証項目と AC の対応は AC-8 を参照。SEC-13 に従い `AIDOCK_SKIP_FIREWALL` は設定せず、**実ファイアウォールを起動した状態で検証する**。
- FR-8.3: e2e は外部 egress（`api.anthropic.com` / `claude.ai` / `api.github.com`）に依存する。各プローブは `--max-time` を持つが、ネットワーク要因による一時失敗の可能性がある（残存リスク）。

### FR-9: CI 後の Claude 検証エージェント
`.github/workflows/post-ci-verify.yml`（GitHub Actions）で、CI 成功後に Claude Code Action（`anthropics/claude-code-action@v1`）を起動し、結果を検証・要約して PR にコメントする。

- FR-9.1: トリガは `workflow_run`（`workflows: ["CI"]`, `types: [completed]`）。`github.event.workflow_run.conclusion == 'success'` かつ `event == 'pull_request'` のときのみ実行する。
- FR-9.2: PR 番号は `workflow_run.pull_requests[0].number` で解決する。空の場合のフォールバックは **同一リポジトリ実行（`head_repository.full_name == owner/repo`）に限定**し、`head_branch` の open PR のうち **`head.sha == workflow_run.head_sha` に一致する PR** を選ぶ（同名 head ブランチの複数 PR で誤った相手にコメントしないため）。fork PR は `pull_requests[]` が空かつ同一リポジトリ判定で弾かれ実質スキップ（セキュリティ上も望ましい）。
- FR-9.3: 認証は **Claude GitHub App + OAuth**。リポジトリ secret `CLAUDE_CODE_OAUTH_TOKEN` を `claude_code_oauth_token` 入力で渡す（代替として `ANTHROPIC_API_KEY` + `anthropic_api_key` も可）。当該 secret は **GitHub Actions secret** でありイメージ層・コンテナには持ち込まない（SEC-10 と整合）。`permissions` は `contents: read` / `pull-requests: write` / `actions: read`。
- FR-9.4: エージェントは type-check / e2e（AC-1〜AC-4 / AC-7）の結果を検証・要約し、PR に**コメント1件**を投稿する。**コミット・ファイル変更・push は行わない**（CI は push/PR でのみ発火し、コメントでは再発火しないため無限ループしない）。
- FR-9.5: `workflow_run` は**デフォルトブランチ（`main`）上のワークフローのみ発火**する。本ワークフローは `main` マージ後の PR から有効になる。
- FR-9.6: 特権ワークフロー（`pull-requests: write` ＋ secret）の堅牢化として、(a) PR head を **checkout しない**（非信頼コードをワークスペースに展開しない）、(b) `claude-code-action` は **有効化前に監査済み v1 commit の SHA へピン**する（可変タグの供給網リスク回避。フル SHA の確認は #17）、(c) Claude のツールを **`gh run view` / `gh pr comment` に限定**する（`--allowedTools`）、(d) `github_token` 入力を省略し **Claude GitHub App 認証**を用いるため、有効化時に **`permissions: id-token: write`** を付与する（OIDC トークン交換に必須。未付与だと検証 step が認証失敗。SHA ピンと併せて #17 で対応）。

---

## 4. 非機能要件（NFR）

### NFR-1: セキュリティ不変条件（**絶対遵守 / Hard Constraints**）

以下を弱める変更は不可。やむを得ず変更する場合は本書を改訂し PR 説明で理由・代替策・残存リスクを明記する。

| ID | 内容 | 根拠ファイル |
| --- | --- | --- |
| SEC-1 | `cap_drop: ALL` を維持。追加 cap は `NET_ADMIN`/`NET_RAW`（ファイアウォール用）と `SETUID`/`SETGID`（entrypoint が root→agent へ降格する `gosu` 用）のみ。降格後の `agent` プロセスは capability を持たない。 | `compose.yaml` |
| SEC-2 | `security_opt: no-new-privileges:true` を維持。 | `compose.yaml` |
| SEC-3 | `read_only: true` を維持し、書き込み可能領域は `/workspace:rw` の明示 bind mount、必要最小限の `tmpfs`、および `claude-home` ボリュームに限定する。`/workspace:rw` は **`.git` を含むツリー全体を書き換え可能**であり、コンテナ内プロセスがコミット・履歴書換を実行しうる前提で運用する（read-only 化はサポート外）。 | `compose.yaml` |
| SEC-4 | `mem_limit`・`pids_limit`・`cpus` の上限を撤廃しない（既定: 4G / 1024 / 2.0）。 | `compose.yaml` |
| SEC-5 | `iptables -P OUTPUT DROP`（既定拒否）と終端の検証プローブを維持。 | `init-firewall.sh` |
| SEC-6 | コンテナイメージに `sudo` を含めない。firewall 初期化は entrypoint が **root で直接実行**し、setuid による昇格を一切使わない（`no-new-privileges` 下では setuid `sudo` が root 化できないため）。 | `Dockerfile` / `entrypoint.sh` |
| SEC-7 | ワークロード（claude-code 等）は `agent` で実行する。entrypoint は firewall 初期化のためにのみ root で起動し、`gosu agent` で**不可逆に降格**してからコマンドを exec する（`no-new-privileges` 下で setuid による再昇格は不可）。 | `Dockerfile` / `entrypoint.sh` |
| SEC-8 | ホストの資格情報・設定ファイルがコンテナへ流出することを防ぐ。**一次防御**は (a) `compose.yaml` が `$PWD` と `claude-home` 以外を bind mount しないこと、(b) `bin/aidock` の `guard_workspace()` が `$HOME` と `/` を起動カレントとして拒否すること。**運用上の禁止事項**として、次のパス配下を `aidock` の起動カレントディレクトリに設定しない: `~/.ssh`、`~/.aws`、`~/.config/aws`、`~/.gcloud`、`~/.config/gcloud`、`~/.azure`、`~/.config/azure`、`~/.gitconfig`、`~/.git-credentials`、`~/.config/git`、`~/.config/gh`、`~/.netrc`、`~/.kube`（kubeconfig）、`~/.docker`、`/var/run/docker.sock`、`~/.npmrc`、`~/.pypirc`。これら各パスは `guard_workspace()` で機械的に拒否する。 | `compose.yaml` / `bin/aidock` |
| SEC-9 | `guard_workspace()` の `/` および `$HOME` 拒否を撤去・回避しない。 | `bin/aidock` |
| SEC-10 | OAuth 資格情報はイメージ層・ホスト FS に書き出さない（名前付きボリュームのみ）。 | `compose.yaml` |
| SEC-11 | allowlist に新規ホストを足すときは PR で必要性を述べる。テレメトリ系（statsig / sentry）は **削除可** だが追加は最小限に。 | `init-firewall.sh` |
| SEC-12.1 | CIDR を ipset に追加する前に正規表現 `^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$` の一致を検証する。**実装済み**（`init-firewall.sh:83`）。 | `init-firewall.sh` |
| SEC-12.2 | 各 octet が `0`–`255`、prefix が `0`–`32` の範囲であることを併せて検証する。**要件先行・未実装**。実装は follow-up PR で対応。SEC-12.2 が未実装である間、形式的に正規表現を通る `999.999.999.999/33` 等が ipset に追加されうる **残存リスク** が存在する。 | `init-firewall.sh` |
| SEC-13 | `AIDOCK_SKIP_FIREWALL=1` の常用を禁止する。**デバッグ用バックドア**であり、CI および共有ホストでは設定しない。一時的に使用した場合はその都度 `unset` する。 | `entrypoint.sh` |
| SEC-14 | `bin/aidock run [args...]` の追加引数は `compose run --rm claude` に **位置引数として無変換で渡される**。コマンド置換（`$()`・バッククォート）等を含めない責任は呼び出し側が負う。ラッパー側で eval/sh -c 等の二次評価を導入してはならない。 | `bin/aidock` |

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
- 重要な分岐・例外には意図が分かるコメントを残す（言語は問わない。既存実装は英語コメント中心）。
- すべてのシェルスクリプトは CI（FR-8.1）の `shellcheck` を、`docker/Dockerfile` は `hadolint` を通過すること。

### NFR-5: 再現性
- NFR-5.1: `Dockerfile` の `ARG CLAUDE_CODE_VERSION` で Claude Code のバージョンを固定し、依存パッケージは `--no-install-recommends` で最小化する。
- NFR-5.2: バージョン更新は **月次もしくは Anthropic の脆弱性公表時** に検討し、`docker/Dockerfile` の改訂と本書 §8 改訂履歴への追記を **同一 PR** で実施する。CVE が該当する場合は即時更新する。

---

## 5. 制約と前提

- ホストは Linux であり、`iptables` / `ipset` が利用可能。
- ホストの UID/GID と `agent` ユーザの UID/GID が一致する（`bin/aidock` が自動注入）。
- Docker デーモンに対して `cap_add: NET_ADMIN, NET_RAW` を許可している。
- OAuth ログインに使うブラウザはホスト側で開く（コンテナ内にブラウザは無い）。
- リポジトリ単位で `chatgpt-codex-connector[bot]`（codex 自動レビュー）が OpenAI 側で有効化済み。発火条件は FR-7 を参照（draft→ready 化、または Codex 接続済みアカウントからの `@codex review` コメント）。

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
- コンテナ内 `whoami` が `agent`（entrypoint が `gosu` で降格した結果）。
- コンテナに `sudo` は存在せず、`agent` から root への昇格手段が無い。
- capability 集合が最小であること（`/proc/self/status` の `CapBnd` で `CAP_SYS_ADMIN` 不在・`CAP_NET_ADMIN` 在を確認）。`mount` 等の syscall はデフォルト seccomp でも遮断されるため、capability の回帰検出には bounding set を直接参照する（`mount` 失敗では検証にならない）。

### AC-4: ネットワーク
- `curl -fsS --max-time 3 https://example.com` が **non-zero exit** であること（接続拒否・タイムアウト・名前解決失敗のいずれも成功扱い）。
- `curl -sS --max-time 8 -o /dev/null -w '%{http_code}\n' https://api.anthropic.com | grep -qE '^[1-9][0-9]{2}$'` が **exit 0** であること。`000` は curl の transport failure 印（DNS / 接続 / TLS 失敗時の sentinel）であり **不合格扱い**。4xx/5xx は合格。**`init-firewall.sh` の api.anthropic.com プローブを `^[1-9][0-9]{2}$` に修正済み**（`000` を不合格化）。
- `AIDOCK_PROFILE=login` のときに限り、同様の手順で `https://claude.ai` からも 100–599 のステータスが返ること。

### AC-5: 永続化
- `aidock login` 実行後、コンテナを再作成しても OAuth セッションが保持される。
- `aidock logout` が **正常に完了した場合**（`compose down -v` および `docker volume rm` の少なくとも一方が実際にボリュームを破棄した場合）、再度 `aidock` 起動時に未ログイン状態になる。**現状実装は両コマンドに `|| true` が付いており Docker 不在時にも success メッセージを出すため、終了コードや出力で破棄成功を保証できない**（follow-up PR で `bin/aidock logout` の失敗を非ゼロ exit で伝播するよう修正予定）。検証は `docker volume ls` で当該ボリュームが消えていることで補強する。

### AC-6: ドキュメント
- 機能変更時、本書 §3 / §4 と `README.md` の表 / `CLAUDE.md` のコマンド表が一致している。

### AC-7: 資格情報ボリューム所有権
- `docker compose -f compose.yaml run --rm --no-deps --entrypoint sh claude -c 'stat -c "%u:%g" /home/agent/.claude'` の出力が **`$(id -u):$(id -g)`** と一致する（FR-3.3）。compose 経由で実行するため、Compose プロジェクト名（ボリューム名の prefix）に依存せず判定できる。一致しない場合は **`aidock build` → `aidock logout` → `aidock login`** の順で再構築する（`agent` ユーザの UID/GID は image build 時に baking されるため、ボリュームの作り直しのみでは復旧しない。FR-3.3 と整合）。

### AC-8: CI
- `.github/workflows/ci.yml` の **type-check** と **e2e** の両ジョブがグリーンであること（PR マージの必須条件、FR-8）。
- type-check は FR-8.1 の静的解析（`shellcheck` / `bash -n` / `hadolint` / `docker compose config`）をすべて通過する。
- e2e は次を GitHub-hosted runner 上で実機検証する: AC-1（ビルド + 起動プローブ）、AC-2（`$HOME` / `/` 起動を exit 2 で拒否）、AC-3（`whoami=agent` / `sudo` 不在 / capability 制限）、AC-4（run プロファイルの example.com 遮断・api.anthropic.com 到達、login プロファイルの claude.ai 到達）、AC-7（資格情報ボリューム所有権）。
- **AC-5（永続化）は対話 OAuth ログインを要するため CI 対象外**とし、ローカル手動検証に委ねる。

### AC-9: CI 後検証エージェント
- `main` 上で `CI` が PR に対して成功すると、`.github/workflows/post-ci-verify.yml`（FR-9）が起動し、Claude が type-check / e2e の結果を検証・要約して PR に**コメント1件**を投稿する。
- 当該ワークフローはコメントのみで、コミット・push は行わない。`CLAUDE_CODE_OAUTH_TOKEN` secret が前提。
- `workflow_run` の仕様上、`main` にマージされるまでは発火しない（PR ブランチ単独では検証不可）。

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

> 凡例: 日付は JST。同一日に複数行ある場合は **上から古い順** に並べる。

| 日付 | 改訂内容 | 担当 |
| --- | --- | --- |
| 2026-05-24 | codex レビュー（5巡目）反映: (1) `post-ci-verify.yml` の PR fallback を **`head.sha == workflow_run.head_sha` 一致**で厳密化し、同名 head ブランチの複数 PR で誤った PR にコメントする経路を排除（P2、FR-9.2 更新）。(2) Claude GitHub App 認証パスが要求する **`id-token: write`** の付与を有効化前タスクとして #17 に集約（codex P1。公式 setup docs で要否を確認済み。SHA ピンと同じ扱い、FR-9.6 に (d) を追記）。 | Claude Code |
| 2026-05-24 | codex レビュー（4巡目）反映: `post-ci-verify.yml` の PR 番号 fallback に **同一リポジトリ判定**（`head_repository.full_name == owner/repo`）を追加し、fork のブランチ名衝突で無関係 PR にコメントする経路を遮断（P3）。action の SHA ピン（claude-code-action / github-script、P1/P2）はフル SHA をこの環境で確認できないため有効化前タスクとして #17 に集約。 | Claude Code |
| 2026-05-24 | codex レビュー（3巡目）反映: (1) e2e の run-profile（AC-1/AC-4）を `claude true` から `api.anthropic.com` の **明示 egress アサーション**（`^[1-9][0-9]{2}$`）に変更。(2) `post-ci-verify.yml` のピン SHA が誤り（`787c5a0` は v1≠、codex によれば現 v1=`20c8abf`）だったため `@v1` に戻し、監査済み SHA へのピンを有効化前タスクとして #17 に集約（FR-9.6 更新）。 | Claude Code |
| 2026-05-24 | 運用ルール追加: Claude は PR への実装変更を push した後、GitHub MCP（izumacha 認証＝Codex 接続済みアカウント名義）で `@codex review` を自動投稿する（workflow の bot 名義投稿は FR-7 のとおり拒否されるため代替）。FR-7 と CLAUDE.md「Git ワークフロー」を更新。 | Claude Code |
| 2026-05-24 | codex レビュー（2巡目）反映: (1) CI の AC-3 capability 検証を `mount` プローブから `/proc/self/status` の `CapBnd` 直接検査へ変更（`mount` はデフォルト seccomp で常に失敗し cap 回帰を検出できないため）。(2) `post-ci-verify.yml` を堅牢化: PR head の checkout を撤去、`claude-code-action` を commit SHA でピン、Claude のツールを `gh run view` / `gh pr comment` に限定（FR-9.6）。`init-firewall.sh:105` の `000` 是正と run-profile プローブは既に対応済み。 | Claude Code |
| 2026-05-24 | CI 後の Claude 検証エージェントを追加: `.github/workflows/post-ci-verify.yml` を新設し、`workflow_run`（CI 成功・PR）で `anthropics/claude-code-action@v1` を起動、type-check / e2e 結果を検証・要約して PR にコメント1件を投稿（コミットしない）。認証は Claude GitHub App + `CLAUDE_CODE_OAUTH_TOKEN`。FR-9 / AC-9 を新設、FR-7 を改訂（codex とは別の検証コメントである旨）。`workflow_run` は `main` 上のワークフローのみ発火するため `main` マージ後に有効。CLAUDE.md / README.md も同期。既存コードは未変更。 | Claude Code |
| 2026-05-24 | e2e で判明した gosu 降格失敗を修正: `cap_drop: ALL` が `CAP_SETUID`/`CAP_SETGID` を剥奪するため root→agent 降格が `operation not permitted` で失敗していた。`cap_add` に `SETUID`/`SETGID` を追加し SEC-1 を改訂（降格後の `agent` は capability ゼロ）。これで firewall は通過済み（`[firewall] ok`）の状態で起動経路が完結する。 | Claude Code |
| 2026-05-24 | codex レビュー反映: `init-firewall.sh` の api.anthropic.com プローブ正規表現を `^[0-9]+$` → `^[1-9][0-9]{2}$` に修正し curl の `000`（transport failure）を不合格化（FR-4.6 / AC-4 の follow-up を実装）。CI の AC-3 capability チェックを **root 経由**（`--entrypoint sh`）の `mount` 失敗確認に変更し、CAP_SYS_ADMIN の回帰を検出可能にした。 | Claude Code |
| 2026-05-24 | e2e で判明した DNS 解決不能を修正: `init-firewall.sh` の `iptables -t nat -F`（および mangle flush）が Docker 組込み DNS（`127.0.0.11:53`）の DNAT を消去し、コンテナ内の全ホスト名解決が失敗していた（allowlist が空になり AC-4 プローブが失敗）。nat/mangle のフラッシュを撤去（filter テーブルのリセットは維持）。egress 拒否方針（SEC-5）は不変。 | Claude Code |
| 2026-05-24 | e2e で判明した起動経路の不具合を修正: `no-new-privileges`（SEC-2）下では setuid `sudo` が root 化できず entrypoint の `sudo init-firewall.sh` が失敗するため、**root 起動 → `gosu agent` 降格** 方式へ変更（`sudo` を廃止しイメージから除去、`gosu` を追加、`USER agent` を撤去して entrypoint を root 起動に）。SEC-6 / SEC-7 を再定義し、FR-4 / AC-3 を更新、CI の AC-3 を sudo 非依存に変更。CLAUDE.md / README.md の脅威モデルも同期。 | Claude Code |
| 2026-05-24 | CI ワークフロー（型チェック + e2e）を新設: `.github/workflows/ci.yml` と `.hadolint.yaml`（DL3008 除外）を追加。type-check は GitHub Releases から取得した固定版 shellcheck 0.11.0 / hadolint 2.14.0 と `bash -n` / `docker compose config`、e2e は AC-1〜AC-4 / AC-7 を GitHub-hosted runner で実機検証（AC-5 は対話ログイン要のため対象外）。§1.3 を CI スコープ内へ改訂、FR-8 / AC-8 を追加、FR-7 / NFR-4 を更新。`bin/aidock` の SC2155（declare-and-assign 分離）、`docker/Dockerfile` の `useradd` の `-l` 欠落（hadolint DL3046）、および node ユーザ削除順序（`groupdel` を `userdel` より先に実行していたためクリーンビルドが exit 8 で失敗）を修正。CLAUDE.md / README.md も同期。 | Claude Code |
| 2026-05-23 | SEC-8 の follow-up を実装: `bin/aidock` の `guard_workspace()` を拡張し、機密ディレクトリ/ファイル配下（`~/.ssh`、`~/.aws`、`~/.config/gh` など）および `/var/run/docker.sock` 配下からの起動を機械的に拒否。README/CLAUDE の説明も運用依存から実装済み表現へ同期。 | Codex |
| 2026-05-23 | 追加レビュー反映: `guard_workspace()` の拒否対象に `~/.config/gcloud` と `~/.git-credentials` を追加し、関連ドキュメントの機密パス一覧を同期。 | Codex |
| 2026-05-23 | 追加レビュー反映: クラウド資格情報配置の揺れを考慮し、`guard_workspace()` の拒否対象に `~/.config/aws` と `~/.config/azure` を追加。README/CLAUDE/要件の機密パス一覧を同期。 | Codex |
| 2026-05-19 | 初版作成。既存実装をベースに要件を抽出。 | Claude Code |
| 2026-05-19 | レビュー指摘反映: AC-4 の curl から `-f` を除去し status code 検査に統一 / SEC-3 に `/workspace:rw` を明示 / NFR-4 のコメント言語要件を緩和。 | Claude Code |
| 2026-05-19 | skill 観点（review / security-review / simplify）の再監査を反映: SEC-13/14、FR-3.3、FR-4.0/4.7、NFR-5.1/5.2、AC-7 を追加。SEC-3/8/12、FR-1.3/4.3/4.5/4.6、AC-4 を改訂。CIDR 検証強化は要件先行（実装は後続 PR）。 | Claude Code |
| 2026-05-19 | codex 自動レビュー設定 + codex P1×3 / P2×1 反映: FR-7 と §5 制約追記、§1.3 スコープ修正、`.github/workflows/codex-review.yml` 新設、`CLAUDE.md` Git ワークフロー節更新、`README.md` ファイル構成更新。AC-4 / FR-4.6 で `^[1-9][0-9]{2}$` により curl `000` を拒否、SEC-8 を運用ハイジーンに降格、SEC-12 を 12.1（実装済み）/ 12.2（要件先行）に分割、AC-7 を compose 経由に変更。SEC-8 機械化と SEC-12.2 実装は follow-up PR。 | Claude Code |
| 2026-05-19 | `.github/workflows/codex-review.yml` 撤去（`github-actions[bot]` 名義の `@codex review` は codex に拒否されるため）。FR-7 を実態に合わせ、ready 化または Codex 接続済みアカウントからの手動コメントが必要であることを明記。codex の追加指摘を反映: FR-4.6/AC-4 に `init-firewall.sh:105` が未対応であることを注記、FR-1.6 を Compose プロジェクト名非依存の表現に書き換え。CLAUDE.md / README.md も同期。 | Claude Code |
| 2026-05-19 | izumacha レビュー反映: `README.md` と `CLAUDE.md` の「一切マウントしない」表現を SEC-8 と整合させ「追加 bind mount しない / 機密ディレクトリ配下では起動しない」に修正。脅威モデル表も同様に更新。 | Claude Code |
| 2026-05-20 | codex P2×3 反映: FR-1.6 に同名グローバルボリューム削除の破壊的副作用を明記、FR-3.3 の復旧手順に `aidock build` 再ビルドを追加、AC-5 を best-effort に緩和（`bin/aidock logout` の `\|\| true` による失敗隠蔽を明示）。実装側強化（`bin/aidock` の終了コード伝播・`docker volume rm` 撤去）は follow-up PR。 | Claude Code |
| 2026-05-20 | codex 追加 P2×2 反映: §1.1 目的の「一切コンテナへ渡さない」を SEC-8 と整合する文言に緩和、AC-7 の復旧手順に `aidock build` を追加し FR-3.3 と整合。 | Claude Code |
| 2026-05-20 | セルフレビュー反映: §8 改訂履歴の凡例違反を修正（workflow 撤去エントリを正しい時系列位置へ移動）、`最終更新` ヘッダを 2026-05-20 に同期。 | Claude Code |
