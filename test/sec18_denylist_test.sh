#!/usr/bin/env bash
# sec18_denylist_test.sh - unit tests for test/sec18_denylist_e2e.sh's verdict
# contract.
#
# Why this exists: the SEC-18 denylist check used to be an inline `run:` block
# in .github/workflows/ci.yml, where nothing could test it and where the
# linters never saw it (shellcheck and `bash -n` run over scripts, not over
# workflow bodies). issue #94 is the bug that grew in that blind spot:
# the check resolved shadow's GID through a pipe that discarded
# docker's exit status, never validated the result, and read *any* failing build
# as proof that the denylist works. Two runs of the same commit disagreed --
# one green, one reporting a SEC-18 regression that had not happened.
#
# The contract this suite pins is the separation of two verdicts:
#
#   FAIL(SEC-18) - the denylist genuinely did not reject the collision.
#   FAIL(probe)  - the check could not be run, so it proves nothing either way.
#
# Both are fail-closed (non-zero exit); mixing them up is what sent a
# maintainer looking for a security regression that did not exist. The cases
# below drive every input that separates them, including the exact shape of
# issue #94 (an empty probe result silently becoming compose's default
# HOST_GID=1000, which collides with nothing and therefore builds fine).
#
# It also covers the mirror-image hole found while fixing #94: a build that
# fails for an unrelated reason (apt-get, npm, network) must not be reported as
# "SEC-18 ok", or a deleted denylist ships green on any day the build is broken.
# That is the "absence == pass" shape this repository has repeatedly been bitten
# by (see the action-pin and record-demo entries in docs/requirements.md).
#
# Hermetic: no Docker, no network. `docker` is a PATH stub whose two
# sub-commands (`run` for the GID probe, `compose … build`) are switchable per
# case, mirroring how test/guard_test.sh stubs docker/getent and
# test/record_demo_test.sh stubs asciinema/agg. The script under test is copied
# into a throwaway repository tree so each case controls the Dockerfile it reads.

# エラー発生時に即座に停止し、未定義変数の参照もエラーにする（安全なスクリプト実行の基本設定）
set -euo pipefail

# このスクリプト自身が置かれているディレクトリの絶対パスを取得する
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# リポジトリのルートディレクトリ（SCRIPT_DIR の一つ上）を絶対パスで求める
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
# テスト対象スクリプト（e2e ジョブから実行される本体）のパス
TARGET_SCRIPT="${REPO_ROOT}/test/sec18_denylist_e2e.sh"

# テスト全体で使う一時ディレクトリ（スタブと擬似リポジトリを置く）
TEST_TMP="$(mktemp -d)"
# テスト終了時に一時ディレクトリを必ず片付ける
# **素の `rm` にしない**: EXIT トラップの本体も `set -e` の対象で、削除に失敗すると
# その終了コードが**成功した実行を乗っ取り**、1 件も失敗していないのに赤くなる
trap 'rm -rf "${TEST_TMP}" || true' EXIT

# 共有のカウンタ・アサーション群（書き写しを増やさないため lib へ切り出してある）
# shellcheck source=test/lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

# --- 定数 ---------------------------------------------------------------------

# Dockerfile の拒否メッセージのうち GID・グループ名に依存しない固定部分。
# **本テスト・テスト対象スクリプト・本物の Dockerfile の 3 者で同じ文字列**であることを
# 末尾の配線ケースで機械的に固定する（どれか 1 つを書き換えると赤くなる）
DENYLIST_REJECTION_FRAGMENT="collides with the base image's sensitive system group"
# 擬似ベースイメージの参照（本物と同じく FROM 行から読み取らせる）
FAKE_BASE_IMAGE="node:22-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000"
# 擬似的な shadow グループの GID（getent の 3 番目のフィールド）
FAKE_SHADOW_GID="42"

# 擬似リポジトリのルート
FAKE_REPO="${TEST_TMP}/repo"
# スタブを置くディレクトリ（PATH の先頭に差し込む）
STUB_BIN="${TEST_TMP}/stub-bin"
# docker スタブが受け取った引数を記録するファイル
STUB_DOCKER_LOG="${TEST_TMP}/docker-args.log"
# docker スタブがビルド時に見た HOST_GID を記録するファイル
STUB_DOCKER_ENV_LOG="${TEST_TMP}/docker-env.log"

