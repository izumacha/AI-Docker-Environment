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

assert_not_wired "条件付きブロックを閉じた fi に付いた || true" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}X\" ]; then
            bash ${SUITE_PATH}
          fi || true"

assert_not_wired "ループを閉じた done に付いた || true" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for f in a; do
            bash ${SUITE_PATH}
          done || true"

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

# --- 制御構造の中の `set`（issue #113。`+` と `-` を非対称に扱う） -------------------
#
# 穴の側と締めすぎの側を対で置く。期待値は実 bash との差分照合で確かめてある
# （`bash -e` で走らせ、スイート呼び出しの**後ろに置いた成功コマンドまで届くか**という
#  副作用で判定する。`set +e` は「落ちても続行」であって最後の終了コードを捨てはしないので、
#  呼び出しが最終行のままだと握り潰されていても script は 1 で終わり、両者を区別できない）。

# 穴の側: `$CI` は GitHub Actions で**常に設定されている**ので、この `set +e` は必ず走る。
# 以前はこれを「走るか分からない」として無視しており、3 行足すだけでスイートの失敗を
# 握り潰しながら全表明を緑のまま通せた（`continue-on-error: true` と同じ効果）
assert_not_wired "通るか分からない分岐の set +e も握り潰しとして数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}CI\" ]; then
            set +e
          fi
          bash ${SUITE_PATH}"

# 締めすぎの側（許容している代償）: この分岐は通らないかもしれないので、実際には
# ゲートしている可能性がある。それでも「未配線」と読むのは、外したときに CI が赤くなって
# 人が見る fail-closed 側だから。**この期待値が緑のまま裏返ったら穴が開いている**
assert_not_wired "通らないかもしれない分岐の set +e は安全側に倒して数える" "name: ci
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

# 強める向きは非対称に扱う: 制御構造の中の `set -e` は今までどおり反映しない。
# 反映すると、通らない分岐の `set -e` が外側の握り潰しを隠す（fail-open）
assert_not_wired "通るか分からない分岐の set -e は握り潰しを打ち消さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          if [ -n \"${DOLLAR}CI\" ]; then
            set -e
          fi
          bash ${SUITE_PATH}"

# 長い綴り（POSIX 形式）でも同じ非対称性が効くことを固定する
assert_not_wired "制御構造の中の set +o errexit も握り潰しとして数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}CI\" ]; then
            set +o errexit
          fi
          bash ${SUITE_PATH}"

# 偽と分かるブロックの中は、弱める向きでも反映しない（1 度も走らないため）。
# ここを一緒に緩めると、ゲートしているステップを「未配線」と誤報して赤くする
assert_wired "一度も走らない分岐の set +e は反映しない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if false; then
            set +e
          fi
          bash ${SUITE_PATH}"

# 部分シェルの中は、弱める向きでも外へ漏らさない（子シェルのオプション変更のため）
assert_wired "部分シェルの中の set +e は外へ漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( set +e )
          bash ${SUITE_PATH}"

# pipefail も弱める向きは制御構造の中から反映する。
# 反映しないと、パイプ越しの失敗が伝わらないステップを「伝わる」と読む
assert_not_wired "制御構造の中の set +o pipefail はパイプの伝播を止める" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -o pipefail
          if [ -n \"${DOLLAR}CI\" ]; then
            set +o pipefail
          fi
          bash ${SUITE_PATH} | tee log"

# --- 1 行で書いた `set`（意味が変わらない書き換えで穴が開かないこと） ----------------
#
# `split_commands` が `;` で切るため、断片の本文は `then set +e` / `do set +e` になる。
# `^set` だけで探すと当たらず、**同じ意味を 1 行に畳むだけ**で握り潰しが見えなくなる

assert_not_wired "1 行の if …; then set +e; fi も握り潰しとして数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}CI\" ]; then set +e; fi
          bash ${SUITE_PATH}"

assert_not_wired "1 行の for …; do set +e; done も握り潰しとして数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for i in 1; do set +e; done
          bash ${SUITE_PATH}"

# ブレースグループは条件を持たず**無条件に走る**ので、これを見落とすと
# 1 行足すだけで確実にゲートを外せる（分岐より短い最悪の綴り）
assert_not_wired "ブレースグループの中の set +e は無条件に効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { set +e; }
          bash ${SUITE_PATH}"

# `if false` の**else 側は必ず走る**。偽の印を持ち越すと 1 行で握り潰しを隠せる
assert_not_wired "偽と分かる条件の else 側の set +e は効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if false; then :; else set +e; fi
          bash ${SUITE_PATH}"

# 締めすぎの側: `then` を剥がすのは `set` を探すときだけで、
# **実行の照会には持ち込まない**（条件部の中身が走るかは条件次第のため）
assert_not_wired "1 行の then の後ろの呼び出しは実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}CI\" ]; then bash ${SUITE_PATH}; fi"

# --- 関数定義の本文（その場では走らない） ------------------------------------------

# 定義しただけでは本文は 1 度も走らないので、弱める向きでも反映しない。
# 反映すると `cleanup() { set +e; … }` という定型句だけで CI が赤いままになる
assert_wired "関数定義の中の set +e は定義した時点では効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          cleanup() {
            set +e
            rm -rf tmp
          }
          bash ${SUITE_PATH}"

# --- 1 語の中のオプションの並び順（bash は左から右へ適用する） ----------------------

# `set +e -e` は最後の `-e` が勝つ＝ゲートする。並び順を落とすと
# 実際にはゲートしているステップを「未配線」と誤報して赤くする
assert_wired "set +e -e は後ろの -e が勝つ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e -e
          bash ${SUITE_PATH}"

assert_not_wired "set -e +e は後ろの +e が勝つ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -e +e
          bash ${SUITE_PATH}"

# 短い綴りの並びの**末尾が `o`** なら、次の語が長い綴りの名前になる（`-euo pipefail`）
assert_wired "set -euo pipefail は pipefail まで立てる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -euo pipefail
          bash ${SUITE_PATH} | tee log"

assert_not_wired "set +euo pipefail は pipefail まで落とす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -o pipefail
          set +euo pipefail
          bash ${SUITE_PATH} | tee log"

# `--` から後ろは位置パラメータであってオプションではない
assert_wired "set -- +e は位置パラメータであってオプションではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -- +e
          bash ${SUITE_PATH}"

# 短い綴りの並びの **`o` はどこにあってもよい**。bash は `-oe pipefail` を
# `-eo pipefail` と同じに扱うので、末尾だけを見ると pipefail を取りこぼす
assert_wired "set -oe pipefail も pipefail まで立てる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -oe pipefail
          bash ${SUITE_PATH} | tee log"

# --- 命令の位置に置けない `set`（綴りを網羅しきれない側の受け皿） ------------------
#
# ブロックを開く語は入れ子になるし、`case` のアームは語ですらない。
# 綴りを 1 つずつ足す限り必ず漏れるので、**置けなかった `set` は
# 「弱める向きだけ反映する」** に倒す（強める向きは決して信用しない）

assert_not_wired "1 行の then の中のブレースグループの set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}CI\" ]; then { set +e; }; fi
          bash ${SUITE_PATH}"

assert_not_wired "1 行の case アームの中の set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case \"${DOLLAR}RUNNER_OS\" in Linux) set +e ;; esac
          bash ${SUITE_PATH}"

# 締めすぎの側: 引用符の中の言及は `set` ではない。
# 反映すると、ゲートしているステップを「未配線」と誤報して赤くする
assert_wired "引用符の中の set +e は言及であって実行ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          echo \"remember to set +e here\"
          bash ${SUITE_PATH}"

# 部分シェルは 1 行で開いて閉じても外へ漏れない（この時点ではまだ深さが増えていない）
assert_wired "1 行の ( set +e ) も外へ漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( set +e )
          bash ${SUITE_PATH}"

# --- 連鎖に守られた `set -e`（強める向きを信用してよい条件） ------------------------

# `&&` の右は条件次第でしか走らないのに `uncertain` は 0 のまま。
# ここで強める向きを信用すると、握り潰しを打ち消したように見える（fail-open）
assert_not_wired "&& で守られた set -e は握り潰しを打ち消さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          [ -z \"${DOLLAR}FORCE\" ] && set -e
          bash ${SUITE_PATH}"

# --- 真と分かる条件の else 側（必ず走らない） --------------------------------------

# `if true` は本体が確実に走るので `uncertain` を立てない。印を付けないと
# else 側の中身が「最上位で確実に走る」ように見え、1 度も走らない呼び出しが
# 実行の証拠に化ける（`set +e` 側は逆に握り潰しを誤って数える）
assert_not_wired "真と分かる条件の else 側の呼び出しは実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then
            :
          else
            bash ${SUITE_PATH}
          fi"

assert_wired "真と分かる条件の else 側の set +e は効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then :; else set +e; fi
          bash ${SUITE_PATH}"

# `elif` を挟んでも印は残る。**偽の解除を先に見ると**、直前に付けた
# 「真と分かる条件だから走らない」印が 2 語足すだけで解除される
assert_not_wired "真と分かる条件は elif を挟んでも残りのアームが走らない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          if true; then :; elif [ -n \"${DOLLAR}X\" ]; then :; else set -e; fi
          bash ${SUITE_PATH}"

# --- 子シェルで走る `set`（親のオプションは変わらない） ------------------------------

# パイプの構成要素は子シェルなので、親の握り潰しは打ち消されない
assert_not_wired "パイプの中の set -e は親の握り潰しを打ち消さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          true | set -e
          bash ${SUITE_PATH}"

# バックグラウンドも同じく子シェル
assert_not_wired "バックグラウンドの set -e は親の握り潰しを打ち消さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          set -e &
          wait
          bash ${SUITE_PATH}"

# --- 部分シェルの判定は「釣り合い」で行う ------------------------------------------

# `case` のアームは POSIX で先頭に `(` を書ける。単に `(` の有無で部分シェルと
# 見なすと、1 文字足すだけで握り潰しが見えなくなる
assert_not_wired "先頭に ( を書いた case アームの set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -e
          case \"${DOLLAR}RUNNER_OS\" in
          (Linux) set +e ;;
          esac
          bash ${SUITE_PATH}"

# --- 引用符付きのオプション（bash には同じ意味） ------------------------------------

assert_not_wired "set \"+e\" は set +e と同じ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set \"+e\"
          bash ${SUITE_PATH}"

# --- 1 行で書いた関数定義（本文はその場では走らない） -------------------------------

# `{` の後ろに本文が続く綴りも定義として数える。数えないと、定義しただけの
# `set +e` が外で走ったように扱われ、ゲートしているステップが赤くなる
assert_wired "1 行の function f { set +e; } は定義しただけ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          function f { set +e; }
          bash ${SUITE_PATH}"

assert_wired "1 行の f() { set +e; } も定義しただけ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          bash ${SUITE_PATH}"

# 見出しと `{` が別の行に分かれた綴りも定義。**どちらも開き側に数えると**
# 2 つ開いて 1 つしか閉じず、以降ずっと入れ子の中に見える（深さも fndef も戻らないので、
# 後続の呼び出しが「未配線」と誤報され、後続の set +e も黙って無視される）
assert_wired "function 見出しの次の行の { も 1 階層だけ開く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          function f
          {
            :
          }
          bash ${SUITE_PATH}"

assert_wired "見出しが別行の関数の中の set +e は定義しただけ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f()
          {
            set +e
          }
          bash ${SUITE_PATH}"

# --- 定義した関数を「呼んだ」場合（issue #120 (2)） ---------------------------------
#
# 上の節は「定義しただけでは走らない」を固定している。その理由付けは**呼ばれた時点で
# 成り立たなくなる**——関数はシェルを共有するので、本文の `set +e` はそのまま呼び出し元へ
# 漏れる。呼び出しを追跡しないと **2 行でスイートの失敗を握り潰せる**（issue #113 が塞いだ
# `if [ -n "$CI" ]; then set +e; fi` と同じ規模の抜け道。fail-open）。
# 期待値はすべて実 `bash -e` との差分照合で確かめてある。
# **対にして置く**のが要点で、片方だけだと「呼び出しを一切見ない」実装でも
# 「常に反映する」実装でも半分が緑になり、検出網として働かない。

# 呼ばれた時点で握り潰しが効く（3 綴りすべてで同じ答えになること）
assert_not_wired "1 行で定義した関数を呼ぶと本文の set +e が効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          f
          bash ${SUITE_PATH}"

