#!/usr/bin/env bash
# ci_workflow_test.sh - pin test/lib/ci_workflow.sh's verdicts against synthetic
# workflows, so the parser's behaviour is checked by something other than the
# one ci.yml it happens to read.
#
# Why this exists: the library answers "does ci.yml run X, in a way that can
# fail the job?", and three suites trust that answer. Until now the only input
# it was ever run against was the repository's real ci.yml -- which contains no
# `shell:`, no `defaults:`, no heredoc, no `if: false`. Every rule written for
# those shapes could therefore be deleted with all suites still green: the
# "absence == pass" shape this repository keeps closing, one level up, in the
# code whose whole job is to close it. Review found four such defects in a
# single round, each of which a case here would have caught.
#
# The cases are the regressions themselves, in pairs: a spelling that must count
# as wired-and-gating, and the neighbouring spelling that must not. Both
# directions matter -- a parser that answers "no" to everything is as useless as
# one that answers "yes", and this file has to fail if either drifts.
#
# Hermetic: no Docker, no network, no git. Each case writes a small workflow to a
# temp file and asks the library about it.

# エラー発生時に即座に停止し、未定義変数の参照もエラーにする（安全なスクリプト実行の基本設定）
set -euo pipefail

# このスクリプト自身が置かれているディレクトリの絶対パスを取得する
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# 共有のカウンタ・アサーション群（書き写しを増やさないため lib へ切り出してある）
# shellcheck source=test/lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# 検査対象そのもの。ここでしか使わない関数も含めて丸ごと読み込む
# shellcheck source=test/lib/ci_workflow.sh
source "${SCRIPT_DIR}/lib/ci_workflow.sh"

# 合成ワークフローと抽出結果を置く場所（テストごとに作り直す）
TMP_DIR="$(mktemp -d)"
# どの経路で終わっても片付ける。**素の `rm` にしない**のが要点で、EXIT トラップの本体も
# `set -e` の対象であり、削除に失敗するとその終了コードが**成功した実行を乗っ取る**
trap 'rm -rf "${TMP_DIR}" || true' EXIT

# 検査対象のスクリプトとして使う架空のパス（実在しなくてよい。ライブラリは文字列として扱う）
SUITE_PATH="test/subject_test.sh"

# ワークフロー本文に**シェルに展開させずに**書きたい `$` を表す定数。
# 合成ワークフローの中の `$GITHUB_WORKSPACE` や `${{ … }}` は、このテストのシェルにとっては
# ただの文字であって変数ではない。単一引用符で書くと shellcheck が「展開されない」と警告し
# （SC2016。ここでは展開されないのが正しい）、二重引用符で書くと本当に展開されてしまうので、
# 意図した literal であることをこの 1 か所で表しておく
DOLLAR='$'

# 終端の照合に使うタブ。`<<-` が落とすのは**先頭のタブだけ**で、スペースは落とさない。
# YAML のブロックスカラーはスペースで字下げされるため、この 2 つは実際に意味が違う
TAB=$'\t'

# 区切り語の**後ろ**に置く空白を表す定数（`DOLLAR` と同じ意図）。
# 行末の空白は多くのエディタと lint が黙って落とすため、ここに直接書くと
# 検査したい形が保存のたびに消える。名前を付けて意図した literal だと示す
SPACE=' '

# どの合成ワークフローにも足す、常に 1 つコマンドを持つジョブ。
# これが無いと「対象のジョブを丸ごと無効化した」ケースで抽出結果が空になり、
# 解析器が壊れて何も取れない状態と区別が付かなくなる（`workflow_verdict` の説明を参照）
KEEPALIVE_JOB='  keepalive:
    runs-on: ubuntu-latest
    steps:
      - name: keepalive
        run: echo alive'

# 合成ワークフローを読み込み、指定パスの判定結果を標準出力へ 1 語で返す。
# `wired` / `not-wired` / `load-failed` の 3 値で、**読み込み失敗を「配線されていない」と混ぜない**のが要点。
# 混ぜると、解析器が丸ごと壊れて何も抽出できなくなったときに
# `assert_not_wired` のケースが全部「期待どおり」に化ける——このファイルが塞ごうとしている
# 「不在＝合格」が、このファイル自身の中に開く（レビューで指摘）。
# 第 1 引数がワークフローの本文、第 2 引数（省略可）が絞り込むジョブ名
workflow_verdict() {
    # 本文を一時ファイルへ書き出す（ライブラリはファイルパスを受け取る）。
    # **必ず 1 つはコマンドを持つジョブを足す**のが要点で、検査対象のジョブを丸ごと
    # 無効化するケースでは抽出結果が空になり、`ci_workflow_load` が「読めなかった」を返す
    # ——判定の食い違いと解析器の故障が見分けられなくなるため、常に見分けられる形にしておく
    local workflow="${TMP_DIR}/workflow.yml"
    printf '%s\n' "${1/$'\njobs:\n'/$'\njobs:\n'${KEEPALIVE_JOB}$'\n'}" > "${workflow}"
    # 抽出結果の置き場は毎回新しくする（前の回の記録が残らないように）
    local extracted="${TMP_DIR}/commands"
    rm -f "${extracted}" || true
    # 読み込めなければその旨をそのまま返す（呼び出し側が失敗として扱う）
    if ! ci_workflow_load "${workflow}" "${extracted}"; then
        printf 'load-failed\n'
        return 0
    fi
    # ジョブ名の絞り込みは第 2 引数（空なら全ジョブ）
    if ci_workflow_runs_script "${SUITE_PATH}" "${2-}"; then
        printf 'wired\n'
    else
        printf 'not-wired\n'
    fi
}

