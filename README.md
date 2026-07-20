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
渡されるため、`~/.ssh`、`~/.aws`、`~/.config/aws`、`~/.config/gcloud`、`~/.config/gh`、`~/.kube`、`~/.gnupg` 等の機密ディレクトリ
配下と、それらを丸ごと含む `~/.config` 自体では `aidock` の起動を機械的に拒否する
（`~/.config/htop` 等の非機密サブディレクトリからの起動は許可される）。

## なぜ作ったか

Claude Code のような AI コーディングエージェントは、ファイルの読み書きやコマンド実行、ネットワークアクセスを
自律的に行えるのが強みです。しかしその裏返しとして、ホスト上で素のまま動かすと次のリスクがあります。

- **意図しないファイル操作**: `~/.ssh` やクラウド SDK の資格情報など、作業対象外の機密ファイルにまで手が届いてしまう。
- **意図しない外部通信**: 任意のホストへ HTTP リクエストを送れるため、資格情報やソースコードの持ち出し経路になりうる。
- **権限の昇格**: `sudo` やルート権限が使える環境では、被害がホスト全体に波及しかねない。

「便利さは活かしつつ、被害の及ぶ範囲をコンテナの中に閉じ込めたい」——これが本リポジトリを作った動機です。
Anthropic 公式 devcontainer のセキュリティモデル（default-deny の egress ファイアウォール）を土台に、
最小権限・読み取り専用 rootfs・`$PWD` のみのマウント・資格情報の隔離を一つのラッパー（`bin/aidock`）にまとめ、
**「うっかり」では事故が起きないデフォルト** で Claude Code を日常的に使えるようにすることを目指しています。

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
| `aidock firewall-refresh` | 起動中の全 claude コンテナで firewall を再初期化 (DNS再解決) |
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
| ホスト資格情報の流出 | `~/.ssh` / `~/.aws` / `gcloud` / `~/.gitconfig` / `~/.gnupg` 等を追加 bind mount しない。`$HOME` と `/` は起動拒否。機密ディレクトリ（`~/.ssh`、`~/.aws`、`~/.config/gcloud`、`~/.gnupg` 等）配下と `~/.config` 自体からの起動も `guard_workspace()` が機械的に拒否する（実装済み） |
| 任意外部送信 | iptables 既定 DROP + ipset allowlist (api.anthropic.com, npm, GitHub等のみ)。**IPv6 も `ip6tables` で同等に default-deny**（v6 を素通しにしない、issue #32）。DNS(53) も `/etc/resolv.conf` の nameserver に限定（任意リゾルバへの直接送信を遮断）。**現状実装**では再帰経由の query 名 exfil は防げない（残余リスク）。**要件（FR-11）**ではコンテナ内 DNS プロキシで query 名 allowlist を施行する方針へ移行する（要件先行・実装は後続）。詳細は下記「DNS の絞り込み」参照 |
| 暴走プロセス | `mem_limit=4g`, `pids_limit=1024`, `cpus=2.0`, `tini` で reap |
| 権限昇格 | `cap_drop: ALL` → `NET_ADMIN`/`NET_RAW`（+ 降格用 `SETUID`/`SETGID`）のみ復帰、`no-new-privileges`、entrypoint は root 起動 → `gosu` で agent 降格 (sudo 不使用)。ホストが UID 0（root）だと `gosu` 降格が capability を落とし切れず、GID 0 だと agent のプライマリグループが root になるため、`bin/aidock build`/`login`/`run`/`shell` はホスト root での実行を起動時に拒否する（SEC-18） |

### Allowlist 構成

`docker/init-firewall.sh` の `CORE_HOSTS` / `LOGIN_EXTRA_HOSTS` を編集して
ホストを増減できる。GitHub の CIDR ブロックは `https://api.github.com/meta`
から動的取得して ipset に追加 (jq + 正規表現の形式検証に加え、各 octet 0-255 / prefix 0-32 の範囲検証を実施。範囲外はスキップ)。

### IPv6 の default-deny（issue #32 / SEC-16）

**IPv6**: 以前は `ip6tables` 未設定で IPv6 egress が素通しだった（IPv4 のみ
default-deny）。現在は IPv6 も `ip6tables -P OUTPUT DROP` で既定拒否し、AAAA
解決した許可ホスト (`allowed-hosts6`) と v6 nameserver (`allowed-dns6`)、meta の
v6 CIDR のみ許可する（issue #32）。IPv6 スタックが無い環境では攻撃面が無いため
スキップする。終端プローブで `example.com` への v6 到達が無いことも検証する。

### DNS の絞り込み（現状実装 と FR-11 計画）