assert_not_wired "複数行で定義した関数を呼ぶと本文の set +e が効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() {
            set +e
          }
          f
          bash ${SUITE_PATH}"

assert_not_wired "function 綴りで定義した関数を呼んでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          function f { set +e; }
          f
          bash ${SUITE_PATH}"

# 長い綴りでも同じ。片方だけ控えると、`+e` を `+o errexit` に書き換えるだけで素通りする
assert_not_wired "set +o errexit を持つ関数を呼んでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +o errexit; }
          f
          bash ${SUITE_PATH}"

# 引数付きの呼び出しも呼び出し（`f` だけを呼び出しと読むと 1 語足すだけで素通りする）
assert_not_wired "引数を付けて呼んでも本文の set +e が効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          f --verbose tmp
          bash ${SUITE_PATH}"

# 継続語の後ろの呼び出しも呼び出し。`then` を関数名と読むと 3 行で素通りする
assert_not_wired "then の後ろで呼んでも本文の set +e が効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          if [ -n \"${DOLLAR}CI\" ]; then f; fi
          bash ${SUITE_PATH}"

# pipefail も同じ扱い（errexit だけ見ると、パイプ越しの失敗が伝わらないまま緑になる）
assert_not_wired "set +o pipefail を持つ関数を呼ぶとパイプ越しの失敗が伝わらない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -eo pipefail
          f() { set +o pipefail; }
          f
          bash ${SUITE_PATH} | cat"

# --- 呼び出しを「見すぎない」側（反映してはいけない綴り） ---------------------------
#
# ここが緑でないと、走らない握り潰しを反映して**ゲートしているステップを赤くする**
# （fail-closed 側の誤報。CI が恒常的に赤くなって検出網ごと信用されなくなる）

# 名前が違えば効かない（前方一致で拾うと、無関係な `foobar` で赤くなる）
assert_wired "名前の前半だけが一致する呼び出しでは効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          foobar || true
          bash ${SUITE_PATH}"

# 代入は呼び出しではない（`f=1` を呼び出しと読むと、同名の変数を置くだけで赤くなる）
assert_wired "同じ名前への代入は呼び出しではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          f=1
          bash ${SUITE_PATH}"

# 部分シェルの中の呼び出しは親のオプションを変えない（`set` 本体と同じ扱い）
assert_wired "部分シェルの中で呼んでも親には漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          ( f )
          bash ${SUITE_PATH}"

# パイプの構成要素も子シェル
assert_wired "パイプの構成要素として呼んでも親には漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          f | cat
          bash ${SUITE_PATH}"

# 走らないと分かるブロックの中の呼び出しは反映しない
assert_wired "if false の中で呼んでも効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          if false; then f; fi
          bash ${SUITE_PATH}"

# 別の関数の本文にある呼び出しは、その関数が呼ばれない限り走らない
assert_wired "呼ばれない関数の本文にある呼び出しは効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          g() { f; }
          bash ${SUITE_PATH}"

# 呼び出しの後ろの `set -e` は握り潰しを打ち消す（`set +e` を書いた場合と同じ）
assert_wired "呼び出しの後ろの set -e が打ち消す" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          f
          set -e
          bash ${SUITE_PATH}"

# **強める向きは呼び出しでも信用しない。** 実 bash はここでゲートするが、
# 反映すると「呼ばれるとは限らない関数の `set -e`」が外側の握り潰しを隠せてしまう
# （fail-open）。`set` 本体で採っている非対称の扱いと揃え、fail-closed 側へ倒す
assert_not_wired "本文が set -e の関数を呼んでも強める向きは credit しない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          f() { set -e; }
          f
          bash ${SUITE_PATH}"

# --- 呼び出しの綴り（`set` を探すときと同じ飾りを落とす） ---------------------------
#
# 飾りの一覧を呼び出し側だけ狭く持つと、**その綴りに書き換えるだけで追跡が外れる**。
# `{ f; }` は 2 文字の抜け道だった（レビューで実測。fail-open）。
# 期待値はすべて実 `bash -e` との差分照合で確かめてある。

assert_not_wired "ブレースグループ越しの呼び出しでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          { f; }
          bash ${SUITE_PATH}"

assert_not_wired "! を前置きした呼び出しでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          ! f
          bash ${SUITE_PATH}"

assert_not_wired "eval 越しの呼び出しでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          eval f
          bash ${SUITE_PATH}"

assert_not_wired "time 越しの呼び出しでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          time f
          bash ${SUITE_PATH}"

assert_not_wired "変数代入を前置きした呼び出しでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          VERBOSE=1 f
          bash ${SUITE_PATH}"

# **`command` / `builtin` はシェル関数の探索を飛ばす綴り**なので、落としてはいけない。
# 落とすと `command f` を関数 f の呼び出しと読み、実際には走らない握り潰しを反映して
# ゲートしているステップを赤くする（実 bash と差分照合して実測）
assert_wired "command 経由は関数の呼び出しではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          command f || true
          bash ${SUITE_PATH}"

assert_wired "builtin 経由は関数の呼び出しではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          builtin f || true
          bash ${SUITE_PATH}"

# --- 間接的な呼び出し（既知の限界。`main` と同じ扱い） -----------------------------
#
# **これは「塞げていない」ことを固定する節**。関数を 1 つ挟んだ握り潰し
# （`f() { set +e; }` / `g() { f; }` / `g`）は実 bash では効くが、ここでは反映しない。
#
# 一度は呼び出し関係をたどって伝播させる実装を入れたが、**関数の本文は「弱める／戻す」が
# 起きた順序で結果が決まる**（`main() { set -e; relax; }` と `f() { g; set -e; }` は
# 同じ材料でも答えが逆になる）。順序を持たない台帳で近似すると、伝播を許せば握り潰しを
# 見落とし（fail-open）、伝播を止めれば正しくゲートしているステップを赤くする
# （fail-closed）——どちらの向きにも実際に外し、レビューで 3 巡続けて回帰を出した。
# **間接の追跡は順序付きの解析として別途入れる**ことにし（issue #123）、ここでは
# 現状の答えを固定して、直したときにこの節ごと見直されるようにしておく。

assert_wired "既知の限界: 関数を 1 つ挟んだ呼び出しは追えない（未対応）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          g() { f; }
          g
          bash ${SUITE_PATH}"

assert_wired "既知の限界: 関数を 2 つ挟んだ呼び出しは追えない（未対応）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          g() { f; }
          h() { g; }
          h
          bash ${SUITE_PATH}"

# 呼び元を先に書いても答えが変わらない（記録した時点ではなく呼び出しの時点で畳むため）
assert_wired "既知の限界: 呼び元を先に定義しても間接も追えない（未対応）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          h() { g; }
          g() { f; }
          f() { set +e; }
          h
          bash ${SUITE_PATH}"

# 締めすぎの側: 間接的にしか繋がっていなくても、**呼ばれなければ**効かない
assert_wired "間接の連鎖を定義しただけでは効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          g() { f; }
          h() { g; }
          bash ${SUITE_PATH}"

# 相互再帰でも畳み込みが止まること（止まらないと CI が固まる）
assert_wired "相互に呼び合う定義でも解析が止まる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          a() { b; }
          b() { a; }
          bash ${SUITE_PATH}"

# --- 本文の中で戻している関数（CI スクリプトの定型句） -------------------------------
#
# `run_quietly() { set +e; "$@"; set -e; }` は呼んだあとの errexit が**有効なまま**。
# 台帳へ記録しっぱなしにすると、この定型句があるだけで以降のスイートがすべて
# 「未配線」と誤報され、**required なジョブが恒常的に赤くなる**（fail-closed だが、
# 検出網ごと信用されなくなる。レビューで実測）。
# 打ち消せるのは**同じ階層で落とした分だけ**——条件の中で戻す綴りは打ち消さない。

assert_wired "本文で戻している関数を呼んでもゲートは残る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          run_quietly() {
            set +e
            \"${DOLLAR}@\"
            set -e
          }
          run_quietly echo hi
          bash ${SUITE_PATH}"

assert_wired "1 行で戻している関数を呼んでもゲートは残る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; :; set -e; }
          f
          bash ${SUITE_PATH}"

assert_wired "長い綴りで戻していても同じ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +o errexit; :; set -o errexit; }
          f
          bash ${SUITE_PATH}"

# **呼び先から伝わってきた弱めも、呼び元の本文が戻していれば効かない。**
# 伝播が載るのは呼び元を呼ぶ断片で畳み直したときで、そこにはもう本文の `set -e` を
# 見に行く経路が無い。控えておかないと、戻している関数が「弱める関数」に化けて
# required なジョブが恒常的に赤くなる（レビューで実測。origin/main は正しく wired）
assert_wired "呼び先の弱めも呼び元が戻していれば効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          g() { set +e; }
          f() { g; set -e; }
          f
          bash ${SUITE_PATH}"

# 見出しが別行の綴りでも打ち消しが成立する（本体の階層の数え方が 1 つずれていた）
assert_wired "見出しが別行の関数が戻していてもゲートは残る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f()
          { set +e; set -e; }
          f
          bash ${SUITE_PATH}"

# **再定義は前の本文を置き換える。** 消さないと古い記録が勝ち、正しくゲートしている
# ステップを「未配線」と誤報して required なジョブを赤くする（レビューで実測。`main` は正しい）
assert_wired "同じ名前で定義し直せば前の本文は残らない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          f() {
            :
          }
          f
          bash ${SUITE_PATH}"

# 逆向きも対で固定する（後から弱める本文へ差し替えたら、そちらが効く）
assert_not_wired "定義し直して弱めるようになれば効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { :; }
          f() { set +e; }
          f
          bash ${SUITE_PATH}"

# 穴の側: **条件の中で戻す**綴りは打ち消さない（走るとは限らないため）。
# 打ち消すと、実際には握り潰されている呼び出しが「ゲートしている」と読まれる
assert_not_wired "条件の中でしか戻さない関数は打ち消しにならない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() {
            set +e
            if [ -n \"${DOLLAR}FORCE\" ]; then set -e; fi
          }
          f
          bash ${SUITE_PATH}"

# 呼び先が何も弱めないなら、間接でも効かない
assert_wired "弱めない関数を挟んだだけでは効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { echo hi; }
          g() { f; }
          g
          bash ${SUITE_PATH}"

# --- 条件の位置に置いた `set` と呼び出し ---------------------------------------------
#
# `if set +e; then …` の `set` は**条件として現在のシェルで走る**ので握り潰しは効く。
# `struct_text` は `then` / `else` / `do` しか剥がさないため、`if` を剥がす場所が
# どこにも無く、1 行でゲートを外せた（**main 既存**の fail-open。レビューで検出）。
# 剥がすのは `set` と呼び出しを探す側だけで、`struct_text` では剥がさない
# （あちらは `if` が 1 階層開くことを数えるための本文。剥がすと深さの勘定が壊れる）。

assert_not_wired "条件の位置の set +e も効く（if）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if set +e; then :; fi
          bash ${SUITE_PATH}"

assert_not_wired "条件の位置の set +e も効く（while）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          while set +e; do break; done
          bash ${SUITE_PATH}"

assert_not_wired "条件の位置の set +e も効く（until）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          until set +e; do break; done
          bash ${SUITE_PATH}"

assert_not_wired "条件の位置の set +e も効く（elif）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if false; then :; elif set +e; then :; fi
          bash ${SUITE_PATH}"

# 呼び出しも同じ位置に書ける（剥がす一覧を共有していないと 3 トークンで抜けられる）
assert_not_wired "条件の位置の呼び出しでも本文の set +e が効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          if f; then :; fi
          bash ${SUITE_PATH}"

assert_not_wired "while の条件で呼んでも本文の set +e が効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          while f; do break; done
          bash ${SUITE_PATH}"

# 締めすぎの側: 強める向きは条件の位置でも credit しない（条件次第でしか走らない）
assert_not_wired "条件の位置の set -e は打ち消しに使わない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          if set -e; then :; fi
          bash ${SUITE_PATH}"

# 締めすぎの側: 条件が `set` でも呼び出しでもない普通の綴りは今までどおり
assert_wired "普通の条件は握り潰しと読まない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          if [ -n \"${DOLLAR}X\" ]; then :; fi
          bash ${SUITE_PATH}"

