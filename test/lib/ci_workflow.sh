#!/usr/bin/env bash
# ci_workflow.sh - read what .github/workflows/ci.yml actually *executes*, so
# several suites can assert wiring the same way instead of each inventing it.
#
# Why this is a library rather than a helper inside one suite: three places now
# need to ask "does ci.yml really run X?" -- test/ci_coverage_test.sh (every
# suite is wired), test/action_pin_test.sh (the coverage step itself is still
# wired), and test/sec18_denylist_test.sh (the e2e script is wired). Written out
# three times they drifted immediately: two of the copies were plain line
# searches that a trailing comment or a `name:` mention satisfied, so a disabled
# step read as wired -- the "absence == pass" shape those very assertions exist
# to prevent (found in review, twice, after the strong version already existed).
# CLAUDE.md §6 asks for extraction at the second or third occurrence; this is it.
#
# What "executes" means here, and why each part is needed:
#
#   * Only the values of `run:` keys count. Searching raw lines lets
#     `run: echo skipped  # bash test/foo_test.sh` and
#     `- name: TODO re-enable bash test/foo_test.sh` pass as wiring.
#   * Comments are stripped from those values, so an inline `#` inside a
#     `run: |` block cannot smuggle a match either.
#   * A step carrying `if: false` or `continue-on-error: true` is dropped. The
#     first never runs; the second runs but cannot fail the job, so neither
#     gates anything -- and disabling a step that way is one added line rather
#     than a deletion, which makes it the easier mistake to miss.
#   * Both a per-line and a per-step view are published. `shellcheck $SHELL_FILES`
#     has to be true of one command; `bash -n "$f"` and `for f in $SHELL_FILES`
#     are two lines of one step and only make sense together.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/ci_workflow.sh"
#   ci_workflow_load "<path to ci.yml>" "<scratch file>"   # returns non-zero on failure;
#                                          the caller decides whether to bail
#   ci_workflow_line_matches  <regex>...  # one command line matches all of them
#   ci_workflow_step_matches  <regex>...  # one step matches all, across its lines
#   ci_workflow_runs_script   <path>      # that step invokes the given script
#   ci_workflow_regex_escape  <string>    # literal text -> safe ERE fragment

# 抽出した「実行されるコマンド」を保持するファイル。1 行が `<ステップ番号><TAB><コマンド行>`
CI_WORKFLOW_COMMANDS=""

# 文字列を拡張正規表現のリテラルとして扱えるようにエスケープする
# （パス中の `.` が任意の 1 文字として働くと、別名のファイルに当たってしまう）
ci_workflow_regex_escape() {
    # 英数字・`_`・`-`・`/` 以外の文字の前にバックスラッシュを置く
    printf '%s' "$1" | sed 's|[^[:alnum:]_/-]|\\&|g'
}

