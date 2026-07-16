# CLAUDE.md

このファイルは、本リポジトリで作業する AI アシスタント（Claude Code など）向けのガイドです。詳細なユーザー向け説明は `README.md` を参照してください。

> このファイルの **§4 以降（共通規約 ＋ 付録）は原本テンプレート `izumacha/claude-code-rules` の
> `CLAUDE.md` と同期**している。共通規約を変更するときは、**まず原本を改訂してから**各リポジトリへ
> 反映すること（このファイルで共通規約だけを勝手に書き換えない）。§1〜§3 は本リポジトリ固有の内容。
>
> **正本（Source of Truth）は `docs/requirements.md`**。実装・ドキュメント・新機能の提案はすべて要件
> 定義書に従う。要件と実装が衝突したら、**先に要件定義書を改訂してから実装を変更する**（同 PR 内で
> `docs/requirements.md` の §3 / §4 / §6 を更新する）。
>
> **このリポジトリのコミットメッセージは英語・命令形・1 行要約**（既存履歴に倣う。§12 の日本語コミット
> 規約より優先する例外）。

---

## 1. プロジェクト概要

`AI-Docker-Environment` は Linux ホスト上で **Claude Code (`@anthropic-ai/claude-code`)** を安全に実行するための Docker サンドボックス。Anthropic 公式 devcontainer のセキュリティモデルを踏襲し、次の防御層を組み合わせる。

- **デフォルト拒否の egress ファイアウォール**（iptables + ipset 許可リスト）
- **最小権限モデル**（`cap_drop: ALL`、`no-new-privileges`、root 起動 → `gosu` で agent 降格・sudo 不使用）
- **ファイルシステム分離**（read-only rootfs + tmpfs、`$PWD` のみ bind mount）
- **リソース上限**（メモリ 4G、CPU 2 コア、PID 1024）
- **OAuth 資格情報の隔離**（名前付きボリューム `claude-home`）

ホストの `~/.ssh` / `~/.aws` / `~/.config/aws` / `~/.config/gcloud` 等を**追加 bind mount しない**。ただし `$PWD` は `/workspace:rw` で渡るため、機密ディレクトリ配下では `aidock` が起動を機械的に拒否する（`docs/requirements.md` SEC-8）。**Linux 専用**（iptables/ipset/cap_add 依存。macOS Docker Desktop 非対応）。

## 2. コマンド

すべて `bin/aidock` 経由で実行する（テストランナー・Makefile・npm scripts はなし）。

| コマンド | 用途 |
|---|---|
| `./bin/aidock build` | イメージビルド（`HOST_UID`/`HOST_GID` を `id -u`/`id -g` で注入） |
| `./bin/aidock login` | 初回 OAuth ログイン（`AIDOCK_PROFILE=login` で許可リスト一時拡張） |
| `./bin/aidock` / `./bin/aidock run [args]` | `$PWD` を `/workspace` に bind mount して Claude Code 起動（デフォルト） |
| `./bin/aidock shell` | デバッグ用 bash シェル |
| `./bin/aidock firewall-refresh` | 稼働中コンテナ内で `init-firewall.sh` 再実行（DNS ローテーション対応） |
| `./bin/aidock logout` | `claude-home` ボリュームを削除し OAuth 資格情報を破棄 |

`bin/aidock` には `$HOME` および `/` を `/workspace` にマウントしないガード（`guard_workspace()`）が組み込まれている。**削除してはいけない**。

## 3. アーキテクチャ

### リポジトリ構成

```
.
├── bin/aidock              # CLI ラッパー (bash)
├── docker/
│   ├── Dockerfile          # node:22-slim ベース、claude-code を npm -g
│   ├── init-firewall.sh    # iptables + ipset の許可リスト構築
│   └── entrypoint.sh       # firewall 初期化 → exec
├── test/guard_test.sh      # guard_workspace() 等の自動テスト（CI から実行）
├── .github/workflows/      # ci.yml（型チェック＋e2e）/ post-ci-verify.yml（Claude Code Action）
├── compose.yaml            # サービス定義 + セキュリティオプション
├── docs/requirements.md    # 要件定義書（正本 / Source of Truth）
├── README.md               # 日本語の詳細ドキュメント
└── CLAUDE.md               # このファイル
```

ソースは bash スクリプトと Docker 関連ファイルのみ（アプリケーションコードなし）。

### セキュリティ不変条件（編集時に必ず守る）

脆弱化につながるため**変更禁止**、または変更時は必ず影響を検討する。

- `compose.yaml`:
  - `cap_drop: ALL` / `cap_add: [NET_ADMIN, NET_RAW, SETUID, SETGID]` のみ（`SETUID`/`SETGID` は entrypoint の `gosu` 降格用）
  - `security_opt: no-new-privileges:true`
  - `read_only: true` ＋必要最小限の `tmpfs`
  - `mem_limit` / `pids_limit` / `cpus` の上限
  - ホストパスの追加 bind mount は原則禁止（特に `~/.ssh`、`~/.aws`、`~/.gitconfig` 等）
  - `/workspace` の `HOST_WORKSPACE` に**デフォルト値を付けない**（`${HOST_WORKSPACE:?...}`）。`bin/aidock` 非経由の直接 `docker compose run` を fail-closed にする SEC-8 一次防御 (a)。`bin/aidock` の `compose()` が必ず値を供給する