# 判定が期待どおりかを数える共通部分。第 1 引数が期待値、第 2 引数がケース名、
# 第 3 引数がワークフロー本文、第 4 引数（省略可）がジョブ名
assert_verdict() {
    # 実際の判定を取る
    local actual
    actual="$(workflow_verdict "$3" "${4-}")"
    # 期待と一致すれば合格
    if [ "${actual}" = "$1" ]; then
        report 0 "$2"
        return
    fi
    # 読み込み自体が成立していない場合は、その事実を診断に出す（判定の食い違いと区別する）
    if [ "${actual}" = "load-failed" ]; then
        report_fail "$2" "合成ワークフローを読み込めませんでした（解析器が壊れています。判定以前の失敗）"
        return
    fi
    # 期待と逆の判定が出た場合は、どちらの向きの誤りかが分かる文言を出す
    if [ "$1" = "wired" ]; then
        report_fail "$2" "この書き方は実行され合否にも効くのに「配線されていない」と判定された（事実と逆の診断で CI が赤くなる）"
    else
        report_fail "$2" "この書き方はスイートを走らせないか結果を握り潰すのに「配線されている」と判定された（穴）"
    fi
}

# 「配線されている」と判定されるべき合成ワークフローを検査する。
# 第 1 引数がケース名、第 2 引数がワークフロー本文、第 3 引数（省略可）がジョブ名
assert_wired() { assert_verdict "wired" "$@"; }

# 「配線されていない（あるいは合否に効かない）」と判定されるべき合成ワークフローを検査する
assert_not_wired() { assert_verdict "not-wired" "$@"; }

# 何も特別なことをしていない土台。ジョブ名の絞り込みなど、書き方の違いが関係しないケースで使う
BASE_WORKFLOW="name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}"

# --- 基本形 -------------------------------------------------------------------

assert_wired "素の run: が配線として読まれる" "${BASE_WORKFLOW}"

assert_wired "ジョブ名で絞り込んでも読まれる" "${BASE_WORKFLOW}" "type-check"

assert_not_wired "別のジョブ名で絞り込むと読まれない" "${BASE_WORKFLOW}" "e2e"

# --- シェルの指定（既定の `bash -e` から外れると合否に効かない） --------------------

assert_not_wired "ステップの shell: が自前テンプレート（-e が消える）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        shell: bash {0}
        run: bash ${SUITE_PATH}"

assert_wired "ステップの shell: bash（-e を含むキーワード形式）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        shell: bash
        run: bash ${SUITE_PATH}"

assert_wired "shell: bash はパイプ越しでも失敗が伝わる（pipefail を含む）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        shell: bash
        run: bash ${SUITE_PATH} | tee log"

assert_not_wired "既定のシェルではパイプ越しの失敗は伝わらない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH} | tee log"

assert_wired "shell: sh は -e を含む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        shell: sh
        run: bash ${SUITE_PATH}"

assert_wired "shell: の値が引用符付きでも同じスカラー" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        shell: \"bash\"
        run: bash ${SUITE_PATH}"

assert_not_wired "ジョブの defaults: が自前テンプレート" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    defaults:
      run:
        shell: bash {0}
    steps:
      - name: subject
        run: bash ${SUITE_PATH}"

assert_not_wired "ワークフローの defaults: が自前テンプレート" "name: ci
defaults:
  run:
    shell: bash {0}
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}"

assert_not_wired "defaults: が jobs: の後ろにあっても効く（キー順は自由）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}
defaults:
  run:
    shell: bash {0}"

assert_not_wired "フロー形式の defaults: は中身を読めないので数えない" "name: ci
defaults: {run: {shell: bash {0}}}
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}"

assert_wired "ジョブの defaults: が bash キーワードなら効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    defaults:
      run:
        shell: bash
    steps:
      - name: subject
        run: bash ${SUITE_PATH}"

assert_not_wired "ジョブの defaults: が steps: の後ろでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}
      - name: trailing
        run: echo done
    defaults:
      run:
        shell: bash {0}"

assert_wired "既定シェルの行末コメントは値に混ざらない" "name: ci
defaults:  # 全ジョブ共通
  run:
    shell: bash  # 明示しておく
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}"

assert_wired "ステップの入力に defaults という名前があっても既定ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - uses: some/action@v1
        with:
          defaults: enabled
      - name: subject
        run: bash ${SUITE_PATH}"

assert_wired "自前テンプレートでも set -e を明示していればゲートする" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        shell: bash {0}
        run: |
          set -euo pipefail
          bash ${SUITE_PATH}"

# --- 無効化されたステップ・ジョブ ------------------------------------------------

assert_not_wired "ステップの if: false" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        if: false
        run: bash ${SUITE_PATH}"

assert_not_wired "ステップの if: が式（その場で評価できない）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        if: ${DOLLAR}{{ github.event_name == 'push' }}
        run: bash ${SUITE_PATH}"

assert_wired "ステップの if: true は止めていない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        if: true
        run: bash ${SUITE_PATH}"

assert_not_wired "ステップの continue-on-error: true" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        continue-on-error: true
        run: bash ${SUITE_PATH}"

assert_wired "ステップの continue-on-error: false は止めていない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        continue-on-error: false
        run: bash ${SUITE_PATH}"

assert_not_wired "ジョブの continue-on-error: が steps: の後ろ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}
      - name: trailing
        run: echo done
    continue-on-error: true"

assert_not_wired "steps: とダッシュが同じ桁でもジョブ単位のキーが効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
    - name: subject
      run: bash ${SUITE_PATH}
    - name: trailing
      run: echo done
    continue-on-error: true"

# --- 失敗の握り潰し（走るが合否に効かない） ----------------------------------------

assert_not_wired "|| true" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH} || true"

assert_not_wired "引数やリダイレクトを挟んだ後のパイプ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH} --verbose 2>&1 | tee log"

assert_wired "pipefail を立てたステップのパイプは伝わる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -o pipefail
          bash ${SUITE_PATH} | tee log"

assert_wired "リダイレクトだけならゲートする" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH} > log 2>&1"

assert_not_wired "set +ex で errexit が落ちている" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +ex
          bash ${SUITE_PATH}"

assert_wired "set +e が set -euo pipefail で戻されている" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          echo probing
          set -euo pipefail
          bash ${SUITE_PATH}"

assert_not_wired "行末の \\ で続く次の行の || true" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} \
            || true"

assert_not_wired "折りたたみ（run: >）の次の行の || true" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: >
          bash ${SUITE_PATH}
          || true"

assert_not_wired "条件部（if <suite>; then）は結果が吸われる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if bash ${SUITE_PATH}; then echo ok; fi"