# ワークフローから「YAML の構造として意味を持つ行」だけを `行番号:行の内容` の形で書き出す関数
# 第 1 引数: ワークフローファイルのパス
#
# 何を落とすか: ブロックスカラー（`run: |` / `prompt: >-` 等）の本文。あれは YAML の構造ではなく
# ただの文字列なので、そこに書かれた `permissions:` や `uses:` を宣言と読み違えてはいけない。
# スカラーを開始する行そのもの（`run: |`）は構造なので残す。
#
# なぜ 1 か所に集約するか: 特権判定と `uses:` 抽出の**両方**がこの前提を必要とするのに、
# 片方だけに読み飛ばしを入れると非対称な誤りが出る。実際、判定側だけに入れた段階では
# `run:` の本文に書かれた `- uses: …@v7` が違反として誤報され、正しくピンされている
# `post-ci-verify.yml`（`prompt:` に長いブロックスカラーを持つ）で CI が恒常的に赤くなりえた。
# 出力形式を `grep -n` と同じ `行番号:内容` に揃えてあるので、消費側は行番号を保ったまま使える
emit_structural_lines() {
    # 検査対象のファイルパスを変数に入れる
    local path="$1"

    # 引用符の文字集合は awk の変数として渡す（awk のプログラムはシェルの単一引用符で囲まれており、
    # その中に `'` を直接書けないため）
    awk -v quote_chars='["'"'"']' '
        # ブロックスカラーの本文の中かどうかと、その開始行の字下げ幅を覚える
        BEGIN { in_scalar = 0; scalar_indent = 0 }
        {
            # 判定に使う 1 行分の文字列を作業用の変数へ取り出す
            line = $0
            # Windows 改行（CR）が混じっていても末尾の空白判定が狂わないよう取り除く
            sub(/\r$/, "", line)
            # 空行は構造を持たないので、状態を変えずに読み飛ばす
            if (line ~ /^[[:space:]]*$/) next

            # 最初に現れる非空白文字の位置から、その行の字下げ幅を求める
            indent = match(line, /[^[:space:]]/) - 1

            # ブロックスカラーの本文は、字下げが浅くなるまで丸ごと読み飛ばす
            if (in_scalar) {
                if (indent > scalar_indent) next
                in_scalar = 0
            }

            # 引用符を落として `"uses":` と `uses:` を同じ形に揃えてから書き出す。
            # ここで揃えておけば、消費側それぞれが引用の有無を数え上げずに済む
            emitted = line
            gsub(quote_chars, "", emitted)
            # ここまで残った行は構造なので、行番号を付けて書き出す
            print NR ":" emitted

            # スカラー開始かどうかは、コメント・大文字小文字を揃えた写しで判定する
            probe = emitted
            sub(/[[:space:]]*#.*$/, "", probe)
            probe = tolower(probe)
            # `run: |` や `prompt: >-` のような行なら、次の行から本文として読み飛ばす
            if (probe ~ /^[[:space:]]*(-[[:space:]]+)?[a-z_][a-z0-9_.-]*[[:space:]]*:[[:space:]]*[|>][0-9]*[+-]?[[:space:]]*$/) {
                in_scalar = 1
                # 本文の範囲は**鍵の桁**で決める。ダッシュの桁で決めると、
                # `- if: >-` の本文だけでなく**同じ手順の兄弟キー**（次行の `uses:` 等）まで
                # 飲み込んでしまい、可変タグが検査対象から丸ごと外れる（実測）
                if (match(probe, /^[[:space:]]*-[[:space:]]+/)) {
                    # `- ` を含む前置きの長さが、そのまま鍵の桁になる
                    scalar_indent = RLENGTH
                } else {
                    scalar_indent = indent
                }
            }
        }
    ' "$path"
}
# 構造行の表を用意したうえで、渡した awk プログラムをワークフローに対して実行する。
# 第 1 引数がワークフロー、第 2 引数が一時ファイルの土台、第 3 引数が awk プログラム本体。
#
# **表の読み込みと後始末をここだけに持つ**のが要点。同じ 6 行の `getline` 断片と
# 「構造行を書き出す → awk → 終了コードを控える → 消す」の型を各所へ書き写すと、
# `emit_structural_lines` の出力形式を変えたときに片方だけが古くなり、
# 表が空のまま「該当なし」という**静かに誤った答え**を返す（本ライブラリを切り出した理由と同じ）。
# awk は BEGIN ブロックを複数持てるので、呼び出し側は自分の初期化を別の BEGIN に書けばよい
ci_workflow_run_with_structure() {
    # 引数を受け取る
    local workflow="$1" scratch="$2" program="$3"
    # 構造行の一覧を控えるファイル
    local structural_file="${scratch}.structural"
    # 構造行を書き出す。失敗したら以降の解析が成立しない
    emit_structural_lines "${workflow}" > "${structural_file}" || return 1
    # 構造行の表を BEGIN で読み込んでから、呼び出し側のプログラムを続ける
    awk -v structural_file="${structural_file}" '
        BEGIN {
            while ((getline entry < structural_file) > 0) {
                colon = index(entry, ":")
                if (colon > 0) { structural[substr(entry, 1, colon - 1) + 0] = 1 }
            }
            close(structural_file)
        }
    '"${program}" "${workflow}"
    # awk の終了コードを控える（後始末で上書きされないように）
    local status=$?
    # 中間ファイルを片付ける（失敗しても終了コードは変えない）
    rm -f "${structural_file}" || true
    # awk の結果をそのまま返す
    return "${status}"
}

# ci.yml を読み、実行される `run:` の中身をステップ番号付きで書き出す。
# 第 1 引数がワークフローのパス、第 2 引数が出力先ファイル。
#
# **構造の判定は `emit_structural_lines` に委ねる**のが要点。ステップの区切りや `if:` の検出を
# 生の行に対して行うと、`run: |` の**本文**に書かれた `- 箇条書き` でステップを切ってしまい
# （実行されているスイートが「配線されていない」と誤報される）、本文中の `if: false` で
# ステップ全体が消える。ブロックスカラー本文を構造と読み違えない判定は上にあるので、それを使う。
#
# **ステップの区切りは字下げで決める。** 「`- ` で始まる構造行」を一律に区切りとすると、
# `with:` / `args:` の下の `- --quiet` のような**入れ子の並び**でもステップが切れる。
# そこで区切りが起きると、その手前で立てた `if: false` の印が新しい疑似ステップにリセットされ、
# **止めたはずのステップが「実行されている」と読まれる**（レビューで実測）。
# 同じ理由でジョブの境界も追う: ジョブ直下の `if:` / `continue-on-error:` はそのジョブの
# 全ステップに掛かり、また**ジョブが変わる前に直前のステップを確定させない**と、
# 次のジョブの無効化キーが前のジョブ最後のステップを取り消してしまう（同じくレビューで実測）
ci_workflow_extract() {
    # 中間ファイルの置き場は出力先とは別の名前にする（読み書きが同じファイルに見えないように）
    local scratch="$2.extract"
    # 構造行の表の用意・後始末は共有ヘルパーに任せ、ここは解析だけを書く。
    # awk のプログラムはシェルに展開させてはいけないので単一引用符で渡す
    # shellcheck disable=SC2016
    ci_workflow_run_with_structure "$1" "${scratch}" '

        # 構造行の表（structural[行番号]）は ci_workflow_run_with_structure が用意する。
        # 入れ子の深さを覚える変数は **-1（まだどこにも入っていない）で始める**必要がある。
        # awk の未初期化変数は 0 なので、初期化を落とすと `step_dash_indent` が 0 と読まれ、
        # ジョブ直下の `continue-on-error:` までステップ内のキーとして扱われ、
        # ジョブ単位の無効化が効かなくなる（この初期化を落として実測した）
        BEGIN { jobs_indent = -1; job_indent = -1; steps_indent = -1; step_dash_indent = -1 }

        # コメント部分（行頭、または空白に続く # から行末まで）を落とす
        function strip_comment(t) { sub(/(^|[[:space:]])#.*$/, "", t); return t }
        # 前後の空白を落とす
        function trim(t) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); return t }

        # 溜めた 1 ステップ分を、無効化されていなければ出力する
        function flush_step(   i) {
            # ステップ単位でもジョブ単位でも止められていなければ「実行される」と数える
            if (!step_disabled && !job_disabled) {
                for (i = 1; i <= ncmd; i++) { print step_id "\t" cmds[i] }
            }
            # 次のステップに備えて溜めた内容を捨てる
            for (i = 1; i <= ncmd; i++) { delete cmds[i] }
            ncmd = 0
            step_disabled = 0
        }

        # 無効化を表すキーかどうかを返す（コメント除去済みの行を渡すこと）。
        # **引用符と大文字小文字を先に正規化する**のが要点。YAML は引用符付きの偽を
        # 素の `if: false` と同じスカラーとして読み、GitHub Actions は `FALSE` / `False` も
        # 偽として評価する。素の綴りだけを見ると、**止めたステップが「実行されている」と読まれる**
        # ——本ライブラリが塞ぐと宣言している当の穴が、引用符 2 つで開く（レビューで実測）
        function is_disabling(t,   probe) {
            # 引用符を落とし、小文字に揃えた写しで判定する
            probe = t
            gsub(/["\047]/, "", probe)
            probe = tolower(probe)
            # **値がブロックスカラー（`if: >-` / `continue-on-error: |`）なら中身は構造行に現れない。**
            # 確かめられない以上「実行される」とは主張できないので、無効化側へ倒す（fail-closed）。
            # `action_pin_test.sh` が `permissions:` をブロックスカラーで書かれたとき特権側へ倒すのと同じ判断
            if (probe ~ /^[[:space:]]*-?[[:space:]]*(if|continue-on-error):[[:space:]]*[|>][0-9]*[+-]?[[:space:]]*$/) { return 1 }
            # `if: false` は決して実行されない（式で書かれた `${{ false }}` も同じ）
            if (probe ~ /^[[:space:]]*-?[[:space:]]*if:[[:space:]]*(false|.\{\{[[:space:]]*false[[:space:]]*\}\})[[:space:]]*$/) { return 1 }
            # `continue-on-error: true` は走るが失敗してもジョブを止めない＝ゲートにならない。
            # **式の形も同じ**（`if:` 側だけ式を見て `continue-on-error:` を見ないと、1 行でゲートが外れる）
            if (probe ~ /^[[:space:]]*-?[[:space:]]*continue-on-error:[[:space:]]*(true|.\{\{[[:space:]]*true[[:space:]]*\}\})[[:space:]]*$/) { return 1 }
            # それ以外は無効化ではない
            return 0
        }

        {
            # 判定に使う 1 行分の文字列を取り出し、CR を落とす
            line = $0
            sub(/\r$/, "", line)

            # 非構造行＝ブロックスカラーの本文。run: の本体のときだけコマンドとして拾う
            if (!structural[NR]) {
                if (in_run) {
                    text = trim(strip_comment(line))
                    if (text != "") { cmds[++ncmd] = text }
                }
                next
            }

            # 構造行が来た時点で、直前のブロックスカラー本文は終わっている
            in_run = 0
            # コメントを落としてから構造を判定する
            # （`if: false  # 理由` のように理由を添えるのが最も自然な書き方なので、
            #   コメント付きを取りこぼすと「止めたステップが動いている」ことになる）
            probe = strip_comment(line)
            # 空になった行（コメントだけの行）は構造として扱わない
            if (trim(probe) == "") { next }
            # 字下げ幅を測る（入れ子の深さの判定に使う）
            indent = match(probe, /[^[:space:]]/) - 1

            # `jobs:` の位置を覚える
            if (jobs_indent < 0 && probe ~ /^[[:space:]]*jobs:[[:space:]]*$/) { jobs_indent = indent; next }

            # ジョブ名の行（`jobs:` より深く、かつ最初に見つけた深さと同じ）が新しいジョブの始まり
            if (jobs_indent >= 0 && indent > jobs_indent && probe ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*$/ \
                && (job_indent < 0 || indent == job_indent)) {
                # **前のジョブの最後のステップをここで確定させる**（次のジョブの無効化キーを被せない）
                flush_step()
                job_indent = indent
                job_disabled = 0
                steps_indent = -1
                step_dash_indent = -1
                next
            }

            # `steps:` の位置を覚える（以降の同じ深さのダッシュがステップの区切り）
            if (job_indent >= 0 && indent > job_indent && probe ~ /^[[:space:]]*steps:[[:space:]]*$/) {
                steps_indent = indent
                step_dash_indent = -1
                next
            }

            # ステップの区切り（`steps:` の下で最初に現れたダッシュと**同じ字下げ**のダッシュ）
            if (steps_indent >= 0 && probe ~ /^[[:space:]]*-[[:space:]]/) {
                # 最初のダッシュの字下げを、このジョブのステップの基準にする
                if (step_dash_indent < 0) { step_dash_indent = indent }
                # 基準と同じ深さのときだけ新しいステップとして扱う（入れ子の並びでは切らない）
                if (indent == step_dash_indent) { flush_step(); step_id++ }
            }

            # 無効化キーの扱いは、ステップの中かジョブ直下かで宛先が変わる
            if (is_disabling(probe)) {
                # ステップの中（基準のダッシュ以上の深さ）ならそのステップだけを止める
                if (step_dash_indent >= 0 && indent >= step_dash_indent) {
                    step_disabled = 1
                } else {
                    # ジョブ直下ならそのジョブの全ステップが対象
                    job_disabled = 1
                }
                next
            }

            # ここから先は run: の取り出し。ステップの中でなければ関係ない
            if (step_dash_indent < 0) { next }

            # `run: |` / `run: >` のブロック開始。以降の非構造行が本体
            if (probe ~ /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[|>]/) { in_run = 1; next }

            # 1 行で書かれた `run: <command>`
            if (probe ~ /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[^|>[:space:]]/) {
                text = probe
                sub(/^[[:space:]]*-?[[:space:]]*run:[[:space:]]*/, "", text)
                text = trim(text)
                # **値全体を囲む引用符は落とす。** `run: "bash test/x_test.sh"` は正当な YAML で
                # 中身は同じコマンドだが、引用符が先頭に残るとコマンドの開始位置の判定に外れ、
                # 実行しているのに「どこからも呼ばれていない」と赤くなる（レビューで実測）
                if (text ~ /^".*"$/ || text ~ /^\047.*\047$/) { text = substr(text, 2, length(text) - 2) }
                text = trim(text)
                if (text != "") { cmds[++ncmd] = text }
            }
        }
        # 最後のステップを取りこぼさない
        END { flush_step() }
    ' > "$2"
}

# ワークフローを読み込んで以降の照会に備える。第 1 引数がワークフロー、第 2 引数が一時ファイル。
# 失敗したら非ゼロを返す（呼び出し側が bail などで止める）
ci_workflow_load() {
    # 抽出して終了コードを確かめる（プロセス置換だと awk の失敗を誰も見ない）
    ci_workflow_extract "$1" "$2" || return 1
    # 1 件も取れなければ YAML の書式が変わって読めていない
    [ -s "$2" ] || return 1
    # 以降の照会が使う保存先を覚える
    CI_WORKFLOW_COMMANDS="$2"
    # ここまで来れば読み込み成功
    return 0
}

# 実行されるコマンド行のうち **1 行が** 渡したすべての正規表現に一致するかを返す。
# 照合は bash 組み込みの `[[ =~ ]]`（ERE）で行う。1 行 1 パターンごとに `grep` を起動すると、
# 現状の ci.yml でも 1 回の照会で百数十プロセスを生む（挙動は同じで費用だけ違う）
ci_workflow_line_matches() {
    # 1 行ずつ見る
    # 走査中の 1 行・コマンド本文・当てるパターン・全一致したかの目印
    local record text pattern matched_all
    while IFS= read -r record; do
        # 行頭のステップ番号とタブを落として、コマンド本文だけにする
        text="${record#*$'\t'}"
        # その行がすべてのパターンを満たすかを確かめる
        matched_all=1
        for pattern in "$@"; do
            # 1 つでも外れたらこの行は候補から外す
            [[ "${text}" =~ $pattern ]] || { matched_all=0; break; }
        done
        # すべて満たす行が見つかれば成功
        [ "${matched_all}" -eq 1 ] && return 0
    done < "${CI_WORKFLOW_COMMANDS}"
    # 最後まで見つからなければ失敗
    return 1
}

# **1 ステップの中で**（行はまたいでよい）渡したすべての正規表現に一致するかを返す。
# `for f in $SHELL_FILES` と `bash -n "$f"` のように、2 行で 1 つの意味を成す形のため
ci_workflow_step_matches() {
    # 各パターンがどのステップで見つかったかを記録する
    local -A hits=()
    # 走査中の 1 行・ステップ番号・コマンド本文・当てるパターン・何番目のパターンかの目印
    local record step text pattern index
    while IFS= read -r record; do
        # ステップ番号とコマンド本文に分ける
        step="${record%%$'\t'*}"
        text="${record#*$'\t'}"
        # パターンを順に当てる
        index=0
        for pattern in "$@"; do
            index=$((index + 1))
            # 一致したら「このステップでこのパターンが見つかった」と印を付ける
            [[ "${text}" =~ $pattern ]] && hits["${step}:${index}"]=1
        done
    done < "${CI_WORKFLOW_COMMANDS}"

    # すべてのパターンが揃ったステップが 1 つでもあるかを調べる
    # 何らかのパターンが当たったステップ番号の集合
    local -A steps=()
    # 走査中のキーと、そのステップが全パターンを満たしたかの目印
    local key complete
    for key in "${!hits[@]}"; do steps["${key%%:*}"]=1; done
    for step in "${!steps[@]}"; do
        complete=1
        index=0
        for pattern in "$@"; do
            index=$((index + 1))
            # 1 つでも欠けていればこのステップは該当しない
            [ -n "${hits[${step}:${index}]-}" ] || { complete=0; break; }
        done
        # すべて揃ったステップが見つかれば成功
        [ "${complete}" -eq 1 ] && return 0
    done
    # 最後まで見つからなければ失敗
    return 1
}

# 指定したスクリプトを実行している `run:` ステップがあるかを返す。
#
# **「コマンドの位置に現れること」まで見る**のが要点。パスが行のどこかに現れるだけで良しとすると、
# `echo "skipping bash test/foo_test.sh until the flake is fixed"` や `ls -l test/foo_test.sh` が
# 「実行している」と読まれる——実行をやめた当のコミットが緑で通る（レビューで実測）。
# 一方で呼び出しの書き方の揺れ（`bash -x path` / `bash ./path` / `bash "path"` /
# 実行権限に頼った `./path`）は吸収する。厳密な `bash <path>` だけを認めると、
# 意味の変わらない書き換えで「どこからも呼ばれていない」という事実と逆の診断とともに赤くなる
ci_workflow_runs_script() {
    # パスを正規表現リテラルとしてエスケープする
    local escaped
    escaped="$(ci_workflow_regex_escape "$1")"
    # コマンドの開始位置は、行頭か、`;` `&` `|` `(` のいずれかの直後。
    # そこから任意で `bash`（オプション付き可）を挟み、引用符と `./` を許してパスに一致させる。
    # 末尾は空白・`;`・行末のいずれかで区切られていること（`…_test.sh.bak` に当てないため）。
    #
    # **オプションに `n` を含むものは受け付けない。** `bash -n <path>` は構文を見るだけで
    # **実行しない**——同じジョブの隣のステップが `bash -n "$f"` なので取り違えは起こりやすく、
    # 取り違えたままだとそのスイートの表明が全部黙る。`n` を含む綴り（`-n` / `-nx` / `--noexec`）は
    # 「実行した証拠にならない」側へ倒す（判定できないものを合格にしない）
    # コマンドの前に `FOO=1` のような環境変数の指定が並ぶこともあるので読み飛ばす
    ci_workflow_line_matches "(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(bash([[:space:]]+-[^[:space:]n]+)*[[:space:]]+)?[\"']?(\./)?${escaped}[\"']?([[:space:]]|;|\$)"
}
