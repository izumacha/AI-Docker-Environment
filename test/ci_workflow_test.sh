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

# **握り潰しのピン**（`set +e` などで失敗が外へ出ないこと）は、スイートの**後ろに 1 行足して**
# 判定する。`run:` の終了状態は「最後に走ったコマンドの状態」なので、スイートが最後の行だと
# 握り潰しても失敗はそのままステップの終了状態になる（実 `bash -e` で GATES。issue #175 /
# #189 がこの fail-closed を挙げていた）。後ろに 1 行足せば握り潰しが観測でき、しかも
# **errexit が生きていれば位置に関わらず伝わる**ので、このピンは「`set` を読めているか」を
# 以前より強く固定する（読めていなければ errexit がその場で落とす＝wired になって落ちる）。
# 足す行は最後の行と同じ字下げに合わせる（`run: |` の中に収める）
assert_swallowed() {
    local workflow="$2" indent
    indent="$(printf '%s' "${workflow##*$'\n'}" | sed 's/[^ ].*//')"
    assert_verdict "not-wired" "$1" "${workflow}"$'\n'"${indent}echo done" "${3-}"
}

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
#
# **この節の握り潰しのピンは `run:` を 2 行にする**（`assert_swallowed` と同じ理由）。
# 自前テンプレート（`bash {0}`）は `-e` を外すだけで、スクリプトの終了状態は
# 「最後に走ったコマンドの状態」のままなので、1 行しかないと**スイートの失敗はそのまま
# ステップの失敗になる**（実測）。後ろに 1 行足すと `-e` が無いことが観測でき、
# 既定シェル（`-e` あり）との違いが出る

assert_not_wired "ステップの shell: が自前テンプレート（-e が消える）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        shell: bash {0}
        run: |
          bash ${SUITE_PATH}
          echo done"

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
        run: |
          bash ${SUITE_PATH}
          echo done"

assert_not_wired "ワークフローの defaults: が自前テンプレート" "name: ci
defaults:
  run:
    shell: bash {0}
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH}
          echo done"

assert_not_wired "defaults: が jobs: の後ろにあっても効く（キー順は自由）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH}
          echo done
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
        run: |
          bash ${SUITE_PATH}
          echo done"

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
        run: |
          bash ${SUITE_PATH}
          echo done
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

assert_swallowed "set +ex で errexit が落ちている" "name: ci
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
        run: |
          bash ${SUITE_PATH}
          echo done"

assert_not_wired "ジョブの defaults: の run: がフロー形式" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    defaults:
      run: {shell: bash {0}}
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH}
          echo done"

assert_not_wired "引用符付きの鍵（\"shell\": 自前テンプレート）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        \"shell\": bash {0}
        run: |
          bash ${SUITE_PATH}
          echo done"

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

# **鍵と指示子のあいだのノードプロパティ（アンカー `&name` / タグ `!tag` `!!str`）を挟んでも
# ブロックスカラーとして読む**（issue #126）。読まないとその行が開始と認められず、本文の
# シェルスクリプトが構造行として漏れて**実在するスイートが「未配線」になる**（fail-closed。
# `run: |` に `&suites ` を足すだけで答えが変わる）。直す場所は 2 つあり、構造行側だけだと
# 本文は読み飛ばされるのに抽出側の判定が外れ、`&suites |` が 1 行書きの値として読まれて
# `suites` という幻のコマンドだけが記録される（実測）
for node_prop_case in \
    "アンカー:&suites |" \
    "タグ:!!str |" \
    "独自タグ:!custom |" \
    "折りたたみ:&s >" \
    "chomping つき:&s |-" \
    "明示字下げ指示子つき:&s |2" \
    "逐語タグ:!<tag:yaml.org,2002:str> |"
do
    assert_wired "ノードプロパティを挟んだブロックスカラー（${node_prop_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: ${node_prop_case#*:}
            bash ${SUITE_PATH}"
done

# **折りたたみ（`>`）の判定にもプロパティを読ませる**（issue #126）。読まないと本文が
# 1 行ずつ別のコマンドとして読まれ、**次の行に置いた `|| true` が呼び出しと結び付かず、
# 握り潰された実行を「ゲートしている」と読む**（fail-open。ライブラリの `run_folded` の
# コメントが同じ理由を記録している）。
# **`bash` と パスを改行で割った形では固定できない**——畳まないと記録が 2 つに割れるが、
# 片方がパスそのもの（`test/subject_test.sh`）になり、それは**直接実行の綴りとして
# 正しく配線と数えられる**ので答えが変わらない（実測）
# **逐語タグ（`!<…>`）は素のスカラーの値からも落とす**（issue #182）。中身は URI 文字で
# フロー形式の区切りを含んでよく（`!<tag:yaml.org,2002:str>` の `,`）、短縮形のタグ用の
# 狭い集合では `,` で名前が切れて値を取り出せない（`main` から fail-closed。
# 同じ取りこぼしが構造行の側では**隠す向き**の fail-open になるのが issue #182 の本体で、
# そちらは `action_pin_test.sh` の特権判定のピンが固定する）
assert_wired "逐語タグを挟んだ素のスカラーの値を読む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: !<tag:yaml.org,2002:str> bash ${SUITE_PATH}"

# 締めすぎない側。**シェル側のタグ名の集合は区切りを含めない**（`CI_WORKFLOW_TAG_NAME`）。
# 根拠は YAML の定義ではない——**PyYAML は `!x,y` を名前 `!x,y` として compose する**（実測。
# issue #201 で `ns-tag-char` という断定を撤回した）。狭めてあるのは**この読み手では
# 広げると fail-open** だからで、伏せ処理の歩きは逆向き（広げないと fail-open）なので
# そちらは区切りで切らない。
# 名前が `!x,` まで伸びる綴りは**読まない**ので、値が取り出せず未配線に倒れる
# （`PyYAML` は名前 `!x,` ＋ 値 `bash <スイート>` と読むが、**GitHub の解析器は PyYAML ではない**
# ——確かめられない綴りで「ゲートしている」と言わない側へ倒す＝fail-closed。
# このピンは `CI_WORKFLOW_PROP_STOP_CHARS` から `,` を外す変異で落ちる）
# 同じく締めすぎない側。**逐語タグの中身に空白と二重引用符は含めない**（YAML の `ns-uri-char`）。
# 含む綴りは `PyYAML` も受け付けない（`ScannerError`）ので、値として読むと
# **走るか確かめられない綴りで「ゲートしている」と言い出す**（レビュー指摘。この差分の
# 最初の版が `[^>]+` と書いていて実際にそうなっていた＝実測で `main` は not-wired）
assert_not_wired "逐語タグの中身に二重引用符を含む綴りは値として読まない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: !<a\"b> bash ${SUITE_PATH}"

assert_not_wired "短縮形のタグの名前に区切りを含む綴りは値として読まない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: !x, bash ${SUITE_PATH}"

assert_not_wired "ノードプロパティを挟んだ折りたたみブロックでは次行の || true が掛かる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: &s >
          bash ${SUITE_PATH}
          || true"

# **明示字下げ指示子もプロパティの後ろから読む**（issue #126）。読まないと `|2` が指示子として
# 認められず基準字下げが未確定になり、最初の非空行から測った分だけ落として**深い位置に置いた
# 区切り語を終端と読む**（＝以降の本文が実行と読まれる）。上の「明示字下げ指示子つき」の対は
# 本文が 1 行なのでこの区別を押さえられず、ここでしか固定されない
assert_not_wired "プロパティ付きの明示字下げ指示子でも深い区切り語は終端ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: &s |2
            cat <<MARK
            one
            MARK
            bash ${SUITE_PATH}"

# **`shell:` の値からもプロパティを落とす**（issue #126 のレビューで実測）。
# `shell: &s bash` は値が `bash` の正当な YAML なのに、残すと「未知のシェル」に転んで
# 実際に走ってゲートしているステップが「未配線」になる（`run:` 側と同じ鍵と値の非対称）
for shell_prop_case in "アンカー:&s bash" "タグ:!!str bash"
do
    assert_wired "shell: の値のプロパティは落とす（${shell_prop_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        shell: ${shell_prop_case#*:}
        run: bash ${SUITE_PATH}"
done

# **`if:` の値からも落とす**（同じレビュー）。`if: &a true` は PyYAML も `True` と読むのに、
# 残すと「真偽を評価できない」側へ落ちてゲートしているステップが「未配線」になる
for cond_prop_case in "アンカー:&a true" "タグ:!!bool true"
do
    assert_wired "if: の値のプロパティは落とす（${cond_prop_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        if: ${cond_prop_case#*:}
        run: bash ${SUITE_PATH}"
done

# 締めすぎない側: プロパティを落としても**無効化の判定は効いたまま**
# （`continue-on-error: &a true` は握り潰しなので「配線されている」と言ってはいけない）
assert_not_wired "continue-on-error: のプロパティ付きの true は握り潰しのまま" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        continue-on-error: &a true
        run: bash ${SUITE_PATH}"

# **アンカーの名前は PyYAML / libyaml の実装に合わせて狭く読む**（issue #126 のレビューで実測）。
# 英数字・`-`・`_` は読み、それ以外を含む綴りは**読まない側＝fail-closed**へ落とす——
# `&a:b` は PyYAML が名前を `a` で切って値を `:b bash …` と読むので、広い集合で読むと
# 「走らないスイートをゲートしていると言う」fail-open になる
assert_wired "アンカーの名前に - と _ は使える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: &a-b_1 |
          bash ${SUITE_PATH}"

for narrow_anchor_case in "コロンを含む:&a:b" "ドットを含む:&shell.files"
do
    assert_not_wired "実装が受け付けないアンカー名は読まない（${narrow_anchor_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: ${narrow_anchor_case#*:} bash ${SUITE_PATH}"
done

# **素のスカラーに置いたプロパティも値から落とす**（issue #126 のレビューで実測）。
# `run: &suites bash test/x.sh` は値が `bash test/x.sh` の正当な YAML なのに、落とさないと
# `suites bash test/x.sh` という幻のコマンドが記録され、実行しているスイートが「未配線」になる
# （fail-closed。`main` から続く既存の穴）。**枝の選び分けではプロパティを読まない**ままにして、
# 値の取り出しでだけ落とす（2 か所で読む / 読まないが食い違うと同じ行が両方の枝に当たる）。
# **名前の無い `!` はここでは落とさない**（下の「! 経由の呼び出し」と同じ綴りになり、
# ランナーがシェルへ渡す側だと終了状態が反転してゲートしない＝fail-open）
for plain_prop_case in \
    "アンカー:&suites bash ${SUITE_PATH}" \
    "タグ:!!str bash ${SUITE_PATH}"
do
    assert_wired "素のスカラーのプロパティは値から落とす（${plain_prop_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: ${plain_prop_case#*:}"
done

# **`!` は名前なしでもよい**（YAML の非特定タグ。`run: ! |` は PyYAML も通す）。
# 名前を 1 文字以上に揃えると、この綴りだけ issue #126 の手当てから外れる
assert_wired "名前の無い非特定タグを挟んだブロックスカラー" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: ! |
          bash ${SUITE_PATH}"

# **締めすぎない側＝素の `&` はプロパティとして読まないこと**（`{name: & "b"}` は PyYAML も
# エラーにする綴り）。読むと後ろの引用が開いて**本物の `, secrets:` を伏せる**ので、
# `!` との非対称は意図したもの（伏せ処理側の `propend > i || ch == "!"` と対で保つ）
assert_not_wired "名前の無いアンカーはブロックスカラーを始めない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: & |
          bash ${SUITE_PATH}"

# **締めすぎない側＝プロパティに見える綴りでブロックを始めないこと。**
# `run: foo !bar |` は素のスカラー（`|` は指示子ではない）なので、本文の読み飛ばしを
# 始めてはいけない。`run: &s|` はプロパティと値のあいだに空白が無く YAML として正しくないので、
# 読まない側＝従来の姿へ倒す（fail-closed。伏せ処理が 1 文字ずつ歩くときの条件と同じ規則）
for node_prop_dead_case in \
    "素のスカラーの中の |:foo !bar |" \
    "空白の無いプロパティ:&s|"
do
    assert_not_wired "プロパティに見えてもブロックを始めない（${node_prop_dead_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: ${node_prop_dead_case#*:}
          bash ${SUITE_PATH}"
done

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

assert_swallowed "通らない分岐の set -e は握り潰しを隠さない" "name: ci
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
assert_swallowed "通るか分からない分岐の set +e も握り潰しとして数える" "name: ci
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
assert_swallowed "通らないかもしれない分岐の set +e は安全側に倒して数える" "name: ci
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
assert_swallowed "通るか分からない分岐の set -e は握り潰しを打ち消さない" "name: ci
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
assert_swallowed "制御構造の中の set +o errexit も握り潰しとして数える" "name: ci
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

assert_swallowed "1 行の if …; then set +e; fi も握り潰しとして数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}CI\" ]; then set +e; fi
          bash ${SUITE_PATH}"

assert_swallowed "1 行の for …; do set +e; done も握り潰しとして数える" "name: ci
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
assert_swallowed "ブレースグループの中の set +e は無条件に効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { set +e; }
          bash ${SUITE_PATH}"

# `if false` の**else 側は必ず走る**。偽の印を持ち越すと 1 行で握り潰しを隠せる
assert_swallowed "偽と分かる条件の else 側の set +e は効く" "name: ci
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

assert_swallowed "set -e +e は後ろの +e が勝つ" "name: ci
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

assert_swallowed "1 行の then の中のブレースグループの set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}CI\" ]; then { set +e; }; fi
          bash ${SUITE_PATH}"

assert_swallowed "1 行の case アームの中の set +e" "name: ci
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
assert_swallowed "&& で守られた set -e は握り潰しを打ち消さない" "name: ci
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
assert_swallowed "真と分かる条件は elif を挟んでも残りのアームが走らない" "name: ci
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
assert_swallowed "パイプの中の set -e は親の握り潰しを打ち消さない" "name: ci
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
assert_swallowed "バックグラウンドの set -e は親の握り潰しを打ち消さない" "name: ci
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
assert_swallowed "先頭に ( を書いた case アームの set +e" "name: ci
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

assert_swallowed "set \"+e\" は set +e と同じ" "name: ci
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
assert_swallowed "1 行で定義した関数を呼ぶと本文の set +e が効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          f
          bash ${SUITE_PATH}"

assert_swallowed "複数行で定義した関数を呼ぶと本文の set +e が効く" "name: ci
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

assert_swallowed "function 綴りで定義した関数を呼んでも効く" "name: ci
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
assert_swallowed "set +o errexit を持つ関数を呼んでも効く" "name: ci
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
assert_swallowed "引数を付けて呼んでも本文の set +e が効く" "name: ci
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
assert_swallowed "then の後ろで呼んでも本文の set +e が効く" "name: ci
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
assert_swallowed "本文が set -e の関数を呼んでも強める向きは credit しない" "name: ci
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

assert_swallowed "ブレースグループ越しの呼び出しでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          { f; }
          bash ${SUITE_PATH}"

assert_swallowed "! を前置きした呼び出しでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          ! f
          bash ${SUITE_PATH}"

assert_swallowed "eval 越しの呼び出しでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          eval f
          bash ${SUITE_PATH}"

assert_swallowed "time 越しの呼び出しでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          time f
          bash ${SUITE_PATH}"

assert_swallowed "変数代入を前置きした呼び出しでも効く" "name: ci
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
assert_swallowed "定義し直して弱めるようになれば効く" "name: ci
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
assert_swallowed "条件の中でしか戻さない関数は打ち消しにならない" "name: ci
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

assert_swallowed "条件の位置の set +e も効く（if）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if set +e; then :; fi
          bash ${SUITE_PATH}"

assert_swallowed "条件の位置の set +e も効く（while）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          while set +e; do break; done
          bash ${SUITE_PATH}"

assert_swallowed "条件の位置の set +e も効く（until）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          until set +e; do break; done
          bash ${SUITE_PATH}"

assert_swallowed "条件の位置の set +e も効く（elif）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if false; then :; elif set +e; then :; fi
          bash ${SUITE_PATH}"

# 呼び出しも同じ位置に書ける（剥がす一覧を共有していないと 3 トークンで抜けられる）
assert_swallowed "条件の位置の呼び出しでも本文の set +e が効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          if f; then :; fi
          bash ${SUITE_PATH}"

assert_swallowed "while の条件で呼んでも本文の set +e が効く" "name: ci
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
assert_swallowed "条件の位置の set -e は打ち消しに使わない" "name: ci
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

assert_swallowed "1 行の POSIX アームの後ろの呼び出しでも効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          case linux in (linux) f ;; esac
          bash ${SUITE_PATH}"

assert_swallowed "2 行に分けた POSIX アームでも効く" "name: ci
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
assert_swallowed "アームの中身の呼び出しは引数のコマンド置換で消えない" "name: ci
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

assert_swallowed "入れ子の 1 行定義でも呼べば set +e が効く" "name: ci
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

assert_swallowed "1 行で入れ子にした if false の中の set -e は効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          if true; then if false; then set -e; fi; fi
          bash ${SUITE_PATH}"

assert_swallowed "1 行で入れ子にした while false の中の set -e は効かない" "name: ci
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
assert_swallowed "ブレースグループの中に 1 行で入れ子にした if false" "name: ci
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
assert_swallowed "入れ子の else は内側の if に結び付く" "name: ci
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
assert_swallowed "見出しの次の行の { set -e; } は定義の本文" "name: ci
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

assert_swallowed "set +eE は errexit を落とす" "name: ci
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
assert_swallowed "eval \"set +e\" は現在のシェルで効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          eval \"set +e\"
          bash ${SUITE_PATH}"

assert_swallowed "builtin set +e も同じ組み込み" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          builtin set +e
          bash ${SUITE_PATH}"

assert_swallowed "command set +e も同じ組み込み" "name: ci
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
assert_swallowed "外側の set +e は内側の set -e で戻らない" "name: ci
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
assert_swallowed "別ブロックの同じ深さの set -e では戻らない" "name: ci
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

assert_swallowed "case … in (a) set +e を 1 行で書いた綴り" "name: ci
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
assert_swallowed "内側の括りは外側の set +e を消さない" "name: ci
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
assert_swallowed "set +e foo -e の -e は位置パラメータ" "name: ci
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
assert_swallowed "既知の残件: ブレースグループの中の set -e は credit しない" "name: ci
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
          bash ${SUITE_PATH}
          echo done"

# 括りの記録は errexit のものなので、pipefail の判断には使わない。
# **いまこの形を止めているのは `uncertain == 0`**（issue #203 で門番を
# 「確実に走るか」へ置き換えたので、errexit の括り記録は読まなくなった）。
# ループの本文は走ると証明できないので、その中の set -o pipefail は credit しない
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

# --- 部分シェル・ブレースの中の set -o pipefail（issue #203） ------------------
#
# `pipefail` は `bash -e` の既定で**立っていない**ので、強める向きの門番を
# errexit と共有すると「同じ階層に `set +e` の記録があるときだけ credit する」
# という無関係な条件になり、隣に `set +e` を書かない限り部分シェル・ブレースの
# 中では**一度も credit できない**。実 bash（番兵なし）では下の 10 形すべてで
# スイートの失敗が job へ伝わる（真値 GATES）のに、`main` は not-wired と答えて
# いた＝**正しくゲートしているスイートを赤くする fail-closed**。
# 門番は「その `set` が確実に走るか」（命令の位置で見つけた綴り・定義の本文でない・
# 走ると証明できない階層の中でない・連鎖の右辺なら左辺のリテラルが走ると言う）

for pipefail_scope_case in \
    "部分シェルの中（複数行）:(
          set -euo pipefail
          bash ${SUITE_PATH} | cat
          )" \
    "ブレースの中（開きと同じ行）:{ set -o pipefail
          bash ${SUITE_PATH} | cat
          }" \
    "部分シェルを 1 行に畳んだ形:( set -o pipefail; bash ${SUITE_PATH} | cat )" \
    "ブレースを 1 行に畳んだ形:{ set -o pipefail; bash ${SUITE_PATH} | cat; }" \
    "飾りの後ろの部分シェル:time (
          set -o pipefail
          bash ${SUITE_PATH} | cat
          )" \
    "入れ子の部分シェル:(
          (
          set -o pipefail
          bash ${SUITE_PATH} | cat
          )
          )" \
    "部分シェルの中のブレースは閉じても残る:(
          {
          set -o pipefail
          }
          bash ${SUITE_PATH} | cat
          )" \
    "while の条件の位置:while set -o pipefail; do break; done
          bash ${SUITE_PATH} | cat" \
    "結論の分かる連鎖の右辺:true && set -o pipefail
          bash ${SUITE_PATH} | cat" \
    "部分シェルの中で定義だけ越える:( f() { :; }
          set -o pipefail
          bash ${SUITE_PATH} | cat
          )"
do
    assert_wired "部分シェル・ブレースの中の set -o pipefail（${pipefail_scope_case%%:*}）はパイプの失敗を伝える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${pipefail_scope_case#*:}"
done

# 締めすぎない側の控え。**どれも実 bash では伝わらない**（真値 NOGATE）ので、
# 上の緩和がここまで広がっていないことを 1 形ずつ固定する。
# 門番のどれを外しても、ここのどれかが赤くなる。
# **コマンド置換の 4 形と連鎖の右辺で開いた複合の 3 形はレビュー 1 巡目で足した**——
# 前者は `strip_command_prefixes()` の代入の規則が `X=$(` までを前置きとして落とすため、
# **子シェルで走る `set` を親の指定として credit していた**（この差分が入れた fail-open）。
# 後者は `chain_in` が区切りの**直後の断片**にしか立たないため、連鎖の右辺で開いた
# 複合の**中**の `set` を credit していた（`main` も同じ fail-open で、ここで一緒に閉じる）

for pipefail_scope_control in \
    "部分シェルを閉じたら入口へ戻る:(
          set -o pipefail
          )
          bash ${SUITE_PATH} | cat" \
    "内側の部分シェルを閉じたら戻る:(
          (
          set -o pipefail
          )
          bash ${SUITE_PATH} | cat
          )" \
    "ブレースの中の部分シェルも戻る:{
          (
          set -o pipefail
          )
          bash ${SUITE_PATH} | cat
          }" \
    "一致しないアームの set は走らない:case x in a) set -o pipefail ;; esac
          bash ${SUITE_PATH} | cat" \
    "越えた定義の本文の set は呼ぶまで走らない:( f() { set -o pipefail; }
          bash ${SUITE_PATH} | cat
          )" \
    "定義の本文の set（複数行）:f() {
          set -o pipefail
          }
          bash ${SUITE_PATH} | cat" \
    "定義の本文の set（1 行）:f() { set -o pipefail; }
          bash ${SUITE_PATH} | cat" \
    "コマンド置換の中の set:X=${DOLLAR}( set -o pipefail )
          bash ${SUITE_PATH} | cat" \
    "引用付きのコマンド置換の中の set:X=\"${DOLLAR}( set -o pipefail )\"
          bash ${SUITE_PATH} | cat" \
    "代入を 2 つ並べたコマンド置換:A=1 X=${DOLLAR}( set -o pipefail )
          bash ${SUITE_PATH} | cat" \
    "コマンド置換の中で飾りを付けた set:X=${DOLLAR}( command set -o pipefail )
          bash ${SUITE_PATH} | cat" \
    "連鎖の右辺で開いた複合の中（読めない左辺）:test -n \"${DOLLAR}SKIP\" && {
          set -o pipefail
          }
          bash ${SUITE_PATH} | cat" \
    "連鎖の右辺で開いた複合の中（結論が偽）:false && {
          set -o pipefail
          }
          bash ${SUITE_PATH} | cat" \
    "連鎖の右辺で開いた複合の中（|| 側）:test -n \"${DOLLAR}HOME\" || {
          set -o pipefail
          }
          bash ${SUITE_PATH} | cat" \
    "結論が偽の連鎖の右辺:( false && set -o pipefail
          bash ${SUITE_PATH} | cat
          )" \
    "読めない左辺の連鎖の右辺:( test -z \"${DOLLAR}HOME\" && set -o pipefail
          bash ${SUITE_PATH} | cat
          )" \
    "フォークしたブレースの中:{ set -o pipefail; } | cat
          bash ${SUITE_PATH} | cat" \
    "set 自身がパイプの左側:set -o pipefail | cat
          bash ${SUITE_PATH} | cat" \
    "走ると証明できない条件の中:( if false; then set -o pipefail; fi
          bash ${SUITE_PATH} | cat
          )" \
    "手前の条件が真なら評価されない elif:if true; then :; elif set -o pipefail; then :; fi
          bash ${SUITE_PATH} | cat" \
    "到達しない位置の set:(
          exit 0
          set -o pipefail
          bash ${SUITE_PATH} | cat
          )"
do
    assert_not_wired "部分シェル・ブレースの緩和が届かない形（${pipefail_scope_control%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${pipefail_scope_control#*:}"
done

# --- 排他なアームは打ち消し合わない（同じ深さでも別の枝） ---------------------------
#
# `if …; then set +e; else set -e; fi` の 2 つは**排他**なので、
# else 側の `set -e` は then 側の `set +e` を打ち消さない。階層だけで見ると
# 同じ深さなので打ち消しが成立してしまい、握り潰されたスイートが
# 「ゲートしている」と読まれる（fail-open）

assert_swallowed "else 側の set -e は then 側の set +e を打ち消さない" "name: ci
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

assert_swallowed "elif 側の set -e も打ち消さない" "name: ci
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

assert_swallowed "長い綴りでも排他なアームは打ち消し合わない" "name: ci
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

assert_swallowed "別の case アームの set -e も打ち消さない" "name: ci
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
assert_swallowed "複数行で書いた case アームも打ち消し合わない" "name: ci
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
assert_swallowed "continue を挟んだ括りは打ち消しにしない" "name: ci
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
assert_swallowed "case の主語がコマンド置換でもアームを見つける" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case ${DOLLAR}(echo linux) in linux) set +e ;; esac
          bash ${SUITE_PATH}"

# アーム模様の `|` は選択肢の区切りであってパイプではない
assert_swallowed "選択肢を持つ case アームの set +e" "name: ci
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
assert_swallowed "閉じたブロックの括り記録は次のブロックへ持ち越さない" "name: ci
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
assert_swallowed "継続語の後ろに書いた case のアーム模様も選択肢と読む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then case \"${DOLLAR}X\" in a|b) set +e ;; esac; fi
          bash ${SUITE_PATH}"

assert_swallowed "ループの中に書いた case でも同じ" "name: ci
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
assert_swallowed "届く continue は括りを壊す" "name: ci
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

# **脱出する綴りの後ろは 1 つも走らない**（issue #151。`main` 既存の fail-open）。
# `if true; then exit 0; bash <スイート>; fi` と `while true; do break; bash <スイート>; done` は
# **2 トークンで必須スイートを止められる**のに「最上位で確実に走る」と記録されていた
# （実 `bash -e` ではスイートが 1 行も走らない。`exit` の次の行も同じ）
for unreachable_after_case in \
    "if true の中の exit:if true; then exit 0; bash ${SUITE_PATH}; fi" \
    "while true の中の break:while true; do break; bash ${SUITE_PATH}; done" \
    "最上位の exit の後ろ:exit 0
          bash ${SUITE_PATH}" \
    "ループの中の continue の後ろ:for i in 1; do continue; bash ${SUITE_PATH}; done" \
    "関数の本文の return の後ろ:f() { return 0; bash ${SUITE_PATH}; }
          f" \
    "連鎖のブロックを抜けた後ろの exit:[ -n \"${DOLLAR}X\" ] || { echo \"no X\"; }
          exit 0
          bash ${SUITE_PATH}"
do
    assert_not_wired "脱出の後ろ（${unreachable_after_case%%:*}）は実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${unreachable_after_case#*:}"
done

# --- 脱出語が bash で届く範囲（issue #204） --------------------------------------
#
# **`break` / `continue` はループの中でしか意味を持たない。** ループの外では bash が
# 診断（only meaningful in a for/while/until loop）を出して**実行を続ける**ので、
# 区間を終わらせてはいけない。以前は囲いの種類を見ずに終わらせていたため、下の 4 形は
# 真値 GATES なのに未配線＝**正しくゲートしているスイートを赤くする fail-closed**
# だった。ループを探すのは**同じシェルの中だけ**で、部分シェルと関数定義の本文で止まる
# （実測: bash 5.2 は `f() { break; }` を `for … do f; done` から呼んでも診断を出す）

for escape_reach_case in \
    "ブレースの中の break:{
          break
          bash ${SUITE_PATH}
          }" \
    "ブレースの中の continue:{
          continue
          bash ${SUITE_PATH}
          }" \
    "必ず走る条件の中の break:if true; then
          break
          bash ${SUITE_PATH}
          fi" \
    "部分シェルの中の break:(
          break
          bash ${SUITE_PATH}
          )" \
    "ループの中の部分シェルの break:while true; do
          (
          break
          bash ${SUITE_PATH}
          )
          break
          done" \
    "ループを閉じたら印も落ちる:for i in 1; do
          :
          done
          {
          break
          bash ${SUITE_PATH}
          }"
do
    assert_wired "ループの外の脱出語（${escape_reach_case%%:*}）は何もしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${escape_reach_case#*:}"
done

# **関数の本文の外の `return` はシェルを終わらせる。** bash は
# can only return from a function or sourced script を出して**非ゼロで返る**ので、
# `errexit`（GitHub Actions は `bash -e`）が立っていればその時点でシェルが終わる。
# 以前はいちばん内側の階層だけを終わらせていたため、閉じ括弧で印が解除されて
# 後ろのスイートが「走る」と記録されていた＝**必須スイートが黙ってゲートから外れる
# fail-open**（真値はいずれも NOGATE）

for return_ends_shell_case in \
    "ブレースの中（複数行）:{
          return 0
          }
          bash ${SUITE_PATH}" \
    "ブレースの中（1 行）:{ return 0; }
          bash ${SUITE_PATH}" \
    "結論の分かる連鎖の右辺:true && return 0
          bash ${SUITE_PATH}" \
    "必ず走る条件の中:if true; then
          return 0
          fi
          bash ${SUITE_PATH}" \
    "部分シェルの中のブレース:(
          {
          return 0
          }
          bash ${SUITE_PATH}
          )"
