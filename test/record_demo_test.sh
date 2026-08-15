#!/usr/bin/env bash
# record_demo_test.sh - unit tests for docs/demo/record-demo.sh's fail-closed
# recording contract.
#
# Why this exists: record-demo.sh promises two things that are easy to break
# silently. First, it must never leave a GIF behind for a run that failed --
# `asciinema rec` does not propagate the recorded command's exit status, so the
# script reads it back through a status file, and a regression that drops that
# plumbing (or reverts to relying on `set -e` after asciinema) would once again
# report "完了" for a broken recording. docs/requirements.md's revision history
# records that this script already shipped that exact fail-open once. Second,
# the three checks inside the recording are assertions, not decoration: a
# reachable example.com (default-deny egress broken), an unreachable
# api.anthropic.com (allowlist/DNS regression), or a `whoami` that is not
# `agent` (the gosu drop is gone -- SEC-7 / AC-3) must abort the run rather
# than produce a GIF that advertises a sandbox which no longer isolates
# anything.
#
# Neither property is covered by CI today: the type-check job only lints the
# script with shellcheck and `bash -n`, which is precisely the "absence ==
# pass" shape this repository has been bitten by before (see the action-pin
# entries in docs/requirements.md).
#
# Hermetic: no Docker, no asciinema, no agg, no network. Everything the script
# shells out to is replaced by a PATH stub, and `bin/aidock` is replaced by a
# stub whose container-side behaviour is switchable per test case, mirroring
# how test/guard_test.sh stubs docker/getent and test/entrypoint_test.sh stubs
# gosu.
#
# Prerequisite beyond coreutils: `script(1)` (util-linux; packaged as
# bsdextrautils on Debian 11+, present on ubuntu-latest). The terminal-size
# branches live behind `[ -t 0 ] && [ -t 1 ]`, so they need a real pty to be
# reachable at all. A missing `script` is reported as a FAIL rather than
# skipped -- a silent skip would restore exactly the "absence == pass" hole
# those cases exist to close.

# エラー発生時に即座に停止し、未定義変数の参照もエラーにする（安全なスクリプト実行の基本設定）
set -euo pipefail

# このスクリプト自身が置かれているディレクトリの絶対パスを取得する
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# リポジトリのルートディレクトリ（SCRIPT_DIR の一つ上）を絶対パスで求める
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
# テスト対象となる録画スクリプトのパス
RECORD_SCRIPT="${REPO_ROOT}/docs/demo/record-demo.sh"

# テスト全体で使う一時ディレクトリ（スタブと擬似リポジトリを置く）
TEST_TMP="$(mktemp -d)"
# テスト終了時に一時ディレクトリを必ず片付ける
trap 'rm -rf "${TEST_TMP}"' EXIT

# 共有のカウンタ・アサーション群（4 本目の書き写しを増やさないため lib へ切り出した）
# shellcheck source=test/lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

# --- スタブの用意 -------------------------------------------------------------

# スタブを置くディレクトリ（PATH の先頭に差し込む）
STUB_BIN="${TEST_TMP}/stub-bin"
mkdir -p "${STUB_BIN}"

# docker スタブ: 依存チェック（docker info）だけを満たす。実際のコンテナは起動しない
cat > "${STUB_BIN}/docker" << 'STUB'
#!/usr/bin/env bash
# デーモンが止まっているケースを模す（CLI はあるが info が失敗する）
if [[ "${AIDOCK_TEST_MODE:-ok}" == "nodaemon" ]]; then
    echo "Cannot connect to the Docker daemon" >&2
    exit 1
fi
# 通常は「デーモンに到達できた」ことにして成功で返す
exit 0
STUB

# agg スタブ: cast を読んだことにして、それらしい GIF を書き出す
cat > "${STUB_BIN}/agg" << 'STUB'
#!/usr/bin/env bash
# 最後の引数が出力先の GIF
out="${!#}"
# 変換が途中で失敗するケースを模す（書きかけの GIF を残して非ゼロで終わる）
if [[ "${AIDOCK_TEST_MODE:-ok}" == "aggfail" ]]; then
    printf 'partial' > "${out}"
    exit 1
fi
# 0 で終わりながら空ファイルを残すケースを模す（書き込み中断・ディスク不足など）
if [[ "${AIDOCK_TEST_MODE:-ok}" == "emptygif" ]]; then
    : > "${out}"
    exit 0
fi
# 0 で終わりながら GIF でない中身を残すケースを模す
if [[ "${AIDOCK_TEST_MODE:-ok}" == "notagif" ]]; then
    printf 'not-a-gif' > "${out}"
    exit 0
fi
# 上限超過の GIF を作るケースを模す（sparse file なので一瞬で作れる）
if [[ "${AIDOCK_TEST_MODE:-ok}" == "biggif" ]]; then
    # 本物と同じシグネチャで始め、sparse file で上限超過のサイズにする
    printf 'GIF89a' > "${out}"
    truncate -s 11M "${out}"
    exit 0
fi
# 0 で終わりながら**出力に一切触れない**ケースを模す（壊れた cast を読み飛ばした等）。
# 出力先へ直接書かせていると、前回のコミット済み GIF がそのまま検査を通ってしまう
if [[ "${AIDOCK_TEST_MODE:-ok}" == "aggnowrite" ]]; then
    exit 0
fi
# 通常はそれらしいダミー内容を書く
printf 'GIF89a-stub' > "${out}"
STUB

