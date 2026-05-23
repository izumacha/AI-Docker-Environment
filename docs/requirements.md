# AI-Docker-Environment 要件定義書

本書は `AI-Docker-Environment` における **すべての実装が従うべき正本（Source of Truth）** である。
コード（`bin/aidock` / `compose.yaml` / `docker/**`）・ドキュメント（`README.md` / `CLAUDE.md`）・新機能の提案は、本書と矛盾してはならない。
変更が必要な場合は **先に本書を改訂し、PR 内で根拠を述べた上で実装に着手する**。

- **対象バージョン**: v1 系（Linux 専用、Claude Code 公式 CLI を Docker でサンドボックス化）
- **最終更新**: 2026-05-20
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
- CI/CD パイプライン、pre-commit フック、テストランナー（codex 自動レビューは bot ベースで設定済みだが、CI ジョブとしては存在しない。FR-7 参照）。

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
- コンテナ起動時、`AIDOCK_SKIP_FIREWALL=1` でない限り `init-firewall.sh` を実行する。
- FR-4.0: `AIDOCK_SKIP_FIREWALL=1` が設定されているときに限り初期化をスキップする。**デバッグ専用** であり、CI および共有ホストでは設定しない（SEC-13）。
- FR-4.1: 既定で `INPUT`/`FORWARD`/`OUTPUT` を `DROP`。
- FR-4.2: loopback、`ESTABLISHED,RELATED`、DNS(53/udp,tcp) のみ恒久許可。
- FR-4.3: `CORE_HOSTS` 全件を DNS 解決し ipset `allowed-hosts` に投入。DNS 解決に失敗したホストは **warn ログを残してスキップ**し、初期化は継続する。
- FR-4.4: `AIDOCK_PROFILE=login` の場合のみ `LOGIN_EXTRA_HOSTS` も投入。
- FR-4.5: GitHub `https://api.github.com/meta` から CIDR を取得し ipset へ追加。取得した CIDR は SEC-12.1 / SEC-12.2 の検証を通過した場合にのみ追加する。**現状実装は SEC-12.1（正規表現）のみ通過確認しており、SEC-12.2（octet/prefix 範囲）は要件先行で未実装** — follow-up PR で実装する。meta 取得自体が失敗した場合は **warn ログのみで継続**し、ホスト名解決で得た IP の範囲に縮退する。
- FR-4.6: 最後に検証プローブを実行する（AC-4 と同表現で揃える）。
  - `curl -fsS --max-time 3 https://example.com` が **non-zero exit** であること（接続拒否・タイムアウト・名前解決失敗のいずれも成功扱い）。到達した場合は exit 1。**実装済み**（`init-firewall.sh:98`）。
  - `curl -sS --max-time 8 -o /dev/null -w '%{http_code}\n' https://api.anthropic.com` の出力が `^[1-9][0-9]{2}$` に一致すること。`000`（curl の transport failure 印）は不合格扱い、4xx/5xx は合格。**現状実装は `^[0-9]+$`（`init-firewall.sh:105`）で `000` も許容してしまう。要件先行・未実装** — follow-up PR で `init-firewall.sh:105` を `^[1-9][0-9]{2}$` に修正する。
- FR-4.7: FR-4.3 / FR-4.5 のホスト解決と CIDR 取得は **best-effort**。個別ホストの失敗で初期化を中止しない。**終端プローブ（FR-4.6）が失敗した場合のみ `exit 1`** とする。

### FR-5: ログ出力
- `init-firewall.sh` のログは `[firewall]` プレフィックスで **stderr** に出力する。
- 解決した IP・追加した CIDR・成功/失敗ステータスをユーザーが追跡できること。

### FR-6: ドキュメント整合
- `README.md` は利用者向け、`CLAUDE.md` は AI 向け、本書は要件の正本。
- 機能を追加・削除・変更したら、**同じ PR 内で関連 doc を更新**する。