assert_not_wired "一度も走らない if false; then <suite>; fi" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if false; then bash ${SUITE_PATH}; fi"

assert_not_wired "条件の中のブレースグループの後ろ（深さが狂わない）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}X\" ]; then
            check || { echo bad; exit 1; }
            bash ${SUITE_PATH}
          fi"

assert_not_wired "defaults: の run: がフロー形式（中の shell: を読めない）" "name: ci
defaults:
  run: {shell: bash {0}}
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}"

assert_not_wired "ジョブの defaults: の run: がフロー形式" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    defaults:
      run: {shell: bash {0}}
    steps:
      - name: subject
        run: bash ${SUITE_PATH}"

assert_not_wired "引用符付きの鍵（\"shell\": 自前テンプレート）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        \"shell\": bash {0}
        run: bash ${SUITE_PATH}"

assert_wired "steps: より前の入れ子に defaults という名前があってもよい" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    env:
      defaults: none
    steps:
      - name: subject
        run: bash ${SUITE_PATH}"

assert_not_wired "here-string と本物の heredoc が同じ行にある" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          grep -q x <<< word; cat > f <<MARK
          bash ${SUITE_PATH}
          MARK"

assert_wired "set -e -o pipefail のように語をまたいだ指定" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -e -o pipefail
          bash ${SUITE_PATH} | tee log"

assert_wired "関数定義の { が次の行にあっても深さが戻る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f()
          {
            echo hi
          }
          bash ${SUITE_PATH}"

assert_not_wired "複数行の部分シェルを閉じた行の || true" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          (
            bash ${SUITE_PATH}
          ) || true"

assert_not_wired "呼ばれていない function 形式の関数の中身" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          function run_suite {
            bash ${SUITE_PATH}
          }
          echo defined"

assert_wired "単独のダッシュで始まるステップも読む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      -
        name: subject
        run: bash ${SUITE_PATH}"

assert_wired "ブロックスカラーの指示子が |-2 の順でも読む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |-2
          bash ${SUITE_PATH}"

assert_not_wired "true || <suite>（そもそも走らない）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: true || bash ${SUITE_PATH}"

assert_not_wired "false && <suite>（そもそも走らない）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: false && bash ${SUITE_PATH}"

assert_wired "1 行の部分シェルの後ろでも深さが戻る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( cd /tmp; echo hi )
          bash ${SUITE_PATH}"

assert_not_wired "通らない分岐の set -e は握り潰しを隠さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          if false; then
            set -e
          fi
          bash ${SUITE_PATH}"

assert_wired "通るとは限らない分岐の set +e で誤報しない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}DEBUG\" ]; then
            set +e
          fi
          bash ${SUITE_PATH}"

assert_wired "コマンド置換は括弧の釣り合いを崩さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          today=${DOLLAR}(date -u +%F)
          bash ${SUITE_PATH}"

assert_not_wired "一致しない case アームの中身" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case \"${DOLLAR}MODE\" in
            never)
              bash ${SUITE_PATH}
              ;;
          esac"

assert_wired "bash -euo pipefail 付きの呼び出し" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash -euo pipefail ${SUITE_PATH}"

assert_wired "sudo 経由の呼び出し" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: sudo bash ${SUITE_PATH}"

assert_not_wired "bash -o noexec（-n の別綴り）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash -o noexec ${SUITE_PATH}"

assert_not_wired "false && … && <suite>（連鎖の先も走らない）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: false && echo mid && bash ${SUITE_PATH}"

assert_wired "; で連鎖が切れた後は走る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: false && echo mid; bash ${SUITE_PATH}"

assert_not_wired "jobs: の外にある run: は CI のコマンドではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: keepalive
        run: echo alive
unrelated:
  bogus:
    steps:
      - run: bash ${SUITE_PATH}"

# --- 言及と実行の区別 -------------------------------------------------------------

assert_not_wired "echo の中の言及" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: echo \"skipping bash ${SUITE_PATH} for now\""

assert_not_wired "引用符の中で ; の後に置かれた言及" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: echo \"stopped; bash ${SUITE_PATH}\""

assert_not_wired "heredoc の本文（ファイルへ書くだけ）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<MARK > note.txt
          bash ${SUITE_PATH}
          MARK"

assert_not_wired "引用符付きの区切り語（<<'MARK'）の heredoc 本文" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<'MARK' > note.txt
          bash ${SUITE_PATH}
          MARK"

assert_not_wired "本文中の字下げされた区切り語は終端ではない（素の <<）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat > note.txt <<MARK
            MARK
          bash ${SUITE_PATH}
          MARK"

assert_wired "必ず走る grouping の中の呼び出しは実行の証拠になる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          (
            cd /tmp
            bash ${SUITE_PATH}
          )"

assert_not_wired "通る分岐の set +e は握り潰しとして効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then
            set +e
          fi
          bash ${SUITE_PATH}"

assert_not_wired "算術式の後ろに置かれた本物の heredoc の本文" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if (( 1 > 0 )); then cat > note.txt <<MARK
          bash ${SUITE_PATH}
          MARK
          fi"

assert_wired "入れ子のある算術式でも後続の実行が消えない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          mask=${DOLLAR}(( (1 << BIT) | FLAG ))
          bash ${SUITE_PATH}"

assert_wired "算術式の左シフトは heredoc ではない（後続の実行が消えない）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bit=${DOLLAR}(( 1 << SHIFT ))
          bash ${SUITE_PATH}"

assert_not_wired "with: 配下の run: は action への入力" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - uses: some/action@v1
        with:
          run: bash ${SUITE_PATH}"

assert_not_wired "bash -n は構文を見るだけで実行しない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash -n ${SUITE_PATH}"

assert_not_wired "複数行で書いた if false; then の中身" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if false; then
            bash ${SUITE_PATH}
          fi"

assert_not_wired "while false; do のループ本体" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          while false; do
            bash ${SUITE_PATH}
          done"

assert_not_wired "呼ばれていない関数の中身" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          run_suite() {
            bash ${SUITE_PATH}
          }
          echo defined"

