#!/usr/bin/env bash
# ci_coverage_test.sh - assert that CI's nets actually cover the repository:
# every committed shell script is linted, and every test suite is executed.
#
# Why this exists: issue #94 was a defect that grew in a blind spot -- the
# SEC-18 denylist check lived inline in .github/workflows/ci.yml, where the
# linters could not see it and where nothing could test it. PR #102
# moved that check into test/sec18_denylist_e2e.sh and collapsed the two
# copies of the linter's file list into a single `SHELL_FILES` env entry, so the
# two steps can no longer disagree with each other.
#
# What that fix did *not* close is the way the blind spot opens in the first
# place: `SHELL_FILES` is still a hand-maintained list. A script committed
# tomorrow without an entry is silently outside shellcheck and `bash -n` --
# the same "code the linters never see" that produced #94, reachable by simply
# forgetting a line. The mirror of it applies to the suites: a new
# test/<name>_test.sh that nobody wires into ci.yml never runs, and a test that
# never runs is indistinguishable from a test that always passes.
#
# Both are the "absence == pass" shape this repository has repeatedly been
# bitten by (see the action-pin and record-demo entries in
# docs/requirements.md): the failure is that a check is *missing*, and nothing
# reports a missing check. So the coverage itself gets a check, and it is
# derived -- the lists are read back out of ci.yml and compared against what is
# actually committed, rather than restated here. Restating them would just
# create a third copy to forget.
#
# Runs in the type-check job: no Docker, no network. It reads the real
# ci.yml and the real file list from git, so it is a repository-invariant test
# (like test/sec18_denylist_test.sh's wiring cases), not a behavioural one.

# エラー発生時に即座に停止し、未定義変数の参照もエラーにする（安全なスクリプト実行の基本設定）
set -euo pipefail

# このスクリプト自身が置かれているディレクトリの絶対パスを取得する
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# リポジトリのルートディレクトリ（SCRIPT_DIR の一つ上）を絶対パスで求める
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
# 検査対象のワークフロー定義（リンタ一覧とテスト実行ステップの正本）
CI_WORKFLOW="${REPO_ROOT}/.github/workflows/ci.yml"

# 共有のカウンタ・アサーション群（書き写しを増やさないため lib へ切り出してある）
# shellcheck source=test/lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

# --- 前提の確認 ---------------------------------------------------------------

# ワークフローが読めなければ以降の抽出がすべて空になり、
# 「照合対象が無い＝全部合格」に化ける。**先に止める**
if [ ! -f "${CI_WORKFLOW}" ]; then
    # 何が無いのかを明示して落とす
    printf 'FAIL - .github/workflows/ci.yml not found at %s\n' "${CI_WORKFLOW}" >&2
    exit 1
fi

# 対象は「コミット済みのファイル」に限る。作業ツリーの未追跡ファイル（試し書きの
# スクリプト等）まで拾うと、手元だけ赤くなって CI と結論が食い違う
if ! tracked_files="$(git -C "${REPO_ROOT}" ls-files 2> /dev/null)"; then
    # git が使えない場所では「検査できなかった」ことを合格に倒さない（fail-closed）
    printf 'FAIL - could not list tracked files via "git ls-files" in %s\n' "${REPO_ROOT}" >&2
    exit 1
fi

# --- ci.yml から検査対象の一覧を読み出す -------------------------------------------

# type-check ジョブの env にある `SHELL_FILES: >-` ブロックの中身を取り出す。
# YAML の折りたたみブロックなので、キー行より深くインデントされた行が値の続き
extract_shell_files() {
    # awk でキー行を見つけ、そこから続くインデント行だけを拾う
    awk '
        # SHELL_FILES キーの行を見つけたら、そのインデント幅を覚えて収集モードに入る
        /^[[:space:]]*SHELL_FILES:[[:space:]]*>-[[:space:]]*$/ {
            match($0, /^[[:space:]]*/)
            key_indent = RLENGTH
            collecting = 1
            next
        }
        # 収集モード中の処理
        collecting {
            # 空行はブロックの終わりとみなす
            if ($0 ~ /^[[:space:]]*$/) { exit }
            # 現在行のインデント幅を測る
            match($0, /^[[:space:]]*/)
            # キー行と同じかそれより浅くなったらブロックの外に出たので終了
            if (RLENGTH <= key_indent) { exit }
            # 前後の空白を落として 1 エントリとして出力する
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print
        }
    ' "${CI_WORKFLOW}"
}

# 抽出結果を配列へ読み込む（1 行 1 ファイル）
mapfile -t shell_files < <(extract_shell_files)

# 抽出が空なら、YAML の書式が変わって読めていない。**照合の土台が無い**ので
# 「差分ゼロ＝合格」に倒さず、ここで検査不能として落とす
if [ "${#shell_files[@]}" -eq 0 ]; then
    printf 'FAIL - could not parse SHELL_FILES out of %s (the "SHELL_FILES: >-" block moved or changed shape); this test cannot verify coverage\n' "${CI_WORKFLOW}" >&2
    exit 1
fi

# --- リポジトリ側の実体を数え上げる -------------------------------------------------