### FR-7: codex 自動レビュー
- `chatgpt-codex-connector[bot]`（codex 自動レビュー）がリポジトリレベルで有効化されている（OpenAI 側設定）。本リポジトリには CI ワークフローは存在しない。
- レビューが発火する条件は次のいずれか:
  - PR を **draft → ready** に変える（誰の操作でも発火）。
  - **Codex 接続済み GitHub アカウント** から `@codex review` コメントを投稿。
- **`github-actions[bot]` 等の bot 名義の `@codex review` は拒否される**ため、ワークフローによる自動投稿は **採用しない**（過去に `.github/workflows/codex-review.yml` で試みたが codex 側が「create a Codex account」と返却するため撤去済み）。
- Claude は draft で PR を作るため、**初回レビューと差分 push 後の再レビューは izumacha が手動で ready 化または `@codex review` を投稿する** 必要がある。本書 §7 変更管理プロセスにおいて、レビュー再依頼は izumacha のアクションを前提とする。

---

## 4. 非機能要件（NFR）

### NFR-1: セキュリティ不変条件（**絶対遵守 / Hard Constraints**）

以下を弱める変更は不可。やむを得ず変更する場合は本書を改訂し PR 説明で理由・代替策・残存リスクを明記する。

| ID | 内容 | 根拠ファイル |
| --- | --- | --- |
| SEC-1 | `cap_drop: ALL` を維持。追加 cap は `NET_ADMIN`/`NET_RAW` のみ（ファイアウォール用）。 | `compose.yaml` |
| SEC-2 | `security_opt: no-new-privileges:true` を維持。 | `compose.yaml` |
| SEC-3 | `read_only: true` を維持し、書き込み可能領域は `/workspace:rw` の明示 bind mount、必要最小限の `tmpfs`、および `claude-home` ボリュームに限定する。`/workspace:rw` は **`.git` を含むツリー全体を書き換え可能**であり、コンテナ内プロセスがコミット・履歴書換を実行しうる前提で運用する（read-only 化はサポート外）。 | `compose.yaml` |
| SEC-4 | `mem_limit`・`pids_limit`・`cpus` の上限を撤廃しない（既定: 4G / 1024 / 2.0）。 | `compose.yaml` |
| SEC-5 | `iptables -P OUTPUT DROP`（既定拒否）と終端の検証プローブを維持。 | `init-firewall.sh` |
| SEC-6 | sudo の許可対象は `/usr/local/bin/init-firewall.sh` のみ NOPASSWD。他に NOPASSWD を追加しない。 | `Dockerfile` |
| SEC-7 | コンテナの最終 `USER` は `agent`。root で実行しない。 | `Dockerfile` |
| SEC-8 | ホストの資格情報・設定ファイルがコンテナへ流出することを防ぐ。**一次防御**は (a) `compose.yaml` が `$PWD` と `claude-home` 以外を bind mount しないこと、(b) `bin/aidock` の `guard_workspace()` が `$HOME` と `/` を起動カレントとして拒否すること。**機械的拒否対象**: 次のパス配下から `aidock` を起動すると `guard_workspace()` が exit 2 で拒否する: `~/.ssh`、`~/.aws`、`~/.config/aws`、`~/.gcloud`、`~/.config/gcloud`、`~/.azure`、`~/.config/azure`、`~/.gitconfig`、`~/.git-credentials`、`~/.config/git`、`~/.config/gh`、`~/.netrc`、`~/.kube`（kubeconfig）、`~/.docker`、`/var/run/docker.sock`、`~/.npmrc`、`~/.pypirc`。`guard_workspace()` は `$HOME` 未設定・空文字・存在しない値の場合も `/etc/passwd` から実 home を解決して比較するため、`HOME=` クリアや `unset HOME` でバイパスできない。運用上もこれらの配下から `aidock` を起動しないことを推奨する。 | `compose.yaml` / `bin/aidock` |
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
- SEC-8 列挙パス配下（`~/.ssh`、`~/.aws`、`~/.config/gcloud` 等）で `./bin/aidock` を実行すると exit code 2 で拒否される。
- 上記 SEC-8 パス配下から `HOME=` クリア、`unset HOME`、または存在しないパスを指す `HOME` で実行しても、`/etc/passwd` から実 home を解決して同様に exit code 2 で拒否される（バイパスできない）。
- 検証手順（任意の SEC-8 列挙パスを使用、例: `~/.aws/test`）:
    - `mkdir -p ~/.aws/test && cd ~/.aws/test`
    - `for h in "/root" "" "/nonexistent"; do HOME="$h" ./bin/aidock run >/dev/null 2>&1; echo "HOME=$h exit=$?"; done`
    - すべて `exit=2` であること。