- `docker/Dockerfile` / `docker/entrypoint.sh`:
  - コンテナに `sudo` を含めない。root で起動し firewall 初期化後に `gosu agent` で降格（setuid 昇格を使わない）。ワークロード（claude-code）は `agent` で実行し root で実行しない
- `docker/init-firewall.sh`:
  - `iptables -P OUTPUT DROP`（デフォルト拒否）を維持
  - **IPv6 も `ip6tables -P OUTPUT DROP` で default-deny を維持（SEC-16 / issue #32）**。IPv4 だけ絞って IPv6 を素通しにしない。許可は loopback / ESTABLISHED / v6 nameserver（`allowed-dns6`）/ AAAA 許可リスト（`allowed-hosts6`）/ meta の v6 CIDR のみ
  - 終端の検証プローブ（`example.com` ブロック v4/v6、`api.anthropic.com` 到達）を維持
  - **許可リスト依存の meta fetch より前に終端 DROP を設置**（issue #34）。デフォルトポリシーのみに拒否を依存させない
  - 許可ホスト追加は `CORE_HOSTS` / `LOGIN_EXTRA_HOSTS` に最小限で追記し、PR に理由を述べる
  - DNS は `nameserver` 限定（ipset `allowed-dns` / SEC-15、**実装済み**）。53 番は (a) `agent`→`127.0.0.1:53` プロキシ、(b) プロキシ→`127.0.0.11:53` forward の 2 経路のみ許可、それ以外の `agent` の 53 番は DROP。拒否名は NXDOMAIN に統一。resolv.conf を `127.0.0.1` に書き換える前に元上流 DNS を捕捉し `allowed-dns` の種にする（FR-11.1）。**注意: このユーザー空間 DNS プロキシ（FR-11、query 名 allowlist 施行）自体は `docs/requirements.md` 上「要件先行、実装は後続 PR」であり、現行の `init-firewall.sh` には未実装。** 現状実装されているのは nameserver IP 限定（SEC-15）のみで、上記 2 経路制限・NXDOMAIN 統一は将来実装時に守るべき契約として記載している。`init-firewall.sh` を編集する際はこの区別を `docs/requirements.md`（正本）の FR-11 / SEC-15 の実装状況欄で必ず確認すること。
- `bin/aidock`:
  - `guard_workspace()` の `/` および `$HOME` 拒否を維持

OAuth トークンは必ず名前付きボリューム `claude-home` に置き、ホスト FS や Docker イメージ層に書き出さない。

### 設定とカスタマイズ（環境変数）

- `AIDOCK_PROFILE` — `run`（既定）または `login`。`login` 時のみ `claude.ai` 等の OAuth ホストを許可。
- `HOST_UID` / `HOST_GID` — `bin/aidock` が自動検出。
- `HOST_WORKSPACE` — `/workspace` にマウントするホストディレクトリ。`compose.yaml` 側に既定値なし（`${HOST_WORKSPACE:?...}`）。`bin/aidock` 非経由の直接 `docker compose run` は fail-closed で起動失敗する（SEC-8）。
- `AIDOCK_SKIP_FIREWALL=1` — ファイアウォール初期化をスキップ（デバッグ用）。**単独では起動拒否**され、`AIDOCK_INSECURE_ACK=1` の併設が必須（二重キー、SEC-13 / issue #33）。

主な調整箇所: リソース上限（`compose.yaml` の `mem_limit` / `cpus` / `pids_limit` / `NODE_OPTIONS`）、Claude Code バージョン（`docker/Dockerfile` の `ARG CLAUDE_CODE_VERSION`）、テレメトリ抑制（`init-firewall.sh` の `CORE_HOSTS` から `statsig.anthropic.com` / `sentry.io` を削除）。

### CI / Git ワークフロー（固有事項）

- CI は GitHub Actions（`.github/workflows/ci.yml`）で**型チェック**（shellcheck / hadolint / `docker compose config`）と **e2e**（AC-1〜AC-4 / AC-7 の実機検証）を実行（FR-8 / AC-8）。`ci.yml` から codex へのコメント投稿はしない（FR-7）。
- CI 成功後、`.github/workflows/post-ci-verify.yml` が Claude Code Action（`anthropics/claude-code-action@v1`）を起動し type-check / e2e を検証・要約して PR にコメント（FR-9 / AC-9）。認証は Claude GitHub App + `CLAUDE_CODE_OAUTH_TOKEN` secret。`workflow_run` の仕様上 `main` マージ後に有効。codex（コードレビュー）とは別物。

---

## 4. 実装フロー（プランモード必須）