# asciinema スタブ: 本物と同じく **録画対象コマンドの終了コードを引き継がない**。
# --command の中身をシェルで実行し、cast ファイルを上書きしてから必ず 0 で終わる
cat > "${STUB_BIN}/asciinema" << 'STUB'
#!/usr/bin/env bash
# --command の値と出力先 cast のパスを取り出す
command_to_run=""
cast_path=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --command)
            command_to_run="$2"
            shift 2
            ;;
        --overwrite | --idle-time-limit)
            # --idle-time-limit は値を伴うので、数値が続く場合だけ読み飛ばす
            if [[ "$1" == "--idle-time-limit" ]]; then shift; fi
            shift
            ;;
        *)
            cast_path="$1"
            shift
            ;;
    esac
done
# --overwrite 相当: 実行前に cast を置き換える（本物も先に truncate する）
printf 'cast-stub\n' > "${cast_path}"
# asciinema 自体が失敗するケース（Ctrl-C・起動失敗など）を模す
if [[ "${AIDOCK_TEST_MODE:-ok}" == "asciinemafail" ]]; then
    exit 130
fi
# 録画対象コマンドを起動しないケース（非 POSIX シェル等で状態ファイルが書かれない）を模す
if [[ "${AIDOCK_TEST_MODE:-ok}" == "nostatus" ]]; then
    exit 0
fi
# 本物と同様、録画対象は利用者のシェル経由で起動する
sh -c "${command_to_run}" || true
# 録画対象が失敗しても asciinema 自体は成功で返る（この挙動の再現がテストの肝）
exit 0
STUB

# stty スタブ: 端末サイズの取得・変更を横取りし、テスト側から観測できるようにする。
# 本物を使うと「現在のサイズ」を選べず、winsize 未設定の pty（"0 0" を返す）を再現できない
cat > "${STUB_BIN}/stty" << 'STUB'
#!/usr/bin/env bash
# サイズ取得の呼び出し（stty size）には、テストが指定した「現在のサイズ」を返す
if [[ "${1:-}" == "size" ]]; then
    # 空を指定されたときは何も出さない（stty size が値を返さない環境を模す）
    if [[ -n "${AIDOCK_TEST_STTY_SIZE:-}" ]]; then
        printf '%s\n' "${AIDOCK_TEST_STTY_SIZE}"
    fi
    exit 0
fi
# サイズ以外のモード変更（STEPS 内の `stty -echo` = 録画用 scratch pty のエコー制御）は
# リサイズ検証の対象外なので、記録も失敗シミュレーションもせず成功させる。
# 固定は "cols …"、復元は "rows …" で始まるため、先頭語がどちらでもなければサイズ変更ではない
if [[ "${1:-}" != "rows" && "${1:-}" != "cols" ]]; then
    exit 0
fi
# サイズ変更（固定・復元）の呼び出しは、引数をそのまま記録に残す。
# 記録先が渡されていない実行（端末を持たない既存ケース）では捨てる
printf '%s\n' "$*" >> "${AIDOCK_TEST_STTY_CAPTURE:-/dev/null}"
# サイズ変更が拒否される環境（ioctl を通さないコンテナ・多重化端末など）を模す。
# 記録は先に残す: 「試したが失敗した」ことと「試していない」ことを取り違えないため
if [[ "${AIDOCK_TEST_STTY_RESIZE_FAILS:-}" == "fail" ]]; then
    exit 1
fi
# 復元だけが拒否される状況（録画中に多重化端末を切り離した等）を模す。
# 固定は "cols … rows …"、復元は "rows … cols …" の順で呼ばれるので先頭語で見分ける
if [[ "${AIDOCK_TEST_STTY_RESIZE_FAILS:-}" == "failrestore" && "${1:-}" == "rows" ]]; then
    exit 1
fi
exit 0
STUB

# 本物の rm / mv / stat の場所を、PATH をスタブで汚す前に控えておく（スタブから委譲するため）
REAL_RM="$(command -v rm)"
REAL_MV="$(command -v mv)"
REAL_STAT="$(command -v stat)"

# stat スタブ: 生成した GIF のサイズ取得だけを失敗させられるようにする。
# サイズ取得は他の検査（rm / agg / mv）と同じく失敗しうるのに素の代入で書かれていると、
# `set -e` がその場でスクリプトを終わらせ、**前回の GIF が上書き済みの .cast と対のまま残る**
cat > "${STUB_BIN}/stat" << STUB
#!/usr/bin/env bash
# 生成した GIF のサイズを問い合わせたときだけ失敗を返す
if [[ "\${AIDOCK_TEST_MODE:-ok}" == "statfail" && "\$*" == *"aidock-demo.gif.tmp" ]]; then
    exit 1
fi
# それ以外は本物の stat にそのまま任せる
exec "${REAL_STAT}" "\$@"
STUB

# mv スタブ: 成果物への移動だけを失敗させられるようにする。
# 移動が失敗する状況（docs/demo が読み取り専用・EACCES 等）でも、上書き済みの .cast と
# 古い .gif が並んだまま残らないことを見るため
cat > "${STUB_BIN}/mv" << STUB
#!/usr/bin/env bash
# 成果物への移動を試みたときだけ失敗を返す
if [[ "\${AIDOCK_TEST_MODE:-ok}" == "mvfail" && "\$*" == *"aidock-demo.gif" ]]; then
    exit 1
fi
# それ以外は本物の mv にそのまま任せる
exec "${REAL_MV}" "\$@"
STUB