# --- 1 行の POSIX アーム（`(pat)`）の後ろの呼び出し ------------------------------------
#
# `starts_case_arm()` は `[^()]*` で測るので、アームの `)` の手前に `(` があると跨げず、
# **1 行に畳んだ POSIX 綴りだけ**が見出しとして剥がれない。剥がれないと断片の先頭が
# `case` のまま残り、呼び出し先が `case` と読まれて追跡が外れる
# （`(` を 1 つ足すだけで塞いだ穴が開き直す。レビューで検出。fail-open）。
# 同じ綴りを 2 行に分けた場合は元から正しく扱えるので、対で固定する。

assert_not_wired "1 行の POSIX アームの後ろの呼び出しでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          case linux in (linux) f ;; esac
          bash ${SUITE_PATH}"

assert_not_wired "2 行に分けた POSIX アームでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          case linux in
            (linux) f ;;
          esac
          bash ${SUITE_PATH}"

# 締めすぎの側: アームが弱めない関数を呼ぶだけなら効かない
assert_wired "POSIX アームが弱めない関数を呼ぶだけでは効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { echo hi; }
          case linux in (linux) f ;; esac
          bash ${SUITE_PATH}"

# 締めすぎの側: 主語のコマンド置換を見出しと読んで巻き込まない
assert_wired "主語のコマンド置換を見出しと読まない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          case ${DOLLAR}(echo linux) in (linux) : ;; esac
          bash ${SUITE_PATH}"

# **見出しの剥がしは `case` を開く断片だけに掛ける。** アームの**中身**にも掛けると、
# `[^)]*` が `\$(` を跨いで `f \$(date)` のような呼び出しを丸ごと消してしまい、
# 弱めが反映されない（握り潰されたスイートが「ゲートしている」と読まれる fail-open。
# レビューで実測。1 度この形で入れて即座に検出された）
assert_not_wired "アームの中身の呼び出しは引数のコマンド置換で消えない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          case x in
            *)
              f ${DOLLAR}(date)
              ;;
          esac
          bash ${SUITE_PATH}"

# --- 入れ子の 1 行定義 ---------------------------------------------------------------
#
# 見出しを 1 つ落としただけでは `{ inner() { set +e` が残り、`set` に届かない
# （＝存在自体を見落とす。fail-open）。複数行で書いた同じコードは正しく扱えるので、
# **1 行に畳むだけで穴が開く**形だった。

assert_not_wired "入れ子の 1 行定義でも呼べば set +e が効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          outer() { inner() { set +e; }; inner; }
          outer
          bash ${SUITE_PATH}"

# 締めすぎの側: 外側を呼ばなければ、入れ子の中身は 1 度も走らない
assert_wired "入れ子の 1 行定義も呼ばなければ効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          outer() { inner() { set +e; }; inner; }
          bash ${SUITE_PATH}"

# --- 連鎖の届かない `set`（1 度も走らない） ----------------------------------------

# `true || set +e` の右は走らないので、握り潰しとして数えてはいけない。
# 数えると、実際にはゲートしているステップを「未配線」と誤報して赤くする
assert_wired "true || set +e は 1 度も走らない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          true || set +e
          bash ${SUITE_PATH}"

assert_wired "false && set +e も 1 度も走らない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          false && set +e
          bash ${SUITE_PATH}"

# --- 継続語と同じ断片に載った開き語（`;` で切ると本文の頭に来る） -------------------
#
# `split_commands` は `;` で切るので、`if …; then if false; …` の断片は `then if false`。
# `^` で錨を打つ判定が継続語を剥がさないと、内側の `if false` が丸ごと見えず、
# **走らないブロックの中の `set -e` が最上位で走ったように扱われる**（fail-open）

assert_not_wired "1 行で入れ子にした if false の中の set -e は効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          if true; then if false; then set -e; fi; fi
          bash ${SUITE_PATH}"

assert_not_wired "1 行で入れ子にした while false の中の set -e は効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          if true; then while false; do set -e; done; fi
          bash ${SUITE_PATH}"

# ブレースグループと開き語が同じ断片に載る綴り。剥がした側に開き語が混ざるので、
# **強める向きは断片の先頭そのもののときだけ**信用する
assert_not_wired "ブレースグループの中に 1 行で入れ子にした if false" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          { if false; then set -e; fi; }
          bash ${SUITE_PATH}"

# `else` は**内側の if** に結び付く。外側の `if true` の印に吸われると、
# 実際には走る set +e が握り潰しとして数えられない
assert_not_wired "入れ子の else は内側の if に結び付く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then if false; then :; else set +e; fi; fi
          bash ${SUITE_PATH}"

# 継続語の後ろに書いた関数定義も定義（`opens_function` を剥がす前の本文で見ると外れる）
assert_wired "then の後ろに書いた関数定義の中の set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then f() { set +e; }; fi
          bash ${SUITE_PATH}"

# 見出しの次の行が `{ set -e; }` の綴り。予約の消費を set の判定より後に置くと、
# まだ fndef が立っていない状態で定義の本文を最上位のコードとして読む
assert_not_wired "見出しの次の行の { set -e; } は定義の本文" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          f()
          { set -e; }
          bash ${SUITE_PATH}"

# --- 大文字を含むオプション（`-Eeuo pipefail` は定型句） ---------------------------

assert_wired "set -Eeuo pipefail は errexit も pipefail も立てる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -Eeuo pipefail
          bash ${SUITE_PATH} | tee log"

assert_not_wired "set +eE は errexit を落とす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +eE
          bash ${SUITE_PATH}"

# --- 言及と実行の区別（`set` を断片のどこでも拾わない） ----------------------------

# 引用符が無くてもただの言及は言及。語の切れ目ならどこでも拾う実装にすると、
# ゲートしているステップを「未配線」と誤報して赤くする
assert_wired "引用符の無い set +e の言及は実行ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          echo Hint: run set +e first
          bash ${SUITE_PATH}"

assert_wired "引数の --set +e は set の呼び出しではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          printf '%s\\n' --set +e
          bash ${SUITE_PATH}"

# --- 同じ組み込みを呼ぶ書き方（現在のシェルで効く） --------------------------------

# `eval` は現在のシェルで走るので、引用の中身も本物の `set`
assert_not_wired "eval \"set +e\" は現在のシェルで効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          eval \"set +e\"
          bash ${SUITE_PATH}"

assert_not_wired "builtin set +e も同じ組み込み" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          builtin set +e
          bash ${SUITE_PATH}"

assert_not_wired "command set +e も同じ組み込み" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          command set +e
          bash ${SUITE_PATH}"

# --- 同じ階層で括った `set +e … set -e`（打ち消し合う） -----------------------------
#
# 非対称の扱いは「通らない分岐の `set -e` が**外側**の握り潰しを隠す」ことへの備えなので、
# 落としたのが同じ階層の `set +e` なら、戻す側も同じだけ条件付きで隠すものが無い。
# ここを見ないと、この括りが「以降ずっと握り潰し」と読まれて CI が恒常的に赤くなる

assert_wired "ループの中で括った set +e … set -e は打ち消し合う" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for f in a; do
            set +e
            true
            set -e
          done
          bash ${SUITE_PATH}"

assert_wired "1 行で括った set +e … set -e も打ち消し合う" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for f in a; do set +e; true; set -e; done
          bash ${SUITE_PATH}"

# 締めすぎない代わりに、**外側**の握り潰しは隠さない（階層が違えば戻せない）
assert_not_wired "外側の set +e は内側の set -e で戻らない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          for f in a; do set -e; done
          bash ${SUITE_PATH}"

# 別のブロックへ持ち越さない（階層の数字が同じでも別のブロック）
assert_not_wired "別ブロックの同じ深さの set -e では戻らない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}A\" ]; then set +e; fi
          if [ -n \"${DOLLAR}B\" ]; then set -e; fi
          bash ${SUITE_PATH}"

# --- 関数定義の 3 綴り（一覧を 2 か所に分けると必ず片方が漏れる） -------------------

# `function f()` の綴りはどちらの一覧からも抜けていた。定義が階層を開かないのに
# 閉じ `}` だけが深さを減らし、外側のブロックを潰す（条件付きの呼び出しが証拠に化ける）
assert_not_wired "function f() { } の綴りでも外側のブロックが潰れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}SKIP\" ]; then
            function note() { echo x; }
            bash ${SUITE_PATH}
          fi"

# --- 丸括弧付きの case アームは 1 行書きでも拾う -----------------------------------

assert_not_wired "case … in (a) set +e を 1 行で書いた綴り" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -e
          case \"${DOLLAR}X\" in (a) set +e ;; esac
          bash ${SUITE_PATH}"

# 打ち消しは「有効へ戻す」だけで、**外側でまだ効いている握り潰しは消さない**。
# 内側の `set +e` に記録を上書きさせると、外側の `set +e` ごと消える（fail-open）
assert_not_wired "内側の括りは外側の set +e を消さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          if [ -n \"${DOLLAR}NOPE\" ]; then
            set +e
            set -e
          fi
          bash ${SUITE_PATH}"

# 長い綴りでも同じ記録を残す（残さないと長い綴りの括りだけが打ち消せない）
assert_wired "長い綴りの set +o errexit … set -o errexit も打ち消し合う" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for f in a; do
            set +o errexit
            echo hi
            set -o errexit
          done
          bash ${SUITE_PATH}"

# 必ず走る入れ子（`while true`）も grouping と同じで、閉じた側の区切りが中身に掛かる
assert_not_wired "while true の done に付いた || true は中身に掛かる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          while true; do
            bash ${SUITE_PATH}
            break
          done || true"

# **最初の非オプション語でオプションの解釈は終わる**（後ろは位置パラメータ）
assert_not_wired "set +e foo -e の -e は位置パラメータ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e foo -e
          bash ${SUITE_PATH}"

# --- 既知の残件（締めすぎ側。挙動を固定して黙って変わらないようにする） -------------
#
# ブレースグループは必ず走るので、この `set -e` は実際には効く。だが `{ if false` のように
# **1 つの断片が開き語を 2 つ運ぶ**綴りがあり、そのときの `uncertain` は内側をまだ数えていない。
# そこで強める向きは「`set` が断片の先頭そのもの」のときだけ信用する側に倒してある。
# 向きは fail-closed（CI が赤くなって人が見る）。直すなら 1 断片で複数の階層を開けるようにする
assert_not_wired "既知の残件: ブレースグループの中の set -e は credit しない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          { set -e; }
          bash ${SUITE_PATH}"

# 打ち消しは**落とす前の値**へ戻す。1 に固定すると「`set -e` が明示された」と読まれ、
# `-e` を持たないシェルでも errexit が有効と扱われる（走らないループの括りで fail-open）
assert_not_wired "自前テンプレートでは走らないループの括りが errexit を立てない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        shell: bash {0}
        run: |
          EMPTY=\"\"
          for f in ${DOLLAR}EMPTY; do set +e; :; set -e; done
          bash ${SUITE_PATH}"

# 括りの記録は errexit のものなので、pipefail の判断には使わない。
# 巻き込むと、無関係な set +e が同じ階層で開いているだけで
# 走らないループの中の set -o pipefail が credit される
assert_not_wired "errexit の括り記録は pipefail に流用しない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          EMPTY=\"\"
          for f in ${DOLLAR}EMPTY; do
            set +e
            set -o pipefail
          done
          set -e
          bash ${SUITE_PATH} | cat"

# --- 排他なアームは打ち消し合わない（同じ深さでも別の枝） ---------------------------
#
# `if …; then set +e; else set -e; fi` の 2 つは**排他**なので、
# else 側の `set -e` は then 側の `set +e` を打ち消さない。階層だけで見ると
# 同じ深さなので打ち消しが成立してしまい、握り潰されたスイートが
# 「ゲートしている」と読まれる（fail-open）

assert_not_wired "else 側の set -e は then 側の set +e を打ち消さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -z \"${DOLLAR}NEVER\" ]
          then
          set +e
          else
          set -e
          fi
          bash ${SUITE_PATH}"

assert_not_wired "elif 側の set -e も打ち消さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -z \"${DOLLAR}NEVER\" ]; then
          set +e
          elif true; then
          set -e
          fi
          bash ${SUITE_PATH}"

assert_not_wired "長い綴りでも排他なアームは打ち消し合わない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -z \"${DOLLAR}NEVER\" ]
          then
          set +o errexit
          else
          set -o errexit
          fi
          bash ${SUITE_PATH}"

assert_not_wired "別の case アームの set -e も打ち消さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case \"${DOLLAR}OS\" in
          linux*) set +e ;;
          never) set -e ;;
          esac
          bash ${SUITE_PATH}"

