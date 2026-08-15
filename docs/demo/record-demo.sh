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
# 実行環境: Linux ホスト (Docker デーモン必須)。依存: asciinema, agg, script(1)。
#   asciinema: https://asciinema.org/ (例: pipx install asciinema)
#   agg:       https://github.com/asciinema/agg (cast → GIF 変換)
#   script:    util-linux 同梱 (コンテナへの入力を pty 越しに流すために使う。後述)
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
# agg に書かせる一時ファイル。**成果物のパスへ直接書かせない**: 直接書かせると、agg が
# 終了コード 0 のまま出力に触れなかった場合 (壊れた cast を読み飛ばした等) に、
# 前回のコミット済み GIF がそのまま検査を通り、上書き済みの .cast と食い違ったまま
# 「完了」と報告されてしまう。一時ファイルへ書かせて全部の検査を通ったものだけを
# 置き換えれば、「そこにある = 今回の実行が作った」が構造的に保証される。
# 同じディレクトリに置くのは、置き換えを同一ファイルシステム内の mv (原子的) にするため
GIF_TMP_FILE="${GIF_FILE}.tmp"
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
#
# **消すのは常に「前回の実行の成果物」だけ**: 今回 agg が書いたものは一時ファイル
# (GIF_TMP_FILE) にしか存在せず、全検査を通ったときにだけ成果物のパスへ移す。
# そのため「未コミットのファイルに git restore を案内する」取り違えが起こりえない
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
# 録画には Docker (aidock の実行) と asciinema (録画) と agg (GIF 変換) と
# script (コンテナへの入力を pty 越しに流す。後述の STEPS 内で使う) が要る
require docker "Docker デーモンが動く Linux ホストで実行してください。"
require asciinema "例: pipx install asciinema"
require agg "https://github.com/asciinema/agg の手順で導入してください。"
require script "util-linux (Debian 11+ では bsdextrautils) を導入してください。"

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
    # 作業ディレクトリと一時ファイル (agg の書き出し先を含む) をまとめて消す。
    # **後始末の失敗で終了コードを乗っ取らせない**: この関数は EXIT トラップから呼ばれ、
    # **トラップの本体も `set -e` の対象**なので、非ゼロを返すコマンドがあるとそこで
    # トラップが打ち切られ、その終了コードがスクリプトの終了コードになる
    # (`set -e` が無ければ元の終了コードは保たれる。bash 5.2 で両方を実測して確認)。
    # 素の rm のままだと、成功した録画が「完了」と報告した直後に exit 1 で終わり、
    # `record-demo.sh && git add docs/demo` が黙って成果物を取り込まなくなる
    if ! rm -rf "${DEMO_WORKSPACE}" "${STEPS_FILE}" "${STATUS_FILE}" "${GIF_TMP_FILE}"; then
        # 握り潰さず知らせる (§6)。録画の成否とは無関係なので終了コードは変えない
        log "warning: 一時ファイルの後始末に失敗しました (${DEMO_WORKSPACE} などが残っています)。"
    fi
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

# 降格後に期待するユーザー名。**1 か所に置く**: 比較とエラー文言の両方で使うため、
# 書き写すと片方だけ変えたときに「一致しないのに合格」「合格なのに違う名前を報告」になる
EXPECTED_USER='agent'
# 実際に誰として動いているかを取得する (set -e により whoami 自体の失敗も止まる)
actual_user="$(whoami)"
# 降格確認は**表明**にする: root のままでも表示するだけだと、`gosu agent` の降格が
# 失われた退行 (SEC-7 / AC-3) でも録画は最後まで成功し、`whoami` が root と出ている GIF を
# 「agent へ降格している証拠」として README に貼ってしまう
if [ "${actual_user}" != "${EXPECTED_USER}" ]; then
    echo "ERROR: running as '${actual_user}', expected '${EXPECTED_USER}' -- gosu drop to agent is broken"
    exit 1
fi
# 表明を通ったユーザー名を見せる (画面上の見え方は素の whoami と同じ)
printf '%s\n' "${actual_user}"

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