assert_not_wired "複数行の引用符付き引数を閉じた行の || true" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          docker run img bash -lc '
            bash ${SUITE_PATH}
          ' || true"

assert_not_wired "引用符の中の # はコメントではない（後ろの || true が消えない）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH} --label 'issue # 94' || true"

assert_wired "引用符の中の << は heredoc を開かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          echo \"use << HERE syntax\"
          bash ${SUITE_PATH}"

assert_wired "here-string（<<<）は heredoc ではない（後続の実行が消えない）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          grep -q foo <<< word
          bash ${SUITE_PATH}"

assert_not_wired "エスケープされた引用符の後ろの || true" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH} --msg \"a \\\" b\" || true"

assert_wired "エスケープされた引用符を含む行の次の行は繋がない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          grep -q \"a \\\" b\" file
          bash ${SUITE_PATH}"

assert_not_wired "入れ子の並びに書かれた - run: は action への入力" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - uses: some/action@v1
        with:
          steps:
            - run: bash ${SUITE_PATH}"

assert_wired "入れ子の並びの - if: false は外側のステップを止めない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}
        with:
          items:
            - if: false"

# --- 呼び出しの書き方の揺れ（意味が変わらない書き換えで赤くしない） ------------------

assert_wired "bash -x" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash -x ${SUITE_PATH}"

assert_wired "実行権限に頼った ./path" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: ./${SUITE_PATH}"

assert_wired "timeout ラッパ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: timeout 300 bash ${SUITE_PATH}"

assert_wired "空白の無い && の直前" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}&&echo ok"

assert_wired "GITHUB_WORKSPACE を頭に付けた絶対パス" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash '${DOLLAR}GITHUB_WORKSPACE/${SUITE_PATH}'"

assert_wired "github.workspace の式を頭に付けた絶対パス" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash '${DOLLAR}{{ github.workspace }}/${SUITE_PATH}'"

assert_not_wired "無関係な変数を頭に付けたパスは別のファイル" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash '${DOLLAR}FIXTURE_DIR/${SUITE_PATH}'"

assert_not_wired "リテラルの別ディレクトリ配下の同名ファイル" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash vendor/${SUITE_PATH}"

# --- env の読み出し（一覧はジョブ単位で見える） -------------------------------------

# `SHELL_FILES` に相当する折りたたみブロックを読む検査。定義したジョブ名と中身を確かめる
assert_env_block() {
    # 合成ワークフローを書き出して読み込む
    local workflow="${TMP_DIR}/env.yml"
    printf '%s\n' "$2" > "${workflow}"
    ci_workflow_load "${workflow}" "${TMP_DIR}/env-commands" \
        || { report_fail "$1" "ワークフローを読み込めませんでした"; return; }
    # 定義箇所のジョブ名と値を 1 本の文字列にまとめて突き合わせる
    local actual
    actual="$(ci_workflow_env_records def LIST | tr '\n' ',')|$(ci_workflow_env_records val LIST | tr '\n' ',')"
    # 期待値と一致するかを数える
    if [ "${actual}" = "$3" ]; then
        report 0 "$1"
    else
        report_fail "$1" "期待 [$3] に対して実際は [${actual}]"
    fi
}

assert_env_block "折りたたみの指示子が >-2 の順でも読む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    env:
      LIST: >-2
        a.sh
    steps:
      - name: subject
        run: bash ${SUITE_PATH}" "type-check,|a.sh,"

assert_env_block "ジョブの env の折りたたみブロックを読む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    env:
      LIST: >-
        a.sh
        b.sh
    steps:
      - name: subject
        run: bash ${SUITE_PATH}" "type-check,|a.sh,b.sh,"

assert_env_block "env: が steps: の後ろでも読む（キー順は自由）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}
    env:
      LIST: >-
        a.sh" "type-check,|a.sh,"

assert_env_block "ステップ固有の env は job の一覧に混ざらない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}
        env:
          LIST: >-
            step-local.sh" "|"

assert_env_block "定義が 2 か所あれば 2 件として見える（呼び出し側が弾ける）" "name: ci
jobs:
  a:
    runs-on: ubuntu-latest
    env:
      LIST: >-
        a.sh
    steps:
      - name: subject
        run: bash ${SUITE_PATH}
  b:
    runs-on: ubuntu-latest
    env:
      LIST: >-
        b.sh
    steps:
      - name: other
        run: echo hi" "a,b,|a.sh,b.sh,"

# --- コマンド単位・ステップ単位の照会 ------------------------------------------------

# `ci_workflow_command_matches` / `ci_workflow_step_matches` は、リンタの網が使う入口。
# **これらにも合成ワークフローのケースを置く**——実 ci.yml だけを入力にしていると、
# 抽出の列構成を変えたときに本文の切り出しがずれても、このファイルは何も言わない
# （実行の照会だけを固定していても、リンタ側の入口は素通しになる。レビューで指摘）
assert_matcher() {
    # 合成ワークフローを書き出して読み込む
    local workflow="${TMP_DIR}/matcher.yml"
    printf '%s\n' "$3" > "${workflow}"
    ci_workflow_load "${workflow}" "${TMP_DIR}/matcher-out" \
        || { report_fail "$2" "合成ワークフローを読み込めませんでした"; return; }
    # 第 5 引数がジョブ名の絞り込み（空なら全ジョブ）、第 6 引数以降がパターン
    local actual="no-match"
    if "$4" "$5" "${@:6}"; then actual="match"; fi
    if [ "${actual}" = "$1" ]; then
        report 0 "$2"
    else
        report_fail "$2" "期待 [$1] に対して実際は [${actual}]"
    fi
}

assert_matcher match "コマンド単位: 同じコマンドが両方のパターンを満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: shellcheck ${DOLLAR}LIST" \
    ci_workflow_command_matches "" '(^|[;&|(][[:space:]]*)shellcheck([^[:alnum:]_])' '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

assert_matcher no-match "コマンド単位: 別々のコマンドに散っていれば満たさない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: |
          echo \"list is ${DOLLAR}LIST\"
          shellcheck bin/aidock" \
    ci_workflow_command_matches "" '(^|[;&|(][[:space:]]*)shellcheck([^[:alnum:]_])' '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