# 複数行で書いたアームは**それぞれの `set` が断片の先頭**になるので、
# 1 行書きと違って深さだけでは区別できない（1 行書きだけを固定すると空振りする）
assert_not_wired "複数行で書いた case アームも打ち消し合わない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case \"${DOLLAR}OS\" in
            linux*)
              set +e
              ;;
            *)
              set -e
              ;;
          esac
          bash ${SUITE_PATH}"

# 途中でループを抜ける綴りがあると、括りの後半は走るとは限らない
assert_not_wired "continue を挟んだ括りは打ち消しにしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for f in a b; do
            set +e
            false || continue
            set -e
          done
          bash ${SUITE_PATH}"

# 主語にコマンド置換があっても本物のアームを取り逃がさない
assert_not_wired "case の主語がコマンド置換でもアームを見つける" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case ${DOLLAR}(echo linux) in linux) set +e ;; esac
          bash ${SUITE_PATH}"

# アーム模様の `|` は選択肢の区切りであってパイプではない
assert_not_wired "選択肢を持つ case アームの set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case \"${DOLLAR}OS\" in a|linux*) set +e ;; esac
          bash ${SUITE_PATH}"

# 1 語の中で自分を打ち消す綴りも、2 コマンドに分けた同じ意味と答えを揃える
assert_wired "1 語の set +e -e はループの中でも打ち消し合う" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for f in a; do
            set +e -e
          done
          bash ${SUITE_PATH}"

# 括りの記録は**閉じた階層の外へ持ち出さない**。持ち出すと、別のブロックの
# `set -e` が深さの数字だけで一致して打ち消しを成立させる（複数行で書くと
# `set_probe == text` の条件も満たしてしまうので、これが最後の砦になる）
assert_not_wired "閉じたブロックの括り記録は次のブロックへ持ち越さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}A\" ]; then
            set +e
          fi
          if [ -n \"${DOLLAR}B\" ]; then
            set -e
          fi
          bash ${SUITE_PATH}"

# `case` の入れ子数も**継続語を剥がした本文**で数える。`then case … in` の断片で
# 数え損ねると、アーム模様の `|` がパイプと読まれてアームの中の `set +e` が丸ごと落ちる
assert_not_wired "継続語の後ろに書いた case のアーム模様も選択肢と読む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then case \"${DOLLAR}X\" in a|b) set +e ;; esac; fi
          bash ${SUITE_PATH}"

assert_not_wired "ループの中に書いた case でも同じ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for f in x; do case \"${DOLLAR}X\" in a|b) set +e ;; esac; done
          bash ${SUITE_PATH}"

# --- 判定は使う前に求める（1 周ずれると生きている記録を捨てる） ---------------------

# アーム見出しと同じ行に `set +e` を置くと、**次の**断片で「アームへ移った」と誤判定して
# 記録を捨てていた。同じアームの `set -e` が打ち消せなくなり、正しくゲートしている
# ステップが赤くなる（同じ意味を 2 行に分けた綴りとも答えが食い違う）
assert_wired "アーム見出しと同じ行の set +e も同じアームで打ち消せる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case \"${DOLLAR}X\" in
            a) set +e
              echo m
              set -e
              ;;
          esac
          bash ${SUITE_PATH}"

# 走らないと分かっている `continue` / `exit` は「途中で抜ける綴り」に数えない。
# 数えると 2 トークン足すだけで正しくゲートしているステップを恒常的に赤くできる
assert_wired "連鎖で届かない continue は括りを壊さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for f in a b; do
            set +e
            true || continue
            set -e
          done
          bash ${SUITE_PATH}"

assert_wired "偽と分かるブロックの中の exit も括りを壊さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for f in a b; do
            set +e
            if false; then exit 1; fi
            set -e
          done
          bash ${SUITE_PATH}"

# 締めすぎない側: **届く** continue は今までどおり括りを壊す
assert_not_wired "届く continue は括りを壊す" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for f in a b; do
            set +e
            false || continue
            set -e
          done
          bash ${SUITE_PATH}"

# --- 先頭の飾り（同じシェルのまま `set` を呼ぶ書き方）------------------------------
#
# 落としてよいのはブレースグループ / 変数代入 / `builtin` / `command` / `eval` だけ。
# アームの中でも同じ判定を通すので、1 トークン足しただけで穴が開かない

assert_not_wired "case アームの中の command set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case a in a) command set +e ;; esac
          bash ${SUITE_PATH}"

assert_not_wired "case アームの中のブレースグループの set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case a in a) { set +e; } ;; esac
          bash ${SUITE_PATH}"

assert_not_wired "ブレースグループの中の eval \"set +e\"" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { eval \"set +e\"; }
          bash ${SUITE_PATH}"

assert_not_wired "変数代入を前置きした set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          X=1 set +e
          bash ${SUITE_PATH}"

# 締めすぎない側: **別プロセスを起こす**実行ラッパは落とさない。
# `sudo set +e` は子プロセスのオプションを変えるだけで、親は握り潰さない
assert_wired "sudo set +e は親のオプションを変えない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          sudo set +e 2>/dev/null || true
          bash ${SUITE_PATH}"

# 引用の中の `) ` はアームの移動ではない（生きている括りの記録を捨てない）
assert_wired "引用の中の ) はアームの移動と読まない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case linux in
            linux)
              set +e
              echo \"a) b\"
              set -e
              ;;
          esac
          bash ${SUITE_PATH}"

# 確実に走ると分かる `set -e` は「明示された」ので、-e を持たないシェルでも有効
assert_wired "自前テンプレートでも最上位の set -e は明示として効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        shell: bash {0}
        run: |
          set +e
          echo a
          set -e
          bash ${SUITE_PATH}"

# --- 連鎖が続く条件は「必ず走る」ではない ------------------------------------------
#
# `split_commands` は `&&` で切るので `if true && [ … ]; then` の断片は `if true`。
# 素直に読むと、2 トークン足すだけで走るとは限らない本体が
# 「最上位で確実に走る」に化ける（実行の証拠として数えられてしまう）

assert_not_wired "if true && <条件> の本体は実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true && [ -z \"${DOLLAR}SKIP\" ]; then
            bash ${SUITE_PATH}
          fi"

assert_not_wired "while true && <条件> の本体も同じ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          while true && [ -z \"${DOLLAR}SKIP\" ]; do
            bash ${SUITE_PATH}
            break
          done"

# --- 同じシェルのまま set を呼ぶ、残りの綴り --------------------------------------

assert_not_wired "エイリアスを止める \\set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          \\set +e
          bash ${SUITE_PATH}"

assert_not_wired "終了状態を反転する ! set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ! set +e
          bash ${SUITE_PATH}"

assert_not_wired "time set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          time set +e
          bash ${SUITE_PATH}"

assert_not_wired "先頭に置いたリダイレクト付きの set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          >/dev/null set +e
          bash ${SUITE_PATH}"

# --- case を開く断片に載ったアームの set は本体の階層に属する ----------------------

# 深さが増えるのは断片の**末尾**なので、素直に記録すると同じアームの後続
# （1 つ深い）の set -e が打ち消せず、複数行で書いた同じアームと答えが食い違う
assert_wired "1 行の case アームでも同じアームの中で打ち消し合う" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case \"${DOLLAR}X\" in y) set +e; true; set -e ;; esac
          bash ${SUITE_PATH}"

# --- POSIX の丸括弧付きアーム（`(a)`）------------------------------------------
#
# `[^()]*` は `(` を跨げないので、先頭の `(` を任意扱いで明示しないと
# 丸括弧付きのアームだけ判定から外れ、アーム同士の排他が効かなくなる

assert_not_wired "丸括弧付きの別アームの set -e は打ち消さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case \"${DOLLAR}X\" in
          (a)
            set +e
            ;;
          (b)
            set -e
            ;;
          esac
          bash ${SUITE_PATH}"

# アーム模様が `|` で切られた前半（`(a`）の `(` は部分シェルの開きではない。
# 数えると幻の階層が開き、`esac` が本物ではなくそちらを閉じて
# 以降の呼び出しが「未配線」に化ける
assert_wired "丸括弧付きの選択肢アームの後ろでも深さが戻る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case \"${DOLLAR}X\" in
          (a|q)
            echo hi
            ;;
          esac
          bash ${SUITE_PATH}"

# --- アームの走査は `case` の中だけ ------------------------------------------------

# 絞らないと、コマンド置換の `)` をアームと読んで言及まで拾い、
# ゲートしているステップを「未配線」と誤報する
assert_wired "コマンド置換の ) はアームではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          echo ${DOLLAR}(date) set +e
          bash ${SUITE_PATH}"

# 部分シェルの中の `)` はアーム見出しではなく閉じ括弧。アームとして剥がすと
# 釣り合いから消え、`subshell` が 0 に戻らないまま以降の `set +e` が
# すべて「子シェルの中」として無視される（握り潰しが「ゲート」に化ける）
assert_not_wired "case アームの中の部分シェルを閉じた後の set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case \"${DOLLAR}RUNNER_OS\" in
            Linux)
              ( cd /tmp; echo prep )
              set +e
              ;;
          esac
          bash ${SUITE_PATH}"

# --- 偽と分かる条件も、連鎖が続けば結論が変わる ------------------------------------
#
# 除くのは**短絡で結論が変わりうる向きだけ**。無条件に除くと本当に走らない本体まで
# 生きていると読み、無条件に印を付けると走る本体の set +e を捨てる（両向きで実測）

assert_not_wired "if false || <条件> の本体の set +e は効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if false || true; then set +e; fi
          bash ${SUITE_PATH}"

assert_not_wired "until true && <条件> の本体の set +e も効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          until true && false; do set +e; break; done
          bash ${SUITE_PATH}"

# 締めすぎない側: `&&` は偽のままなので、本体は本当に走らない
assert_wired "if false && <条件> の本体は走らない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if false && true; then set +e; fi
          bash ${SUITE_PATH}"

# --- 1 行書きの case を外側のブロックの中に置く ------------------------------------
#
# 深さも `case_depth` も増えるのは断片の末尾なので、1 行書きを処理している最中はまだ 0。
# アームの `)` を部分シェルの閉じと数えると、囲っているブロックの階層が巻き戻り、
# 走らないはずの本体が「最上位で確実に走る」に化ける

assert_not_wired "偽と分かるブロックの中の 1 行 case は外側を巻き戻さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if false; then
            case \"${DOLLAR}RUNNER_OS\" in Linux) echo linux ;; esac
            bash ${SUITE_PATH}
          fi"

assert_not_wired "走らないループの中の 1 行 case も外側を巻き戻さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          while false; do case a in a) : ;; esac; set -e; done
          bash ${SUITE_PATH}"

# --- パイプの構成要素として開いた複合コマンドは子シェル -----------------------------
#
# `( … )` は釣り合いで拾えるが、パイプはこの経路でしか分からない。
# 印を付けないと親へ漏れない `set +e` を握り潰しとして数え、赤くする

assert_wired "パイプの中のループの set +e は親へ漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          echo x | while read -r l; do set +e; done
          bash ${SUITE_PATH}"

assert_wired "パイプの中の if の set +e も親へ漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          echo x | if true; then set +e; fi
          bash ${SUITE_PATH}"

# 締めすぎない側: `case` のアーム模様の `|` はパイプではないので、この印を付けない
# （付けるとアームの中の set +e が丸ごと落ちて握り潰しを見逃す）
assert_not_wired "丸括弧付きの選択肢アームの set +e は数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case \"${DOLLAR}X\" in
          (a|b) set +e ;;
          esac
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

# --- 1 行に畳んでも答えが変わらないこと（issue #123）--------------------------------
#
# issue #123 の 5 件は「**複数行で書けば正しいのに、1 行に畳むと答えが変わる**」形に
# 集約される。アーム見出し・複合コマンドの開き／閉じ・パイプの子シェル判定が
# 同じ断片に同居したときの扱いが根で、向きは fail-closed（正しくゲートしている
# ステップを赤くする）と fail-open（握り潰されたスイートを緑で通す）の両方があった。
# 期待値はすべて実 `bash -eo pipefail` との差分照合で確かめてある。

# (1) 複合コマンドが**パイプの左側**にあると、子シェルの印が一度も付かなかった。
# 開き側の判定は「複合を開く断片に `|` が付いているとき」しか成立せず、
# `split_commands` は `|` を `done` / `fi` / `}` の断片に付けるため（fail-closed）
assert_wired "パイプの左のループの set +e は親へ漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          while read -r l; do set +e; done < /dev/null | cat
          bash ${SUITE_PATH}"

