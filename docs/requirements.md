# AI-Docker-Environment 要件定義書

本書は `AI-Docker-Environment` における **すべての実装が従うべき正本（Source of Truth）** である。
コード（`bin/aidock` / `compose.yaml` / `docker/**`）・ドキュメント（`README.md` / `CLAUDE.md`）・新機能の提案は、本書と矛盾してはならない。
変更が必要な場合は **先に本書を改訂し、PR 内で根拠を述べた上で実装に着手する**。

- **対象バージョン**: v1 系（Linux 専用、Claude Code 公式 CLI を Docker でサンドボックス化）
- **最終更新**: 2026-07-14
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
- **カーネルレベルの全 syscall 監査**（seccomp-bpf によるトレース、auditd / eBPF による syscall ログ等）。エージェントの挙動を syscall 粒度で完全記録する「フライトレコーダー」のうち、カーネル介入を要する層は v1 スコープ外とする（DNS query 名の allowlist 施行と拒否ログ＝FR-11 までを v1 の説明責任の到達点とする）。
- **Sigstore 等の公開透明性ログ（transparency log）への必須記録**。供給網・監査ログの公開検証可能性は **opt-in 拡張**として将来検討の余地を残すが、v1 では必須化しない（ネットワーク依存とプライバシー上の含意があるため既定では無効）。

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
| FR-1.3 | `run [args...]` / 引数なし | `$PWD` を `/workspace` に bind mount して Claude Code を起動。`run` は既定サブコマンド。追加 `args` は `compose run --rm claude` に **位置引数として無変換で渡される**（SEC-14 参照）。**`AIDOCK_PROFILE=run` を明示的に固定する**（呼び出し元シェルのアンビエントな値を上書きする。SEC-19）。 |
| FR-1.4 | `shell` / `bash` | 同マウントで bash を起動。**`AIDOCK_PROFILE=run` を明示的に固定する**（FR-1.3 と同様。SEC-19）。 |
| FR-1.5 | `firewall-refresh` | 稼働中の **全 `claude` コンテナ**で `init-firewall.sh` を再実行（DNS 再解決）。`compose ps -q --all --filter status=running claude` の戻り値は（`docker compose ps` は既定で `compose run` 由来の one-off コンテナを一覧から除外するが、`aidock` がコンテナを作る経路は `run`/`login`/`shell` すべて `compose run --rm` のため、`--all` で one-off を含めた上で `--filter status=running` により稼働中のみに絞る）**`compose ps` 自体の終了コードを確認した上で**行ごとに配列へ取り込み（空行はスキップ）、コンテナが 0 件なら `no running claude container` で exit 1、1 件以上なら**各コンテナで順に** `init-firewall.sh` を実行する。**`compose ps` 自体の失敗（Docker デーモン停止等）とコンテナが 0 件であることを混同しない**: `compose ps` をプロセス置換 (`< <(...)`) に直接つなぐと当該コマンド自身の終了コードを検査できず、`compose ps` の失敗が「稼働中コンテナが 1 つも無い」という誤った一次診断（`no running claude container`）に落ちてしまう。出力を変数へ一旦読み込んで `compose ps` の終了コードを明示的にチェックし、失敗時は `failed to list containers (is the Docker daemon running?)` という専用の診断メッセージで exit 1 とする。複数 claude コンテナを同時起動した場合（例: `run` と `shell` の並行）に複数 CID を改行連結したまま単一引数として `docker exec` へ渡すと無効なコンテナ ID になり失敗するため、CID は必ず 1 件ずつ分離して渡す。再実行は **best-effort**: あるコンテナで失敗しても残りのコンテナの再実行は中断せず、失敗を stderr に記録した上で **1 件でも失敗があれば最終的に非ゼロ exit** する。**重要（DNS プロキシとの整合）**: refresh は既に起動済みのコンテナ内で `init-firewall.sh` を再実行するため、その時点の `/etc/resolv.conf` は FR-11.1 により既に `127.0.0.1`（自プロキシ）を指している。`allowed-dns` を resolv.conf から再導出すると上流が「ローカルプロキシ自身」になりプロキシの forward が落ちて refresh 後に全 DNS が壊れるため、**`init-firewall.sh` は初回起動時に退避した元上流ネームサーバ（FR-11.1 の永続化値）を再利用**しなければならない（resolv.conf からの再捕捉は退避値が無いときのみ）。 |
| FR-1.6 | `logout` | `compose down -v` でサービスと名前付きボリューム（`claude-home`）を破棄し、OAuth 資格情報を失わせる。**`compose down -v` の終了コードを伝播する**: 失敗時は stderr に警告を出し非ゼロ exit、成功時のみ success メッセージを表示する（best-effort で握りつぶさない。AC-5 / SEC-10）。**テアダウンは `compose down -v` のみを唯一の権威ソースとする**: Compose がプロジェクト名でスコープした実ボリューム名（既定では小文字化したディレクトリ名 + `_claude-home`、例 `ai-docker-environment_claude-home`）を自動解決して削除する。**固定名 `docker volume rm aidock_claude-home` は実装しない**（#9 で撤去済み）: 当該リテラルは本リポジトリの実プロジェクト名と一致せず無効であるばかりか、別文脈（他チェックアウト・別プロジェクト等）で作られた **同名グローバルボリューム** を指して **意図せず他プロジェクトの資格情報を削除する破壊的副作用** を持つため、再導入してはならない。 |
| FR-1.7 | `help` / `-h` / `--help` | `usage` を表示。 |
| FR-1.8 | 未知のサブコマンド | エラーメッセージを stderr に出力し exit code 1。 |

### FR-2: ワークスペースマウント
- `$PWD` を `/workspace:rw` に bind mount する（`compose.yaml` の `HOST_WORKSPACE`）。
- FR-2.1: **`/` を `/workspace` としてマウントしてはならない**。検知時は exit code 2 で拒否（`guard_workspace`）。
- FR-2.2: **`$HOME` を `/workspace` としてマウントしてはならない**。同上。
- FR-2.3: `$HOME` / `/` 以外への追加 bind mount を勝手に増やさない（特に `~/.ssh`・`~/.aws`・`~/.gitconfig`・`~/.config/gh` 等）。
- FR-2.4: `compose.yaml` の `HOST_WORKSPACE` には **デフォルト値を持たせない**（`${HOST_WORKSPACE:?...}`）。`bin/aidock` を経由せず `docker compose run claude` を直接実行した場合は、カレントディレクトリを暗黙にマウントせず **起動失敗（fail-closed）** とする。`bin/aidock` は `compose()` ラッパーで常に `HOST_WORKSPACE` を設定する: マウントを伴う `run` / `login` / `shell` は **`guard_workspace()` が標準出力へ返す、`realpath` で正規化済みの検証済み実パス**（生の `$PWD` ではない）、マウント不要な `build` / `logout` / `firewall-refresh` は補間のための非機密プレースホルダ（`/nonexistent`、コンテナを対話起動しないため実マウントされない）。これにより SEC-8 一次防御 (a) を `bin/aidock` 非経由でも機能させる。**TOCTOU 対策**: `guard_workspace()` の検証時点と `docker compose run` 実行時点の間に生の `$PWD` を再利用すると、`$PWD` がシンボリックリンクの場合にその向き先を検証後に差し替えることで、検証したパスとは別の場所が bind mount されてしまう窓が生じる。`guard_workspace()` が返した実パスをそのまま `HOST_WORKSPACE` に使うことでこの窓を閉じる。

### FR-3: OAuth 資格情報
- `claude-home` という名前付きボリュームを `/home/agent/.claude` にマウントする。
- FR-3.1: 資格情報はホスト FS にも Docker イメージ層にも書き出さない。
- FR-3.2: `logout` で同ボリュームを破棄できる。
- FR-3.3: ボリューム配下のファイルは `build` 時の `HOST_UID:HOST_GID` で所有される。`agent` ユーザ自体も `Dockerfile` で同 UID/GID を持って生成されるため、ホストの UID/GID が変わった場合は **`aidock build` でイメージを再構築 → `aidock logout` でボリュームを破棄 → `aidock login`** の順で実施する（イメージを再ビルドせずにボリュームのみ作り直しても、`HOME=/home/agent` の所有者は古い UID/GID のままで AC-7 が失敗し続ける）。**マルチユーザー共用ホストでは利用終了時に必ず `aidock logout` を実行する**（資格情報がボリュームに残るため）。

### FR-4: ファイアウォール初期化
- コンテナ起動時、`AIDOCK_SKIP_FIREWALL=1` でない限り `init-firewall.sh` を実行する。entrypoint は **root** で起動して `init-firewall.sh` を直接実行し（sudo は使わない）、初期化後に `gosu agent` でワークロードを exec する（SEC-6 / SEC-7 参照）。
- FR-4.0: `AIDOCK_SKIP_FIREWALL=1` が設定されているときに限り初期化をスキップする。**デバッグ専用** であり、CI および共有ホストでは設定しない（SEC-13）。スキップは egress 許可リスト（製品の一次防御）を無効化するため、**二重キー要件**として `AIDOCK_INSECURE_ACK=1` の併設を必須とする: `AIDOCK_SKIP_FIREWALL=1` 単独では `entrypoint.sh` が **fail-closed で起動拒否（exit 1）** し、両方が揃ったときのみスキップしてワークロードを起動する。スキップ起動時は「無制限 egress」である旨の恒久警告を stderr に出力する。これは単一の環境変数（shell 継承・`compose.override`・将来の env 転送）が無言でサンドボックスを開放するのを防ぐ（issue #33）。**実装済み**（`entrypoint.sh`）。
- FR-4.1: 既定で IPv4 `INPUT`/`FORWARD`/`OUTPUT` を `DROP`。**IPv6 も同様に `ip6tables` で `INPUT`/`FORWARD`/`OUTPUT` を `DROP`** とする（SEC-16）。IPv6 スタックの有無は **カーネル状態（`/proc/sys/net/ipv6` の有無）** で判定する。読み取り専用の `ip6tables -L` プローブで判定すると、プローブ自身の一時失敗（xtables ロック競合・モジュール autoload タイミング）で **fail-open**（v6 接続があるのに DROP 未設置）になりうるため採用しない。`/proc/sys/net/ipv6` が存在する＝カーネルに ipv6 モジュールがロード済み（`ipv6.disable=1` 起動では非存在）の場合は **v6 をフィルタすると確定**し、`ip6tables` の失敗は `set -e` で致命（fail-closed: firewall 構築失敗＝起動しない）とする。必ず DROP ポリシーを先に設置してから許可ルールを足す。非存在時は v6 スタック自体が無く攻撃面が無いためスキップする。**実装済み**（`init-firewall.sh`）。
- FR-4.2: loopback、`ESTABLISHED,RELATED`、DNS(53/udp,tcp) のみ恒久許可。ただし **loopback 包括 ACCEPT は 53 番には無条件適用しない**: Docker 組込 DNS も loopback（`127.0.0.11:53`）であるため、53/udp,tcp に限っては FR-11.2 が定める 2 経路（(a) `agent`→`127.0.0.1:53` プロキシ、(b) プロキシ→`127.0.0.11:53` forward）だけを包括 lo ACCEPT より前に許可し、`agent` から `127.0.0.11:53` への**直接**送信（プロキシ迂回）を DROP する。DNS(53) の上流宛先は **全宛先ではなく `/etc/resolv.conf` の `nameserver`（書換え前に捕捉した元上流。FR-11.1）に対応する IPv4 アドレス**（ipset `allowed-dns`）に限定する（SEC-15）。**IPv6 の DNS egress も同様に v6 `nameserver`（ipset `allowed-dns6`）に限定する**（Docker 組込み DNS は通常 IPv4 `127.0.0.11` のため `allowed-dns6` は空のことが多く、その場合 v6 DNS egress が遮断されるだけで v4 解決には影響しない。SEC-16）。これは任意の攻撃者制御リゾルバへの直接送信を断つ defense-in-depth であり、**iptables/ipset 層だけでは正規リゾルバの再帰解決を経由する query 名 exfiltration を防げない**。この query 名フィルタの不足は **FR-11（コンテナ内ユーザー空間 DNS プロキシ）で施行**し、53 番の egress 経路自体も上記 2 経路（プロキシ→組込 DNS の forward と agent→プロキシ）のみに絞る（限界と残余リスクは SEC-15 / FR-11 参照）。`nameserver` を 1 件も検出できない場合は warn ログを残し、DNS egress は遮断される（終端プローブ FR-4.6 が名前解決失敗で fail するため fail-closed に倒れる）。**実装済み**（query 名施行と loopback 53 番限定を担う FR-11 は要件先行で実装は後続 PR）。
- FR-4.3: `CORE_HOSTS` 全件を DNS 解決し ipset `allowed-hosts` に投入。**IPv6 スタックがある場合は同じホストの AAAA レコードも解決して `allowed-hosts6` に投入する**（SEC-16）。DNS 解決に失敗したホスト（A／AAAA のいずれも）は **warn ログを残してスキップ**し、初期化は継続する（best-effort、FR-4.7）。AAAA を持たないホストのスキップは正常系。
- FR-4.4: `AIDOCK_PROFILE=login` の場合のみ `LOGIN_EXTRA_HOSTS` も投入。
- FR-4.5: GitHub `https://api.github.com/meta` から CIDR を取得し ipset へ追加。取得した CIDR は SEC-12.1（正規表現）/ SEC-12.2（octet 0-255・prefix 0-32 の範囲）の検証を **両方** 通過した場合にのみ追加する（いずれも実装済み）。範囲外の CIDR は warn ログを残してスキップする（FR-4.7 best-effort）。meta 取得は **一過性の失敗に対し shell の有界リトライループ**で再試行する（issue #13）。これは初回 DNS 解決失敗・瞬断・レート制限 429・5xx 等の transient error を吸収し、CIDR フォールバック欠落による（GitHub IP ローテーション時の）接続失敗余地を縮小する目的。**curl のリトライフラグではなく shell ループ**を用いるのは、再試行したい集合が「transport エラー（DNS exit 6・connect・timeout 等）＋ HTTP 408/429/5xx」であり、curl 単体では表現できないため: 素の `--retry` は DNS 解決失敗を再試行せず、`--retry-all-errors`（`-f` 併用）は逆に 403/404 等の**ハード HTTP エラーまで再試行**してしまい「403 は即 warn-continue」という本契約に反し毎起動で無駄な遅延を生む。ループの不変条件: **最大 3 試行かつ累積 ~20s の実時間デッドライン**（transient を返し続ける server がコンテナ起動を無限に引き延ばせない）。レスポンス本文は **`-o <tmpfile>`（`/tmp` tmpfs）で受け、`2xx` 成功時のみ読み出す**ため、失敗試行の部分バイトが JSON を壊して jq の CIDR 抽出を 0 件にすることがない。ハード HTTP エラー（403/404 等）は再試行せず即座に warn ログで継続しホスト名解決 IP の範囲に縮退する。なお **transport 失敗での再試行前には `resolve_and_add api.github.com` を再実行**して新たに解決した IP を allowlist に admit する: 冒頭 CORE_HOSTS の解決が失敗していると ipset に API の IP が無く、直前の ACCEPT ルールが後続の解決 IP も DROP するため、再 admit 無しでは初回 DNS 失敗からリトライで回復できない（IP ローテーションにも追随）。（codex P2 レビュー ×5 反映）。**取得 JSON には IPv6 CIDR も含まれるため、IPv6 スタックがある場合は v6 CIDR（prefix 0-128 を検証）を `allowed-hosts6` に投入する**（SEC-16）。**初期化順序（issue #34）**: 許可リスト依存の meta fetch を行う**前**に終端 `DROP`（v4: `iptables -A OUTPUT -j DROP`、v6: 同 `ip6tables`）を明示設置する。従来は meta fetch の後に終端 DROP を足しており、fetch/DNS 解決フェーズの拒否を chain の **デフォルトポリシー** のみに依存していた（ポリシーが DROP のため塞がってはいたが、将来ポリシーを一時 ACCEPT に倒す変更で fail-open 窓が開く脆さがあった）。ACCEPT→DROP を先頭で固定しても、api.github.com は CORE_HOSTS 解決で既に admit 済みのため meta fetch は成功し、以降の `ipset add` は稼働中の ACCEPT ルール下で即時反映される。**残存リスク（issue #34）**: 本方式は IP/ipset ベースのため、許可 IP を共有するマルチテナント CDN（Fastly/Cloudflare/GitHub）上のホストは到達可能で、短 TTL/rebinding で pin 済み IP が別テナントに移ることもある。GitHub `/meta` の広い netblock 取り込みはこれを更に拡大する。これは IP 許可リストの受容済み限界であり、厳密な制約には SNI/Host 認識型 egress proxy が必要。**実装済み**。
- FR-4.6: 最後に検証プローブを実行する（AC-4 と同表現で揃える）。
  - `curl -fsS --max-time 3 https://example.com` が **non-zero exit** であること（接続拒否・タイムアウト・名前解決失敗のいずれも成功扱い）。到達した場合は exit 1。**IPv6 スタックがある場合は `curl -6 -fsS --max-time 3 https://example.com` も non-zero であること**を併せて検証する（v6 DROP による遮断・v6 ルート不在のいずれも成功扱い、到達したら exit 1。SEC-16）。**実装済み**。
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
- レビューは **Codex 接続済み GitHub アカウント** から `@codex review` コメントを投稿することで発火する。
- **`github-actions[bot]` 等の bot 名義の `@codex review` は拒否される**ため、ワークフローによる自動投稿は **採用しない**（過去に `.github/workflows/codex-review.yml` で試みたが codex 側が「create a Codex account」と返却するため撤去済み）。
- Claude は **PR を open（draft ではない）で作成**する。**Claude Code の GitHub 操作（MCP）が izumacha 名義（OWNER）で記録される実行環境では、Claude が投稿する `@codex review` コメントも Codex に受理される**（実証済み）ため、Claude 自身がレビューを発火できる。
  - **運用ルール**: Claude は **差分を push するたびに（初回 PR 作成時を含む）`@codex review` コメントを投稿**して初回・再レビューを発火させる。質問への返信やレビューを要しない状況報告コメントには付けない。
  - **CI の成否（グリーン）は Claude が GitHub MCP（check-runs / status）で取得し、Claude 上（チャット）で報告する**（PR コメントでの検証・要約は引き続き FR-9 の Claude Code Action が担う）。
  - Claude の操作が `github-actions[bot]` 等の bot 名義になる実行環境では従来どおり受理されないため、izumacha の手動 `@codex review` 投稿が必要。