# スタブが参照するパスを子プロセスへ渡す
export STUB_DOCKER_LOG STUB_DOCKER_ENV_LOG

# --- スタブの用意 -------------------------------------------------------------

# スタブ用ディレクトリを作る
mkdir -p "${STUB_BIN}"

# docker スタブ: `run`（GID プローブ）と `compose … build` を別々に振る舞わせる。
# クォート付きヒアドキュメントなので、書き出し時点では何も展開されない
cat > "${STUB_BIN}/docker" << 'STUB'
#!/usr/bin/env bash
# 呼ばれた引数をそのまま記録する（どのサブコマンドがどう呼ばれたかを表明で読むため）
printf '%s\n' "$*" >> "${STUB_DOCKER_LOG}"
# GID プローブ（docker run --rm <image> getent group shadow）
if [ "$1" = "run" ]; then
    # 出力が指定されていれば返す（空なら「何も返さない getent」を模す）
    if [ -n "${STUB_RUN_OUTPUT-}" ]; then
        printf '%s\n' "${STUB_RUN_OUTPUT}"
    fi
    # 指定された終了コードで終わる（pull 失敗・レート制限などを模す）
    exit "${STUB_RUN_STATUS:-0}"
fi
# イメージビルド（docker compose -f … build --progress=plain）
if [ "$1" = "compose" ]; then
    # ビルドに渡された HOST_GID を記録する（意図した値が届いたかを表明で読む）
    printf 'HOST_GID=%s\n' "${HOST_GID-<unset>}" >> "${STUB_DOCKER_ENV_LOG}"
    # ビルドログの中身は**標準エラー**へ出す。本物の BuildKit が `--progress=plain` の
    # 進捗（Dockerfile の `>&2` による拒否メッセージを含む）を stderr に書くのと揃える。
    # 標準出力にしてしまうと、本体側の `2>&1` を消しても全ケースが緑のままになり、
    # 「拒否メッセージを一生拾えない e2e」が本テストをすり抜ける（レビューで実測）
    if [ -n "${STUB_BUILD_OUTPUT-}" ]; then
        printf '%s\n' "${STUB_BUILD_OUTPUT}" >&2
    fi
    # 指定された終了コードで終わる（既定は「拒否されて失敗」）
    exit "${STUB_BUILD_STATUS:-1}"
fi
# 想定外のサブコマンドは失敗させる（黙って 0 を返すと表明が素通りする）
printf 'unexpected docker sub-command: %s\n' "$*" >&2
exit 99
STUB
# スタブに実行権限を付ける
chmod +x "${STUB_BIN}/docker"

# --- ヘルパー -----------------------------------------------------------------

# 擬似リポジトリを作り直す。第 1 引数に Dockerfile の中身を渡す
make_fake_repo() {
    # 前のケースの残骸を消す
    rm -rf "${FAKE_REPO}"
    # テスト対象スクリプトは本物と同じ相対位置（<repo>/test/）に置く必要がある
    mkdir -p "${FAKE_REPO}/test" "${FAKE_REPO}/docker"
    # 検査対象のスクリプトをそのままコピーする
    cp "${TARGET_SCRIPT}" "${FAKE_REPO}/test/"
    # compose.yaml は docker がスタブなので中身を読まれない。存在だけさせる
    : > "${FAKE_REPO}/compose.yaml"
    # Dockerfile の中身はケースごとに差し替える（空文字なら作らない）
    if [ -n "$1" ]; then
        printf '%s\n' "$1" > "${FAKE_REPO}/docker/Dockerfile"
    fi
}

# 既定の Dockerfile（FROM 行＋デニーリストの拒否メッセージを持つ最小構成）
default_dockerfile() {
    printf 'FROM %s\n' "${FAKE_BASE_IMAGE}"
    # `${HOST_GID}` / `${AGENT_GROUP}` は **Dockerfile 側の**プレースホルダなので、
    # ここでシェルに展開させてはいけない（本物の Dockerfile と同じ見た目にするのが目的）
    # shellcheck disable=SC2016
    printf 'RUN echo "docker build: HOST_GID=${HOST_GID} %s ${AGENT_GROUP}" >&2\n' "${DENYLIST_REJECTION_FRAGMENT}"
}