コード変更を伴う作業に着手する前に、**必ず Claude Code のプランモード（Plan Mode）で計画を作成し、ユーザーの承認を得てから実装に移る**こと。

- 対象: 機能追加・改修・リファクタ・バグ修正など、ソースコード／スキーマ／設定ファイルを変更するすべての作業。
- 計画には以下を含める:
  1. **Context**: 何を、なぜ変更するのか。正本（要件定義書・計画書）のどの項目に対応するか。
  2. **変更対象ファイル**: 修正・追加するファイルの絶対パス（既存ファイルは行番号や関数名まで具体化）。
  3. **再利用する既存実装**: 既にある関数・モジュール・Port を優先して再利用する。新規作成する場合はその理由を明記。
  4. **検証方法**: lint / typecheck / test（必要に応じて E2E）と、画面確認の手順。
- **例外**: タイポ修正・コメントのみの変更・1 行以下の自明な修正は計画作成を省略してよい。それ以外は必ず `ExitPlanMode` でユーザー承認を得る。
- 計画と異なる実装が必要になったら、いったん手を止めてプランを更新（または `AskUserQuestion` で確認）してから続行する。

## 5. コメント規約（最優先）

- **1 行ごとに初心者でも意味がわかるコメントを書く。** コード 1 行ごとに、プログラミング初心者でも処理内容が理解できる日本語コメントを付ける。変数宣言・条件分岐・関数呼び出し・ループ・`return` など、すべての実行行に対して「何をしているか」を説明するコメントを必ず添える（型定義の単純な再エクスポートなど明らかに自明な行は除く）。
- コメントは行の直前または行末に記述し、専門用語を使うときは平易な言い換えを併記する。
  - 例: `var x = users.Where(u => u.IsActive); // アクティブなユーザーだけを抜き出す`
- このルールは本方針固有であり、汎用的な「コメントは最小限に」というガイダンスよりも**優先**する。
- 言語別コメント記法: C# / JS / TS は `//`、Razor (`.cshtml`) は `@* *@`、JSON など非対応形式は対象外。

## 6. コーディング規約

- **既存コードのスタイルに合わせる。** インデント・命名・ファイル構成は周囲の慣習を踏襲する。
- **自己説明的な構成にする。** モジュールは単一責務に分割し、ファイル名・関数名から役割が推測できるようにする。公開関数には docstring / コメントで意図を残す。
- **設計判断を残す。** 非自明な実装やトレードオフには「なぜそうしたか」をコメントで残す。
- **定数・ラベルは一元管理する。** 配色・フォント・余白・UI 文言・enum ラベルなどは単一の参照元（例: `theme.py`, `constants.ts`, `EnumLabels.cs`, CSS の `:root` 変数）に集約し、各所に直書きしない。新しい値を追加したら参照元をすべて更新する。
- **マジックナンバー・マジック文字列を避ける。** 意味のある値（しきい値・キー名・パスなど）は名前付き定数にし、上記の一元管理に従って単一の参照元に置く。意図が読み取れない裸の数値・文字列をコードに散らさない。
- **重複を避ける（DRY）。** 同じロジックを書き写す前に既存の関数・モジュール・Port を探して再利用する（§4 のプラン段階で確認）。ただし将来を見越した過度な抽象化は避け、実際に 2〜3 箇所目で重複したら共通化する。
- **エラーを握り潰さない。** 例外は黙って捨てず、文脈を付けて再送出するかログに残す。空の `catch` / 裸の `except:` を作らない。回復不能な失敗は安全側に倒し（§9 の fail-closed）、ユーザーには内部詳細を含まない安全なメッセージを返す。
- **デッドコードを残さない。** 使われない import・変数・関数や、コメントアウトしただけの旧コードは削除する（履歴は Git に残る）。
- **変更は最小スコープに保つ。** 1 つの変更は単一の目的に絞り、無関係なリファクタや整形を同じ差分に混ぜない（§12 の「1 コミット = 1 論理変更」と整合）。レビューしやすい粒度を保つ。
- 言語別の補足:
  - **TypeScript**: `strict: true` を維持。`any` は禁止（不明なら `unknown`）。Props は `interface` で定義。パスエイリアス `@/*` → `src/*`。Server Component をデフォルトにし、必要時のみ `'use client'`。
  - **Python**: `from __future__ import annotations` を先頭に。公開関数に docstring。入力検証は「範囲外→クランプ、非数値→デフォルト」パターン。定数は `UPPER_SNAKE_CASE`。
  - **Bash**: 先頭で `set -euo pipefail`。ログは stderr。インデント 4 スペース。

## 7. アクセシビリティ（a11y）