### FR-8: CI ワークフロー
`.github/workflows/ci.yml`（GitHub Actions）で**型チェック**と **e2e** を実行する。push（全ブランチ）および `main` への pull_request で発火し、`permissions: contents: read` のみを付与する（FR-7 に従い codex へのコメント投稿は行わない）。

- FR-8.1: **type-check ジョブ**は次の静的解析を実行し、いずれか失敗で CI を不合格とする。
  - `shellcheck`（v0.11.0、GitHub Releases から取得した固定版）を全シェルスクリプト（`bin/aidock`・`docker/init-firewall.sh`・`docker/entrypoint.sh`）に適用。
  - `bash -n` による構文チェック。
  - `hadolint`（v2.14.0、GitHub Releases から取得した固定版）で `docker/Dockerfile` を検査。`DL3008`（apt パッケージのバージョン固定）は `.hadolint.yaml` で除外する（理由は NFR-5.1: 再現性は `CLAUDE_CODE_VERSION` 固定と `--no-install-recommends` で担保し、OS ライブラリの逐一ピン留めは方針外）。`shellcheck` / `bash -n` は `test/guard_test.sh` も対象に含める。
  - `docker compose -f compose.yaml config -q` による compose 定義の妥当性検証。加えて `HOST_WORKSPACE` 未設定での `docker compose config` が **非ゼロ exit** することを検証し、SEC-8(a) の fail-closed（`${HOST_WORKSPACE:?...}`）を回帰検出する（AC-2）。
  - `bash test/guard_test.sh` による `guard_workspace()` の自動テスト（SEC-8 / AC-2）。`getent` / `docker` を PATH スタブで差し替えた**ハーメティック（Docker 不要）**なブラックボックステストで、SEC-8 列挙の全機密パス（ディレクトリ/ファイル名）、`/` と `$HOME` の拒否、`HOME` 偽装（空・unset・`/tmp` 等）でのバイパス不能性、docker socket ブランチ、passwd home 解決失敗時の fail-closed、非機密ディレクトリの通過を `exit 2` / 通過で検証する。拒否系は compose 到達前に `exit 2` するため type-check ジョブで実行する。同テストは FR-1.5 の回帰も固定化する: docker スタブを「`--all --filter status=running` が揃った `compose ps` にのみ CID を返す」ものに差し替え、one-off コンテナ発見フラグの退行（`--all` の削除等）を検出する。
- FR-8.2: **e2e ジョブ**（type-check 成功後に実行）は GitHub-hosted runner 上で受け入れ基準を実機検証する。検証項目と AC の対応は AC-8 を参照。SEC-13 に従い `AIDOCK_SKIP_FIREWALL` は設定せず、**実ファイアウォールを起動した状態で検証する**。
- FR-8.3: e2e は外部 egress（`api.anthropic.com` / `claude.ai` / `api.github.com`）に依存する。各プローブは `--max-time` を持つが、ネットワーク要因による一時失敗の可能性がある（残存リスク）。

### FR-9: CI 後の Claude 検証エージェント
`.github/workflows/post-ci-verify.yml`（GitHub Actions）で、CI 成功後に Claude Code Action（`anthropics/claude-code-action@v1`）を起動し、結果を検証・要約して PR にコメントする。

- FR-9.1: トリガは `workflow_run`（`workflows: ["CI"]`, `types: [completed]`）。`github.event.workflow_run.conclusion == 'success'` かつ `event == 'pull_request'` のときのみ実行する。
- FR-9.2: PR 番号は `workflow_run.pull_requests[0].number` で解決する。空の場合のフォールバックは **同一リポジトリ実行（`head_repository.full_name == owner/repo`）に限定**し、`head_branch` の open PR のうち **`head.sha == workflow_run.head_sha` に一致する PR** を選ぶ（同名 head ブランチの複数 PR で誤った相手にコメントしないため）。fork PR は `pull_requests[]` が空かつ同一リポジトリ判定で弾かれ実質スキップ（セキュリティ上も望ましい）。
- FR-9.3: 認証は **Claude GitHub App + OAuth**。リポジトリ secret `CLAUDE_CODE_OAUTH_TOKEN` を `claude_code_oauth_token` 入力で渡す（代替として `ANTHROPIC_API_KEY` + `anthropic_api_key` も可）。当該 secret は **GitHub Actions secret** でありイメージ層・コンテナには持ち込まない（SEC-10 と整合）。`permissions` は `contents: read` / `pull-requests: write` / `actions: read` / `id-token: write`（最後は Claude GitHub App の OIDC 用。FR-9.6(d) 参照）。
- FR-9.4: エージェントは type-check / e2e（AC-1〜AC-4 / AC-7）の結果を検証・要約し、PR に**コメント1件**を投稿する。**コミット・ファイル変更・push は行わない**（CI は push/PR でのみ発火し、コメントでは再発火しないため無限ループしない）。
- FR-9.5: `workflow_run` は**デフォルトブランチ（`main`）上のワークフローのみ発火**する。本ワークフローは `main` マージ後の PR から有効になる。
- FR-9.6: 特権ワークフロー（`pull-requests: write` ＋ secret）の堅牢化として、(a) PR head を **checkout しない**（非信頼コードをワークスペースに展開しない）、(b) action は **可変タグではなくフル commit SHA へピン**する（供給網リスク回避）。`claude-code-action` は `git ls-remote` で v1 annotated タグから解決した v1.0.135 = `70a6e525…`、`actions/github-script` は v7.1.0 = `f28e40c7…` にピン済み（#17 で確定）、(c) Claude のツールを **`gh run view` / `gh pr comment` に限定**する（`--allowedTools`）。なお action は `GH_TOKEN` を Claude App トークンへ上書きし、その既定スコープに Actions read が含まれないため、`gh run view`（private repo で必須）向けに **`additional_permissions: actions: read`** を明示付与する、(d) `github_token` 入力を省略し **Claude GitHub App 認証**を用いるため、**`permissions: id-token: write`** を付与済み（OIDC トークン交換に必須。未付与だと検証 step が認証失敗）。secret `CLAUDE_CODE_OAUTH_TOKEN` 登録後に有効化（#17）。

### FR-11: コンテナ内 DNS プロキシ（query 名 allowlist 施行）
SEC-15 が iptables/ipset 層で残していた **query 名 exfiltration** の穴を施行へ転換するため、コンテナ内にユーザー空間の forwarding DNS プロキシを置き、**問い合わせドメイン名（query 名）を policy 由来の allowlist で照合**する。許可名のみ上流（Docker 組込 DNS `127.0.0.11`）へ forward し、未許可名は記録の上 NXDOMAIN を返す。これは「許可した IP へしか出られない」（FR-4 / SEC-15）に加え「**許可したドメイン名しか引けない**」を成立させる第二の関門であり、`<secret>.attacker.example` のような正規リゾルバ経由の query 名チャネルを権威 NS 到達前に遮断する。**要件先行**（実装は後続 PR）。

- FR-11.1: **配置と上流ネームサーバの退避・永続化**。コンテナ内 `127.0.0.1:53` にユーザー空間の forwarding プロキシを bind し、`/etc/resolv.conf` の `nameserver` を `127.0.0.1` に向ける。`agent` から発行される全 DNS 問い合わせはまずプロキシを経由する。**重要（書換え順序）**: `allowed-dns`（ipset）は SEC-15 / FR-4.2 に従い `/etc/resolv.conf` の `nameserver` から導出されるため、resolv.conf を `127.0.0.1` に書き換える**前に元の上流ネームサーバ（典型的には Docker 組込 DNS `127.0.0.11`）を必ず捕捉**し、プロキシの forward 先および `allowed-dns` の**種（seed）として明示的に保持する**。これを怠ると、書換え後の resolv.conf にはローカルプロキシ（`127.0.0.1`）しか残らず、`allowed-dns` に上流 DNS が入らずプロキシの forward が `allowed-dns` ルールで落ちて**全解決が失敗**する。よって `allowed-dns` には少なくとも「捕捉した元上流（`127.0.0.11` 等）」を含め、`127.0.0.1`（自プロキシ）宛は別途 FR-11.2 のループバック例外で扱う。
  - **捕捉した上流の永続化（再実行耐性）**: 捕捉した元上流ネームサーバは、**resolv.conf とは独立した固定パス（例: `/run/aidock/upstream-dns`、tmpfs 上の書込み可能領域）へ永続化**し、`firewall-refresh`（FR-1.5）が**起動済みコンテナ内で `init-firewall.sh` を再実行**する際は **resolv.conf から再導出せず、この退避値を再利用**する。理由: 初回初期化後の resolv.conf は既に `127.0.0.1`（自プロキシ）を指すため、refresh 時に resolv.conf から `allowed-dns` を再導出すると上流が「ローカルプロキシ自身」になり、プロキシの forward 先が自分自身を指して **forward が成立せず refresh 後に全 DNS が壊れる**。よって `init-firewall.sh` は「退避値が既に存在すればそれを真とし、無い場合に限り resolv.conf から捕捉して退避する」順序とし、初回起動と refresh の双方で同一の上流へ forward する。退避先は read-only rootfs（SEC-3）の例外となる tmpfs / 書込み可能領域に置き、機微情報（上流 DNS の IP）はログに出すがホスト FS には書き出さない。