assert_matcher match "ステップ単位: 2 行にまたがっていても同じステップなら満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: |
          for f in ${DOLLAR}LIST; do
              bash -n \"${DOLLAR}f\"
          done" \
    ci_workflow_step_matches "" "(^|[;&|(][[:space:]]*)for +[A-Za-z_][A-Za-z0-9_]* +in +[^;&|]*[$][{]?LIST[}]?([^[:alnum:]_]|$)" '(^|[;&|(][[:space:]]*)bash +-n([^[:alnum:]_]|$)'

assert_matcher no-match "ステップ単位: 失敗を握り潰すステップは満たさない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: |
          set +e
          for f in ${DOLLAR}LIST; do
              bash -n \"${DOLLAR}f\"
          done" \
    ci_workflow_step_matches "" "(^|[;&|(][[:space:]]*)for +[A-Za-z_][A-Za-z0-9_]* +in +[^;&|]*[$][{]?LIST[}]?([^[:alnum:]_]|$)" '(^|[;&|(][[:space:]]*)bash +-n([^[:alnum:]_]|$)'

assert_matcher match "コマンド単位: 実行ラッパ越しでも満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: sudo shellcheck ${DOLLAR}LIST" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_COMMAND_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

assert_matcher no-match "コマンド単位: if false; then の中は満たさない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: |
          if false; then
            shellcheck ${DOLLAR}LIST
          fi" \
    ci_workflow_command_matches "" '(^|[;&|(][[:space:]]*)shellcheck([^[:alnum:]_])' '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

assert_matcher no-match "ステップ単位: if false; then の中は満たさない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: |
          if false; then
            for f in ${DOLLAR}LIST; do
                bash -n \"${DOLLAR}f\"
            done
          fi" \
    ci_workflow_step_matches "" "(^|[;&|(][[:space:]]*)for +[A-Za-z_][A-Za-z0-9_]* +in +[^;&|]*[$][{]?LIST[}]?([^[:alnum:]_]|$)" '(^|[;&|(][[:space:]]*)bash +-n([^[:alnum:]_]|$)'

# 一覧を定義したジョブと、それを読むステップが**別のジョブ**にあるとき、
# 絞り込みが効いていなければ「消費されている」と誤って読める（ci_coverage_test.sh がこれに依存する）
TWO_JOB_WORKFLOW="name: ci
jobs:
  a:
    runs-on: ubuntu-latest
    env:
      LIST: >-
        x.sh
    steps:
      - name: noop
        run: echo hi
  b:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: shellcheck ${DOLLAR}LIST"

assert_matcher match "ジョブ絞り込み: 実際に居るジョブなら見つかる" "${TWO_JOB_WORKFLOW}" \
    ci_workflow_command_matches "b" '(^|[;&|(][[:space:]]*)shellcheck([^[:alnum:]_])'

assert_matcher no-match "ジョブ絞り込み: 一覧を定義した側のジョブには無い" "${TWO_JOB_WORKFLOW}" \
    ci_workflow_command_matches "a" '(^|[;&|(][[:space:]]*)shellcheck([^[:alnum:]_])'

assert_matcher no-match "ジョブ絞り込み: ステップ単位でも効く" "${TWO_JOB_WORKFLOW}" \
    ci_workflow_step_matches "a" '(^|[;&|(][[:space:]]*)shellcheck([^[:alnum:]_])'

# --- 読み込み自体が成立しない場合 --------------------------------------------------

# 実行されるコマンドが 1 つも取れないワークフローは、照合対象が空のまま
# 「差分なし＝合格」に倒れないよう、読み込み失敗として返らなければならない
assert_load_failed() {
    # 本文を一時ファイルへ書き出して読み込みを試す
    local workflow="${TMP_DIR}/degenerate.yml"
    printf '%s\n' "$2" > "${workflow}"
    # 成功が返ったらそれ自体が失敗（照合対象が空のまま緑になる）
    if ci_workflow_load "${workflow}" "${TMP_DIR}/degenerate-out" 2> /dev/null; then
        report_fail "$1" "実行されるコマンドが無いのに読み込み成功が返った（空の照合対象で「差分なし＝合格」に倒れる）"
    else
        report 0 "$1"
    fi
}

# --- ここから: 28 巡目のレビューで検出した取りこぼし（いずれも握り潰しを「ゲート」と読む向き）---

# 区切り語はシェルの識別子より広い。`EOF-1` を `EOF` と読むと終端に出会えず、
# 本文がコマンドとして読まれる（ファイルへ書き出しているだけの呼び出しが「配線」に化ける）
assert_not_wired "記号を含む区切り語の heredoc 本文は実行ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<'EOF-1' > note.txt
          bash ${SUITE_PATH}
          EOF-1"

# 数字で始まる区切り語も有効（シェルの識別子の規則は区切り語には掛からない）
assert_not_wired "数字で始まる区切り語の heredoc 本文は実行ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<'1EOF' > note.txt
          bash ${SUITE_PATH}
          1EOF"

# 逆向きも押さえる: 区切り語を縮めて読むと終端に出会えず、heredoc の**後ろ**にある
# 本物の呼び出しまで本文として捨てられ、「配線されていない」と事実と逆に診断される
assert_wired "記号を含む区切り語の heredoc の後ろの呼び出しは実行である" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<'EOF-1' > note.txt
          hello
          EOF-1
          bash ${SUITE_PATH}"

# 鍵を囲む引用符 2 つで既定シェルの検出をすり抜けられない
assert_not_wired "ワークフロー既定の defaults: は鍵が引用符付きでも効く" 'name: ci
"defaults":
  run:
    shell: bash {0}
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash '"${SUITE_PATH}"

assert_not_wired "ワークフロー既定の shell: は鍵が引用符付きでも効く" 'name: ci
defaults:
  run:
    "shell": bash {0}
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash '"${SUITE_PATH}"

# grouping を開いた断片そのものに呼び出しが載る形（`(` と呼び出しが同じ断片）
assert_not_wired "grouping を開いた断片の呼び出しにも閉じ側の区切りが掛かる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: ( bash ${SUITE_PATH}; ) || true"

# 部分シェルの中の set は外へ漏れない（ブレースグループは漏れる）
assert_not_wired "部分シェルの中の set -e は外の set +e を打ち消さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          (
            set -e
          )
          bash ${SUITE_PATH}"

assert_wired "ブレースグループの中の set -e は外へ効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          {
            set -e
          }
          bash ${SUITE_PATH}"

# POSIX の長い綴り
assert_not_wired "set +o errexit も握り潰しとして効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +o errexit
          bash ${SUITE_PATH}"

assert_wired "set -o errexit は set +e を打ち消す" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          set -o errexit
          bash ${SUITE_PATH}"

# 向きが変わる連鎖: `&&` が外れた後の `||` の右は走る
assert_wired "false && … || 呼び出し は実行される" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: false && echo mid || bash ${SUITE_PATH}"

assert_wired "true || … && 呼び出し は実行される" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: true || echo skipped && bash ${SUITE_PATH}"

# 既存の伝播（連鎖が同じ向きのまま続く形）は変わらない
assert_not_wired "false && … && 呼び出し は実行されない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: false && echo mid && bash ${SUITE_PATH}"

assert_load_failed "空のワークフローは読み込み失敗として返る" ""

assert_load_failed "run: を 1 つも持たないワークフローは読み込み失敗として返る" 'name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# --- ヒアドキュメントの終端判定（bash と同じ厳しさで読む / issue #108）------------------
#
# 終端の判定が bash より緩いと、**本文（＝実行されない文字列）が「実行されるコマンド」に化ける**。
# `ci_coverage_test.sh` の「全スイートが実行されるか」の網はこの記録を根拠に判定するので、
# ワークフローから外されたスイートが、ヒアドキュメントの中で名前を挙げられているだけで
# 「実行されている」と通る——このライブラリが塞ぐために作られた「不在＝合格」そのものの形になる。


# `<<-` はスペース字下げされた区切り語を終端と認めない（落とすのはタブだけ）。
# 認めてしまうと、本文の途中で読み飛ばしが終わり、以降の本文が実行と読まれる
assert_not_wired "<<- でもスペース字下げされた区切り語は終端ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat > note.txt <<-MARK
          one
            MARK
          bash ${SUITE_PATH}
          MARK"

# bash は「区切り語だけの行」しか終端と認めない。行末コメントが付いた行は本文のまま。
# コメントを剥がしてから照合すると、ここで読み飛ばしが終わって以降の本文が実行と読まれる
assert_not_wired "行末コメントの付いた区切り語は終端ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<MARK > note.txt
          MARK # ここはまだ本文
          bash ${SUITE_PATH}
          MARK"

# 逆向きも押さえる: 締めすぎると本物の終端に出会えず、heredoc の**後ろ**にある実行まで
# 本文として捨てられ、「配線されていない」と事実と逆に診断される。
# `<<-` のタブ字下げは bash が落とすので、これは正しく終端である
assert_wired "<<- のタブ字下げされた区切り語は終端である" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat > note.txt <<-MARK
          one
          ${TAB}MARK
          bash ${SUITE_PATH}"

# 字下げを落とす基準は**ブロックスカラーの基準字下げ**（＝最初の非空行）であって、
# ヒアドキュメントを開いた行の桁ではない。開いた行を基準にすると、`if …; then` の中など
# 基準より深い位置で開いたときに落としすぎ、本文中の字下げされた区切り語まで終端と読む。
# 実際の bash は基準分しか落とさないので `  MARK` は本文のままで、後ろの行も本文
assert_not_wired "入れ子で開いた heredoc は深い字下げの区切り語で終端しない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then
            cat <<MARK
          body
            MARK
          bash ${SUITE_PATH}
          MARK
          fi"

# **`<<-` かどうかの区別そのものを固定する。** タブを落とすのは `<<-` のときだけで、
# 素の `<<` はタブ字下げされた区切り語を終端と認めない（bash で実測）。
# この対が無いと `if (dash)` のガードを消しても全件緑のまま通り、区別が削除可能になる
assert_not_wired "素の << はタブ字下げされた区切り語を終端と認めない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<MARK
          one
          ${TAB}MARK
          bash ${SUITE_PATH}
          MARK"

# **「区切り語ちょうど」の末尾側も固定する。** bash は `MARK ` を終端と認めない。
# 比較の前に右トリムを足すと通ってしまうが、末尾空白は目に見えないぶん実際の
# ワークフローに混入しやすく、混入した瞬間に本文が「実行されたコマンド」に化ける
assert_not_wired "行末に空白が付いた区切り語は終端ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<MARK
          MARK${SPACE}
          bash ${SUITE_PATH}
          MARK"

# **明示字下げ指示子（`run: |2`）があれば基準字下げはそちらが決める。**
# YAML は指示子の桁までしか落とさないので、本文をそれより深く書くと深い分は内容に残り、
# `  MARK` は終端ではない。最初の非空行から基準を決めると落としすぎてここが穴になる
assert_not_wired "明示字下げ指示子つきブロックでは深い区切り語は終端ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |2
            cat <<MARK
            one
            MARK
            bash ${SUITE_PATH}"

# **指示子の基準は「鍵の桁」であって「ダッシュの桁」ではない。** `- run: |2` では
# `run` の桁（8）に 2 を足した 10 が内容の字下げになる。ダッシュの桁（6）から数えると
# 基準が 2 桁浅く出て本物の終端を見落とし、後ろの呼び出しまで本文として捨てる。
# 上の `|2` のケースはダッシュの無い書き方なので、この区別はここでしか固定されない
assert_wired "ダッシュ付きの鍵でも指示子の基準は鍵の桁から数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - run: |2
          cat <<MARK
          one
          MARK
          bash ${SUITE_PATH}"

# タブは YAML の字下げではなく**内容の一部**（YAML は字下げにタブを使えない）。
# 基準字下げをタブまで含めて測ると後で落としすぎ、素の `<<` でタブ字下げされた
# 区切り語を終端と読んで、以降の本文が実行と読まれる（レビューで実測）
# 区切り語は**基準より 1 桁だけ深く**置くのが要点。基準と同じ桁に置くと、タブを
# 字下げに数えても数えなくても落とす量が同じに丸まってしまい、この規則を固定できない
# （基準と同じ桁のケースは上の「素の << はタブ字下げ…」が別途押さえている）
assert_not_wired "本文先頭のタブは字下げではないので基準字下げに数えない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${TAB}echo hi
          cat <<MARK
          one
           MARK
          bash ${SUITE_PATH}
          MARK"

# **基準字下げはステップをまたいで持ち越さない。** `run:` ブロックごとに測り直さないと、
# 前のステップの深い基準が残って次のステップで落としすぎ、本文中の区切り語を終端と読む。
# 前段の `|6` は基準 14 桁、後段は 10 桁なので、持ち越すと 12 桁の区切り語が終端に化ける
assert_not_wired "基準字下げは run: ブロックごとに測り直す（前段から持ち越さない）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: earlier
        run: |6
              echo hi
      - name: subject
        run: |
          cat <<MARK
          one
            MARK
          bash ${SUITE_PATH}
          MARK"

# 逆向きの歯止め: 基準字下げに置かれた区切り語はちゃんと終端で、その後ろの呼び出しは実行。
# 落とす量を「開いた行の桁」から絞ったせいで本物の終端を見落とすと、ここが赤くなる
assert_wired "入れ子で開いた heredoc も基準字下げの区切り語で終端する" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then
            cat <<MARK
          body
          MARK
          bash ${SUITE_PATH}
          fi"

# --- ヒアドキュメントの「開き方」の読み取り（issue #110 / #111）------------------------
#
# 終端（上の節）と同じくらい、**どこで開いたか・区切り語は何か**の読み取りも合否を左右する。
# 開き方を読み違えると、本文（＝実行されない文字列）が「実行されるコマンド」に化けるか、
# 逆に実行している呼び出しが本文として捨てられる。以下の期待値はすべて**実際の bash**で
# 確かめてある（heredoc の本文を /dev/null へ捨て、副作用のあるコマンドが走ったかで判定）。

# 1 行に 2 つ開いたとき、bash は**先に書いた方の本文を先に**読む。区切り語を 1 つしか
# 覚えないと、A の本文の中に現れた `B` で読み飛ばしを終え、まだ A の本文である行を
# 実行として記録する（issue #111 (1)）
assert_not_wired "1 行に 2 つ開いた heredoc の、先に読まれる本文" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<A > a.txt; cat <<B > b.txt
          B
          bash ${SUITE_PATH}
          A
          B"

# 逆向きの歯止め: 2 つとも終端した**後ろ**の呼び出しは実行である。
# 待ち行列を消化しきれないと、ここが「配線されていない」と事実と逆に診断される
assert_wired "1 行に 2 つ開いた heredoc の、両方の本文の後ろの呼び出し" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<A > a.txt; cat <<B > b.txt
          one
          A
          two
          B
          bash ${SUITE_PATH}"

# 空の区切り語（`<<\"\"`）も bash では正当な heredoc で、本文は**空行**で終わる。
# 開いたと認識できないと、本文がそのまま実行として記録される（issue #111 (2)）
assert_not_wired "空の区切り語（<<\"\"）の本文" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<\"\" > note.txt
          bash ${SUITE_PATH}

          echo done"

# 逆向きの歯止め: 空行で終端した後ろの呼び出しは実行である
assert_wired "空の区切り語（<<\"\"）の本文を終える空行の後ろ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<\"\" > note.txt
          one

          bash ${SUITE_PATH}"

# `<<-` のタブ剥がしは**その区切り語だけ**に効く。行のどこかに `<<-` があるかで決めると、
# 同じ行の素の `<<` の終端判定にまで伝染し、タブ字下げされた行を終端と読んで
# まだ本文である行を実行として記録する（issue #111 (3)）
assert_not_wired "<<- と素の << が同じ行にあるとき、タブ剥がしは素の << に伝染しない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<-A > a.txt; cat <<B > b.txt
          ${TAB}B
          bash ${SUITE_PATH}
          A
          B"

# 逆向きの歯止め: `<<-` を付けた当の区切り語には、ちゃんとタブ剥がしが効く。
# 効かないと A の本文が終わらず、後ろの呼び出しまで捨てられる
assert_wired "<<- を付けた区切り語自身にはタブ剥がしが効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<-A > a.txt; cat <<B > b.txt
          ${TAB}A
          B
          bash ${SUITE_PATH}"

# バックスラッシュ引用の区切り語（`<<\\MARK`）は bash では `<<'MARK'` と同じ扱い。
# 引用を潰す処理に先に食われて区切り語が `ARK` に化けると、終端に一生出会えず
# **本文の後ろの実行まで捨てる**（issue #110・向きは fail-closed）
assert_wired "バックスラッシュ引用の区切り語（<<\\MARK）の本文の後ろの呼び出し" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<\\MARK > note.txt
          one
          MARK
          bash ${SUITE_PATH}"

# 対になる向き: `<<\\MARK` の**本文の中**の呼び出しは実行ではない。
# 引用の綴りが変わっても本文が本文として読まれることを固定する
assert_not_wired "バックスラッシュ引用の区切り語（<<\\MARK）の本文" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cat <<\\MARK > note.txt
          bash ${SUITE_PATH}
          MARK"

# --- 構造行の書き出し（`emit_structural_lines`）の契約 -----------------------------
#
# **この共有トークナイザの規則を、消費側の正規表現越しでなく直接固定する。**
# issue #93 の対応で入れた「引用に囲まれたスカラーの中のフロー区切りを伏せる」処理は、
# これまで `action_pin_test.sh` の位置規則を通してしか検査されていなかった。つまり伏せる処理を
# 丸ごと消しても、このスイートも網羅性検査も緑のままだった（実測）。トークナイザの契約が
# 消費側 1 つの実装詳細に人質を取られている状態なので、ここで直接押さえる。

# 合成したワークフローを `emit_structural_lines` に通し、指定した行の内容を返す
structural_line() {
    # 引数を意味の分かる名前に取り出す（本文と、取り出したい行番号）
    local body="$1" lineno="$2"
    # 合成ワークフローを一時ファイルへ書き出す
    printf '%s\n' "${body}" > "${TMP_DIR}/structural.yml"
    # 構造行を書き出し、目的の行だけを取り出して行番号の接頭辞を落とす
    emit_structural_lines "${TMP_DIR}/structural.yml" | awk -F: -v n="${lineno}" '
        $1 == n { sub(/^[0-9]+:/, ""); print; exit }'
}

# 構造行が期待どおりかを数える。第 1 引数がケース名、第 2 引数が期待する内容、
# 第 3 引数がワークフロー本文、第 4 引数が見たい行番号
assert_structural_line() {
    # 実際に書き出された行を取る
    local actual
    actual="$(structural_line "$3" "$4")"
    # 期待と一致すれば合格、違えば両方を見せて落とす
    if [ "${actual}" = "$2" ]; then
        report 0 "$1"
    else
        report_fail "$1" "期待«$2» に対して «${actual}» が書き出された"
    fi
}

# 引用の中の読点は構造ではないので、代役の文字へ伏せて書き出す（幻の参照を作らないため）
assert_structural_line "引用された手順名の読点は伏せられる" \
    '      - name: compare pinning~ uses: policy' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: "compare pinning, uses: policy"' 6

# 伏せる文字は読点だけではない。**波括弧・角括弧も同じく構造としてしか意味を持たない**ので、
# 引用の中にあれば伏せる。ここを読点だけに絞ると `- name: "a{uses: policy}"` で幻の参照が戻り、
# `- name: "Rotate {secrets: prod}"` は特権判定を read-only から privileged へ倒してしまう
# （実測: `flow_re` を `[,]` に狭める変異は、この 1 件を足す前は全スイート緑のまま通った）
assert_structural_line "引用された値の中の波括弧も伏せられる" \
    '      - name: a~uses: policy~' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: "a{uses: policy}"' 6

# 角括弧も同様（フロー並びの開き・閉じとして読まれないようにする）
assert_structural_line "引用された値の中の角括弧も伏せられる" \
    '      - name: a~uses: policy~' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: "a[uses: policy]"' 6

# 引用の中の `#` も伏せる。YAML でコメントを始めるのは引用の外の `#` だけなのに、
# 引用符を落とした後の行を見る消費側にはその区別が付かないため、ここで決める
# （伏せないと特権判定が値の中の `#` で行を切り、後ろの `secrets:` を捨てて fail-open になる）
assert_structural_line "引用された値の中の # も伏せられる" \
    '      - name: a: ~b' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: "a: #b"' 6

# 逆に、**引用の外の `#` はコメントの印なので伏せない**（版注記の取り出しがここに依存している）
assert_structural_line "引用の外の # はそのまま残る" \
    '      - uses: a/b@v1  # v1' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: a/b@v1  # v1' 6

# 伏せるのは区切り文字だけで、引用された値の綴りには触れない（参照を読めなくしないため）
assert_structural_line "引用された uses: の値はそのまま残る" \
    '      - uses: actions/checkout@v7' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: "actions/checkout@v7"' 6

# 素のスカラー途中のアポストロフィは引用の開始ではないので、後ろの区切りは生きたまま残る
assert_structural_line "素のスカラー途中のアポストロフィでは伏せない" \
    '      - {name: dont, uses: actions/evil@v1, desc: its fine}' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - {name: don'"'"'t, uses: actions/evil@v1, desc: it'"'"'s fine}' 6

# 行内で閉じない引用は伏せずに従来の姿へ倒す（本物の区切りを隠さないため）
assert_structural_line "閉じない引用は伏せずにそのまま出す" \
    '      - {name: oops, uses: actions/evil@v1' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - {name: "oops, uses: actions/evil@v1' 6

# **引用符は 1 つも書き出さない。** 消費側（`scan_workflow_structure`）はこの前提のもとで
# `"permissions":` と `permissions:` を同じ形として扱っている。ここが崩れると、崩れ方は
# 「特権ワークフローを非特権と誤判定する」向き（fail-open）なので、契約として明示的に固定する
quote_free_body='name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: "a, b"
      - name: '"'"'c, d'"'"'
      - name: "say \"hi\""
      - name: '"'"'don'"'"''"'"'t'"'"'
      - {"name":"e, f", "uses": ./local}
      - name: "unclosed, g'
printf '%s\n' "${quote_free_body}" > "${TMP_DIR}/quote-free.yml"
# **まず出力を受け取ってから判定する。** `| grep -q` に直接つなぐと、解析器が壊れて 1 行も
# 出さなくなった場合も「引用符が見つからない＝合格」になり、**このスイートが守るはずの
# fail-open をそのまま見逃す**（＝「不在＝合格」。このリポジトリが繰り返し塞いできた形）
quote_free_out="$(emit_structural_lines "${TMP_DIR}/quote-free.yml")"
# 何も出てこないのは解析器の異常なので、引用符の有無を見るより先に落とす
if [ -z "${quote_free_out}" ]; then
    report_fail "構造行に引用符を 1 つも残さない" \
        "構造行が 1 行も書き出されなかった（解析器が壊れています。引用符の有無以前の失敗）"
elif printf '%s\n' "${quote_free_out}" | grep -q "['\"]"; then
    report_fail "構造行に引用符を 1 つも残さない" \
        "書き出された構造行に引用符が残っている（消費側の正規化の前提が崩れ、特権判定が fail-open になる）"
else
    report 0 "構造行に引用符を 1 つも残さない"
fi

# 存在しないファイルも同じ扱い（読めないまま先へ進ませない）
if ci_workflow_load "${TMP_DIR}/does-not-exist.yml" "${TMP_DIR}/missing-out" 2> /dev/null; then
    report_fail "存在しないワークフローは読み込み失敗として返る" "読めないファイルなのに成功が返った"
else
    report 0 "存在しないワークフローは読み込み失敗として返る"
fi

# 集計を出して、失敗が 1 件でもあれば非ゼロで終わる
harness_summary