# rm スタブ: 既定では本物へそのまま委譲し、cleanupfail モードのときだけ
# **作業ディレクトリの削除だけ**を失敗させる。EXIT トラップ内で cleanup が非ゼロを返す
# 状況（rm -rf が EACCES 等）を作り、それでも端末サイズの復元に到達することを見るため
cat > "${STUB_BIN}/rm" << STUB
#!/usr/bin/env bash
# デモ用の作業ディレクトリを消そうとしたときだけ失敗を返す
if [[ "\${AIDOCK_TEST_MODE:-ok}" == "cleanupfail" && "\$*" == *"aidock-demo-workspace"* ]]; then
    # **消したうえで**失敗を返す: 後始末の失敗だけを模したいので、
    # スタブ自身が /tmp に一時ファイルを積み残さないようにする
    "${REAL_RM}" "\$@" || true
    exit 1
fi
# それ以外は本物の rm にそのまま任せる
exec "${REAL_RM}" "\$@"
STUB

# 実行権限を与える
chmod +x "${STUB_BIN}/docker" "${STUB_BIN}/agg" "${STUB_BIN}/asciinema" "${STUB_BIN}/stty" "${STUB_BIN}/rm" "${STUB_BIN}/mv" "${STUB_BIN}/stat"

# --- 擬似リポジトリの用意 -----------------------------------------------------

# 録画スクリプトはスクリプト自身の位置からリポジトリルートを求めるので、同じ構造を作る。
# パスにシングルクォートと $ を含めて、引用符の扱いの回帰も同時に見る
FAKE_REPO="${TEST_TMP}/it's-\$repo"
mkdir -p "${FAKE_REPO}/docs/demo" "${FAKE_REPO}/bin"
# テスト対象のスクリプトを擬似リポジトリへ複製する
cp "${RECORD_SCRIPT}" "${FAKE_REPO}/docs/demo/record-demo.sh"
# 生成物の置き場所（アサーションで使う）
FAKE_GIF="${FAKE_REPO}/docs/demo/aidock-demo.gif"
# agg に書かせる一時ファイル。**どの経路でも残してはいけない**:
# 残ると `git add docs/demo` で中途半端な出力がそのままコミットされうる
FAKE_GIF_TMP="${FAKE_GIF}.tmp"

# bin/aidock スタブを書き出す。AIDOCK_TEST_MODE でコンテナ内の挙動を切り替える:
#   ok        … 遮断されており許可ホストへ到達できる（正常なサンドボックス）
#   leaky     … 許可外ホストへ到達できてしまう（default-deny の退行）
#   blocked   … 許可ホストへ到達できない（許可リスト / DNS の退行）
#   rootuser  … agent へ降格できていない（gosu 降格の退行 / SEC-7・AC-3）
#   buildfail … build が失敗する
#   cleanupfail … 一時ファイルの後始末（rm -rf）が失敗する（コンテナ内の挙動は ok と同じ）
#   mvfail    … 生成した GIF を成果物の位置へ移動できない（コンテナ内の挙動は ok と同じ）
#   statfail  … 生成した GIF のサイズを取得できない（コンテナ内の挙動は ok と同じ）
cat > "${FAKE_REPO}/bin/aidock" << 'STUB'
#!/usr/bin/env bash
set -uo pipefail
# build サブコマンド: テストモードに応じて成功／失敗を返す
if [[ "${1:-}" == "build" ]]; then
    if [[ "${AIDOCK_TEST_MODE:-ok}" == "buildfail" ]]; then
        echo "build failed (stub)" >&2
        exit 5
    fi
    echo "aidock stub: build"
    exit 0
fi
# shell サブコマンド: 標準入力に流れてくるコマンドを読み、検査スクリプトを実行する
if [[ "${1:-}" == "shell" ]]; then
    # 起動時のカレントディレクトリを保存する。実機ではここが /workspace として
    # bind mount されるので、**デモ用の一時ディレクトリでなければ操作者の実パスが録画に写る**
    pwd > "${AIDOCK_TEST_PWD_CAPTURE}"
    # 標準入力に流れてきた内容を保存する（テスト側が中身と文字集合を検証するため）。
    # 実機ではここが TTY にエコーされて録画へ写るので、ASCII だけであることが重要
    cat > "${AIDOCK_TEST_STDIN_CAPTURE}"
    # マウント相当: ワークスペースに置かれた検査スクリプトを、コンテナ側の挙動を
    # 決める 2 つのコマンド（curl / whoami）だけ差し替えて実行する
    checks="${AIDOCK_DEMO_WORKSPACE}/aidock-demo-checks.sh"
    # スタブを置くディレクトリを作る
    stub_dir="$(mktemp -d)"
    cat > "${stub_dir}/curl" << 'CURL'
#!/usr/bin/env bash
# 引数の中に example.com が含まれるかで、どちらの確認かを判別する
for arg in "$@"; do
    case "${arg}" in
        *example.com*)
            # leaky モードでは「到達できてしまう」= 成功を返す
            if [[ "${AIDOCK_TEST_MODE:-ok}" == "leaky" ]]; then exit 0; fi
            exit 7
            ;;
        *api.anthropic.com*)
            # blocked モードでは「到達できない」= 失敗を返す
            if [[ "${AIDOCK_TEST_MODE:-ok}" == "blocked" ]]; then exit 7; fi
            # **本物の curl -I と同じ CRLF 区切りの複数行ヘッダを返す**: 検査側は
            # ステータス行だけを取り出して行末の CR を落とすので、LF 1 行だけを返す
            # スタブだとその処理が働かなくても緑のままになり、CR が録画に残る退行
            # （端末が行頭へ戻り、続く文字が上書きされて読めなくなる）を見逃す
            printf 'HTTP/2 200 \r\ndate: Thu, 01 Jan 2026 00:00:00 GMT\r\ncontent-type: application/json\r\n\r\n'
            exit 0
            ;;
    esac