# コミット済みファイルのうちシェルスクリプトであるものを列挙する。
# 判定は「拡張子が .sh」または「1 行目が sh / bash の shebang」。
# **shebang も見る**のが要点で、bin/aidock のように拡張子を持たない実行スクリプトを
# 拡張子だけで探すと取りこぼし、それこそが本テストの防ぎたい漏れになる
discovered_scripts=()
# 追跡ファイルを 1 行ずつ処理する
while IFS= read -r path; do
    # 空行は読み飛ばす
    [ -n "${path}" ] || continue
    # 作業ツリーに実体が無いもの（削除途中など）は対象外
    [ -f "${REPO_ROOT}/${path}" ] || continue
    # 拡張子が .sh ならシェルスクリプトとして扱う
    if [[ "${path}" == *.sh ]]; then
        discovered_scripts+=("${path}")
        continue
    fi
    # 拡張子が無い場合は 1 行目の shebang を見る。**コマンド置換ではなく `read`** で読むのは、
    # 追跡ファイルにはバイナリ（docs/demo/aidock-demo.gif）も含まれ、`$(head -n1 …)` だと
    # bash が「ignored null byte in input」を警告して CI ログを汚すため
    first_line=""
    # 1 行目だけを読む（読めない・空ファイルでも失敗させない）
    IFS= read -r first_line < "${REPO_ROOT}/${path}" 2> /dev/null || true
    # sh / bash を指す shebang ならシェルスクリプトとして扱う（python 等は対象外）
    if [[ "${first_line}" =~ ^#\!.*[[:space:]/](bash|sh)$ ]]; then
        discovered_scripts+=("${path}")
    fi
done <<< "${tracked_files}"

# 発見数が 0 なら列挙のロジックが壊れている（本リポジトリには必ずシェルスクリプトがある）。
# 0 件のまま進むと「全部カバーされている」と報告してしまう
if [ "${#discovered_scripts[@]}" -eq 0 ]; then
    printf 'FAIL - found no shell scripts in the repository; the discovery logic is broken and this test proves nothing\n' >&2
    exit 1
fi

# 配列に指定の要素が含まれるかを返す小さなヘルパー（第 1 引数が探す値、以降が配列）
array_contains() {
    # 探したい値を取り出す
    local needle="$1"
    # 残りの引数を走査する
    shift
    # 1 要素ずつ突き合わせる
    local item
    for item in "$@"; do
        # 一致したら成功として返る
        [ "${item}" = "${needle}" ] && return 0
    done
    # 最後まで一致しなければ失敗
    return 1
}

# --- ケース 1: すべてのシェルスクリプトがリンタの一覧に載っている -----------------------

# 発見したスクリプトを 1 つずつ SHELL_FILES と突き合わせる
for script in "${discovered_scripts[@]}"; do
    # 一覧に載っていれば成功、載っていなければ失敗として数える
    if array_contains "${script}" "${shell_files[@]}"; then
        report 0 "リンタ網: ${script} が ci.yml の SHELL_FILES に載っている"
    else
        # 直近の実行情報は使わないので、診断に必要な内容を明示的に入れておく
        LAST_STATUS=1
        LAST_OUTPUT="${script} は shellcheck / bash -n のどちらからも見られていない（ci.yml の SHELL_FILES へ追加すること）"
        report 1 "リンタ網: ${script} が ci.yml の SHELL_FILES に載っている"
    fi
done

# --- ケース 2: 一覧に載っているファイルが実在する ---------------------------------------

# 消えたファイルが一覧に残っていると shellcheck のステップ自体が失敗するが、
# 原因が「一覧の古さ」だと分かる形でここでも落としておく
for listed in "${shell_files[@]}"; do
    # 実体があれば成功、無ければ失敗
    if [ -f "${REPO_ROOT}/${listed}" ]; then
        report 0 "リンタ網: SHELL_FILES の ${listed} が実在する"
    else
        LAST_STATUS=1
        LAST_OUTPUT="${listed} は ci.yml の SHELL_FILES に載っているがリポジトリに存在しない（削除・改名の追随漏れ）"
        report 1 "リンタ網: SHELL_FILES の ${listed} が実在する"
    fi
done

# --- ケース 3: すべてのテストスイートが CI から実行されている ---------------------------

# test/ 直下の *_test.sh を「CI が走らせるべきスイート」とみなす。
# 命名規約に沿ったファイルだけを対象にするので、ヘルパー（lib/harness.sh）や
# e2e 本体（sec18_denylist_e2e.sh）は含まれない
for script in "${discovered_scripts[@]}"; do
    # test/ 直下の *_test.sh 以外は対象外
    [[ "${script}" == test/*_test.sh ]] || continue
    # ci.yml が `bash <path>` の形で実際に呼んでいることを確かめる。
    # 置いただけで呼ばれないスイートは「常に緑」と見分けが付かない
    assert_file_contains "${CI_WORKFLOW}" "bash ${script}" "実行網: ${script} が ci.yml から実行されている"
done

# 集計を出して、失敗が 1 件でもあれば非ゼロで終わる
harness_summary