- FR-11.2: **53 番 egress の絞り込みとループバック例外の限定**（iptables）。53/udp,tcp について、許可する DNS 経路は次の **2 経路のみ** とし、それ以外の 53 番宛は **DROP** する:
    - **(a) `agent` → `127.0.0.1:53`（ローカルプロキシ）**: `agent` の resolver は FR-11.1 によりここを向く。プロキシ自身への loopback 送信を許可する。
    - **(b) プロキシ（プロキシのプロセス／loopback）→ Docker 組込 DNS（`127.0.0.11:53`）への forward**: 許可名を上流解決するための唯一の出口。ipset `allowed-dns`（SEC-15）の宛先限定はこの上流 forward に引き続き適用する。
  - 上記 (a)(b) **以外の `agent` からの 53 番 egress（`127.0.0.11` への直接送信を含む）は DROP** する。これにより allowlist を回避してプロキシを迂回する直接問い合わせを断つ。
  - **識別境界（プロキシと `agent` の区別が宛先/ポートだけでは付かない問題）**: 現行 entrypoint はワークロードを `gosu agent` で降格して実行する（SEC-7）。**プロキシも同じ `agent` UID で動かすと、(b) のプロキシ→`127.0.0.11:53` forward と、迂回を断つべき `agent` の `127.0.0.11:53` 直接送信は、iptables から見て送信元/宛先/ポートがすべて同一になり区別できない**。そのため (b) のみを ACCEPT し迂回直送を DROP するルールが書けない。したがって **プロキシは `agent` とは異なる識別子（専用 UID/GID、典型的には専用の `dnsproxy` ユーザー）で動作させ、iptables は `owner` マッチ（`-m owner --uid-owner <proxy-uid>`）でプロキシ発の forward と `agent` 直送を区別する**こと（パケットマーキング `-m owner ... -j MARK` ＋ `-m mark` による識別でも可）。これにより「プロキシ（専用 UID）→`127.0.0.11:53` は ACCEPT、`agent` UID → `127.0.0.11:53` は DROP」を宛先一致のまま owner 条件で分離できる。
    - **SEC-1 / gosu 降格モデルとの整合**: プロキシを専用 UID で起動するのは entrypoint が root で `init-firewall.sh` を実行する段（`gosu agent` 降格より前）にプロキシを `gosu dnsproxy` 等で立ち上げる構成を想定する。プロキシ専用ユーザーも capability を持たない非特権ユーザーとし、`no-new-privileges`（SEC-2）と `cap_drop: ALL`（SEC-1）の不変条件は維持する（プロキシ用に追加 capability を付与しない。53 番低位ポートの bind は loopback 上のユーザー空間プロキシであり、必要なら `CAP_NET_BIND_SERVICE` ではなく非特権ポート＋iptables リダイレクト等の代替で capability 追加を避ける）。SETUID/SETGID は既に entrypoint の `gosu` 用に許可済み（SEC-1）であり、`agent` と `dnsproxy` の 2 系統への降格に流用できるため **追加 capability は不要**。`agent` と `dnsproxy` の UID 分離は降格対象を 2 つにするだけで、降格後はいずれも capability ゼロを保つ。
  - **ループバック例外の 53 番限定（順序付け）**: 現行ファイアウォールの包括的な `iptables -A OUTPUT -o lo -j ACCEPT` は、Docker 組込 DNS も loopback（`127.0.0.11:53`）であるため、`agent` が `127.0.0.11:53` へ直接 DNS を送ってプロキシを迂回できてしまう。したがって **loopback 包括 ACCEPT を 53 番についてはそのまま適用せず**、53/udp,tcp に限っては上記 (a)(b) の経路だけを許可するルールを **包括 lo ACCEPT より前に評価**し、`127.0.0.11:53` への直接送信（プロキシ経由でない loopback DNS）を **DROP** する。53 番以外の loopback トラフィックは従来どおり ACCEPT してよい。
- FR-11.3: **照合ロジック**。プロキシは受信した query 名を **policy 由来の許可ホスト名集合**（`CORE_HOSTS` / `AIDOCK_PROFILE=login` 時の `LOGIN_EXTRA_HOSTS` と同一の単一ソースに由来）と照合する。完全一致に加え、**許可ホストの親ドメイン配下サブドメインの扱いは最小限**に留める（ワイルドカード許可は CDN 等で必要な範囲に限定し、無制限の `*.example.com` 許可を既定にしない）。許可名は上流へ forward し、**拒否名は `[dns-proxy]` プレフィックスで stderr に記録した上で NXDOMAIN を返す**（FR-5 のログ方針に従う）。**拒否レスポンスコードは NXDOMAIN に統一する**（健全性プローブ FR-11.5 / AC-10 が NXDOMAIN を要求するため。`REFUSED` 等を混在させない。仮にプローブ側で両方を受理する余地を残す場合は FR-11.5 / AC-10 にその旨を明記してプロキシ実装と一致させる）。
- FR-11.4: **fail-closed**。プロキシの起動・bind に失敗した場合、または上流 forward 経路が確立できない場合は **DNS を全断**し、entrypoint を **非ゼロ exit** で停止する（DNS フィルタが効かない状態でワークロードを起動しない）。`AIDOCK_SKIP_FIREWALL=1`（SEC-13、デバッグ専用）配下の挙動のみ例外とし、CI / 共有ホストでは設定しない。
- FR-11.5: **健全性プローブ**。`init-firewall.sh` 終端の検証プローブ（FR-4.6）に DNS プロキシのプローブを追加する: (a) **許可ドメイン**（例 `api.anthropic.com`）が解決できること、(b) **不許可ドメイン**が **NXDOMAIN になる**こと。(b) のテスト名は AC-10 と同様に「**プロキシが無ければ通常は解決する**が allowlist に無いドメイン」（例: `example.com` 自身——実在し A レコードを返すが allowlist 外）を用い、予約 TLD `.example` / `.invalid` や上流が元々 NXDOMAIN を返す名前は使わない（プロキシ不在でも NXDOMAIN になり施行を証明できないため）。**拒否コードは NXDOMAIN とする**（FR-11.3 と統一。プローブが `REFUSED` も受理する場合は本項にその旨を明記しプロキシ実装と一致させる）。いずれか不一致なら `exit 1`（fail-closed）。AC-10 と同表現で揃える。
- FR-11.6: **二重 allowlist の同期**。本プロキシの「**名前** allowlist」と ipset `allowed-hosts` の「**IP** allowlist」は、いずれも同一の policy（`CORE_HOSTS` / `LOGIN_EXTRA_HOSTS`）を単一ソースとして導出する。両者の不整合（名前は許可だが IP 未投入、またはその逆）は接続失敗や穴につながるため、**将来 Phase で policy を機械可読な単一ファイルへ外出しし、ipset 構築とプロキシ設定の双方が同一ソースを読む構成へ収斂させる**（前方参照: §1.3 のスコープ拡張候補）。本 FR では「同一 policy から導出する」契約の明文化に留め、単一ファイル化は後続とする。
- FR-11.7: **限界と残余リスク**（誇大表現を避けるため正直に明記）。本プロキシは query 名を allowlist 化するが、次の経路は塞げない:
    - **(1) 許可ドメイン配下サブドメインを使った低帯域チャネル**（例: 許可した CDN ドメイン配下に攻撃者が制御するサブドメインを用意し、query 名にエンコードした少量データを漏出させる経路）。
    - **(2) 許可ドメインへの HTTPS 接続が確立した後の通信本文・TLS SNI を経由する exfiltration**（DNS 層の問題ではなく本 FR の対象外。egress 先 IP が allowlist 内であっても、許可ドメイン経由のデータ持ち出しは別レイヤの課題）。
    - **(3) 既知の許可 IP への直接通信**。ipset `allowed-hosts` は **IP（アドレス）ベースの ACCEPT** であるため、**許可 IP を既に知っている／学習したプロセスは、DNS をプロキシ経由せず（名前解決を一切行わず）その IP へ直接任意のトラフィックを送れる**。これは query 名 allowlist でも `allowed-dns` でも塞げない経路で、(1) の許可サブドメイン DNS チャネルや (2) の HTTPS 本文 / SNI とも独立した別の exfil 経路である（DNS プロキシは「名前を引く」操作だけを仲介し、IP 直打ちの egress は対象外のため）。
  - 残余リスクは上記 (1)〜(3) に **限定**される、という到達点を SEC-15 と共有する。

---

## 4. 非機能要件（NFR）

### NFR-1: セキュリティ不変条件（**絶対遵守 / Hard Constraints**）

以下を弱める変更は不可。やむを得ず変更する場合は本書を改訂し PR 説明で理由・代替策・残存リスクを明記する。