done
exit 0
CURL
    # whoami スタブ: コンテナ内のユーザーを模す。**本物を使えない**理由は、
    # このテスト自身が root で走る環境（CI のコンテナなど）だと本物の whoami が
    # 常に root を返し、正常系まで降格の退行として落ちてしまうため
    cat > "${stub_dir}/whoami" << 'WHOAMI'
#!/usr/bin/env bash
# rootuser モードでは gosu 降格が失われた状態を模して root を返す
if [[ "${AIDOCK_TEST_MODE:-ok}" == "rootuser" ]]; then
    echo 'root'
    exit 0
fi
# 通常は降格後の agent を返す
echo 'agent'
WHOAMI
    chmod +x "${stub_dir}/curl" "${stub_dir}/whoami"
    # ls は本物を使い、curl / whoami だけスタブを優先させる。
    # **出力はバイト列のまま控えを取る**（tee で画面へも流すので録画側の見え方は変わらない）:
    # テスト本体が見る LAST_OUTPUT は pty 実行との比較を揃えるため CR を全部落としており、
    # 「CR が残っている」という退行だけはそこからは絶対に検出できない。控えを取らずに
    # LAST_OUTPUT へ assert を書くと、CR を落とす処理を消しても緑のままの偽合格になる
    PATH="${stub_dir}:${PATH}" bash "${checks}" | tee "${AIDOCK_TEST_CHECKS_CAPTURE}"
    # **検査本体の終了コードを名指しで取り出す**。このスタブは pipefail を有効にしているので
    # 素の `$?` でも今は同じ値になるが、それは「tee が 0 を返す一方 pipefail が非ゼロを
    # 拾い上げる」という離れた設定への暗黙の依存になる。default-deny 退行の検知が
    # そこに乗ると、pipefail を外した瞬間に失敗が握り潰されても誰も気付けない
    status="${PIPESTATUS[0]}"
    rm -rf "${stub_dir}"
    exit "${status}"
fi
exit 0
STUB
chmod +x "${FAKE_REPO}/bin/aidock"

# --- 実行ヘルパー -------------------------------------------------------------

# 録画スクリプトを 1 回実行し、終了コード・出力・各種捕捉ファイルを用意する共通の土台。
# **入口を 2 つに分けても中身は書き写さない**: 端末の有無だけが違う 2 通りの起動方法が要る
# 一方で、捕捉ファイルや環境変数は共通なので、書き写すと後から足した捕捉ファイルが
# 片方だけ更新されず、もう片方のケースが前回の内容を見たまま緑になる（§6 DRY）。
# 第 1 引数がテストモード、第 2 引数以降が「録画スクリプトをどう起動するか」
run_record_with() {
    # コンテナ内スタブへ渡すテストモード
    local mode="$1"
    # 残りの引数（起動コマンド）を "$@" として使えるよう、モードを取り除く
    shift
    # 検査スクリプトの場所は record-demo.sh が export する AIDOCK_DEMO_WORKSPACE で
    # スタブ側へ伝わるので、ここでは何も渡さない
    # コンテナへ流し込まれた標準入力を受け取るファイル（毎回まっさらにする）
    STDIN_CAPTURE="${TEST_TMP}/stdin-capture"
    : > "${STDIN_CAPTURE}"
    # aidock shell を起動したときのカレントディレクトリを受け取るファイル
    PWD_CAPTURE="${TEST_TMP}/pwd-capture"
    : > "${PWD_CAPTURE}"
    # stty へのサイズ変更要求（固定・復元）を受け取るファイル
    STTY_CAPTURE="${TEST_TMP}/stty-capture"
    : > "${STTY_CAPTURE}"
    # コンテナ内の検査スクリプトが出した内容を**バイト列のまま**受け取るファイル。
    # LAST_OUTPUT は CR を落としてしまうので、CR 由来の退行はこちらでしか見られない
    CHECKS_CAPTURE="${TEST_TMP}/checks-capture"
    : > "${CHECKS_CAPTURE}"
    set +e
    LAST_OUTPUT="$(
        cd "${FAKE_REPO}" &&
            PATH="${STUB_BIN}:${PATH}" AIDOCK_TEST_MODE="${mode}" \
                AIDOCK_TEST_STDIN_CAPTURE="${STDIN_CAPTURE}" \
                AIDOCK_TEST_CHECKS_CAPTURE="${CHECKS_CAPTURE}" \
                AIDOCK_TEST_PWD_CAPTURE="${PWD_CAPTURE}" \
                AIDOCK_TEST_STTY_CAPTURE="${STTY_CAPTURE}" \
                "$@" 2>&1
    )"
    # **パイプを挟まない**: 挟むと $? がパイプ末尾のものになり、判定がすり替わる
    LAST_STATUS=$?
    set -e
    # pty 経由の実行では行末が CR LF になるので、比較しやすいよう CR だけ落とす
    # （端末を使わない実行では何も変わらない）
    LAST_OUTPUT="${LAST_OUTPUT//$'\r'/}"
}

# stty スタブへ渡す設定。**export しておく**: 起動コマンドが script(1) を挟むため、
# 呼び出し行の環境変数の前置きでは（sh -c の内側で走る）録画スクリプトまで届かない
export AIDOCK_TEST_STTY_SIZE=""
export AIDOCK_TEST_STTY_RESIZE_FAILS=""

# 録画スクリプトを**端末を持たない状態で**実行する（既定の入口）
run_record() {
    # 起動はそのまま。stty スタブの振る舞いは使わないので既定値に戻しておく
    AIDOCK_TEST_STTY_SIZE=""
    AIDOCK_TEST_STTY_RESIZE_FAILS=""
    run_record_with "$1" ./docs/demo/record-demo.sh
}