### AC-3: 権限
- コンテナ内 `whoami` が `agent`。
- `sudo -n /usr/local/bin/init-firewall.sh` のみ実行可能、他コマンドの sudo は失敗する。
- `cap_add` に列挙されていない capability を要求する操作（例: マウント追加）は失敗する。

### AC-4: ネットワーク
- `curl -fsS --max-time 3 https://example.com` が **non-zero exit** であること（接続拒否・タイムアウト・名前解決失敗のいずれも成功扱い）。
- `curl -sS --max-time 8 -o /dev/null -w '%{http_code}\n' https://api.anthropic.com | grep -qE '^[1-9][0-9]{2}$'` が **exit 0** であること。`000` は curl の transport failure 印（DNS / 接続 / TLS 失敗時の sentinel）であり **不合格扱い**。4xx/5xx は合格。**現状の `init-firewall.sh:105` は `grep -qE '^[0-9]+$'` のため `000` も合格扱いになる残存リスクあり**（follow-up PR で同期）。
- `AIDOCK_PROFILE=login` のときに限り、同様の手順で `https://claude.ai` からも 100–599 のステータスが返ること。

### AC-5: 永続化
- `aidock login` 実行後、コンテナを再作成しても OAuth セッションが保持される。
- `aidock logout` が **正常に完了した場合**（`compose down -v` および `docker volume rm` の少なくとも一方が実際にボリュームを破棄した場合）、再度 `aidock` 起動時に未ログイン状態になる。**現状実装は両コマンドに `|| true` が付いており Docker 不在時にも success メッセージを出すため、終了コードや出力で破棄成功を保証できない**（follow-up PR で `bin/aidock logout` の失敗を非ゼロ exit で伝播するよう修正予定）。検証は `docker volume ls` で当該ボリュームが消えていることで補強する。

### AC-6: ドキュメント
- 機能変更時、本書 §3 / §4 と `README.md` の表 / `CLAUDE.md` のコマンド表が一致している。