| ID | 内容 | 根拠ファイル |
| --- | --- | --- |
| SEC-1 | `cap_drop: ALL` を維持。追加 cap は `NET_ADMIN`/`NET_RAW`（ファイアウォール用）と `SETUID`/`SETGID`（entrypoint が root→agent へ降格する `gosu` 用）のみ。降格後の `agent` プロセスは capability を持たない。**`NET_ADMIN`/`NET_RAW` を初期化後に bounding set から落とさないのは意図的**: `firewall-refresh`（稼働中コンテナで `init-firewall.sh` を再実行し DNS ローテーションへ追随）が実行時に NET_ADMIN を要し、AC-3 もその存在を回帰検証するため（issue #35 のレビューで「初期化後に cap-drop」案を検討したが、この機能要件と衝突するため不採用）。 | `compose.yaml` |
| SEC-2 | `security_opt: no-new-privileges:true` を維持。 | `compose.yaml` |
| SEC-3 | `read_only: true` を維持し、書き込み可能領域は `/workspace:rw` の明示 bind mount、必要最小限の `tmpfs`、および `claude-home` ボリュームに限定する。`/workspace:rw` は **`.git` を含むツリー全体を書き換え可能**であり、コンテナ内プロセスがコミット・履歴書換を実行しうる前提で運用する（read-only 化はサポート外）。**`$HOME` 直下の設定ファイル（`~/.gitconfig`、claude-code 本体の `~/.claude.json`。いずれも `~/.claude/`（OAuth ボリューム）とは別物）**は、`/home/agent` 自体が read-only rootfs 上にあるため素のままでは書き込めない。`Dockerfile` のビルド時に `~/.gitconfig` → `.config/gitconfig`、`~/.claude.json` → `.config/claude.json` の相対シンボリックリンクとして焼き込み、実行時は既存の `.config` tmpfs（書き込み可能）へ透過的に書き込ませる（新規 tmpfs は追加しない。issue: `$HOME` 直下の設定ファイル書き込み不可）。**残存リスク（正直に明記）**: (1) `.config` は `bin/aidock` が毎回 `compose run --rm` で使い捨てコンテナを起動するため、`claude-home`（`~/.claude/`）と異なりセッションをまたいで永続化しない。つまり `git config --global` も claude-code 自身のオンボーディング状態（`~/.claude.json` の trust dialog 承認状態等）も、コンテナを跨ぐたびに失われる（安全側の挙動ではあるが、ユーザーが `git config --global` の内容が定着すると誤解しないよう明記する）。(2) 本シンボリックリンクは claude-code（`CLAUDE_CODE_VERSION` で pin）が `~/.claude.json` を**直接 `fs.writeFileSync` する現行の書き込み方式**を前提に成立している。将来のバージョンで「同じディレクトリに一時ファイルを作ってから rename する」アトミック書き込み方式へ変更された場合、一時ファイルの作成先パスがシンボリックリンクの**解決前**のパス（`/home/agent`、read-only）から計算されると書き込みに失敗しうる。`CLAUDE_CODE_VERSION` を更新する際は、AC-1 の `~/.claude.json` 書き込みプローブが CI で引き続き通ることを確認する。**将来予告**: フライトレコーダー（エージェントの説明責任）構想では、拒否 DNS query・実行コマンド等の監査証跡を保存する **append-only な監査用ボリューム**を `read_only: true` の例外として 1 つ認める余地を残す（追記専用・改竄困難な構成に限る）。本 SEC では予告に留め、具体的なマウント設計と不変条件化は後続 PR で本書を改訂してから導入する。 | `compose.yaml` / `Dockerfile` |
| SEC-4 | `mem_limit`・`pids_limit`・`cpus` の上限を撤廃しない（既定: 4G / 1024 / 2.0）。**`memswap_limit` を `mem_limit` と同値（4G）に明示ピンする**: `memswap_limit` を指定しないと、ホストに swap が有効かつ cgroup の swap accounting が有効な環境（多くの Linux ディストリで既定）では Docker が `memswap_limit` を `mem_limit` の 2 倍として扱うため、暴走・侵害されたプロセスが文書化された 4G 上限ではなく最大 ~8G（RSS 4G + swap 4G）まで消費してから初めて OOM Killer に落とされうる。`memswap_limit: 4g` を明示することで swap による上限の実質的な倍化を防ぎ、DoS 境界を常に 4G に保つ（ホストの swap 設定に依存しない）。 | `compose.yaml` |
| SEC-5 | `iptables -P OUTPUT DROP`（既定拒否）と終端の検証プローブを維持。 | `init-firewall.sh` |
| SEC-16 | **IPv6 egress も IPv4 と同等に default-deny にする**（issue #32）。`ip6tables -P OUTPUT DROP`（INPUT/FORWARD も）を設置し、loopback・`ESTABLISHED,RELATED`・v6 nameserver（`allowed-dns6`）・AAAA 解決した許可ホスト（`allowed-hosts6`）・github meta の v6 CIDR のみ許可する。`ip6tables` が利用不能な環境（IPv6 スタック無し）は攻撃面が無いため warn してスキップ（fail-safe）。`example.com` への v6 到達が無いことを終端プローブで検証する。IPv4 のみを絞って IPv6 を素通しにする状態に戻してはならない。 | `init-firewall.sh` |
| SEC-17 | **許可ホスト（`allowed-hosts`/`allowed-hosts6`）への ACCEPT ルールは HTTPS(`-p tcp --dport 443`)に限定する**。従来はポート指定なしで許可 IP への全ポート・全プロトコルを ACCEPT していたため、`github.com` のように git-over-SSH（22 番）も提供するホストが allowlist に入ると、コンテナ内に侵入したプロセス（サプライチェーン汚染された npm postinstall・プロンプトインジェクション経由のツール呼び出し等）が許可 IP への 22 番接続を C2 / 持ち出しの汎用トンネルとして悪用でき、`init-firewall.sh` の他の部分が慎重に維持している「HTTPS API のみ」という意図を素通りできてしまっていた（イメージに `git`（SSH 経由の `git@host:22` をサポート）が入っているため現実的な経路）。CORE_HOSTS/LOGIN_EXTRA_HOSTS および GitHub meta 由来 CIDR はいずれも HTTPS 用途のみのため、443 固定は既存の許可ホストの正当な用途を妨げない。DNS(53) の許可は SEC-15 が別途規定する専用ルールであり本 SEC の対象外。 | `init-firewall.sh` |
| SEC-18 | **ホストの UID または GID が 0（root）でのコンテナ作成を fail-closed で拒否する。** `docker/Dockerfile` は `HOST_UID`/`HOST_GID`（build arg）をそのまま `groupadd -g`/`useradd -u` に渡すため、ホストユーザーが root の場合コンテナ内の `agent` ユーザーも UID/GID 0 として作成される。**UID 0（主因）**: Linux の capability クリア規則は「実効 UID が 0 から非 0 へ変わったとき」だけ有効 capability を消去する（`capabilities(7)`）ため、UID 0→0 の遷移では `entrypoint.sh` の `gosu agent` 降格を経ても `cap_add` 済みの `NET_ADMIN`/`NET_RAW` が実効 capability として残存しうる。これは SEC-1/SEC-7 が前提とする「降格後の `agent` プロセスは capability を持たない」という不変条件を崩し、コンテナ内のワークロードが `iptables`/`ip6tables` を直接操作して egress ファイアウォール（一次防御）を無効化・書き換えできてしまう。**GID 0（多層防御・capability クリアとは無関係）**: capability クリア規則は実効 UID のみを見るため、GID 0 単独は capability 残存を引き起こさない。それでも `agent` のプライマリグループがコンテナ内の root グループになると、group-root で読める既存ファイルへのアクセスが意図せず広がるため、UID 0 と同様に拒否する（理由が異なる旨をエラーメッセージ・コードコメントで区別する）。`bin/aidock` の `require_non_root_host()` は、実際にイメージをビルドしコンテナを作成する 4 コマンド（`build`/`login`/`run`/`shell`）の先頭でのみ `HOST_UID`/`HOST_GID` が非 0 であることを検証し、いずれかが `0` なら `exit 2` で拒否する（`guard_workspace()` と同じ fail-closed の流儀）。**`logout`・`firewall-refresh`・`help` はこのガードの対象外**: `logout`（`compose down -v` によるボリューム破棄）と `firewall-refresh`（既に起動済みのコンテナ内で `init-firewall.sh` を再実行するのみ）はいずれも `gosu` 降格を経由せず、コンテナの UID/GID マッピングは作成時点で既に確定しているため、ここでガードしても保護効果がない。むしろガード対象に含めると、本ガード導入前に作成された（あるいは他経路で作成された）root ホストのコンテナに対して資格情報ボリュームの後始末（`logout`）すらできなくなる副作用がある。**`docker/Dockerfile` 側にも独立した二次防御**: `bin/aidock` を経由しない直接の `docker build --build-arg HOST_GID=0`（または `docker compose build`）に備え、`Dockerfile` 自身も `HOST_GID` が `0` なら `docker build` を明示的に失敗させる（`HOST_UID=0` は `useradd -u 0` が既存の `root` ユーザーと衝突するため従来から暗黙に失敗していたが、`HOST_GID=0` は既存 `root` グループを暗黙に再利用してしまう余地があったため明示チェックを追加）。 | `bin/aidock` / `docker/Dockerfile` |
| SEC-19 | **`AIDOCK_PROFILE` を呼び出し元シェルのアンビエントな環境変数から独立させ、サブコマンドごとに `bin/aidock` が明示的に固定する。** `compose.yaml` の `environment: AIDOCK_PROFILE: "${AIDOCK_PROFILE:-run}"` は `docker compose` を起動したプロセスの環境変数をそのまま補間するため、`bin/aidock` が明示的に上書きしない限り、呼び出し元シェルにたまたま `AIDOCK_PROFILE=login` が残っていた場合（例: 直前の `aidock login` セッションで手動 `export` したまま `unset` し忘れた、共有 dotfiles やラッパースクリプトが誤って export している等）、通常の `run`/`shell` セッションでもコンテナ内の `init-firewall.sh` が `login` プロファイルとして起動し、`LOGIN_EXTRA_HOSTS`（`claude.ai`/`console.anthropic.com`/`auth.anthropic.com`/`login.anthropic.com`）への許可リストが無言で広がってしまう。これは egress 許可リストの最小化という製品の一次防御方針（SEC-7 / FR-4.4）を、ユーザーの意図しないアンビエント環境変数が弱めうるという穴であり、`AIDOCK_SKIP_FIREWALL`/`AIDOCK_INSECURE_ACK`（SEC-13）に対して既に採用している「`bin/aidock` 経由でこれらの env を無加工で素通しさせない」という設計原則から漏れていた同種の欠落だった。`cmd_run()`/`cmd_shell()` の先頭付近で `export AIDOCK_PROFILE="run"` を明示することで、実行中のサブコマンドに対応するプロファイルだけが常に使われることを保証する（`cmd_login()` は元々 `export AIDOCK_PROFILE="login"` を明示していたため対象外。`cmd_build()`/`cmd_logout()`/`cmd_firewall_refresh()` はコンテナの `entrypoint.sh`/`init-firewall.sh` を実行時に起動しない、または `docker exec` で作成済みコンテナ自身の環境を使うためスコープ外）。 | `bin/aidock` |
| SEC-6 | コンテナイメージに `sudo` を含めない。firewall 初期化は entrypoint が **root で直接実行**し、setuid による昇格を一切使わない（`no-new-privileges` 下では setuid `sudo` が root 化できないため）。 | `Dockerfile` / `entrypoint.sh` |
| SEC-7 | ワークロード（claude-code 等）は `agent` で実行する。entrypoint は firewall 初期化のためにのみ root で起動し、`gosu agent` で**不可逆に降格**してからコマンドを exec する（`no-new-privileges` 下で setuid による再昇格は不可）。 | `Dockerfile` / `entrypoint.sh` |
| SEC-8 | ホストの資格情報・設定ファイルがコンテナへ流出することを防ぐ。**一次防御**は (a) `compose.yaml` が `$PWD`（`HOST_WORKSPACE`）と `claude-home` 以外を bind mount しないこと。`HOST_WORKSPACE` は **デフォルト値を持たず**（`${HOST_WORKSPACE:?...}`、FR-2.4）、`bin/aidock` を経由しない直接の `docker compose run` は **fail-closed** で起動失敗する（カレントディレクトリの暗黙マウントを防ぐ）。(b) `bin/aidock` の `guard_workspace()` が `$HOME` と `/` を起動カレントとして拒否すること。**機械的拒否対象**: 次のパス配下から `aidock` を起動すると `guard_workspace()` が exit 2 で拒否する: `~/.ssh`、`~/.aws`、`~/.config/aws`、`~/.gcloud`、`~/.config/gcloud`、`~/.azure`、`~/.config/azure`、`~/.gitconfig`、`~/.git-credentials`、`~/.config/git`、`~/.config/gh`、`~/.config/op`（1Password CLI）、`~/.config/doctl`（DigitalOcean）、`~/.config/rclone`（クラウドストレージ資格情報）、`~/.config/hub`（GitHub トークン）、`~/.netrc`、`~/.kube`（kubeconfig）、`~/.docker`、`/var/run/docker.sock`、`~/.npmrc`、`~/.pypirc`、`~/.gnupg`（GPG 秘密鍵・キーリング）、`~/.config`（ディレクトリ自体。丸ごとマウントすると配下の `~/.config/aws`・`~/.config/gcloud`・`~/.config/azure`・`~/.config/git`・`~/.config/gh` が一括露出するため親も拒否する。`~/.config/htop` 等の非機密サブディレクトリからの起動は引き続き許可）。`guard_workspace()` は判定基準を常に passwd データベース（`getent passwd "$(id -u)"`）の実 home から導出し、呼び出し側の `$HOME` は一切信用しない。passwd home が解決できない（取得失敗・非ディレクトリ・`realpath` 失敗）場合は **fail closed** で `exit 2` とし、`$HOME` へはフォールバックしない。これにより `HOME=` クリア・`unset HOME`・別の実在ディレクトリへの偽装（`HOME=/tmp` 等）のいずれでもバイパスできない。**残余リスク（symlink 再配置）**: ガードは `realpath` で正規化した実パスを passwd home からの相対パターンで照合するため、`~/.config` 自体が home 外や別名ディレクトリへの symlink である XDG 再配置レイアウト（例: `~/.config` → `~/dotfiles/config`）では、解決後のパスがパターン名前空間に一致せず拒否できない（列挙済みの子ディレクトリも同様）。この構成の利用者は機密ディレクトリ配下から `aidock` を起動しない運用で補完すること。運用上もこれらの配下から `aidock` を起動しないことを推奨する。 | `compose.yaml` / `bin/aidock` |
| SEC-9 | `guard_workspace()` の `/` および `$HOME` 拒否を撤去・回避しない。 | `bin/aidock` |
| SEC-10 | OAuth 資格情報はイメージ層・ホスト FS に書き出さない（名前付きボリュームのみ）。 | `compose.yaml` |
| SEC-11 | allowlist に新規ホストを足すときは PR で必要性を述べる。テレメトリ系（statsig / sentry）は **削除可** だが追加は最小限に。 | `init-firewall.sh` |
| SEC-12.1 | CIDR を ipset に追加する前に正規表現 `^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$` の一致を検証する。**実装済み**（`init-firewall.sh:452` の `CIDR_RE`）。 | `init-firewall.sh` |
| SEC-12.2 | 各 octet が `0`–`255`、prefix が `0`–`32` の範囲であることを併せて検証する。**実装済み**（`init-firewall.sh` の `cidr_in_range()`。SEC-12.1 の正規表現通過後にフィールド分解し base-10（`10#`）で範囲比較。範囲外は warn ログを残してスキップし初期化は継続＝FR-4.7 best-effort）。形式的に正規表現を通る `999.999.999.999/33` 等は ipset に追加されない。 | `init-firewall.sh` |
| SEC-13 | `AIDOCK_SKIP_FIREWALL=1` の常用を禁止する。**デバッグ用バックドア**であり、CI および共有ホストでは設定しない。一時的に使用した場合はその都度 `unset` する。**スキップには二重キー `AIDOCK_INSECURE_ACK=1` の併設を必須**とし、単独指定では `entrypoint.sh` が fail-closed で起動拒否する（issue #33、FR-4.0）。両キー揃い時は無制限 egress である旨の恒久警告を出力する。`bin/aidock` 経由でこれらの env を無加工で素通しさせない運用とする。 | `entrypoint.sh` |
| SEC-14 | `bin/aidock run [args...]` の追加引数は `compose run --rm claude` に **位置引数として無変換で渡される**。コマンド置換（`$()`・バッククォート）等を含めない責任は呼び出し側が負う。ラッパー側で eval/sh -c 等の二次評価を導入してはならない。 | `bin/aidock` |
| SEC-15 | DNS(53/udp,tcp) の egress を **全宛先許可にしない**。`/etc/resolv.conf` の `nameserver` 行から抽出した IPv4 アドレスを ipset `allowed-dns` に投入し、`-m set --match-set allowed-dns dst` で宛先を限定する。**効果**: コンテナ内プロセスが**任意の攻撃者制御リゾルバへ直接** 53 番で送信する経路（不正リゾルバを使った素朴な DNS トンネル・任意 UDP/53 covert channel）を遮断する defense-in-depth。**query 名 exfiltration の施行**: iptables/ipset 層だけでは `<secret>.attacker.example` のように**正規リゾルバ（`127.0.0.11`／ホスト再帰リゾルバ）の再帰解決を経由して権威 NS（攻撃者）へ到達する query 名 exfiltration を防げない**（再帰チェーンの先まで宛先制御できないため）。この穴は従来「受容」していたが、**コンテナ内ユーザー空間 DNS プロキシ（FR-11）で query 名 allowlist を施行し、未許可ドメインは権威ネームサーバ到達前に NXDOMAIN で遮断する**方針へ改訂する。53 番 egress は FR-11.2 の **2 経路のみ**（(a) `agent`→`127.0.0.1:53` プロキシ、(b) プロキシ→組込 DNS `127.0.0.11:53` の forward）に絞り、loopback 包括 ACCEPT を 53 番には無条件適用せず `agent` から `127.0.0.11:53` への直接送信（プロキシ迂回）を DROP する。`allowed-dns` の上流宛先は resolv.conf 書換え**前に捕捉した元上流**（典型的には `127.0.0.11`）を種に導出する（FR-11.1。捕捉を怠ると上流が `allowed-dns` から抜け全解決が落ちる）。捕捉した上流は**書込み可能領域へ永続化し `firewall-refresh`（FR-1.5）の再実行でも resolv.conf から再導出せず再利用する**（refresh 時の resolv.conf は既に `127.0.0.1` を指すため再導出は上流を自プロキシにすり替え全 DNS を壊す。FR-11.1）。**プロキシの識別境界**: プロキシは `agent` とは別 UID（専用 `dnsproxy` ユーザー等）で動作させ、iptables `owner` マッチ（`--uid-owner`）で「プロキシ→`127.0.0.11:53` の forward ACCEPT」と「`agent` の `127.0.0.11:53` 直送 DROP」を宛先一致のまま分離する（同一 UID では両者を区別できずプロキシ迂回を塞げない。SEC-1 / SEC-7 の gosu 降格モデルとは追加 capability なしで整合。FR-11.2）。allowlist 構築後に 53 を全 DROP すると実行時再解決（CDN の IP ローテーション等）が壊れる問題は、プロキシが許可名を上流へ forward し続けることで回避する。**残余リスク（正直に明記）**: 施行後も次の 3 経路は塞げない: (1) **許可ドメイン配下サブドメインへの低帯域チャネル**（許可 CDN ドメイン配下に攻撃者制御サブドメインを置き query 名に少量データをエンコードする経路）、(2) **許可ドメイン経由の HTTPS 本文 / TLS SNI を使った exfiltration**（DNS 層外）、(3) **既知の許可 IP への直接通信**（`allowed-hosts` は IP ベース ACCEPT のため、許可 IP を既知／学習したプロセスは DNS をプロキシ経由せず当該 IP へ直接任意トラフィックを送れる。query 名 allowlist でも `allowed-dns` でも塞げない、(1)(2) と独立した別経路）。残余リスクはこの 3 経路に**限定**される（FR-11.7 と共有）。**実装状況**: `nameserver` 限定（ipset `allowed-dns`）は**実装済み**（`init-firewall.sh`。`nameserver` 不検出時は warn ログを残し DNS を遮断＝fail-closed）。**query 名 allowlist の施行（FR-11）は要件先行で、実装は後続 PR**。 | `init-firewall.sh` / `entrypoint.sh` |