do
    assert_not_wired "関数の外の return（${return_ends_shell_case%%:*}）より後ろは実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${return_ends_shell_case#*:}"
done

# 締めすぎない側の控え。**どれも実 bash では失敗が job へ伝わる**（真値 GATES）ので、
# 上の 2 つの緩和・強化がここまで広がっていないことを 1 形ずつ固定する

for escape_reach_control in \
    "errexit が落ちていれば return は何もしない:set +e
          {
          return 0
          }
          bash ${SUITE_PATH}" \
    "errexit が落ちていれば最上位の return も何もしない:set +e
          return 0
          bash ${SUITE_PATH}" \
    "関数の本文の return はその関数だけを抜ける:f() {
          return 0
          }
          f
          bash ${SUITE_PATH}" \
    "閉じ括弧に付いた || true は部分シェルの return を吸う:(
          return 0
          ) || true
          bash ${SUITE_PATH}" \
    "ループを抜けた後ろは走る:{
          for i in 1; do
          break
          done
          bash ${SUITE_PATH}
          }" \
    "1 行に畳んだブレースの break:{ break; bash ${SUITE_PATH}; }" \
    "1 行に畳んだ部分シェルの break:( break
          bash ${SUITE_PATH} )" \
    "1 行に畳んだ定義の中の break はループを終わらせない:while true; do
          f() { break; }
          bash ${SUITE_PATH}
          break
          done" \
    "部分シェルを越えた 1 行の定義の中の break も同じ:while true; do
          ( f() { break; }
          bash ${SUITE_PATH}
          )
          break
          done" \
    "反転された関数外の return は何もしない:! return 0
          bash ${SUITE_PATH}" \
    "同（ブレースの中）:{
          ! return 0
          }
          bash ${SUITE_PATH}" \
    "同（必ず走る条件の中）:if true; then
          ! return 0
          fi
          bash ${SUITE_PATH}" \
    "関数の本文の反転された return は関数を抜ける:f() {
          ! return 0
          echo x
          }
          f
          bash ${SUITE_PATH}" \
    "ループの外の連鎖の break は従来どおり何もしない:( true && break
          bash ${SUITE_PATH} )" \
    "読めない左辺の連鎖の break は見送る:while true; do
          test -n \"\$SKIP\" && break
          bash ${SUITE_PATH}
          break
          done" \
    "部分シェルを越えた反転も読む（開きと同じ行）:( ! return 0
          bash ${SUITE_PATH}
          )" \
    "同（開きの次の行）:(
          ! return 0
          bash ${SUITE_PATH}
          )" \
    "条件付きの break はループの本体を殺さない:while true; do
          if [ -n \"\$SKIP\" ]; then
          break
          fi
          bash ${SUITE_PATH}
          break
          done" \
    "同（1 行の if）:while true; do
          if [ -n \"\$SKIP\" ]; then break; fi
          bash ${SUITE_PATH}
          break
          done" \
    "同（continue）:while true; do
          if [ -n \"\$SKIP\" ]; then
          continue
          fi
          bash ${SUITE_PATH}
          break
          done" \
    "同（case のアーム）:while true; do
          case \$SKIP in
          y)
          break
          ;;
          esac
          bash ${SUITE_PATH}
          break
          done" \
    "同（elif のアーム）:while true; do
          if false; then
          :
          elif [ -n \"\$SKIP\" ]; then
          break
          fi
          bash ${SUITE_PATH}
          break
          done" \
    "同じ断片で越えた部分シェルの break はループを抜けない:while true; do
          {
          ( break
          )
          }
          bash ${SUITE_PATH}
          break
          done" \
    "同（囲い無し）:while true; do
          ( break
          )
          bash ${SUITE_PATH}
          break
          done" \
    "同（continue）:while true; do
          ( continue
          )
          bash ${SUITE_PATH}
          break
          done" \
    "errexit が免除される位置の return（|| の左辺）:return 0 || true
          bash ${SUITE_PATH}" \
    "同（&& の左辺）:return 0 && true
          bash ${SUITE_PATH}" \
    "同（囲いの閉じに付いた ||）:{ return 0; } || true
          bash ${SUITE_PATH}" \
    "同（二重の囲いの閉じに付いた ||）:{
          { return 0; }
          } || true
          bash ${SUITE_PATH}" \
    "同（if の条件）:if return 0; then
          :
          fi
          bash ${SUITE_PATH}" \
    "同（while の条件）:while return 0; do
          break
          done
          bash ${SUITE_PATH}" \
    "部分シェルの return は || で吸われたら何もしない:(
          return 0
          ) || true
          bash ${SUITE_PATH}" \
    "部分シェルの exit は親を終わらせない（対照）:(
          exit 0
          )
          bash ${SUITE_PATH}" \
    "無条件に exit する関数を部分シェルで呼ぶ（対照）:f() {
          exit 0
          }
          ( f
          )
          bash ${SUITE_PATH}" \
    "1 行に畳んだ部分シェルの exit は親を終わらせない（対照）:( exit 0 )
          bash ${SUITE_PATH}" \
    "部分シェルの中の exit は手前にコマンドがあっても親を終わらせない:( echo a; exit 0 )
          bash ${SUITE_PATH}" \
    "ループの中の部分シェルの break は手前にコマンドがあってもループを抜けない:while true; do
          ( echo a; break )
          bash ${SUITE_PATH}
          break
          done" \
    "errexit が免除される位置の return（&& の左辺・右辺が偽でも）:return 0 && false
          bash ${SUITE_PATH}" \
    "部分シェルの中の return を || が吸う（1 行）:( return 0 || true )
          bash ${SUITE_PATH}" \
    "同（右辺が普通のコマンド）:( return 0 || echo z )
          bash ${SUITE_PATH}" \
    "同（右辺が部分シェルを 0 で終える exit）:( return 0 || exit 0 )
          bash ${SUITE_PATH}" \
    "閉じ括弧の後ろに付いた && は部分シェルの失敗を吸う:( return 0 ) && true
          bash ${SUITE_PATH}" \
    "同（手前にコマンドがある）:( echo a; return 0 ) && true
          bash ${SUITE_PATH}" \
    "同（右辺が偽でも並びの最後ではない）:( return 0 ) && false
          bash ${SUITE_PATH}" \
    "部分シェルの中の囲いの閉じに付いた || は吸う:( { return 0; } || true )
          bash ${SUITE_PATH}" \
    "同じ階層の 2 つの return は囲いの閉じでまとめて取り消される:{ return 0; return 0; } || true
          bash ${SUITE_PATH}" \
    "フォークした閉じの return は後ろの取り消しに寄与しない:{ return 0; } | cat
          { return 0; } || true
          bash ${SUITE_PATH}" \
    "入れ子の 2 つの印はそれぞれの階層の閉じで取り消す:{
          return 0
          { return 0; } || true
          } || true
          bash ${SUITE_PATH}" \
    "同（内側がフォークした閉じ）:{
          return 0
          { return 0; } | cat
          } || true
          bash ${SUITE_PATH}" \
    "同（内側の複合に素の exit がある）:{
          return 0
          { exit 0; } | cat
          } || true
          bash ${SUITE_PATH}" \
    "フォークした閉じは中の素の exit も取り消す:{ exit 0; } | cat
          bash ${SUITE_PATH}" \
    "同（非同期の & 側）:{ exit 0; } &
          bash ${SUITE_PATH}" \
    "同（return の印と同じ複合の中にある exit）:{
          return 0
          { exit 0; }
          } | cat
          bash ${SUITE_PATH}" \
    "同（ループ脱出と同じ複合の中にある exit）:{ break
          { exit 0; } } | cat
          bash ${SUITE_PATH}" \
    "同（ループの中）:while true; do
          { exit 0; } | cat
          bash ${SUITE_PATH}
          break
          done" \
    "同（必ず走る条件の中）:if true; then
          exit 0
          fi | cat
          bash ${SUITE_PATH}" \
    "同（部分シェルの中）:(
          { exit 0; } | cat
          )
          bash ${SUITE_PATH}" \
    "空白を挟んだ入れ子の部分シェルの exit は親を終わらせない:( ( exit 0 ) )
          bash ${SUITE_PATH}" \
    "同（ループ脱出）:while true; do
          ( ( break ) )
          bash ${SUITE_PATH}
          break
          done" \
    "閉じ括弧が 2 つ並んだ後ろの && は最上位に掛かる:( ( return 0 ) ) && true
          bash ${SUITE_PATH}" \
    "1 行に畳んだ部分シェルの break はループを抜けない（対照）:while true; do
          ( break )
          bash ${SUITE_PATH}
          break
          done" \
    "フォークした複合の中の関数外 return は親を終わらせない（パイプ）:{
          return 0
          } | cat
          bash ${SUITE_PATH}" \
    "同（バックグラウンド）:{
          return 0
          } &
          bash ${SUITE_PATH}" \
    "フォークした複合の中の break は親のループへ届かない（パイプ）:while true; do
          {
          break
          } | cat
          bash ${SUITE_PATH}
          break
          done" \
    "同（バックグラウンド）:while true; do
          {
          break
          } &
          bash ${SUITE_PATH}
          break
          done" \
    "同（必ず走る条件を閉じてパイプ）:while true; do
          if true; then
          continue
          fi | cat
          bash ${SUITE_PATH}
          break
          done" \
    "包みの中でも閉じ括弧の後ろの && は部分シェルの失敗を吸う:{
          ( return 0 ) && true
          bash ${SUITE_PATH}
          }" \
    "同（部分シェルの包み）:(
          ( return 0 ) && true
          bash ${SUITE_PATH}
          )" \
    "同（必ず走る条件の包み）:if true; then
          ( return 0 ) && true
          bash ${SUITE_PATH}
          fi" \
    "同（ループの包み）:while true; do
          ( return 0 ) && true
          bash ${SUITE_PATH}
          break
          done" \
    "同（二重の囲い）:{
          {
          ( return 0 ) && true
          bash ${SUITE_PATH}
          }
          }" \
    "包みの中の && の左辺の return は右辺が偽でも吸われる:(
          return 0 && false
          bash ${SUITE_PATH}
          )" \
    "開いたままの部分シェルでも並びの後ろにコマンドが続けば吸う:( ( return 0 ) && true; echo z )
          bash ${SUITE_PATH}" \
    "同（並びに || がある）:( ( return 0 ) && true || echo z )
          bash ${SUITE_PATH}" \
    "同（&& の左辺が素の return）:( return 0 && true; echo z )
          bash ${SUITE_PATH}"
do
    assert_wired "脱出語の射程の控え（${escape_reach_control%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${escape_reach_control#*:}"
done

# ループの中の `break` / `continue` は**従来どおり**区間を終わらせる（真値 NOGATE）。
# **`while true` もループ**で、`if true` と同じ枝で階層が開くので印の付け忘れが起きやすい
# ——付け忘れるとこの 1 形だけが wired へ倒れる（実測）

for escape_in_loop_case in \
    "while true の中の break:while true; do
          break
          bash ${SUITE_PATH}
          done" \
    "for の中の break:for i in 1; do
          break
          bash ${SUITE_PATH}
          done" \
    "ループの中の case のアームの break:for i in 1; do
          case x in
          x)
          break
          bash ${SUITE_PATH}
          ;;
          esac
          done" \
    "ループの中のブレースの break:while true; do
          {
          break
          bash ${SUITE_PATH}
          }
          break
          done" \
    "関数の本文の return の後ろ（階層だけを抜ける）:f() {
          return 0
          bash ${SUITE_PATH}
          }
          f" \
    "結論の分かる連鎖の右辺の break:while true; do
          true && break
          bash ${SUITE_PATH}
          break
          done" \
    "同（|| 側）:while true; do
          false || break
          bash ${SUITE_PATH}
          break
          done" \
    "同（continue）:while true; do
          true && continue
          bash ${SUITE_PATH}
          break
          done" \
    "ループと脱出のあいだのブレース:while true; do
          {
          break
          }
          bash ${SUITE_PATH}
          break
          done" \
    "ループと脱出のあいだの if true:while true; do
          if true; then
          break
          fi
          bash ${SUITE_PATH}
          break
          done" \
    "ループと脱出のあいだの二重のブレース:while true; do
          {
          {
          break
          }
          }
          bash ${SUITE_PATH}
          break
          done" \
    "反転された exit はシェルを終える:! exit 0
          bash ${SUITE_PATH}" \
    "反転された break もループを抜ける:while true; do
          ! break
          bash ${SUITE_PATH}
          done" \
    "取り消しは無関係な囲いの || では効かない:return 0
          { echo a; } || true
          bash ${SUITE_PATH}" \
    "exit は囲いの閉じの || では取り消されない:{ exit 0; } || true
          bash ${SUITE_PATH}" \
    "部分シェルの関数外 return は親も終わらせる:(
          return 0
          )
          bash ${SUITE_PATH}" \
    "同（ブレースの中の部分シェル）:{
          (
          return 0
          )
          }
          bash ${SUITE_PATH}" \
    "同（1 行に畳んだ部分シェル）:( return 0
          )
          bash ${SUITE_PATH}" \
    "同（ループの中の部分シェル）:while true; do
          (
          return 0
          )
          bash ${SUITE_PATH}
          break
          done" \
    "同（ループの中の 1 行の部分シェル）:while true; do
          ( return 0
          )
          bash ${SUITE_PATH}
          break
          done" \
    "取り消しは階層を閉じた断片でだけ効く（ブレース）:{
          return 0
          }
          false || echo rec
          bash ${SUITE_PATH}" \
    "同（部分シェル）:(
          return 0
          )
          false || echo rec
          bash ${SUITE_PATH}" \
    "同（必ず走る条件）:if true; then
          return 0
          fi
          false || echo rec
          bash ${SUITE_PATH}" \
    "無関係な exit が立てた印まで取り消さない:{
          return 0
          }
          exit 0
          false || echo rec
          bash ${SUITE_PATH}" \
    "兄弟の複合が同じ深さで閉じても取り消さない:{
          return 0
          }
          { :; } || true
          bash ${SUITE_PATH}" \
    "同（部分シェル）:(
          return 0
          )
          { :; } || true
          bash ${SUITE_PATH}" \
    "同（無関係な exit の印も残す）:{
          return 0
          }
          exit 0
          { :; } || true
          bash ${SUITE_PATH}" \
    "1 行に畳んだ部分シェルの関数外 return も親を終わらせる:( return 0 )
          bash ${SUITE_PATH}" \
    "同（引数なし）:( return )
          bash ${SUITE_PATH}" \
    "同（セミコロン付き）:( return 0; )
          bash ${SUITE_PATH}" \
    "同じ階層の素の exit の寄与は取り消しで消さない:{ return 0; exit 0; } || true
          bash ${SUITE_PATH}" \
    "同（並び順を入れ替えても）:{ exit 0; return 0; } || true
          bash ${SUITE_PATH}" \
    "|| の右辺が成功しえない位置の return はシェルを終わらせる:return 0 || false
          bash ${SUITE_PATH}" \
    "同（ブレースの中）:{ return 0 || false; }
          bash ${SUITE_PATH}" \
    "部分シェルの中の && の左辺の return は部分シェルごと落ちる:( return 0 && true )
          bash ${SUITE_PATH}" \
    "同（右辺が偽）:( return 0 && false )
          bash ${SUITE_PATH}" \
    "同（|| の右辺が成功しえない）:( return 0 || false )
          bash ${SUITE_PATH}" \
    "部分シェルの中で並びの最後に来る return:( true && return 0 )
          bash ${SUITE_PATH}" \
    "部分シェルの最後のコマンドが return:( echo a; return 0 )
          bash ${SUITE_PATH}" \
    "部分シェルの中の囲いの閉じに付いた && は吸わない:( { return 0; } && true )
          bash ${SUITE_PATH}" \
    "同（複数行）:(
          {
          return 0
          } && true
          )
          bash ${SUITE_PATH}" \
    "同（内側が部分シェル）:(
          (
          return 0
          ) && true
          )
          bash ${SUITE_PATH}" \
    "同（内側が必ず走る条件）:(
          if true; then
          return 0
          fi && true
          )
          bash ${SUITE_PATH}" \
    "囲いの閉じの || は右辺が成功しえないなら吸わない:{ return 0; } || false
          bash ${SUITE_PATH}" \
    "同（部分シェルの中）:( { return 0; } || false )
          bash ${SUITE_PATH}" \
    "取り消しは押し出した最上位の return の寄与まで消さない:return 0
          { return 0; } || true
          bash ${SUITE_PATH}" \
    "最上位の素の exit はフォークした閉じでも取り消せない:exit 0
          { :; } | cat
          bash ${SUITE_PATH}" \
    "フォークして閉じた複合の外にある exit は取り消さない:{
          exit 0
          }
          { :; } | cat
          bash ${SUITE_PATH}" \
    "空白を挟んだ入れ子の部分シェルの関数外 return は親も終わらせる:( ( return 0 ) )
          bash ${SUITE_PATH}" \
    "同（三重）:( ( ( return 0 ) ) )
          bash ${SUITE_PATH}" \
    "内側の部分シェルの失敗は外側の部分シェルの終了状態になる:( ( return 0 ) && true )
          bash ${SUITE_PATH}" \
    "同（右辺が偽）:( ( return 0 ) && false )
          bash ${SUITE_PATH}" \
    "同（押し出したのが別の階層の印）:{ return 0; }
          { return 0; } || true
          bash ${SUITE_PATH}" \
    "ループ脱出の区間は囲いの閉じに付いた || では取り消さない:while true; do
          {
          break
          } || true
          bash ${SUITE_PATH}
          break
          done" \
    "同（&& 側）:while true; do
          {
          break
          } && true
          bash ${SUITE_PATH}
          break
          done"
do
    assert_not_wired "ループの中の脱出語（${escape_in_loop_case%%:*}）の後ろは実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${escape_in_loop_case#*:}"
done

# **`errexit` の下では「必ず失敗するコマンド」もシェルを終わらせる**（issue #229）。
# 脱出語に固有の話ではなく、**裸の `false` 1 つで騙せる**のが根だった
# （`main` ＝ `f53e155` は `{` ＋ `false` ＋ スイート ＋ `}` を wired と答えていた）。
# 判定は既存の `chain_never_succeeds()` が唯一の源で、`false` ・ `(( 0 ))` ・
# `exit N` ・ `return N` と `!` の反転を扱う。**包みの中の綴りで固定する**
# ——レビュー 12 巡目で、最上位だけのピンでは包みが 1 枚増えた退行を見逃すと実測した

for always_failing_case in \
    "最上位の裸の false:false
          bash ${SUITE_PATH}" \
    "並びの最後が false:true && false
          bash ${SUITE_PATH}" \
    "|| の右辺も false:false || false
          bash ${SUITE_PATH}" \
    "セミコロンのあとにコマンドがある:false
          true
          bash ${SUITE_PATH}" \
    "囲いの中の false:{
          false
          bash ${SUITE_PATH}
          }" \
    "囲いを閉じたあとのスイート:{
          false
          }
          bash ${SUITE_PATH}" \
    "部分シェルの中の false:(
          false
          bash ${SUITE_PATH}
          )" \
    "必ず走る条件の中の false:if true; then
          false
          bash ${SUITE_PATH}
          fi" \
    "ループの中の false:while true; do
          false
          bash ${SUITE_PATH}
          break
          done" \
    "二重の囲いの中の false:{
          {
          false
          bash ${SUITE_PATH}
          }
          }" \
    "部分シェルを閉じたあとのスイート:( false )
          bash ${SUITE_PATH}" \
    "同（複数行）:(
          false
          )
          bash ${SUITE_PATH}" \
    "部分シェルの中の並びが最後のコマンド:( false && true )
          bash ${SUITE_PATH}" \
    "同（包みの中）:{
          ( false && true )
          }
          bash ${SUITE_PATH}" \
    "包みの閉じの || が吸う（スイートは中）:{
          false
          bash ${SUITE_PATH}
          } || true" \
    "同（部分シェル）:(
          false
          bash ${SUITE_PATH}
          ) || true" \
    "包みの後ろに行がある:{
          false
          bash ${SUITE_PATH}
          } && echo ok
          echo tail" \
    "ループの閉じに && が付く:while true; do
          false
          bash ${SUITE_PATH}
          break
          done && true"
do
    assert_not_wired "必ず失敗するコマンドの後ろは実行の証拠にしない（${always_failing_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${always_failing_case#*:}"
done

# **締めすぎない側。** `errexit` が発火しない位置の失敗と、必ず失敗するとは言えない綴りは
# 今までどおり実行の証拠にする。**AND-OR の最後の要素でなければ `errexit` は免除**され、
# `!` も免除する（状態の反転とは別の軸）。**下の控えはすべて真値 GATES**（実測。
# 件数は書かない——控えを足したときにこの数字だけが古くなる）

for always_failing_control in \
    "並びの最後ではない（&& の左辺）:false && true
          bash ${SUITE_PATH}" \
    "同（|| の左辺）:false || true
          bash ${SUITE_PATH}" \
    "errexit を切ってある:set +e
          false
          bash ${SUITE_PATH}" \
    "同（部分シェルの中で切る）:(
          set +e
          false
          bash ${SUITE_PATH}
          )" \
    "反転して必ず成功する:! false
          bash ${SUITE_PATH}" \
    "反転は errexit を免除する:! true
          bash ${SUITE_PATH}" \
    "同（反転した囲い）:! { : ; }
          bash ${SUITE_PATH}" \
    "パイプの最後ではない:false | true
          bash ${SUITE_PATH}" \
    "非同期なので状態は 0:false &
          bash ${SUITE_PATH}" \
    "条件の中なので発火しない:if false; then
          echo a
          fi
          bash ${SUITE_PATH}" \
    "囲いの閉じに付いた && が吸う:{ false; } && true
          bash ${SUITE_PATH}" \
    "同（|| 側）:{ false; } || true
          bash ${SUITE_PATH}" \
    "包みの中でも並びの最後ではない:{
          false && true
          bash ${SUITE_PATH}
          }" \
    "部分シェルの中の並びに || がある:( false || true )
          bash ${SUITE_PATH}" \
    "部分シェルの中で並びの後ろにコマンドがある:( false && true; echo z )
          bash ${SUITE_PATH}"
do
    assert_wired "必ず失敗するコマンドの控え（${always_failing_control%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${always_failing_control#*:}"
done

# **締めすぎない側＝走るかどうか分からない位置の脱出は数えない。**
# 条件次第で走らない `exit` の後ろを死に体にすると、**実際にはゲートしているスイートを
# 「未配線」と報告**する（CI では通過する早期ガードを持つワークフローが軒並み赤くなる）。
# 部分シェル・パイプ・呼ばれない関数の本文の `exit` は親を終わらせないので同じく数えない
for reachable_after_exit_case in \
    "条件が読めない if の中:if [ -n \"${DOLLAR}X\" ]; then exit 0; fi" \
    "case のアームの中:case \"${DOLLAR}M\" in
            a) exit 0 ;;
          esac" \
    "1 行に畳んだ case のアームの中:case \"${DOLLAR}M\" in a) exit 0 ;; esac" \
    "偽と分かるブロックの中:if false; then exit 1; fi" \
    "真と分かる条件の else の中:if true; then echo a; else exit 1; fi" \
    "真と分かる条件の elif の中:if true; then echo a; elif false; then exit 1; fi" \
    "コロンで真と分かる条件の else の中:if :; then echo a; else exit 1; fi" \
    "部分シェルの中:( exit 0 )" \
    "パイプの構成要素:exit 0 | cat" \
    "呼ばれない関数の本文:f() { exit 0; }" \
    "連鎖に守られた exit:[ -n \"${DOLLAR}X\" ] && exit 0" \
    "連鎖で入ったブレースの中の exit:[ \"${DOLLAR}c\" -eq 2 ] || { echo \"FAIL\"; exit 1; }" \
    "連鎖で入った部分シェルの中の exit:[ \"${DOLLAR}c\" -eq 2 ] || ( echo \"FAIL\"; exit 1 )" \
    "ループを抜けた後ろ:while true; do break; done" \
    "break の後ろ:while true; do break; exit 1; done" \
    "continue したループの後ろ:for i in 1; do continue; done"
do
    assert_wired "脱出を数えない位置（${reachable_after_exit_case%%:*}）の後ろは配線のまま" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${reachable_after_exit_case#*:}
          bash ${SUITE_PATH}"
done

# **向きの対**: 真と分かる条件の **then** 側は必ず走るので、そこの `exit` は数える
# （実 `bash -e` で NOGATE＝スイートは 1 件も走らない）。
# **この対が何を捕まえるかは実測で決めた。** 当初ここには「issue #181 の手当てを
# 『`dead_depth` が付いていれば一律で数えない』へ広げすぎると、この形まで配線扱いになる」と
# 書いていたが**事実と違った**——その変異（門番を `dead_depth < 0` だけにする）では
# この断片の時点で `dead_depth` が -1 なので**この対は緑のまま**通り、落ちるのは
# 既存の 4 形（条件が読めない `if` / `case` のアーム / 呼ばれない関数の本文 /
# 連鎖で入ったブレース）だった。この対が**単独で**捕まえるのは
# 「階層が閉じたときに `exit_seen` を戻す」変異（`true_at[depth] = 0` の隣へ
# `exit_seen = 0` を足す形）で、実測でこの 1 件だけが落ちる。
# **理由を書くときは、その変異を実際に当てて確かめること**（issue #181 はまさに
# 「実測が不完全なまま書かれたコメント」を直す差分だった）
assert_not_wired "真と分かる条件の then の中の exit は後ろを死に体にする" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then exit 1; fi
          bash ${SUITE_PATH}"

# **部分シェルの中・呼ばれた関数の中の無条件の `exit` も後ろを死に体にする**
# （issue #189。`main` 既存の fail-open）。`exit_seen` の門番にあった `subshell == 0` は
# 「ステップ全体を死に体にしない」ことだけを守っていて**その部分シェルの残りを死に体に
# する手当てが無く**、`!in_fndef_here` は「定義しただけ」を正しく無視する一方
# **呼ばれた時点では何も効かなかった**——どちらも実 `bash -e` でスイートが 1 行も
# 走らないのに `wired`。**3 トークンで必須スイートを静かに外せた**
for exit_inside_case in \
    "1 行の部分シェル:( exit 0; bash ${SUITE_PATH} )" \
    "複数行の部分シェル:( exit 0
          bash ${SUITE_PATH} )" \
    "部分シェルの後ろに別のコマンド:( exit 0; bash ${SUITE_PATH} )
          echo done" \
    "飾りを前置きした部分シェル:time ( exit 0; bash ${SUITE_PATH} )" \
    "死に体の区間が終わる断片の呼び出し:f() { exit 0; }
          ( exit 0
          echo a )
          f
          bash ${SUITE_PATH}" \
    "ブレースだけで越えた定義の呼び出し:{ f() { exit 0; }
          f
          }
          bash ${SUITE_PATH}" \
    "部分シェルの中の再定義は親の関数を置き換えない:f() { exit 0; }
          ( f() { :; }
          )
          f
          bash ${SUITE_PATH}" \
    "部分シェルの中の再定義（1 断片）:f() { exit 0; }
          ( f() { :; } )
          f
          bash ${SUITE_PATH}" \
    "ブレースの中の部分シェル:{ ( exit 0; bash ${SUITE_PATH} ); }" \
    "無条件に exit する関数の呼び出し:f() { exit 0; }
          f
          bash ${SUITE_PATH}" \
    "複数行で書いた本文:f() {
            exit 0
          }
          f
          bash ${SUITE_PATH}" \
    "見出しが別行の本文:f()
          {
            exit 0
          }
          f
          bash ${SUITE_PATH}" \
    "function 見出しの本文:function f {
            exit 0
          }
          f
          bash ${SUITE_PATH}" \
    "本文の真と分かる条件の中:f() { if true; then exit 0; fi; }
          f
          bash ${SUITE_PATH}" \
    "連鎖の左辺の呼び出し:f() { exit 0; }
          f || true
          bash ${SUITE_PATH}" \
    "部分シェルの中の呼び出し:f() { exit 0; }
          ( f; bash ${SUITE_PATH} )" \
    "真と分かる条件の中の呼び出し:f() { exit 0; }
          if true; then f; fi
          bash ${SUITE_PATH}" \
    "ブレースの中の呼び出し:f() { exit 0; }
          { f; }
          bash ${SUITE_PATH}" \
    "部分シェルの中で定義して呼ぶ:( f() { exit 0; }
          f
          bash ${SUITE_PATH} )"
do
    assert_not_wired "無条件の脱出（${exit_inside_case%%:*}）の後ろは実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${exit_inside_case#*:}"
done

# **連鎖の右辺の `exit` も、左辺の真偽が綴りから分かるなら後ろを死に体にする**
# （issue #202。`main` 既存の fail-open）。脱出の門番は `prev_op` が `&&` / `||` なら
# 一律に見送っていたため、**`true &&` の 2 トークンを足すだけで必須スイートを
# ゲートから外せた**（実 `bash -e` ではスイートが 1 行も走らないのに `wired`）。
# 判定は既にある `chain_in`（「走ると証明できない連鎖の中か」）を読むので、
# 短絡で向きが決まる形（`false && echo mid || exit 0` の `||` の右・
# `true || echo mid && exit 0` の `&&` の右）も同じ経路で閉じる
for chain_exit_case in \
    "true の右辺:true && exit 0
          bash ${SUITE_PATH}" \
    "コロンの右辺:: && exit 0
          bash ${SUITE_PATH}" \
    "false の || の右辺:false || exit 0
          bash ${SUITE_PATH}" \
    "true を 2 つ重ねた連鎖:true && true && exit 0
          bash ${SUITE_PATH}" \
    "短絡で || へ渡る形:false && echo mid || exit 0
          bash ${SUITE_PATH}" \
    "短絡で && へ渡る形:true || echo mid && exit 0
          bash ${SUITE_PATH}" \
    "1 行に畳んだ形:true && exit 0; bash ${SUITE_PATH}" \
    "部分シェルの中の連鎖:( true && exit 0
          bash ${SUITE_PATH} )" \
    "ブレースの中の連鎖:{ true && exit 0
          bash ${SUITE_PATH}; }" \
    "真と分かる条件の中の連鎖:if true; then
            true && exit 0
            bash ${SUITE_PATH}
          fi" \
    "連鎖の右辺の呼び出し:f() { exit 0; }
          true && f
          bash ${SUITE_PATH}" \
    "連鎖の右辺の呼び出し（|| 側）:f() { exit 0; }
          false || f
          bash ${SUITE_PATH}"
do
    assert_not_wired "結論の分かる連鎖の右辺の脱出（${chain_exit_case%%:*}）の後ろは実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${chain_exit_case#*:}"
done

# 締めすぎない側。**走らないと分かる右辺・読めない左辺・`break` / `continue` は数えない。**
# - 走らないと分かる右辺（`false && exit 0` / `true || exit 0`）は脱出そのものが走らないので
#   後ろのスイートは実行される（数えると、正しくゲートしているワークフローを赤くする）。
# - 読めない左辺（`test -n "$X" && exit 0`）は条件次第。**環境を決めれば真値は決まるが
#   綴りからは決まらない**ので、「走ると証明できない」側＝見送る（issue #189 で何度も踏んだ向き）。
#   **実測の境界は極性で分かれる**（レビューで訂正）: `X` が空なら `test -n` は偽なので脱出は
#   走らず、真値は **GATES**＝`wired` は正しい答え（ここは fail-open ではない）。
#   残っている fail-open は**逆の極性**（`test -z "$X" && exit 0` ・ `test -n "$X" || exit 0`）で、
#   `X` が空のとき脱出が走って真値 NOGATE なのに `wired` と答える。綴りから閉じる方法が
#   無いので、その 2 形も**境界の記録として**この一覧へ置く（答えが変わったら気付けるように）。
# - `break` / `continue` には広げない。実測で、ループの外の `break` を連鎖の右辺で数えると
#   `( true && break` 改行 スイート `)` ほか**真値 GATES の 36 形が未配線へ倒れた**
#   （ループの中かどうかを見ていないのが根＝issue #204）
for chain_exit_control_case in \
    "false の && の右辺:false && exit 0
          bash ${SUITE_PATH}" \
    "true の || の右辺:true || exit 0
          bash ${SUITE_PATH}" \
    "読めない左辺の && の右辺:test -n \"\$X\" && exit 0
          bash ${SUITE_PATH}" \
    "読めない左辺の || の右辺:test -z \"\$X\" || exit 0
          bash ${SUITE_PATH}" \
    "部分シェルの中の連鎖の break:( true && break
          bash ${SUITE_PATH} )" \
    "ブレースの中の連鎖の continue:{ true && continue
          bash ${SUITE_PATH}; }" \
    "部分シェルを閉じた後ろのスイート:( true && exit 0 )
          bash ${SUITE_PATH}" \
    "連鎖の右辺が脱出でない形:true && true
          bash ${SUITE_PATH}" \
    "読めない左辺の呼び出し:f() { exit 0; }
          test -n \"\$X\" && f
          bash ${SUITE_PATH}" \
    "読めない左辺の呼び出し（|| 側）:f() { exit 0; }
          test -z \"\$X\" || f
          bash ${SUITE_PATH}" \
    "複数行の部分シェルの連鎖:( true && exit 0
          echo x )
          bash ${SUITE_PATH}" \
    "連鎖の右辺で定義を開く断片の呼び出し:f() { exit 0; }
          true && ( h() { f ; }
          bash ${SUITE_PATH}
          )" \
    "連鎖の右辺でブレースの定義を開く断片の呼び出し:f() { exit 0; }
          true && { h() { f ; }
          bash ${SUITE_PATH}
          }" \
    "残っている fail-open の境界（&& 側）:test -z \"\$X\" && exit 0
          bash ${SUITE_PATH}" \
    "残っている fail-open の境界（|| 側）:test -n \"\$X\" || exit 0
          bash ${SUITE_PATH}"
do
    assert_wired "結論の分かる連鎖の右辺でも数えない形（${chain_exit_control_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${chain_exit_control_case#*:}"
done

# **締めすぎない側。** 部分シェルの外・呼ばれない関数・条件付きの脱出・本文の部分シェルの中は
# どれも後ろが走るので、死に体にすると**正しくゲートしているスイートを「未配線」と報告**する。
# **素の `( exit 0 )` と `f() { exit 0; }`（呼ばない）はここに置かない**——上の
# `reachable_after_exit_case`（issue #151 の「脱出を数えない位置」）が同じ YAML を持っており、
# 同じ綴りを 2 度ピンすると、片方を直したときにもう片方が残って齟齬の出どころになる
for exit_scoped_case in \
    "本文の部分シェルの中で脱出する関数の呼び出し:f() { ( exit 0 ); }
          f" \
    "本文の部分シェルを複数行で書いた関数の呼び出し:f() {
            ( exit 0 )
          }
          f" \
    "同じ名前で定義し直した関数の呼び出し:f() { exit 0; }
          f() { :; }
          f" \
    "本文の条件付きの脱出:f() { if [ -n \"${DOLLAR}X\" ]; then exit 0; fi; }
          f" \
    "部分シェルの中の条件付きの脱出:( if [ -n \"${DOLLAR}X\" ]; then exit 0; fi )" \
    "部分シェルの中の届かない脱出:( true || exit 0 )" \
    "呼ばれた関数が部分シェルの中だけを終わらせる:f() { exit 0; }
          ( f )" \
    "呼び出しと閉じ括弧を同じ断片に置く:f() { exit 0; }
          (
          f )" \
    "部分シェルの中で定義して同じ断片で閉じる:( f() { exit 0; }
          f )" \
    "本文の部分シェルを 3 行で書いた関数の呼び出し:f() {
            (
            exit 0
            )
          }
          f" \
    "本文の部分シェルを開いたまま改行した関数の呼び出し:f() {
            ( exit 0
            )
          }
          f" \
    "部分シェルの中の脱出の後ろ（最上位へ戻る）:( exit 0
          echo inner )" \
    "1 行に畳んだ case のアームの中の呼び出し:f() { exit 0; }
          case \"${DOLLAR}M\" in a) f ;; esac" \
    "本文の 1 行 case のアームの中の脱出:f() { case \"${DOLLAR}M\" in a) exit 0 ;; esac; }
          f" \
    "本文の複数行 case のアームの中の脱出:f() {
            case \"${DOLLAR}M\" in
              a) exit 0 ;;
            esac
          }
          f"
do
    assert_wired "脱出の及ばない位置（${exit_scoped_case%%:*}）の後ろは配線のまま" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${exit_scoped_case#*:}
          bash ${SUITE_PATH}"
done

# **「定義しただけ」「無条件ではない」脱出は台帳へ入れない**（issue #189 のレビューで見つけた
# 4 形。どれもこの差分が一度入れた fail-closed で、`main` は正しく wired と答えていた）。
# 本文は全文を与える（スイートが部分シェルの中にある形があるため、上の 2 ループのように
# 末尾へ足す形にできない）
for exit_not_unconditional_case in \
    "部分シェルの後ろで定義だけして呼ばない:( f() { exit 0; }
          bash ${SUITE_PATH} )" \
    "部分シェルの後ろの function 見出しで定義だけする:( function f { exit 0; }
          bash ${SUITE_PATH} )" \
    "本文の手前に条件付きの return:f() { [ -z \"${DOLLAR}X\" ] && return 0
            exit 1
          }
          f
          bash ${SUITE_PATH}" \
    "本文の手前に if の return:f() { if [ -z \"${DOLLAR}X\" ]; then return 0; fi
            exit 1
          }
          f
          bash ${SUITE_PATH}" \
    "1 行で return のあとに exit:f() { return 0; exit 1; }
          f
          bash ${SUITE_PATH}" \
    "1 行に畳んだ入れ子の定義:outer() { inner() { exit 0; }; }
          outer
          bash ${SUITE_PATH}" \
    "部分シェルで越えた定義の手前の return:( f() { return 0; exit 1; }
          f )
          bash ${SUITE_PATH}" \
    "ブレースで越えた定義の手前の return:{ f() { return 0; exit 1; }
          f
          }
          bash ${SUITE_PATH}" \
    "ブレースで越えた定義による再定義:f() { exit 0; }
          { f() { :; }
          f
          }
          bash ${SUITE_PATH}" \
    "部分シェルで越えた定義による再定義:f() { exit 0; }
          ( f() { return 0; }
          f )
          bash ${SUITE_PATH}"
do
    assert_wired "無条件でない脱出（${exit_not_unconditional_case%%:*}）は台帳へ入れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${exit_not_unconditional_case#*:}"
done

# **弱める関数の反映は、呼んだ階層へ帰属させる**（issue #189 の配線 ＋ issue #200）。
# 呼び出しの名前を取り出す門番から `subshell == 0` を外した（無条件に `exit` する関数は
# その部分シェルを終わらせるので、部分シェルの中でも名前を引く必要がある）ぶん、
# **弱めを反映する側では階層を取り違えない**ことが要る。取り違えると 2 つの向きに壊れる:
# 部分シェルの中の弱めを**外**の階層で記録すると内側の `set -e` が打ち消せず、
# 部分シェルの終了状態として伝わる失敗を「握り潰された」と読む（fail-closed）。
# 逆に反映を**見送る**と、握り潰されているのに wired と答える（fail-open）。
# 下のループはその fail-closed 側（弱めが外へ漏れない＝中の失敗は伝わる）を押さえ、
# すぐ下の `fncall_weaken_scope_case` が fail-open 側（issue #200 で閉じた形）を押さえる
for subshell_weaken_case in \
    "部分シェルの中で呼ぶ:( quiet; bash ${SUITE_PATH} )" \
    "部分シェルの中で呼び、後ろに別のコマンド:( quiet; bash ${SUITE_PATH} )
          echo done" \
    "部分シェルの中で呼び、スイートは外:( quiet )
          bash ${SUITE_PATH}" \
    "部分シェルを開いたまま改行して呼び、スイートは外:( quiet
          )
          bash ${SUITE_PATH}" \
    "部分シェルの中で弱めてから同じ階層で戻す:( quiet
          set -e
          bash ${SUITE_PATH}
          echo x )"
do
    assert_wired "弱める関数を部分シェルの中で呼んでも中の失敗は伝わる（${subshell_weaken_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          quiet() { set +e; }
          ${subshell_weaken_case#*:}"
done

# **部分シェルの中で弱めてからスイートを呼び、後ろに別のコマンドを置く綴りは握り潰し**
# （issue #200）。部分シェルの最後に走るのが `echo x` なので、実 `bash -e` ではスイートの
# 失敗は外へ出ない。`main` は**全件 wired** と答えていた＝3 行でスイートを静かに外せる
# fail-open（実測）。直し方は `set` 側と同じ「先に番号を振って呼んだ階層へ帰属させる」で、
# **門番を単に外すのは誤り**（内側の `set -e` が打ち消せなくなり、上のループが落ちる）。
# **呼び出しが `(` と同じ断片にある形と、`(` の次の行にある形は別の経路**
# （前者は「この断片で越えた」側、後者は「もう部分シェルの中にいる」側）なので両方置く。
# 混在（`{ ( quiet` / `( { quiet`）も、深さの数え方を取り違えると帰属がずれるので置く
for fncall_weaken_scope_case in \
    "開きと同じ断片・閉じは末尾行:( quiet
          bash ${SUITE_PATH}
          echo x )" \
    "開きと同じ断片・閉じは独立行:( quiet
          bash ${SUITE_PATH}
          echo x
          )" \
    "1 行に畳む:( quiet; bash ${SUITE_PATH}; echo x )" \
    "呼び出しは開きの次の行:(
          quiet
          bash ${SUITE_PATH}
          echo x
          )" \
    "閉じにリダイレクト:(
          quiet
          bash ${SUITE_PATH}
          echo x
          ) >/dev/null" \
    "ブレースの中の部分シェル:{ ( quiet
          bash ${SUITE_PATH}
          echo x ) }" \
    "部分シェルの中のブレース:( { quiet; bash ${SUITE_PATH}; echo x; } )"
do
    assert_not_wired "部分シェルの中で弱めると後ろにコマンドがある限り失敗は外へ出ない（${fncall_weaken_scope_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          quiet() { set +e; }
          ${fncall_weaken_scope_case#*:}"
done

# **帰属の対照**: 入れ子の部分シェルの中で呼び、**同じ階層**で `set -e` に戻す綴りは
# 打ち消しが成立するので、スイートの失敗はその部分シェルを落として外へ伝わる（真値 GATES）。
# 上のループと同じ「呼び出しが開きの次の行」経路で、**帰属先を間違えるとここが赤くなる**
# （弱めを部分シェルの外の階層で記録すると、内側の `set -e` が打ち消せない）
assert_wired "入れ子の部分シェルの中で弱めてから同じ階層で戻すと失敗は伝わる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          quiet() { set +e; }
          (
          (
          quiet
          set -e
          bash ${SUITE_PATH}
          echo x
          )
          )"

# **pipefail の弱めは部分シェルの中では据え置く**（`main` と同じ門番＝この差分で挙動を動かさない）。
# `set_flag()` は階層を持たないので、部分シェルの中で反映すると内側の `set -o pipefail` で
# 打ち消せず、**正しくゲートする綴りを赤くする**。errexit 側（`apply_errexit()`）が階層を持つのとの
# 非対称で、階層を持たせるのは issue #203 の仕事。**このピンは errexit 側の門番を外すときに
# pipefail 側まで一緒に緩める退行を捕まえる**——実測で、門番を `call_sub == 0` だけに緩めると
# （呼び出しが開き括弧の次の行にあると `call_sub` は 0 なので反映されてしまい）この形が
# wired → not-wired へ倒れた。`main` では wired＝退行の検出であって性質の固定ではない
assert_wired "部分シェルの中で pipefail を弱めても同じ階層で戻せばパイプの失敗は伝わる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          pq() { set +o pipefail; }
          set -o pipefail
          (
          pq
          set -o pipefail
          bash ${SUITE_PATH} | cat )"

# **語リストが空の `for` / `select` は本体が 1 度も走らない**（issue #200 のレビュー指摘）。
# `for v in ; do set +e; done` の `set +e` は実行されないので errexit は生きたままで、
# スイートの失敗はそのまま伝わる（真値 GATES）。`main` は未配線と答えていた＝**fail-closed**
# （兄弟の `if false` / `while false` / `until true` は以前から正しく扱えており、
#  空の語リストだけが漏れていた）。**この差分がこの根を踏んだ**——弱めを部分シェルの中へ
# 反映するようにした結果、`( for v in ; do quiet; done` が `main` では wired だったのに
# 未配線へ倒れた。根を直したので両方の綴り（素の `set` と関数の呼び出し）が真値どおりになる
for empty_list_case in \
    "素の set +e・最上位:for v in ; do set +e; done
          bash ${SUITE_PATH}
          echo x" \
    "素の set +e・部分シェルの中:( for v in ; do set +e; done
          bash ${SUITE_PATH}
          echo x )" \
    "弱める関数・部分シェルの中:quiet() { set +e; }
          ( for v in ; do quiet; done
          bash ${SUITE_PATH}
          echo x )" \
    "select も同じ:quiet() { set +e; }
          ( select v in ; do quiet; done
          bash ${SUITE_PATH}
          echo x )" \
    "in の後ろで改行する綴り:quiet() { set +e; }
          ( for v in
          do
          quiet
          done
          bash ${SUITE_PATH}
          echo x )"
do
    assert_wired "語リストが空のループの中の弱めは反映しない（${empty_list_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${empty_list_case#*:}"
done

# **空と決め打つのは「`in` の後ろに 1 語も無い」ときだけ。** `for v in "" ;` は空文字 1 語なので
# 本体が 1 度走り、弱めは反映される（真値 NOGATE）。`main` は wired＝fail-open だった
assert_not_wired "空文字 1 語のリストは走るので弱めが反映される" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          quiet() { set +e; }
          ( for v in \"\" ; do quiet; done
          bash ${SUITE_PATH}
          echo x )"

# **中身が読めないリスト（`for v in $L`）は空と決め打たない。** 回数が分からないので真値は
# 変数の中身で変わる（空なら GATES・非空なら NOGATE）。ライブラリは**素の `set +e` と同じ側**
# ——「弱めは反映する」＝未配線——へそろえる。**そろえること自体が issue #200 の目的**で、
# 以前は同じ意味の 2 つの綴りで答えが割れていた（素の `set` は未配線・呼び出しは wired）。
# 向きは反 fail-open（リストが非空のときに正しく、空のときは `main` の素の `set` と同じ
# fail-closed）。**片方だけを動かすとこのピンが落ちる**
assert_not_wired "読めないリストの中の弱めは素の set と同じく反映する" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          quiet() { set +e; }
          ( for v in \$L; do quiet; done
          bash ${SUITE_PATH}
          echo x )"

# --- 先頭の飾り（同じシェルのまま `set` を呼ぶ書き方）------------------------------
#
# 落としてよいのはブレースグループ / 変数代入 / `builtin` / `command` / `eval` だけ。
# アームの中でも同じ判定を通すので、1 トークン足しただけで穴が開かない

assert_swallowed "case アームの中の command set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case a in a) command set +e ;; esac
          bash ${SUITE_PATH}"

assert_swallowed "case アームの中のブレースグループの set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case a in a) { set +e; } ;; esac
          bash ${SUITE_PATH}"

assert_swallowed "ブレースグループの中の eval \"set +e\"" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { eval \"set +e\"; }
          bash ${SUITE_PATH}"

assert_swallowed "変数代入を前置きした set +e" "name: ci
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

assert_swallowed "エイリアスを止める \\set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          \\set +e
          bash ${SUITE_PATH}"

assert_swallowed "終了状態を反転する ! set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ! set +e
          bash ${SUITE_PATH}"

assert_swallowed "time set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          time set +e
          bash ${SUITE_PATH}"

assert_swallowed "先頭に置いたリダイレクト付きの set +e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          >/dev/null set +e
          bash ${SUITE_PATH}"

# **リダイレクトの綴りは 1 文字では足りない**（issue #177。実測）——`[<>]` 1 文字で書くと
# `>>` の 2 文字目が転送先として読まれ、前置きとして落とせない。**転送先の前に空白を置く**
# のが要点で、`>>/dev/null` と詰めて書くと 1 文字の綴りでも転送先が `>/dev/null` として
# まとめて飲まれ、たまたま正しく落ちる（実測で、詰めた綴りのピンは古い綴りでも緑だった）。落とせないと
# `>> log set +e` の `set` が見つからず握り潰しを読み落とすので、**握り潰された実行が
# 「ゲートしている」と報告される**（`main` から fail-open。`>/dev/null set +e` は
# 正しく読めていたので、追記の綴りだけが素通りする非対称だった）
for redirect_prefix_case in \
    "追記リダイレクト:>> /dev/null set +e" \
    "番号付き追記リダイレクト:2>> /dev/null set +e" \
    "まとめリダイレクト:&> /dev/null set +e" \
    "ここ文字列:<<< x set +e"
do
    assert_swallowed "先頭に置いたリダイレクト付きの set +e（${redirect_prefix_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${redirect_prefix_case#*:}
          bash ${SUITE_PATH}"
done

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

assert_swallowed "丸括弧付きの別アームの set -e は打ち消さない" "name: ci
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
assert_swallowed "case アームの中の部分シェルを閉じた後の set +e" "name: ci
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

assert_swallowed "if false || <条件> の本体の set +e は効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if false || true; then set +e; fi
          bash ${SUITE_PATH}"

assert_swallowed "until true && <条件> の本体の set +e も効く" "name: ci
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

assert_swallowed "走らないループの中の 1 行 case も外側を巻き戻さない" "name: ci
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
assert_swallowed "丸括弧付きの選択肢アームの set +e は数える" "name: ci
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

# **必ず走るグループの開きは、何個重なっても命令の位置を変えない**（レビューで実測）。
# `(` を 1 つしか許していなかった頃は、実際には走ってゲートしている綴りを
# 「実行されていない」と**事実と逆の診断**で落としていた（fail-closed）。
# 対になる控えは下の 2 件（関数定義・偽と分かる条件）で、こちらが「何でも通す」形へ
# 緩んでいないことを押さえる
for group_open_case in \
    "ブレースグループ:{ bash ${SUITE_PATH}; }" \
    "ブレースの中の部分シェル:{ ( bash ${SUITE_PATH} ) }" \
    "二重の部分シェル:( ( bash ${SUITE_PATH} ) )" \
    "部分シェルの中のブレース:( { bash ${SUITE_PATH}; } )"
do
    assert_wired "${group_open_case%%:*}の先頭に置いた呼び出し" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${group_open_case#*:}"
done

# **`time` も前置き**（`strip_command_prefixes()` が既にそう扱っているのと揃える）。
# `time bash x` はスクリプトを実行し、失敗もそのまま伝わる（`set -e` の下で `time false` は
# exit 1）のに、前置きの一覧に無いせいで「実行されていない」と読まれていた（fail-closed）
assert_wired "time 経由の呼び出し" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: time bash ${SUITE_PATH}"

assert_wired "time -p 経由の呼び出し" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: time -p bash ${SUITE_PATH}"

# 締めすぎない側: **`!` は終了状態を反転する**ので前置きに入れない（本当にゲートしない）
assert_not_wired "! 経由の呼び出し（終了状態が反転するのでゲートしない）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: ! bash ${SUITE_PATH}"

# 締めすぎない側: `-p` は `time` にだけ続く形（素の `-p` を前置きとして認めない）
assert_not_wired "素の -p は前置きではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: -p bash ${SUITE_PATH}"

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
assert_swallowed "|| で閉じたブレースグループの set +e は親へ漏れる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { set +e; } || true
          bash ${SUITE_PATH}"

assert_swallowed "; で閉じたブレースグループの set +e は親へ漏れる" "name: ci
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

# (3) 1 行に畳んだ**必ず走る**ブロックの本体は実行の証拠にする（issue #123 (3)）。
# **以前はここを意図的に落としていた**が、その理由（開き側が読めない語で始まる断片では
# `uncertain` も `dead_depth` も立たないので、継続語を命令の位置として許すと走らない本体が
# 最上位の実行に化ける）は **issue #142 (3) で消えている**——`( if false` も `time if …` も
# `! if …` も開き側が分類できるようになったため。下の 4 形がその控えで、いまは
# **深さの勘定だけ**で止まっている。
# **止めているのは錨ではなく `top` の絞り込み**（`uncertain == 0` だけを通す）。
# `for … do` / `until true` / 条件が読めない `if` はいずれも `uncertain` を立てるので、
# 錨が継続語を許しても渡ってこない（**手前の `&&` / `||` に守られた `if true` も同じく
# 渡ってこない**。`true_at` が直後の区切りしか見ていなかった分はレビューで直した）。
# だから `ci_workflow_runs_script` は
# `CI_WORKFLOW_BLOCK_BODY_START` を使ってよい——**`shellcheck` の網とは事情が違う**
# （あちらは `top` を渡さないので錨が唯一の歯止め。なお `bash -n` の網も `top` を
# 渡さないが広い錨を使う＝「`top` を渡さない照会はすべて狭い錨」ではない。
# 選び分けの正本は `test/ci_coverage_test.sh` の「錨は網ごとに選び分ける」）。
# 実 `bash -e`（末尾に成功する番兵を足して「失敗が中断させるか」を測る）を真値とした
# 30 形の差分照合で、**7 形が改善し、新しい誤りは 0 形**だった。
# **その 30 形は「飾り」の軸を 1 つも含んでいない**ので、「新しい誤りは 0」を広い集合の
# 結論として読まないこと——狙って当てた 15 形では `!` で反転された開き（下で閉じた）と
# 複合コマンドを閉じた `fi` に付いた `&&`（issue #149 で追う）の 2 系統が出た
for folded_certain_case in \
    "if true:if true; then bash ${SUITE_PATH}; fi" \
    "if コロン:if :; then bash ${SUITE_PATH}; fi" \
    "while true:while true; do bash ${SUITE_PATH}; break; done" \
    "if true と部分シェル:if true; then ( bash ${SUITE_PATH} ); fi" \
    "if true とブレース:if true; then { bash ${SUITE_PATH}; }; fi" \
    "入れ子の if true:if true; then if true; then bash ${SUITE_PATH}; fi; fi"
do
    assert_wired "1 行の${folded_certain_case%%:*}の本体は実行の証拠になる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${folded_certain_case#*:}"
done

# **手前の連鎖に守られた `if true` / `while true` は「必ず走る」ではない**（レビューで実測）。
# `true_at` の印は**直後**の区切りしか見ていなかったので、`&&` / `||` で**入ってきた**断片の
# `if true` が「必ず走る」と記録されていた。錨が継続語を許すようになった時点で、その本体が
# 実行の証拠に化ける——実 `bash -e` では左辺が偽なら 1 度も走らないのに `wired` になる
# （`&&` / `||` の並びは `set -e` を発動させない）。入ってきた区切りは `pipe_in` の隣で
# 控える（`prev_op` は断片の処理中に自分の区切りへ更新されるので開き側まで持たない）
for chain_guarded_case in \
    "&& の後ろの if true:test -n \"${DOLLAR}RUN\" && if true; then bash ${SUITE_PATH}; fi" \
    "偽と分かる && の後ろ:false && if true; then bash ${SUITE_PATH}; fi" \
    "真と分かる || の後ろ:true || if true; then bash ${SUITE_PATH}; fi" \
    "&& の後ろの while true:test -n \"${DOLLAR}RUN\" && while true; do bash ${SUITE_PATH}; break; done"
do
    assert_not_wired "${chain_guarded_case%%:*}の本体は実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${chain_guarded_case#*:}"
done

# **連鎖に守られているのは `if true` の本体だけではない**（issue #150。`main` 既存の fail-open）。
# `test -n "${DOLLAR}RUN" && bash <スイート>` は `$RUN` が空なら 1 度も走らないのに「最上位で
# 確実に走る」と記録されていた——**2 トークンで必須スイートを無効化できる**形で、素の呼び出し・
# ブレースグループ・部分シェル・`||` の右辺・2 段の連鎖のどれでも同じだった
# （`if true` を挟んだ形だけが PR #148 で閉じていた）。記録の 5 列目（走ると証明できない
# 理由の数）に連鎖の分を足して、実行の照会から外す
for chain_call_case in \
    "素の呼び出し:test -n \"${DOLLAR}RUN\" && bash ${SUITE_PATH}" \
    "ブレースグループ:test -n \"${DOLLAR}RUN\" && { bash ${SUITE_PATH}; }" \
    "部分シェル:test -n \"${DOLLAR}RUN\" && ( bash ${SUITE_PATH} )" \
    "|| の右辺:test -z \"${DOLLAR}RUN\" || bash ${SUITE_PATH}" \
    "2 段の連鎖:test -n \"${DOLLAR}RUN\" && test -n \"${DOLLAR}ALSO\" && bash ${SUITE_PATH}" \
    "反転された真:! true && bash ${SUITE_PATH}"
do
    assert_not_wired "連鎖の右辺（${chain_call_case%%:*}）は実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${chain_call_case#*:}
          echo done"
done

# **算術コマンド（`(( … ))`）の真偽は読まない**（issue #150 のレビューで実測）。
# 丸括弧を 2 つ落とすと中身が「コマンドとしての `true`」に見えるが、算術の真偽は
# **変数の値**で決まる——`(( true ))` は未設定の変数 `true` を 0 と読むので終了状態は 1（偽）。
# 読むと向きが逆になり、`&&` の右辺の呼び出しを「必ず走る」と記録する（`bash -n` も通る綴り）
for arith_chain_case in \
    "空白あり:(( true ))" \
    "空白なし:((true))" \
    "コロン:(( : ))" \
    "部分シェルで包む:( (( true )) )" \
    "time 付き:time (( true ))"
do
    assert_not_wired "算術コマンドの連鎖（${arith_chain_case%%:*}）は実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${arith_chain_case#*:} && bash ${SUITE_PATH}
          echo end"
done

# **算術コマンドの中身は「走るコマンド」ではない**（issue #206）。実 bash は `(( … ))` の
# 中を算術式として読むのでコマンドは 1 つも走らない。伏せないと中のスイート名が照合に
# 当たって「配線されている」と答え、`ci_coverage_test.sh` が**必ず赤くなるワークフロー**に
# ついて誤った答えを返す。**下の 5 形はすべて真値 NOGATE**（番兵なしの実 `bash -e` で実測）。
# **`||` を含む 2 形が要点**で、算術の中の `||` は演算子なので並びの区切りとして切らない
# ——切ると断片が `(( bash <スイート>` に割れ、`))` を持たないので伏せ字に当たらない
for arith_body_case in \
    "算術の中のスイート:(( bash ${SUITE_PATH} ))" \
    "手前にコマンドがある:echo a
          (( bash ${SUITE_PATH} ))" \
    "算術の中の || と exit:(( bash ${SUITE_PATH} || exit 1 ))" \
    "算術の中の || と false:(( bash ${SUITE_PATH} || false ))" \
    "後ろに && が付く:(( bash ${SUITE_PATH} )) && echo ok" \
    "入れ子の括弧がある:(( (1+2) * bash ${SUITE_PATH} ))" \
    "閉じない算術:(( bash ${SUITE_PATH}"
do
    assert_not_wired "算術コマンドの中身は実行の証拠にしない（${arith_body_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${arith_body_case#*:}"
done

# **締めすぎない側。** 算術**展開**（`$(( … ))`）はコマンドの引数・代入の値として普通に現れ、
# その行のコマンドは走る。**下の 4 形はすべて真値 GATES**（実測）
for arith_expansion_case in \
    "スイートの引数:bash ${SUITE_PATH} \$(( 1 + 2 ))" \
    "手前の行の展開:echo \$(( 1 ))
          bash ${SUITE_PATH}" \
    "代入の値:X=\$(( 2 * 3 ))
          bash ${SUITE_PATH}" \
    "後ろの行の展開:bash ${SUITE_PATH} && echo \$(( 1 ))" \
    "展開の中のパイプ記号:bash ${SUITE_PATH} \$(( (1<<2)|3 ))" \
    "展開の中の論理積:bash ${SUITE_PATH} --n=\$(( (1|2) ))" \
    "置換の隣の入れ子の展開:X=\$(bash ${SUITE_PATH})\$(( (1+2) ))"
do
    assert_wired "算術展開は後続の実行を消さない（${arith_expansion_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${arith_expansion_case#*:}"
done

# **算術展開を伏せてはいけない**（issue #206 のレビューが実測した 2 つ目の向き）。
# 展開はコマンドの**一部**なので、照合へ出す本文から消すと**別のコマンドに化ける**。
# 下は真値 NOGATE——実 bash は `test/subject_test.sh1` というファイルを探して 127 で終わる
# （区切りの空白が無い）。展開まで伏せる版では本文が `bash <スイート>` に化け、
# **走らないスイートを「配線されている」**と答えた（`strip_arithmetic` を照合へ渡していた）
assert_not_wired "算術展開はコマンドの一部なので伏せない（空白なしで続く展開）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH}\$(( 1 ))"

# 同じ取り違えは**逆向き**にも効く（この差分が入れかけた退行）。`! (( true ))` を「偽」と読むと
# 右辺の `set +e` が「走らない」ことになり、握り潰されたスイートが「ゲートしている」と読まれる
assert_not_wired "算術コマンドの反転で set +e を取り落とさない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ! (( true )) && set +e
          bash ${SUITE_PATH}
          echo end"

# **`{` の後ろの空白は必須**（issue #150 のレビューで実測）。`{true` は bash として
# 成り立たない綴り（`{true` という名前のコマンドを探して 127 で終わる）なので、
# グループの開きとして落とすと「真と分かる」に化ける。`&&` の左辺なので `set -e` も発動せず、
# **ステップは緑のままスイートが 1 度も走らない**。綴りの源は `CI_WORKFLOW_GROUP_OPENER`
for brace_chain_case in \
    "空白なしの true:{true" \
    "空白なしのコロン:{:" \
    "閉じる前の区切りが無い:{ echo a; true }"
do
    assert_not_wired "開きとして読めないブレース（${brace_chain_case%%:*}）は実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${brace_chain_case#*:} && bash ${SUITE_PATH}
          echo end"
done

# 締めすぎない側: **空白のあるブレースグループは従来どおり読む**（`{ true && <呼び出し>; }`）
assert_wired "空白のあるブレースグループの中の真と分かる連鎖" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { true && bash ${SUITE_PATH}; }"

# **締めすぎない側＝短絡で結論が分かる連鎖は「必ず走る」のまま。**
# 連鎖の有無だけで見送ると、実際に走る呼び出しを「未配線」と事実と逆に診断して CI を赤くする。
# 真偽の判定は `chain_literal_status()` が持ち、**先頭のグループの開き（`( true`）・
# 末尾の閉じ（`( true )`）・飾り（`time` / `!`）を落としてから**比べる——生の綴りで
# `true` と比べていた版では、この 8 形（`( … )` と `{ … }` の中）が `not-wired` に化けた（実測）
for chain_known_case in \
    "真と分かる &&:true && bash ${SUITE_PATH}" \
    "コロンの &&:: && bash ${SUITE_PATH}" \
    "偽の && から || へ:false && echo mid || bash ${SUITE_PATH}" \
    "真の || から && へ:true || echo mid && bash ${SUITE_PATH}" \
    "部分シェルの中の真:( true && bash ${SUITE_PATH} )" \
    "閉じた部分シェル:( true ) && bash ${SUITE_PATH}" \
    "反転された偽:! false && bash ${SUITE_PATH}" \
    "time 付きの真:time true && bash ${SUITE_PATH}"
do
    assert_wired "結論の分かる連鎖（${chain_known_case%%:*}）は実行の証拠になる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${chain_known_case#*:}"
done

# **`!` で反転された `if true` / `while true` も「必ずゲートする」ではない**（レビューで実測）。
# `open_form()` は `strip_struct_wrappers()` を通して分類するので `! if true; then` も
# 「必ず走る」の種類になるが、`!` は終了状態を**反転**するので、本体が走って失敗しても
# ジョブは緑のまま終わる（実 `bash -e` で `! if true; then bash <suite>; fi` は rc=0）。
# ライブラリは `CI_WORKFLOW_COMMAND_PREFIXES` の説明で「`!` は入れない——あちらは終了状態を
# 反転するので、本当にゲートしない」と宣言しているのに、**制御構造に付いた `!` だけが
# その宣言から漏れていた**。1 行書きは錨を広げた時点で（issue #123 (3)）、複数行書きは
# `main` の時点で `wired` になっていた（どちらも実測）。剥がしたかどうかは
# `strip_struct_wrappers()` が `STRUCT_INVERTED` へ控える（綴りの一覧を呼び出し側へ写さない）。
for bang_guarded_case in \
    "1 行の if true:! if true; then bash ${SUITE_PATH}; fi" \
    "1 行の while true:! while :; do bash ${SUITE_PATH}; break; done" \
    "time と重ねた if true:! time if true; then bash ${SUITE_PATH}; fi" \
    "time を手前に置いた if true:time ! if true; then bash ${SUITE_PATH}; fi"
do
    assert_not_wired "! で反転した${bang_guarded_case%%:*}の本体は実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${bang_guarded_case#*:}"
done

assert_not_wired "! で反転した if true の本体は実行の証拠にしない（複数行）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ! if true; then
            bash ${SUITE_PATH}
          fi"

# **素のグループ（`( … )` / `{ … }`）に付いた `!` も同じ**（issue #155。`main` 既存の fail-open）。
# `open_form()` のブレースの判定は剥がす前の綴りを見るので `! { … }` は何も開かず、
# 先頭の `(` を越えるループも `^\(` を求めるので `! ( … )` では 1 度も回らない
# ——どちらも階層が開かないので反転を見る行に**そもそも到達しなかった**。
# **1 行に畳んだ `( … )` は閉じ括弧が呼び出しと同じ断片**なので、階層は記録より先に
# 閉じる。閉じた階層が反転していたことを控えて記録へ載せる（`closed_inverted`）
for bang_group_case in \
    "ブレースグループ:! { : ; bash ${SUITE_PATH} ; }" \
    "部分シェル:! ( : ; bash ${SUITE_PATH} )" \
    "部分シェルの中にアーム見出し:! ( case \"${DOLLAR}X\" in a) :;; esac ; bash ${SUITE_PATH} )" \
    "time と重ねたブレース:time ! { : ; bash ${SUITE_PATH} ; }" \
    "ブレースの中の if true:! { if true; then bash ${SUITE_PATH}; fi; }" \
    "部分シェルの中の if true:! ( if true; then bash ${SUITE_PATH}; fi )" \
    "ブレースの中の部分シェル:! { : ; ( bash ${SUITE_PATH} ) ; }"
do
    assert_not_wired "! で反転した${bang_group_case%%:*}の中は実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${bang_group_case#*:}"
done

# **締めすぎない側。** `!` が付いていない素のグループは必ず走るので今までどおり証拠にする。
# `time` だけの飾りも終了状態を通すので同じ（反転するのは `!` だけ）。
# `!` の付いたグループを**抜けた後ろ**も、反転はそのグループの終了状態にしか掛からない
for bang_group_live_case in \
    "飾りなしのブレース:{ : ; bash ${SUITE_PATH} ; }" \
    "飾りなしの部分シェル:( : ; bash ${SUITE_PATH} )" \
    "time だけのブレース:time { : ; bash ${SUITE_PATH} ; }" \
    "反転したブレースを抜けた後ろ:! { : ; }
          bash ${SUITE_PATH}" \
    "反転した部分シェルを抜けた後ろ:! ( : )
          bash ${SUITE_PATH}"
do
    assert_wired "反転していないグループの中は証拠のまま（${bang_group_live_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${bang_group_live_case#*:}"
done

# **`!` を重ねると打ち消し合う。** `STRUCT_INVERTED` を「1 を代入する掛け金」にすると
# `! ! if true; then <呼び出し>; fi` を「反転されている」と読み、実 bash では伝わる失敗を
# 「伝わらない」と判定する（fail-closed。実測で `main` は `not-wired`・実 bash は GATES）
assert_wired "! を重ねた if true の本体は実行の証拠になる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ! ! if true; then bash ${SUITE_PATH}; fi"

# **締めすぎない側**: `!` の無い `time` は今までどおり証拠になること（`STRUCT_INVERTED` を
# 「飾りが 1 つでも剥がれたか」にすると、計測するだけの `time` まで巻き込んで
# 正しくゲートしている呼び出しが実行の証拠から外れる）
assert_wired "time を付けた if true の本体は実行の証拠になる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          time if true; then bash ${SUITE_PATH}; fi"

# **アームの走査は丸括弧がいくつ並んでも必ず終わる**（issue #123 の補足で、到達不能だった
# 「1 文字も進まないなら打ち切る」門番を外したことの対）。`match()` はどちらの選択肢も
# `)` を 1 つ要求するので毎周必ず進むが、**止まらなければスイートが固まる**ので、
# 丸括弧が入れ子で並ぶ綴りを実際に通しておく（握り潰しが見えていることも同時に確かめる）
for arm_scan_case in \
    "主語にコマンド置換:case ${DOLLAR}(echo linux) in (linux) set +e ;; esac" \
    "入れ子のコマンド置換と複数アーム:case ${DOLLAR}(basename ${DOLLAR}(pwd)) in (a) : ;; (linux) set +e ;; esac"
do
    assert_swallowed "アームの走査が終わる（${arm_scan_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${arm_scan_case#*:}
          bash ${SUITE_PATH}"
done

# **締めすぎない側＝広げても開かないこと**（上と同じ 1 行書きで、**ライブラリには
# 本体が走ると証明できない**形）。`top` の絞り込みが効いていることをここで固定する——
# 錨だけを見て「継続語を許したら何でも通る」と読まないため。
# **「実 bash では失敗が中断させない形」と書かないこと**——最後の 1 件
# （連鎖に守られた `if true`）は `${DOLLAR}SKIP` が空なら**本体が走り、失敗はちゃんと
# 中断させる**（実測で rc=1）。`assert_not_wired` が正しいのは「ライブラリが
# `${DOLLAR}SKIP` を読めないので走ると主張しない」（fail-closed）からで、実 bash の
# 挙動を理由にすると、将来条件を読めるようにした人がこの対を「本体は走らない」の
# 根拠と読んで消しにかかる
for folded_uncertain_case in \
    "0 回まわるループ:for i in ${DOLLAR}NEVERSET; do bash ${SUITE_PATH}; done" \
    "until true:until true; do bash ${SUITE_PATH}; done" \
    "真と分かる条件の else:if true; then :; else bash ${SUITE_PATH}; fi" \
    "連鎖に守られた if true:if true && [ -z \"${DOLLAR}SKIP\" ]; then bash ${SUITE_PATH}; fi"
do
    assert_not_wired "1 行の${folded_uncertain_case%%:*}の本体は実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${folded_uncertain_case#*:}"
done

# **握り潰した本体は上のループから出してある。** スイートが最後の行だと握り潰しても
# 失敗がステップの終了状態になるので、このピンは後ろに 1 行足す形（`assert_swallowed`）で
# 測る。上のループの解説が言う「実 bash では本体が走り失敗はちゃんと中断させる」は
# 行を足すと成り立たなくなるため、同じループに置けない
assert_swallowed "1 行の握り潰した本体の本体は実行の証拠にしない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then set +e; bash ${SUITE_PATH}; fi"

# 上の受け皿が外れると一斉に穴になる形（**件数は書かない**——足すたびにこの数字だけが
# 古くなる。実際 4 と書いたまま 5 件目が足されていた）。**開き側が読めない語で始まる断片**の
# 後ろの継続語を命令の位置として扱うと、走らない本体が最上位の実行として記録される
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

# **上の 3 形も、止めているのは深さの勘定だけになった**（issue #123 (3) で
# `ci_workflow_runs_script` の錨が継続語を許したため、生の本文が `then` で始まっても
# 開始位置に当たる）。**「1 行書きなら受け皿でも止まる」と書かないこと**——この差分より前は
# 二重の網だったが、いまはこの 3 形も複数行の綴りと同じく `dead_depth` / `uncertain` の
# 1 枚だけで止まっている。複数行で書くと呼び出しの断片は素の `bash …` になるので、
# もともと深さの勘定だけだった——`open_form()` が `(` を読まないため、以前は `(` の後ろの
# 制御構造が**1 階層も開かないのに `fi` / `esac` だけが閉じていた**（issue #142 (3)）。
# 実測では 3 形すべてが `main` で `wired`（＝条件次第でしか走らないスイートが
# 「最上位で確実に走る」と報告される。1 文字で「最上位だけ」の絞り込みを迂回できた）
assert_not_wired "部分シェルの中の条件付き分岐の本体（複数行）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( if [ -n \"${DOLLAR}X\" ]; then
            bash ${SUITE_PATH}
          fi )"

assert_not_wired "部分シェルの中の case のアームの本体（複数行）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( case \"${DOLLAR}M\" in
            a)
              bash ${SUITE_PATH}
              ;;
          esac )"

# **閉じ側が 1 つ余分に閉じると、外側の条件の `uncertain` まで消える**（同じ根の別の症状）。
# `( if true; then :; fi )` は中が必ず走るので、それ自体は証拠になってよい形だが、
# **その後ろ**の呼び出しは外側の `if [ -n … ]` 次第でしか走らない。
# 以前は `fi )` が 2 階層閉じて（開いたのは `(` の 1 階層だけ）外側の印ごと巻き戻り、
# 続く呼び出しが最上位扱いになっていた（実測で `main` は `wired`）
assert_not_wired "部分シェルの中の制御構造を閉じた後ろは外側の条件のまま" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if [ -n \"${DOLLAR}X\" ]; then
            ( if true; then :; fi )
            bash ${SUITE_PATH}
          fi"

# **締めすぎない側**: 部分シェルに直接置いた呼び出しは今までどおり証拠になること
# （`(` を開き側で読むようにした変更が、必ず走る部分シェルまで巻き込んでいないこと）
assert_wired "部分シェルに直接置いた呼び出しは実行の証拠になる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          (
            bash ${SUITE_PATH}
          )"

# **階層の勘定が部分シェルを抜けたところで 0 に戻ること**（issue #142 のレビューで実測）。
# 上の 4 件はどれも「部分シェルの*中*の呼び出し」を問うので、`)` が食べられて
# `subshell` が漏れたままでも答えが変わらない——**漏れが見えるのは閉じた*後ろ*の断片**。
# ここは「閉じた後ろに置いた `set +e` が効く（＝親のオプションを変えられる）」を問うので、
# 漏れていれば `set +e` が「子シェルの中」として無視されて `wired` に化ける。
# 3 形とも**レビューの実測で壊れていた**（いずれも fail-open）
assert_swallowed "部分シェルの case を閉じた後ろの set +e は効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( case \"${DOLLAR}M\" in
            a) echo hi ;;
          esac )
          set +e
          bash ${SUITE_PATH}"

# `|` で切った POSIX のアーム模様（`(a|b)`）は、その `(` が部分シェルの開きではない。
# 先頭の `(` を越えて `case` を見つけられないと `case_scope` が偽になり、
# **アーム模様の `(` を部分シェルとして数える補正が働かない**（釣り合いが 1 つ膨らんで
# 階層が閉じ切らず、以降の `set +e` がすべて無視される）
assert_swallowed "部分シェルの中の選択肢アームでも釣り合いが戻る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( case ${DOLLAR}X in (a|b) echo hi ;;
          esac
          )
          set +e
          bash ${SUITE_PATH}"

# **偽と分かる条件の印は、その制御構造を囲っている階層に付ける。**
# 断片に入る前の深さを印にすると、階層を開く前置き（`(` / `{` / `f() {`）が手前に付いたとき
# **閉じた後も印が残り**、同じ前置きの中で*走る*後続の断片まで死に体として記録される
# ——正しくゲートしている綴りを「配線されていない」と事実と逆に診断して赤くする。
# `(` はレビューで実測した退行、`{` は `main` でも壊れていた既存の fail-closed
assert_wired "部分シェルの中で偽と分かる条件を閉じた後ろは生きている" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( if false; then :; fi
          bash ${SUITE_PATH}
          )"

assert_wired "ブレースの中で偽と分かる条件を閉じた後ろは生きている" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { if false; then :; fi
          bash ${SUITE_PATH}
          }"

# **前置きを重ねた形も同じこと**（レビューで実測した退行）。偽と分かる条件の印の深さは
# `last_deciding_open()` から導くが、その中で先頭の `(` を越える上限を**開いた階層すべての数**と
# 共有すると、手前に `{` や `f() {` があるだけで上限に当たり **`(` を 1 つも越えられない**
# ——印が 2 階層浅くなり、閉じた後も残って*走る*呼び出しが `not-wired` に化ける（fail-closed）。
# 越えた数は専用に数える（`cross_lead_subshells()`）。**重ね方を網羅するのが要点**で、
# 「手前に 1 つあるときだけ」「2 つ重なったときだけ」「内と外を入れ替えたときだけ」割れる
# 分断があるため、1 形だけ置くと残りが静かに穴になる（並べる綴りは重ね方 3 形
# ——`{ ( … ) }` / `{ ( ( … ) ) }` / `( { … } )`——と、偽と分かる条件の 3 綴り）。
# **`while false` / `until true` を併記するのは分類の枝が違うから**ではない
# （`if` / `while` / `until` は `open_form()` の同じ枝に落ちる）——偽と分かる条件を見る
# `strip_dead_cond_prefixes()` 側が `if|while` と `until` を**別の綴り**で判定しており、
# そちらの取りこぼしを押さえる
for composed_dead_case in \
    "ブレースと部分シェル:{ ( if false; then :; fi ) ; bash ${SUITE_PATH}; }" \
    "ブレースと二重の部分シェル:{ ( ( if false; then :; fi ) ) ; bash ${SUITE_PATH}; }" \
    "部分シェルとブレース:( { if false; then :; fi ; bash ${SUITE_PATH}; } )" \
    "ブレースと部分シェルの偽のループ:{ ( while false; do :; done ) ; bash ${SUITE_PATH}; }" \
    "ブレースと部分シェルの until ループ:{ ( until true; do :; done ) ; bash ${SUITE_PATH}; }"
do
    assert_wired "${composed_dead_case%%:*}を閉じた後ろは生きている" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${composed_dead_case#*:}"
done

# **越えた数で数える上限は 2 か所にあり、両方を固定する**（レビューで実測）。
# 上の 4 件が落とすのは `last_deciding_open()` 側（偽と分かる条件の印の深さ）だけで、
# `walk_opens_case()` 側（`case` を開くかの判定）を `cap - n` へ戻しても**全件緑のまま通る**。
# こちらは `{` を 2 つ重ねて上限を使い切ってから `(` の後ろに `case` を置くと、
# `case_scope` が偽になって POSIX のアーム模様 `(a|b)` の `(` が部分シェルの開きとして
# 数えられ、釣り合いが戻らないまま**最上位の `set +e` が「子シェルの中」として捨てられる**
# ——握り潰されたスイートが「ゲートしている」と読まれる fail-open
assert_not_wired "重ねた前置きの先で開く case も数える（上限は越えた数で）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { { ( case ${DOLLAR}M in (a|b) set +e ;; esac )
          set +e
          bash ${SUITE_PATH}"

# **締めすぎない側**: 前置きを重ねても、偽と分かる条件の**中**は証拠にしないこと
# （上の 4 件が「印をどこにも付けない」形で緑になっていないことを押さえる）
assert_not_wired "ブレースと部分シェルの中の偽と分かる分岐の本体" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { ( if false; then
            bash ${SUITE_PATH}
          fi ) ; }"

# **関数の本体は重ねても証拠にならない**（`f() { ( … ) }` の形。上の `assert_wired` 群と
# 同じ重ね方なので、こちらを置かないと「前置きを越えたら何でも最上位」へ緩めた変異が
# 全件緑のまま通る）。呼び出しを書いても同じ——このライブラリは関数の本体を
# 一度も実行の証拠にしない
for composed_fn_case in \
    "呼び出しなし:f() { ( if false; then :; fi ) ; bash ${SUITE_PATH}; }" \
    "呼び出しあり:f() { ( if false; then :; fi ) ; bash ${SUITE_PATH}; }
          f"
do
    assert_not_wired "関数の本体に重ねた前置き（${composed_fn_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${composed_fn_case#*:}"
done

# **1 行書きのアーム見出しを閉じる `)` は部分シェルの閉じではない**（issue #145）。
# `case ${DOLLAR}X in a)` の `)` は**対応する `(` を持たない**ので、生の釣り合いでは
# 手前の `(` を打ち消す。すると `(` の階層が 1 つも開かず、続く `esac` が
# **関数やブレースの階層**を閉じて、呼ばれていない本体が「最上位で確実に走る」として
# 記録されていた（`main` から続く fail-open。`f` は一度も呼ばれていないので実 bash では
# 1 行も走らない）。POSIX の綴り（`(a)`）と部分シェルの無い綴りは釣り合いが崩れないので
# `main` でも正しく `not-wired` だった＝**綴り 1 つで答えが変わる非対称**でもあった
for arm_close_case in \
    "部分シェルの中:f() { ( case ${DOLLAR}X in a) :;; esac ; bash ${SUITE_PATH} ) }" \
    "部分シェルが外:( f() { case ${DOLLAR}X in a) :;; esac ; bash ${SUITE_PATH}; } )" \
    "呼び出しあり:f() { ( case ${DOLLAR}X in a) :;; esac ; bash ${SUITE_PATH} ) }
          f" \
    "空白なしの開き:f() { (case ${DOLLAR}X in a) :;; esac ; bash ${SUITE_PATH} ) }" \
    "タブで開く:f() { (	case ${DOLLAR}X in a) :;; esac ; bash ${SUITE_PATH} ) }"
do
    assert_not_wired "裸のアーム見出しと関数の本体（${arm_close_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${arm_close_case#*:}"
done

# **締めすぎない側＝本物の部分シェルの閉じを食わないこと。** 落とすのは見出しを閉じる
# `)` の 1 文字だけなので、同じ断片にある本物の `( … )` は今までどおり閉じ、
# 最上位に置いた呼び出しは証拠のまま（実 bash でもすべて失敗が伝わる形）
for arm_close_live_case in \
    "部分シェルの中の最上位:( case ${DOLLAR}X in a) :;; esac ; bash ${SUITE_PATH} )" \
    "esac の後ろ:case ${DOLLAR}X in a) :;; esac
          bash ${SUITE_PATH}" \
    "アームの中の本物の部分シェル:case never in a) time ( : ) ;; esac
          bash ${SUITE_PATH}" \
    "ブレースの中:{ case ${DOLLAR}X in a) :;; esac ; bash ${SUITE_PATH}; }"
do
    assert_wired "裸のアーム見出しがあっても証拠になる（${arm_close_live_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${arm_close_live_case#*:}"
done

# **この差分で締めすぎが 1 つほどけた**（実 bash を真値とした 800 ケースの総当たりで実測）。
# 部分シェルの中の `set +e` は**親の errexit を消さない**ので、部分シェルの終了状態
# （＝最後のコマンドの状態）がそのまま親へ伝わり、失敗はジョブへ届く。ところが
# 1 行書きのアーム見出しで釣り合いが崩れていた分、`(` の階層が開かず `set +e` が
# **最上位のもの**として読まれ、続く呼び出しが「握り潰されている」と判定されていた
# （fail-closed＝正しくゲートしている設定を「配線されていない」と報告する向き）
# **1 行書きの `( … )` も同じ**。この形は**上限（`lead_subshell_cap()`）に同じ補正を
# 入れると `not-wired` へ戻る**ので、補正を入れない判断をここで固定している
# （入れた版では先頭の `(` を越えて `case_depth` が増え、続く `set +e` の読み方が変わる。
#  800 ケースの総当たりで差はこの形と `( { … ; } )` の 2 つだけ＝実測）
for subsh_setoff_case in \
    "改行で開く:(
          case \"${DOLLAR}M\" in a) echo hi ;; esac ; set +e
          bash ${SUITE_PATH}
          )" \
    "1 行で開く:( case \"${DOLLAR}M\" in a) echo hi ;; esac ; set +e
          bash ${SUITE_PATH} )" \
    "ブレースを重ねる:( { case \"${DOLLAR}M\" in a) echo hi ;; esac ; set +e
          bash ${SUITE_PATH} ; } )"
do
    assert_wired "部分シェルの中の set +e は親の errexit を消さない（${subsh_setoff_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${subsh_setoff_case#*:}"
done

# **部分シェルの中の `set +e` は、同じ部分シェルの中の呼び出しへ効く**（issue #152。`main` 既存の
# fail-open）。以前は `subshell == 0` で丸ごと捨てていたため、握り潰された呼び出しが
# 「ゲートしている」と読まれていた（実 `bash -e` では失敗がジョブへ届かない）。
# **部分シェルの終了状態は「最後に走ったコマンドの状態」**なので、握り潰しが効くのは
# **後ろにコマンドが続くとき**だけ——続かなければ失敗はそのまま親へ伝わる。
# したがって対は「後ろにコマンドがある／ない」で分かれる
for subshell_weaken_case in \
    "部分シェルの中のループ:( while true; do set +e; bash ${SUITE_PATH}; break; done )" \
    "パイプの右のループ:echo x | while true; do set +e; bash ${SUITE_PATH}; break; done" \
    "部分シェルの中で落として後ろに別のコマンド:(
          set +e
          bash ${SUITE_PATH}
          echo done )" \
    "部分シェルの中の if の中で落として後ろに別のコマンド:(
          if true; then set +e; fi
          bash ${SUITE_PATH}
          echo done )"
