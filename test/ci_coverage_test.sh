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
# Three things had to be got right for this to be evidence rather than
# decoration, each found by injecting the regression and watching this suite
# stay green (see the PR's review round):
#
#   * Membership in `SHELL_FILES` proves nothing unless the lint steps still
#     *consume* the variable, so the two consumers are asserted too.
#   * A commented-out `run:` line still contains the text we search for, so the
#     search runs over ci.yml with comment lines removed -- commenting a step
#     out is the most likely way a suite quietly stops running.
#   * Discovery has to see the scripts that have no `.sh` suffix, so the
#     shebang branch tokenizes the line instead of matching it whole (`#!/bin/bash -eu`
#     and `#!/usr/bin/env -S bash -euo pipefail` are shell scripts too).
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

# 検査が成立しないと分かった時点で、合格に倒さず理由を述べて止めるための共通の出口。
# 「照合対象が無い＝差分ゼロ＝合格」に化けるのを防ぐのがこのテストの要なので、
# 土台が崩れたときこそ黙って緑にしない（fail-closed）
bail() {
    # 何が成立しなかったのかを stderr に出す（CI ログでの見出しになる）
    printf 'FAIL - %s\n' "$1" >&2
    # 非ゼロで終了して CI を赤くする
    exit 1
}

# ワークフローが読めなければ以降の抽出がすべて空になる
[ -f "${CI_WORKFLOW}" ] || bail ".github/workflows/ci.yml not found at ${CI_WORKFLOW}"

# 対象は「コミット済みのファイル」に限る。作業ツリーの未追跡ファイル（試し書きの
# スクリプト等）まで拾うと、手元だけ赤くなって CI と結論が食い違う。
# まず git が使える場所かを確かめる（使えないまま進むと一覧が空になる）
git -C "${REPO_ROOT}" rev-parse --git-dir > /dev/null 2>&1 \
    || bail "${REPO_ROOT} is not a usable git checkout, so the committed file list cannot be read"

# --- ci.yml のうち「実際に実行される部分」を取り出す ------------------------------------

# 行頭が `#` の行を落とす。YAML のコメントも `run: |` ブロック内のシェルコメントも
# 行頭 `#` である点は同じで、どちらも実行されない。
# **コメント行を含めたまま探すと、コメントアウトされたステップを「配線されている」と読む**——
# 一時的にコメントアウトするのはスイートの実行が止まる最もありがちな経路で、
# それを素通りさせると本テスト自体が「不在＝合格」になる（レビューで実測）
CI_ACTIVE="$(grep -v '^[[:space:]]*#' "${CI_WORKFLOW}")"

# 実行される行が 1 行も残らなければ、コメント除去か読み込みが壊れている
[ -n "${CI_ACTIVE}" ] || bail "no non-comment lines remain in ${CI_WORKFLOW}; this test cannot verify wiring"

# 文字列を拡張正規表現のリテラルとして扱えるようにエスケープする
# （パス中の `.` が任意の 1 文字として働くと、別名のファイルに当たってしまう）
regex_escape() {
    # 英数字・`_`・`-`・`/` 以外の文字の前にバックスラッシュを置く
    printf '%s' "$1" | sed 's|[^[:alnum:]_/-]|\\&|g'
}

# ci.yml の「実行される部分」が指定の拡張正規表現に一致するかを返す
ci_active_matches() {
    # 行単位で探す（見つかれば成功）
    printf '%s\n' "${CI_ACTIVE}" | grep -Eq -- "$1"
}

# 「ci.yml に この記述がある」ことを 1 ケースとして数える共通ヘルパー。
# 第 1 引数が探す拡張正規表現、第 2 引数がケース名、第 3 引数が失敗時の診断。
#
# **部分一致ではなく語境界まで見る**のが要点。素の部分一致だと
# `shellcheck $SHELL_FILES` の探索が `shellcheck $SHELL_FILES_FAST` にも当たり、
# 一覧の一部しか lint していない状態を「配線されている」と読む（レビューで実測）
assert_ci_wires() {
    # 実行される行の中に見つかれば成功として数える
    if ci_active_matches "$1"; then
        report 0 "$2"
    else
        # 診断はこのケース固有の内容にする（共通ヘルパーは lib/harness.sh 側）
        report_fail "$2" "$3"
    fi
}

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
            # 空行は YAML の折りたたみブロックでは**段落の区切り**であってブロックの終わりではない。
            # ここで打ち切ると一覧が途中で切れ、実際には載っているファイルを
            # 「載っていない」と誤報する（しかも空にはならないので下の空判定にも掛からない）
            if ($0 ~ /^[[:space:]]*$/) { next }
            # 現在行のインデント幅を測る
            match($0, /^[[:space:]]*/)
            # キー行と同じかそれより浅くなったらブロックの外に出たので終了
            if (RLENGTH <= key_indent) { exit }
            # **空白で区切って 1 エントリずつ**出力する。折りたたみブロックは
            # 最終的に 1 本の空白区切り文字列になり、消費側（`shellcheck $SHELL_FILES` と
            # `for f in $SHELL_FILES`）も空白で分割する。1 行 1 パスと決め打つと、
            # 2 つを同じ行に書いた（消費側には何の影響も無い）だけで
            # 「載っているファイルが載っていない」と誤報する（レビューで実測）
            for (i = 1; i <= NF; i++) { print $i }
        }
    ' "${CI_WORKFLOW}"
}