- **対象は Web フロントエンド（HTML/CSS/JS を伴う UI）。** CLI・ライブラリ・バッチや、HTML を持たないネイティブ GUI（tkinter 等）には適用しない（共通規約の中で数少ない、適用範囲が限定される項目）。ネイティブ GUI の a11y は各リポジトリの固有ルールで扱う。
- **セマンティック HTML を使う。** 見出しは階層（`h1`→`h2`→…）を飛ばさず、操作要素は `<button>` / `<a>` を使う。`div` / `span` に `onClick` を乗せて疑似ボタン化しない。
- **キーボードだけで全機能を操作できるようにする。** フォーカス可能要素は可視のフォーカスリングを残す（`outline` を消す場合は代替の見た目を用意）。モーダルはフォーカストラップ＋`Esc` で閉じ、`tabindex` は `0` / `-1` のみ使う（正の値は使わない）。SPA でページ遷移したらフォーカスを新ページの先頭（`main` 等）へ移し、本文へ飛ぶスキップリンクも用意する。
- **スクリーンリーダーに情報を伝える。** 画像に `alt`（装飾画像は `alt=""`）、アイコンだけのボタンに `aria-label`、フォーム入力に対応する `<label>`（または `aria-labelledby`）を付ける。`aria-live` は簡潔な状態通知・エラーなど「即時に読み上げてほしい変化」に限って使う（検索結果・タイマー・カルーセル・ストリーミング等、頻繁に変わる領域全体に付けると読み上げ過多でかえって使いづらくなる）。
- **色だけに意味を持たせない。** エラー・成功などの状態はテキストやアイコンも併用する。コントラスト比は WCAG AA を満たす（通常文 4.5:1 / 大きな文字 3:1。加えて UI 部品の境界・状態・フォーカスリングや意味のある図形などの非テキストは 3:1＝SC 1.4.11）。配色は §6 の一元管理（CSS の `:root` 変数・`theme`）側でコントラストも担保する。
- **動きを抑えられるようにする。** `prefers-reduced-motion` を尊重し、過度なアニメーションは無効化できるようにする。
- **言語属性と外部リンクを正しく設定する。** ルート要素の `lang` は実際の文書の言語（§1 で宣言した UI 言語）に一致させる。多くは日本語なので `lang="ja"` だが、UI が他言語のリポジトリやローカライズページでは、その言語を正しく指定する（発音・言語処理が支援技術の挙動を左右するため）。別タブで開く外部リンクには `rel="noopener noreferrer"` を付ける。
- **検証する。** Lighthouse / axe などで a11y を確認し、可能なら CI（§14）に組み込む。キーボードのみでの操作確認を手動チェックに含める。

## 8. パフォーマンス・リソース

- **N+1 クエリを避ける。** ORM では関連を eager-load（EF Core の `.Include`、Prisma の `include` / `select`）でまとめて取得する（§E の `.Include(x => x.Incident)` と整合）。ループの中で 1 件ずつクエリを投げない。
- **よく絞り込む列にインデックスを張る。** `where` / `order by` / `join` で頻繁に使う列（ユーザー ID・日付・ステータス等）には DB インデックスを作成し、全件走査（sequential scan）を避ける。複合条件では複合インデックスの列順も意識する。
- **一覧取得は必ず上限・ページネーションを持たせる。** 件数無制限の取得をしない（§9 の DoS・リソース枯渇防止と整合）。既定件数・最大件数は定数で一元管理する（§6）。
- **計測してから最適化する。** 推測で最適化せず、プロファイラ／メトリクスで遅い箇所を特定してから手を入れる。早すぎる最適化で可読性を犠牲にしない。
- **重い処理で UI／イベントループを止めない。** 大量データの計算・変換・パースは分割や非同期化（Web Worker・ストリーム処理・バックグラウンドジョブ）で行い、メインスレッドやリクエスト処理をブロックしない。
- **フロントの配信を最適化する。** Web ではバンドルを分割（dynamic import / code splitting）し、画像は適切なフォーマット・サイズで最適化する。フォールド下や重要でない画像は `loading="lazy"` で遅延読み込みし、ファーストビューの LCP 候補（ヒーロー画像等）は遅延させず優先的に読み込む（Next.js は `next/image`。LCP 画像の優先読み込みはバージョンに応じて指定する: 16+ は `preload`、〜15 は `priority`）。重い依存は遅延読み込みする。
- **Core Web Vitals を意識する。** LCP / CLS / INP を悪化させない。画像・広告枠などにはサイズを指定してレイアウトシフトを防ぎ、Web フォントには `font-display: swap`（または `fallback`、装飾用途は `optional`）を設定して FOIT（文字が一定時間不可視になる現象）で LCP を悪化させない。
- **キャッシュを活用する。** 同じ計算・取得を繰り返さない（メモ化やフレームワークのキャッシュ機構 — Next.js なら 16+ の `use cache`／〜15 の `unstable_cache`、§D と整合 — を使う）。キャッシュは無効化条件を明確にし、古いデータを返さないようにする。
- **リソースを確実に解放する。** 接続・ファイル・タイマー・購読は使い終わったら閉じる（§D の SSE 購読のように、購読解除を必ず実装する）。

## 9. セキュリティ（必達）