do
    assert_not_wired "部分シェルの中の set +e は中の呼び出しへ効く（${subshell_weaken_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${subshell_weaken_case#*:}"
done

# **この対は 1 行書き（`( set +e; …`）では書かない**（レビュー指摘）——あの綴りでは
# `set_command()` が先頭の `(` を越えられず `set +e` が**そもそも読まれない**ので、
# 下の 3 つの向き（同じ部分シェルの中での打ち消し・閉じたときの巻き戻し・最後の
# コマンドの失敗が外へ出ること。**「引き上げ」ではない**——#199 で削除したあとは
# `record_gates()` の階層の歩きが担う）を 1 つも見張らないまま緑になる（実測で、`subshell == 0` の
# 門番を戻しても落ちなかった）。複数行の綴り（とパイプの右側）で書く
# **打ち消しの対は「呼び出しの後ろにもう 1 行」置く**——最後のコマンドなら失敗がそのまま
# ステップの終了状態になって救われるので、打ち消しが壊れても緑のまま通る（当時これを
# 救っていたのは issue #152 の引き上げで、#199 で削除したあとは `record_gates()` の
# 階層の歩きが同じ答えを出す。**ピンの形は変えない**。実測で、同一性の
# 判定を反転させる変異が 634 件すべて緑だった）
# **締めすぎない側。** 部分シェルの中の `set +e` を**親へ漏らす**と、正しくゲートしている
# ステップを「握り潰されている」と誤報して必須ジョブが赤くなる（issue #152 が明示的に
# 禁じている向き）。`( … )` を閉じたら入口の姿へ戻すこと・最後のコマンドの失敗は外へ出ること
# （**引き上げではない**。#199 で削除したあとは `record_gates()` の階層の歩きが担う）・
# 外側の `set +e` の下で内側の `set -e` を credit しないことの 3 つをここで固定する
# （最後のものは、credit すると「部分シェルは自分の中で止まるだけで親は止まらない」のに
#  ゲートしていると読む＝540 形の総当たりで 47 形が誤った。実測）
for subshell_keep_case in \
    "部分シェルを抜けた後ろ:(
          set +e
          true
          )
          bash ${SUITE_PATH}" \
    "部分シェルのループの中で落として抜けた後ろ:( for f in a; do set +e; done )
          bash ${SUITE_PATH}" \
    "落として戻した部分シェルの中:(
          set +e
          set -e
          bash ${SUITE_PATH}
          echo done
          )" \
    "部分シェルの中の最後のコマンド:(
          set +e
          bash ${SUITE_PATH}
          )" \
    "ブレースを挟んだ部分シェルの中の最後のコマンド:( {
          set +e
          bash ${SUITE_PATH}
          ; } )" \
    "パイプの右で落として最後のコマンド:echo x | {
          set +e
          bash ${SUITE_PATH}
          }"
