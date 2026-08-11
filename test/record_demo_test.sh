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

# 成功したテストの件数
PASS=0
# 失敗したテストの件数
FAIL=0

# 直近の実行結果を保持する変数（終了コードと標準出力＋標準エラーの内容）
LAST_STATUS=0
LAST_OUTPUT=""

# 期待どおりなら PASS、違えば FAIL を数えて内容を表示する共通ヘルパー
report() {
    # 第 1 引数が真（0）なら成功として数える
    if [[ "$1" -eq 0 ]]; then
        PASS=$((PASS + 1))
        printf 'ok   - %s\n' "$2"
    else
        FAIL=$((FAIL + 1))
        printf 'NOT OK - %s\n' "$2"
        # 失敗時は原因調査のため実行結果を出す
        printf '       status=%s\n' "${LAST_STATUS}"
        printf '       output=%s\n' "${LAST_OUTPUT}"
    fi
}

# 終了コードが期待値と一致することを確認する
assert_status() {
    # 実際の終了コードと期待値を比較する（set -e で中断しないよう if で受ける）
    if [[ "${LAST_STATUS}" -eq "$1" ]]; then
        report 0 "$2"
    else
        report 1 "$2"
    fi
}

# 出力に指定した文字列が含まれることを確認する
assert_contains() {
    # 部分一致で探す
    if [[ "${LAST_OUTPUT}" == *"$1"* ]]; then
        report 0 "$2"
    else
        report 1 "$2"
    fi
}

# 指定したファイルが存在しないことを確認する
assert_missing() {
    # ファイルが無ければ成功
    if [[ ! -e "$1" ]]; then
        report 0 "$2"
    else
        report 1 "$2"
    fi
}

# 指定したファイルが存在することを確認する
assert_exists() {
    # ファイルがあれば成功
    if [[ -e "$1" ]]; then
        report 0 "$2"
    else
        report 1 "$2"
    fi
}

# --- スタブの用意 -------------------------------------------------------------

# スタブを置くディレクトリ（PATH の先頭に差し込む）
STUB_BIN="${TEST_TMP}/stub-bin"
mkdir -p "${STUB_BIN}"

# docker スタブ: 依存チェック（docker info）だけを満たす。実際のコンテナは起動しない
cat > "${STUB_BIN}/docker" << 'STUB'
#!/usr/bin/env bash
# info は「デーモンに到達できた」ことにして成功で返す
exit 0
STUB

# agg スタブ: cast を読んだことにして、それらしい GIF を書き出す
cat > "${STUB_BIN}/agg" << 'STUB'
#!/usr/bin/env bash
# 最後の引数が出力先の GIF なので、そこへダミー内容を書く
printf 'GIF89a-stub' > "${!#}"
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
# 本物と同様、録画対象は利用者のシェル経由で起動する
sh -c "${command_to_run}" || true
# --overwrite 相当: cast を録画内容で置き換える
printf 'cast-stub\n' > "${cast_path}"
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
#   buildfail … build が失敗する
write_aidock_stub() {
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
    # 標準入力（"bash /workspace/aidock-demo-checks.sh" と "exit"）は読み捨てる
    cat > /dev/null
    # マウント相当: ワークスペースに置かれた検査スクリプトを、curl だけ差し替えて実行する
    checks="${AIDOCK_DEMO_WORKSPACE}/aidock-demo-checks.sh"
    # curl スタブを置くディレクトリを作る
    curl_dir="$(mktemp -d)"
    cat > "${curl_dir}/curl" << 'CURL'
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
    chmod +x "${curl_dir}/curl"
    # ls / whoami は本物を使い、curl だけスタブを優先させる
    PATH="${curl_dir}:${PATH}" bash "${checks}"
    status=$?
    rm -rf "${curl_dir}"
    exit "${status}"
fi
exit 0
STUB
    chmod +x "${FAKE_REPO}/bin/aidock"
}
write_aidock_stub

# --- 実行ヘルパー -------------------------------------------------------------

# 録画スクリプトを指定のテストモードで実行し、終了コードと出力を記録する
run_record() {
    # コンテナ内スタブへ渡すテストモード
    local mode="$1"
    # 検査スクリプトの場所は record-demo.sh が export する AIDOCK_DEMO_WORKSPACE で
    # スタブ側へ伝わるので、ここでは何も渡さない
    set +e
    LAST_OUTPUT="$(
        cd "${FAKE_REPO}" &&
            PATH="${STUB_BIN}:${PATH}" AIDOCK_TEST_MODE="${mode}" \
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

# 2) default-deny の退行: 許可外ホストへ到達できたら失敗し、GIF を残さない
run_record leaky
assert_status 1 "reachable example.com: exits non-zero"
assert_contains "default-deny egress is broken" "reachable example.com: names the regression"
assert_missing "${FAKE_GIF}" "reachable example.com: refuses to leave a GIF"

# 3) 許可リスト / DNS の退行: 許可ホストへ到達できなければ失敗し、GIF を残さない
run_record ok
rm -f "${FAKE_GIF}"
run_record blocked
assert_status 1 "unreachable api.anthropic.com: exits non-zero"
assert_contains "allowlist/DNS regression" "unreachable api.anthropic.com: names the regression"
assert_missing "${FAKE_GIF}" "unreachable api.anthropic.com: refuses to leave a GIF"

# 4) ビルド失敗: 録画対象が失敗したら（asciinema は 0 を返すが）失敗として扱う
run_record ok
run_record buildfail
assert_status 1 "failing build: exits non-zero despite asciinema returning 0"
assert_missing "${FAKE_GIF}" "failing build: refuses to leave a GIF"

# 5) 失敗時は前回の GIF を残さない（.cast と食い違うため）
run_record ok
assert_exists "${FAKE_GIF}" "stale GIF setup: a successful run leaves a GIF"
run_record leaky
assert_missing "${FAKE_GIF}" "failed run discards the GIF left by the previous run"

# 6) 検査スクリプトはワークスペース経由で渡し、標準入力へは ASCII だけを流す
#    （TTY エコーで録画へ写るため。日本語を流すと agg の既定フォントで豆腐になる）
assert_contains "aidock-demo-checks.sh" "container command is passed as a mounted script path"

# --- summary ----------------------------------------------------------------
# パス数とフェイル数を集計してテスト結果の概要を出力する
printf '\n# %d passed, %d failed\n' "$PASS" "$FAIL"
# フェイルが 1 件でもあれば非ゼロで終了してテストスイートを失敗させる
[[ "$FAIL" -eq 0 ]]