assert_wired "パイプの左の if の set +e は親へ漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then set +e; fi | cat
          bash ${SUITE_PATH}"

assert_wired "パイプの左のブレースグループの set +e は親へ漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { set +e; } | cat
          bash ${SUITE_PATH}"

# 締めすぎない側（fail-closed の防止）: 巻き戻すのは**子シェルの中で変わった分だけ**で、
# 外側の階層で落とした `set +e` の記録は生きている。括りの途中にフォークする複合が
# 挟まるだけで `set -e` が打ち消せなくなると、正しくゲートしているステップが
# 恒常的に赤くなる（レビューで実測）
assert_wired "括りの途中にフォークが挟まっても set -e は打ち消せる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for f in a; do
          set +e
          { :; } | cat
          set -e
          done
          bash ${SUITE_PATH}"

assert_wired "括りの途中の if のフォークでも set -e は打ち消せる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for f in a; do
          set +e
          if true; then :; fi | cat
          set -e
          done
          bash ${SUITE_PATH}"

# 締めすぎない側: `||` / `&&` / `;` はフォークしないので、握り潰しはそのまま親へ漏れる
# （実 bash で確認済み。巻き戻す対象を広げると、本物の握り潰しを見逃す fail-open になる）
assert_not_wired "|| で閉じたブレースグループの set +e は親へ漏れる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { set +e; } || true
          bash ${SUITE_PATH}"

assert_not_wired "; で閉じたブレースグループの set +e は親へ漏れる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { set +e; } ; true
          bash ${SUITE_PATH}"

# (2) 1 断片が `{` と `(` を同時に開くと、`(` の階層が開かなかった。
# 内側の `)` が閉じた時点で子シェルの印が外れ、残りの `set +e` が親に効いたものとして
# 扱われていた（fail-closed）
assert_wired "1 断片で { と ( を同時に開いても深さが合う" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          echo x | { (
          :
          ) ; set +e ; }
          bash ${SUITE_PATH}"

# (3) 1 行に畳んだ `if true; then …` の本体は、**意図的に**実行の証拠にしない。
# issue #123 (3) はこれを直すよう求めており、控える本文を継続語を剥がした側
# （`struct_text`）にすれば確かに直る。**だが同じ変更で fail-open が丸ごと開く**——
# 開き側が読めない語で始まる断片（`( if false`・`time if …`・`eval if …`）では
# 制御構造が分類されず `uncertain` も `dead_depth` も立たないため、1 度も走らない
# 本体が「最上位で確実に走る」として記録される（下の 4 ケースで固定。実測で
# `( if false; then bash x; fi )` が「配線されている」に化けた）。
# 生の本文を控えていれば `then bash x` のまま綴りに当たらず、受け皿になる。
# **畳んだ綴りを拾うのは、開き側が同じ語を読めるようになってから**
assert_not_wired "1 行の if true の本体は実行の証拠にしない（fail-closed 側の受け皿）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then bash ${SUITE_PATH}; fi"

assert_not_wired "1 行の while true の本体も実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          while true; do bash ${SUITE_PATH}; break; done"

# 上の受け皿が外れると一斉に穴になる 4 形。**開き側が読めない語で始まる断片**の後ろの
# 継続語を命令の位置として扱うと、走らない本体が最上位の実行として記録される
assert_not_wired "部分シェルの中の偽と分かる分岐の本体" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( if false; then bash ${SUITE_PATH}; fi )"

assert_not_wired "部分シェルの中の条件付き分岐の本体" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( if [ -n \"${DOLLAR}X\" ]; then bash ${SUITE_PATH}; fi )"

assert_not_wired "部分シェルの中のループの本体" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( for f in a; do bash ${SUITE_PATH}; done )"

assert_not_wired "実行ラッパの後ろに置いた偽と分かる分岐の本体" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          time if false; then bash ${SUITE_PATH}; fi"

# 締めすぎない側: `then` を許したことで**条件の位置**まで通してはいけない。
# `if bash x; then …` の呼び出しは落ちても `set -e` を発動させず job も止めない
assert_not_wired "条件の位置に置いた呼び出しは実行の証拠にならない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if bash ${SUITE_PATH}; then echo ok; fi"

# 締めすぎない側: 走らないと分かる分岐の本体も通してはいけない
assert_not_wired "1 行の if false の本体は実行の証拠にならない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if false; then bash ${SUITE_PATH}; fi"

# 締めすぎない側: 条件を読まないと決まらない分岐の本体も通してはいけない
assert_not_wired "1 行の条件付き分岐の本体は実行の証拠にならない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}CI\" ]; then bash ${SUITE_PATH}; fi"

# 締めすぎない側: `case` のアームは**模様が一致するか読めない**ので、1 行書きでも
# 実行の証拠にしない（複数行で書いた同じコードも従来どおり `not-wired`）。
# issue #123 (3) はこれも `wired` にすべきと書いているが、それは
# `case ${DOLLAR}X in (linux) bash …` を「必ず走る」と読むことになり fail-open
assert_not_wired "1 行の case アームの本体は実行の証拠にならない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case linux in (linux) bash ${SUITE_PATH} ;; esac"

# (4) 1 行の `case x in (a|b) …` が幻の部分シェルを開き、その断片の `set +e` が
# すべて「子シェルの中」として捨てられていた（fail-open）
assert_not_wired "1 行の丸括弧付き選択肢アームの set +e は数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case x in (x|y) set +e ;; esac
          bash ${SUITE_PATH}"

assert_not_wired "主語がコマンド置換でも選択肢アームの set +e は数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case ${DOLLAR}(uname) in (Linux|Darwin) set +e ;; esac
          bash ${SUITE_PATH}"

# 締めすぎない側: アームの**中身**に置いた本物の部分シェルは今までどおり子シェル
assert_wired "選択肢アームの中の部分シェルの set +e は漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case x in (x|y) ( set +e | cat ) ;; esac
          bash ${SUITE_PATH}"

# 締めすぎない側（fail-open の防止）: アーム模様の補償で**本物の**部分シェルを食わないこと。
# 「閉じられていない最後の `(`」まで広げると `time ( : | cat )` の `(` が落ち、
# 階層が開かないまま続く `)` がアームの階層を閉じて、**一致しないアームの中身が
# 最上位のコード**として読まれる（レビューで実測。まさに *absence == pass* の形）。
# アーム模様が現れるのは `in` の直後か断片の先頭だけなので、そこに限る
assert_not_wired "case の中の前置き付き部分シェルはアーム模様と混ぜない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case never in
          a)
          time ( : | cat \$(date) )
          bash ${SUITE_PATH}
          ;;
          esac"

# 同上。**断片の先頭にある `(` でも本物の部分シェルはある**ので、位置（`case … in` の
# 直後か `;;` の直後か）で判断する。「先頭なら模様」「括弧の後ろが 1 語なら模様」の
# どちらも `( :` に当たってしまい、一致しないアームの中身を最上位に引き上げる
assert_not_wired "アーム本体の先頭に置いた部分シェルもアーム模様と混ぜない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case never in
          a)
          ( : | cat \$(date) )
          bash ${SUITE_PATH}
          ;;
          esac"

# 引用の中の `)` で釣り合いを測ると、本物の部分シェルの `(` を模様と読んでしまう
assert_not_wired "引用の中の ) を含む部分シェルもアーム模様と混ぜない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case never in
          a)
          ( echo \"x)y\" | cat \$(date) )
          bash ${SUITE_PATH}
          ;;
          esac"

# アームの**本体の途中**に行末の `;` があっても模様の位置は立たない。
# 「空の断片＝`;;` の跡」とだけ読むと、行末のただの `;` でも立ってしまい、
# 続く本物の部分シェルの `(` を模様と読む（`;` 1 文字でこの検査を外せる。レビューで実測）
assert_not_wired "アーム本体の行末の ; では模様の位置は立たない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case never in
          a) :;
          ( : | cat \$(echo /dev/null) )
          bash ${SUITE_PATH}
          ;;
          esac"

# 締めすぎない側: `;;` の**後ろ**は模様の位置なので、そこの丸括弧付き選択肢は今までどおり拾う
assert_not_wired ";; の後ろの丸括弧付き選択肢アームの set +e は数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case x in
          zzz) : ;;
          (x|y) set +e ;;
          esac
          bash ${SUITE_PATH}"

# 模様まで同じ断片に載っている 1 行書きでは、**次**の断片は模様の位置ではない。
# 立てたままにすると、その先頭の `(`（本物の部分シェル）を模様と読んで落とす
assert_not_wired "模様を消費した断片の次は模様の位置ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case never in a) echo m | ( : | cat \$(date) )
          bash ${SUITE_PATH}
          ;;
          esac"

# `case` は断片の先頭にあるとは限らない（開き側のループが本体の中でも開く）。
# `^case` だけで入れ子を数えると、アーム見出しの `)` が部分シェルの閉じとして
# 数えられ、囲っている関数の階層まで巻き戻る（呼ばれない関数の中身が最上位に上がる）
assert_not_wired "関数の本体の中で開いた case もアーム見出しを読む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { case x in
          a) : ;;
          esac
          bash ${SUITE_PATH}
          }"

# 締めすぎない側: `;&`（フォールスルー）の後ろも模様の位置
assert_not_wired ";& の後ろの丸括弧付き選択肢アームの set +e は数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case x in
          zzz) : ;&
          (x|y) set +e ;;
          esac
          bash ${SUITE_PATH}"

# (5) 1 断片が 2 つ開く関数定義で、閉じ側が関数の階層を食っていた。
# **呼ばれていない関数の本文の残りが最上位のコードとして読まれる**ため、
# 実際のコマンド一覧から外したスイートでも、呼ばれない関数の中に名前を書くだけで
# 「配線されている」と報告できた（fail-open。`ci_coverage_test.sh` に直接効く）
assert_not_wired "入れ子の 1 行定義の後ろの呼び出しは走らない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { g() { : ; }; bash ${SUITE_PATH}; }"

assert_not_wired "本文に if を挟んだ 1 行定義の後ろの呼び出しは走らない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { if true; then :; fi; bash ${SUITE_PATH}; }"

assert_not_wired "本文にループを挟んだ 1 行定義の後ろの呼び出しは走らない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { for x in a; do :; done; bash ${SUITE_PATH}; }"

assert_not_wired "本文にブレースを挟んだ 1 行定義の後ろの呼び出しは走らない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { { :; }; bash ${SUITE_PATH}; }"

# **呼んだ場合も入れ子でない定義と同じ答えになること。** 呼び出しの本文を実行の証拠に
# しないのは「間接的な呼び出し（既知の限界）」の節で固定済みの fail-closed な扱いで、
# 素の `f() { bash x; }` ＋ `f` も `not-wired` になる。修正前の入れ子の綴りは
# ここだけ `wired` を返していたが、それは呼び出しを追えていたからではなく
# **階層が 1 つ足りず本文が最上位のコードに見えていた**ためで、
# 「呼ばない」ケースと答えが同じになっていた（＝呼ぶ／呼ばないを区別できていなかった）
assert_not_wired "入れ子の 1 行定義でも、呼び出しの扱いは素の定義と同じ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { g() { : ; }; bash ${SUITE_PATH}; }
          f"

assert_not_wired "素の 1 行定義を呼んだ場合（比較用の基準）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { bash ${SUITE_PATH}; }
          f"

# 1 断片が 2 つ以上開けるようになった副作用を固定する 3 件（いずれもレビューで実測）。
# **`case` が断片の先頭に無い綴りでも、アーム模様の `|` はパイプではない。**
# `^case` で見るとアーム模様をパイプと読み、囲っている階層に子シェルの印を付けて
# そのアームの `set +e` を丸ごと捨てる（握り潰しが「ゲート」に化ける fail-open）
# 締めすぎない側: 見送るのは「この断片から**出ていく** `|`」が模様の区切りでありうるときだけ。
# 入ってくる `|` は前の断片に付いていたもので、`case` の外から来ている以上模様ではない
# （まとめて見送ると、パイプの右側で `case` を開く綴りで子シェルの印が付かず、
#   中の `set +e` が親に効いたものとして扱われる）
assert_wired "パイプの右側で case を開いても子シェルとして扱う" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          echo x | { case zz in
          zz) set +e ;;
          esac
          }
          bash ${SUITE_PATH}"