do
    assert_wired "部分シェルの中の set +e を漏らさない（${subshell_keep_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${subshell_keep_case#*:}"
done

# **`set` を開き括弧と同じ断片に書いた綴り（`( set +e`）も読む**（issue #180）。
# `strip_command_prefixes()` は `(` を落とさない（落とすと階層を二重に開く）ので、
# 以前は `set_probe` が空になり握り潰しの存在そのものを見落としていた——`errexit` が
# 立ったままになるので、その部分シェルの中の呼び出しがまるごと「合否に効く」と
# 読まれる（**4 トークンでスイートをゲートから外せる fail-open**）。
# 下の 4 形はどれも実 `bash -e` で NOGATE（部分シェルは 0 で終わるので失敗が伝わらない）
for lead_sub_set_case in \
    "複数行:( set +e
          bash ${SUITE_PATH}
          echo done )" \
    "ループを挟む:( set +e
          while true; do bash ${SUITE_PATH}; break; done
          )" \
    "一行:( set +e; bash ${SUITE_PATH}; echo done )" \
    "二重の部分シェル:( ( set +e
          bash ${SUITE_PATH}
          echo done ) )" \
    "ブレースの前置き:{ ( set +e
          bash ${SUITE_PATH}
          echo done )
          }" \
    "time の前置き:time ( set +e
          bash ${SUITE_PATH}
          echo done )" \
    "ブレースと time:{ time ( set +e
          bash ${SUITE_PATH}
          echo done )
          }" \
    "time とブレース:time { ( set +e
          bash ${SUITE_PATH}
          echo done ) ; }" \
    "入れ子のブレース:{ { ( set +e
          bash ${SUITE_PATH}
          echo done ) } }" \
    "ブレースの前置きと二重の部分シェル:{ ( ( set +e
          bash ${SUITE_PATH}
          echo done ) )
          }" \
    "ブレースの前置きと一行:{ ( set +e; bash ${SUITE_PATH}; echo done ) ; }"
do
    assert_not_wired "開き括弧と同じ断片の set +e を読む（${lead_sub_set_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${lead_sub_set_case#*:}"
done

