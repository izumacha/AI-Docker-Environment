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

# 録画に失敗したとき、前回の実行で作られた GIF を消す。
# **消さないと .cast と .gif が食い違う**: .cast は --overwrite で失敗時の内容に
# 置き換わる一方、GIF は前回成功時のものが残るため、`git status` には .cast だけが
# 変更として現れ、無関係な GIF と一緒にコミットされてしまう
discard_stale_gif() {
    # 前回の GIF が残っていれば削除し、消したことを明示する (git restore で戻せる)
    if [ -f "${GIF_FILE}" ]; then
        rm -f "${GIF_FILE}"
        log "       前回の ${GIF_FILE} は .cast と食い違うため削除しました (git restore で復元できます)。"
    fi
}

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
# 失敗したらそこで止める (デモは「壊れていないこと」の証拠なので握り潰さない)
set -e
# /workspace にホスト側のデモ用ディレクトリがマウントされていることを見せる
ls -la
# root ではなく agent へ降格していることを見せる
whoami
# 遮断確認: 許可外ホストへ**到達できてしまったら** default-deny の退行なので失敗させる。
# `|| echo` だけで受け流すと、firewall が壊れていても «blocked» 行が出ないまま
# 成功扱いになり、壊れたサンドボックスを「安全」と宣伝する GIF ができてしまう
if curl -sS --max-time 5 https://example.com > /dev/null 2>&1; then
    echo 'ERROR: example.com is REACHABLE -- default-deny egress is broken'
    exit 1
fi
echo '=> example.com blocked (default-deny)'
# 到達確認: 許可ホストへ到達できなければ許可リスト/DNS の退行なので失敗させる。
# curl の終了コードを直接見る (`curl | head` にすると head の 0 が curl の失敗を覆い隠す)
if ! anthropic_head="$(curl -sSI --max-time 10 https://api.anthropic.com)"; then
    echo 'ERROR: api.anthropic.com is UNREACHABLE -- allowlist/DNS regression'
    exit 1
fi
# 応答のステータス行だけを見せる
printf '%s\n' "${anthropic_head}" | head -n 1
# 対話 bash は標準入力の終端だけでは終わらないことがあるため明示的に抜ける
exit
INNER
STEPS

log "録画を開始します → ${CAST_FILE}"
# 端末の桁数・行数を固定してから録画する (GIF の寸法を撮影者の環境に依存させない)。
# **判定は標準入力 (fd 0) で行う**: stty が読み書きするのは fd 0 なので、fd 1 を見て
# 分岐すると「標準出力だけ端末」の状況 (make / nohup 経由など) で stty が黙って失敗し、
# 固定したはずのサイズが効かないまま録画されてしまう
if [ -t 0 ]; then
    # 元のサイズを控えてから変更し、EXIT トラップで必ず戻す
    # (戻さないと呼び出し元の端末が 120x30 のままになり、以後の表示が崩れる)
    ORIGINAL_STTY_SIZE="$(stty size 2> /dev/null || true)"
    if [ -n "${ORIGINAL_STTY_SIZE}" ]; then
        # stty size は "行 桁" の順で返すので、そのまま rows/cols へ割り当てて復元する
        trap 'rm -rf "${DEMO_WORKSPACE}" "${STEPS_FILE}" "${STATUS_FILE}"; stty rows ${ORIGINAL_STTY_SIZE% *} cols ${ORIGINAL_STTY_SIZE#* } 2> /dev/null || true' EXIT
    fi
    # 録画用のサイズへ変更する (失敗したら理由を伝える。黙って無視しない)
    if ! stty cols "${RECORD_COLS}" rows "${RECORD_ROWS}" 2> /dev/null; then
        log "warning: 端末サイズを ${RECORD_COLS}x${RECORD_ROWS} に固定できませんでした。GIF の幅が環境依存になります。"
    fi
else
    # 端末が無ければサイズを固定できないので、幅が環境依存になることを伝える
    log "warning: 標準入力が端末ではないため端末サイズを固定できません。GIF の幅が環境依存になります。"
fi
# --idle-time-limit でビルド待ちなどの無操作時間を 2 秒に圧縮する。
# **asciinema rec は録画対象コマンドの終了コードを引き継がない**ため、`set -e` では
# 失敗を検知できない。ステップ側の終了コードをファイルへ書き出し、録画後に読んで判定する
# --command は asciinema が**利用者のログインシェル**で解釈するため、`bash -c` を明示して
# POSIX 互換でないシェル (fish / csh 等) でも `$?` の書き出しが確実に走るようにする
asciinema rec --overwrite --idle-time-limit 2 \
    --command "bash -c \"bash '${STEPS_FILE}'; echo \\\$? > '${STATUS_FILE}'\"" \
    "${CAST_FILE}"

# 録画対象コマンドの終了コードを読む (書かれていなければ失敗扱いにする = fail-closed)。
# mktemp が空ファイルを先に作るので、「空」= echo まで到達しなかった、と判別できる
STEPS_STATUS="$(cat "${STATUS_FILE}" 2> /dev/null || true)"
if [ -z "${STEPS_STATUS}" ]; then
    # ステップ本体ではなく、録画コマンドの起動自体が失敗した可能性が高いケース
    log "error: 録画対象のコマンドの終了コードを取得できませんでした。"
    log "       asciinema が --command を起動できたか (シェルの互換性・PATH) を確認してください。"
    discard_stale_gif
    exit 1
fi
if [ "${STEPS_STATUS}" != "0" ]; then
    log "error: 録画対象のコマンドが失敗しました (exit ${STEPS_STATUS})。"
    log "       ${CAST_FILE} に失敗時の出力が残っているので原因を確認してください。"
    log "       GIF は生成しません (壊れた録画を README に貼らないため)。"
    discard_stale_gif
    exit 1
fi

log "GIF へ変換します → ${GIF_FILE}"
# 録画中の文字列はすべて ASCII に揃えてある。agg の既定フォント (JetBrains Mono 等) は
# 日本語グリフを持たず、CJK を含めると豆腐 (□) になって最重要の一行が読めなくなるため
agg --font-size 16 "${CAST_FILE}" "${GIF_FILE}"

# GIF の上限 (CLAUDE.md §15) を超えていたら警告する。
# **文言の閾値も定数から組み立てる**: ここに 10MB と直書きすると、GIF_MAX_BYTES を
# 変えたときにメッセージだけが古い値を主張する (§6 単一の参照元)
GIF_SIZE="$(stat -c %s "${GIF_FILE}")"
if [ "${GIF_SIZE}" -gt "${GIF_MAX_BYTES}" ]; then
    log "warning: GIF が上限 $((GIF_MAX_BYTES / 1024 / 1024))MB を超えています (${GIF_SIZE} bytes)。"
    log "         このままコミットせず、--idle-time-limit や解像度を調整して録り直してください。"
fi

# 生成できたことと、コミット前の目視確認を促す
log "完了: ${CAST_FILE} と ${GIF_FILE} を生成しました。"
log "内容を目視確認し、個人情報やトークンが写っていないことを確認してからコミットしてください。"