assert_not_wired "ブレースの中で開いた case の選択肢アームの set +e は数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { case zz in (zz|yy) : ; set +e ;; esac; }
          bash ${SUITE_PATH}"

# **1 断片の中で入れ子に定義した関数は、外側の名前で台帳に載せる。**
# `set` を探す側は最奥の本文まで一気に落とした結果を外側の定義の断片で読むので、
# 内側の名前で控えると記録と参照の名前が食い違い、呼んでも反映されない
assert_not_wired "入れ子の 1 行定義の本文の set +e も、呼べば効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          g() { f() { set -e; set +e; }; f; }
          g
          bash ${SUITE_PATH}"

# **台帳の階層は「断片の末尾で開き終わった後の深さ」**。「定義を開く断片なら +1」と
# 決め打ちすると、1 断片が 2 つ開く綴りで記録側と打ち消し側が 1 つずれ、
# 本文で戻している関数が「弱める関数」として残る（正しくゲートする綴りを赤くする）
assert_wired "本体がブレースで囲まれていても set -e で打ち消せる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { { set +e; set -e; }; }
          f
          bash ${SUITE_PATH}"

# 台帳の名前は「`set` を探す側がどの名前に帰属させるか」に合わせる。断片の先頭が
# 定義でないとき（`{ f() { …`）まで外側の名前へ寄せると名無しになり、
# 記録そのものが落ちて握り潰しが見えなくなる
assert_not_wired "ブレースの中で開いた定義の本文の set +e も、呼べば効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { f() {
          set +e
          bash ${SUITE_PATH}
          }
          }
          f
          bash ${SUITE_PATH}"

# **閉じ語も 1 断片に 2 つ以上載る。** 開き側が複数開けるのに閉じ側が 1 つしか
# 閉じないと、以降が「まだ関数の本体の中」に見えて正しくゲートする綴りを赤くする
assert_wired "1 断片に閉じ語が 2 つ載っても深さが戻る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { if :; then
          :
          fi }
          bash ${SUITE_PATH}"

# 模様の位置かどうかを見るのは**断片の先頭の閉じ語だけ**。2 つ目以降はもう模様ではない
# （`esac }` の `}` を模様と読むと階層が戻らず、以降が「まだ関数の本体の中」に見える）
assert_wired ";; の後ろの esac } は 2 つとも閉じる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { case x in
          a) : ;; esac }
          bash ${SUITE_PATH}"

# `case` の入れ子は `depth` とは独立に数える。閉じ側のループは `depth > 0` で止まるので、
# 「階層は別の綴りが先に閉じてしまい `esac` が深さ 0 で来る」場合に数え損ねると、
# 以降ずっと「`case` の中」に見えてパイプの子シェル判定が外れる
assert_wired "深さ 0 で来た esac も case の入れ子を戻す" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case zz in
          zz) ! if false; then :; fi ;;
          esac
          echo x | while read -r l; do set +e; done
          bash ${SUITE_PATH}"

# 模様が `|` で複数の選択肢に切られていれば、その間ずっと模様の位置。
# 1 つ目しか守らないと、選択肢を 1 つ増やすだけで `case` の階層が畳まれる
assert_wired "2 つ目の選択肢に来た閉じ語も模様として読む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case zz in
          a|done|zz) : ;;
          esac
          echo x | while read -r l; do set +e; done
          bash ${SUITE_PATH}"

# `set` を記録する階層に数えるのは **`case` のアームの分だけ**。開いた階層の数
# （`count_opens()`）に置き換えると、**ブレースグループは同じシェル**なのに
# `{ set +e; }` の外の `set -e` が打ち消せなくなり、**`if set +e; then` の `set` は
# 条件の位置＝外側の深さで走る**のに 1 つ深く記録される（どちらも正しくゲートする
# 綴りを赤くする。レビューで実測）。この 2 つを対で固定する
assert_wired "ブレースグループの外の set -e は打ち消せる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for i in 1 2; do
          { set +e; }
          set -e
          done
          bash ${SUITE_PATH}"

# 同じ 2 つを**関数の本文**でも固定する（台帳側の階層は別の変数で数えているので、
# 片方だけ直すともう片方が黙って残る。実際この対が無かったために 1 巡見落とした）。
# 台帳の階層は「その関数の本体の階層」であって `set` が走る階層ではない
assert_wired "関数の本文でもブレースグループの外の set -e は打ち消せる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() {
          { set +e; }
          set -e
          }
          f
          bash ${SUITE_PATH}"

assert_wired "関数の本文でも条件の位置の set +e を打ち消せる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { if set +e; then :; fi; set -e; }
          f
          bash ${SUITE_PATH}"

# 最上位で定義した関数の台帳は、無関係な複合コマンドがフォークして閉じても消えない
assert_not_wired "最上位の定義の台帳はフォークで消えない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          quiet() { set +e; }
          for f in a b; do echo \"${DOLLAR}f\"; done | sort
          quiet
          bash ${SUITE_PATH}"

assert_wired "条件の位置の set +e も外側の set -e で打ち消せる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          for i in 1 2; do
          if set +e; then :; fi
          set -e
          done
          bash ${SUITE_PATH}"

# **既知の締めすぎ（fail-closed）。** 関数の本文で子シェルの中に置いた `set +e` は、
# 呼んでも呼び出し元へ漏れない（フォークするため）のに台帳へ残るので、呼び出しの時点で
# 弱めたものとして扱われる。**巻き戻しを「閉じた階層より深い記録を落とす」形にすると
# 直るが、それは fail-open を開く**——最上位で定義した関数（本文は深さ 1）が、無関係な
# 複合コマンドが深さ 0 でフォークして閉じただけで台帳から消え、握り潰されたスイートが
# 「ゲートしている」と読まれる（レビューで実測）。階層の数値だけでは「この複合の中で
# 控えたか」を区別できないので、区別できる印を持たせるまでは締めすぎ側で固定する
assert_not_wired "子シェルの中の set +e も関数の台帳には残る（既知の締めすぎ）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f311() {
          case zz in (zz|yy) set +e ;; esac | cat
          }
          f311
          bash ${SUITE_PATH}"

# **アーム見出しの後ろは命令の位置。** 剥がさないと、アームの中で開いた複合コマンドが
# 1 つも数えられず、後の `esac` が外側の `case` の階層を閉じてしまう。
# 「模様を消費したか」を `set_arm_here` で代用すると、外側のアームの中で内側の `case` を
# 開く綴りで真になり、内側の模様（`(p|q)`）を読めずアームの `set +e` が捨てられる
assert_not_wired "外側のアームの中で開いた case の選択肢アームも読む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case ${DOLLAR}X in
          a) case ${DOLLAR}Y in
          (p|q) set +e ;;
          esac ;;
          esac
          bash ${SUITE_PATH}"

# アームの中で開いたループも数える（数えないと `done` が `case` の階層を閉じ、
# 一致しないアームの中身が最上位のコードとして読まれる）
assert_not_wired "アームの中で開いたループの後ろの呼び出しは最上位ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case never in
          a) for i in 1; do :; done
          bash ${SUITE_PATH}
          ;;
          esac"

# **模様の位置では閉じ語も模様。** `done|other)` の `done` は模様であって
# `do … done` の閉じではない。閉じ扱いすると `case` の階層をそこで畳み、
# 直前のアームで見た `set +e` まで巻き戻される
assert_not_wired "模様の位置の done は閉じ語ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case ${DOLLAR}X in
          a) set +e ;;
          done|other) : ;;
          esac
          bash ${SUITE_PATH}"

# 締めすぎない側: 模様の位置に来た `esac` は空の `case` の終わりで、本当に閉じる
assert_wired "模様の位置の esac は空の case を閉じる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case ${DOLLAR}X in
          esac
          bash ${SUITE_PATH}"

# `case` の入れ子も閉じ側のループで数える。`^esac` だけを見ると `depth` は正しく戻るのに
# `case_depth` だけが残り、以降の最上位のコードが「`case` の中」に見えて
# パイプの子シェル判定が外れる（握り潰しでないものを握り潰しと読み、赤くする）
assert_wired "1 断片の 2 つ目の esac も case の入れ子を戻す" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case a in
          a)
          if :; then
          :
          fi esac
          echo x | while read -r l; do set +e; done
          bash ${SUITE_PATH}"

# アーム模様の位置も「この断片で `case` の入れ子が増えたか」で見る。
# `^case` で見ると `{ case x in` の次の行の `(x|y)` を模様と読めず、
# 幻の部分シェルが開いてアームの `set +e` が捨てられる
assert_not_wired "ブレースの中で開いた case の次行の選択肢アームも読む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { case x in
          (x|y) set +e ;;
          esac; }
          bash ${SUITE_PATH}"

# 締めすぎない側: 定義の**後ろ**の最上位のコードは今までどおり最上位として読む
assert_wired "入れ子の 1 行定義の次の行の呼び出しは最上位" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { g() { : ; }; : ; }
          bash ${SUITE_PATH}"

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

# **前の手順の名前に書かれた区切り文字が、後ろの手順の実行を消してはいけない。**
# 上の構造行の契約が守る規則を、消費側（配線の検査）から見た形でも押さえる。
# ブロック形式の平文にある `,` の直後のアポストロフィを引用スカラーの開始と読むと、
# 閉じない引用が次の行以降へ引き継がれて `run: |` が本文として扱われなくなり、
# **本文に書かれた検証コマンドが抽出から丸ごと消える**（実測で `not-wired` に化けた）。
# 手順名は PyYAML が 1 つの平文として読む、なんの変哲もない文字列
assert_wired "前の手順名の読点とアポストロフィは後ろの手順の実行を消さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: Build image, 'tis the slow step
        run: echo build
      - name: subject
        run: |
          bash ${SUITE_PATH}"

# --- 構造行の書き出し（`emit_structural_lines`）の契約 -----------------------------
#
# **この共有トークナイザの規則を、消費側の正規表現越しでなく直接固定する。**
# issue #93 の対応で入れた「引用に囲まれたスカラーの中のフロー区切りを伏せる」処理は、
# これまで `action_pin_test.sh` の位置規則を通してしか検査されていなかった。つまり伏せる処理を
# 丸ごと消しても、このスイートも網羅性検査も緑のままだった（実測）。トークナイザの契約が
# 消費側 1 つの実装詳細に人質を取られている状態なので、ここで直接押さえる。

# 仮ワークフローの連番（ケースごとに別名にして、失敗した入力がディスクに残るようにする）
STRUCTURAL_SEQ=0

# 合成したワークフローを `emit_structural_lines` に 1 度だけ通し、全出力を
# `STRUCTURAL_OUT` に置く。**仮ファイルの名前も呼び出しもここだけが持つ**（呼び出し側が
# 同じパスを書き写すと、名前の付け方を変えたときに「別のファイルを見て緑」になる）
structural_emit() {
    # 引数を意味の分かる名前に取り出す（ワークフロー本文）
    local body="$1"
    # 検査ごとに別名の仮ワークフローを作る（失敗したケースの入力がディスクに残るように）
    STRUCTURAL_SEQ=$((STRUCTURAL_SEQ + 1))
    local path="${TMP_DIR}/structural-${STRUCTURAL_SEQ}.yml"
    # 合成ワークフローを書き出す
    printf '%s\n' "${body}" > "${path}"
    # 構造行の全出力を控える（emit はこの 1 回だけ）
    STRUCTURAL_OUT="$(emit_structural_lines "${path}")"
}