DNS(53/udp,tcp) は全宛先許可ではなく、`/etc/resolv.conf` の `nameserver`
行から抽出したアドレス (IPv4: ipset `allowed-dns` / IPv6: `allowed-dns6`) に
限定する。これは
コンテナ内プロセスが**任意の攻撃者制御リゾルバへ直接** DNS を送る経路を断つ
defense-in-depth。

**現状の実装（このコードで動いているもの）**:
`nameserver` 限定 (ipset `allowed-dns`) **までが実装済み**。`<secret>.attacker.example`
を**正規リゾルバ (`127.0.0.11` / ホスト再帰リゾルバ) の再帰解決経由**で権威 NS
(攻撃者) へ到達させる **query 名 exfiltration は現状では防げない**
(再帰チェーンの宛先を iptables/ipset で制御できないため)。**この query 名
チャネルは現時点では残余リスクとして残っている。**

**要件で計画されている強化（FR-11、要件先行・実装は後続 PR）**:
正本 (`docs/requirements.md`) は上記の query 名チャネルを「受容」から
「**施行**」へ改訂済み。コンテナ内に**ユーザー空間の forwarding DNS プロキシ**
(`127.0.0.1:53`) を置き、問い合わせドメイン名を policy 由来の allowlist と
照合して**許可名のみ上流 (`127.0.0.11`) へ forward・未許可名は権威 NS 到達前に
NXDOMAIN で遮断**する。53 番 egress は (a) `agent`→`127.0.0.1:53` プロキシ、
(b) プロキシ→`127.0.0.11:53` forward の 2 経路のみに絞り、`agent` から
`127.0.0.11:53` への直送 (プロキシ迂回) は DROP する。プロキシは `agent` とは
別 UID で動かし iptables `owner` マッチで両者を区別する。**この施行は要件として
確定しているが、実装は後続 PR**であり、現状コードはまだ query 名フィルタを
施行していない（＝上記「現状の実装」の残余リスクが今は残る）。

**施行後も残る限界（誇大化せず正直に）**: FR-11 を実装しても次の 3 経路は
塞げない。(1) **許可ドメイン配下サブドメインを使った低帯域チャネル**
(許可 CDN ドメイン配下に攻撃者制御サブドメインを置き query 名に少量データを
エンコード)、(2) **許可ドメインへの HTTPS 確立後の通信本文 / TLS SNI を経由した
exfiltration** (DNS 層外)、(3) **既知の許可 IP への直接通信**
(`allowed-hosts` は IP ベース ACCEPT のため、許可 IP を既知/学習したプロセスは
DNS をプロキシ経由せず直接トラフィックを送れる)。残余リスクはこの 3 経路に限定。

ホスト DNS が変わった場合や CDN の IP ローテーション時は
`aidock firewall-refresh` で再取得する。

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

## コードレビュー / PR 運用

コードレビューは Claude Code のレビュースキル `/code-review ultra` と `/security-review ultra` で行う（`chatgpt-codex-connector[bot]` による codex 自動レビューは廃止済み）。運用ルールは次のとおり。

- **PR は open で作成する**（draft ではない）。
- PR を ready 化して open にした直後、および PR ブランチへ push するたび（初回 PR 作成時を含む）に **`/code-review ultra` と `/security-review ultra` を差分に対して実行**する。指摘は対応可否を判断して反映し、対応・見送りの理由をチャットで報告する。
- **CI の成否（グリーン）は AI アシスタントが GitHub MCP（check-runs / status）で取得して報告する**。PR コメントでの検証・要約は `post-ci-verify.yml`（FR-9）が引き続き担う。

詳細は `docs/requirements.md` の FR-7、AI アシスタント向けの運用は `CLAUDE.md` §13 を参照。

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
├── test/guard_test.sh      # guard_workspace() 等の自動テスト（CI から実行）
├── test/entrypoint_test.sh # entrypoint.sh の SEC-13 二重キーテスト（CI から実行）
├── docs/
│   └── requirements.md     # 要件定義書（正本 / Source of Truth）
├── .hadolint.yaml          # hadolint 設定（DL3008 除外）
└── .gitignore
```

## カスタマイズ

- **メモリ上限**: `compose.yaml` の `mem_limit` / `NODE_OPTIONS`
- **CPU 上限**: 同 `cpus`
- **allowlist 追加**: `docker/init-firewall.sh` の `CORE_HOSTS` 配列
- **テレメトリ無効化**: `CORE_HOSTS` から `statsig.anthropic.com` / `sentry.io` を削除
- **Claude Code バージョン固定**: `docker/Dockerfile` の `ARG CLAUDE_CODE_VERSION`