### NFR-2: 性能・リソース
- 既定リソース上限（mem 4G / cpus 2.0 / pids 1024）で Claude Code が通常運用可能であること。
- `NODE_OPTIONS=--max-old-space-size` の Node ヒープ上限は **`mem_limit` から「ネイティブ処理用マージン（512 MiB 以上）＋ tmpfs 合計」を差し引いて設定する**。既定は `mem_limit=4096 MiB` に対し `--max-old-space-size=2368`（4096 − 512 − 1216）。`mem_limit` は SEC-4 の DoS 上限として 4G を維持し、ヒープ側のみ下げる。
  - 根拠: ヒープ上限と cgroup 上限を同値（旧 `4096`）にすると、ヒープ外領域（V8 の C++ ヒープ、JS スタック、ネイティブモジュール、`git`/`jq`/`ripgrep` 等の子プロセス）が積み上がった際に RSS 合計が `mem_limit` を超え、V8 の graceful な heap-exceeded ハンドリングより先に cgroup OOM killer が SIGKILL を送り、Claude Code が原因不明で落ちる余地があった（issue #11）。マージンを確保することでヒープ外領域の突発的な伸びを cgroup 上限内に収める。
  - `compose.yaml` の `tmpfs`（`/tmp:512m` + `.cache:512m` + `.npm:128m` + `.config:64m` = 合計 1216 MiB）は RAM 上に確保され、ヒープや RSS と同じ cgroup メモリ上限に計上される。当初の 512 MiB マージンはこの tmpfs 分を計上しておらず、ヒープが上限近くまで積み上がり同時に tmpfs も使い切られると `mem_limit` を超過し issue #11 の SIGKILL シナリオを再発しうる不整合があったため、マージンに tmpfs 合計を追加した。
  - 不変条件: **ヒープ上限 ≦ `mem_limit` − 512 MiB（ネイティブ処理用マージン）− tmpfs 合計**。`mem_limit` または tmpfs サイズを変更する場合は本値も追従させる。

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
- NFR-5.1: `Dockerfile` の `ARG CLAUDE_CODE_VERSION` で Claude Code のバージョンを固定し、依存パッケージは `--no-install-recommends` で最小化する。**ベースイメージは digest pin する**（`FROM node:22-slim@sha256:...`、issue #35）。`22-slim` は可変タグのため、digest 固定で再ビルドの再現性とサプライチェーン整合性を担保する。タグ併記は可読性のためで、digest が正本。
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
- コンテナ内で `git config --global user.email test@example.com && git config --global user.name test` が **エラーなく成功**し、`git config --global --get user.email` が設定値を返す（SEC-3 の `~/.gitconfig` シンボリックリンク経由の書き込み）。
- コンテナ内で `~/.claude.json` に直接書き込み、読み戻せる（Node の `fs.writeFileSync` で検証。SEC-3 の `~/.claude.json` シンボリックリンク経由の書き込み。SEC-3 の残存リスク注記も参照）。

### AC-2: ガード
> 自動検証: 下記の拒否・通過・`HOME` 偽装・docker socket・passwd 解決失敗・SEC-8(a) compose fail-closed は CI の **type-check** ジョブが `test/guard_test.sh`（Docker 不要のハーメティックなブラックボックステスト）と compose config の負例で機械検証する（FR-8.1）。以下の手動手順は同等の確認をローカルで行うためのもの。

- `$HOME` で `./bin/aidock` を実行すると exit code 2 で拒否される。
- `/` で実行しても拒否される。
- SEC-8 列挙パス配下（`~/.ssh`、`~/.aws`、`~/.config/gcloud` 等）で `./bin/aidock` を実行すると exit code 2 で拒否される。
- `bin/aidock` を経由せず `HOST_WORKSPACE` 未設定のまま `docker compose -f compose.yaml run --rm claude ...`（または `config`）を実行すると、`HOST_WORKSPACE is unset` で **non-zero exit** となり起動しない（FR-2.4 / SEC-8(a) の fail-closed。カレントディレクトリは暗黙マウントされない）。検証: `unset HOST_WORKSPACE; docker compose -f compose.yaml config -q; echo $?` が非ゼロ。
- 上記 SEC-8 パス配下から `HOME=` クリア、`unset HOME`、または存在しないパスを指す `HOME` で実行しても、passwd データベース（`getent passwd "$(id -u)"`）から実 home を解決して同様に exit code 2 で拒否される（バイパスできない）。
- 検証手順（リポジトリルートで実行。任意の SEC-8 列挙パスを使用、例: `~/.aws/test`）:
    - `repo="$PWD"`
    - `mkdir -p "$HOME/.aws/test"`
    - `( cd "$HOME/.aws/test"; for h in "$HOME" "" "/nonexistent" "/tmp"; do HOME="$h" "$repo/bin/aidock" run >/dev/null 2>&1; echo "HOME=$h exit=$?"; done )`
    - すべて `exit=2` であること（`HOME` を空・不在値・別の実在ディレクトリ（`/tmp` 等）へ偽装しても、passwd データベースの実 home を基準に判定するため拒否される）。

### AC-3: 権限
- コンテナ内 `whoami` が `agent`（entrypoint が `gosu` で降格した結果）。
- コンテナに `sudo` は存在せず、`agent` から root への昇格手段が無い。
- capability 集合が最小であること（`/proc/self/status` の `CapBnd` で `CAP_SYS_ADMIN` 不在・`CAP_NET_ADMIN` 在を確認）。`mount` 等の syscall はデフォルト seccomp でも遮断されるため、capability の回帰検出には bounding set を直接参照する（`mount` 失敗では検証にならない）。

### AC-4: ネットワーク
- `curl -fsS --max-time 3 https://example.com` が **non-zero exit** であること（接続拒否・タイムアウト・名前解決失敗のいずれも成功扱い）。
- `curl -sS --max-time 8 -o /dev/null -w '%{http_code}\n' https://api.anthropic.com | grep -qE '^[1-9][0-9]{2}$'` が **exit 0** であること。`000` は curl の transport failure 印（DNS / 接続 / TLS 失敗時の sentinel）であり **不合格扱い**。4xx/5xx は合格。**`init-firewall.sh` の api.anthropic.com プローブを `^[1-9][0-9]{2}$` に修正済み**（`000` を不合格化）。
- `AIDOCK_PROFILE=login` のときに限り、同様の手順で `https://claude.ai` からも 100–599 のステータスが返ること。
- SEC-17 の回帰検証: 許可ホストへの非 443 ポート（例: `github.com:22`）への接続が **non-zero exit**（タイムアウト・接続拒否のいずれも成功扱い）であること。443 番のみが ACCEPT され、他ポートは終端 DROP に落ちることを確認する。

### AC-5: 永続化
- `aidock login` 実行後、コンテナを再作成しても OAuth セッションが保持される。
- `aidock logout` が **正常に完了した場合**（`compose down -v` が成功した場合）、再度 `aidock` 起動時に未ログイン状態になる。**`compose down -v` が失敗した場合は success メッセージを出さず stderr に警告を出して非ゼロ exit する**（Docker 不在・権限不足・ボリューム使用中などを握りつぶさない。FR-1.6）。テアダウンは `compose down -v` のみが行い（Compose がプロジェクトスコープの実ボリューム名を自動解決）、固定名の `docker volume rm` による補強は持たない（#9）。検証は `docker volume ls` で当該ボリュームが消えていることで補強する。

### AC-6: ドキュメント
- 機能変更時、本書 §3 / §4 と `README.md` の表 / `CLAUDE.md` のコマンド表が一致している。

### AC-7: 資格情報ボリューム所有権
- `docker compose -f compose.yaml run --rm --no-deps --entrypoint sh claude -c 'stat -c "%u:%g" /home/agent/.claude'` の出力が **`$(id -u):$(id -g)`** と一致する（FR-3.3）。compose 経由で実行するため、Compose プロジェクト名（ボリューム名の prefix）に依存せず判定できる。一致しない場合は **`aidock build` → `aidock logout` → `aidock login`** の順で再構築する（`agent` ユーザの UID/GID は image build 時に baking されるため、ボリュームの作り直しのみでは復旧しない。FR-3.3 と整合）。

### AC-8: CI
- `.github/workflows/ci.yml` の **type-check** と **e2e** の両ジョブがグリーンであること（PR マージの必須条件、FR-8）。
- type-check は FR-8.1 の静的解析（`shellcheck` / `bash -n` / `hadolint` / `docker compose config`）と、`guard_workspace()` の自動テスト（`test/guard_test.sh`）・SEC-8(a) compose fail-closed の負例検証をすべて通過する。これにより AC-2 の大半（SEC-8 全機密パス・`HOME` 偽装・docker socket・passwd 解決失敗・compose fail-closed）は **Docker 不要**で type-check ジョブが検証する。
- e2e は次を GitHub-hosted runner 上で実機検証する: AC-1（ビルド + 起動プローブ）、AC-2（実機での `$HOME` / `/` 起動を exit 2 で拒否）、AC-3（`whoami=agent` / `sudo` 不在 / capability 制限）、AC-4（run プロファイルの example.com 遮断・api.anthropic.com 到達、login プロファイルの claude.ai 到達）、AC-7（資格情報ボリューム所有権）。**FR-11 実装後は AC-10（許可ドメイン解決・未許可サブドメイン NXDOMAIN）を本 e2e ジョブに追加する**（FR-11 は現時点では要件先行のため未追加）。
- **AC-5（永続化）は対話 OAuth ログインを要するため CI 対象外**とし、ローカル手動検証に委ねる。

### AC-9: CI 後検証エージェント
- `main` 上で `CI` が PR に対して成功すると、`.github/workflows/post-ci-verify.yml`（FR-9）が起動し、Claude が type-check / e2e の結果を検証・要約して PR に**コメント1件**を投稿する。
- 当該ワークフローはコメントのみで、コミット・push は行わない。`CLAUDE_CODE_OAUTH_TOKEN` secret が前提。
- `workflow_run` の仕様上、`main` にマージされるまでは発火しない（PR ブランチ単独では検証不可）。

### AC-10: DNS query 名 allowlist（FR-11）
> FR-11 は要件先行のため、本 AC は実装 PR で満たされる目標基準である（現時点では未充足を許容）。

- コンテナ起動後、**許可ドメイン**は解決できること。例: `getent hosts api.anthropic.com`（または同等の解決）が成功する。
- **未許可ドメイン**は **NXDOMAIN** になること。**テストには「プロキシが無ければ通常は解決する」不許可ドメイン**を使う（予約 TLD `.example` / `.invalid` や上流リゾルバが元々 NXDOMAIN を返す名前は使わない。プロキシ不在でも NXDOMAIN になりテストが通ってしまい、FR-11 の回帰を証明できないため）。具体的には次のいずれかとする:
    - **(a) 通常は解決する公開ドメインで、かつ allowlist に載っていないもの**（例: `example.com` 自身——`example.com` は実在し A レコードを返すが `CORE_HOSTS` / `LOGIN_EXTRA_HOSTS` に無いため不許可。プロキシが有効なら NXDOMAIN、無効なら解決される、という差分でプロキシの施行を証明できる）。
    - **(b) 検証者の管理下にある権威ドメインのサブドメイン**で、**権威サーバ側のクエリログに当該名が到達しなかったことで「プロキシによって遮断された」ことを積極的に証明できる**もの。