# 録画スクリプトを**擬似端末（pty）の上で**実行する。
# **なぜ必要か**: 端末サイズを固定する分岐は `[ -t 0 ] && [ -t 1 ]` の内側にあり、
# 通常の run_record（出力をコマンド置換で受けるので端末ではない）では一度も通らない。
# その状態では、固定と復元の条件をまるごと消してもテストが緑のまま＝「不在＝合格」になる。
# script(1) が pty を用意し、その中で終了コードもそのまま返してくれる（-e）。
# stty はスタブ済みなので、実行している端末のサイズには一切触れない。
#   第 2 引数: stty スタブが「現在のサイズ」として報告する値（空なら取得失敗を模す）
#   第 3 引数: 省略可。'fail' ならサイズ変更の呼び出しを失敗させる
#   第 4 引数: 省略可。録画スクリプトに付けるリダイレクト（標準出力だけ端末から外す等）
run_record_pty() {
    # stty スタブへ「現在のサイズ」と「変更が失敗するか」を伝える
    AIDOCK_TEST_STTY_SIZE="$2"
    AIDOCK_TEST_STTY_RESIZE_FAILS="${3:-}"
    # script(1) には起動するコマンドを 1 つの文字列で渡す（相対パスなので引用は不要）
    run_record_with "$1" script -qec "./docs/demo/record-demo.sh ${4:-}" /dev/null
}

# --- テスト本体 ---------------------------------------------------------------

printf '# record-demo.sh fail-closed contract\n\n'

# 1) 正常系: サンドボックスが健全なら GIF が生成され、終了コードは 0
rm -f "${FAKE_GIF}"
run_record ok
assert_status 0 "healthy sandbox: exits 0"
assert_exists "${FAKE_GIF}" "healthy sandbox: writes the GIF"
assert_contains "example.com blocked" "healthy sandbox: records the default-deny proof"
assert_missing "${FAKE_GIF_TMP}" "healthy sandbox: leaves no half-written temporary GIF behind"

# 1a) 合格した検査は**3 つとも同じラベル付きの行**で録画に残ること。
#     録画は README のデモ GIF そのもので、見る人はここだけを 5 秒で読む（CLAUDE.md §15）。
#     裸の値を出すと読み取れない・誤読される:
#       - `agent` 単独 … 直前の ls -la の所有者列（agent agent）に埋もれる
#       - `HTTP/2 200` 単独 … 到達できた証拠なのに「失敗した」と読まれる（実機では 404 が返る）
#     照合は LAST_OUTPUT ではなく**検査出力の控え**に対して行う: LAST_OUTPUT は pty 実行と
#     比較を揃えるため CR を全部落としており、CR 由来の退行をそこからは検出できない
assert_file_contains "${CHECKS_CAPTURE}" "[check] ok: running as agent (gosu drop to non-root)" \
    "healthy sandbox: labels the gosu drop instead of printing a bare user name"
assert_file_contains "${CHECKS_CAPTURE}" "[check] ok: example.com blocked (default-deny egress)" \
    "healthy sandbox: labels the default-deny proof"
assert_file_contains "${CHECKS_CAPTURE}" "[check] ok: api.anthropic.com reachable -- HTTP/2 200" \
    "healthy sandbox: labels the allowlist proof instead of printing a bare status line"
# ステータス行**だけ**を見せること（ヘッダを丸ごと流すと 3 行の証拠が押し流される）
assert_file_not_contains "${CHECKS_CAPTURE}" "content-type: application/json" \
    "healthy sandbox: shows only the status line, not the whole header block"
# 行末の CR を落としていること。**残ると端末がカーソルを行頭へ戻す**ため、GIF の上でだけ
# 次の行が先頭を上書きして壊れて見える（マージ前の録画に実際に残っていた退行）
assert_file_not_contains "${CHECKS_CAPTURE}" "$(printf 'HTTP/2 200 \r')" \
    "healthy sandbox: strips the CR that CRLF headers leave at the end of the status line"
# **成功時に削除の案内を出さない**: 前回の成果物が残っている状態で成功すると、
# 「git restore で復元できます」と案内された直後に新しい GIF が出来上がる。
# 案内に従うと古い GIF が新しい .cast と対になり、この仕組みが防ぎたい状態そのものになる
touch "${FAKE_GIF}"
run_record ok
assert_status 0 "healthy sandbox with a previous GIF present: exits 0"
assert_exists "${FAKE_GIF}" "healthy sandbox with a previous GIF present: replaces it with the new one"
assert_not_contains "git restore" \
    "healthy sandbox with a previous GIF present: gives no recovery advice for an artifact it just regenerated"

# 1b) コンテナへ流す標準入力は **ASCII のみ**であること。
#     実機ではここが TTY にエコーされて録画に写るため、日本語を流すと agg の既定フォントで
#     豆腐 (□) になる。検査本体はマウントしたスクリプトへ逃がしてあるので、
#     標準入力に載るのは検査スクリプトの起動行と exit だけのはず
assert_file_contains "${STDIN_CAPTURE}" "bash /workspace/aidock-demo-checks.sh" \
    "container stdin invokes the mounted checks script"
assert_file_ascii "${STDIN_CAPTURE}" "container stdin is ASCII only (would be echoed into the recording)"
# 対話 bash を確実に終わらせる exit が送られていること
# （無いと TTY 付きシェルが EOF で終わらず、録画がハングする）
assert_file_contains "${STDIN_CAPTURE}" "exit" "container stdin ends the shell with an explicit exit"

# 1c) 録画は**デモ用の一時ディレクトリ**から起動すること。
#     ここを外すと操作者の実パスが /workspace として bind mount され、
#     ls -la でその中身まで録画に写る（CLAUDE.md §3「実パスを写さない」）
assert_file_contains "${PWD_CAPTURE}" "/tmp/aidock-demo-workspace." \
    "aidock shell runs from the neutral demo workspace, not the operator's cwd"