# **越えた分は「その部分シェルの中で落とした」として記録する**（issue #180）。
# 階層ごとの連番（`sub_id`）は開き側のループで振られ、それはこの `set` の処理より
# **後ろ**なので、素直に読むと親の番号になり同じ部分シェルの中の `set -e` が
# 打ち消せない（実 `bash -e` は GATES なのに `not-wired`＝正しくゲートする綴りを赤くする）
# **前置きの後ろでも打ち消せる**（issue #187）。覗きを広げるだけで予約の宛先を直さないと、
# `{ ( set +e` の握り潰しが**ブレースの階層**へ結び付き、同じ部分シェルの中の `set -e` が
# 打ち消せなくなる（wired → not-wired。正しくゲートする綴りを赤くする向きで、
# issue #187 がレビューの実測として記録している退行）。実 `bash -e` はどちらも GATES
for lead_sub_cancel_case in \
    "ブレースの前置き:{ ( set +e
          set -e
          bash ${SUITE_PATH}
          echo done )
          }" \
    "time の前置き:time ( set +e
          set -e
          bash ${SUITE_PATH}
          echo done )" \
    "入れ子のブレース:{ { ( set +e
          set -e
          bash ${SUITE_PATH}
          echo done ) } }"
do
    assert_wired "前置きの後ろの set +e も中の set -e で戻せる（${lead_sub_cancel_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${lead_sub_cancel_case#*:}"
done

assert_wired "開き括弧と同じ断片の set +e は中の set -e で戻せる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( set +e
          set -e
          bash ${SUITE_PATH}
          echo done )"

# **部分シェルを閉じたあとの呼び出しは握り潰しを継がない**（issue #180）。
# 越えた分を親の階層へ記録すると、`)` の巻き戻しで戻らず以降すべてが未配線に化ける
assert_wired "部分シェルの中の set +e は閉じたあとへ漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( set +e
          echo x )
          bash ${SUITE_PATH}
          echo done"

# **部分シェルの同一性は深さの数値では測れない**（issue #152 のレビュー指摘）。
# 閉じたブレースと同じ深さに開いた部分シェルを区別できないと、ブレースの中で落とした分が
# 「この部分シェルの中で落とした」ことになり、内側の `set -e` を credit してしまう
# （実 `bash -e` は NOGATE なのに `wired`＝握り潰されたスイートが「ゲートしている」と読まれる）。
# 階層ごとに振る連番（`sub_id`）で見るので、下の 2 形はどちらも握り潰しのまま
for sub_identity_case in \
    "ブレースで落とす:{ set +e; }" \
    "必ず走るブロックで落とす:if true; then set +e; fi"
do
    assert_not_wired "部分シェルの外で落とした分は中の set -e で戻せない（${sub_identity_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${sub_identity_case#*:}
          (
          set -e
          bash ${SUITE_PATH}
          echo done )"
done

# **入れ子の部分シェルでも、内側が外側の最後のコマンドなら失敗は外へ出続ける**（真値 GATES）。
# 当時これを支えていたのは issue #152 の「引き上げ候補を外側へ引き継ぐ」仕掛けで、
# **#199 で削除した**（削除は `main` の fail-open を直している。下の「部分シェルの最後が
# set -e なら…」のピンを参照）——いまは `record_gates()` が階層を
# 1 段ずつ出ながら測って同じ答えを出す。**ピンはそのまま残す**: どれも「内側が最後なら
# 失敗は外へ出る」という挙動そのものを固定しており、6 形は本文が互いに違う
# （複数行 1 形＋閉じる断片のリダイレクト 5 綴り）。**このループにブレースの綴りは無い**——
# グループは下の `assert_wired "グループの && の連鎖がパイプで終わっても合否に効く"` が
# 独立に押さえている（フォークせず閉じても errexit を戻さないので理由が別。**こちらを
# 「このループが覆っている」と読んで消さないこと**——`record_gates()` のパイプの落としから
# `absorbed` の免除を外す変異で落ちる 6 本のうちの 1 本で、**ブレースの綴りはその 1 本だけ**
# ＝実測）。
# **ただし「issue #177 の退行をここだけが
# 捕まえている」とは書かない（実測で誤り）**——`CI_WORKFLOW_REDIRECT_LEAD` を #177 の
# 素朴な 1 文字形へ戻す変異を当て、**このループを丸ごと削除してからもう一度当てても**
# `先頭に置いたリダイレクト付きの set +e` のピンが落ちて退行は検出されたままだった。
# 定数を両方のループが共有しているので、どちらからでも同じ退行に当たる
# （**落ちたピンの件数は書かない**——どちらもループの件数の和なので、綴りを 1 つ足すと
#  この文だけが古くなる。何も突き合わせていない数字は置かない）
for sub_last_cmd_case in \
    "入れ子の部分シェル（複数行）:(
          set +e
          (
          bash ${SUITE_PATH}
          )
          )" \
    "閉じる断片のリダイレクト:(
          set +e
          bash ${SUITE_PATH}
          ) >/dev/null" \
    "閉じる断片の追記リダイレクト:(
          set +e
          bash ${SUITE_PATH}
          ) >> /dev/null" \
    "閉じる断片の番号付き追記リダイレクト:(
          set +e
          bash ${SUITE_PATH}
          ) 2>> /dev/null" \
    "閉じる断片のまとめリダイレクト:(
          set +e
          bash ${SUITE_PATH}
          ) &> /dev/null" \
    "閉じる断片のここ文字列:(
          set +e
          bash ${SUITE_PATH}
          ) <<< x"
do
    assert_wired "部分シェルの最後のコマンドの失敗は外へ出る（${sub_last_cmd_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${sub_last_cmd_case#*:}"
done

# **部分シェルの最後に走るのが `set -e` なら、その中のスイートの失敗は外へ出ない**
# （真値 NOGATE）。issue #199 で削除した引き上げは、閉じた部分シェルの**入口の** errexit を
# 記録へ書き戻していたので、握り潰されたスイートを「ゲートしている」と読んでいた
# （`main` は wired。**この削除が実際に直した fail-open** で、「どの判定も決めていない」
# という削除時の見立ては誤りだった＝4 巡目のレビューで反例を受けて実測）。
# **向きが fail-open なので必ずピンで押さえる**——同等の引き上げを復活させると、
# 失敗がステップに届かないワークフローをまた wired と報告する。
# **条件は「最後に走るのが `set -e`」ではない（8 巡目のレビューで測り直した）。**
# 効いているのは**スイートのあとで `set -e` に戻すこと**で、その後ろにコマンドが続いても同じ
# （`set +e` / スイート / `set -e` / `echo z` / `)` は真値 NOGATE・base wired・head 未配線。
# `:` / `true` / `cd .` / `echo z | cat` / `echo z && echo y` と閉じる断片のリダイレクト付きで実測）。
# 逆に **`set -e` を書かずに後続行だけ置く形は base でも正しく未配線**なので、
# 引き金は `set -e` の側。制御構造の有無も条件ではなく、いちばん素直な
# `(` / `set +e` / `bash <スイート>` / `set -e` / `)` も同じ。
# **向きは一方向**で、変わるのは必ず wired → not-wired（逆向きは 1 件も無い。
# corpus ごとの実測値は `docs/requirements.md` の変更履歴が正本——件数を写さない）。
# **だからピンは「素の形・`if` の中・`while` の中・`set -e` の後ろに行が続く形」をそろえる**。
# 最後のものが無いと、「部分シェルの最後が `set -e` のときだけ」と狭めて引き上げを戻す変異が
# **全ピン緑のまま**通り、実際のスクリプトがいちばん書く綴り（`set +e` → スイート →
# `set -e` → 続きの処理）で fail-open が戻る（レビュー指摘。実測で base は wired）
# **区切りは `:` だけにする（9 巡目のレビューで実測）。** 1 度は 4 本を素直に並べたが、
# その理由（「見出しと閉じが別の行なので 2 つ目の区切りが要る」）は**誤り**だった——
# 本文は複数行のまま 1 つの文字列に入るので、近隣のループと同じ `"ラベル:本文"` で足りる。
# 4 巡目に `|` を 2 つ目の区切りにしたのが**不要な 3 分割**で、`%%|*` / `##*|` が最初と最後の
# `|` の間を黙って捨てるため本文にパイプを含む形で**偽のピン**になっていた（正本は
# `docs/requirements.md`）。ループへ戻すと `ケースの一覧のラベルにコロンを含めない` の
# 検出網（ソースから一覧を導く）にも入る
for sub_tail_set_case in \
    "素の部分シェル:(
          set +e
          bash ${SUITE_PATH}
          set -e
          )" \
    "if の中:(
          if true; then
          set +e
          bash ${SUITE_PATH}
          set -e
          fi )" \
    "while の中:(
          while true; do
          set +e
          bash ${SUITE_PATH}
          set -e
          break; done )" \
    "set -e に戻したあと処理が続く:(
          set +e
          bash ${SUITE_PATH}
          set -e
          echo z
          )"
do
    assert_not_wired "部分シェルでスイートのあと set -e に戻すと失敗は外へ出ない（${sub_tail_set_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${sub_tail_set_case#*:}"
done

# **向きの対。** 末尾の `set -e` を外すと部分シェルの最後に走るのはスイート自身なので
# 失敗は外へ出る（真値 GATES。`main` も head も wired）。この 1 本が無いと、上の 2 形を
# 「部分シェルの中の制御構造はいつでも握り潰す」と広げる変異が素通りする
assert_wired "部分シェルの最後がスイートなら失敗は外へ出る（if の中）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          (
          if true; then
          set +e
          bash ${SUITE_PATH}
          fi )"

# **グループ（`{ … ; }`）でも `&&` の連鎖がパイプで終われば失敗はステップの状態になる**
# （真値 GATES）。**部分シェルの引き上げとは別の理由**で——グループはフォークせず
# 閉じても errexit を戻さないので、並びの失敗がそのままステップの終了状態になる。
# 上のループのアサート文は「部分シェル」と名乗るので、同じ文で報告しない
assert_wired "グループの && の連鎖がパイプで終わっても合否に効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          {
          set +e
          bash ${SUITE_PATH} && echo ok | cat ; }"

# 締めすぎない側: **`pipefail` 無しでパイプの左に置いたスイートは握り潰される**（真値 NOGATE）。
# **この向きを決めているのは `record_gates()` のパイプの落とし**（`op == "|" && !absorbed && !p_here`
# なら未配線へ倒す）。issue #199 は**部分シェルの引き上げ**の門番が見る区切りの集合を広げるよう
# 提案していたが、広げても答えは 1 件も変わらず（実測。全ピン・36 形・corpus 7 本 3,530 形すべて
# 同一）、**引き上げ自体は当時の計測の範囲でどの判定も決めていなかったので同じ PR で削除した**
# （識別子はもう無い。**その見立ては後で覆り、削除は `main` の fail-open を直していた**
#  ——`test/lib/ci_workflow.sh` の削除跡のコメントが正本）。
# **同じ本体のピンは既にあり**（`パイプで握り潰す`）、ここは閉じ括弧を同じ断片に置く形と
# グループだけを足している
for sub_pipe_swallow_case in \
    "閉じ括弧が同じ断片:(
          set +e
          bash ${SUITE_PATH} | cat )" \
    "グループ:{
          set +e
          bash ${SUITE_PATH} | cat ; }"
do
    assert_not_wired "pipefail 無しのパイプの左は握り潰される（${sub_pipe_swallow_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${sub_pipe_swallow_case#*:}"
done

# **`&&` でつながった並びが部分シェルの最後のコマンドなら、どの要素の失敗も親へ伝わる**
# （issue #193）。`&&` は左が落ちた時点で短絡するので、その失敗がそのまま部分シェルの
# 終了状態になる（実 `bash -e` で GATES）。**当時これを決めていたのは issue #152 の引き上げ**で、
# 候補を 1 件しか控えない形だと右辺（`echo ok`）がスイートの控えを潰し、
# **正しくゲートしている綴りを「未配線」と逆の診断で赤くする**退行だった
# （issue #180 の対応＝`( set +e` を読むようにした変更が作った形。閉じる断片のコマンドを見る
#  門番も区切りを見ていなかったので、1 行書きと `… && echo ok )` の 2 形は候補が正しくても
#  引き上げを見送っていた）。**その機構は #199 で削除した**ので、いまこのループを決めているのは
# `record_gates()` の階層の歩き——失敗したピンを追うときに「部分シェルごとの候補の台帳」を
# 探さないこと（識別子はもう無い）。**ピンの形は変えない**: 真値も向きも変わっていない
for sub_and_chain_case in \
    "複数行:(
          set +e
          bash ${SUITE_PATH} && echo ok
          )" \
    "閉じ括弧が同じ断片:(
          set +e
          bash ${SUITE_PATH} && echo ok )" \
    "一行:( set +e; bash ${SUITE_PATH} && echo ok )" \
    "3 つつなぐ:(
          set +e
          bash ${SUITE_PATH} && echo a && echo b
          )" \
    "閉じる断片のリダイレクト:(
          set +e
          bash ${SUITE_PATH} && echo ok
          ) >/dev/null" \
    "末尾の ; で閉じる:(
          set +e
          bash ${SUITE_PATH} && echo ok;
          )" \
    "内側の部分シェルの中で並ぶ:(
          set +e
          ( bash ${SUITE_PATH} && echo ok )
          )" \
    "内側の部分シェルに && が付く:(
          set +e
          ( bash ${SUITE_PATH} ) && echo ok
          )" \
    "&& の右辺として開いた部分シェル:(
          set +e
          bash ${SUITE_PATH} && (
          echo x
          )
          )" \
    "&& の右辺の部分シェルを閉じる断片がコマンドを持つ:(
          set +e
          bash ${SUITE_PATH} && (
          echo x )
          )" \
    "&& の右辺の部分シェルを 1 断片で書く:(
          set +e
          bash ${SUITE_PATH} && ( echo x )
          )" \
    "並びの右辺がパイプライン:(
          set +e
          bash ${SUITE_PATH} && echo ok | cat
          )" \
    "並びの右辺が 2 段のパイプライン:(
          set +e
          bash ${SUITE_PATH} && echo ok | cat | wc -l
          )" \
    "部分シェルの中で && が続く:(
          set +e
          (
          bash ${SUITE_PATH} &&
          echo ok )
          )" \
    "&& の右辺の部分シェルの中でも && が続く:(
          set +e
          true && (
          bash ${SUITE_PATH} &&
          echo ok )
          )" \
    "pipefail つきのパイプの左:(
          set +e
          set -o pipefail
          bash ${SUITE_PATH} | cat
          )" \
    "pipefail つきのパイプの左のあと &&:(
          set +e
          set -o pipefail
          bash ${SUITE_PATH} | cat && echo ok
          )" \
    "pipefail を部分シェルの外で立てる:set -o pipefail
          (
          set +e
          bash ${SUITE_PATH} | cat
          )" \
    "&& の右辺がパイプで閉じ括弧が同じ断片:(
          set +e
          bash ${SUITE_PATH} && echo ok | cat )"
do
    assert_wired "&& の連鎖が部分シェルの最後なら失敗は外へ出る（${sub_and_chain_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${sub_and_chain_case#*:}"
done

# **向きの対。** 上の「部分シェルの最後の `&&` の連鎖の失敗は外へ出る」を**区切りを問わず**
# まで広げると、手前の失敗が
# 右辺の実行に吸われる綴りまで「ゲートしている」と読む fail-open になる（実 `bash -e` は
# いずれも NOGATE）。`||` は左が落ちても右辺が走って 0 で終わり、`;` や改行で続く綴りは
# 後ろのコマンドが終了状態を上書きする。**`&& … || …` も握り潰し側**で、短絡しても
# `||` の右辺が拾うので失敗は 1 つも漏れない
for sub_and_chain_swallowed_case in \
    "|| で拾う:(
          set +e
          bash ${SUITE_PATH} || echo fallback
          )" \
    "&& のあと || で拾う:(
          set +e
          bash ${SUITE_PATH} && echo ok || echo bad
          )" \
    "|| のあと && でつなぐ:(
          set +e
          bash ${SUITE_PATH} || true && echo ok
          )" \
    "並びの後ろにもう 1 行:(
          set +e
          bash ${SUITE_PATH} && echo ok
          echo z
          )" \
    "閉じ括弧の断片が || で拾う:(
          set +e
          bash ${SUITE_PATH} && echo ok || echo bad )" \
    "パイプで握り潰す:(
          set +e
          bash ${SUITE_PATH} | cat
          )" \
    "パイプで握り潰したあと && でつなぐ:(
          set +e
          bash ${SUITE_PATH} | cat && echo ok
          )" \
    "&& の右辺の部分シェルの中で後ろにもう 1 行:(
          set +e
          true && (
          bash ${SUITE_PATH}
          echo ok )
          )" \
    "部分シェルの中で後ろにもう 1 行:(
          set +e
          (
          bash ${SUITE_PATH}
          echo ok )
          )" \
    "部分シェルより手前で終わる:(
          set +e
          bash ${SUITE_PATH}
          (
          echo x )
          )"
do
    assert_not_wired "&& の連鎖でも握り潰される側（${sub_and_chain_swallowed_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${sub_and_chain_swallowed_case#*:}"
done

assert_not_wired "外で落として部分シェルの中で戻しても credit しない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          (
          set -e
          bash ${SUITE_PATH}
          echo done )"

# **POSIX の綴り（`(a)`）には触らないこと。** 開閉が揃っているので釣り合いは崩れておらず、
# `drop_arm_head_close()` が `(` を含む見出しまで落とすと**本物の階層が 1 つ余分に開いたまま残る**。
# 下の形はそれが fail-open として現れる: 部分シェルが閉じたのに階層が残るので、
# 続く最上位の `set +e` が「子シェルの中」として捨てられ、**握り潰されたスイートが
# 「ゲートしている」と読まれる**（実測で、門番を外した版は `wired`。実 bash は NOGATE）。
# **`f() { ( case $X in (a) … ) }` のような形では固定できない**——あちらは門番の有無に
# かかわらず `not-wired` なので、置いても何も見張らない（実測）
assert_swallowed "POSIX の綴りのアーム見出しの後ろの set +e は最上位のまま" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( case ${DOLLAR}X in (a) :;; esac )
          set +e
          bash ${SUITE_PATH}"

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
assert_swallowed "1 行の丸括弧付き選択肢アームの set +e は数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case x in (x|y) set +e ;; esac
          bash ${SUITE_PATH}"

assert_swallowed "主語がコマンド置換でも選択肢アームの set +e は数える" "name: ci
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
assert_swallowed ";; の後ろの丸括弧付き選択肢アームの set +e は数える" "name: ci
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
assert_swallowed ";& の後ろの丸括弧付き選択肢アームの set +e は数える" "name: ci
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

# 模様が `|` で切られた断片が**入ってくるパイプ**も持つ場合。入ってくる `|` は前の断片の
# ものなので、出ていく `|` が模様の区切りでも子シェルの印は付ける
assert_wired "パイプの右側の case で模様が切られていても子シェル" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          echo x | { case zz in zz|yy) set +e ;; esac; }
          bash ${SUITE_PATH}"

# `case_scope` は「先頭が `case` か」ではなく「この断片が `case` を開くか」で見る。
# 先頭一致だけだと `{ case zz in (zz` / `f() { case zz in (zz` でアーム模様の `(` が
# 本物の部分シェルとして数えられ、そのアームの `set +e` が捨てられる
assert_swallowed "ブレースの中の case の丸括弧付き選択肢アーム（同一断片）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { case zz in (zz|yy) set +e ;; esac; }
          bash ${SUITE_PATH}"

assert_swallowed "関数の中の case の丸括弧付き選択肢アーム（同一断片）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { case zz in (zz|yy) set +e ;; esac; }
          f
          bash ${SUITE_PATH}"

# `case_depth` の走査の模様位置ガードは、控えてある `pipe_in` を読む。`prev_op` は
# この断片の処理中に自分の区切りへ更新されるので、素直に書くと「前が `|`」ではなく
# 「後ろが `|`」を意味し、`esac | cat` で `case_depth` だけが残る
assert_wired "esac にパイプが付いても case の入れ子は戻る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case zz in
          a) : ;;
          esac | cat
          echo x | while read -r l; do set +e; done
          bash ${SUITE_PATH}"

# アーム見出しを剥がす位置は**伏せた写しで測る**（切るのは生の本文）。揃えないと
# 引用の中の `)` で剥がす量がずれ、アームの中の複合コマンドが 1 つも数えられず、
# 後の `done` が `case` の階層を閉じて一致しないアームの中身が最上位に上がる
assert_not_wired "引用の中に ) を含むアーム見出しでも本文を数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case never in
          \"a)b\") for i in 1; do
          :
          done
          bash ${SUITE_PATH} ;;
          esac"

# 模様の位置は「この断片が**自分で開いた** `case` の模様を読み切ったか」で決める。
# 「断片が `in` で終わるか」で見ると、1 行書きで模様が `|` に切られた形を取りこぼし、
# 模様の途中の閉じ語（`done`）が `case` の階層を閉じてしまう
assert_not_wired "1 行書きの (aa|done|cc) 模様でも閉じ語は模様" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case never in (aa|done|cc) : ;;
          xx)
          bash ${SUITE_PATH}
          ;;
          esac"

# 括弧の勘定側のアーム見出し剥がしも伏せた写しで測る（3 か所すべて同じ規則に揃える）。
# 揃えないと引用の中の `)` で剥がす量がずれ、残りの `)` が開いていない階層を閉じる
assert_not_wired "引用の中の ) を含む模様でも括弧の勘定が合う" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case never in
          \"a)b\"\"c)d\") ( : )
          bash ${SUITE_PATH}
          ;;
          esac"

# アーム見出しを剥がすかどうかも「この断片が（先頭とは限らず）`case` を開くか」で見る。
# 先頭一致だと `{ case never in match) …` で前置きごと模様と読み、`case … in match)` を
# 丸ごと落として階層が 1 つも開かない
assert_not_wired "ブレースの中の 1 行 case でもアームの中身は最上位ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { case never in match) :
          bash ${SUITE_PATH}
          ;;
          esac; }"

# 模様を読み切ったかは **`case` の後ろの最初の `in`** で測る。1 本の貪欲な正規表現だと
# アームの本体にある裸の `in` に引っ張られ、消費済みの模様を「まだ来ていない」と読む
assert_not_wired "アームの本体に裸の in があっても模様は消費済み" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case never in match) echo hello in
          ( : | cat \$(date) )
          bash ${SUITE_PATH}
          ;;
          esac"

# アームの終端として認める空の断片は `;;` と `;&` だけ。`|&` も空の断片を残すが
# あれはパイプであって終端ではない（認めるとアームの本体の途中で模様の位置が立つ）
assert_not_wired "|& はアームの終端ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case never in
          match) echo x |& ( : | cat \$(date) )
          bash ${SUITE_PATH} ;;
          esac"

# `case_scope` をこの断片が開く `case` まで広げた副作用を固定する 3 件。
# **入ってきた `|` が模様の区切りなのは模様の位置にいたときだけ**——本物のパイプで
# 入ってきた断片がたまたまアーム見出しを含む場合まで見送ると、子シェルの `set +e` を
# 親に効いたものとして扱う
assert_wired "本物のパイプの右側の case アームの set +e は漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          echo x | { case zz in zz) set +e ;; esac; }
          bash ${SUITE_PATH}"

# アームの `set` を記録する階層は「`case` までに開いた分」。頭一致で +1 に決め打ちすると、
# `case` の前に別の開きがある綴りで記録側が浅くなり、同じアームの `set -e` が打ち消せない
assert_wired "ブレースの中の case アームでも set -e で打ち消せる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { case x in a) set +e ; set -e ;; esac; }
          bash ${SUITE_PATH}"

assert_wired "関数の中の case アームでも set -e で打ち消せる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { case x in a) set +e ; set -e ;; esac; }
          f
          bash ${SUITE_PATH}"

# 記録側と打ち消し側は同じ階層を指す必要がある。記録は「その `set` が走る深さ」、
# 打ち消しは「同じか、それより外側（＝より確実に走る）階層なら成立」。
# 逆向き（外で落として内で戻す）は成立させない（すぐ下の対で固定）
assert_wired "入れ子の 1 行定義でも本文の set -e で打ち消せる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { g() { set +e; set -e; }; :; }
          f
          bash ${SUITE_PATH}"

assert_wired "アームで落として本文で戻す関数は弱めない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { case x in a) set +e ;; esac; set -e; }
          f
          bash ${SUITE_PATH}"

assert_wired "アームの中のブレースで括った set +e … set -e" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case a in a|b) { set +e; set -e; } ;; esac
          bash ${SUITE_PATH}"

# 模様を読み切ったかは**一番内側＝最後の** `case … in` で測る。1 行に入れ子で書くと
# 外側が先に来るので、最初の 1 つで測ると内側のアームの位置が立たない
assert_swallowed "1 行の入れ子 case でも内側のアームの set +e を数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case \"${DOLLAR}OSTYPE\" in linux*) case \"${DOLLAR}CI\" in true|1) set +e ;; esac ;; esac
          bash ${SUITE_PATH}"

# 模様の**途中**に来た `esac` は模様であって閉じ語ではない（先頭に来たものだけが
# 空の `case` の終わり）。深さの走査と `case_depth` の走査の**両方**を揃えないと、
# 片方だけが数えて `case_scope` が偽になり、本物のアームの `set` が見つからなくなる
assert_swallowed "模様の途中の esac は閉じ語ではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          case zz in
          (done|esac|zz) set +e ;;
          esac
          bash ${SUITE_PATH}"

assert_swallowed "ブレースの中で開いた case の選択肢アームの set +e は数える" "name: ci
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
assert_swallowed "入れ子の 1 行定義の本文の set +e も、呼べば効く" "name: ci
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

# **部分シェルを越えて見つけた握り潰しは「関数が弱める」として控えない**（issue #187）。
# `f() { ( set +e; : ); }` の `set +e` は部分シェルと一緒に消えるので、呼び出し元の
# errexit は立ったまま——控えると「この関数は弱める」と記録され、呼び出しより後ろの
# スイートが**まるごと未配線**と報告される（真値 GATES なのに not-wired。正しくゲート
# する綴りを赤くする）。実 `bash -e` は下の 7 形すべて GATES
for fn_sub_set_case in \
    "一行:f() { ( set +e; : ); }" \
    "見出しが別行:f()
          { ( set +e; : ); }" \
    "function の綴り:function f { ( set +e; : ); }" \
    "time の前置き:f() { time ( set +e; : ); }" \
    "二重の部分シェル:f() { ( ( set +e; : ) ); }" \
    "ブレース挟み:f() { { ( set +e; : ); }; }" \
    "入れ子の定義:g() { f() { ( set +e; : ); }; }
          g" \
    "本文が複数行:f() {
          ( set +e
          :
          )
          }" \
    "長い綴り:f() { ( set +o errexit; : ); }" \
    "長い綴りの pipefail:f() { ( set +o pipefail; : ); }"
do
    assert_wired "部分シェルの中の set +e は関数の台帳へ載せない（${fn_sub_set_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${fn_sub_set_case#*:}
          f
          bash ${SUITE_PATH}
          echo tail"
done

# 向きの対: 本文の素の `set +e` は（部分シェルの中ではないので）従来どおり台帳へ載る
assert_not_wired "本文の素の set +e は呼べば効く（部分シェルを越えた分と区別する）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          f() { set +e; }
          f
          bash ${SUITE_PATH}
          echo tail"

# 台帳の名前は「`set` を探す側がどの名前に帰属させるか」に合わせる。断片の先頭が
# 定義でないとき（`{ f() { …`）まで外側の名前へ寄せると名無しになり、
# 記録そのものが落ちて握り潰しが見えなくなる
assert_swallowed "ブレースの中で開いた定義の本文の set +e も、呼べば効く" "name: ci
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