# 録画に映すプロンプトの体裁。**1 か所に置く**: 2 つのステップが同じ見た目である必要があり、
# 書き写すと片方だけ変えたときに録画内でプロンプトが食い違う (§6 UI 文言は単一の参照元)
PROMPT_FORMAT='\n$ %s\n'

# 打ったコマンドを表示する (実行はしない。ヒアドキュメントを渡す step でも使えるようにするため)
show() {
    # 直前に空行を入れ、プロンプト風に "$ コマンド" を表示する
    # shellcheck disable=SC2059  # 体裁を 1 か所に集約するため書式は変数から与える
    printf "${PROMPT_FORMAT}" "$*"
}

# 打ったコマンドを表示してから実行する (録画に操作が写るようにするため)
run() {
    # まず画面に見せる
    show "$@"
    # 表示した内容をそのまま実行する
    "$@"
}

# リポジトリルートへ移動してイメージをビルドする (パスは環境変数から受け取る)
cd "${AIDOCK_DEMO_REPO_ROOT}"
run ./bin/aidock build
# 個人情報を含まないデモ用ワークスペースへ移動する (ここが /workspace としてマウントされる)
cd "${AIDOCK_DEMO_WORKSPACE}"
# 次に打つコマンドを表示する (aidock shell はヒアドキュメントを渡すので run を使わない)
show "aidock shell  # firewall init -> checks"
# コンテナを起動し、マウントした検査スクリプトを実行させる。
# **標準入力へ流すのはこの 2 行だけ**にする (TTY エコーで録画に写るため ASCII に限る)。
# 末尾の exit は、TTY 付きの対話 bash が標準入力の終端だけでは終わらず、
# aidock shell が返らないまま録画がハングするのを防ぐ
#
# **script(1) の pty 越しに流し込む**: `aidock shell` は `compose run` に行き着き、
# compose は TTY を割り当てる際に**標準入力が端末であること**を要求する。ヒアドキュメントを
# 直接つなぐと標準入力が端末でなくなり、asciinema 配下 (標準出力は pty) でも
# "the input device is not a TTY" で起動自体が失敗する (GitHub Actions ランナーで実測)。
# script が確保した pty を標準入力として与え、ヒアドキュメントは script が pty へ
# 中継することで、対話シェルへ「打った」のと同じ形で届く (TTY エコーで録画にも写る)。
# -e は内側のコマンドの終了コードをそのまま返すために必須 (set -e で失敗を検知するため)。
# -c の文字列内の変数展開は実行時に sh が二重引用符の中で行うので、パスに空白や
# 記号が含まれても安全 (このファイル冒頭の「パスは環境変数で渡す」方針と同じ)。
#
# 先頭の stty -echo は**外側 pty の入力エコーを消す**: これが無いと、ヒアドキュメントの
# 2 行がコンテナ起動前 (compose の Creating 表示より前) にまとめて画面へ流れてしまう。
# 消しても、コンテナ側 tty が受信時に 1 回 (firewall 初期化中の「先行入力」として) と、
# bash プロンプトで readline が 1 回表示するのは残る — これは実端末で先行入力したときと
# 同じ見え方であり許容する (コンテナ内の tty 設定は起動前に外から変えられない)。
#
# 入力は { sleep; cat; } 経由で**少し遅らせて**流す: script は標準入力を pty へ即座に
# 中継するため、直結すると -c の stty -echo が走る前に入力が届いてエコーされてしまう
# (実測で再現)。遅延はこの競合を避けるためだけのもので、負けた場合の影響は
# 「エコーが 1 回余計に写る」という見た目のみ (動作・終了コードには影響しない)
ECHO_OFF_SETTLE_SECONDS=1
{ sleep "${ECHO_OFF_SETTLE_SECONDS}"; cat; } << 'INNER' | script -qec 'stty -echo; "${AIDOCK_DEMO_REPO_ROOT}/bin/aidock" shell' /dev/null
bash /workspace/aidock-demo-checks.sh
exit
INNER
STEPS