# 拒否メッセージ 1 行を組み立てる。第 1 引数は「ビルドに渡されたことになっている GID」。
# BuildKit の `--progress=plain` が付ける行頭の進捗プレフィックスも再現する
rejection_line() {
    printf "#9 0.412 docker build: HOST_GID=%s %s 'shadow'; refusing to make it agent's primary group (SEC-18 widening) -- pass a different --build-arg HOST_GID" \
        "$1" "${DENYLIST_REJECTION_FRAGMENT}"
}

# テスト対象スクリプトを擬似リポジトリの中で実行し、終了コードと出力を控える
run_script() {
    # 毎回ログを空にしてから実行する（**空ファイルとして作る**のが要点で、
    # 未生成のままだと「呼ばれていないこと」を主張する表明がファイル不在で落ちる）
    : > "${STUB_DOCKER_LOG}"
    : > "${STUB_DOCKER_ENV_LOG}"
    # set -e で止まらないよう、終了コードを明示的に受け取る
    if LAST_OUTPUT="$(cd "${FAKE_REPO}" && PATH="${STUB_BIN}:${PATH}" bash test/sec18_denylist_e2e.sh 2>&1)"; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi
}

# --- ケース 1: 正常系（デニーリストが意図した GID を拒否する） ------------------------

# 既定の Dockerfile を用意する
make_fake_repo "$(default_dockerfile)"
# プローブは shadow の GID を返し、ビルドはその GID を名指しで拒否して失敗する
export STUB_RUN_STATUS=0 STUB_RUN_OUTPUT="shadow:x:${FAKE_SHADOW_GID}:" STUB_BUILD_STATUS=1
STUB_BUILD_OUTPUT="$(rejection_line "${FAKE_SHADOW_GID}")"
export STUB_BUILD_OUTPUT
run_script
assert_status 0 "正常系: 意図した GID が拒否されたら成功で終わる"
assert_contains "SEC-18 ok" "正常系: SEC-18 の合格を明示する"
assert_contains "probe ok" "正常系: プローブが成立したことも残す"
assert_file_contains "${STUB_DOCKER_ENV_LOG}" "HOST_GID=${FAKE_SHADOW_GID}" "正常系: 解決した GID がそのままビルドへ渡る"
assert_file_contains "${STUB_DOCKER_LOG}" "--progress=plain" "正常系: ログを行単位で読むため --progress=plain を付ける"
assert_file_contains "${STUB_DOCKER_LOG}" "run --rm ${FAKE_BASE_IMAGE} getent group shadow" "正常系: プローブは FROM 行のベースイメージに対して行う"

# --- ケース 2: プローブの docker run が失敗する（issue #94 の直接原因） -----------------

# イメージが pull できない状況を模す（終了コード 125・出力なし）
export STUB_RUN_STATUS=125 STUB_RUN_OUTPUT=""
run_script
assert_status 1 "probe 失敗: docker run が失敗したら非ゼロで終わる"
assert_contains "FAIL(probe)" "probe 失敗: probe の失敗として報告する"
assert_contains "was NOT exercised" "probe 失敗: デニーリストを検査できていないと明言する"
assert_not_contains "FAIL(SEC-18)" "probe 失敗: SEC-18 の退行とは報告しない（issue #94 の誤判定）"
assert_file_empty "${STUB_DOCKER_ENV_LOG}" "probe 失敗: GID が取れない以上ビルドは行わない"

# --- ケース 3: getent が 0 で終わりながら何も返さない ----------------------------------

# 空の出力（グループがベースイメージから消えた等）を模す
export STUB_RUN_STATUS=0 STUB_RUN_OUTPUT=""
run_script
assert_status 1 "空の probe: 非ゼロで終わる"
assert_contains "returned no output" "空の probe: 出力が無かったことを原因として示す"
assert_not_contains "FAIL(SEC-18)" "空の probe: SEC-18 の退行とは報告しない"
assert_file_empty "${STUB_DOCKER_ENV_LOG}" "空の probe: 空の GID のままビルドへ進まない（compose 既定の 1000 に化ける経路を断つ）"

# --- ケース 4: GID が数値として読めない --------------------------------------------