# 締めすぎない側の裏返し（fail-open の防止）: 本文の中でも**走るとは限らない**階層の
# `set -e` は打ち消しにならない。台帳の階層を関数の階層まで一気に畳むと、
# `if [ -n "$X" ]; then set -e; fi` の 4 行で握り潰された関数が「戻している」に化ける
assert_swallowed "条件の中の set -e は関数の握り潰しを打ち消さない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -e
          f() {
          set +e
          if [ -n \"${DOLLAR}MAYBE\" ]; then
          set -e
          fi
          }
          f
          bash ${SUITE_PATH}"

# 最上位で定義した関数の台帳は、無関係な複合コマンドがフォークして閉じても消えない
assert_swallowed "最上位の定義の台帳はフォークで消えない" "name: ci
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
assert_swallowed "子シェルの中の set +e も関数の台帳には残る（既知の締めすぎ）" "name: ci
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
assert_swallowed "外側のアームの中で開いた case の選択肢アームも読む" "name: ci
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
assert_swallowed "模様の位置の done は閉じ語ではない" "name: ci
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
assert_swallowed "ブレースの中で開いた case の次行の選択肢アームも読む" "name: ci
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

assert_swallowed "通る分岐の set +e は握り潰しとして効く" "name: ci
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

# **後置の `&&` は位置で決まる**（issue #149。`main` 既存の fail-open）。POSIX は
# AND-OR の並びのうち**最後以外**を `-e` の対象外とするので、`bash <スイート> && echo ok`
# の失敗はその場では捨てられる。**ただし並び自身がステップの最後のコマンドなら**、
# 並びの終了状態（＝スイートの失敗）がステップの終了状態になって伝わる
# （実 `bash -e` で、本文がその 1 行だけなら GATES・後ろに 1 行足すと NOGATE ＝実測）。
# 以前は `&&` を一律「伝わる」側に倒していたので、**スイートをワークフローから外して
# `&& echo ok` と 1 行を足すだけ**で `ci_coverage_test.sh` が緑のまま通った。
# **閉じ語だけの記録（`}` / `fi` / `done` / `)`）は「後ろのコマンド」に数えない**
# **閉じた部分シェルに付いた `&&` は「部分シェルの中だから伝わる」と読んではいけない**
# ——免除が起きるのは閉じた**外側**なので、伝えるときは記録の「部分シェルの中か」の
# 旗も落とす（落とさないと `( bash <スイート> ) && echo ok` ＋後ろの 1 行が
# 位置によらず wired に化ける＝実測で、この対が無いと変異が素通りした）
for and_absorbed_case in \
    "素の &&:bash ${SUITE_PATH} && echo ok
          echo done" \
    "ブレースの中:{ bash ${SUITE_PATH} && echo ok ; }
          echo done" \
    "if の本体:if true; then bash ${SUITE_PATH} && echo ok ; fi
          echo done" \
    "fi に付いた &&:if true; then bash ${SUITE_PATH} ; fi && echo ok
          echo done" \
    "連鎖の途中:true && bash ${SUITE_PATH} && echo ok
          echo done" \
    "閉じたブレースに付いた &&:{ bash ${SUITE_PATH} ; } && echo ok
          echo done" \
    "閉じた部分シェルに付いた &&:( bash ${SUITE_PATH} ) && echo ok
          echo done" \
    "複数行で閉じた部分シェルに付いた &&:( bash ${SUITE_PATH}
          ) && echo ok
          echo done"
do
    assert_not_wired "後ろに行がある && の左辺は合否に効かない（${and_absorbed_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${and_absorbed_case#*:}"
done

# **締めすぎない側。** 並びがステップの最後なら伝わる（上の各形から後ろの 1 行を抜いたもの）。
# **部分シェルの中の `&&` は位置によらず伝わる**——`( … && … )` の終了状態は親で検査されるので
# 免除が及ばない（実 `bash -e` で後ろに 1 行足しても GATES ＝実測）
for and_live_case in \
    "素の && が最後:bash ${SUITE_PATH} && echo ok" \
    "ブレースの中が最後:{ bash ${SUITE_PATH} && echo ok ; }" \
    "if の本体が最後:if true; then bash ${SUITE_PATH} && echo ok ; fi" \
    "fi に付いた && が最後:if true; then bash ${SUITE_PATH} ; fi && echo ok" \
    "閉じたブレースに付いた && が最後:{ bash ${SUITE_PATH} ; } && echo ok" \
    "閉じた部分シェルに付いた && が最後:( bash ${SUITE_PATH} ) && echo ok" \
    "部分シェルの中の &&（後ろに行あり）:( bash ${SUITE_PATH} && echo ok )
          echo done" \
    "複数行で閉じた部分シェルに付いた && が最後:( bash ${SUITE_PATH}
          ) && echo ok" \
    "&& の右辺:true && bash ${SUITE_PATH}" \
    "閉じ語だけが後ろにある:{
          bash ${SUITE_PATH} && echo ok
          }"
do
    assert_wired "並びが最後なら && の左辺も合否に効く（${and_live_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${and_live_case#*:}"
done

# **アーム見出しの `)` を釣り合いから外すのは、`case` が命令の位置にあるときだけ**（issue #172）。
# `( : case x in y )` は `case` が**引数の位置**にある散文で、`)` は本物の部分シェルを閉じる。
# 外してしまうと閉じない部分シェルの階層が開き、以降の記録がすべて「部分シェルの中」として
# 書かれて issue #149 の位置の判定が飛ばされる（実測で、握り潰された `&& echo ok` が
# wired に化ける fail-open）。**命令の位置にある形（`(` の直後・`do` の後ろ 等）は
# 引き続き外す**ので、issue #145 の対（「裸のアーム見出しと関数の本体」6 形）が守る
# 締めすぎない側。**本体を開く語は断片の先頭にも来る**（レビュー指摘、実測）——`split_commands` は
# 断片の前後の空白を落とすので `then case $X in a) :` には手前の空白が無い。空白を必須にすると
# 見出しの `)` が釣り合いに残り、先頭の `(` を打ち消して階層が 1 つも開かず、
# **1 度も呼ばれない関数の本体が「最上位で確実に走る」と記録される**（issue #145 の fail-open が戻る）
for arm_head_body_word_case in \
    "then の直後:f() { ( if true; then case \$X in a) :;; esac; fi ; bash ${SUITE_PATH} ) }" \
    "do の直後:f() { ( for i in a; do case \$X in a) :;; esac; done ; bash ${SUITE_PATH} ) }" \
    "else の直後:f() { ( if false; then :; else case \$X in a) :;; esac; fi ; bash ${SUITE_PATH} ) }"
do
    assert_not_wired "本体を開く語の直後の見出しも釣り合いから外す（${arm_head_body_word_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${arm_head_body_word_case#*:}"
done

assert_not_wired "引数の位置の case は見出しとして読まない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( : case x in y )
          bash ${SUITE_PATH} && echo ok
          echo z"

# **伏せ字の写しを省く素通しは、引用符だけでなく打ち消し（`\\`）も見る**（issue #166）。
# `bash <スイート> \&& echo ok` の `\&` は**ただの引数**で、残る 1 つの `&` が
# 並びごと背後へ回す（実 `bash -e` で NOGATE ＝実測）。伏せ字で `\&` を空白へ潰さないと
# `&&` と読まれ、握り潰された実行が「ゲートしている」と報告される
for mask_escape_case in \
    "素の呼び出し:bash ${SUITE_PATH} \\&& echo ok" \
    "部分シェルの後ろ:( bash ${SUITE_PATH} ) \\&& echo ok"
do
    assert_not_wired "打ち消した & は演算子に数えない（${mask_escape_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${mask_escape_case#*:}"
done

# **素通しは「引用符が閉じていないか」の控えも必ず 0 に戻す**（issue #166）。
# あの控えはグローバルなので、落とさないと**前のステップの閉じていない引用符**が残り、
# 引用符を 1 つも含まない次のステップの行が「論理行の途中」と読まれて後ろの行と
# 連結される（実測で、握り潰されるはずの `&& echo ok` が wired に化ける fail-open）
assert_not_wired "前のステップの閉じない引用符が次のステップへ漏れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: first
        run: |
          echo \"unclosed
      - name: subject
        run: |
          bash ${SUITE_PATH} && echo ok
          echo done"

# **並びの途中で握り潰される形は位置を見る前に落とす**（レビュー指摘、実測）。
# `&` が付いた並びは丸ごと背後へ回り、`||` の右辺が綴りから真と分かるなら並びの
# 終了状態は 0 になる。どちらも実 `bash -e` で NOGATE。
# **部分シェルの中でも効く**——`( … || true )` は部分シェルの終了状態そのものが 0 になる
for and_swallowed_case in \
    "|| true が後ろ:bash ${SUITE_PATH} && echo ok || true" \
    "コロンの no-op が後ろ:bash ${SUITE_PATH} && echo ok || :" \
    "並びを背後へ回す:bash ${SUITE_PATH} && echo ok &" \
    "パイプラインで終わる並び＋後ろの行:bash ${SUITE_PATH} && echo ok | cat
          echo done" \
    "パイプラインの並びを背後へ回す:bash ${SUITE_PATH} && echo ok | cat &" \
    "部分シェルの中の || true:( bash ${SUITE_PATH} && echo ok || true )" \
    "読めない右辺の ||:bash ${SUITE_PATH} && echo ok || echo \"suite failed\"" \
    "部分シェルの中の読めない右辺:( bash ${SUITE_PATH} && echo ok || echo msg )" \
    "0 を明示した exit が後ろ:bash ${SUITE_PATH} && echo ok || exit 0" \
    "非 0 の算術コマンドが後ろ:bash ${SUITE_PATH} && echo ok || (( 1 ))" \
    "読めない算術コマンドが後ろ:bash ${SUITE_PATH} && echo ok || (( x ))" \
    "反転した 0 の算術コマンドが後ろ:bash ${SUITE_PATH} && echo ok || ! (( 0 ))"
do
    assert_not_wired "並びの途中で握り潰される（${and_swallowed_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${and_swallowed_case#*:}"
done

# 締めすぎない側。**パイプラインは並びの 1 要素なので跨ぐ**（跨がないと連鎖の終端が
# 「ステップの最後のコマンド」に届かず、正しくゲートしている綴りを未配線と報告する）。
# **「成功しえない右辺」の `||` は握り潰し扱いにしない**——並びをいつでも失敗させるので
# 実 `bash -e` では伝わる（実測で GATES）。`false` に加えて `exit` / `return` の
# 失敗で終わる綴りがここに入る（レビュー指摘。除く条件を `false` だけにしていた頃は
# `|| exit 1` を未配線と報告していた＝正しい配線を赤にする fail-closed）。
# **引数の終了状態が読めない脱出（`exit $rc`）だけは握り潰し側へ倒す**（下の節。
# issue #174 で置いた「読めない引数も失敗側へ倒す」を実測で入れ替えた）。
# **数値リテラルは 256 で割った余りが終了状態**なので `exit 256` は成功して終わる
for and_pipeline_case in \
    "パイプラインで終わる並びが最後:bash ${SUITE_PATH} && echo ok | cat" \
    "偽と分かる右辺の ||:bash ${SUITE_PATH} && echo ok || false" \
    "失敗で終わる exit が後ろ:bash ${SUITE_PATH} && echo ok || exit 1" \
    "引数の無い exit が後ろ:bash ${SUITE_PATH} && echo ok || exit" \
    "$? を持ち出す exit が後ろ:bash ${SUITE_PATH} && echo ok || exit \$?" \
    "失敗で終わる return が後ろ:bash ${SUITE_PATH} && echo ok || return 1" \
    "0 の算術コマンドが後ろ:bash ${SUITE_PATH} && echo ok || (( 0 ))" \
    "0 が並ぶ算術コマンドが後ろ:bash ${SUITE_PATH} && echo ok || (( 00 ))" \
    "反転した非 0 の算術コマンドが後ろ:bash ${SUITE_PATH} && echo ok || ! (( 1 ))"
do
    assert_wired "並びの終端まで届けば合否に効く（${and_pipeline_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${and_pipeline_case#*:}"
done

# **引数の終了状態が読めない脱出は「必ず失敗する」と言えないので握り潰し側へ倒す**
# （レビュー 5 巡目。issue #174 が置いた「読めない引数も失敗側へ倒す」の逆）。
# `bash <スイート> && echo ok || exit $rc` の真値は**変数の値で変わる**——実測で
# `rc=0` なら NOGATE・`rc=7` なら GATES。「失敗を伝えるために書くのがほぼすべて」
# という見立ては書き手の意図としては正しいが、**意図が外れた配備（`$rc` が 0）で
# 必須スイートが黙ってゲートしなくなる**のはこの照会がいちばん避けたい向きなので、
# 証明できないものは未配線へ倒す（§9 の「不明なら拒否」）。**よく書く綴りは読めるので
# 巻き込まれない**: 引数なしの `exit` と `exit $?` は `||` の右辺が走る条件
# （左辺が落ちた）から必ず非 0 で、数値リテラルも読める。
# **`exit 256` は成功して終わる**（待機状態は 8 ビットで剰余が 0）ので握り潰し側
for unreadable_escape_case in \
    "読めない変数の exit:bash ${SUITE_PATH} && echo ok || exit \$rc" \
    "波括弧つきの変数の exit:bash ${SUITE_PATH} && echo ok || exit \${code}" \
    "剰余が 0 になるリテラル:bash ${SUITE_PATH} && echo ok || exit 256" \
    "剰余が 0 になる大きなリテラル:bash ${SUITE_PATH} && echo ok || exit 512" \
    "0 を明示した exit:bash ${SUITE_PATH} && echo ok || exit 0"
do
    assert_not_wired "読めない・成功して終わる脱出は握り潰し側（${unreadable_escape_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${unreadable_escape_case#*:}"
done

# **`exit` は errexit の有無も並びの位置も問わずその場でシェルを終える**（レビュー 5 巡目）。
# 位置と errexit を見ていたため、`set +e` の下や後ろに行がある綴りで**正しくゲートして
# いるワークフローを赤く**していた（真値はすべて GATES。`main` も未配線＝この PR で
# 直す側）。**剰余が 0 のリテラルは上の節のとおり除く**
for exit_ends_shell_case in \
    "set +e の下の exit 1:set +e
          bash ${SUITE_PATH} || exit 1
          echo done" \
    "set +e の下の引数なし exit:set +e
          bash ${SUITE_PATH} || exit
          echo done" \
    "後ろに行がある exit 1:bash ${SUITE_PATH} || exit 1
          echo done" \
    "部分シェルの中の exit 1:( bash ${SUITE_PATH} || exit 1 )
          echo done"
do
    assert_wired "exit は位置と errexit を問わず終わらせる（${exit_ends_shell_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${exit_ends_shell_case#*:}"
done

# 締めすぎない側: **部分シェルの `exit` が終えるのはその部分シェルだけ**なので、
# 外で握り潰されれば失敗は伝わらない（実測で NOGATE。`aborts` の印を階層の外へ
# 持ち越すと「ゲートしている」と読む fail-open になる）
assert_not_wired "部分シェルの exit を外で握り潰す形は伝わらない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( bash ${SUITE_PATH} || exit 1 ) || true
          echo done"

# **`!` で反転した右辺は errexit を発動させない**（レビュー 4 巡目。この PR が入れた fail-open）。
# 並びはいつでも失敗するが**その場では落ちない**ので、後ろに行があればその行の状態で
# ステップが終わる（実測で NOGATE。反転を見ないと「1 件も走らないスイートがゲートして
# いる」と読む）。後ろに行が無ければ並びの状態がそのままステップの状態になる＝GATES
for inverted_rhs_case in \
    "反転した true:bash ${SUITE_PATH} || ! true" \
    "反転した ::bash ${SUITE_PATH} || ! :" \
    "反転した非 0 の算術:bash ${SUITE_PATH} || ! (( 1 ))" \
    "ブレースの中で反転:bash ${SUITE_PATH} || { ! true ; }"
do
    assert_swallowed "反転した || の右辺は errexit を発動させない（${inverted_rhs_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${inverted_rhs_case#*:}"
done

assert_wired "反転した || の右辺が最後ならステップの状態になる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || ! true"

# **`||` の右辺が複合なら、中で errexit がその場で落とす記録も見る**（レビュー 5 巡目）。
# 右辺は並びの**最後の要素**なので中の errexit が生きており、`|| ( false; true )` は
# `false` で死ぬ＝並びはいつでも失敗する（真値 GATES）。最後のコマンドだけを見ていたため
# 「成功しうる」と読んで未配線＝正しくゲートしている綴りを赤くしていた（`main` も同じ）
for compound_fatal_case in \
    "部分シェルの中の false:bash ${SUITE_PATH} || ( false; true )" \
    "ブレースの中の false:bash ${SUITE_PATH} || { false; true ; }" \
    "false のあとに表示:bash ${SUITE_PATH} || ( false; echo hi )" \
    "最後が false:bash ${SUITE_PATH} || ( echo a; false )" \
    "部分シェルに false だけ:bash ${SUITE_PATH} || ( false )"
do
    assert_wired "複合の右辺は中の errexit でも落ちる（${compound_fatal_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${compound_fatal_case#*:}
          echo done"
done

# 締めすぎない側。中の errexit を当てにできない 2 形（どちらも真値 NOGATE）:
# **複合が並びの最後の要素でなければ**中の errexit は抑制され、複合の状態は最後の
# コマンドのものになる。**中で `set +e` していれば**そもそも落ちない
for compound_fatal_control_case in \
    "後ろに && が続く:bash ${SUITE_PATH} || ( false; true ) && echo z" \
    "中で set +e:bash ${SUITE_PATH} || ( set +e; false; true )" \
    "手前で成功して抜ける:bash ${SUITE_PATH} || ( exit 0; false )"
do
    assert_not_wired "中の errexit を当てにできない複合の右辺（${compound_fatal_control_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${compound_fatal_control_case#*:}
          echo done"
done

# **1 断片で部分シェルを開く綴りの `exit` は、その部分シェルだけを終える**
# （レビュー 5 巡目の実装中に実測で見つけた穴）。`{ ( exit 1 ) ; }` の `exit` が終えるのは
# 内側の部分シェルなので、`set +e` の下では失敗が伝わらない（真値 NOGATE）。
# **階層の識別子では判定できない**——命令の手前で開いた数は括弧の開きを数えない経路があり、
# 記録の階層が部分シェルではなく外のグループになる（実測）ので、綴りの手前の `(` で見る
assert_not_wired "1 断片で開いた部分シェルの exit は外へ伝わらない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          bash ${SUITE_PATH} || { ( exit 1 ) ; }
          echo done"

# 対照（締めすぎない側）: 同じ綴りでも**素のグループなら同じシェル**なので終わらせる。
# 反転した複合は errexit を発動させない。パイプの左側は `pipefail` が無ければ捨てられる
for escape_compound_case in \
    "ブレースの中の exit は同じシェル:wired:bash ${SUITE_PATH} || { exit 1 ; } && echo z" \
    "部分シェルの中の最後が false:wired:bash ${SUITE_PATH} || ( : ; false )" \
    "並びを ; で閉じた複合:wired:bash ${SUITE_PATH} || { false ; } ; echo z" \
    "pipefail つきのパイプの左側:wired:set -o pipefail
          bash ${SUITE_PATH} || { false ; } | cat" \
    "反転した複合:not-wired:bash ${SUITE_PATH} || ! { false ; }" \
    "pipefail 無しのパイプの左側:not-wired:bash ${SUITE_PATH} || { false ; } | cat"
do
    escape_compound_label="${escape_compound_case%%:*}"
    escape_compound_rest="${escape_compound_case#*:}"
    escape_compound_want="${escape_compound_rest%%:*}"
    escape_compound_body="${escape_compound_rest#*:}"
    "assert_${escape_compound_want/-/_}" "複合の右辺の脱出と抑制（${escape_compound_label}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${escape_compound_body}
          echo done"
done

# **中で errexit が落とす記録として数えるのは「その記録自身の失敗で落ちる」ものだけ**
# （レビュー 5 巡目の実装中に実測で見つけた穴）。直後が `&&` / `||` なら並びの最後の要素では
# ないので errexit は抑制され、`|` ならパイプの左側、`&` なら背後の実行で、どちらも
# その失敗は複合の状態にならない——数えると**1 件も走らないスイートが「ゲートしている」**と
# 読まれる（真値はすべて NOGATE）
for fatal_suppressed_case in \
    "false のあとに && が続く:bash ${SUITE_PATH} || { false && echo z ; echo ok ; }" \
    "false のあとに || が続く:bash ${SUITE_PATH} || { false || echo z ; echo ok ; }" \
    "false をパイプの左側に置く:bash ${SUITE_PATH} || { false | cat ; echo ok ; }" \
    "false を背後へ回す:bash ${SUITE_PATH} || { false & echo ok ; }" \
    "通らないアームの中の false:bash ${SUITE_PATH} || ( if false; then false; fi; echo ok )"
do
    assert_not_wired "抑制された記録は複合を落とさない（${fatal_suppressed_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${fatal_suppressed_case#*:}
          echo done"
done

# 締めすぎない側: **並びを単独で終える記録なら複合を落とす**（真値 GATES）。
# 入れ子の部分シェルが失敗する形も、外側の階層では「失敗した 1 つのコマンド」なので落とす
# （中で `set +e` していても部分シェルの終了状態は非 0 になる）
for fatal_effective_case in \
    "単独の false:bash ${SUITE_PATH} || { false ; echo ok ; }" \
    "入れ子の部分シェルの false:bash ${SUITE_PATH} || { echo a; ( false ); echo ok ; }" \
    "入れ子の部分シェルの中の set +e:bash ${SUITE_PATH} || { echo a; ( set +e; false ); echo ok ; }"
do
    assert_wired "並びを単独で終える記録は複合を落とす（${fatal_effective_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${fatal_effective_case#*:}
          echo done"
done

# **内側の階層の失敗が外へ届かないなら、その複合は落ちない**（レビュー 6 巡目。実測で
# 見つけた fail-open）。中の `false` で内側の部分シェル・ブレースは死ぬが、その閉じの
# 後ろが `||` / `&&` なら受け手がいて、`|` ならパイプの左側、`&` なら背後の実行なので
# 外側の階層の終了状態にならない——数えると**1 件も走らないスイートが「ゲートしている」**
# と読まれる（真値はすべて NOGATE）
for inner_sep_case in \
    "部分シェルのあとに ||:(:):|| true" \
    "部分シェルのあとに &&:(:):&& echo z" \
    "部分シェルをパイプの左側へ:(:):| cat" \
    "部分シェルを背後へ:(:):& wait" \
    "ブレースのあとに ||:{:}:|| true" \
    "ブレースをパイプの左側へ:{:}:| cat"
do
    inner_open="$(printf '%s' "${inner_sep_case}" | cut -d: -f2)"
    inner_close="$(printf '%s' "${inner_sep_case}" | cut -d: -f3)"
    inner_sep="$(printf '%s' "${inner_sep_case}" | cut -d: -f4)"
    assert_not_wired "外へ届かない内側の失敗は複合を落とさない（${inner_sep_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || ${inner_open}
          ${inner_open}
          false
          ${inner_close} ${inner_sep}
          true
          ${inner_close}"
done

# 締めすぎない側: **内側の失敗が外へ届くなら落とす**（真値 GATES）
for inner_sep_ok_case in \
    "区切り無し:(:):" \
    "区切りが ;:(:):;" \
    "ブレースで区切り無し:{:}:"
do
    inner_open="$(printf '%s' "${inner_sep_ok_case}" | cut -d: -f2)"
    inner_close="$(printf '%s' "${inner_sep_ok_case}" | cut -d: -f3)"
    inner_sep="$(printf '%s' "${inner_sep_ok_case}" | cut -d: -f4)"
    assert_wired "外へ届く内側の失敗は複合を落とす（${inner_sep_ok_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || ${inner_open}
          ${inner_open}
          false
          ${inner_close} ${inner_sep}
          true
          ${inner_close}
          echo done"
done

# **走ると証明できない記録は複合を落とさない**（レビュー 6 巡目。実測で見つけた fail-open）。
# 呼ばれない関数の本体・空になりうる `for` の本体・一致しない `case` のアームはどれも
# 走るとは限らないので、その中の失敗を当てにできない。**`||` の受け皿に補助関数を書く**
# のはごく普通の綴りなので、これは偶然成立する（真値はすべて NOGATE）
for unproven_body_case in \
    "呼ばない関数の false:g() {
          false
          }
          echo ignored" \
    "呼ばない関数の exit 1:g() {
          exit 1
          }
          echo ignored" \
    "呼ばない関数の return 1:g() {
          return 1
          }
          echo ignored" \
    "空になりうる for の本体:for f in \$FILES; do
          false
          done
          echo ignored" \
    "until の本体:until true; do
          false
          done
          echo ignored" \
    "一致しない case のアーム:case y in
          x)
          false
          ;;
          esac
          echo ignored"
do
    assert_not_wired "走ると証明できない記録は複合を落とさない（${unproven_body_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          ${unproven_body_case#*:}
          )"
done

# **複合が並びの最後の要素でなければ、中の errexit は抑制される**（レビュー 5 巡目の機構に
# 6 巡目で付けたピン。それまで**どの変異でも落ちなかった**）。`) && echo z` の複合は
# AND-OR 並びの左辺なので中の `false` では死なず、`true` まで進んで成功する（真値 NOGATE）。
# **後ろに行を置くと位置の判定が先に未配線へ倒すので、この条件だけを見るには行を置かない**
assert_not_wired "最後の要素でない複合は中の errexit で落ちない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          false
          true
          ) && echo z"

# **複合の中の反転した記録も errexit を落とさない**（同じく 6 巡目で付けたピン）。
# `! true` はいつでも失敗するが反転した失敗では errexit が落ちないので、`echo ok` まで
# 進んで複合は成功する（真値 NOGATE）。**1 断片に畳んだ `|| { ! true ; }` は複合ではなく
# 連鎖として読まれる経路なので、この条件を通らない**——複数行で書く必要がある
assert_not_wired "複合の中の反転した記録は errexit を落とさない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || {
          ! true
          echo ok
          }
          echo done"

# **`&&` の右辺が制御構造なら、連鎖の終わりは閉じ語**（issue #198）。`if true; then` /
# `for f in a; do` / `case x in` の見出しは**条件や一覧を外側の階層で走らせる**ので記録は
# 外側に載るが、並びの要素としては `fi` / `done` / `esac` までが 1 つのコマンド。見出しで
# 連鎖が終わると本体が「後ろに続くコマンド」に見え、位置の判定が gate を 0 にする
# （真値 GATES なので fail-closed。`( … )` / `{ … ; }` は開き記号が命令の手前に来るので
# 記録自身が内側に載り、以前から正しく読めていた——**改行の位置ではなく綴りの違い**）
for ctrl_rhs_case in \
    "if true の本体:if true; then
          echo x
          fi" \
    "リテラルの一覧を回る for:for f in a; do
          echo x
          done" \
    "変数の一覧を回る for:for f in \$LIST; do
          echo x
          done" \
    "case の見出し:case x in
          x) echo hi ;;
          esac"
do
    assert_wired "&& の右辺の制御構造は閉じ語まで 1 つの要素（${ctrl_rhs_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && ${ctrl_rhs_case#*:}"
done

# 締めすぎない側: **後ろに行があれば握り潰される**（真値 NOGATE）。連鎖の状態は閉じ語で
# 確定するが、その後ろに行があればステップの状態はその行のものになる
for ctrl_rhs_tail_case in \
    "if true の本体:if true; then
          echo x
          fi" \
    "リテラルの一覧を回る for:for f in a; do
          echo x
          done" \
    "case の見出し:case x in
          x) echo hi ;;
          esac"
do
    assert_not_wired "制御構造の後ろに行があれば握り潰される（${ctrl_rhs_tail_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && ${ctrl_rhs_tail_case#*:}
          echo tail"
done

# 締めすぎない側: **`||` の右辺の制御構造は握り潰す**（真値 NOGATE）。本体が走れば複合は
# 成功しうるので、失敗はそこで受け止められる
for ctrl_or_case in \
    "if true の本体:if true; then
          echo x
          fi" \
    "case の見出し:case x in
          x) echo hi ;;
          esac"
do
    assert_not_wired "|| の右辺の制御構造は握り潰す（${ctrl_or_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || ${ctrl_or_case#*:}"
done

# **`||` の右辺の制御構造は「本体がいつでも失敗する」と読めない**（レビュー指摘。この差分が
# 入れた fail-open）。複合の状態は「中で最後に走ったコマンド」のものだが、制御構造の本体は
# 条件や一覧が空なら**1 度も走らない**ので、`false` や `exit 1` で終わる本体でも複合は
# 成功して抜けうる（真値 NOGATE）。上の `ctrl_or_case` は本体が必ず成功する綴りだけだったため、
# 門番（`rec_unc`）を外しても**966 ピンすべてが緑のまま通っていた**（実測）
for ctrl_or_fail_case in \
    "条件が読めない if の本体が失敗する:if [ -n \$DEBUG ]; then
          false
          fi" \
    "変数の一覧を回る for の本体が失敗する:for f in \$LIST; do
          false
          done" \
    "条件が読めない if の本体が脱出する:if [ -n \$DEBUG ]; then
          exit 1
          fi" \
    "読み込みの while の本体が失敗する:while read -r l; do
          false
          done < /dev/null"
do
    assert_not_wired "|| の右辺の制御構造は本体が失敗しても握り潰す（${ctrl_or_fail_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || ${ctrl_or_fail_case#*:}
          echo tail"
done

# **門番は「読めない」で打ち切らず下の枝へ落とす**: 本体が読めなくても、手前に「走ると
# 証明できる」致命的な記録があれば複合はそこで死ぬので並びはいつでも失敗する（真値 GATES。
# 打ち切る形に変えるとこの 1 形だけが未配線へ倒れる＝fail-closed）
assert_wired "|| の右辺の複合は手前の致命的な記録で死ぬ（後ろが読めなくても）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || ( false
          if [ -n \$D ]; then
          true
          fi )
          echo tail"

# **呼ばれていない関数の本体は `main` が持つ fail-open のまま**（真値 NOGATE なのに配線済み）。
# ここにピンは置かない——閉じるには「その階層が走るか」を**階層ごと**に答える機構が要り、
# 包んだ制御構造（`|| ( if true; then false; fi )` ＝真値 GATES で `main` も配線済み）を
# 巻き添えにせずに分ける必要がある。別 issue で扱う（この差分の範囲は #198）

# **包んだ制御構造は `main` の経路なので答えを変えない**（レビュー 9 巡目の指摘。上の門番を
# 一律に掛けると `( … )` / `{ … ; }` で包んだ形まで握り潰し側へ倒れ、**`main` が正しく
# 配線済みと答えていた 20 形が退行**していた＝正しくゲートしているワークフローを赤くする向き。
# 門番は見出しの複合を受け入れる新しい経路（`rec_opened`）だけに掛ける）
for wrapped_ctrl_case in \
    "部分シェルで包む:( if true; then
          false
          fi )" \
    "グループで包む:{ if true; then
          false
          fi ; }" \
    "部分シェルで包んだ for:( for f in a b; do
          false
          done )"
do
    assert_wired "包んだ制御構造は答えを変えない（${wrapped_ctrl_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || ${wrapped_ctrl_case#*:}"
done

# **連鎖の右辺が無い複合は読めない**（レビュー 9 巡目。この差分が入れた fail-open）。
# `bash -n` が通らない＝スイートが 1 件も走らないので真値 NOGATE・`main` も未配線だが、
# 見出しの複合を受け入れるようにした結果「複合の位置」だけで配線済みと答えていた
for dangling_chain_case in \
    "閉じ語の直前:if true; then
          echo a &&
          fi" \
    "継続語の直前:if true; then
          echo a &&
          else
          echo b
          fi" \
    "ループの閉じ語の直前:for f in a; do
          echo a &&
          done" \
    "case の閉じ語の直前:case x in
          x) echo a && ;;
          esac"
do
    assert_not_wired "連鎖の右辺が無い複合は未配線（${dangling_chain_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && ${dangling_chain_case#*:}"
done

# 締めすぎない側: **右辺のある連鎖は読める**（真値 GATES）。上の門番が「区切りが `&&` なら
# 落とす」へ広がっていないことを固定する
for inner_chain_case in \
    "改行をまたぐ連鎖:if true; then
          echo a &&
          echo b
          fi" \
    "1 行の連鎖:if true; then
          echo a && echo b
          fi"
do
    assert_wired "右辺のある連鎖は読める（${inner_chain_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && ${inner_chain_case#*:}"
done

# **残る境界（記録。真値 GATES なので fail-closed・`main` と同じ答え）**: 本体が必ず走る
# 制御構造でも、走ると証明する手段が無いので握り潰し側へ倒れる。上の fail-open を閉じる
# 代償で、6 巡目が同じ理由で受け入れた 4 形と同種（直すときはこのピンを意図して反転させる）
for ctrl_or_boundary_case in \
    "リテラルの一覧を回る for の本体が失敗する:for f in a b; do
          false
          done" \
    "リテラルで真の if の本体が失敗する:if true; then
          false
          fi"