log "録画を開始します → ${CAST_FILE}"
# 端末の桁数・行数を固定してから録画する (GIF の寸法を撮影者の環境に依存させない)。
# **判定には標準出力 (fd 1) も含める**: サイズを変えるのは stty (fd 0) だが、asciinema が
# 録画データへ書き込む端末サイズは fd 1 から読む。fd 0 だけ見て分岐すると、
# `./record-demo.sh > run.log` のように標準出力だけリダイレクトした場合に stty は成功する一方、
# 録画は既定の 80x24 で記録され、「固定した」と報告しながら幅が変わってしまう
if [ -t 0 ] && [ -t 1 ]; then
    # 元のサイズを控えてから変更し、EXIT トラップで必ず戻す
    # (戻さないと呼び出し元の端末が 120x30 のままになり、以後の表示が崩れる)
    # 失敗しても止めずに空文字として受け取る (取得できたかどうかは直後に明示的に分岐する)
    ORIGINAL_STTY_SIZE="$(stty size 2> /dev/null || true)"
    # **元のサイズを「復元に使える値」として控えられたときだけ変更する**:
    # 復元できない状態変更をしないため。無条件にリサイズすると、stty size が使える値を
    # 返さない環境で呼び出し元の端末が 120x30 のまま戻らず、しかもリサイズ自体は
    # 成功しているので警告も出ない。
    # **非空かどうかだけを条件にしない**: winsize が未設定の pty (bare openpty など) では
    # stty size が "0 0" を返し、そのまま復元すると `stty rows 0 cols 0` を実行してしまう。
    # 「行 桁」が正の整数 2 つであることまで確かめる (stty size の出力形式そのもの)
    if [[ "${ORIGINAL_STTY_SIZE}" =~ ^([1-9][0-9]*)[[:space:]]+([1-9][0-9]*)$ ]]; then
        # stty size は "行 桁" の順で返すので、その順で取り出して復元に使う
        ORIGINAL_STTY_ROWS="${BASH_REMATCH[1]}"
        ORIGINAL_STTY_COLS="${BASH_REMATCH[2]}"
        # 終了時に元の桁数・行数へ戻す (一時ファイルの後始末もまとめて行う)。
        # **復元を先に置く**: トラップの本体も `set -e` の対象なので、先に置いた後始末が
        # 非ゼロで返るとトラップはそこで打ち切られ、復元に到達しない。
        # 一次の保証は `cleanup` が失敗を返さないこと (下の cleanup() を参照。
        # そこが崩れると終了コードも乗っ取られるため、テストが exit 0 を表明している) で、
        # この順序はそれが将来崩れたときに端末だけは戻すための二重の備え
        # 復元に失敗したら知らせる (§6)。**トラップ自体は失敗させない**: log は 0 を返すので
        # 終了コードを乗っ取らず、後続の cleanup にも到達する。黙って握り潰すと、
        # 呼び出し元の端末が 120x30 のまま戻らないのに何の手掛かりも残らない
        trap 'stty rows "${ORIGINAL_STTY_ROWS}" cols "${ORIGINAL_STTY_COLS}" 2> /dev/null || log "warning: 端末サイズを ${ORIGINAL_STTY_ROWS}x${ORIGINAL_STTY_COLS} へ戻せませんでした。stty size で確認してください。"; cleanup' EXIT
        # 録画用のサイズへ変更する (失敗したら理由を伝える。黙って無視しない)
        if ! stty cols "${RECORD_COLS}" rows "${RECORD_ROWS}" 2> /dev/null; then
            log "warning: 端末サイズを ${RECORD_COLS}x${RECORD_ROWS} に固定できませんでした。GIF の幅が環境依存になります。"
        fi
    else
        # 取得できなかったこと自体を握り潰さない (§6)。戻せないので変更もしない
        log "warning: 現在の端末サイズを復元できる形で取得できないため端末サイズを固定しません (元に戻せない変更はしません)。GIF の幅が環境依存になります。"
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
# **agg を呼ぶ前に一時ファイルを消す**: 名前が固定なので、前回の実行が途中で殺された
# (SIGKILL / OOM) 場合や後始末に失敗した場合に中身が残りうる。消さずに走らせると、
# agg が 0 で終わりながら出力に触れなかったときに**その残骸が全検査を通って成果物になる** —
# 一時ファイル化で無くしたはずの「古い GIF が新しい .cast と対になる」状態が復活する
# **この rm も失敗しうる**: 同じパスにディレクトリが残っている / docs/demo が EACCES など。
# 素で書くと set -e がここでスクリプトを終わらせ、他の失敗経路と違って
# 前回の GIF を残したまま (= 上書き済みの .cast と対のまま) 止まってしまう
if ! rm -f "${GIF_TMP_FILE}"; then
    log "error: 変換用の一時ファイル ${GIF_TMP_FILE} を消せませんでした。"
    log "       同じ名前のディレクトリが残っていないか、書き込み権限があるかを確認してください。"
    discard_stale_gif
    exit 1