# 1d) 端末が無い環境では「幅が環境依存になる」と警告する。
#     この警告が出ること自体が、端末サイズを固定する分岐が生きている証拠でもある
#     （テストは端末を持たないので必ずこちらの経路を通る）。
#     **サイズ固定を諦める分岐は 2 つある**ので、端末が無い側だけに現れる文言で照合する
#     （もう一方は「現在の端末サイズを復元できる形で取得できないため…固定しません」）。
#     ここで見ているのは正常系 (case 1) の出力なので、この 1 件のために
#     録画を丸ごともう一度回す必要はない
assert_contains "標準入力または標準出力が端末ではないため端末サイズを固定できません" \
    "no terminal: warns that the GIF width is environment-dependent"

# 2) default-deny の退行: 許可外ホストへ到達できたら失敗し、直前の実行で出来た GIF も残さない
run_record leaky
assert_status 1 "reachable example.com: exits non-zero"
assert_contains "default-deny egress is broken" "reachable example.com: names the regression"
assert_missing "${FAKE_GIF}" "reachable example.com: discards the GIF left by the previous run"

# 3) 許可リスト / DNS の退行: 許可ホストへ到達できなければ失敗し、GIF を残さない。
#    直前のケースが GIF を消しているので、**事前状態を touch で作ってから**検査する
#    （作らないと「何も削除しなくても assert_missing が緑」という不在＝合格になる）
touch "${FAKE_GIF}"
run_record blocked
assert_status 1 "unreachable api.anthropic.com: exits non-zero"
assert_contains "allowlist/DNS regression" "unreachable api.anthropic.com: names the regression"
assert_missing "${FAKE_GIF}" "unreachable api.anthropic.com: refuses to leave a GIF"

# 3b) gosu 降格の退行（SEC-7 / AC-3）: root のままなら失敗し、GIF を残さない。
#     ここが表示だけだと、`whoami` が root と出ている GIF を「agent へ降格している証拠」として
#     README に貼ってしまう（docs/demo/README.md が egress の 2 つに求めている表明と同じ原則）
touch "${FAKE_GIF}"
run_record rootuser
assert_status 1 "container still running as root: exits non-zero"
assert_contains "gosu drop to agent is broken" "container still running as root: names the regression"
assert_missing "${FAKE_GIF}" "container still running as root: refuses to leave a GIF"

# 4) ビルド失敗: 録画対象が失敗したら（asciinema は 0 を返すが）失敗として扱う。
#    直前のケースが GIF を消しているので事前状態を作る（3 と同じ理由）
touch "${FAKE_GIF}"
run_record buildfail
assert_status 1 "failing build: exits non-zero despite asciinema returning 0"
assert_missing "${FAKE_GIF}" "failing build: refuses to leave a GIF"
# 録画対象の失敗も agg へ到達しないので、消えたのは前回の成果物と確定できる
assert_contains "は .cast と食い違うため削除しました" \
    "failing build: attributes the discarded GIF to the previous run"

# 5) asciinema 自体の失敗（中断・起動失敗）でも古い GIF を残さない。
#    set -e で即終了すると後始末に到達しないため、明示的に受けているかを見る。
#    前回の成果物が残っている状態は touch で直接作る（本番実行を挟むより意図が明確で速い）
touch "${FAKE_GIF}"
run_record asciinemafail
assert_status 1 "asciinema failure: exits non-zero"
assert_missing "${FAKE_GIF}" "asciinema failure: discards the stale GIF"
# 削除した GIF の**説明**も固定する。消えるのは常に前回の実行の成果物なので、
# 「.cast と食い違うため削除した」「git restore で戻せる」と言い切れる
assert_contains "は .cast と食い違うため削除しました" \
    "asciinema failure: attributes the discarded GIF to the previous run"
assert_contains "git restore" "asciinema failure: points at the recovery path"

# 6) 状態ファイルが書かれなかった場合（録画対象を起動できなかった）も fail-closed
touch "${FAKE_GIF}"
run_record nostatus
assert_status 1 "missing status file: exits non-zero"
assert_contains "終了コードを取得できませんでした" "missing status file: distinguishes it from a failed step"
# ここも agg へ到達していないので、消えたのは前回の成果物と確定できる
assert_contains "は .cast と食い違うため削除しました" \
    "missing status file: attributes the discarded GIF to the previous run"
assert_missing "${FAKE_GIF}" "missing status file: discards the stale GIF"

# 7) GIF 変換の失敗でも、書きかけの GIF を残さない
touch "${FAKE_GIF}"
run_record aggfail
assert_status 1 "agg failure: exits non-zero"
assert_missing "${FAKE_GIF}" "agg failure: discards the partial GIF"
assert_missing "${FAKE_GIF_TMP}" "agg failure: leaves no half-written temporary GIF behind"

# 8) 上限を超える GIF は成果物として残さない（§15 の 10MB 基準）。
#    直前のケースが GIF を消しているので事前状態を作る（3 / 4 と同じ理由）
touch "${FAKE_GIF}"
run_record biggif
assert_status 1 "oversized GIF: exits non-zero"
assert_contains "上限" "oversized GIF: names the cap"
assert_missing "${FAKE_GIF_TMP}" "oversized GIF: leaves no half-written temporary GIF behind"
assert_missing "${FAKE_GIF}" "oversized GIF: refuses to leave the oversized artifact"

