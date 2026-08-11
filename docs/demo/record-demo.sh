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
# 一時ファイル類の後始末。**1 か所にまとめる**: trap を 2 度張る (端末サイズを戻す版とそうでない版)
# ので、削除対象をそれぞれに書き写すと、後で足した一時ファイルが片方だけ消し忘れられる
cleanup() {
    # 作業ディレクトリと一時ファイルをまとめて消す
    rm -rf "${DEMO_WORKSPACE}" "${STEPS_FILE}" "${STATUS_FILE}"
}
# スクリプト終了時に必ず片付ける (端末サイズを変えた場合は後段でトラップを張り直す)
trap cleanup EXIT
# ワークスペースがマウントされていることを録画中に見せるためのダミーファイル
printf '# aidock demo sample project\n' > "${DEMO_WORKSPACE}/README.md"

# コンテナ内で走らせる検査本体を、**マウントされるワークスペースへファイルとして置く**。
#
# **なぜ標準入力へ直接流し込まないか**: `aidock shell` は `compose run` を経由し、
# compose は標準出力が端末かどうかで TTY 割り当てを決める (`-T` の既定値。実測: 標準出力が
# pty なら TTY あり)。asciinema 配下では標準出力が pty なのでコンテナには TTY が付き、
# **端末のライン discipline が流し込んだ入力をそのまま画面へエコーする**。
# つまりヒアドキュメントに書いた内容は 1 行残らず録画に写る。ここに日本語コメントを書くと、
# CJK グリフを持たない agg の既定フォントでは豆腐 (□) の列になってしまう。
# ファイルへ逃がせば、標準入力に流れるのは下の ASCII 2 行だけになる。
CHECKS_FILE="${DEMO_WORKSPACE}/aidock-demo-checks.sh"
# ヒアドキュメントの区切りをクォートし、書き出す時点では何も展開しない
cat > "${CHECKS_FILE}" << 'CHECKS'
# 未定義変数とパイプ途中の失敗も検出する (デモは「壊れていないこと」の証拠なので握り潰さない)
set -euo pipefail

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
CHECKS

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

cat > "${STEPS_FILE}" << 'STEPS'
# 未定義変数も失敗扱いにする。**bash <file> は新しいシェルなので外側の set は継がれない** —
# ここで -u を付けないと、環境変数が渡らなかったときに `cd ""` が黙って成功し (bash では
# 何もせず 0 を返す)、まったく別のディレクトリでビルドした映像を録ってしまう
set -euo pipefail

# 打ったコマンドを表示してから実行する (録画に操作が写るようにするため)
run() {
    # 直前に空行を入れ、プロンプト風に "$ コマンド" を表示する
    printf '\n$ %s\n' "$*"
    # 表示した内容をそのまま実行する
    "$@"
}

# リポジトリルートへ移動してイメージをビルドする (パスは環境変数から受け取る)
cd "${AIDOCK_DEMO_REPO_ROOT}"
run ./bin/aidock build
# 個人情報を含まないデモ用ワークスペースへ移動する (ここが /workspace としてマウントされる)
cd "${AIDOCK_DEMO_WORKSPACE}"
# 次に打つコマンドを表示する (aidock shell はヒアドキュメントを渡すので run を使わない)
printf '\n$ %s\n' "aidock shell  # firewall init -> checks"
# コンテナを起動し、マウントした検査スクリプトを実行させる。
# **標準入力へ流すのはこの 2 行だけ**にする (TTY エコーで録画に写るため ASCII に限る)。
# 末尾の exit は、TTY 付きの対話 bash が標準入力の終端だけでは終わらず、
# aidock shell が返らないまま録画がハングするのを防ぐ
"${AIDOCK_DEMO_REPO_ROOT}/bin/aidock" shell << 'INNER'
bash /workspace/aidock-demo-checks.sh
exit
INNER
STEPS

log "録画を開始します → ${CAST_FILE}"
# 端末の桁数・行数を固定してから録画する (GIF の寸法を撮影者の環境に依存させない)。
# **判定は標準入力 (fd 0) で行う**: stty が読み書きするのは fd 0 なので、fd 1 を見て
# 分岐すると「標準出力だけ端末」の状況 (make / nohup 経由など) で stty が黙って失敗し、
# 固定したはずのサイズが効かないまま録画されてしまう
# **判定には標準出力 (fd 1) も含める**: サイズを変えるのは stty (fd 0) だが、asciinema が
# 録画データへ書き込む端末サイズは fd 1 から読む。fd 0 だけ見て分岐すると、
# `./record-demo.sh > run.log` のように標準出力だけリダイレクトした場合に stty は成功する一方、
# 録画は既定の 80x24 で記録され、「固定した」と報告しながら幅が変わってしまう
if [ -t 0 ] && [ -t 1 ]; then
    # 元のサイズを控えてから変更し、EXIT トラップで必ず戻す
    # (戻さないと呼び出し元の端末が 120x30 のままになり、以後の表示が崩れる)
    ORIGINAL_STTY_SIZE="$(stty size 2> /dev/null || true)"
    if [ -n "${ORIGINAL_STTY_SIZE}" ]; then
        # stty size は "行 桁" の順で返すので、そのまま rows/cols へ割り当てて復元する
        trap 'cleanup; stty rows ${ORIGINAL_STTY_SIZE% *} cols ${ORIGINAL_STTY_SIZE#* } 2> /dev/null || true' EXIT
    fi
    # 録画用のサイズへ変更する (失敗したら理由を伝える。黙って無視しない)
    if ! stty cols "${RECORD_COLS}" rows "${RECORD_ROWS}" 2> /dev/null; then
        log "warning: 端末サイズを ${RECORD_COLS}x${RECORD_ROWS} に固定できませんでした。GIF の幅が環境依存になります。"
    fi
else
    # どちらかが端末でなければサイズを固定できないので、幅が環境依存になることを伝える
    log "warning: 標準入力または標準出力が端末ではないため端末サイズを固定できません。GIF の幅が環境依存になります。"
fi
# --idle-time-limit でビルド待ちなどの無操作時間を 2 秒に圧縮する。
# **asciinema rec は録画対象コマンドの終了コードを引き継がない**ため、`set -e` では
# 失敗を検知できない。ステップ側の終了コードをファイルへ書き出し、録画後に読んで判定する
# --command は asciinema が**利用者のログインシェル**で解釈するため、`bash -c` を明示して
# POSIX 互換でないシェル (fish / csh 等) でも `$?` の書き出しが確実に走るようにする
# **`|| { ... }` で受ける**: `set -e` のまま asciinema 自体が失敗 (Ctrl-C・起動失敗など) すると
# ここでスクリプトが即終了し、後段の後始末に到達しない。--overwrite で .cast は既に
# 上書きされているため、古い .gif だけが残って両者が食い違う
if ! asciinema rec --overwrite --idle-time-limit 2 \
    --command "bash -c \"bash '${STEPS_FILE}'; echo \\\$? > '${STATUS_FILE}'\"" \
    "${CAST_FILE}"; then
    log "error: asciinema による録画自体が失敗しました (中断・起動失敗など)。"
    discard_stale_gif
    exit 1
fi

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
# agg も `|| { ... }` で受ける: 途中で失敗すると書きかけの GIF がそのまま残り、
# 一見もっともらしい .cast と並んでコミットされてしまう
if ! agg --font-size 16 "${CAST_FILE}" "${GIF_FILE}"; then
    log "error: GIF への変換に失敗しました。"
    discard_stale_gif
    exit 1
fi

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