# 抽出結果を配列へ読み込む（1 行 1 ファイル）
mapfile -t shell_files < <(extract_shell_files)

# 抽出が空なら、YAML の書式が変わって読めていない
[ "${#shell_files[@]}" -gt 0 ] \
    || bail "could not parse SHELL_FILES out of ${CI_WORKFLOW} (the \"SHELL_FILES: >-\" block moved or changed shape); this test cannot verify coverage"

# --- リポジトリ側の実体を数え上げる -------------------------------------------------

# コミット済みファイルのうちシェルスクリプトであるものを列挙する。
# 判定は「拡張子が .sh」または「1 行目が sh / bash の shebang」。
# **shebang も見る**のが要点で、bin/aidock のように拡張子を持たない実行スクリプトを
# 拡張子だけで探すと取りこぼし、それこそが本テストの防ぎたい漏れになる
discovered_scripts=()
# NUL 区切りで読む。既定の `git ls-files` は非 ASCII のパスを
# 8 進エスケープ付きのダブルクォートで囲んで出すため（core.quotePath の既定は true）、
# 日本語を含むファイル名が「実体の無いパス」に化けて静かに検査対象から落ちる。
# 本リポジトリはドキュメントも識別子も日本語なので、これは十分に起こりうる（レビューで実測）。
#
# **いったんファイルへ落としてから読む**のには 2 つの理由がある。(1) NUL を含む出力を
# コマンド置換へ通すと bash が「ignored null byte in input」を警告して CI ログを汚す。
# (2) `< <(git …)` のプロセス置換だと **git の終了コードを誰も見ない**。索引の読み取り
# エラーやロック競合で一覧を途中まで出して失敗した場合、残りのスクリプトは
# 「発見されなかった」＝暗黙に合格となる——issue #94 の `docker … | cut` と同じ形を
# このスイート自身が持つことになる（レビューで指摘）
tracked_list="$(mktemp)" || bail "could not create a temporary file for the tracked-file list"
# どの経路で終わっても一時ファイルを残さない
trap 'rm -f "${tracked_list}"' EXIT
# 一覧を書き出し、**git 自身の終了コードを確かめる**
git -C "${REPO_ROOT}" -c core.quotePath=false ls-files -z > "${tracked_list}" \
    || bail "\`git ls-files\` failed in ${REPO_ROOT}; the committed file list is incomplete and coverage cannot be verified"

while IFS= read -r -d '' path; do
    # 空のエントリは読み飛ばす
    [ -n "${path}" ] || continue
    # 追跡されているのに作業ツリーに実体が無い＝索引と食い違っている。
    # ここで読み飛ばすと「見つからなかったから合格」に倒れるので、理由を述べて止める
    [ -f "${REPO_ROOT}/${path}" ] \
        || bail "${path} is tracked by git but missing from the working tree; the checkout is inconsistent and coverage cannot be verified"
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
    # CRLF で保存されたファイルでも判定できるよう行末の CR を落とす
    first_line="${first_line%$'\r'}"
    # shebang で始まらなければシェルスクリプトではない
    [[ "${first_line}" == '#!'* ]] || continue
    # shebang を**単語に分割して**調べる。行全体を 1 つの正規表現で終端一致させると
    # `#!/bin/bash -eu` や `#!/usr/bin/env -S bash -euo pipefail` のように
    # 引数付きの shebang を取りこぼす（＝そのファイルがリンタからも本テストからも消える）
    shebang_tokens=()
    # `#!` を取り除いた残りを空白で区切って配列にする
    read -r -a shebang_tokens <<< "${first_line#'#!'}"
    # 先頭から順にトークンを見る
    for token in "${shebang_tokens[@]}"; do
        # パス部分（/usr/bin/ 等）を落として実行ファイル名だけにする
        token="${token##*/}"
        # sh か bash を指していればシェルスクリプトとして扱う（python 等は対象外）
        if [ "${token}" = "bash" ] || [ "${token}" = "sh" ]; then
            discovered_scripts+=("${path}")
            break
        fi
    done
done < "${tracked_list}"

# 発見数が 0 なら列挙のロジックが壊れている（本リポジトリには必ずシェルスクリプトがある）
[ "${#discovered_scripts[@]}" -gt 0 ] \
    || bail "found no shell scripts in the repository; the discovery logic is broken and this test proves nothing"

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