# 9) agg が 0 で終わっても中身が壊れていれば成果物にしない（上限だけでなく下限も見る）
touch "${FAKE_GIF}"
run_record emptygif
assert_status 1 "empty GIF: exits non-zero"
assert_missing "${FAKE_GIF}" "empty GIF: refuses to leave the empty artifact"
assert_missing "${FAKE_GIF_TMP}" "empty GIF: leaves no half-written temporary GIF behind"

# 9b) agg が 0 で終わりながら**出力に一切触れない**場合に、前回の実行が残した一時ファイルを
#     今回の成果物として昇格させない（出力先へ直接書かせていれば前回の .gif が、
#     一時ファイルを消さずに走らせれば前回の .tmp が、それぞれ検査を通って成果物になる）。
#     一時ファイルの名前は固定なので、SIGKILL / OOM や後始末の失敗で中身が残りうる。
#     agg を呼ぶ前に消していないと、agg が 0 で終わりながら書かなかったときに
#     **その残骸が全検査を通って .gif になる**（一時ファイル化で無くしたはずの状態）
printf 'GIF89a-stale-tmp' > "${FAKE_GIF_TMP}"
touch "${FAKE_GIF}"
run_record aggnowrite
assert_status 1 "leftover temporary GIF: is not promoted into the artifact"
assert_missing "${FAKE_GIF}" "leftover temporary GIF: leaves no artifact paired with the new .cast"
assert_missing "${FAKE_GIF_TMP}" "leftover temporary GIF: is cleaned up rather than kept"


touch "${FAKE_GIF}"
run_record notagif
assert_status 1 "non-GIF output: exits non-zero"
assert_missing "${FAKE_GIF}" "non-GIF output: refuses to leave the bogus artifact"
assert_missing "${FAKE_GIF_TMP}" "non-GIF output: leaves no half-written temporary GIF behind"

# 9c) 一時ファイルのパスを消せない場合（同じ名前のディレクトリが残っている等）も、
#     .cast を上書きした後の失敗なので前回の GIF を残さない。素の `rm -f` のままだと
#     set -e がここで止め、他の失敗経路と違って古い .gif が新しい .cast と対のまま残る
mkdir -p "${FAKE_GIF_TMP}/undeletable-by-rm-f"
touch "${FAKE_GIF}"
run_record ok
assert_status 1 "undeletable temporary path: exits non-zero"
assert_contains "一時ファイル" "undeletable temporary path: names what it could not remove"
assert_missing "${FAKE_GIF}" "undeletable temporary path: does not leave the previous GIF beside the new .cast"
rm -rf "${FAKE_GIF_TMP}"

# 9c-2) サイズの取得が失敗した場合も、前回の GIF を残さない。
#     素の代入（`GIF_SIZE="$(stat …)"`）のままだと `set -e` がここでスクリプトを終わらせ、
#     後始末に到達しないまま古い .gif が新しい .cast と対で残る（他の失敗経路と振る舞いが食い違う）
touch "${FAKE_GIF}"
run_record statfail
assert_status 1 "failing stat: exits non-zero"
assert_contains "サイズを取得できませんでした" "failing stat: names what it could not read"
assert_missing "${FAKE_GIF}" "failing stat: does not leave the previous GIF beside the new .cast"
assert_missing "${FAKE_GIF_TMP}" "failing stat: leaves no temporary GIF behind"

# 9d) 成果物への移動が失敗した場合も、前回の GIF を残さない。
#     ここも .cast を上書きした後なので、残すと新しい .cast と古い .gif が並ぶ
touch "${FAKE_GIF}"
run_record mvfail
assert_status 1 "failing mv: exits non-zero"
assert_missing "${FAKE_GIF}" "failing mv: does not leave the previous GIF beside the new .cast"
assert_missing "${FAKE_GIF_TMP}" "failing mv: leaves no temporary GIF behind"

# 10) Docker デーモンへ到達できなければ、録画を始める前に案内して止まる
run_record nodaemon
assert_status 1 "unreachable Docker daemon: exits non-zero"
assert_contains "デーモンを起動してから" "unreachable Docker daemon: gives an actionable message"