- **入力は信用しない。** 外部入力（ユーザー入力・設定ファイル・JSON・環境変数）は必ず検証する。Web ではスキーマ検証（例: Zod の `safeParse`）を通してから永続化・API へ渡す。壊れたデータでクラッシュさせず、不正値はフォールバックする。
- **正規表現で algorithmic DoS（ReDoS）を起こさない。** 信頼できない入力に使う正規表現はネストした量指定子（`(a+)+` など）を避け、入力長に上限を設ける。複雑なパターンは線形時間のマッチャや専用の検証ライブラリに寄せ、未検証の正規表現を外部入力に直接当てない。
- **秘密情報をコミットしない。** 認証情報・トークン・API キー・個人情報をコード・ログ・コミットに含めない。`.env` / `.env.local` はコミットせず、`.env.example` にキー名だけ記載する。
- **API キーをフロントエンドに露出させない。** 外部 API はサーバー側（API ルート / Server Action）経由で呼ぶ。モデル名やエンドポイントは定数・環境変数で管理し、ハードコードしない。
- **認可はサーバー側で強制する。** UI を隠すだけに頼らず、Server Action / コントローラの冒頭で認証・ロールチェックを行う。マルチテナントではクエリに必ずテナント条件（`where.tenantId = session.user.tenantId`）を差し込み、クロステナント漏洩を防ぐ。
- **外部 Webhook は署名を検証する。** 受信 Webhook は共有シークレットで HMAC 署名（例: `X-Hub-Signature-256`）を検証し、一致しないリクエストは拒否する。アプリ層の認証だけに頼らず、なりすまし POST で状態を変えられないようにする。検証は定数時間比較で行う。
- **危険な実行・安全でない解析を避ける。** `eval` / `exec` / `pickle` / `shell=True` を使わない。外部コマンドは引数配列で実行し、ユーザー入力を文字列連結でシェルに渡さない。信頼できない XML は外部実体（XXE）・DTD を無効化したパーサで読み（.NET は `DtdProcessing = Prohibit`、Python は `defusedxml`）、YAML は `safe_load`、JSON は eval せず標準パーサで解析する。
- **失敗しても安全側に倒す（fail-safe / fail-closed）。** 例外時はクラッシュや権限昇格ではなく機能を縮退して継続する。権限・ネットワーク・パスの判定は「不明なら拒否」をデフォルトにする。
- **最小権限・最小公開。** 読み書きするファイルは想定パス配下に限定し、外部由来の値をそのままパスに連結しない（パストラバーサル防止）。
- **サーバー側の外向きリクエストを検証する（SSRF 対策）。** ユーザー由来の URL をそのまま `fetch` / HTTP クライアントに渡さない。スキーム・ホストを許可リストで制限し、プライベート IP（`127.0.0.0/8` / `10.0.0.0/8` / `169.254.0.0/16` 等）やクラウドメタデータ（`169.254.169.254`）への到達を遮断する。リダイレクト追跡先も同様に検証する。
- **リダイレクト先を検証する（オープンリダイレクト対策）。** `returnUrl` / `next` など外部由来の遷移先は、自サイト内パス（または許可リスト）に照合してからリダイレクトする。任意の絶対 URL へ飛ばさない（ログイン後フィッシング防止）。
- **出力もエスケープする（インジェクション対策）。** SQL は ORM／パラメータ化クエリで組み立て、ユーザー値を文字列連結で SQL に混ぜない。HTML はフレームワークの自動エスケープに任せ、`dangerouslySetInnerHTML` / `v-html` / `innerHTML` などの生 HTML 挿入は原則避ける（やむを得ない場合はサニタイズしてから）。OS コマンド・パス・LDAP なども同様に値を直接連結しない。
- **状態変更リクエストを保護する。** フォーム送信や書き込み系 API には CSRF トークン（またはダブルサブミットクッキー）を必須とする。`SameSite` クッキーはそれを置き換えるものではなく、多層防御として併用する（OWASP 準拠。登録ドメインを他サービスと共有する場合、サブドメイン経由や `Lax` のトップレベル遷移では `SameSite` だけでは防げない）。副作用のある操作を GET で行わない。
- **機密情報・PII・スタックトレースをログやエラー応答に漏らさない。** 外部にはサニタイズした安全なメッセージだけを返し、詳細はサーバ内ログに限定する。ログに残す前にトークン・個人情報はマスク／伏字化する。
- **暗号・認証情報は自前実装しない。** パスワードは平文・可逆形式で保存せず bcrypt / argon2 等でハッシュ化する。暗号化は標準ライブラリを使い、自前の暗号方式を発明しない。署名・擬似匿名化に使うソルトや鍵は環境変数から取得し、未設定なら起動を失敗させる（fail-closed）。
- **依存（サプライチェーン）を管理する。** ロックファイルをコミットし、新規依存は最小限に絞って出所・メンテ状況を確認する。`npm audit` / Dependabot 等で既知脆弱性を定期的に確認し、放置しない。
- **公開エンドポイントを保護する。** レート制限と、リクエストサイズ・タイムアウト・ページネーション上限を設けて DoS とリソース枯渇を防ぐ。