- 検証の本質は「**プロキシが無ければ解決される名前が、プロキシによって NXDOMAIN になる**」ことの確認である。単に NXDOMAIN が返ることだけを見ない（上流が元々 NXDOMAIN を返す名前では施行を証明できない）。
- 上記 2 点を e2e ジョブ（FR-8.2 / AC-8）で実機検証する。許可ドメインの解決成功と不許可ドメインの NXDOMAIN を 1 ジョブ内で確認する。
- `agent` から `127.0.0.1:53`（プロキシ）以外への直接 53 番送信は DROP され、プロキシ迂回での解決ができないこと（FR-11.2）。これには Docker 組込 DNS（`127.0.0.11:53`）への `agent` からの直接送信も含む（loopback 包括 ACCEPT で迂回できないこと。FR-11.2 / FR-4.2）。**プロキシは `agent` と別 UID（`dnsproxy` 等）で動作**し、`127.0.0.11:53` への forward はプロキシ UID 発のみ ACCEPT・`agent` UID 直送は DROP となること（iptables `owner --uid-owner` で識別。同一 UID で動かすと両者を分離できないため、この UID 分離も併せて検証する。FR-11.2）。
- `firewall-refresh`（FR-1.5）を起動済みコンテナで再実行しても DNS 解決が壊れないこと（許可ドメインが引き続き解決でき、未許可ドメインが NXDOMAIN のまま）。退避した元上流を再利用せず resolv.conf から再導出する実装はこの検証で回帰検出される（FR-11.1）。
- プロキシ起動失敗時は DNS 全断・非ゼロ exit で fail-closed になること（FR-11.4）。終端の健全性プローブ（FR-11.5）が不一致なら `init-firewall.sh` 相当の初期化が `exit 1` する。

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
| 2026-07-16 | 定例コードレビューで `bin/aidock` の `cmd_run()`/`cmd_shell()` が `AIDOCK_PROFILE` を明示的に固定していない欠落を検出・修正。`compose.yaml` の `environment: AIDOCK_PROFILE: "${AIDOCK_PROFILE:-run}"` は `docker compose` を起動したプロセスの環境変数をそのまま補間するため、呼び出し元シェルにたまたま `AIDOCK_PROFILE=login`（例: 直前の `aidock login` で手動 export したまま `unset` し忘れた等）が残っていると、通常の `run`/`shell` セッションでもコンテナが `login` プロファイルで起動し、`LOGIN_EXTRA_HOSTS`（`claude.ai`/`console.anthropic.com`/`auth.anthropic.com`/`login.anthropic.com`）への許可リストが無言で広がってしまう 経路があった。`AIDOCK_SKIP_FIREWALL`/`AIDOCK_INSECURE_ACK`（SEC-13）に対して既に採用している「`bin/aidock` 経由でこれらの env を無加工で素通しさせない」という設計原則から漏れていた同種の欠落。`cmd_run()`/`cmd_shell()` の先頭付近で `export AIDOCK_PROFILE="run"` を明示することでアンビエント環境変数から独立させた。新設 **SEC-19** に整理し FR-1.3/FR-1.4 を更新。`test/guard_test.sh` に、ambient `AIDOCK_PROFILE=login` を残したまま `run`/`shell` を実行しても `docker compose` に 渡る値が `run` に固定されることを検証する回帰試験を追加。 | Claude Code |
| 2026-07-15 | 定例コードレビュー（PR #54）で `compose.yaml` に `memswap_limit` が明示されておらず、ホストに swap が有効かつ cgroup の swap accounting が有効な環境（多くの Linux ディストリで既定）では Docker が `memswap_limit` を `mem_limit` の2 倍として扱うため、暴走・侵害されたプロセスが文書化された 4G 上限ではなく最大 ~8G（RSS 4G + swap 4G）まで消費してから初めて OOM Killer に落とされうる欠落を検出・修正。`memswap_limit: 4g` を `mem_limit` と同値に明示ピンし、ホストの swap 設定に依存せず SEC-4/NFR-2 の DoS 境界を常に 4G に保つよう修正。SEC-4 を更新。 | Claude Code |
| 2026-07-15 | 定例コードレビュー（PR #54）で `firewall-refresh`（`cmd_firewall_refresh()`）が `compose ps` の出力をプロセス置換 (`< <(...)`) に直接つないでおり、`compose ps` 自体の失敗（例: Docker デーモン停止）を検知できず、実際の原因とは無関係な「稼働中コンテナが1 つも無い」（`no running claude container`）という誤った一次診断メッセージに落ちていた不具合を検出・修正。`compose ps` の出力を変数へ一旦読み込み終了コードを明示チェックし、失敗時は `failed to list containers (is the Docker daemon running?)` という専用の診断メッセージで exit 1 とするよう修正。FR-1.5 を更新し `test/guard_test.sh` に `compose ps`失敗を模擬する回帰試験を追加。 | Claude Code |
| 2026-07-15 | 定例コードレビュー（PR #55）で `guard_workspace()` が検証した実パス（`realpath` 正規化済み）と、`cmd_run()`/`cmd_login()`/`cmd_shell()` が実際に `HOST_WORKSPACE` へ再エクスポートしていた生の `$PWD` が異なりうる TOCTOU（Time-Of-Check to Time-Of-Use）を検出・修正。`$PWD` がシンボリックリンクの場合、ガード検証と `docker compose run` 実行の間に向き先を差し替えることで、SEC-8 が承認したパスとは別のディレクトリが `/workspace` として bind mount されうる窓があった。`guard_workspace()` を検証済みの実パスを標準出力へ返す形に変更し、呼び出し側は必ずその戻り値を `HOST_WORKSPACE` に使うよう統一（生の `$PWD` の再利用を廃止）してこの窓を閉じた。FR-2.4 / SEC-8 を更新し、シンボリックリンク経由のワークスペースで実際に解決済み実パスがマウントされることを検証する回帰試験を `test/guard_test.sh` に追加。 | Claude Code |
| 2026-07-14 | コードレビューで 2 件を検出・修正。**(1) `$HOME` 直下の設定ファイルが書き込めない不具合**: `/home/agent` は `.cache`/`.npm`/`.config`/`.claude` の tmpfs/named volume を除き read-only rootfs 上にあるため、`git config --global`（`~/.gitconfig`）や claude-code 本体の初回起動時保存（`~/.claude.json`。`~/.claude/` の OAuth ボリュームとは別物）が素のままでは失敗していた。`Dockerfile` に相対シンボリックリンク（`~/.gitconfig` → `.config/gitconfig`、`~/.claude.json` → `.config/claude.json`）をビルド時に焼き込み、既存の `.config` tmpfs（書き込み可能）へ透過的に書き込ませることで解消（新規 tmpfs は追加せず「必要最小限の tmpfs」原則を維持）。SEC-3 を更新し AC-1 に検証手順を追加。**(2) 許可ホストへの ACCEPT ルールがポート無制限だった**: `init-firewall.sh` の `allowed-hosts`/`allowed-hosts6` ACCEPT ルールにポート指定がなく、`github.com` のように git-over-SSH（22 番）も提供するホストが allowlist に入ると、コンテナ内の侵入プロセスが許可 IP への任意ポートを C2/持ち出しの汎用トンネルとして悪用できる余地があった。両 ACCEPT ルールに `-p tcp --dport 443` を追加し「許可ホストへの HTTPS のみ」を明示的に強制する。DNS(53) 専用ルール（SEC-15）は対象外。新設 **SEC-17** に整理し AC-4 に回帰検証を追加。既存の CORE_HOSTS/LOGIN_EXTRA_HOSTS/GitHub meta CIDR はいずれも HTTPS 用途のみのため正当な用途への影響なし。 | Claude Code |
| 2026-07-14 | コードレビュー（bin/aidock・docker/Dockerfile の 2 ファイル監査）で 2 件を検出・修正。**(1) ホスト root 実行時の capability 残存（高）**: `docker/Dockerfile` が `HOST_UID`/`HOST_GID`（build arg）を検証せず `groupadd -g`/`useradd -u` へ渡すため、ホストユーザーが UID/GID 0（root）だとコンテナ内の `agent` ユーザーも UID/GID 0 として作成されていた。Linux の capability クリア規則は「実効 UID が 0 から非 0 へ変わったとき」だけ有効 capability を消去するため、UID 0→0 の遷移では `entrypoint.sh` の `gosu agent` 降格を経ても `NET_ADMIN`/`NET_RAW`（cap_add 済み）が実効 capability として残存しうる。これは SEC-1/SEC-7 が前提とする「降格後の agent は capability を持たない」という不変条件を崩し、コンテナ内ワークロードが `iptables`/`ip6tables` を直接操作して egress ファイアウォール（一次防御）を無効化できてしまう経路だった。`bin/aidock` に `HOST_UID`/`HOST_GID` が 0 の場合は `exit 2` で拒否するガードを追加（`guard_workspace()` と同じ fail-closed の流儀）。新設 **SEC-18** に整理。**(2) GID 衝突によるビルド失敗（中）**: 同じ `Dockerfile` の agent グループ作成が、ホストの GID が `node:22-slim` の既存グループ（`dialout`/`sudo`/`staff`/`users` 等）と衝突する環境で `groupadd: GID '...' already exists` により `docker build` ごと失敗していた。既存グループが該当 GID を持っていればそれを再利用し、無い場合のみ `agent` グループを新規作成するよう変更（可用性のみの修正、セキュリティ不変条件の変更なし）。 | Claude Code |
| 2026-07-14 | 上記 SEC-18 に対するセルフレビュー（`/code-review ultra`）で 3 件を検出・修正（マージ前、同一 PR 内）。**(1) UID/GID の混同**: SEC-18 の根拠説明が capability クリア規則（実効 UID のみに適用）を UID/GID 両方の拒否理由として引いており不正確だった。UID 0 が capability クリアを破る主因であることと、GID 0 は capability クリアとは無関係な多層防御（agent のプライマリグループが root になり group-root 読み取り可能ファイルへのアクセスが広がる懸念）であることを、SEC-18 本文・`bin/aidock` のコメント/エラーメッセージそれぞれで区別して明記。**(2) `bin/aidock` を経由しない直接 `docker build --build-arg HOST_GID=0` が黙って成功する**: (1) の GID 衝突修正（既存グループの再利用）が、HOST_GID=0 を渡された場合に既存の `root` グループを黙って再利用してしまう副作用を持っていた（従来は `groupadd -g 0 agent` が `root` と衝突して意図せず失敗し、結果的に拒否できていた）。`docker/Dockerfile` に `HOST_GID=0` の明示チェックを追加し `docker build` 自体を失敗させることで、`bin/aidock` を迂回する経路にも二次防御を用意（`HOST_UID=0` は `useradd -u 0` が既存 `root` ユーザーと衝突するため従来通り暗黙に失敗する）。**(3) ガードが `logout`/`firewall-refresh`/`help` まで一律ブロックしていた**: SEC-18 のガードをスクリプト冒頭で無条件実行していたため、`gosu` 降格を経由しない `aidock logout`（ボリューム破棄のみ）や `aidock firewall-refresh`（起動済みコンテナ内の再初期化のみ、UID/GID マッピングは作成時点で確定済み）まで、ホスト root ユーザーに対して一律拒否していた。ホスト root な運用者が資格情報ボリュームの後始末（`logout`）すらできなくなる副作用があった。ガードを `require_non_root_host()` 関数へ切り出し、実際にイメージをビルド/コンテナを作成する 4 コマンド（`build`/`login`/`run`/`shell`）の先頭でのみ呼び出すよう変更。SEC-18 本文にこの適用範囲を明記。`test/guard_test.sh` は変更不要（既存の SEC-18 試験ケースは `run` サブコマンド経由のままで新しい適用範囲と整合）で 52/52 パスを再確認。 | Claude Code |
| 2026-07-14 | コードレビューで NFR-2 のヒープ余白計算が `compose.yaml` の `tmpfs`（`/tmp:512m` + `.cache:512m` + `.npm:128m` + `.config:64m` = 合計 1216 MiB）を計上していない不整合を検出・修正。tmpfs は RAM 上に確保され cgroup のメモリ上限に heap/RSS と同じく計上されるため、旧来の「ヒープ上限 ≦ `mem_limit` − 512 MiB」だけではヒープが上限近くまで積み上がり同時に tmpfs も使い切られた場合に `mem_limit` を超過し、issue #11 の cgroup OOM SIGKILL シナリオを再発しうる余地があった。`compose.yaml` の `NODE_OPTIONS=--max-old-space-size` を `3584`（4096 − 512）から `2368`（4096 − 512 − 1216）へ下げ、NFR-2 の不変条件を「ヒープ上限 ≦ `mem_limit` − 512 MiB − tmpfs 合計」へ改訂。`mem_limit` は SEC-4 の DoS 上限として 4G を維持しヒープ側のみ調整（ヒープ上限を下げるのみで安全側の変更）。あわせて SEC-12.1 の実装済み参照行番号（`init-firewall.sh:83` → `init-firewall.sh:452` の `CIDR_RE`）が過去の編集でずれていた誤りも修正。 | Claude Code |
| 2026-07-14 | コードレビューで SEC-8 の機密パス列挙に `~/.gnupg`（GPG 秘密鍵・キーリング）が抜けていた漏れを検出・修正。SEC-8 は `~/.ssh` / `~/.aws` / `~/.config/gcloud` 等の資格情報ディレクトリを `guard_workspace()` で機械的に拒否する設計だが、同じく高価値な秘密鍵を保持する `~/.gnupg`（GPG 署名鍵・暗号鍵）が拒否リストから漏れており、GPG コミット署名（`commit.gpgsign`）を使う開発者が `~/.gnupg` 配下やそのサブディレクトリから `aidock` を起動すると秘密鍵ディレクトリが `/workspace` としてそのままコンテナへ bind mount されてしまう経路が残っていた。`bin/aidock` の `guard_workspace()` の case 文に `.gnupg`/`.gnupg/*` を追加し、他の機密ディレクトリと同様に exit 2 で拒否するよう修正。`test/guard_test.sh` の `SENSITIVE_DIRS` にも追加し回帰検証を追加（59/59 パス）。README.md の機密ディレクトリ列挙も同期。 | Claude Code |
| 2026-07-14 | コードレビュー（SEC-8）: `guard_workspace()` の機密パターンが `.config/gcloud` 等の子のみで親 `~/.config` 自体を拒否しておらず、`cd ~/.config && aidock run` で `~/.config` 全体（配下の aws/gcloud/azure/git/gh 資格情報ディレクトリを含む）が `/workspace:rw` としてコンテナへ露出していた（実証済み）。case 文に `.config`（完全一致のみ。非機密の子—例 `~/.config/htop`—の通過契約は維持）を追加し、SEC-8 の列挙・README・`test/guard_test.sh` を同期。 | Claude Code |
| 2026-07-14 | コードレビュー（FR-1.5）: `docker compose ps` は既定で `compose run` 由来の one-off コンテナを一覧から除外するため、`run`/`login`/`shell`（すべて `compose run --rm`）で起動したコンテナが 1 件も列挙されず、`firewall-refresh` が常に「no running claude container」exit 1 になっていた。`compose ps -q --all --filter status=running claude` に変更し FR-1.5 の記述も同期。 | Claude Code |
| 2026-07-14 | コードレビュー（§6 デッドコード）: リポジトリ直下の `.dockerignore` はビルドコンテキスト（`./docker`、compose.yaml）の外にあり無効（no-op）。内容もルートコンテキスト前提で書かれており、将来コンテキストを変更した際に誤動作する地雷のため削除。 | Claude Code |
| 2026-07-14 | PR #53 セキュリティレビュー反映: SEC-8 の機密ディレクトリ列挙に `~/.config/op`（1Password CLI）・`~/.config/doctl`（DigitalOcean API トークン）・`~/.config/rclone`（rclone.conf の平文クラウド資格情報）・`~/.config/hub`（GitHub OAuth トークン）を追加。親 `~/.config` の拒否だけではサブディレクトリ自体からの起動（例: `cd ~/.config/rclone && aidock run`）を防げないため、既知の資格情報ディレクトリとして個別に列挙する。`bin/aidock` の case 文と `test/guard_test.sh` の `SENSITIVE_DIRS` を同期。 | Claude Code |
| 2026-07-14 | PR #53 コードレビュー反映: (1) README のリポジトリ構成ツリーから削除済み `.dockerignore` を除去（AC-6 同期）。(2) `~/.config` 拒否テストを `reject_from` ヘルパー再利用に変更し他テストの mkdir 順序への依存を解消。(3) FR-1.5 の発見フラグ（`--all --filter status=running`）に自動回帰テストが無かったため、`test/guard_test.sh` にdocker スタブ差し替え方式のハーメティックな firewall-refresh 試験を追加（FR-8.1 の記述も同期）。 | Claude Code |
| 2026-07-14 | PR #53 レビュー指摘（残余リスクの明文化）: SEC-8 のガードは realpath 正規化後の相対パターン照合のため、`~/.config` 自体を home 外へ symlink する XDG 再配置レイアウトでは拒否が効かない（既存機構の制約であり本 PR による退行ではない）。SEC-8 本文に残余リスクとして明記し、README の「機械的に拒否する」表現が過大にならないよう根拠を要件側に置く。パターン照合から「解決済み実パスの包含比較」への移行は将来課題。 | Claude Code |
| 2026-07-09 | 日次コードレビュー（bin/aidock・docker/Dockerfile・docker/entrypoint.sh・docker/init-firewall.sh・compose.yaml・test/guard_test.sh の 4 観点監査）で `init-firewall.sh` の非対称なエラーハンドリングを 3 件目として検出・修正: GitHub meta API（`https://api.github.com/meta`）から取得した IPv4 CIDR を `allowed-hosts` ipset へ追加する箇所（SEC-12.1 の形式チェックと SEC-12.2 の値域チェック `cidr_in_range()` を両方通過した後の `ipset add allowed-hosts "$cidr" -exist`）が、同じ 3 行下の IPv6 CIDR 分岐（`ipset add allowed-hosts6 ... 2>/dev/null \|\| log ...`）と異なりガードされていなかった。SEC-12.1/12.2 の検証を通過した値であっても ipset 自体が別理由（重複・オーバーラップ処理等）で拒否する余地は残るため、`set -e` 下でこの 1 件の失敗がファイアウォール初期化全体（コンテナ起動・`firewall-refresh` 双方）を異常終了させうる可用性上の穴だった。これは #43（IPv4 nameserver ループ）・A-record `resolve_and_add()` 修正と**同一クラスの欠陥**の 3 件目の再発であり、既に確立されている「不正な形式は warn ログでスキップし `set -e` で初期化全体を落とさない」ガードパターン（IPv6 CIDR 分岐と同じ形）をこの箇所にも適用し対称性を回復した。FR-4.5 / FR-4.7 の best-effort 方針・SEC-12 の検証範囲は変更なし（許可リストの内容や悪意ある値の admit 経路に変更はない）。実装のみの変更で新規 FR/SEC は追加していない。 | Claude Code |
| 2026-07-03 | コードレビュー（bin/aidock・docker/Dockerfile・docker/entrypoint.sh・docker/init-firewall.sh・compose.yaml の 4 観点監査）で `init-firewall.sh` の非対称なエラーハンドリングを検出・修正: IPv4 の `nameserver`（/etc/resolv.conf）抽出ループが `ipset add allowed-dns` の失敗をガードしておらず、同じファイル内の IPv6 nameserver ループ・AAAA 解決・GitHub meta CIDR 追加の各箇所（いずれも「不正な形式は warn ログでスキップし `set -e` で初期化全体を落とさない」ガード済み）と扱いが不揃いだった。抽出正規表現は桁形式のみ検証し値域（各オクテット 0-255）まではチェックしない（SEC-12.1 のみで SEC-12.2 相当が無い状態）ため、境域外の値が resolv.conf に含まれると `ipset add` が失敗し `set -e` でファイアウォール初期化全体（コンテナ起動および `firewall-refresh`）が異常終了しうる可用性上の穴だった。IPv6 nameserver ループと同じガード（`if ipset add ...; then カウンタ増やす; else warn ログでスキップ; fi`）を追加し、単一の不正なエントリで初期化全体が落ちないようにした（許可リストの範囲は変えず、悪意ある値が admit されることもないため既存のセキュリティ不変条件は変更なし）。NFR-4 / FR-4.2 の best-effort 方針との整合性を回復。実装のみの変更で新規 FR/SEC は追加していない。 | Claude Code |
| 2026-06-05 | issue #9（P2）対応: `bin/aidock` の `cmd_logout()` から固定名 `docker volume rm aidock_claude-home` を撤去し、テアダウンを `compose down -v --remove-orphans` のみに集約。当該リテラルは実プロジェクト名（既定で `ai-docker-environment_claude-home`）と一致せず無効である上、別文脈で作られた同名グローバルボリュームを誤削除する破壊的副作用を持つ既知 defect だったため除去。Compose はプロジェクトスコープの実ボリューム名を自動解決して `claude-home` を削除する。FR-1.6 / AC-5 を更新（PR #22 で延期されていた follow-up を完了）。 | Claude Code |
| 2026-06-05 | issue #13（P2）対応: `init-firewall.sh` の GitHub meta API フェッチ curl に有界リトライ `--retry 3 --retry-delay 2 --retry-connrefused` を追加。初回 DNS 解決失敗・瞬断・レート制限 429 等の一過性失敗を再試行で吸収し、CIDR フォールバック欠落（→ GitHub IP ローテーション時の接続失敗余地）を縮小。FR-4.5/4.7 の best-effort 契約は維持（リトライ尽きた失敗・403 等のハードエラーは従来どおり warn ログで継続しホスト名解決 IP に縮退）。WARN ログに「retries 後」「firewall-refresh で再試行可」を明記。issue 起票時に併記されていた「`AIDOCK_PROFILE=login` 中の OAuth callback 破綻」懸念は検証の結果過大（OAuth ホストは meta と独立に `resolve_and_add()` で解決されるため GitHub meta 失敗の影響を受けない）と確認、残余リスクは GitHub IP ローテーションの狭い範囲に限定。**codex P2 レビュー反映**: curl は 403/429 の `Retry-After` ヘッダに従い待機し `--max-time` はリトライ毎にリセットされるため、リトライの累積実時間が無上限だとコンテナ起動が server 指定の待機で引き延ばされうる。`--retry-max-time 20` を追加し累積リトライ時間を上限化（起動時間を予測可能な範囲に維持）。**2件目の codex P2 反映**: 素の `--retry`／`--retry-connrefused` は名前解決失敗（curl exit 6）を再試行しないため、本変更が狙う「初回 DNS 解決失敗」が実際には未カバーだった。`--retry-connrefused` を `--retry-all-errors` に置換し全エラー（DNS 含む）を再試行対象に。**3件目の codex P2 反映**: `--retry-all-errors` は失敗試行の部分ボディを stdout に出力しうるため、コマンド置換だと部分バイト連結で JSON が壊れ jq が CIDR を 0 件にする恐れ。レスポンスを `-o <tmpfile>`（`/tmp` tmpfs、試行毎に truncate）で受け curl 成功後にのみ読み出すよう変更。**4件目の codex P2 反映**: `--retry-all-errors`（`-f` 併用）は 403/404 等のハード HTTP エラーまで再試行し「403 は即 warn-continue」契約に反する。curl のリトライフラグでは「transport エラー＋408/429/5xx のみ再試行、ハード 4xx は即縮退」を表現できないため、curl フラグ群を撤去し **shell の有界リトライループ**（最大 3 試行・累積 ~20s デッドライン・transient のみ再試行・`-o` 一時ファイルを 2xx 時のみ読み出し）に置換。**5件目の codex P2 反映**: 初回 CORE_HOSTS の解決失敗時は ipset に api.github.com の IP が無く ACCEPT ルールが後続解決 IP も DROP するため、curl 再試行だけでは初回 DNS 失敗から回復不能だった（=2件目の修正が実質無効）。transport 失敗での再試行前に `resolve_and_add api.github.com` を呼び新解決 IP を admit するよう修正（IP ローテーションにも追随）。FR-4.5 を更新。 | Claude Code |
| 2026-06-06 | フライトレコーダー（エージェントの説明責任）構想の第一手として SEC-15 を「受容」から「施行」へ改訂。DNS query 名 exfiltration を **コンテナ内ユーザー空間 DNS プロキシで query 名 allowlist 施行**し、未許可ドメインを権威 NS 到達前に NXDOMAIN で遮断する方針へ転換。**FR-11**（DNS プロキシ: `127.0.0.1:53` 配置・53 番 egress を「プロキシ→`127.0.0.11` のみ許可／`agent` 直接 53 は DROP」・policy 由来の名前 allowlist 照合・拒否名は記録の上 NXDOMAIN・起動失敗時 fail-closed・健全性プローブ・二重 allowlist の policy 単一ソース化への前方参照・残余リスクの明記）と **AC-10**（許可ドメイン解決／未許可サブドメイン NXDOMAIN を e2e 検証）を新設。FR-4.2 / SEC-15 を施行表現へ更新、AC-8 に FR-11 実装後の AC-10 追加を予告。**SEC-3** に append-only 監査ボリュームを read_only 例外として認める余地を将来予告として追記。**§1.3** に「カーネルレベル全 syscall 監査は v1 スコープ外」「Sigstore 等の公開透明性ログ必須化は opt-in 拡張」を明記。残余リスクは「許可ドメイン配下サブドメインへの低帯域チャネル」「許可ドメイン経由の HTTPS 本文 / TLS SNI」に限定（誇大表現を避け正直に明記）。**本 PR は要件文書のみの変更**で、`bin/aidock` / `docker/*` の実装は未変更（FR-11 は要件先行・実装は後続 PR）。CLAUDE.md も最小限同期。 | Claude Code |
| 2026-06-06 | PR #37 codex P2 レビュー（6 件）反映（要件文書のみ・実装未変更）: (1) **AC-10 / FR-11.5** の不許可テスト名を予約 TLD `.example`（上流が元々 NXDOMAIN を返しプロキシ不在でもテストが通り FR-11 回帰を証明できない）から「**プロキシが無ければ通常解決するが allowlist 外**」のドメイン（例 `example.com` 自身）または「権威サーバ側で未到達を証明できる管理下ドメイン」へ変更し、検証本質を「プロキシが無ければ解決される名前がプロキシで NXDOMAIN になる」差分確認に明文化。(2) **FR-11.2** に agent→プロキシ DNS 経路の明示許可を追記: 許可 53 番経路を (a) `agent`→`127.0.0.1:53`、(b) プロキシ→`127.0.0.11:53` の **2 経路に分離**し、それ以外の agent の 53 番は DROP。(3) **FR-11.2 / FR-4.2** に **loopback 例外の 53 番限定**を明記: 包括 `-o lo -j ACCEPT` のままだと `agent` が `127.0.0.11:53` 直送でプロキシを迂回できるため、53 番は (a)(b) のみを包括 lo ACCEPT より前に評価し直接 `127.0.0.11:53` を DROP。(4) **FR-11.3 / FR-11.5 / AC-10** の拒否レスポンスコードを **NXDOMAIN に統一**（従来 FR-11.3 の `REFUSED` 併記を解消、矛盾除去）。(5) **FR-11.7 / SEC-15** の残余リスクを 2 ケースから **3 ケースに拡張**し「**既知の許可 IP への直接通信**」（`allowed-hosts` は IP ベース ACCEPT のため許可 IP 既知プロセスは DNS をプロキシ迂回せず直接 exfil 可能）を追加。(6) **FR-11.1 / FR-4.2 / SEC-15** に **resolv.conf 書換え前の上流 DNS 退避**を明記: `allowed-dns` は resolv.conf から導出されるため、`127.0.0.1` 書換え前に元上流（`127.0.0.11` 等）を捕捉し `allowed-dns` の種として明示投入しないとプロキシ forward が落ち全解決失敗。番号体系・残余リスク到達点は FR-11.7 / SEC-15 で相互参照整合。 | Claude Code |
| 2026-06-06 | PR #37 codex P2 レビュー（追加 3 件）反映（要件文書＋README のみ・実装未変更）: (1) **FR-11.1 / FR-1.5 / SEC-15** に **捕捉した上流リゾルバの永続化と firewall-refresh 時の再利用**を明記。refresh は起動済みコンテナで `init-firewall.sh` を再実行するが、その時点の resolv.conf は既に `127.0.0.1`（自プロキシ）を指すため、resolv.conf から `allowed-dns` を再導出すると上流が自プロキシにすり替わりプロキシ forward が落ちて全 DNS が壊れる。初回に捕捉した元上流を書込み可能領域へ退避し、refresh では再導出せず再利用する契約を追加。(2) **FR-11.2 / SEC-15 / AC-10** に **プロキシの識別境界**を明記。プロキシを `agent` と同一 UID で動かすと iptables は宛先/ポートだけでは「プロキシ→`127.0.0.11:53` forward」と「`agent` 直送」を区別できないため、プロキシを専用 UID（`dnsproxy` 等）で動作させ `owner --uid-owner`（またはパケットマーキング）で分離する要件を追加。SEC-1 / SEC-7 の gosu 降格モデルとは追加 capability なし（既存 SETUID/SETGID を 2 系統降格へ流用）で整合する旨も明記。(3) **README** の脅威モデルを FR-11 と同期（FR-6/AC-6）。「現状実装（query 名フィルタ未施行＝従来の残余リスクが残る）」と「FR-11 で計画されたプロキシ施行（要件先行・実装は後続）」を明確に区別して記述し、施行後も残る 3 残余リスク（許可サブドメイン低帯域・HTTPS 本文/SNI・既知許可 IP 直送）を正直に反映。誇大化しない。 | Claude Code |
| 2026-06-02 | issue #11（P2）対応: `compose.yaml` の `NODE_OPTIONS=--max-old-space-size` を `4096`（= `mem_limit` と同値）から `3584` に下げ、Node ヒープと cgroup 上限の間に 512 MiB のマージンを確保。ヒープ外領域（V8 C++ ヒープ・JS スタック・ネイティブモジュール・子プロセス）が積み上がった際に V8 の graceful な heap-exceeded ハンドリングより先に cgroup OOM killer が SIGKILL する経路を緩和。`mem_limit` は SEC-4 の DoS 上限として 4G を維持しヒープ側のみ調整。NFR-2 に数値根拠と不変条件「ヒープ上限 ≦ `mem_limit` − 512 MiB」を明記。 | Claude Code |
| 2026-06-01 | issue #10（P2）対応: `bin/aidock` の `cmd_firewall_refresh()` を複数コンテナ耐性化。`compose ps -q claude` の戻り値を行ごとに配列へ取り込み（空行スキップ）、0 件→exit 1、1 件以上→**各コンテナで順に** `init-firewall.sh` を実行（DNS 再解決はどの claude コンテナにも等しく必要なため全件をループ）。従来は複数 CID を単一スカラに格納していたため、複数同時起動時に改行連結された CID が無効なコンテナ ID となり `docker exec` が失敗していた。**再レビュー反映**: ループを best-effort 化し（あるコンテナの失敗で残りをスキップせず、1 件でも失敗なら非ゼロ exit）、`usage()` の help 文言を全コンテナ対象に修正。FR-1.5 / README を全コンテナ対象の挙動に更新。 | Claude Code |
| 2026-05-30 | issue #12（P2）対応: `init-firewall.sh` の DNS(53) egress を全宛先許可から `/etc/resolv.conf` の `nameserver` IPv4（ipset `allowed-dns`、`-m set --match-set allowed-dns dst`）限定に変更。`nameserver` 不検出時は warn ログを残し DNS を遮断（fail-closed）。SEC-15 を新設、FR-4.2 を更新。**codex レビュー反映**: 本ルールは任意の攻撃者制御リゾルバへの直接送信を断つ defense-in-depth であり、正規リゾルバの再帰解決を経由する query 名 exfiltration は防げない（query 名フィルタは iptables/ipset 不可、構築後の 53 全 DROP は実行時再解決を壊す）ため残余リスクを受容、という効果と限界を SEC-15 / FR-4.2 / README に正確化（当初の「DNSトンネル exfil を遮断」表現は過大だったため訂正）。 | Claude Code |
| 2026-05-29 | issue #7（P1）対応: `bin/aidock` の `cmd_logout()` で `compose down -v` の終了コードを伝播するよう修正。失敗時は stderr に警告を出して非ゼロ exit し、success メッセージは成功時のみ表示（従来の `\|\| true` による失敗握りつぶしを解消＝共有ホストで logout 失敗を成功と誤認する経路を排除）。補強の `docker volume rm` は `compose down -v` 成功後にのみ best-effort 実行しテアダウン成否をマスクしない。FR-1.6 / AC-5 を更新（`docker volume rm` 行撤去とボリューム名動的解決は #9 で別途対応）。 | Claude Code |
| 2026-05-29 | 運用ルール再改訂（FR-7）: 「CI の成否はこの実行環境で確認できない」前提を撤去し、**Claude が GitHub MCP（check-runs / status）で CI 結果を取得し Claude 上（チャット）で報告する**方針に変更。post-ci-verify（FR-9）の PR コメント要約は維持。CLAUDE.md / README.md も同期。 | Claude Code |
| 2026-05-29 | `README.md` に「コードレビュー / PR 運用」節を追加し、codex 自動レビューと PR 作成フロー（open 作成 / `@codex review` 投稿でレビュー発火 / push ごとの投稿 / CI グリーンを主張しない）を利用者向けに記載。FR-7（正本）と CLAUDE.md の運用を要約・同期。 | Claude Code |
| 2026-05-29 | 運用ルール改訂（FR-7）: Claude は PR を **draft ではなく open** で作成し、**差分を push するたびに（初回 PR 作成時を含む）`@codex review` を投稿**して初回・再レビューを発火させる。PR を open 作成にするため **draft → ready トリガ記述を撤去**。この実行環境では **CI の成否（グリーン）を確認できない**ため、Claude が CI 成功を確認・主張しない旨を明記（CI 結果の検証・要約は FR-9 が担う）。CLAUDE.md「Git ワークフロー」も同期。 | Claude Code |
| 2026-05-29 | issue #6（P1）対応: `init-firewall.sh` に `cidr_in_range()` を追加し SEC-12.2（octet 0-255 / prefix 0-32 の範囲検証）を実装。SEC-12.1 の正規表現通過後に base-10（`10#`）で範囲比較し、`999.999.999.999/33` 等の範囲外 CIDR を warn ログ付きでスキップ（FR-4.7 best-effort、初期化は継続）。SEC-12.2 / FR-4.5 を「実装済み」に更新。 | Claude Code |
| 2026-05-29 | issue #8（P1）対応: `compose.yaml` の `/workspace` マウントから `HOST_WORKSPACE` のデフォルト `:-./` を撤去し `${HOST_WORKSPACE:?...}` に変更。`bin/aidock` 非経由の直接 `docker compose run` がカレントディレクトリを暗黙マウントせず fail-closed で停止するようにし、SEC-8 一次防御 (a) を補強。`bin/aidock` の `compose()` ラッパーでマウント不要なサブコマンド（build/logout/firewall-refresh）向けに非機密プレースホルダ（`/nonexistent`）を供給。FR-2.4 を新設、SEC-8(a) と AC-2 を更新。README も同期。 | Claude Code |
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
| 2026-05-23 | 追加レビュー反映 (HOME バイパス対策): `guard_workspace()` の `$HOME` 解決を堅牢化。`HOME=` クリア、`unset HOME`、存在しない `HOME` 値で起動した際にも `/etc/passwd` から実 home を解決して SEC-8 拒否を発動するよう修正。AC-2 にテストレシピを追記。SEC-8 表現を「運用上の禁止事項」並列から「機械的拒否対象 + 運用推奨」階層構造に整理。 | Claude Code |
| 2026-05-23 | Codex 追加レビュー (P1) 反映: `guard_workspace()` の判定基準を user-supplied `$HOME` 優先から `/etc/passwd` 実 home 優先に変更（passwd 失敗時のみ `$HOME` フォールバック）。`HOME=/tmp` 等の実在ディレクトリへの偽装による SEC-8 バイパスを封鎖。AC-2 テストレシピに偽装 HOME ケースを追加。 | Claude Code |
| 2026-05-23 | FR-7 更新: Claude の GitHub 操作が OWNER 名義で記録される実行環境では Claude 投稿の `@codex review` も受理されることを反映。運用として差分 push を伴う報告コメント末尾に `@codex review` を追記し再レビューを発火させる旨を明記。CLAUDE.md も同期。 | Claude Code |
| 2026-05-23 | Codex 追加レビュー (P1×3) 反映: `guard_workspace()` の home 解決を fail closed 化。passwd home が解決不能/無効な場合に `$HOME` へフォールバックする経路を撤去し `exit 2`。passwd 参照を `id -un` から `id -u`（UID 指定）に変更し NSS 名前解決の曖昧性を低減。SEC-8/AC-2 の「/etc/passwd」表現を「passwd データベース（getent）」に修正。 | Claude Code |
| 2026-05-19 | 初版作成。既存実装をベースに要件を抽出。 | Claude Code |
| 2026-05-19 | レビュー指摘反映: AC-4 の curl から `-f` を除去し status code 検査に統一 / SEC-3 に `/workspace:rw` を明示 / NFR-4 のコメント言語要件を緩和。 | Claude Code |
| 2026-05-19 | skill 観点（review / security-review / simplify）の再監査を反映: SEC-13/14、FR-3.3、FR-4.0/4.7、NFR-5.1/5.2、AC-7 を追加。SEC-3/8/12、FR-1.3/4.3/4.5/4.6、AC-4 を改訂。CIDR 検証強化は要件先行（実装は後続 PR）。 | Claude Code |
| 2026-05-19 | codex 自動レビュー設定 + codex P1×3 / P2×1 反映: FR-7 と §5 制約追記、§1.3 スコープ修正、`.github/workflows/codex-review.yml` 新設、`CLAUDE.md` Git ワークフロー節更新、`README.md` ファイル構成更新。AC-4 / FR-4.6 で `^[1-9][0-9]{2}$` により curl `000` を拒否、SEC-8 を運用ハイジーンに降格、SEC-12 を 12.1（実装済み）/ 12.2（要件先行）に分割、AC-7 を compose 経由に変更。SEC-8 機械化と SEC-12.2 実装は follow-up PR。 | Claude Code |
| 2026-05-19 | `.github/workflows/codex-review.yml` 撤去（`github-actions[bot]` 名義の `@codex review` は codex に拒否されるため）。FR-7 を実態に合わせ、ready 化または Codex 接続済みアカウントからの手動コメントが必要であることを明記。codex の追加指摘を反映: FR-4.6/AC-4 に `init-firewall.sh:105` が未対応であることを注記、FR-1.6 を Compose プロジェクト名非依存の表現に書き換え。CLAUDE.md / README.md も同期。 | Claude Code |
| 2026-05-19 | izumacha レビュー反映: `README.md` と `CLAUDE.md` の「一切マウントしない」表現を SEC-8 と整合させ「追加 bind mount しない / 機密ディレクトリ配下では起動しない」に修正。脅威モデル表も同様に更新。 | Claude Code |
| 2026-05-20 | codex P2×3 反映: FR-1.6 に同名グローバルボリューム削除の破壊的副作用を明記、FR-3.3 の復旧手順に `aidock build` 再ビルドを追加、AC-5 を best-effort に緩和（`bin/aidock logout` の `\|\| true` による失敗隠蔽を明示）。実装側強化（`bin/aidock` の終了コード伝播・`docker volume rm` 撤去）は follow-up PR。 | Claude Code |
| 2026-05-20 | codex 追加 P2×2 反映: §1.1 目的の「一切コンテナへ渡さない」を SEC-8 と整合する文言に緩和、AC-7 の復旧手順に `aidock build` を追加し FR-3.3 と整合。 | Claude Code |
| 2026-05-20 | セルフレビュー反映: §8 改訂履歴の凡例違反を修正（workflow 撤去エントリを正しい時系列位置へ移動）、`最終更新` ヘッダを 2026-05-20 に同期。 | Claude Code |