# 11) 端末がある環境での端末サイズの扱い。
#     ここまでのケースはすべて端末を持たないため、固定と復元の分岐は一度も通っていない
#     （その状態では分岐をまるごと消してもテストは緑のまま＝「不在＝合格」）。
#     pty を用意して各枝を通す。stty はスタブなので実端末には触れない。
#     **script(1) が無ければ検査できないので、黙って飛ばさず失敗にする**（不在＝合格を作らない）
if command -v script > /dev/null 2>&1; then
    # 11a) 復元に使えるサイズを返す端末: 録画用に固定し、終了時に元へ戻す
    run_record_pty ok "24 80"
    assert_status 0 "restorable terminal: exits 0"
    assert_file_contains "${STTY_CAPTURE}" "cols 120 rows 30" \
        "restorable terminal: pins the recording size so the GIF width is reproducible"
    assert_file_contains "${STTY_CAPTURE}" "rows 24 cols 80" \
        "restorable terminal: restores the caller's original size on exit"

    # 11b) winsize が未設定の pty（stty size が "0 0" を返す）: 戻せないので変更もしない。
    #      非空かどうかだけで判定していると、ここで `stty rows 0 cols 0` を実行してしまう
    run_record_pty ok "0 0"
    assert_status 0 "unusable terminal size: exits 0"
    assert_contains "復元できる形で取得できないため端末サイズを固定しません" \
        "unusable terminal size: says why the width will be environment-dependent"
    assert_file_empty "${STTY_CAPTURE}" \
        "unusable terminal size: makes no resize it could not undo"

    # 11c) 後始末が失敗しても端末サイズは元へ戻す。
    #      **トラップの本体も `set -e` の対象**なので、cleanup を先に置くと rm -rf が
    #      非ゼロで返った時点でトラップが打ち切られ、復元に到達しない（端末が 120x30 のまま残る）
    run_record_pty cleanupfail "24 80"
    assert_file_contains "${STTY_CAPTURE}" "rows 24 cols 80" \
        "failing cleanup: still restores the caller's terminal size"
    # **後始末の失敗で終了コードを乗っ取らせない**: 直上と同じ理由で**トラップの本体も
    # `set -e` の対象**なので、非ゼロを返すコマンドがあるとそこでトラップが打ち切られ、
    # その終了コードがスクリプトの終了コードになる。素の rm のままだと
    # 「完了」と報告した直後に exit 1 で終わり、`record-demo.sh && git add` が黙って空振りする
    assert_status 0 "failing cleanup: a successful recording still exits 0"
    assert_contains "一時ファイルの後始末に失敗しました" \
        "failing cleanup: reports the cleanup failure instead of swallowing it"

    # 11d) サイズ変更が拒否されたら黙って続けない（§6 エラーを握り潰さない）。
    #      ここを `|| true` で受けると、幅が固定できていないのに固定した前提で録画が進む
    run_record_pty ok "24 80" fail
    assert_contains "に固定できませんでした" \
        "refused resize: warns instead of silently recording at an unknown width"
    # 幅が固定できないことは録画の失敗ではない。ここを致命傷にすると、resize ioctl を
    # 通さない端末（多重化端末・制限付きコンテナ）では一切録画できなくなる
    assert_status 0 "refused resize: still completes the recording"

    # 11e) 標準出力だけ端末から外した場合も固定しない。
    #      **asciinema が録画データへ書く端末サイズは fd 1 から読む**ため、fd 0 だけを見て
    #      分岐すると stty は成功する一方で録画は既定の 80x24 になり、
    #      「固定した」と報告しながら幅が変わる（判定を `&&` から `||` に緩めるとこうなる）
    run_record_pty ok "24 80" "" "> /dev/null"
    assert_contains "標準入力または標準出力が端末ではないため端末サイズを固定できません" \
        "stdout redirected away from the terminal: declines to pin the size"
    assert_file_empty "${STTY_CAPTURE}" \
        "stdout redirected away from the terminal: touches no terminal size at all"
    # 11g) pty 経由でも**失敗が失敗として伝わる**こと。これが無いと、起動を `script -qec` から
    #      `script -qc`（終了コードを伝えない）へ変えても全ケースが緑のままになり、
    #      11a〜11f の assert_status がまとめて空振りする
    run_record_pty leaky "24 80"
    assert_status 1 "pty runs propagate a failing exit status (not just a passing one)"

    # 11f) 復元だけが拒否された場合も黙らない（§6 エラーを握り潰さない）。
    #      ここを `|| true` で受けると、端末が 120x30 のまま戻らないのに手掛かりが残らない
    run_record_pty ok "24 80" failrestore
    assert_status 0 "refused restore: the recording itself still succeeds"
    assert_contains "へ戻せませんでした" \
        "refused restore: tells the operator their terminal was left resized"
else
    report 1 "script(1) is available to exercise the terminal-size branches"
fi

# 12) 一時ファイル名の**一元管理**: スクリプトは `${GIF_FILE}.tmp` から導く一方、
#     .gitignore はその名前を直書きしている。成果物名を変えたときに .gitignore だけが
#     取り残されると、中断した実行の書きかけが `git add docs/demo` でコミットされうる
# shellcheck disable=SC2016  # sed のパターンには ${DEMO_DIR} という**文字列そのもの**を渡す
ARTIFACT_BASENAME="$(sed -n 's|^GIF_FILE="${DEMO_DIR}/\(.*\)"$|\1|p' "${RECORD_SCRIPT}")"
# **抽出に失敗したら合格に倒さない**: 空のまま照合すると grep -F "" が何にでも当たる
if [ -n "${ARTIFACT_BASENAME}" ]; then
    assert_file_contains "${REPO_ROOT}/.gitignore" "docs/demo/${ARTIFACT_BASENAME}.tmp" \
        "the temporary artifact name the script derives is the one .gitignore ignores"
else
    report 1 "the artifact name can be read out of record-demo.sh (GIF_FILE)"
fi

# 13) **コミット済みの録画が今のラベルで録られていること**。上のケース群は「今この場で
#     実行した検査スクリプト」の出力しか見ないため、ラベルを変えて期待値 3 つを直せば
#     CI は緑になり、README が貼る .cast / .gif だけが古い体裁のまま取り残される。
#     この PR 自身がその形を踏んだ（`=> ` で録った後に接頭辞を変え、録り直しが必要になった）。
#     接頭辞は pass() の printf から読み取り、成果物と機械的に突き合わせる（§6 一元管理。
#     ケース 12 の「スクリプトから導いた名前を .gitignore と照合する」のと同じ方式）
PASS_PREFIX="$(sed -n "/^pass() {/,/^}/ s/.*printf '\(.*\)%s.*/\1/p" "${RECORD_SCRIPT}")"
# **抽出に失敗したら合格に倒さない**: 空のまま照合すると grep -F "" が何にでも当たる
if [ -n "${PASS_PREFIX}" ]; then
    assert_file_contains "${REPO_ROOT}/docs/demo/aidock-demo.cast" "${PASS_PREFIX}" \
        "the committed recording was made with the label pass() currently prints"
else
    report 1 "the check label prefix can be read out of record-demo.sh (pass)"
fi

# --- summary ----------------------------------------------------------------
# 集計と終了コードの決定は共有ハーネスに任せる
harness_summary
