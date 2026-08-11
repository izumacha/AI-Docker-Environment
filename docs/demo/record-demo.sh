#!/usr/bin/env bash
# README のデモブロック用に、代表フローの端末録画 (asciinema cast + GIF) を生成するスクリプト。
#
# 録画する代表フロー (CLAUDE.md「見せ方 (§15 の具体化)」に対応):
#   1. `aidock build`  — イメージのビルド (HOST_UID/HOST_GID 注入)
#   2. `aidock shell`  — コンテナ起動 → ファイアウォール初期化 → `agent` ユーザーへの降格を確認
#                        し、許可外ホスト (example.com) の遮断と api.anthropic.com への到達を確認
#
# 注意 (CLAUDE.md「見せ方」の制約):
#   - OAuth トークンやホストの実パス ($HOME 配下の個人情報が分かるパス) を録画に写さないため、
#     デモ用の一時ディレクトリへ移動してから aidock を起動する。
#   - `aidock login` / `run` の対話部分 (OAuth コード貼り付け・Claude Code の対話画面) は
#     自動化に向かないため本スクリプトでは録画しない。必要なら手動で
#     `asciinema rec -c './bin/aidock run' docs/demo/aidock-run.cast` のように録る。
#
# 実行環境: Linux ホスト (Docker デーモン必須)。依存: asciinema, agg。
#   asciinema: https://asciinema.org/ (例: pipx install asciinema)
#   agg:       https://github.com/asciinema/agg (cast → GIF 変換)
#
# 使い方: リポジトリルートで  ./docs/demo/record-demo.sh
# 生成物: docs/demo/aidock-demo.cast / docs/demo/aidock-demo.gif

set -euo pipefail

# このスクリプト自身の場所からリポジトリルートを求める (docs/demo/ の 2 つ上)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# 生成物の置き場所 (README から参照するパスと一致させる)
DEMO_DIR="${REPO_ROOT}/docs/demo"
# asciinema の録画データ (再生用の cast ファイル) の出力先
CAST_FILE="${DEMO_DIR}/aidock-demo.cast"
# README に貼る GIF の出力先
GIF_FILE="${DEMO_DIR}/aidock-demo.gif"
# GIF の上限サイズ (CLAUDE.md §15 の「10MB 以下」を名前付き定数にする)
GIF_MAX_BYTES=$((10 * 1024 * 1024))
# 録画する端末の桁数・行数。GIF の幅は「桁数 × フォント送り幅」で決まるため、
# ここを固定しないと撮影者の端末幅しだいで README 掲載画像の寸法が変わる。
# 120 桁 × フォントサイズ 16 で概ね 1150px 前後になり、§15 の「幅 1280px 目安」に収まる
RECORD_COLS=120
RECORD_ROWS=30

# ログはすべて stderr へ (共通規約)
log() { printf '%s\n' "$*" >&2; }

# 依存コマンドの存在確認 (無ければ導入方法を案内して fail-closed で終了)
require() {
    # command -v でパスが通っているかを調べる (見つからなければ非ゼロ)
    if ! command -v "$1" > /dev/null 2>&1; then
        # 何が足りないかと導入方法を伝えてから終了する
        log "error: '$1' が見つかりません。$2"
        exit 1
    fi
}
# 録画には Docker (aidock の実行) と asciinema (録画) と agg (GIF 変換) が要る
require docker "Docker デーモンが動く Linux ホストで実行してください。"
require asciinema "例: pipx install asciinema"
require agg "https://github.com/asciinema/agg の手順で導入してください。"

# CLI があってもデーモンが止まっていれば録画は失敗するので、ここで通信まで確かめる。
# docker info はデーモンへ実際に問い合わせる最も軽い呼び出し (fail-closed)
if ! docker info > /dev/null 2>&1; then
    log "error: Docker デーモンへ接続できません。デーモンを起動してから再実行してください。"
    exit 1
fi

# 録画に個人情報を写さないための中立な作業ディレクトリ (デモ用サンプルプロジェクト)
DEMO_WORKSPACE="$(mktemp -d /tmp/aidock-demo-workspace.XXXXXX)"
# 録画対象コマンドの本体と、その終了コードを受け取るための一時ファイル
STEPS_FILE="$(mktemp /tmp/aidock-demo-steps.XXXXXX.sh)"
STATUS_FILE="$(mktemp /tmp/aidock-demo-status.XXXXXX)"
# スクリプト終了時に一時ファイル類を必ず片付ける
trap 'rm -rf "${DEMO_WORKSPACE}" "${STEPS_FILE}" "${STATUS_FILE}"' EXIT
# ワークスペースがマウントされていることを録画中に見せるためのダミーファイル
printf '# aidock demo sample project\n' > "${DEMO_WORKSPACE}/README.md"