# 3 番目のフィールドが数字でない壊れた行を模す
export STUB_RUN_STATUS=0 STUB_RUN_OUTPUT="shadow:x:abc:"
run_script
assert_status 1 "非数値 GID: 非ゼロで終わる"
assert_contains "could not parse a numeric GID" "非数値 GID: 解析できなかったことを示す"
assert_file_empty "${STUB_DOCKER_ENV_LOG}" "非数値 GID: ビルドへ進まない"

# --- ケース 5: GID が 0（SEC-18 の別分岐を検査してしまう） ------------------------------

# shadow の GID が 0 として返る異常を模す
export STUB_RUN_STATUS=0 STUB_RUN_OUTPUT="shadow:x:0:"
run_script
assert_status 1 "GID=0: 非ゼロで終わる"
assert_contains "root-GID branch" "GID=0: デニーリストではなく root-GID 分岐を突くため拒否すると示す"
assert_file_empty "${STUB_DOCKER_ENV_LOG}" "GID=0: ビルドへ進まない"

# --- ケース 6: ビルドが成功してしまう（本物の SEC-18 退行） -----------------------------

# デニーリストが縮小・削除され、衝突する GID でもビルドが通る状況を模す
export STUB_RUN_STATUS=0 STUB_RUN_OUTPUT="shadow:x:${FAKE_SHADOW_GID}:" STUB_BUILD_STATUS=0 STUB_BUILD_OUTPUT="#9 DONE 0.4s"
run_script
assert_status 1 "退行: ビルドが成功したら非ゼロで終わる"
assert_contains "FAIL(SEC-18)" "退行: SEC-18 の退行として報告する"
assert_contains "build succeeded" "退行: 拒否されなかったことを原因として示す"
assert_not_contains "SEC-18 ok" "退行: 合格の文言は出さない"

# --- ケース 7: ビルドは失敗したが理由がデニーリストではない ------------------------------

# apt-get の一時的な失敗などで非ゼロになる状況を模す（拒否メッセージは出ない）
export STUB_BUILD_STATUS=1 STUB_BUILD_OUTPUT="#8 12.3 E: Failed to fetch http://deb.debian.org/debian/pool/main/... Connection timed out"
run_script
assert_status 1 "無関係な失敗: 非ゼロで終わる"
assert_not_contains "SEC-18 ok" "無関係な失敗: 終了コードだけで合格に倒さない（デニーリスト削除が緑で通る穴）"
assert_contains "may be unrelated" "無関係な失敗: 何も証明できていないと明言する"

# --- ケース 8: 拒否されたが GID が意図した値でない（issue #94 の観測された症状） ----------

# ビルドが compose 既定の 1000 で走ってしまい、別 GID の拒否メッセージが出る状況を模す
export STUB_BUILD_STATUS=1
STUB_BUILD_OUTPUT="$(rejection_line "1000")"
export STUB_BUILD_OUTPUT
run_script
assert_status 1 "GID 取り違え: 非ゼロで終わる"
assert_not_contains "SEC-18 ok" "GID 取り違え: 意図した GID でビルドされていない以上、合格にしない"
# **期待した拒否メッセージ全体**で照合する。`HOST_GID=42` だけを探すと、経路によらず必ず出る
# 「docker compose build exit (HOST_GID=42): 1」の行に当たってしまい、診断文を丸ごと消しても
# 緑のままになる（レビューで実測）。ここで見たいのは「何を期待していたか」を操作者に示せているか
assert_contains "docker build: HOST_GID=${FAKE_SHADOW_GID} ${DENYLIST_REJECTION_FRAGMENT} 'shadow'" "GID 取り違え: 期待していた拒否メッセージを診断に含める"

# --- ケース 9: Dockerfile から拒否メッセージが消えている --------------------------------

# デニーリストごと削除された（あるいは文言が変わった）Dockerfile を模す
make_fake_repo "FROM ${FAKE_BASE_IMAGE}"
export STUB_RUN_STATUS=0 STUB_RUN_OUTPUT="shadow:x:${FAKE_SHADOW_GID}:" STUB_BUILD_STATUS=1
STUB_BUILD_OUTPUT="$(rejection_line "${FAKE_SHADOW_GID}")"
export STUB_BUILD_OUTPUT
run_script
assert_status 1 "文言消失: 非ゼロで終わる"
assert_contains "no longer contains the denylist rejection message" "文言消失: 照合の土台が失われたことを示す"
assert_file_empty "${STUB_DOCKER_LOG}" "文言消失: 照合できないと分かった時点で docker を呼ばない"

