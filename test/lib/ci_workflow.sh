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
#   ci_workflow_load "<path to ci.yml>"   # dies via the caller's bail/exit on failure
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

# ci.yml を読み、実行される `run:` の中身をステップ番号付きで書き出す。
# 第 1 引数がワークフローのパス、第 2 引数が出力先ファイル
ci_workflow_extract() {
    # awk でステップ単位に読み、無効化されたステップを落としてから中身を出す
    awk '
        # 1 ステップ分の生の行を溜める配列を空にする
        function reset_step(   i) { for (i = 1; i <= nlines; i++) delete lines[i]; nlines = 0 }

        # コメント部分（行頭、または空白に続く # から行末まで）を落とす
        function strip_comment(t) { sub(/(^|[[:space:]])#.*$/, "", t); return t }
        # 前後の空白を落とす
        function trim(t) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); return t }

        # 溜めた 1 ステップを検査して、実行される run: の中身だけを出力する
        function flush_step(   i, line, indent, disabled, in_run, run_indent, text) {
            # 行が無ければ何もしない
            if (nlines == 0) { return }
            # このステップが無効化されていないかを先に調べる
            disabled = 0
            for (i = 1; i <= nlines; i++) {
                # `if: false` は決して実行されない
                if (lines[i] ~ /^[[:space:]]*-?[[:space:]]*if:[[:space:]]*(false|"false"|.\{\{[[:space:]]*false[[:space:]]*\}\})[[:space:]]*$/) { disabled = 1 }
                # `continue-on-error: true` は走るが失敗してもジョブを止めない＝ゲートにならない
                if (lines[i] ~ /^[[:space:]]*-?[[:space:]]*continue-on-error:[[:space:]]*(true|"true")[[:space:]]*$/) { disabled = 1 }
            }
            # 無効化されていれば、このステップの run: は「実行される」と数えない
            if (disabled) { reset_step(); return }

            # ステップ番号を進める（同じステップの行を結び付けるための識別子）
            step_id++
            # run: の値を取り出す
            in_run = 0
            for (i = 1; i <= nlines; i++) {
                line = lines[i]
                # `run: |` / `run: >` のブロック開始。以降のより深い行が本体
                if (line ~ /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[|>]/) {
                    match(line, /^[[:space:]]*/)
                    run_indent = RLENGTH
                    in_run = 1
                    continue
                }
                # 1 行で書かれた `run: <command>`
                if (line ~ /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[^|>[:space:]]/) {
                    in_run = 0
                    text = line
                    sub(/^[[:space:]]*-?[[:space:]]*run:[[:space:]]*/, "", text)
                    text = trim(strip_comment(text))
                    if (text != "") { print step_id "\t" text }
                    continue
                }
                # ブロック本体の収集中
                if (in_run) {
                    # 空行はブロックを終わらせない（YAML では単なる区切り）
                    if (line ~ /^[[:space:]]*$/) { continue }
                    match(line, /^[[:space:]]*/)
                    # `run:` と同じかそれより浅くなったらブロックの外
                    if (RLENGTH <= run_indent) { in_run = 0; continue }
                    text = trim(strip_comment(line))
                    if (text != "") { print step_id "\t" text }
                }
            }
            # 次のステップに備えて溜めた行を捨てる
            reset_step()
        }

        # リスト項目（`- ` で始まる行）が新しいステップの開始
        /^[[:space:]]*-[[:space:]]/ {
            # 直前のステップを確定させてから溜め直す
            flush_step()
            lines[++nlines] = $0
            next
        }
        # ステップの続きの行を溜める
        { lines[++nlines] = $0 }
        # 最後のステップを取りこぼさない
        END { flush_step() }
    ' "$1" > "$2"
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

# 実行されるコマンド行のうち **1 行が** 渡したすべての正規表現に一致するかを返す
ci_workflow_line_matches() {
    # 1 行ずつ見る
    local record
    while IFS= read -r record; do
        # 行頭のステップ番号とタブを落として、コマンド本文だけにする
        record="${record#*$'\t'}"
        # その行がすべてのパターンを満たすかを確かめる
        local pattern matched_all=1
        for pattern in "$@"; do
            # 1 つでも外れたらこの行は候補から外す
            grep -Eq -- "${pattern}" <<< "${record}" || { matched_all=0; break; }
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
            grep -Eq -- "${pattern}" <<< "${text}" && hits["${step}:${index}"]=1
        done
    done < "${CI_WORKFLOW_COMMANDS}"

    # すべてのパターンが揃ったステップが 1 つでもあるかを調べる
    local -A steps=()
    local key
    for key in "${!hits[@]}"; do steps["${key%%:*}"]=1; done
    for step in "${!steps[@]}"; do
        local complete=1
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
# **呼び出しの書き方の揺れを吸収する**のが要点で、`bash -x path` / `bash ./path` /
# `bash "path"` / 実行権限に頼った `./path` はいずれも「実行している」。
# 厳密な `bash <path>` だけを認めると、意味の変わらない書き換えで
# 「どこからも呼ばれていない」という事実と逆の診断とともに赤くなる
ci_workflow_runs_script() {
    # パスを正規表現リテラルとしてエスケープする
    local escaped
    escaped="$(ci_workflow_regex_escape "$1")"
    # bash 経由（オプション付きも可）か直接実行のどちらかに一致すればよい。
    # 前後は空白・行頭行末・`;` のいずれかで区切られていること（`…_test.sh.bak` に当てないため）
    ci_workflow_line_matches "(^|[[:space:]:;])(bash([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?[\"']?(\\./)?${escaped}[\"']?([[:space:]]|;|\$)"
}