fi
if ! agg --font-size 16 "${CAST_FILE}" "${GIF_TMP_FILE}"; then
    log "error: GIF への変換に失敗しました。"
    discard_stale_gif
    exit 1
fi

# GIF の上限 (CLAUDE.md §15) を超えていたら警告する。
# **文言の閾値も定数から組み立てる**: ここに 10MB と直書きすると、GIF_MAX_BYTES を
# 変えたときにメッセージだけが古い値を主張する (§6 単一の参照元)
# **中身が GIF であることを先に確かめる**: agg が 0 で終わりながら空ファイルや
# 壊れた出力を残すことがある (書き込み中断・ディスク不足など)。上限だけを見ていると
# 0 バイトは «上限以下» として素通りし、README に死んだサムネイルが貼られてしまう
if [ ! -s "${GIF_TMP_FILE}" ]; then
    log "error: 生成された GIF が空です。agg の出力を確認してください。"
    discard_stale_gif
    exit 1
fi
# GIF のシグネチャ (GIF87a / GIF89a の先頭 4 バイト) を確認する
if [ "$(head -c 4 "${GIF_TMP_FILE}")" != "GIF8" ]; then
    log "error: 生成されたファイルが GIF ではありません。agg の出力を確認してください。"
    discard_stale_gif
    exit 1
fi
# サイズの取得も**素で書かない**: 他の検査 (rm / agg / mv) と同じく失敗しうるのに、
# 素の代入だと `set -e` がここでスクリプトを終わらせ、後始末に到達しないまま
# **前回の GIF が上書き済みの .cast と対のまま残る** (他のどの失敗経路とも違う振る舞いになる)
if ! GIF_SIZE="$(stat -c %s "${GIF_TMP_FILE}")"; then
    log "error: 生成した GIF のサイズを取得できませんでした (${GIF_TMP_FILE})。"
    discard_stale_gif
    exit 1
fi
if [ "${GIF_SIZE}" -gt "${GIF_MAX_BYTES}" ]; then
    # **警告で済ませない**: 他の不備 (agg の失敗・ステップの失敗) では GIF を消しているのに
    # ここだけ残すと、`record-demo.sh && git add docs/demo` で上限超過の GIF がそのまま
    # コミットされる。基準を満たさない成果物は置いていかない (§15 / fail-closed)
    log "error: GIF が上限 $((GIF_MAX_BYTES / 1024 / 1024))MB を超えています (${GIF_SIZE} bytes)。"
    log "       --idle-time-limit や解像度を調整して録り直してください。"
    discard_stale_gif
    exit 1
fi

# ここまで通ったものだけを成果物の位置へ移す。**移動を最後に置く**ことで、
# 「${GIF_FILE} が存在する = 全検査を通った今回の GIF」という不変条件が保たれる
if ! mv "${GIF_TMP_FILE}" "${GIF_FILE}"; then
    log "error: 生成した GIF を ${GIF_FILE} へ移動できませんでした。"
    # ここも .cast を上書きした後の失敗なので、他の失敗経路と同じく前回の GIF を残さない
    # (残すと、新しい .cast と古い .gif が並んだままコミットされうる)
    discard_stale_gif
    exit 1
fi

# 生成できたことと、コミット前の目視確認を促す
log "完了: ${CAST_FILE} と ${GIF_FILE} を生成しました。"
log "内容を目視確認し、個人情報やトークンが写っていないことを確認してからコミットしてください。"