### AC-7: 資格情報ボリューム所有権
- `docker compose -f compose.yaml run --rm --no-deps --entrypoint sh claude -c 'stat -c "%u:%g" /home/agent/.claude'` の出力が **`$(id -u):$(id -g)`** と一致する（FR-3.3）。compose 経由で実行するため、Compose プロジェクト名（ボリューム名の prefix）に依存せず判定できる。一致しない場合は **`aidock build` → `aidock logout` → `aidock login`** の順で再構築する（`agent` ユーザの UID/GID は image build 時に baking されるため、ボリュームの作り直しのみでは復旧しない。FR-3.3 と整合）。

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
| 2026-05-23 | SEC-8 の follow-up を実装: `bin/aidock` の `guard_workspace()` を拡張し、機密ディレクトリ/ファイル配下（`~/.ssh`、`~/.aws`、`~/.config/gh` など）および `/var/run/docker.sock` 配下からの起動を機械的に拒否。README/CLAUDE の説明も運用依存から実装済み表現へ同期。 | Codex |
| 2026-05-23 | 追加レビュー反映: `guard_workspace()` の拒否対象に `~/.config/gcloud` と `~/.git-credentials` を追加し、関連ドキュメントの機密パス一覧を同期。 | Codex |
| 2026-05-23 | 追加レビュー反映: クラウド資格情報配置の揺れを考慮し、`guard_workspace()` の拒否対象に `~/.config/aws` と `~/.config/azure` を追加。README/CLAUDE/要件の機密パス一覧を同期。 | Codex |
| 2026-05-23 | 追加レビュー反映 (HOME バイパス対策): `guard_workspace()` の `$HOME` 解決を堅牢化。`HOME=` クリア、`unset HOME`、存在しない `HOME` 値で起動した際にも `/etc/passwd` から実 home を解決して SEC-8 拒否を発動するよう修正。AC-2 にテストレシピを追記。SEC-8 表現を「運用上の禁止事項」並列から「機械的拒否対象 + 運用推奨」階層構造に整理。 | Claude Code |
| 2026-05-19 | 初版作成。既存実装をベースに要件を抽出。 | Claude Code |
| 2026-05-19 | レビュー指摘反映: AC-4 の curl から `-f` を除去し status code 検査に統一 / SEC-3 に `/workspace:rw` を明示 / NFR-4 のコメント言語要件を緩和。 | Claude Code |
| 2026-05-19 | skill 観点（review / security-review / simplify）の再監査を反映: SEC-13/14、FR-3.3、FR-4.0/4.7、NFR-5.1/5.2、AC-7 を追加。SEC-3/8/12、FR-1.3/4.3/4.5/4.6、AC-4 を改訂。CIDR 検証強化は要件先行（実装は後続 PR）。 | Claude Code |
| 2026-05-19 | codex 自動レビュー設定 + codex P1×3 / P2×1 反映: FR-7 と §5 制約追記、§1.3 スコープ修正、`.github/workflows/codex-review.yml` 新設、`CLAUDE.md` Git ワークフロー節更新、`README.md` ファイル構成更新。AC-4 / FR-4.6 で `^[1-9][0-9]{2}$` により curl `000` を拒否、SEC-8 を運用ハイジーンに降格、SEC-12 を 12.1（実装済み）/ 12.2（要件先行）に分割、AC-7 を compose 経由に変更。SEC-8 機械化と SEC-12.2 実装は follow-up PR。 | Claude Code |
| 2026-05-19 | `.github/workflows/codex-review.yml` 撤去（`github-actions[bot]` 名義の `@codex review` は codex に拒否されるため）。FR-7 を実態に合わせ、ready 化または Codex 接続済みアカウントからの手動コメントが必要であることを明記。codex の追加指摘を反映: FR-4.6/AC-4 に `init-firewall.sh:105` が未対応であることを注記、FR-1.6 を Compose プロジェクト名非依存の表現に書き換え。CLAUDE.md / README.md も同期。 | Claude Code |
| 2026-05-19 | izumacha レビュー反映: `README.md` と `CLAUDE.md` の「一切マウントしない」表現を SEC-8 と整合させ「追加 bind mount しない / 機密ディレクトリ配下では起動しない」に修正。脅威モデル表も同様に更新。 | Claude Code |
| 2026-05-20 | codex P2×3 反映: FR-1.6 に同名グローバルボリューム削除の破壊的副作用を明記、FR-3.3 の復旧手順に `aidock build` 再ビルドを追加、AC-5 を best-effort に緩和（`bin/aidock logout` の `\|\| true` による失敗隠蔽を明示）。実装側強化（`bin/aidock` の終了コード伝播・`docker volume rm` 撤去）は follow-up PR。 | Claude Code |
| 2026-05-20 | codex 追加 P2×2 反映: §1.1 目的の「一切コンテナへ渡さない」を SEC-8 と整合する文言に緩和、AC-7 の復旧手順に `aidock build` を追加し FR-3.3 と整合。 | Claude Code |
| 2026-05-20 | セルフレビュー反映: §8 改訂履歴の凡例違反を修正（workflow 撤去エントリを正しい時系列位置へ移動）、`最終更新` ヘッダを 2026-05-20 に同期。 | Claude Code |