# 打ったコマンドを画面に見せてから実行するヘルパーを、録画される側のスクリプトに埋め込む。
# **これが無いと GIF に「何を打つとこうなるか」が写らない**: 外側は非対話シェルなので
# プロンプトもエコーも出ず、出力だけが唐突に始まる映像になってしまう。
#
# **録画対象は一時ファイルへ書き出して `bash <file>` で実行する。** 同じ内容を
# `bash -c "..."` の引数へ埋め込むと二重のシェル解釈になり、引用符の入れ子が破綻する。
#
# **パスはスクリプト本文に埋め込まず環境変数で渡す。** 埋め込むと、リポジトリのパスに
# `'` や `$` が含まれたときに壊れる (`/tmp/it's-repo` は構文エラー、`/tmp/my$repo` は
# 二重引用符の中で変数展開されて別のディレクトリを指す)。ヒアドキュメントの区切りを
# クォートして展開を止め、値は export 済みの環境変数から読ませればどんなパスでも安全になる。
export AIDOCK_DEMO_REPO_ROOT="${REPO_ROOT}"
export AIDOCK_DEMO_WORKSPACE="${DEMO_WORKSPACE}"

# コンテナ内へ渡すコマンドは最後に `exit` を送る。TTY 付きの対話 bash は標準入力の
# 終端だけでは終わらないことがあり、その場合 aidock shell が返らず録画がハングする。
cat > "${STEPS_FILE}" << 'STEPS'
# 打ったコマンドを表示してから実行する (録画に操作が写るようにするため)
run() {
    # 直前に空行を入れ、プロンプト風に "$ コマンド" を表示する
    printf '\n$ %s\n' "$*"
    # 表示した内容をそのまま実行する
    "$@"
}
# 1 つでも失敗したら以降を実行しない (壊れた録画を作らない)
set -e
# リポジトリルートへ移動してイメージをビルドする (パスは環境変数から受け取る)
cd "${AIDOCK_DEMO_REPO_ROOT}"
run ./bin/aidock build
# 個人情報を含まないデモ用ワークスペースへ移動する (ここが /workspace としてマウントされる)
cd "${AIDOCK_DEMO_WORKSPACE}"
# 次に打つコマンドを表示する (aidock shell はヒアドキュメントを渡すので run を使わない)
printf '\n$ %s\n' "aidock shell  # firewall init -> checks"
# コンテナを起動し、マウント内容・降格ユーザー・遮断・到達をまとめて確認する
"${AIDOCK_DEMO_REPO_ROOT}/bin/aidock" shell << 'INNER'
ls -la
whoami
curl -sS --max-time 5 https://example.com > /dev/null || echo '=> example.com blocked (default-deny)'
curl -sSI --max-time 10 https://api.anthropic.com | head -n 1
exit
INNER
STEPS

log "録画を開始します → ${CAST_FILE}"
# 端末の桁数・行数を固定してから録画する (GIF の寸法を撮影者の環境に依存させない)。
# 標準出力が端末でない場合 stty は失敗するので、その時は既定サイズのまま続行する
if [ -t 1 ]; then
    stty cols "${RECORD_COLS}" rows "${RECORD_ROWS}" 2> /dev/null || true
fi
# --idle-time-limit でビルド待ちなどの無操作時間を 2 秒に圧縮する。
# **asciinema rec は録画対象コマンドの終了コードを引き継がない**ため、`set -e` では
# 失敗を検知できない。ステップ側の終了コードをファイルへ書き出し、録画後に読んで判定する
asciinema rec --overwrite --idle-time-limit 2 \
    --command "bash '${STEPS_FILE}'; echo \$? > '${STATUS_FILE}'" \
    "${CAST_FILE}"

# 録画対象コマンドの終了コードを読む (書かれていなければ失敗扱いにする = fail-closed)
STEPS_STATUS="$(cat "${STATUS_FILE}" 2> /dev/null || echo 1)"
if [ "${STEPS_STATUS}" != "0" ]; then
    log "error: 録画対象のコマンドが失敗しました (exit ${STEPS_STATUS})。"
    log "       ${CAST_FILE} に失敗時の出力が残っているので原因を確認してください。"
    log "       GIF は生成しません (壊れた録画を README に貼らないため)。"
    exit 1
fi

log "GIF へ変換します → ${GIF_FILE}"
# 録画中の文字列はすべて ASCII に揃えてある。agg の既定フォント (JetBrains Mono 等) は
# 日本語グリフを持たず、CJK を含めると豆腐 (□) になって最重要の一行が読めなくなるため
agg --font-size 16 "${CAST_FILE}" "${GIF_FILE}"

# GIF は 10MB 以下が基準 (CLAUDE.md §15)。超過していたら警告する。
GIF_SIZE="$(stat -c %s "${GIF_FILE}")"
if [ "${GIF_SIZE}" -gt "${GIF_MAX_BYTES}" ]; then
    log "warning: GIF が 10MB を超えています (${GIF_SIZE} bytes)。--idle-time-limit や解像度を調整してください。"
fi

# 生成できたことと、コミット前の目視確認を促す
log "完了: ${CAST_FILE} と ${GIF_FILE} を生成しました。"
log "内容を目視確認し、個人情報やトークンが写っていないことを確認してからコミットしてください。"