do
    assert_not_wired "残る境界: 本体が必ず走る制御構造も握り潰し側（${ctrl_or_boundary_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || ${ctrl_or_boundary_case#*:}"
done

# **閉じ括弧が空白で隔てられていても右辺を読む**（レビュー 6 巡目の指摘。`main` も持つ
# fail-closed）。以前は末尾の閉じを落とす走査が空白を跨げなかったため、`false ) )` が
# 読めず未配線に倒れ、**空白を 1 つ詰めただけの同じプログラム（`))`）とは答えが食い違って**
# いた（真値はどちらも GATES）
for spaced_closer_case in \
    "部分シェル 2 段の false:( ( bash ${SUITE_PATH} || false ) )" \
    "部分シェル 2 段の exit 1:( ( bash ${SUITE_PATH} || exit 1 ) )" \
    "部分シェル 3 段:( ( ( bash ${SUITE_PATH} || false ) ) )" \
    "空白を詰めた形（対照）:( ( bash ${SUITE_PATH} || false ))"
do
    assert_wired "空白を挟んだ閉じでも右辺を読む（${spaced_closer_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${spaced_closer_case#*:}"
done

# **`$?` を持ち出す脱出は引用・波括弧の 4 綴りすべて読める**（レビュー 6 巡目の指摘。
# `main` も持つ fail-closed）。`||` の右辺が走るのは左辺が落ちたときだけなので、
# どの綴りも必ず非 0 で終わる。**`exit "$?"` は shellcheck が勧める書き方**なのに
# 「読めない引数」に落ちて正しくゲートしている綴りを赤くしていた——綴りの判定が
# 5 か所に写してあり 1 か所だけ広げ忘れていたのが原因で、同じ巡で `escape_probe()` /
# `escape_arg_carries_status()` へ一元化した
for status_escape_case in \
    "素の \$?:exit \$?" \
    "引用した \$?:exit \"\$?\"" \
    "波括弧:exit \${?}" \
    "引用した波括弧:exit \"\${?}\""
do
    assert_wired "\$? を持ち出す脱出は読める（${status_escape_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || ${status_escape_case#*:}
          echo done"
done

# **`exit` は同じシェルなら複合の中からでもその場で終える**（レビュー 5 巡目）。
# 素のグループ・制御構造の本体は同じシェルなので、`set +e` の下でも後ろに行があっても
# ステップの終了状態はその `exit` のものになる（真値 GATES）
for exit_in_group_case in \
    "set +e の下のブレースの中:set +e
          bash ${SUITE_PATH} || { echo x; exit 1 ; }" \
    "ブレースで囲んだ連鎖:{ bash ${SUITE_PATH} || exit 1 ; }" \
    "set +e の下でブレースで囲んだ連鎖:set +e
          { bash ${SUITE_PATH} || exit 1 ; }" \
    "後ろに || が続く:bash ${SUITE_PATH} || exit 1 || echo z" \
    "後ろに && が続く:bash ${SUITE_PATH} || exit 1 && echo z"
do
    assert_wired "同じシェルの exit は複合の中でも終わらせる（${exit_in_group_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${exit_in_group_case#*:}
          echo done"
done

# 締めすぎない側。**子シェルで走る `exit` は呼び出し元のシェルを終えない**（真値 NOGATE）。
# 部分シェル・パイプの要素・背後の実行がそれぞれ別のシェルで、印を持ち越すと
# 「1 件も走らないスイートがゲートしている」と読む fail-open になる
for exit_in_subshell_case in \
    "set +e の下の部分シェルの中:set +e
          bash ${SUITE_PATH} || ( echo x; exit 1 )" \
    "パイプの要素としての exit:bash ${SUITE_PATH} || exit 1 | cat" \
    "パイプの要素としてのブレース:bash ${SUITE_PATH} || { exit 1 ; } | cat" \
    "背後へ回した exit:bash ${SUITE_PATH} || exit 1 &"
do
    assert_not_wired "子シェルの exit は呼び出し元を終えない（${exit_in_subshell_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${exit_in_subshell_case#*:}
          echo done"
done

# **`&&` を伝えるとき、中の記録が既に持つ強い抑制を上書きしない**（レビュー指摘、実測）。
# `{ bash <スイート> || true; } && echo ok` の呼び出しは `||` で握り潰されていて外へ 1 つも
# 漏れないのに、閉じ括弧に付いた区切りで一律に塗り替えると `&&` になり、位置の判定を
# 通って「ゲートしている」と読まれる（実 `bash -e` は NOGATE）。
# `||` / `|` / `&` は `&&` より強い抑制なので、付いている方を残す
for and_keeps_suppressor_case in \
    "|| true で握り潰す:{ bash ${SUITE_PATH} || true; } && echo ok" \
    "パイプの左辺:( bash ${SUITE_PATH} | cat ) && echo ok" \
    "ブレースの中のパイプ:{ bash ${SUITE_PATH} | cat ; } && echo ok" \
    "背後へ回す:( bash ${SUITE_PATH} & ) && echo ok"
do
    assert_not_wired "握り潰した区切りは && の伝播で塗り替えない（${and_keeps_suppressor_case%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${and_keeps_suppressor_case#*:}"
done

# **裸のリダイレクトだけの行は 1 つのコマンド**で、`$?` を 0 にする（レビュー指摘、実測）。
# 「後ろのコマンド」に数えないと、連鎖がステップの最後だと読まれて握り潰された実行が
# ゲートしていると報告される（実 `bash -e` は NOGATE）
assert_not_wired "裸のリダイレクトだけの行が後ろにある" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && echo ok
          > out"

# 締めすぎない側。**閉じ括弧に付いたリダイレクトは終了状態を変えない**ので後ろの
# コマンドに数えない（issue #152 のレビュー指摘と同じ理由。数えると正しくゲートして
# いる綴りが未配線になる）
assert_wired "閉じ括弧に付いたリダイレクトは後ろのコマンドに数えない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          {
          bash ${SUITE_PATH} && echo ok
          } >/dev/null"

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

# --- ジョブ名の読み出し（渡すジョブ名の綴りを確かめるため） --------------------------

# `ci_workflow_job_names` の結果を 1 本の文字列にまとめて突き合わせる検査
assert_job_names() {
    # 合成ワークフローを書き出して読み込む
    local workflow="${TMP_DIR}/jobs.yml"
    printf '%s\n' "$2" > "${workflow}"
    ci_workflow_load "${workflow}" "${TMP_DIR}/jobs-commands" \
        || { report_fail "$1" "ワークフローを読み込めませんでした"; return; }
    # 出てきたジョブ名をカンマ区切りにして期待値と比べる
    local actual
    actual="$(ci_workflow_job_names | tr '\n' ',')"
    if [ "${actual}" = "$3" ]; then
        report 0 "$1"
    else
        report_fail "$1" "期待 [$3] に対して実際は [${actual}]"
    fi
}

assert_job_names "ジョブ名を宣言順に 1 件ずつ返す" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: a
        run: bash ${SUITE_PATH}
      - name: b
        run: echo hi
  e2e:
    runs-on: ubuntu-latest
    steps:
      - name: c
        run: echo hi" "type-check,e2e,"

# **折りたたみの `env:` を持つジョブは `run:` が無くても現れること**（`SHELL_FILES` を
# 定義するジョブがこの形になりうるため）
assert_job_names "env だけのジョブも一覧に現れる" "name: ci
jobs:
  only-env:
    runs-on: ubuntu-latest
    env:
      LIST: >-
        a.sh
    steps:
      - name: a
        uses: actions/checkout@v5" "only-env,"

# **境界の記録**: `run:` も折りたたみ `env:` も持たないジョブ（`uses:` のステップだけ）は
# 控えに 1 行も残らないので一覧に現れない。呼び出し側（`SUITE_JOBS` の値の照合）には
# 足りる——`run:` を 1 つも持たないジョブはスイートを走らせられないので、
# そこを表に登録することは最初から誤り。**「現れる」と読まないための固定**
assert_job_names "uses だけのジョブは一覧に現れない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: a
        run: bash ${SUITE_PATH}
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: b
        uses: actions/checkout@v5" "type-check,"

# 同じジョブの複数ステップで重複しないこと（突き合わせの表を素直に作れるようにする）
assert_job_names "同じジョブ名は畳んで 1 件にする" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    env:
      LIST: >-
        a.sh
    steps:
      - name: a
        run: bash ${SUITE_PATH}
      - name: b
        run: bash ${SUITE_PATH}" "type-check,"

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

# **鍵と指示子のあいだのノードプロパティを挟んでも読む**（issue #126 のレビューで実測）。
# 構造行側は `&files >-` をブロックの開始と認めて本文を読み飛ばすので、ここが読まないと
# 定義が 1 件も記録されず `ci_coverage_test.sh` が「定義が 0 か所」という事実と違う診断で落ちる
assert_env_block "ノードプロパティを挟んだ env の折りたたみブロックを読む" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    env:
      LIST: &files >-
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

# **連鎖の右辺でもリンタの網は見る**（issue #150）。実行の照会は「走ると証明できない」として
# 外すが、`test -n "${DOLLAR}LIST" && shellcheck ${DOLLAR}LIST` は正当な綴りなので、
# こちらで外すと**正しく設定されたリンタを「配線されていない」と報告**する（照会ごとに
# 意味が違うので、記録の 5 列目を見るのは `top` を渡す側だけ）
assert_matcher match "コマンド単位: 連鎖の右辺のコマンドも見る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: test -n \"${DOLLAR}LIST\" && shellcheck ${DOLLAR}LIST" \
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

# --- ブロック本体の先頭を許す開始位置（issue #114 (1)） --------------------------------

# **穴の側**: 意味の変わらない 1 行書きでも、ステップ単位の照合が満たされること。
# `split_commands` は `;` で切るので断片は `do bash -n "$f"` になり、
# `^` に錨を打った `CI_WORKFLOW_COMMAND_START` には当たらなかった
# （実際にはすべてのファイルが構文チェックされているのに「されない」と**事実と逆の診断**で
#  CI を赤くする＝整形しただけで赤くなる形）
assert_matcher match "ステップ単位: 1 行に畳んだループの本体も満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: for f in ${DOLLAR}LIST; do bash -n \"${DOLLAR}f\"; done" \
    ci_workflow_step_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}for +[A-Za-z_][A-Za-z0-9_]* +in +[^;&|]*[$][{]?LIST[}]?([^[:alnum:]_]|$)" "${CI_WORKFLOW_BLOCK_BODY_START}bash +-n([^[:alnum:]_]|$)"

# **旧い開始位置では当たらないこと**（この 2 つが別物であることの固定）。
# どちらかに寄せる変更が入ったら、ここか下の no-match が落ちる
assert_matcher no-match "ステップ単位: 旧い開始位置は 1 行書きに当たらない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: for f in ${DOLLAR}LIST; do bash -n \"${DOLLAR}f\"; done" \
    ci_workflow_step_matches "" "${CI_WORKFLOW_COMMAND_START}bash +-n([^[:alnum:]_]|$)"

# **広げた開始位置の代償を固定しておく**（issue #142 (1)）。ブロック本体の先頭を命令の位置と
# 認めると、**0 回まわりうるループの本体**も「配線されている」と数える。
# `bash -n` は一覧をループで回すほかに書きようが無いのでこの弱さを承知で受け入れているが、
# 一覧を 1 コマンドで受け取る `shellcheck` を同じ錨へ寄せると、
# `for f in ${DOLLAR}CHANGED; do shellcheck ${DOLLAR}LIST; done`（「変更された分だけ lint する」
# というごく自然なリファクタ）が `${DOLLAR}CHANGED` が空で**1 度も走らないまま**数えられる
# ——`shellcheck` を事実上無効化したまま全スイートが緑になる。
# **どちらの網がどの錨を使うかは `ci_coverage_test.sh` が決める**ので、ここでは
# 「2 つの錨がこの形で答えを変える」ことだけを固定する（寄せる変更が入ればこの対が落ちる）
LOOPED_LINT_WORKFLOW="name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: for f in ${DOLLAR}CHANGED; do shellcheck ${DOLLAR}LIST; done"

assert_matcher match "コマンド単位: 広げた開始位置は 0 回まわりうるループの本体も数える" \
    "${LOOPED_LINT_WORKFLOW}" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

assert_matcher no-match "コマンド単位: コマンドの位置の開始位置はループの本体を数えない" \
    "${LOOPED_LINT_WORKFLOW}" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_COMMAND_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

# **狭い錨が落とすのは 1 行書きだけ（実測。issue #146）。** 同じループを複数行で書くと
# 本体が独立した断片になるので、**錨の広狭に関係なく当たる**——この照会は
# `ci_workflow_gating_commands` を `top` なしで呼ぶ（制御構造の深さで絞らない）ため、
# 錨はループ本体を除く手段になっていない。穴は複数行の綴りでは開いたままで、
# **それでも錨は広げない**（広げれば 1 行書きでも同じ穴が開く）。
# ここは「狭い錨が何を保証していて何を保証していないか」を両向きで固定する
MULTILINE_LOOPED_LINT_WORKFLOW="name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: |
          for f in ${DOLLAR}CHANGED; do
              shellcheck ${DOLLAR}LIST
          done"

# **入れ子の部分シェルの中のコマンドは、合否に効く一覧から落ちない**（issue #199 の削除で
# 入れ子の綴りから消えるのは**裸の開き括弧**の記録——引き上げが errexit を入口の値へ
# 書き戻していたので公開対象に入っていた。入れ子 24 形でコマンドを持つ記録の消失は 0 件＝実測。
# **ただし「削除でコマンドを持つ記録が落ちることは無い」ではない**——部分シェルの最後が
# `set -e` になる綴りでは落ち、**そこは `main` の fail-open を直している側**。上の
# `sub_tail_set_case` のループがその形を押さえる（**件数は書かない**。`main` では全件落ちる））。
# **このピンは退行を捕まえるものではない（main も同じ答えを返す）。** **入れ子で開けば必ず
# 記録が変わるわけでもない**——素の入れ子（`(` / `set +e` / `(` / `shellcheck $LIST` / `)` / `)`）と、
# そこへ `echo y` を内側／内側の閉じの後ろへ足す形、開きの前に `true` を置く形は、
# main も head も同じ記録で差が出ない（16 巡目のレビューが「入れ子で部分シェルを開く綴り」と
# 一般化していたこの文へ反例を出し、こちらでも測り直した）。差が出たのは**開き／閉じの断片が
# コマンドを持つ**綴りで、`shellcheck $LIST && (` ＋ `echo x` ＋独立行の `)` が main 6 件・head 5 件
# （`echo x` を省くとどちらも 5 件で差が出ない＝**開いた部分シェルの中にコマンドが要る**。
# 9 巡目まで引用からこの行が抜けており、読み手が再現すると「差が無い」と出た）、
# `shellcheck $LIST | cat )` が main 4 件・head 3 件（**パイプは条件ではない**——前者は持たない）。
# **条件をこれ以上綴りの規則へ一般化しない**（挙げたのは測った形そのもの）。
# どちらで消えるのも裸の `(` だけで、スイートの記録は一覧に残る）。
# 裸の開き括弧はコマンドを持たないので
# 照会 3 つ（いずれもコマンドの綴りで突き合わせる）からは**観測できない**——それが
# 「答えは 1 つも動かない」の中身。ここで固定するのは動いてほしくない側の性質
# （入れ子の部分シェルの中のコマンドは一覧に残る）で、内側の閉じ括弧をコマンドと
# 同じ断片に置く綴りで押さえる
NESTED_SUB_LINT_WORKFLOW="name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: |
          (
          set +e
          (
          shellcheck ${DOLLAR}LIST )
          )"

assert_matcher match "コマンド単位: 入れ子の部分シェルの中のコマンドを数える" \
    "${NESTED_SUB_LINT_WORKFLOW}" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_COMMAND_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

assert_matcher match "コマンド単位: 複数行のループの本体は狭い開始位置でも数えてしまう" \
    "${MULTILINE_LOOPED_LINT_WORKFLOW}" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_COMMAND_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

assert_matcher match "コマンド単位: 複数行のループは広げた開始位置でも数える" \
    "${MULTILINE_LOOPED_LINT_WORKFLOW}" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

# **広げた側でも、複数行の書き方は今までどおり満たすこと**（退行していないこと）
assert_matcher match "ステップ単位: 複数行のループも引き続き満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: |
          for f in ${DOLLAR}LIST; do
              bash -n \"${DOLLAR}f\"
          done" \
    ci_workflow_step_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}for +[A-Za-z_][A-Za-z0-9_]* +in +[^;&|]*[$][{]?LIST[}]?([^[:alnum:]_]|$)" "${CI_WORKFLOW_BLOCK_BODY_START}bash +-n([^[:alnum:]_]|$)"

# **グループの開きは `do` / `then` / `else` の後ろ**（レビューで実測）。手前に置くと
# `( do …` という成り立たない綴りしか当たらず**一度も効かない門番**になり、実際に起きる
# `for f in $LIST; do ( bash -n "$f" ); done` の 1 行書き（断片は `do ( bash -n "$f" )`）が
# no-match のまま——全ファイルが構文チェックされているのに「されていない」と
# **事実と逆の診断**を出す（fail-closed）
for block_group_case in \
    "部分シェル:for f in ${DOLLAR}LIST; do ( bash -n \"${DOLLAR}f\" ); done" \
    "ブレースグループ:for f in ${DOLLAR}LIST; do { bash -n \"${DOLLAR}f\"; }; done" \
    "括りなし:for f in ${DOLLAR}LIST; do bash -n \"${DOLLAR}f\"; done"
do
    assert_matcher match "ステップ単位: ブロック本体の${block_group_case%%:*}も満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: ${block_group_case#*:}" \
        ci_workflow_step_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}bash +-n([^[:alnum:]_]|\$)"
done

# **広げた側でも実行ラッパを読み飛ばせること**（前置きの一覧を 1 か所に寄せた結果の確認）
assert_matcher match "ステップ単位: 本体の先頭の語と実行ラッパが重なっても満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: for f in ${DOLLAR}LIST; do sudo bash -n \"${DOLLAR}f\"; done" \
    ci_workflow_step_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}bash +-n([^[:alnum:]_]|$)"

# **締めすぎの側**: 「本当に実行されるか」を問う照会は、**0 回まわりうるループの**本体を
# 実行の証拠に数えないこと。**止めているのは錨ではなく `top` の絞り込み**
# （`uncertain == 0` の記録だけを通す）で、issue #123 (3) 以降この照会は
# `CI_WORKFLOW_BLOCK_BODY_START`＝継続語を許す錨を使っている。
# **この 1 件は「どちらの定数でも通る」**（レビューで実測）——`for f in a` は
# `open_form()` が形 2 として読むので本体は深さ 1 にあり、`top` が錨に関係なく除くため。
# 2 つの定数を 1 つに畳む変更を落とすのは同じファイルの 2 件
# （「ステップ単位: 旧い開始位置は 1 行書きに当たらない」と
# 「コマンド単位: コマンドの位置の開始位置はループの本体を数えない」。どちらも上にある）で、
# ここはその結論を照会の入口で重ねて固定するだけ。
# **`if true` / `while true` の 1 行書きを挙げないこと**——issue #123 (3) で
# `assert_wired` へ反転したので、畳む変異では落ちない（実測で確認した 2 件が上記）。
# **「この 1 件が定数の区別を守っている」と読まないこと**
assert_matcher no-match "実行網: 1 行に畳んだループの本体は実行の証拠に数えない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: suites
        run: for f in a; do bash test/subject_test.sh; done" \
    ci_workflow_runs_script 'test/subject_test.sh'

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

# --- 開き側が読めない飾りの後ろの偽と分かる条件（issue #114 のレビューで実測） --------
#
# `open_form()` は `( if false` / `time if false` / `! if false` / `eval if false` を
# 分類できないので、階層も `uncertain` も立たない。偽と分かる条件の判定が
# `^if` だけを見ていた頃は、**1 度も走らない本体がリンタの照合を満たしていた**
# ——`main` でも複数行で書けば素通りしており（既存の穴）、ブロック本体の先頭を許す
# 開始位置を入れると 1 行書きでも素通りした（どちらも実測）。
# 判定は `strip_dead_cond_prefixes()` が飾りを剥がしてから行う。
# **4 形すべてを置く**のが要点で、1 つでも欠けるとその綴りだけが静かに穴になる
for dead_prefix_case in \
    "部分シェル:( if false; then shellcheck ${DOLLAR}LIST; fi )" \
    "実行ラッパ:time if false; then shellcheck ${DOLLAR}LIST; fi" \
    "終了状態の反転:! if false; then shellcheck ${DOLLAR}LIST; fi" \
    "重ねた飾り:( ! time if false; then shellcheck ${DOLLAR}LIST; fi )" \
    "偽のループ:( while false; do shellcheck ${DOLLAR}LIST; done )" \
    "until が真:( until true; do shellcheck ${DOLLAR}LIST; done )" \
    "ブレースグループ:{ if false; then shellcheck ${DOLLAR}LIST; fi; }" \
    "ブレースの偽のループ:{ while false; do shellcheck ${DOLLAR}LIST; done; }" \
    "関数の本体:f() { if false; then shellcheck ${DOLLAR}LIST; fi; }" \
    "case のアーム:case ${DOLLAR}M in lint) if false; then shellcheck ${DOLLAR}LIST; fi;; esac" \
    "POSIX の case のアーム:case ${DOLLAR}M in (lint) if false; then shellcheck ${DOLLAR}LIST; fi;; esac" \
    "飾り付きの case のアーム:time case ${DOLLAR}M in lint) if false; then shellcheck ${DOLLAR}LIST; fi;; esac" \
    "反転付きの case のアーム:! case ${DOLLAR}M in lint) if false; then shellcheck ${DOLLAR}LIST; fi;; esac"
do
    assert_matcher no-match "コマンド単位: ${dead_prefix_case%%:*}の中の偽と分かる条件は満たさない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: ${dead_prefix_case#*:}" \
        ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'
done

# **`case` を開くかの判定も、分類と同じ剥がし方を通す**（レビューで実測した fail-open）。
# `open_form()` は `time` / `!` を剥がしてから分類するのに、「この断片は `case` を開くか」を
# 生の綴りで見ていたため、`time case …` / `! case …` では `case_depth` も `arm_expected` も
# 立たず、**アーム模様の `)` が部分シェルの閉じとして数えられて**一致しないアームの中身が
# 「最上位で確実に走る」に化けた（2 語足すだけで「最上位だけ」の絞り込みを迂回できた）。
# 素の綴りと答えがそろうことを対で押さえる
for decorated_case_arm in \
    "素の綴り:case ${DOLLAR}X in a) ( : | cat ) ; bash ${SUITE_PATH};; esac" \
    "time 付き:time case ${DOLLAR}X in a) ( : | cat ) ; bash ${SUITE_PATH};; esac" \
    "反転付き:! case ${DOLLAR}X in a) ( : | cat ) ; bash ${SUITE_PATH};; esac"
do
    assert_not_wired "一致しないアームの中身は最上位に上がらない（${decorated_case_arm%%:*}）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ${decorated_case_arm#*:}"
done

# --- 必ず走らないアームの中の lint（issue #142 (2)(3)） -----------------------------
#
# **偽と分かる条件とは別の経路**で 1 度も走らない本体がある: 真と分かる条件
# （`if true`）の残りのアームと、偽と分かる条件を持つ `elif`。どちらも
# `uncertain` を立てない側なので、印を付けないと「最上位で確実に走る」に化ける
assert_matcher no-match "コマンド単位: 真と分かる条件の else 側の lint は満たさない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: if true; then :; else shellcheck ${DOLLAR}LIST; fi" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

# **部分シェルに包むと印が立たなかった**（issue #142 (3)）。`open_form()` は `(` を
# 読まないので `( if true` の `if` が 1 階層も開かず、`true_at` の印が付かないまま
# `else` 側が「最上位で確実に走る」として記録されていた（実測で `main` は MATCH）
assert_matcher no-match "コマンド単位: 部分シェルの中の真と分かる条件の else 側の lint は満たさない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: ( if true; then :; else shellcheck ${DOLLAR}LIST; fi )" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

# **偽と分かる条件を持つ `elif` の本体も 1 度も走らない**（issue #142 (2)）。
# `elif` を `else` と同じ扱い（印の解除）にしていたので、2 語足すだけで
# 走らない lint が証拠に数えられた（実測で `main` は MATCH）
assert_matcher no-match "コマンド単位: 偽と分かる elif の中の lint は満たさない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: if false; then :; elif false; then shellcheck ${DOLLAR}LIST; fi" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

# **締めすぎない側**: 飾りを剥がした先が偽と分かる条件でなければ、今までどおり満たすこと。
# 剥がす対象を広げすぎると（`{ ` や変数代入まで剥がす、条件を読まずに一律で死に体と見る等）
# 正しく lint しているステップを「されていない」と誤報して赤くする
assert_matcher match "コマンド単位: 部分シェルの中の必ず走る条件は満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: ( if true; then shellcheck ${DOLLAR}LIST; fi )" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

assert_matcher match "コマンド単位: 部分シェルの中の条件付き分岐は満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: ( if [ -n \"${DOLLAR}X\" ]; then shellcheck ${DOLLAR}LIST; fi )" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

assert_matcher match "コマンド単位: 部分シェルに直接置いた呼び出しは満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: ( shellcheck ${DOLLAR}LIST )" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

# **POSIX のアーム見出しでも、偽でなければ証拠のまま**であること（issue #142 (4) の裏側）。
# `[^()]*` は内側の `(` を跨げないので、1 行書きの `case $M in (lint) …` では
# 見出しが剥がせず、偽と分かる条件の判定が当たらなかった（丸括弧なしの綴りは当たる
# ＝POSIX の綴りだけが外れる非対称）。剥がす側を広げた結果として
# **本物の lint を「無い」と診断する**方向へ倒れていないことを押さえる。
# **1 行書きのアームに置いた lint は、どちらの綴りでも証拠にならない**（実測）——
# 控えるのは生の本文なので `case … in (lint) shellcheck …` は開始位置に当たらない
# （`flush_step()` が「読めない以上は主張しない」と書いている受け皿。綴りによる
#   非対称ではないので、ここでは複数行書きで「証拠のまま」を押さえる）
assert_matcher match "コマンド単位: POSIX のアーム見出しの中の lint は満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: |
          case ${DOLLAR}M in
            (lint)
              shellcheck ${DOLLAR}LIST
              ;;
          esac" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

# **`elif <不明>` の本体は走りうるので証拠のまま**であること（issue #142 (2) の裏側）。
# 偽と分かる `elif` だけを死に体にする判定が、条件を読まずに一律で倒していないこと
assert_matcher match "コマンド単位: 条件が読めない elif の中の lint は満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: if false; then :; elif [ -n \"${DOLLAR}X\" ]; then shellcheck ${DOLLAR}LIST; fi" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

# **偽と分かる条件の else 側は必ず走る**ので証拠のまま（印の解除が効いていること）。
# `elif false` を印の付け直しにした変更が、`else` の解除まで止めていないこと
assert_matcher match "コマンド単位: 偽と分かる条件の else 側の lint は満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: if false; then :; else shellcheck ${DOLLAR}LIST; fi" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

# **部分シェルの中の `case` のアームも証拠のまま**（開き側が `(` を読むようにした変更が、
# アーム見出しの `)` を部分シェルの閉じと数えて `case` の階層を潰していないこと。
# `set_arm_here` の `subshell == 0` を模様の位置で緩めた分の裏側）
assert_matcher match "コマンド単位: 部分シェルの中の case のアームの lint は満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: |
          ( case ${DOLLAR}M in
            lint)
              shellcheck ${DOLLAR}LIST
              ;;
          esac )" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

# **引用で包んだ `eval` の中の複合コマンドは「開きっぱなし」にしない**（レビューで実測）。
# `split_commands` は引用の中の `;` で切らないので `eval "if false; …; fi"` は 1 断片で
# 自己完結する。`eval ` と引用符を落として分類すると `open_form()` が階層を開くのに
# 閉じる断片が来ず、**同じステップの以降すべて**が非ゲート扱いになって
# 「配線されていない」という事実と逆の診断が出た（`main` は正しく緑）
assert_matcher match "コマンド単位: 引用で包んだ eval の後ろは満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: |
          eval \"if false; then echo skipped; fi\"
          shellcheck ${DOLLAR}LIST" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

assert_matcher match "実行網: 引用で包んだ eval の後ろの呼び出しは実行の証拠になる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: suites
        run: |
          eval \"if false; then echo skipped; fi\"
          bash test/subject_test.sh" \
    ci_workflow_runs_script 'test/subject_test.sh'

# **ブレース・関数・アームの見出しを落としても、偽でない条件は証拠のまま**であること
assert_matcher match "コマンド単位: ブレースグループの中の条件付き分岐は満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: { if [ -n \"${DOLLAR}X\" ]; then shellcheck ${DOLLAR}LIST; fi; }" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

# **偽と分かる条件を閉じた後ろは生きている**こと（印の後始末が効いていること）。
# `dead_depth` を戻し忘れると、ステップの残り全部が証拠から外れて赤くなる
assert_matcher match "コマンド単位: 偽と分かる条件を閉じた後ろは満たす" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: lint
        run: |
          ( if false; then echo skipped; fi )
          shellcheck ${DOLLAR}LIST" \
    ci_workflow_command_matches "" "${CI_WORKFLOW_BLOCK_BODY_START}shellcheck([^[:alnum:]_])" '[$][{]?LIST[}]?([^[:alnum:]_]|$)'

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
        run: |
          bash '"${SUITE_PATH}"'
          echo done'

assert_not_wired "ワークフロー既定の shell: は鍵が引用符付きでも効く" 'name: ci
defaults:
  run:
    "shell": bash {0}
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash '"${SUITE_PATH}"'
          echo done'

# grouping を開いた断片そのものに呼び出しが載る形（`(` と呼び出しが同じ断片）
assert_not_wired "grouping を開いた断片の呼び出しにも閉じ側の区切りが掛かる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: ( bash ${SUITE_PATH}; ) || true"