# 構造行が期待どおりかを数える。第 1 引数がケース名、第 2 引数が期待する内容、
# 第 3 引数がワークフロー本文、第 4 引数が見たい行番号
assert_structural_line() {
    # 仮ワークフローを作って構造行の全出力を取る
    structural_emit "$3"
    # **構造行が 1 行でも出ているかを先に確かめる。** 期待値が空文字のケース
    # （ブロックスカラーの本文が漏れないこと）は、解析器が丸ごと壊れて何も出なくなった場合にも
    # 一致してしまう（「不在＝合格」。このリポジトリが繰り返し塞いできた形）
    if [ -z "${STRUCTURAL_OUT}" ]; then
        report_fail "$1" "構造行が 1 行も書き出されなかった（解析器が壊れています。行の中身以前の失敗）"
        return
    fi
    # 控えた出力から目的の行だけを取り出し、行番号の接頭辞を落とす
    local actual
    actual="$(printf '%s\n' "${STRUCTURAL_OUT}" | awk -F: -v n="$4" '
        $1 == n { sub(/^[0-9]+:/, ""); print }')"
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

# **YAML のノードプロパティ（アンカー `&name`）を挟んでも、引用の中身は伏せられること（issue #124）。**
# 読み飛ばせていないと引用符の直前が `n` になって値の開始と認められず、`#` が生のまま残る。
# するとこの行を読む消費側がそこで行を切り、**後ろの本物の `secrets:` を捨てて特権ワークフローを
# read-only と誤判定する**＝ FR-9.6(b) の SHA ピン強制がそのファイルから丸ごと外れる（**fail-open**）
assert_structural_line "アンカーを挟んだ引用値の中の # も伏せられる" \
    '      - name: &n a: ~b' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: &n "a: #b"' 6

# タグ（`!!str`）でも同じこと。プロパティは `&` と `!` の 2 種類あるので、
# 片方だけを読み飛ばす直し方では綴りを変えるだけで穴が戻る
assert_structural_line "タグを挟んだ引用値の中の # も伏せられる" \
    '      - name: !!str a: ~b' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: !!str "a: #b"' 6

# YAML はアンカーとタグを**両方・任意の順で**並べられるので、連続しても読み飛ばせること
assert_structural_line "アンカーとタグを並べても引用値の中の # は伏せられる" \
    '      - name: &n !!str a: ~b' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: &n !!str "a: #b"' 6

# **逆向きの守り: 読み飛ばしを緩めすぎないこと。** 値の途中に現れた `&` はただの文字で、
# その後ろの引用符は値の開始ではない。ここを開始と認めると**本物の区切りごと伏せて**
# `uses: actions/evil@v1` を見逃す（いま塞いだのと同じ向きの穴が別経路で開く）。
# 伏せていなければ読点が構造として残り、可変タグは検査対象として見える
assert_structural_line "素のスカラー途中の & の後ろでは伏せない" \
    '      - name: a &n b, uses: actions/evil@v1' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: a &n "b, uses: actions/evil@v1"' 6

# **複数行にまたがる引用スカラーの続きの行でも、中身の `#` は伏せること（issue #124）。**
# 伏せないと消費側がそこで行を切り、後ろの `uses:` / `secrets:` を丸ごと捨てる（**fail-open**）
assert_structural_line "引用の続きの行でも中身の # は伏せられる" \
    '      ~b, uses: actions/evil@v1}]' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{name: "a
      #b", uses: actions/evil@v1}]' 6

# **逆向きの守り: 閉じ引用符より後ろの `#` は本物のコメントなので伏せないこと。**
# ここまで伏せると、コメントに書いた語が構造として読まれて幻の参照が出る
# （必須チェックが恒常的に赤くなる形。このファイルが繰り返し避けてきた失敗）
assert_structural_line "引用の続きの行でも閉じた後ろの # は残る" \
    '      , uses: actions/evil@v1}]  # note: x' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{name: "a
      ", uses: actions/evil@v1}]  # note: x' 6

# **閉じ引用符より後ろに別の引用値がある形。** 後ろは引用の外＝普通の YAML なので通常の判定に
# かける。ここを「引用符を落とすだけ」に留めると、`"b #c"` の中の `#` が伏せられず、
# **同じ行の後ろにある本物の `secrets:` がそこで切り落とされる**（この関数が塞いでいるはずの
# 穴が、閉じ引用符の後ろで再発する。セルフレビューで実測した **fail-open**）
assert_structural_line "続きの行の閉じた後ろにある引用値の中の # も伏せられる" \
    '      , note: b ~c, secrets: inherit, uses: actions/evil@v1}]' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{name: "a
      ", note: "b #c", secrets: inherit, uses: actions/evil@v1}]' 6

# **プロパティの名前に引用符を含む綴りは、プロパティとして読まないこと。**
# 読んで綴りをそのまま出力へ送ると、構造行に引用符が残って「構造行に引用符を 1 つも残さない」
# という FR-8.1 の前提（このファイルの別のケースが固定している）が黙って破れる。
# PyYAML もこの綴りを受け付けないので、従来どおり引用符を落とす経路へ倒すのが正しい
assert_structural_line "アンカー名に引用符を含む綴りはプロパティとして読まない" \
    '      - name: &ab c' \
    'name: ci
jobs:
  j:
    steps:
      - name: &a"b c' 5

# **名前が空のプロパティ（素の `&` だけ）も読まないこと。** YAML が受け付けない綴りで、
# プロパティとして読むと後ろの引用が開いて**本物の `, secrets:` を伏せてしまう**（隠す向き＝危険側）。
# 伏せなければ読点が構造として残り、特権判定に効く
assert_structural_line "名前が空のプロパティは読まない" \
    '  j: {name: & b, secrets: inherit, runs-on: x}' \
    'name: ci
jobs:
  j: {name: & "b, secrets: inherit", runs-on: x}' 3

# 行の**全体**が引用スカラーの中身に当たる（この行では閉じない）場合も、中身なので `#` を伏せる。
# 閉じる行と閉じない行で扱いが分かれると、間に 1 行挟むだけで穴が戻る
assert_structural_line "閉じない続きの行でも中身の # は伏せられる" \
    '      ~b' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{name: "a
      #b
      ", uses: actions/evil@v1}]' 6

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

# --- 引用スカラーの「開始位置」の規則（ここまでの契約と同じく直接押さえる） ---
#
# 開始位置の規則はどれも、緩めると**本物の区切りを伏せて `uses:` を見逃す** fail-open か、
# 厳しくすると**幻の参照で必須チェックが恒常的に赤くなる**かのどちらかに倒れる。
# 消費側の位置規則越しでしか検査されていないと、トークナイザ側の契約が
# `action_pin_test.sh` の正規表現に人質を取られたままになるので、ここでも固定する。

# **既知の残件**: 値を持たない鍵の次の行に置いた引用値は、行頭の引用符を開始と認めないため
# 伏せられない（幻の参照が出る側＝余分に赤くなる）。前の行を見て例外を作る実装は
# 複数行にまたがる引用で fail-open を 3 通り作ったため撤回した（requirements.md の (d)）
assert_structural_line "KNOWN RESIDUAL: 値を持たない鍵の次行の引用値は伏せられない" \
    '          compare pinning, uses: policy' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name:
          "compare pinning, uses: policy"' 7


# **引用を開いたまま終わった行は「値を持たない鍵」ではない。** 未終端の引用は素の姿へ倒して
# 書き出すので `steps: [{name: "a:` が `:` で終わって見えるが、次の行の先頭にあるのは
# **閉じる側**の引用符であって新しい値の始まりではない。ここを鍵と読むと、閉じ側を開始と誤読して
# 後ろの本物の区切りごと伏せ、`uses:` を見逃す（実測: main は `actions/evil@v1` を検出し、
# この守りを入れる前のこちらは 1 件も返さなかった。**fail-open**）
assert_structural_line "引用を開いたまま終わった行の次行では伏せない" \
    '      , uses: actions/evil@v1, note: x}]' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{name: "a:
      ", uses: actions/evil@v1, note: "x"}]' 6

# 同じ形の **3 行以上**版。行頭を開始と認める実装では、途中の行の見え方によって
# 閉じ側の引用符が開始と誤読され、`actions/evil@v1` が消えた（実測）。行内で完結する
# いまの判定ではどの行も伏せないので、読点は構造として残る
assert_structural_line "引用の中の途中の行でも鍵と認めない" \
    '      , uses: actions/evil@v1}]' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{name: "a:
      b:
      ", uses: "actions/evil@v1"}]' 7

# 引用スカラーが 1 つ出た時点で、行頭の「字下げと `-` だけ」の並びは終わっていること。
# ここを降ろさないと、後ろの `-` を並びの印と読んで次の引用符を開始と認め、
# 本物の区切りごと伏せてしまう（実測: 降ろさない実装では `actions/evil@v1` が消えた）
assert_structural_line "引用の後ろのハイフンは並びの印ではない" \
    '          a - b, uses: actions/evil@v1' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name:
          "a" - '"'"'b, uses: actions/evil@v1'"'"'' 7

# **閉じた**引用スカラーでも、行頭の印の並びはそこで終わっていること。
# 上のケースは行頭が引用符なので「落とした」経路を通る。こちらは `- ` の後ろで**開いて閉じる**ため
# 閉じ側の経路を通り、そこで降ろさないと後ろの `- ` を並びの印と読んで次の引用符を開始と認め、
# 読点を伏せて `actions/evil@v1` を取り逃がす（実測。2 つの経路は別々に押さえる必要がある）
assert_structural_line "閉じた引用の後ろのハイフンも並びの印ではない" \
    '      - a - b, uses: actions/evil@v1' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - "a" - '"'"'b, uses: actions/evil@v1'"'"'' 6

# 落とした引用符をまたいで**位置の記憶を持ち越さない**こと。持ち越すと、壊れた形で
# 「引用された鍵の直後の `:`」と誤認して本物の区切りを伏せる（`{"a"" :"b, secrets: …"}` で実測。
# 特権判定が read-only へ倒れ、ワークフロー内の可変タグが検査から全部外れる **fail-open**）
assert_structural_line "落とした引用符をまたいで位置の記憶を持ち越さない" \
    '  j: {a :b, secrets: inherit, runs-on: ubuntu-latest}' \
    'name: ci
jobs:
  j: {"a"" :"b, secrets: inherit", runs-on: ubuntu-latest}' 3

# 開始と認めずに**落とした**引用符でも、行頭の印の並びはそこで終わっていること。
# 降ろさないと、後ろの `- ` を並びの印と読んで次の引用符を開始と認め、区切りを伏せてしまう
# （実測: 降ろさない実装では読点が伏せられ、`actions/evil@v1` が抽出から消えた）
assert_structural_line "落とした引用符の後ろのハイフンも並びの印ではない" \
    '      - - b, uses: actions/evil@v1' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      -" - '"'"'b, uses: actions/evil@v1'"'"'' 6

# **引用スカラーの続きの行では、どこに引用符があっても伏せない。** 継続行に現れる引用符は
# 「閉じる側」かもしれず、開始位置の文字（`,` `{` `[` / 空白付きの `:` `-`）の直後に来ると
# 開始と誤読して後ろの**本物の区切り**ごと伏せる（実測: 可変タグが検査から消えた **fail-open**）。
# 続きの行かどうかは前の行が引用を開いたままかで分かり、この止め方は
# **伏せるのをやめる方向にしか効かない**ので、見立てを誤っても余分に赤くなるだけで済む
assert_structural_line "続きの行では閉じ側の引用符を開始と読まない" \
    '      ,, uses: actions/evil@v1}]' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{name: "a,
      ,", uses: "actions/evil@v1"}]' 6

# 続きの行の**脱出表記は終端ではない**こと。`\"` を終端と読むと引用の続きがそこで終わったことになり、
# 次の行から伏せる判断が復活して、そこにある**本物の区切り**を伏せてしまう
# （実測: 読点が `~` になり `actions/evil@v1` が抽出から消えた **fail-open**）
assert_structural_line "続きの行の脱出された引用符は終端ではない" \
    '      ,, uses: actions/evil@v1}]' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{name: "a,
      \", b,
      ,", uses: "actions/evil@v1"}]' 7

# 単一引用の側の脱出表記（`'"'"''"'"'` ＝ 2 つ続けたアポストロフィ）も終端ではないこと。
# **綴りを共有した `is_escape_at` の単一引用側だけを消しても、上の二重引用の case では緑のまま
# 通った**（実測）ので、両方の綴りをここで押さえる。観測点は「引用スカラーの続きの行は伏せない」
# という契約で、規則が壊れると 6 行目で span が閉じたことになり、7 行目に伏せる処理が復活して
# `p, uses: policy` が `p~ uses: policy` に変わる。
#
# **7 行目に幻の参照 `policy` は出ない。** 閉じ引用符より後ろは引用の外＝普通の YAML なので、
# そこは通常の判定にかける（issue #124）。`x:` の値 `'"'"'p, uses: policy'"'"'` は引用値として伏せられ、
# 読点が代役へ変わって参照に化けない。PyYAML はこの入力を
# `{'"'"'name'"'"': "a, '"'"', b, ", '"'"'x'"'"': '"'"'p, uses: policy'"'"', '"'"'uses'"'"': '"'"'actions/evil@v1'"'"'}` と読むので、
# 本物の参照は `actions/evil@v1` だけ＝**構造行の見え方が PyYAML の読みと一致する**。
# その本物の参照が同じ行に残っている（伏せすぎていない）ことも同時に押さえている
assert_structural_line "続きの行の単一引用の脱出表記も終端ではない" \
    '      , x: p~ uses: policy, uses: actions/evil@v1}]' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{name: '"'"'a,
      '"'"''"'"', b,
      '"'"', x: '"'"'p, uses: policy'"'"', uses: actions/evil@v1}]' 7

# 続きの行が閉じたら、**その次の行からは通常どおり伏せる**こと（止めっぱなしにすると、
# 以降のふつうの手順名でこの PR が直した幻の参照が戻る）
assert_structural_line "続きが閉じた次の行では通常どおり伏せる" \
    '      - {name: b~ uses: policy, uses: ./local}' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - {name: "a,
      "}
      - {name: "b, uses: policy", uses: ./local}' 8

# 逆に、**素のスカラーの継続行**の先頭にある引用符は開始ではない（伏せると本物の区切りが消える）
assert_structural_line "継続行の先頭の引用符では伏せない" \
    '      b, uses: actions/evil@v1, z: 1}, {uses: ./local}]' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{name: a
      '"'"'b, uses: actions/evil@v1'"'"', z: 1}, {uses: ./local}]' 6

# 引用された鍵に続く `:` は空白が無くても開始（JSON 形式）
assert_structural_line "JSON 形式の引用された鍵の後は伏せられる" \
    '      - {name:a~ uses: policy, uses: ./local}' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - {"name":"a, uses: policy", uses: ./local}' 6

# 素の鍵に続く `:` は空白を要求する（`{name:"a` は鍵ごと 1 つのスカラーなので開始ではない）
assert_structural_line "素の鍵の後ろの空白なしの引用符では伏せない" \
    '      - {name:a, uses: actions/evil@v1, note: b}' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - {name:"a, uses: actions/evil@v1, note: b"}' 6

# 空白で囲まれていてもスカラー途中の `-` は並びの印ではない（伏せると可変タグが消える）
assert_structural_line "スカラー途中の空白付きハイフンでは伏せない" \
    '      - {name: Lint - tis time, uses: actions/evil@v1, note: its ok}' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - {name: Lint - '"'"'tis time, uses: actions/evil@v1, note: it'"'"'s ok}' 6

# --- ブロックスカラーの見つけ方（本文を構造と読み違えないこと） ---
#
# `run: |` の**本文**は YAML の構造ではなくただの文字列なので、そこに書かれた `uses:` を
# 宣言と読むと、実在しない参照で必須チェックが恒常的に赤くなる（このライブラリを切り出した理由）。
# 開始行の判定は**行末コメントを落としてから**行うので、その落とし方が壊れると
# `run: |  # 説明` が開始行として認識されず、本文が丸ごと構造として漏れ出す。

# ブロックスカラーの本文（`uses:` を含む）は構造行として書き出さないこと
assert_structural_line "行末コメント付きの run: | の本文は漏れない" \
    '' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |  # 説明
          uses: actions/evil@v1
      - uses: ./local' 7

# 同じ入力で**本文の後ろの行はきちんと出る**こと（上の空文字が「何も出ていない」ことの
# 裏返しにならないよう、走査が生きていることを同時に押さえる）
assert_structural_line "本文を読み飛ばしても後続の構造行は出る" \
    '      - uses: ./local' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |  # 説明
          uses: actions/evil@v1
      - uses: ./local' 8

# **引用スカラーの続きの行は、たとえ `run: |` の形をしていてもブロックスカラーを始めない。**
# その行は文字列の中身であって構造ではない。ここで始めてしまうと以降の行を本文として読み飛ばし、
# **その中にある本物の `uses:` が抽出から丸ごと消える**（違反 0 件で通る **fail-open**）。
# 下の入力は PyYAML では手順が 2 つで、2 つ目が `uses: actions/evil@v1` を持つ
# （`{'name': 'a run: | ', 'uses': 'actions/evil@v1'}`）。可変タグを載せた 9 行目が
# 書き出されることを固定する
assert_structural_line "続きの行が run: | の形でも本文として読み飛ばさない" \
    '            , uses: actions/evil@v1}' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./local
      - {name: "a
          run: |
            ", uses: actions/evil@v1}' 9

# **行末コメントの中で開いた引用符は、次の行へ引き継がない。** YAML のコメントは行末までなので、
# そこに書かれた `\"` は複数行にまたがる引用スカラーの始まりではない。引き継ぐと以降の行がすべて
# 「引用スカラーの続き」と見なされ、**`run: |` がブロックスカラーとして認識されなくなってシェル本文が
# 構造として漏れ出す**（実測: `run:` の本文の `uses: …@v1` が幻の参照として報告され、本文の
# `permissions: write-all` を宣言と読んで read-only のワークフローが特権と判定された。
# 必須チェックが恒常的に赤くなる **fail-open**）。PyYAML はこの入力の 2 つ目の手順を
# `{'run': 'uses: actions/evil@v1\n'}` と読む＝本文は文字列であって構造ではない
assert_structural_line "コメントの中の閉じない引用符は次の行へ引き継がない" \
    '' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./local   # see: "release notes
      - run: |
          uses: actions/evil@v1
      - uses: ./other' 8

# 同じ入力で**本文の後ろの行はきちんと出る**こと（上の空文字が「解析器が止まった」の裏返しに
# ならないよう、走査が生きていることを同時に押さえる）
assert_structural_line "コメントの引用符に足を取られても後続の構造行は出る" \
    '      - uses: ./other' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./local   # see: "release notes
      - run: |
          uses: actions/evil@v1
      - uses: ./other' 9

# **続きの行は「閉じたか」ではなく「末尾で何が開いているか」で見る。** 閉じた時点で打ち切ると、
# 同じ行の後ろでもう 1 つ引用が開く形を取り逃がし、次の行が「引用の中なのに普通の行」として扱われる。
# するとそこに書かれた `run: |` がブロックスカラーとして認識され、**続く行が本文として丸ごと落ちる**
# （**fail-open**。下の入力では 9・10 行目が構造行から消えていた）
assert_structural_line "続きの行の後ろで開き直した引用も引き継ぐ" \
    '            uses: actions/checkout@v7' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: "a
          b" note: '"'"'c
          run: |
            uses: actions/checkout@v7
            more string
          d'"'"'' 9

# **ブロック形式では `{` `[` `,` は構造ではなく、ただの平文。** これらを無条件に
# 「値が始まりうる位置」と読むと、素のスカラーの中の引用符（`Build image, '"'"'tis the slow step` の
# アポストロフィ）が引用スカラーの開始に化ける。その引用は行内で閉じないので
# **複数行スカラーとして次の行以降へ引き継がれ**、以降の行がすべて「続き」扱いになる。
# すると `run: |` がブロックスカラーとして認識されなくなり、本文が構造として漏れ出す
# （実測: 本文の `uses: …@v1` が幻の参照として報告され、同時に本文の検証コマンドが
# 抽出から消えて「配線されていない」と判定された。**両方向に壊れる**）。
# PyYAML はこの手順名を 1 つの平文 `Build image, 'tis the slow step` として読む。
#
# 3 つの区切り文字それぞれで押さえる（1 つだけ直しても他の 2 つで同じ穴が開くため）
for tight_case in "読点" "Build image, 'tis the slow step" \
                  "波括弧" 'Compare {a, "b} against c' \
                  "角括弧" "Compare [a, 'b] against c"; do
    # 2 語で 1 組なので、名前を控えたら次の回で本文を受け取る
    if [ -z "${tight_label-}" ]; then tight_label="${tight_case}"; continue; fi
    # ブロック形式の平文を手順名に持つワークフローを組み立てる
    tight_body="name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: ${tight_case}
      - run: |
          uses: actions/evil@v1
      - uses: ./other"
    # ブロックスカラーの本文（8 行目）は構造ではないので、1 行も書き出されてはいけない
    assert_structural_line "ブロック形式の${tight_label}の直後の引用符は開始と認めない" \
        '' "${tight_body}" 8
    # 同じ入力で後続の構造行が出ること（上の空文字が「解析器が止まった」の裏返しにならないように）
    assert_structural_line "ブロック形式の${tight_label}に足を取られても後続の構造行は出る" \
        '      - uses: ./other' "${tight_body}" 9
    # 次の組のために名前を空へ戻す
    tight_label=""
done
# ループで使った作業変数は後続のケースへ持ち越さない
unset tight_case tight_label tight_body

# **逆に、フロー形式の中の区切りの直後は今までどおり開始と認める。** 上の修正を
# 「`{` `[` `,` を開始位置から外す」で済ませると、`{name: a, "b, uses: policy": c}` の
# 引用の中の読点が伏せられなくなり、**幻の参照 `policy`**（issue #93 の 2 件目）が戻る。
# PyYAML はこの入力を `{'name': 'a', 'b, uses: policy': 'c'}` と読む＝読点は値の一部
assert_structural_line "フロー形式の中の読点の直後は引用スカラーの開始と認める" \
    '      - {name: a, b~ uses: policy: c}' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - {name: a, "b, uses: policy": c}' 6

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

# --- awk プログラムの渡し方（引数長の崖を作り直さない） -----------------------------
#
# awk プログラムを**引数**で渡していたころ、Linux の `MAX_ARG_STRLEN`（1 引数 128 KiB。
# `ARG_MAX` を上げても変わらない固定値）まで残り 11 KiB しかなかった。コメントを
# 200 行足すだけで `awk: Argument list too long` になり、**解析が丸ごと死ぬ**
# （実測: 本 PR の追加で 136 KiB に達し、260 表明が一斉に落ちた）。
# いまは `-f` でファイルから読ませているので上限が無い。引数渡しへ戻すと
# この崖が復活するため、**上限を超える大きさのプログラムが通ること**で固定する。
# 「大きい」の基準は上限そのもの（131072）で、実装の都合を書き写さない
awk_arg_limit_case() {
    # 上限そのもの（Linux の `MAX_ARG_STRLEN` = 32 ページ × 4096）。**この値から詰め物の量を導く**
    # のが要点で、行数や行長を直接書くと、片方を削っただけで上限を下回っても
    # テストは緑のまま通り、**何も検査しなくなったことに誰も気付かない**（レビューで指摘）
    local arg_limit=131072
    # 上限を確実に超える詰め物を作る（awk のコメント行なので意味は変えない）
    local padding
    padding="$(awk -v want="$((arg_limit + 4096))" 'BEGIN {
        # 1 行分の長さを決める（コメント行なので中身は何でよい）
        line = "# "; while (length(line) < 200) { line = line "x" }
        # 上限を超えるまで行数を積む（行長から必要な本数を割り出す）
        for (i = 0; i * (length(line) + 1) < want; i++) { print line }
    }')"
    # **詰め物が本当に上限を超えているか**をここで確かめる。超えていなければ
    # このケースは崖を踏まないので、通っても何の証拠にもならない
    if [ "${#padding}" -le "${arg_limit}" ]; then
        report_fail "上限を超える大きさの awk プログラムでも走る" \
            "詰め物が上限（${arg_limit} バイト）を超えていない（${#padding} バイト）。この検査は何も固定していません"
        return
    fi
    # 詰め物を載せた小さなプログラムを、共有の入口経由で走らせる
    local workflow="${TMP_DIR}/arg-limit.yml"
    printf '%s\n' "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: bash ${SUITE_PATH}" > "${workflow}"
    # 詰め物 ＋ 1 行だけの本体。通れば「引数長の上限に縛られていない」ことが示せる
    local out
    out="$(ci_workflow_run_with_structure "${workflow}" "${TMP_DIR}/arg-limit" \
        "${padding}
        END { print \"reached\" }" 2>&1)" || {
        report_fail "上限を超える大きさの awk プログラムでも走る" \
            "解析器がプログラムを受け取れなかった（引数渡しに戻っていると MAX_ARG_STRLEN で落ちる）: ${out}"
        return
    }
    # 本体が実際に走ったことまで確かめる（受け取れても走らなければ意味がない）
    if [ "${out}" = "reached" ]; then
        report 0 "上限を超える大きさの awk プログラムでも走る"
    else
        report_fail "上限を超える大きさの awk プログラムでも走る" \
            "プログラムは受け取れたが本体が走っていない（出力: ${out}）"
    fi
}
awk_arg_limit_case

# 集計を出して、失敗が 1 件でもあれば非ゼロで終わる
harness_summary