## 10. 移植性・プラットフォーム差異ゼロ設計

- **ロジックと UI を分離する。** ビジネスロジックは表示層に依存しない純粋関数として保ち、Web / デスクトップ / モバイルで共有できる状態を維持する。
- **プラットフォーム差を 1 か所に閉じ込める。** OS / 実行環境固有の処理は分岐（例: `platform.system()`）で局所化し、必ずフォールバックを用意する。
- **移植可能な書き方をする。** 特定 OS でしか動かない記述（例: `strftime` の `%-d`）を持ち込まない。同じ操作はどの環境でも同じ結果になるよう、判定ロジックは共有層に置きテストで担保する。
- **契約（contract）で同一性を保証する。** 言語・プラットフォーム非依存の入力→期待出力ケース（例: JSON の契約ファイル）を真実の源とし、各実装はそれに従う。

## 11. テスト

- **テストは必ず通過させること。** 変更の前後で、そのリポジトリの §2 と CI 設定（`.github/workflows/`）に記載された実際の検証コマンド（lint / 型チェック / テスト等、存在するものすべて）を通す。コマンド名や有無はスタックごとに異なるため、§2 と CI 設定を正本とし、ここに書かれた例（`lint && typecheck && test` 等）をそのまま当てはめない。
- テストファイルはそのスタックの慣習に従った場所・命名で配置する（例: Python/JS は `tests/` に `test_<module>.py` / `*.test.ts`、Maven は `src/test/java` に `<Class>Test.java`、.NET は専用テストプロジェクトに `<Class>Tests.cs`）。
- **純粋ロジックはユニットテスト、DB / 外部依存は E2E or 契約テストに寄せる。** ユニットテストに DB アクセスを持ち込まない。外部 API はモックして実際には呼ばない。
- 境界値（0・最大・空文字列・非数値など）を重視する。OS 依存処理はモック（`@patch` 等）し、特定 OS でしか通らないテストを作らない。
- DB を破壊的に扱う契約テストは、専用 DB を明示フラグで起動したときだけ走らせ、開発 DB を指さない。共有 DB を `TRUNCATE` するテストは直列実行する。

## 12. Git 規約

- コミットメッセージ形式: `type(scope): 日本語の説明`
  - type: `feat` / `fix` / `refactor` / `test` / `docs` / `chore`
  - scope: 変更領域（例: `chat`, `api`, `ui`, `tickets`, `reminder`）
  - 例: `feat(chat): ストリーミング応答の実装`
- **1 コミット = 1 論理変更。** スキーマ変更とマイグレーションは同一コミットに含める。
- 開発は機能ブランチで行い、`main`（デフォルトブランチ）への直 push は避ける。

## 13. PR・レビュー運用

- **PR は draft ではなく open（ready）で作成する。** harness のデフォルトが draft の場合は、作成直後に ready 化してから次の手順に進む。
- **コードレビューは `/code-review ultra` と `/security-review ultra` で行う（Codex 自動レビューは廃止）。** PR を ready 化して open にした直後、および PR ブランチへ push するたび（初回 PR 作成時を含む）に、この 2 つのスキルを実行して差分をレビューする。`@codex review` コメントの投稿は行わない（`chatgpt-codex-connector` 連携には依存しない）。
  - `/code-review ultra` — 差分の正確性（バグ）と、再利用・簡素化・効率・粒度（altitude）の観点でレビューする。
  - `/security-review ultra` — ブランチの保留中変更に対してセキュリティレビューを行う。
  - 指摘は対応可否を判断して反映し、対応・見送りの理由をチャットで報告する。質問返信やレビュー不要な状況報告では実行しない。
- **CI の成否（グリーン）はチャット上で報告する。** GitHub MCP（check-runs / status）で取得して報告する。
- **ユーザーへの結果報告・要約は必ず日本語で出力する。** CI の成否・レビュー結果・作業サマリなど、要約した結果は常に日本語で記述する（各リポジトリの UI／コード言語に関わらず、チャットでの報告は日本語に統一する）。

## 14. CI

- GitHub Actions（`.github/workflows/`）でそのリポジトリに必要な検証を実行する。実行するジョブはスタックに応じて異なる（例: Web/TS なら lint → typecheck → test → E2E、Maven なら `mvn -B verify`、.NET なら `dotnet build` ＋ `dotnet test`、シェル/Docker なら shellcheck / hadolint / `docker compose config` ＋ e2e）。**PR を出す前に、§2 と CI 設定に記載のローカル検証コマンド（そのリポジトリに実在するものすべて）を通す。** 存在しないコマンドを当てはめない。
- DB / ブラウザ依存のジョブはサービスコンテナ（PostgreSQL 等）や chromium を使う。依存があるスタックでは、ローカルでも `docker compose up` などで依存を起動してから実行する。

---

## 付録: リポジトリ別のルール（Appendix）