# --- ケース 1: リンタの一覧が実際に使われている -----------------------------------------

# **一覧に載っていること**は、その一覧を読むステップが生きていて初めて意味を持つ。
# 2 つの消費側を固定しないと、`shellcheck $SHELL_FILES` を
# `shellcheck bin/aidock` に書き換えるだけで 11 本が誰にも lint されなくなるのに
# 本テストは緑のまま通る（レビューで実測）
# 変数参照は `$SHELL_FILES` と `${SHELL_FILES}` のどちらの書き方でも同じ意味なので両方を認め、
# **直後が識別子の文字でないこと**まで見る（`$SHELL_FILES_FAST` のような別変数に当たらないように）
SHELL_FILES_REF='[$]\{?SHELL_FILES\}?([^[:alnum:]_]|$)'
assert_ci_wires "shellcheck +${SHELL_FILES_REF}" \
    "リンタ網: shellcheck ステップが SHELL_FILES を参照している" \
    "ci.yml の shellcheck ステップが SHELL_FILES そのもの（部分一致する別名ではなく）を読んでいない。一覧に載せても lint されない"
assert_ci_wires "for +f +in +${SHELL_FILES_REF}" \
    "リンタ網: bash -n ステップが SHELL_FILES を参照している" \
    "ci.yml の bash -n ステップが SHELL_FILES そのもの（部分一致する別名ではなく）を読んでいない。一覧に載せても構文チェックされない"

# --- ケース 2: すべてのシェルスクリプトがリンタの一覧に載っている -----------------------

# 発見したスクリプトを 1 つずつ SHELL_FILES と突き合わせる
for script in "${discovered_scripts[@]}"; do
    # 一覧に載っていれば成功、載っていなければ失敗として数える
    if array_contains "${script}" "${shell_files[@]}"; then
        report 0 "リンタ網: ${script} が ci.yml の SHELL_FILES に載っている"
    else
        # 診断はこのケース固有の内容にする（共通ヘルパーは lib/harness.sh 側）
        report_fail "リンタ網: ${script} が ci.yml の SHELL_FILES に載っている" \
            "${script} は shellcheck / bash -n のどちらからも見られていない（ci.yml の SHELL_FILES へ追加すること）"
    fi
done

# --- ケース 3: 一覧に載っているファイルが実在する ---------------------------------------

# 消えたファイルが一覧に残っていると shellcheck のステップ自体が失敗するが、
# 原因が「一覧の古さ」だと分かる形でここでも落としておく
for listed in "${shell_files[@]}"; do
    # 実体があれば成功、無ければ失敗
    if [ -f "${REPO_ROOT}/${listed}" ]; then
        report 0 "リンタ網: SHELL_FILES の ${listed} が実在する"
    else
        report_fail "リンタ網: SHELL_FILES の ${listed} が実在する" \
            "${listed} は ci.yml の SHELL_FILES に載っているがリポジトリに存在しない（削除・改名の追随漏れ）"
    fi
done

# --- ケース 4: すべてのテストスイートが CI から実行されている ---------------------------

# `test/` 配下の *_test.sh を「CI が走らせるべきスイート」とみなす。
# 命名規約に沿ったファイルだけを対象にするので、ヘルパー（lib/harness.sh）や
# e2e 本体（sec18_denylist_e2e.sh）は含まれない。
#
# **下位ディレクトリも対象に含める。** `[[ ]]` のパターンでは `*` が `/` も跨ぐので
# `test/e2e/foo_test.sh` もここに入る。当初これを「test/ 直下だけ」に狭めたが、
# それでは `test/e2e/` に置いたスイートが配線されないまま緑で通り、
# **本テストが塞いだはずの穴が 1 階層深いところに開き直る**（レビューで実測）。
# 契約の側を広げるのが正しく、要件（FR-8.1）もそれに合わせてある
for script in "${discovered_scripts[@]}"; do
    # 命名規約 `*_test.sh` に沿わないファイルは対象外
    [[ "${script}" == test/*_test.sh ]] || continue
    # ci.yml が `bash <path>` の形で**実行される行として**呼んでいることを確かめる。
    # 置いただけで呼ばれないスイートは「常に緑」と見分けが付かない。
    # パスは正規表現リテラルとしてエスケープし、直後が空白か行末であることまで見る
    # （`bash test/foo_test.sh` の探索が `bash test/foo_test.sh.bak` に当たらないように）
    assert_ci_wires "(^|[[:space:]])bash +$(regex_escape "${script}")([[:space:]]|\$)" \
        "実行網: ${script} が ci.yml から実行されている" \
        "${script} は ci.yml のどの実行ステップからも呼ばれていない（コメントアウトされた行は数えない）"
done

# 集計を出して、失敗が 1 件でもあれば非ゼロで終わる
harness_summary