# 部分シェルの中の set は外へ漏れない（ブレースグループは漏れる）
assert_swallowed "部分シェルの中の set -e は外の set +e を打ち消さない" "name: ci
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
assert_swallowed "set +o errexit も握り潰しとして効く" "name: ci
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

# --- 失敗が `run:` の終了状態へ届くか（issue #191 / #168 / #175 / #178 / #189 の残り）---
#
# `run:` の終了状態は**最後に走ったコマンドの状態**で、errexit はその手前で落とす仕組み。
# したがって失敗がジョブへ届く道は 2 つしかない: **(a) その場で落ちる**、
# **(b) 囲っている階層の最後の状態として外へ出続ける**。位置（階層の最後かどうか）が
# 効くのは (b) のときだけで、(a) は位置を問わず届く。
#
# 実 `bash -e` で測った要点（どれも推測ではなく実測）:
#   * 複合コマンドを AND-OR の左辺に置くと、その**中まで** errexit が免除される
#     （`( false; echo z ) && echo ok` は `z` を印字して 0 で終わる）。
#   * 免除は**同じシェルの中では外へ出ても続く**（`{ bash <スイート> && echo ok ; }` ＋
#     `echo done` は NOGATE）が、**部分シェルを出ると消える**（`( … )` ＋ `echo done` は
#     GATES。終了状態として親に渡り、そこで errexit が改めて落とす）。
#   * `||` の右辺が成功しえない（`false` / `exit 1` / 中が `exit 1` で終わる複合）なら
#     並びはいつでも失敗し、その右辺は並びの**最後の要素**なので位置を問わず届く。
#   * `&&` の左辺が落ちると右のパイプラインは**走らない**ので、`pipefail` は関係ない。

assert_wired "|| の右辺が exit なら並びはいつでも失敗する" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || exit 1"

assert_wired "|| の右辺が複合でも中が exit で終われば失敗する" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || { echo fail; exit 1; }"

assert_wired "|| の右辺が false なら並びはいつでも失敗する" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || false"

assert_not_wired "|| の右辺が成功しうるなら握り潰される" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || echo oops"

assert_wired "成功しえない並びは最後でなくても届く（|| false のあとに行がある）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && echo ok || false
          echo tail"

assert_wired "成功しえない並びは最後でなくても届く（|| exit 1 のあとに行がある）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && echo ok || exit 1
          echo tail"

assert_not_wired "ブレースの最後のコマンドでなければ && の外へ出ない（複数行）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          {
          bash ${SUITE_PATH}
          echo inner
          } && echo ok"

assert_not_wired "部分シェルの最後のコマンドでなければ外へ出ない（複数行）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          (
          bash ${SUITE_PATH} && echo ok
          echo inner
          )"

assert_not_wired "後置の && は部分シェルの最後のコマンドで測る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( bash ${SUITE_PATH}; echo z ) && echo ok"

assert_not_wired "後置の && はブレースの最後のコマンドで測る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { bash ${SUITE_PATH}; echo z; } && echo ok"

assert_not_wired "部分シェルの中の && 連鎖は部分シェルの最後で測る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( bash ${SUITE_PATH} && echo ok; echo z )"

assert_wired "部分シェルの最後の && 連鎖なら外へ出る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( bash ${SUITE_PATH} && echo ok )"

assert_wired "ブレースの最後の && 連鎖なら外へ出る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { bash ${SUITE_PATH} && echo ok; }"

assert_wired "set +e の下でもステップ最後なら終了状態になる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set +e
          bash ${SUITE_PATH}"

assert_not_wired "免除は同じシェルの中では外へ出ても続く（ブレース）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { bash ${SUITE_PATH} && echo ok ; }
          echo done"

assert_not_wired "免除は同じシェルの中では外へ出ても続く（if の本体）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then bash ${SUITE_PATH} && echo ok ; fi
          echo done"

assert_wired "免除は部分シェルを出ると消える（終了状態として親が見る）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( bash ${SUITE_PATH} && echo ok )
          echo done"

assert_wired "部分シェルの中の set +e は親の errexit を弱めない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( set +e; bash ${SUITE_PATH} )
          echo done"

assert_wired "部分シェルの中で errexit がその場で落とすなら位置は問わない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( bash ${SUITE_PATH}; echo z )"

assert_not_wired "pipefail が無ければ部分シェルの失敗はパイプで捨てられる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( bash ${SUITE_PATH}; echo z ) | cat"

assert_wired "&& の右辺のパイプラインは走らないので pipefail は関係ない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && echo ok | cat"

assert_not_wired "&& の右辺がパイプラインでも後ろに行があれば届かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && echo ok | cat
          echo tail"

assert_not_wired "入れ子の部分シェルは親から見れば 1 つのコマンド" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          (
          set +e
          bash ${SUITE_PATH}
          (
          echo x )
          )"

assert_wired "同じ深さに並ぶ兄弟の部分シェルは別の階層として数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( bash ${SUITE_PATH} )
          ( echo z )"

# **1 断片に収めたブレースは「閉じていない階層」に見える**（閉じ語の走査は `depth > 0` で
# 回るので、開いたのと同じ断片の `}` には届かない）。本当に閉じていない綴り
# （`{ {` ＝ bash の構文エラーでスイートが 1 件も走らない）と区別できないので、
# **errexit がその場で落とす道だけ認める**。下の 2 件がその両側で、どちらも `main` と同じ答え
assert_wired "1 断片で閉じたブレースの中の呼び出し（errexit が落とす）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { ( bash ${SUITE_PATH} ) }"

assert_wired "閉じない階層でも errexit を戻してあれば届く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { { ( set +e
          set -e
          bash ${SUITE_PATH}
          echo done ) } }"

# 下の 5 件は**機構ごとに 1 つずつ**対応する（変異で潰すと必ずどれかが落ちる）。
# 深さではなく階層ごとの連番で数えること／部分シェルを出たら外の errexit を見ること／
# 免除は親からも継ぐこと／`&&` の右辺の複合は閉じた位置まで飛ぶこと、の 4 つ
assert_wired "兄弟の部分シェルは深さが同じでも別の階層（複数行）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          (
          bash ${SUITE_PATH}
          )
          (
          echo z
          )"

assert_wired "兄弟の部分シェルは && 連鎖の位置でも混ざらない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          (
          bash ${SUITE_PATH} && echo ok
          )
          (
          echo z
          )"

assert_wired "&& の右辺の複合は外側の階層が閉じる位置で測る" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && ( {
          echo x
          }
          echo y
          )"

assert_wired "部分シェルを出たら外の errexit で判定する" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( set +e
          echo z
          bash ${SUITE_PATH}
          )
          echo done"

assert_not_wired "免除は親の階層からも継ぐ（入れ子のブレース）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { { bash ${SUITE_PATH}; echo z; } ; } && echo ok"

assert_not_wired "&& の右辺が複合なら閉じた位置で位置を測る（後ろに行がある）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && ( {
          echo x
          } )
          echo tail"

assert_wired "&& の右辺が複合でもそれがステップ最後なら届く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && ( {
          echo x
          } )"

# **ここから下はレビュー指摘で見つけた 3 つの穴**（どれも実 `bash -e` と突き合わせて実測）。
# (1) 走らない記録を「最後に走ったコマンド」に数えると、`||` の右辺の到達不能な `exit 1` を
#     「成功しえない右辺」と読んで握り潰しを配線と答える（fail-open）。
# (2) 1 断片で入れ子をまとめて閉じたとき、内側の階層にも断片の区切りを付けると、歩きが
#     内側を出た時点で `&&` を拾って「吸われた」と判断し、まだ部分シェルを出ていないのに
#     位置の判定を省く（fail-closed）。
# (3) `||` の右辺が複合のとき「最後のコマンドが成功しえない」だけでは足りない——手前に
#     成功して抜ける脱出（`exit 0`）があれば並びは成功する（fail-open）。

assert_swallowed "|| の右辺の通らない exit は最後のコマンドではない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          if false; then
          exit 1
          fi
          )"

assert_swallowed "|| の右辺の通らない exit（グループ）も数えない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || {
          if false; then
          exit 1
          fi
          }"

assert_swallowed "|| の右辺が通らない exit で終わるなら握り潰し" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          echo x
          if false; then
          exit 1
          fi
          )"

assert_wired "|| の右辺の通る exit は成功しえないので届く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          if true; then
          exit 1
          fi
          )"

assert_swallowed "|| の右辺は手前の exit 0 で成功しうる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          exit 0
          exit 1
          )"

assert_swallowed "|| の右辺の exit 0 は 1 行書きでも成功しうる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || ( exit 0; exit 1 )"

assert_swallowed "|| の右辺のグループの exit 0 も部分シェルを抜ける" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || {
          exit 0
          exit 1
          }"

assert_swallowed "|| の右辺の中のグループの exit 0 も外側を抜ける" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          { exit 0; }
          exit 1
          )"

assert_swallowed "|| の右辺のアームの通る exit 0 でも成功しうる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          if true; then
          exit 0
          fi
          exit 1
          )"

assert_wired "|| の右辺の引数なしの exit は成功しうるが最後なら届く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          exit
          exit 1
          )"

assert_wired "|| の右辺の手前の exit が非 0 なら並びは失敗する" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          exit 2
          exit 1
          )"

assert_wired "|| の右辺の手前が普通のコマンドなら最後の exit で失敗する" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          echo x
          exit 1
          )"

assert_wired "|| の右辺の定義しただけの本文の exit 0 は抜けない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          f() { exit 0; }
          exit 1
          )"

assert_wired "入れ子をまとめて閉じた部分シェルは && の左辺でも届く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( { bash ${SUITE_PATH} ; } ) && echo ok"

assert_wired "入れ子をまとめて閉じたアームも && の左辺で届く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( if true; then bash ${SUITE_PATH}; fi ) && echo ok"

assert_wired "部分シェルを二重に閉じた断片も && の左辺で届く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( ( bash ${SUITE_PATH} ; ) ) && echo ok"

assert_wired "部分シェルとグループを混ぜて閉じた断片も届く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( ( { bash ${SUITE_PATH} ; } ) ) && echo ok"

assert_wired "入れ子をまとめて閉じた部分シェルは pipefail のパイプでも届く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -o pipefail
          ( { bash ${SUITE_PATH} ; } ) | cat"

assert_swallowed "入れ子をまとめて閉じても後ろにコマンドがあれば握り潰し" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( { bash ${SUITE_PATH} ; } ) && echo ok"

# **引数が読めない脱出（素の `exit` / `exit $rc`）は手前のコマンド次第**（レビュー指摘）。
# `||` の右辺が走るのは左辺が落ちたときだけなので、手前に何も走っていなければ
# 直前の状態＝左辺の失敗を引き継いで必ず非 0 で抜ける（＝並びはいつでも失敗する）。
# 手前に走ったコマンドがあればその状態は読めないので握り潰し側へ倒す
assert_swallowed "|| の右辺の手前にコマンドがあると素の exit は成功しうる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          echo cleanup
          exit
          )"

assert_swallowed "|| の右辺のグループでも手前のコマンド次第" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || {
          echo cleanup
          exit
          }"

assert_swallowed "|| の右辺の手前にコマンドがある 1 行書きも同じ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || ( echo cleanup; exit )"

assert_swallowed "|| の右辺の読めない引数の exit も手前次第" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          echo x
          exit \$u
          )"

assert_swallowed "|| の右辺の入れ子の部分シェルも手前のコマンドに数える" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          (
          echo x
          )
          exit
          )"

assert_wired "|| の右辺の先頭の素の exit は左辺の失敗を引き継ぐ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          exit
          exit 1
          )"

assert_wired "|| の右辺の先頭の読めない引数の exit も同じ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          exit \$u
          exit 1
          )"

assert_wired "開くだけの断片は手前のコマンドに数えない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          {
          exit
          }
          )"

assert_wired "|| の右辺の入れ子の部分シェルの exit 0 は外側を抜けない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          (
          exit 0
          )
          exit 1
          )
          echo done"

assert_wired "|| の右辺の通らないアームの exit 0 は印を付けない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          if false; then
          exit 0
          fi
          exit 1
          )
          echo done"

# **閉じていない複合の右辺は読めないので握り潰し側へ倒す。** 閉じ語の無い綴り
# （bash の構文エラーでスイートは 1 行も走らない）で連鎖の歩きを進めると、閉じた位置が
# 読めないまま外へ出て「失敗が伝わる」と答える（真値 NOGATE なのに wired ＝fail-open。実測）
assert_not_wired "閉じていないグループを && の右辺に置いた形は配線と読まない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} && {
          echo x"

assert_not_wired "閉じていない部分シェルを || の右辺に置いた形も配線と読まない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          exit 1"

# **連鎖の右辺はステップをまたがない。** `run:` はステップごとに別のシェルで走るので、
# 末尾に区切りだけが残った綴り（bash の構文エラーでスイートは 1 行も走らない）の
# 右辺を次のステップの先頭から拾ってはいけない（真値 NOGATE。拾うと「成功しえない右辺」と
# 読んで wired ＝fail-open になる。実測で `main` も not-wired）
assert_not_wired "連鎖の右辺を次のステップから拾わない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} &&
      - name: next
        run: |
          exit 1"

# **残る境界（fail-closed・`main` と同じ答え）**: `||` の右辺の中で**部分シェルに包んだ**
# `exit 0` を 1 行で書く綴り（`( ( exit 0 ); exit 1 )`）は、包んだ部分シェルが同じ断片で
# 開いて閉じるため記録が**外側の階層**に載り、「外側を抜ける脱出」と読んで握り潰し側へ倒れる
# （真値 GATES・`main` も not-wired）。包みを見分けるには断片の中の括弧の対応を
# 読む必要があり、綴りを数える近似を増やすより安全側に倒すほうを採った
assert_swallowed "包んだ exit 0 は安全側に倒す（残る境界）" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          bash ${SUITE_PATH} || (
          ( exit 0 )
          exit 1
          )"


# --- 複合コマンドがパイプの左側になる形（issue #191 のレビュー指摘）-------------------
#
# **閉じた後ろが `|` なら、その複合はパイプの左側＝子シェルで走る。** 2 点が効く:
# (a) 中の `&&` が与えた errexit の免除は子シェルを出た時点で消える、(b) パイプラインの
# 状態を決めるのは**親の** `pipefail` なので、複合の中で `set -o pipefail` しても届かない。
# どちらが欠けても「スイートの失敗が伝わる」と答える fail-open になる（真値 NOGATE なのに
# wired。実測で `main` はすべて未配線）。**必須スイートが黙ってゲートしなくなる向き**なので、
# ここは綴りの数だけピンを置く

assert_not_wired "グループをパイプの左側に置くと失敗は捨てられる" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { bash ${SUITE_PATH} && echo ok ; } | tee log"

assert_not_wired "リダイレクトを挟んだパイプでも同じ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { bash ${SUITE_PATH} && echo ok ; } 2>&1 | tee log"

assert_not_wired "|& で繋いだパイプでも同じ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { bash ${SUITE_PATH} && echo ok ; } |& cat"

assert_not_wired "制御構造の本体をパイプの左側に置いた形も同じ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          if true; then bash ${SUITE_PATH} && echo ok; fi | cat"

assert_not_wired "入れ子のグループを経てパイプの左側に出る形も同じ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { { bash ${SUITE_PATH} && echo ok ; } && echo o2 ; } | cat"

assert_not_wired "パイプラインの後ろに && が続く形も同じ" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { bash ${SUITE_PATH} && echo ok ; } | cat && echo z"

# **`set -o pipefail` を複合の中で書いても親のパイプラインには効かない。** 素のグループは
# 同じシェルで走るので中の `set` は親へ残るが、**パイプの左側になったときだけは子シェルで
# 走る**ので残らない（実 `bash -e` で NOGATE）。**いまこの答えを支えているのは
# 「複合の中の `set -o pipefail` を記録へ反映しない」という別の未修正（issue #203）**で、
# それを直したときは閉じた断片の巻き戻し（区切りが `|` / `&` なら階層の入口の値へ戻す）が
# この形を守る——どちらも消すとこのピンが落ちる（実測で巻き戻しだけを外しても落ちない）
assert_not_wired "複合の中の set -o pipefail は親のパイプに効かない" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { set -o pipefail; bash ${SUITE_PATH} && echo ok ; } | cat"

# 対照（締めすぎない側）: `pipefail` が**複合の外**で立っていれば失敗は伝わる
assert_wired "複合の手前の set -o pipefail はパイプに効く" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          set -o pipefail
          { bash ${SUITE_PATH} && echo ok ; } | cat"

# 対照: 部分シェル・素の呼び出しだけのグループも同じく捨てられる（向きの確認）
assert_not_wired "部分シェルをパイプの左側に置いた形" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( bash ${SUITE_PATH} && echo ok ) | cat"

assert_not_wired "呼び出しだけのグループをパイプの左側に置いた形" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          { bash ${SUITE_PATH} ; } | cat"

# **閉じ括弧に付いた区切りは「複合全体」のもので、中の並びのものではない**（同じ指摘）。
# 1 断片で「階層の最後のコマンド」と「その階層を閉じる」が重なる綴りで、後ろの `&&` を
# 中の並びの区切りとして読むと「右辺は外側の複合」に見えて読めず、未配線へ倒れていた
# （真値 GATES・`main` も wired ＝**正しくゲートしている綴りを赤くする**向き。実測）
assert_wired "部分シェルの中の && 連鎖が最後で、後ろに && が続く形" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( bash ${SUITE_PATH} && echo ok ) && echo ok"

assert_wired "部分シェルの中の set +e の下でスイートが最後で、後ろに && が続く形" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - name: subject
        run: |
          ( set +e; bash ${SUITE_PATH} ) && echo ok"


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

# --- 1 行が「ブロックスカラーを開く」と「引用を開いたまま終わる」を同時に満たす形（issue #119） ---
#
# 続きの行かどうかの印（`open_type`）は**その行に入る前**の状態しか見ないので、
# `- run: "|` のように両方を満たす行では `in_scalar` と `open_type` が同時に立つ。
# すると次の行（＝**閉じ引用符を載せた行**）が本文として `next` で読み飛ばされ、
# 引用が**永久に閉じない**。**いったんラッチすると同じファイル内に回復経路が無い**のがこの形の
# 厄介さで、以降そのファイル全体で伏せ処理とブロックスカラー判定の両方が死ぬ。
# 壊れ方は両向き:
#   - 伏せ処理が死ぬ → 引用の中の `#` が行を切って本物の `secrets:` が落ちる（**fail-open**。
#     特権ワークフローが read-only に化けて FR-9.6(b) のピン検査をすり抜ける）
#   - ブロックスカラー判定が死ぬ → 後続の `run: |` の本文が構造行として漏れ、実在するスイートが
#     「未配線」になる（**fail-closed**。実測で `main` は `NOT-WIRED`）
# 塞ぎ方は「その行を出ていく時点で引用が閉じていること」を開始条件へ足すこと。
# 2 形（`run: "|` と `"run: |`）を**両方**置く——前者はブロックスカラーの綴りが引用の*外*、
# 後者は*中*にあり、通る経路が違う（後者は `main` では抽出そのものが失敗した）
assert_wired "ブロックスカラーと引用を同時に開く行の後ろでも run: | は読める" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - run: \"|
          a\"
      - name: suites
        run: |
          bash ${SUITE_PATH}"

assert_wired "引用の中に run: | と書いた手順の後ろでも run: | は読める" "name: ci
jobs:
  type-check:
    runs-on: ubuntu-latest
    steps:
      - \"run: |
          note\"
      - name: suites
        run: |
          bash ${SUITE_PATH}"

# **締めすぎない側**: 引用を開いていない素の `run: |` は今までどおり本文を読み飛ばすこと
# （`open_type == \"\"` を足した条件が、正当なブロックスカラーまで止めていないこと）。
# 本文に書いた `uses:` が構造行へ漏れないことで観測する
assert_structural_line "引用を開いていない run: | の本文は今までどおり読み飛ばす" \
    '' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          uses: actions/evil@v1
      - uses: ./other' 7

# 同じ入力で本文の後ろの行は出ること（上の空文字が「走査が止まった」の裏返しにならないよう）
assert_structural_line "引用を開いていない run: | の後続の構造行は出る" \
    '      - uses: ./other' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          uses: actions/evil@v1
      - uses: ./other' 8

# **穴の側の出力も固定する**（レビューで実測）。`run: "|` はブロックスカラーの開始と
# 読まないので、続きの行（閉じ引用符を載せた行）は**本文として落ちず構造行として出る**。
# 向きは「余分に出す」側で、ピン検査には実在しない手順への参照（幻の `uses:`）を渡すことに
# なるが、**取りこぼす側（本物の `secrets:` を捨てる fail-open）よりこちらを取る**という
# 既知の残り（`KNOWN RESIDUAL: 複数行にまたがる引用スカラーは幻を残す`）どおりの挙動。
# 引用符そのものは伏せ処理が落とすので、期待値に閉じ引用符は現れない（実測）。
# 固定しておかないと、どちらの向きへ動いてもテストが何も言わない
assert_structural_line "引用の中のブロックスカラー記号の続きの行は構造行として出る" \
    '          uses: actions/evil@v1' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: "|
          uses: actions/evil@v1"
      - uses: ./other' 7

# 同じ入力で後続の構造行も出ること（ラッチが戻っていることを別の行で押さえる）
assert_structural_line "引用の中のブロックスカラー記号の後ろでも構造行は出る" \
    '      - uses: ./other' \
    'name: ci
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: "|
          uses: actions/evil@v1"
      - uses: ./other' 8

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
      - {name: !<a'"'"'b> x, uses: ./local}
      - {name: &anchor "h, i", uses: ./local}
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

# --- 階層ごとの状態がステップをまたいで残らないこと（issue #121）---------------------
#
# なぜここを直接押さえるのか: ステップは 1 つずつ別のシェルで走るので、前のステップが
# 閉じ忘れた `{` や関数定義は次のステップに何の影響も与えない。解析器の側では
# `flush_step()` の**引数（awk の局所変数）**として階層ごとの配列を持つことでそれを表して
# いるが、これは**綴りの上では読み取れない取り決め**で、引数の一覧から 1 つ落ちただけで
# グローバルに昇格し、前のステップの印が次のステップで読まれる。
#
# issue #121 が挙げていたもう 1 つの案（閉じる処理を関数へ出す）は、awk が複数のスカラーを
# 返せないため**まさにこの昇格を要求する**。写しを 1 つにする側の案を採ったが、将来また
# 昇格の誘惑が出るので、昇格した瞬間に落ちる形をここに置く。
#
# 向きは両方ある（いずれも変異で実測）:
#   - 握り潰しを「ゲートしている」と読む fail-open（前のステップの「走るか分からない」印が
#     残り、`set -e` の効かない位置での再強化が効いたことになる）
#   - 正しくゲートしている綴りを赤くする fail-closed（前のステップの印の分だけ
#     余計に数が戻り、最上位の呼び出しが「走るか分からない」側に数えられる）
#
# **控え（前のステップが何も残さない形）と対で置く**のが要点。控えが無いと、判定が
# たまたま期待値と同じになっただけの状態と見分けが付かない。

# 前のステップが閉じない関数定義と `if` を残す形（深さ 2 ぶんの印が残る）
LEAKY_STEP='      - name: leaky
        run: |
          f() { if [ -z "x" ]; then'

# 何も残さない控えのステップ（同じ本文に対する「正しい答え」を示す）
CLEAN_STEP='      - name: clean
        run: |
          echo clean'

# 2 ステップのワークフローを組み立てる。第 1 引数が前のステップ、第 2 引数が本文
two_step_workflow() {
    printf 'name: ci\njobs:\n  type-check:\n    runs-on: ubuntu-latest\n    steps:\n%s\n      - name: subject\n        run: |\n%s\n' \
        "$1" "$2"
}

# 最上位で呼ぶ本文（控えでは配線として読まれる）。
# ブレースのグループを先に開いて閉じるので、閉じ側の処理が階層ごとの印を読む
TOPLEVEL_BODY='          { : ; }
          bash '"${SUITE_PATH}"

# 条件が読めない `if` の中で呼ぶ本文（控えでは「走るか分からない」側）
UNCERTAIN_BODY='          if [ -z "x" ]; then
          { : ; }
          bash '"${SUITE_PATH}"'
          fi'

assert_wired "控え: 最上位の呼び出しは配線として読まれる" \
    "$(two_step_workflow "${CLEAN_STEP}" "${TOPLEVEL_BODY}")"

assert_wired "前のステップが閉じない関数定義を残しても最上位の呼び出しは配線のまま" \
    "$(two_step_workflow "${LEAKY_STEP}" "${TOPLEVEL_BODY}")"

assert_not_wired "控え: 条件が読めない if の中の呼び出しは配線として読まれない" \
    "$(two_step_workflow "${CLEAN_STEP}" "${UNCERTAIN_BODY}")"

assert_not_wired "前のステップが閉じない関数定義を残しても if の中は配線にならない" \
    "$(two_step_workflow "${LEAKY_STEP}" "${UNCERTAIN_BODY}")"

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

# **awk へ `-v` で渡す綴りにバックスラッシュを含めない。**
# `-v` の値は**逃がし列として解釈される**ので、`\{` のような綴りは実装ごとに扱いが違う——
# `gawk` は「escape sequence `\{' treated as plain `{'」を**呼び出しごとに stderr へ出し**、
# awk の出力を比較している上の検査がその警告で落ちる。`mawk` は黙って受けるので
# **手元では通り CI だけが赤くなる**（実測。CI は gawk・この開発環境は mawk で、
# issue #150 の対応中に実際に踏んだ）。括り（`[{]`）で書けばどちらでも同じに読める。
# **対象はライブラリのソースから導く**（一覧を書くと、次に足した `-v` が黙って外れる）
awk_v_backslash_case() {
    # `-v <小文字の名前>="${CI_WORKFLOW_…}"` の形から、渡している定数の名前を集める。
    # **ライブラリだけでなくスイート側も見る**——`action_pin_test.sh` のように
    # テストから直接 awk へ渡す箇所もあり、そこだけに渡される定数は片方だけの走査から外れる
    local -a passed_vars=()
    mapfile -t passed_vars < <(grep -ohE -- '-v [a-z_]+="\$\{CI_WORKFLOW_[A-Z_]+\}"' \
        "${SCRIPT_DIR}/lib/ci_workflow.sh" "${SCRIPT_DIR}"/*_test.sh \
        | grep -oE 'CI_WORKFLOW_[A-Z_]+' | sort -u)
    # 1 つも拾えなければ検出網が死んでいる（渡し方の綴りが変わった）ので落とす（fail-closed）
    if [ "${#passed_vars[@]}" -eq 0 ]; then
        report_fail "awk へ渡す綴りにバックスラッシュを含めない" \
            "-v で渡している定数を 1 つも拾えませんでした（渡し方の綴りが変わった可能性）"
        return
    fi
    # 拾った定数の値を 1 つずつ見て、バックスラッシュを含むものを名指しする
    local var offenders=""
    for var in "${passed_vars[@]}"; do
        case "${!var-}" in
            *\\*) offenders="${offenders}${offenders:+, }${var}" ;;
        esac
    done
    if [ -z "${offenders}" ]; then
        report 0 "awk へ渡す綴りにバックスラッシュを含めない（${#passed_vars[@]} 件）"
    else
        report_fail "awk へ渡す綴りにバックスラッシュを含めない" \
            "逃がし列として解釈される値があります（${offenders}）。括り（例: [{]）で書き直してください"
    fi
}
awk_v_backslash_case

# **ケースの一覧のラベルにコロンを含めない。** この近くの検査は `"ラベル:本文"` という
# 1 つの文字列を `${case%%:*}` と `${case#*:}` で割るので、**ラベル側にコロンが入ると
# 本文の先頭にラベルの残りが混ざる**。混ざった本文は bash の綴りとして成り立たない語に
# なるため呼び出しが見つからず、`assert_not_wired` のケースは**何も見張らないまま緑**で
# 通る（実測。`"|| : が後ろ:bash <スイート> …"` が本文 ` が後ろ:bash …` に化けて、
# 仕掛けを壊す変異でも落ちなかった）。**本文が日本語で始まることを印として落とす**
# ——正しい本文はコマンド（ASCII）で始まる。
# **対象はこのファイル自身のソースから導く**（一覧を書くと次に足したループが黙って外れる）
case_label_colon_case() {
    local out
    # `for <名前> in \` から `do` までを一覧の本体とみなし、`"` で始まる行を 1 ケースとして読む。
    # **近似**: 本文が複数行のケースは 1 行目（ラベルを含む行）だけを見る。本文の中に
    # 桁 0 の `do` があるとその一覧を早く閉じるが、倒れる向きは「見る数が減る」側
    out="$(awk '
        /^for [A-Za-z_]+ in \\$/ { inlist = 1; next }
        inlist && /^do$/ { inlist = 0; next }
        inlist && /^    "/ {
            seen++
            entry = substr($0, index($0, "\"") + 1)
            colon = index(entry, ":")
            if (colon == 0) { next }
            body = substr(entry, colon + 1)
            sub(/^[[:space:]]+/, "", body)
            first = substr(body, 1, 1)
            if (first != "" && first !~ /^[ -~]$/) { bad = bad "\n  " NR ": " substr(entry, 1, colon - 1) }
        }
        END { print seen bad }
    ' "${BASH_SOURCE[0]}")"
    local seen="${out%%$'\n'*}"
    local offenders="${out#"${seen}"}"
    # 1 件も拾えなければ検出網が死んでいる（一覧の書き方が変わった）ので落とす（fail-closed）
    if [ -z "${seen}" ] || [ "${seen}" -eq 0 ] 2>/dev/null; then
        report_fail "ケースの一覧のラベルにコロンを含めない" \
            "ケースを 1 つも拾えませんでした（一覧の書き方が変わった可能性）"
        return
    fi
    if [ -z "${offenders}" ]; then
        report 0 "ケースの一覧のラベルにコロンを含めない（${seen} 件）"
    else
        report_fail "ケースの一覧のラベルにコロンを含めない" \
            "ラベルにコロンを含むケース（本文の先頭にラベルの残りが混ざります）:${offenders}"
    fi
}
case_label_colon_case

# 集計を出して、失敗が 1 件でもあれば非ゼロで終わる
harness_summary