各リポジトリの `CLAUDE.md` から、**§4〜§14 の共通規約と重複しない固有ルールだけ**を抜き出したカタログ。
新規リポジトリが似た技術スタックの場合、該当ブロックを §1〜§3 の具体化や追補として流用できる。
（出典の `CLAUDE.md` には、ここに載らないプロジェクト固有のアーキテクチャ詳細も含まれる。詳細は各リポジトリを参照。）

### A. profile-portfolio（静的 HTML/CSS/JS, GitHub Pages）

- ビルドツール・パッケージマネージャを使わない。確認は `open index.html` または `python -m http.server 8000`。
- ファイル構成: `index.html`（ダークテーマ）/ `resume.html`（ライトテーマ・印刷対応）。
- 色の変更は `:root` の CSS 変数（`--primary`, `--accent`, `--bg-dark` 等）経由。個別要素にカラーコードを直書きしない。
- レスポンシブ: ブレークポイント 968px（タブレット）・768px（モバイル）。グリッドは `auto-fit, minmax()` でメディアクエリを最小化。フォントは `clamp()` で流体タイポグラフィを適用。
- CSS は BEM 風命名（`.section-header` 等）、JS は Vanilla のみ（外部ライブラリを追加しない）。a11y の基本（セマンティック HTML・`alt`・外部リンクの `rel`・`lang`）は §7 に従う（この repo は日本語 UI なので `lang="ja"`）。
- セクション追加時は Intersection Observer の `.observe()` 対象に追加し、ナビリンク・768px 表示・`resume.html` 反映を確認する。

### B. my-task-manager（Python + tkinter, GUI）

- ビジネスロジックは GUI 非依存の純粋関数に保つ（`timeline.py` / `stats.py` / `recurrence.py` / `task.py`）。表示層を差し替えてもロジックを共有できる状態を維持。
- デザイントークン（配色・フォント・余白・カレンダー寸法）は `theme.py` に一元化。見た目の値をコードに直書きしない。
- 繰り返しタスクは「完了した時点」を起点に日/週/月/年で再スケジュール（月末日・うるう年はクランプ）。
- 言語・プラットフォーム非依存の繰り返し契約は `contract/recurrence_cases.json` を真実の源とし、契約駆動テスト（`test_recurrence_contract.py`）で検証。Web/スマホ版も同一契約に従う。
- tkinter の `StringVar` / `IntVar` はテスト用 `_DummyVar` で代替し、`_create_app()` ファクトリでモック済みインスタンスを生成（Tk 無しでテスト可能）。
- 入力検証は `_coerce_int()` パターン（範囲外→クランプ、非数値→デフォルト）。
- 今日のタスクは Treeview でなく `tk.Canvas` の「デイビュー」で描画し、位置・高さは分→px 換算（`HOUR_HEIGHT`）で Canvas 実サイズに依存させない。
- クロスプラットフォーム: 音/通知は macOS(`afplay`)・Windows(`winsound`)・Linux(`notify-send`+`tk.bell()`)を `platform.system()` で分岐。`cairosvg` はオプション依存で `ImportError` 時 graceful degradation。

### C. my-first-ai-app（Next.js 16 + Claude API）

- システムプロンプトは `src/lib/prompts.ts` に集約し、コンポーネントやルートハンドラに直接書かない。プロンプトは日本語で記述。
- モデル名（`claude-sonnet-4-6` 等）は環境変数または定数で管理しハードコードしない。`max_tokens` 既定 1024、長文が必要なカテゴリは `prompts.ts` で個別設定。
- `POST /api/chat` が唯一の API。Claude へのストリーミングプロキシで、`ANTHROPIC_API_KEY` はサーバ側環境変数から取得しフロントに露出させない。
- API ルートに簡易レート制限（IP ベース、1 分あたり 20 リクエスト目安）。
- API ルートのエラーは HTTP ステータスを使い分け: 401（キー未設定/無効）/ 429（レート制限超過）/ 500（その他）。フロントはユーザーフレンドリーな日本語メッセージを表示。

### D. helpdesk-hub（Next.js 15 / Prisma / Auth.js v5）

- 正本は `docs/smb-dx-pivot-plan.md`。Lite/Pro 二層・マルチテナント化・用語簡素化等の方針に反する変更をしない。Phase 0→1→2→3→4 の順序を尊重し、後フェーズ機能を前フェーズに混ぜない。
- Prisma クライアントは `src/generated/prisma` に出力される。型/enum は必ず `@/generated/prisma` から import（`@prisma/client` ではない）。クローン後やスキーマ変更後は `npm run db:generate` を実行。
- ロールは実質 requester と agent/admin の 2 種。`isAgent(role)`（`src/lib/role.ts`）を使い、`role === 'admin'` を直接比較しない（admin 限定の意図がある場合を除く）。
- Mutation（Server Action）の定型: `auth()`＋ロール表明 → `findUniqueOrThrow` → 状態変更は `isValidTransition(from,to)` でゲート → Prisma で更新 → `recordHistory(...)` → `createNotification(...)` → `revalidatePath(...)`。
- 状態遷移テーブル `ALLOWED_TRANSITIONS`（`src/domain/ticket-status.ts`）が唯一の真実の源。バイパスせず、ブロックされたら表とテストを更新する。
- Data 層は Ports & Adapters。Port を `src/data/ports/` に定義し、本番は `adapters/prisma/`、テストは `adapters/memory/`。Prisma を直接 import するのは Adapter 内のみ。
- 未読通知数は SSE（`/api/notifications/stream`）＋ `unstable_cache` で配信。`sse-subscribers.ts` はインプロセス Map のため、水平スケール前に要注意。
- 契約テストは `*.contract.prisma.test.ts` 命名。`RUN_PRISMA_CONTRACT=1` のときだけ走り、`beforeEach` で全テーブル `TRUNCATE` するため**開発 DB を指さない**。`--no-file-parallelism` で直列実行。