# --- ケース 10: FROM 行が読めない ----------------------------------------------------

# FROM 行を持たない Dockerfile を模す（書式変更・生成失敗など）
make_fake_repo "RUN echo \"docker build: HOST_GID=x ${DENYLIST_REJECTION_FRAGMENT} y\""
run_script
assert_status 1 "FROM 欠落: 非ゼロで終わる"
assert_contains "could not read the base image" "FROM 欠落: ベースイメージを解決できなかったと示す"
assert_file_empty "${STUB_DOCKER_LOG}" "FROM 欠落: docker を呼ばない"

# --- ケース 11: Dockerfile 自体が無い -------------------------------------------------

# Dockerfile を作らない（パスの打ち間違い・移動を模す）
make_fake_repo ""
run_script
assert_status 1 "Dockerfile 不在: 非ゼロで終わる"
assert_contains "not found" "Dockerfile 不在: 見つからなかったことを示す"
assert_file_empty "${STUB_DOCKER_LOG}" "Dockerfile 不在: docker を呼ばない"

# --- ケース 12: 配線（本物のリポジトリ側） --------------------------------------------

# 本テストが持つ固定文字列が、テスト対象スクリプトと本物の Dockerfile の双方に実在することを
# 固定する。3 者のどれか 1 つだけを書き換えると、照合が「何にも当たらない」= 素通りに化ける
assert_file_contains "${TARGET_SCRIPT}" "${DENYLIST_REJECTION_FRAGMENT}" "配線: e2e スクリプトが同じ拒否メッセージ断片を見ている"
assert_file_contains "${REPO_ROOT}/docker/Dockerfile" "${DENYLIST_REJECTION_FRAGMENT}" "配線: 本物の Dockerfile に拒否メッセージが実在する"
# CI から実際に呼ばれていることも固定する（スクリプトを置いただけで呼ばれない状態を防ぐ）
# 実行の配線は**共有ライブラリ**で判定する。ここで素の文字列一致を書くと、
# 行末コメントや `name:` の言及、`if: false` で無効化されたステップでも
# 「実行されている」と読む弱い版になる（`test/lib/ci_workflow.sh` のヘッダを参照）
# shellcheck source=test/lib/ci_workflow.sh
source "${SCRIPT_DIR}/lib/ci_workflow.sh"
# ci.yml の実行内容を読み込む（読めなければ配線を検査できないので失敗として数える）
if ci_workflow_load "${REPO_ROOT}/.github/workflows/ci.yml" "${TEST_TMP}/ci-commands"; then
    # e2e ジョブが e2e スクリプトを実行していること
    assert_with ci_workflow_runs_script "配線: e2e ジョブが本スクリプトを実行する" \
        "ci.yml のどの run: ステップも test/sec18_denylist_e2e.sh を実行していない" \
        'test/sec18_denylist_e2e.sh'
    # type-check ジョブが本テストを実行していること
    assert_with ci_workflow_runs_script "配線: type-check ジョブが本テストを実行する" \
        "ci.yml のどの run: ステップも test/sec18_denylist_test.sh を実行していない" \
        'test/sec18_denylist_test.sh'
    # 網羅性テストが実行されていること。**輪を断つためにここでも固定する**:
    # `ci_coverage_test.sh` の配線は `action_pin_test.sh` が、`action_pin_test.sh` の配線は
    # `ci_coverage_test.sh` が見ているだけなので、**その 2 つを同時に止めると誰も気付かない**
    # （検査が走らなければ何も報告しない、という同じ形が 1 段上に移るだけ。レビューで指摘）。
    # 3 本目の支えを別のスイートに置くと、同時に止める必要のあるステップが 1 つ増える
    assert_with ci_workflow_runs_script "配線: type-check ジョブが網羅性テストを実行する" \
        "ci.yml のどの run: ステップも test/ci_coverage_test.sh を実行していない。これが止まると SHELL_FILES への追記漏れも未配線スイートも検出されなくなる" \
        'test/ci_coverage_test.sh'
else
    report_fail "配線: ci.yml の run: ステップを読み取れる" \
        "could not read the run: steps from ci.yml, so the wiring of the SEC-18 scripts could not be verified"
fi

# 集計を出して、失敗が 1 件でもあれば非ゼロで終わる
harness_summary
