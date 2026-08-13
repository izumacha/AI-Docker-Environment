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
# the two checks inside the recording are assertions, not decoration: a
# reachable example.com (default-deny egress broken) or an unreachable
# api.anthropic.com (allowlist/DNS regression) must abort the run rather than
# produce a GIF that advertises a sandbox which no longer isolates anything.
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

# 実行権限を与える
chmod +x "${STUB_BIN}/docker" "${STUB_BIN}/agg" "${STUB_BIN}/asciinema"

# --- 擬似リポジトリの用意 -----------------------------------------------------

# 録画スクリプトはスクリプト自身の位置からリポジトリルートを求めるので、同じ構造を作る。
# パスにシングルクォートと $ を含めて、引用符の扱いの回帰も同時に見る
FAKE_REPO="${TEST_TMP}/it's-\$repo"
mkdir -p "${FAKE_REPO}/docs/demo" "${FAKE_REPO}/bin"
# テスト対象のスクリプトを擬似リポジトリへ複製する
cp "${RECORD_SCRIPT}" "${FAKE_REPO}/docs/demo/record-demo.sh"
# 生成物の置き場所（アサーションで使う）
FAKE_GIF="${FAKE_REPO}/docs/demo/aidock-demo.gif"

# bin/aidock スタブを書き出す。AIDOCK_TEST_MODE でコンテナ内の挙動を切り替える:
#   ok        … 遮断されており許可ホストへ到達できる（正常なサンドボックス）
#   leaky     … 許可外ホストへ到達できてしまう（default-deny の退行）
#   blocked   … 許可ホストへ到達できない（許可リスト / DNS の退行）
#   rootuser  … agent へ降格できていない（gosu 降格の退行 / SEC-7・AC-3）
#   buildfail … build が失敗する
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
            printf 'HTTP/2 200\n'
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
    # ls は本物を使い、curl / whoami だけスタブを優先させる
    PATH="${stub_dir}:${PATH}" bash "${checks}"
    status=$?
    rm -rf "${stub_dir}"
    exit "${status}"
fi
exit 0
STUB
chmod +x "${FAKE_REPO}/bin/aidock"

# --- 実行ヘルパー -------------------------------------------------------------

# 録画スクリプトを指定のテストモードで実行し、終了コードと出力を記録する
run_record() {
    # コンテナ内スタブへ渡すテストモード
    local mode="$1"
    # 検査スクリプトの場所は record-demo.sh が export する AIDOCK_DEMO_WORKSPACE で
    # スタブ側へ伝わるので、ここでは何も渡さない
    # コンテナへ流し込まれた標準入力を受け取るファイル（毎回まっさらにする）
    STDIN_CAPTURE="${TEST_TMP}/stdin-capture"
    : > "${STDIN_CAPTURE}"
    # aidock shell を起動したときのカレントディレクトリを受け取るファイル
    PWD_CAPTURE="${TEST_TMP}/pwd-capture"
    : > "${PWD_CAPTURE}"
    set +e
    LAST_OUTPUT="$(
        cd "${FAKE_REPO}" &&
            PATH="${STUB_BIN}:${PATH}" AIDOCK_TEST_MODE="${mode}" \
                AIDOCK_TEST_STDIN_CAPTURE="${STDIN_CAPTURE}" \
                AIDOCK_TEST_PWD_CAPTURE="${PWD_CAPTURE}" \
                ./docs/demo/record-demo.sh 2>&1
    )"
    LAST_STATUS=$?
    set -e
}

# --- テスト本体 ---------------------------------------------------------------

printf '# record-demo.sh fail-closed contract\n\n'

# 1) 正常系: サンドボックスが健全なら GIF が生成され、終了コードは 0
rm -f "${FAKE_GIF}"
run_record ok
assert_status 0 "healthy sandbox: exits 0"
assert_exists "${FAKE_GIF}" "healthy sandbox: writes the GIF"
assert_contains "example.com blocked" "healthy sandbox: records the default-deny proof"

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

# 5) asciinema 自体の失敗（中断・起動失敗）でも古い GIF を残さない。
#    set -e で即終了すると後始末に到達しないため、明示的に受けているかを見る。
#    前回の成果物が残っている状態は touch で直接作る（本番実行を挟むより意図が明確で速い）
touch "${FAKE_GIF}"
run_record asciinemafail
assert_status 1 "asciinema failure: exits non-zero"
assert_missing "${FAKE_GIF}" "asciinema failure: discards the stale GIF"

# 6) 状態ファイルが書かれなかった場合（録画対象を起動できなかった）も fail-closed
touch "${FAKE_GIF}"
run_record nostatus
assert_status 1 "missing status file: exits non-zero"
assert_contains "終了コードを取得できませんでした" "missing status file: distinguishes it from a failed step"
assert_missing "${FAKE_GIF}" "missing status file: discards the stale GIF"

# 7) GIF 変換の失敗でも、書きかけの GIF を残さない
touch "${FAKE_GIF}"
run_record aggfail
assert_status 1 "agg failure: exits non-zero"
assert_missing "${FAKE_GIF}" "agg failure: discards the partial GIF"

# 8) 上限を超える GIF は成果物として残さない（§15 の 10MB 基準）
run_record biggif
assert_status 1 "oversized GIF: exits non-zero"
assert_contains "上限" "oversized GIF: names the cap"
assert_missing "${FAKE_GIF}" "oversized GIF: refuses to leave the oversized artifact"

# 9) agg が 0 で終わっても中身が壊れていれば成果物にしない（上限だけでなく下限も見る）
touch "${FAKE_GIF}"
run_record emptygif
assert_status 1 "empty GIF: exits non-zero"
assert_missing "${FAKE_GIF}" "empty GIF: refuses to leave the empty artifact"

touch "${FAKE_GIF}"
run_record notagif
assert_status 1 "non-GIF output: exits non-zero"
assert_missing "${FAKE_GIF}" "non-GIF output: refuses to leave the bogus artifact"

# 10) Docker デーモンへ到達できなければ、録画を始める前に案内して止まる
run_record nodaemon
assert_status 1 "unreachable Docker daemon: exits non-zero"
assert_contains "デーモンを起動してから" "unreachable Docker daemon: gives an actionable message"

# 11) 端末が無い環境では「幅が環境依存になる」と警告する。
#     この警告が出るということは端末サイズを固定する分岐が生きている証拠でもある
#     （テストは端末を持たないので、必ずこちらの経路を通る）
run_record ok
assert_contains "端末サイズを固定できません" "no terminal: warns that the GIF width is environment-dependent"

# --- summary ----------------------------------------------------------------
# 集計と終了コードの決定は共有ハーネスに任せる
harness_summary