### E. incident-insight（ASP.NET Core 8 MVC + EF Core 8）

- DB プロバイダ非依存。SQLite（既定）/ SQL Server / PostgreSQL を `Database:Provider` で切替。プロバイダ固有 SQL・列型をコードに持ち込まない。
- 楽観的同時実行制御: 編集 POST は `FindAsync` で再読込後、クライアントの編集前 `ConcurrencyToken` を `OriginalValue` に明示ピンして保存し、`DbUpdateConcurrencyException` を捕捉。トークンは hidden field で round-trip。
- 時刻は常に注入された `IClock`（JST）。`DateTime.Now/Today/UtcNow` を直接呼ばない。
- 監査ログは `AuditSaveChangesInterceptor` が唯一の源。`AuditLog` に直接書かない。`SaveChanges` 経由で更新し、`ExecuteUpdate`/`ExecuteDelete` を使わない（変更追跡を迂回し監査漏れになるため）。
- PHI 保護: 自由記述・個人名カラムには `[Sensitive(Mask.Redact)]` か `[Sensitive(Mask.Hash)]` を付与（`[REDACTED]` か HMAC-SHA256 擬似匿名化）。新カラム追加時も必ず annotate。本番で `Audit:HashSalt` 空は起動失敗。
- ビジネスルール `HasAtLeastOneValidMeasure`（インシデントは予防策が最低 1 件ないと登録不可）をバイパスしない。
- Enum（重症度・部署・インシデント種別）は `Incident` クラスの `static readonly` 辞書/配列が真実の源（DB ではない）。`EnumLabels.cs` に日本語ラベル＋Bootstrap カラーを集約。
- `SameDepartmentHandler` は `Incident` の eager-load（`.Include(x => x.Incident)`）が前提で fail-closed（null なら拒否）。
- 新規 POST アクション時チェック: `[Authorize]` / `[ValidateAntiForgeryToken]` / `ConcurrencyToken` ピン / 必要なら `.Include(Incident)` / `SaveChangesAsync` 使用 / `TempData["Success"|"Warning"]` / 新 PHI カラムに `[Sensitive]` / 対応テスト追加。テストは InMemory DbContext を優先（Mock より）。

### F. AI-Docker-Environment（Docker サンドボックス, bash, Linux 専用）

- 正本は `docs/requirements.md`。実装・新機能はすべて要件定義書に従い、衝突したら先に要件を改訂してから実装変更（同一 PR 内で §3/§4/§6 を更新）。
- すべて `bin/aidock` 経由で実行（`build`/`login`/`run`/`shell`/`firewall-refresh`/`logout`）。`guard_workspace()` の `/` および `$HOME` をマウント拒否するガードを削除しない。
- セキュリティ不変条件（変更禁止 or 影響必須検討）:
  - `compose.yaml`: `cap_drop: ALL`（必要 cap のみ add）/ `no-new-privileges:true` / `read_only: true`＋最小 `tmpfs` / メモリ・CPU・PID 上限 / ホストパスの追加 bind mount 原則禁止（`~/.ssh` 等）。
  - `HOST_WORKSPACE` に既定値を付けない（`${HOST_WORKSPACE:?...}`）。`bin/aidock` 非経由の直接 `docker compose run` を fail-closed にする。
  - `Dockerfile`/`entrypoint.sh`: `sudo` を含めず、root 起動 → firewall 初期化後に `gosu agent` で降格。ワークロードは `agent` で実行。
  - `init-firewall.sh`: `iptables -P OUTPUT DROP` と `ip6tables -P OUTPUT DROP`（IPv4/IPv6 両方 default-deny）を維持。許可ホスト追加は最小限・理由を PR に明記。DNS は許可 nameserver 限定。
- OAuth トークンは名前付きボリューム `claude-home` に置き、ホスト FS や Docker イメージ層に書き出さない。
- Linux 専用（iptables/ipset/cap_add 依存。macOS Docker Desktop 非対応）。スクリプトは Bash・先頭で `set -euo pipefail`、ログは stderr、インデント 4 スペース。
- このリポジトリのコミットメッセージは英語・命令形・1 行要約（既存履歴に倣う。§12 の日本語コミット規約より優先する例外）。
