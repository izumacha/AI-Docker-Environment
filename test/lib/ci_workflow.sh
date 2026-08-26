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
#   * A step carrying `if: false` or `continue-on-error: true` is dropped, and
#     so is every step of a job carrying one. The first never runs; the second
#     runs but cannot fail the job, so neither gates anything -- and disabling
#     that way is one added line rather than a deletion, which makes it the
#     easier mistake to miss.
#   * Commands are published as *gating segments*: each command line is split at
#     `;` `&&` `||` `|` `&`, and a segment counts only when its own failure can
#     still fail the job. `bash x || true`, a trailing `&`, a pipe without
#     `pipefail`, and anything after `set +e` all run the command while
#     discarding its verdict -- `continue-on-error: true` spelled in one token.
#   * Both a per-command and a per-step view are published. `shellcheck $SHELL_FILES`
#     has to be true of one command; `bash -n "$f"` and `for f in $SHELL_FILES`
#     are two lines of one step and only make sense together.
#   * Commands are tagged with the job they belong to, so a caller can ask
#     "does *this* job run it" -- a variable defined in one job is invisible to
#     another, so an unscoped answer would call a cross-job split wired.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/ci_workflow.sh"
#   ci_workflow_load "<path to ci.yml>" "<scratch file>"   # returns non-zero on failure;
#                                          the caller decides whether to bail
#   ci_workflow_command_matches <job> <regex>...  # one gating command matches all of them
#   ci_workflow_step_matches    <job> <regex>...  # one step matches all, across its commands
#   ci_workflow_runs_script     <path> [<job>]    # some gating command invokes that script
#   ci_workflow_env_records     def <name>        # jobs whose env defines that folded block
#   ci_workflow_env_records     val <name>        # the entries of that block, one per line
#   ci_workflow_regex_escape    <string>          # literal text -> safe ERE fragment
# `<job>` は絞り込むジョブ名。空文字列を渡すとジョブを問わない。

# **コマンドの開始位置**を表す正規表現の断片（実行ラッパと環境変数の前置きを読み飛ばす）。
# `ci_workflow_runs_script` と、リンタの綴りを照合する呼び出し側の**両方**がこれを使う——
# 別々に書くと「このコマンドは実際に呼ばれているか」への答えが 2 つに割れ、
# 片方だけが `sudo shellcheck …` のような等価な書き換えを認めなくなる（レビューで実測）
CI_WORKFLOW_COMMAND_START='^[(]?[[:space:]]*((sudo|env|nice|timeout|command|exec)[[:space:]]+|[0-9]+[smhd]?[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'

# 抽出した「実行されるコマンド」を保持するファイル。1 行が
# `<ジョブ名>#<ステップ番号><TAB><ゲートに効くか(1/0)><TAB><コマンドの断片>`
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

    # 引用符の 2 種類は awk の変数として 1 文字ずつ渡す（awk のプログラムはシェルの単一引用符で
    # 囲まれており、その中に `'` を直接書けないため）。
    # `flow_re` はフロー形式の区切りとして意味を持つ文字の集合、`flow_mask` はそれを伏せる代役の文字
    awk -v dq='"' -v sq="'" -v flow_re='[][{},]' -v flow_mask='~' \
        -v tight_openers='{[,' '
        # 引用符に囲まれたスカラー（値）の中にあるフロー形式の区切り文字を、代役の文字へ置き換える。
        #
        # なぜ要るか（issue #93 の 2 件目）: この関数はもともと引用符を無条件に落としていたため、
        # `- name: "compare pinning, uses: policy"` が `- name: compare pinning, uses: policy` に
        # なり、**ただの手順名が「カンマの直後の `uses:`」というフロー形式の宣言に化けていた**。
        # 消費側は位置規則でしか構造を見分けられないので、参照 `policy` を報告して
        # **正しく SHA ピンされたリポジトリの必須チェックを恒常的に赤くしていた**（実測）。
        #
        # なぜ「区切り文字だけ」を伏せるのか: 引用の中身ごと伏せると
        # `uses: "actions/checkout@v7"` の参照まで読めなくなり、可変タグが検査を素通りする
        # （＝このファイルが繰り返し塞いできた fail-open へ逆戻りする）。伏せるのは
        # **構造としてしか意味を持たない文字**に限り、参照の綴りには一切触れない。
        #
        # なぜ 1 文字を 1 文字へ置き換えるのか: **構造行を元の行と桁で突き合わせられる状態に保つため**。
        # いまの消費側は伏せたあとの行だけを見て桁を数えるので、実は長さが変わっても動く
        # （`flow_mask` を 2 文字にしても `action_pin_test.sh` は緑のままなことを実測）。
        # それでも 1 対 1 を守るのは、元の行と桁がずれる変換を入れると、将来「生の行の桁と
        # 突き合わせる消費側」が黙って壊れるため。安いので保っておく、という判断。
        #
        # **伏せると値の綴りが変わる場合がある。** 引用された値そのものが区切り文字を含むとき
        # （`uses: "${{ inputs.action_ref }}"` など）は、その値も `$~~` のように変わる。
        # 検査は通らない側へ倒れる（＝ピン済みとは扱われない）ので安全側だが、診断に出る綴りが
        # ファイル中の文字列と一致しなくなる点は承知のうえ。
        #
        # **どこで始まり、どこで終わるかは YAML の規則どおりに見る。** ここを緩めるとどちらの向きにも
        # 壊れることが、この関数を作る過程で実測できた:
        #   - 開始を緩めた場合（引用符なら何でも開始と読む）… 素のスカラー途中のアポストロフィ
        #     （`don'"'"'t`）が開始になり、次のアポストロフィ（`it'"'"'s`）までが「引用の中」になる。
        #     その範囲に**本物の**区切りが挟まっていると、それごと伏せて `uses:` を見逃す
        #     （実測: `- {name: pre-'"'"'release, uses: actions/evil@v1, note: it'"'"'s ok}` で
        #     可変タグが検査から丸ごと消えた。**fail-open**）。
        #   - 終了を緩めた場合（最初の同種の引用符で必ず閉じる）… YAML の脱出表記
        #     （単一引用の `'"'"''"'"'`／二重引用の `\"`）で早く閉じてしまい、残りが引用の外として
        #     出てくる。実測: `- name: '"'"'don'"'"''"'"'t compare pinning, uses: policy'"'"'` で
        #     issue #93 の 2 件目（幻の参照 `policy`）がそのまま再現した。
        # そこで開始は**値が始まりうる位置**に限り、終了は**脱出表記を解いてから**判定する。
        # 判断が付かない引用（位置が合わない・行内で閉じない）は伏せずに従来の姿へ倒す
        # ＝「余分に赤くなる」側であって、見逃しは生まない（fail-closed）。
        #
        # 引用符そのものは今までどおり落とす（`"permissions":` と `permissions:` を同じ形に
        # 揃える FR-8.1 の前提。脱出表記や入れ子で現れた引用符も同じく落とす）。
        function mask_quoted_flow_punctuation(src, line_start_ok,   out, raw, masked, quote, prev, gap, closed, keyq, seqzone, dashind, i, ch, nxt, len) {
            # 確定した出力・引用の中身の写し・開いている引用符の種類を初期化する
            out = ""; raw = ""; quote = ""
            # 引用の外で最後に見た空白以外の文字と、その後ろに空白があったか（開始位置の判定に使う）
            prev = ""; gap = 0
            # 直前の非空白が引用スカラーの終わりだったか／いまの `:` がその直後の `:` だったか
            closed = 0; keyq = 0
            # 行頭からまだ字下げと `-` しか見ていないか（`-` が本物の並びの印かを見分けるのに使う）
            # と、直前の `-` がその位置にあったか
            seqzone = 1; dashind = 0
            # 1 文字ずつ見るので、行の長さを先に求めておく
            len = length(src)
            # 行の左端から 1 文字ずつ走査する
            for (i = 1; i <= len; i++) {
                # いま見ている 1 文字を取り出す
                ch = substr(src, i, 1)
                # まだ引用の外にいる場合
                if (quote == "") {
                    # 引用符かどうかを先に見る
                    if (ch == dq || ch == sq) {
                        # 値が始まりうる位置に置かれているときだけ、スカラーの開始として扱う。
                        # フローの区切り（`{` `[` `,`）の直後なら空白の有無を問わない。
                        # 並びの `-` と、素の鍵に続く `:` は**空白を挟んでいることを要求する**:
                        # 空白が無い `pre-'"'"'release` の `-` は区切りではなくただの文字で、
                        # ここを緩めると語中のハイフンから始まる fail-open がそのまま戻る。
                        # ただし**引用された鍵に続く `:` は空白を要らない**（JSON 形式の
                        # `{"name":"a, uses: policy"}` は正しい YAML で、PyYAML も
                        # `{'"'"'name'"'"': '"'"'a, uses: policy'"'"'}` と読む）。素の鍵の `{name:"a` とは
                        # 区別が付く: あちらは `name:"a` までが 1 つの鍵になるので開始と認めない。
                        #
                        # **行頭の引用符は開始と認めない。** 素のスカラーは複数行に続けられ、
                        # その**継続行は引用符から始まってよい**（YAML が禁じるのはスカラーの
                        # 先頭文字だけ）。この関数は 1 行ずつしか見ないので、行頭の引用符が
                        # 新しいスカラーの開始なのか継続行の中の 1 文字なのかを決められない。
                        # 決められないまま開始と読むと、そこから次の引用符までの**本物の区切り**を
                        # 伏せて `uses:` や `secrets:` を見逃す（実測: `steps: [{name: a` の次行を
                        # `'"'"'b, uses: actions/evil@v1'"'"', z: 1}, …]` とすると可変タグが検査から消えた）。
                        # 決められないなら伏せない＝従来の姿へ倒す（fail-closed）
                        # **`prev != ""` を先に確かめる。** `index()` に空の探し文字列を渡すと
                        # 実装によって答えが割れ、mawk 1.3.4 は `index("{[,", "")` に **1** を返す。
                        # つまりこの守りが無いと、行頭（まだ何も見ていない状態）が
                        # 「フローの区切りの直後」と判定され、上に書いた fail-open が
                        # **条件を消しても消えないまま**残る（実測でここに気付いた）
                        if ((prev == "" && line_start_ok) || \
                            (prev != "" && (index(tight_openers, prev) > 0 || \
                            (prev == ":" && (gap || keyq)) || \
                            (prev == "-" && gap && dashind)))) {
                            quote = ch; raw = ""; continue
                        }
                        # 位置が合わない引用符は、従来どおり落とすだけ（伏せない＝今日と同じ挙動）
                        continue
                    }
                    # 引用の外の文字は構造かもしれないので、一切手を加えず出力へ送る
                    out = out ch
                    # 空白は位置判定に影響させない（`{"a" : "b"}` のように間が空く書き方があるため、
                    # 「直前が引用の終わりだったか」の記憶もここでは消さない）
                    if (ch ~ /[[:space:]]/) { gap = 1; continue }
                    # `:` を見たら「引用された鍵の直後の `:` か」を控える（上の開始判定で使う）
                    if (ch == ":") keyq = closed
                    # `-` を見たら「行頭から字下げと `-` しか見ていない位置か」を控える。
                    # YAML で `- ` が並びの印になるのはこの位置だけで、スカラーの途中の
                    # `Lint - '"'"'tis time` の `-` はただの文字。ここを見ないと、その `-` の後ろの
                    # 引用符が開始と認められ、**本物の区切りごと伏せて `uses:` を見逃す**（実測）
                    if (ch == "-") dashind = seqzone
                    # 字下げと `-` 以外の文字が出た時点で、行頭の印の並びは終わり
                    if (ch != "-") seqzone = 0
                    # 直前の文字として覚え、空白と引用終わりの記憶はここで消す
                    prev = ch; gap = 0; closed = 0
                    continue
                }
                # 単一引用の中では `'"'"''"'"'` が「文字としてのアポストロフィ」を表し、ここでは閉じない。
                # 従来の一律削除に合わせて、写しに足さずに 2 文字ぶん読み飛ばす
                if (quote == sq && ch == sq && substr(src, i + 1, 1) == sq) { i++; continue }
                # 二重引用の中の `\` は次の 1 文字を脱出させる。`\"` で閉じたと誤らないよう 2 文字で扱う
                if (quote == dq && ch == "\\") {
                    # 脱出される側の 1 文字を先に覗く
                    nxt = substr(src, i + 1, 1)
                    # バックスラッシュ自体は従来どおり素の文字として残す
                    raw = raw ch
                    # 脱出された文字が引用符なら従来の一律削除に合わせて落とし、それ以外は控える
                    if (nxt != "" && nxt != dq && nxt != sq) raw = raw nxt
                    # 脱出された 1 文字はいま処理したので、次の文字まで読み進める
                    i++
                    continue
                }
                # 同じ種類の引用符が来たらスカラーの終わり（脱出表記は上で処理済み）
                if (ch == quote) {
                    # 中身の写しから、フロー形式の区切り文字だけを代役へ一括で置き換える
                    masked = raw
                    gsub(flow_re, flow_mask, masked)
                    # 伏せた写しを出力へ確定させ、引用の外へ戻る
                    out = out masked
                    # 閉じた直後に続く引用符を「開始」と誤読しないよう、開始位置になりえない文字を
                    # 直前の文字として置く（`"` は開始位置の文字集合のどれにも含まれない）。
                    # 併せて「直前は引用の終わりだった」ことを控える（JSON 形式の鍵の判定に使う）
                    prev = dq; gap = 0; closed = 1
                    # 引用の状態を片付けて次の文字へ進む
                    quote = ""; raw = ""
                    continue
                }
                # 入れ子の別種の引用符は、従来の一律削除と同じく落とす（写しにも入れない）
                if (ch == dq || ch == sq) continue
                # それ以外は中身としてそのまま控える（伏せるのは閉じるときにまとめて行う）
                raw = raw ch
            }
            # 行末まで来ても引用が閉じていなければ、伏せずに元の姿で出力する。
            # 複数行にまたがる引用スカラーなど、この行だけでは対応が取れない場合に
            # 伏せてしまうと**本物の区切りを隠して `uses:` を見逃す**ため、従来の挙動へ倒す（fail-closed）
            if (quote != "") out = out raw
            # 組み立てた 1 行を返す
            return out
        }
        # ブロックスカラーの本文の中かどうかと、その開始行の字下げ幅を覚える
        BEGIN { in_scalar = 0; scalar_indent = 0; bare_key = 0 }
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
            # ここで揃えておけば、消費側それぞれが引用の有無を数え上げずに済む。
            # 併せて、引用の中にあるフロー形式の区切り文字を代役の文字へ伏せる
            # （ただの値に書かれた読点や括弧を構造と読み違えないため。理由は関数側のコメント）
            # 行頭の引用符を開始と認めてよいかは**前の構造行**で決まる（下の `bare_key` を参照）
            emitted = mask_quoted_flow_punctuation(line, bare_key)
            # ここまで残った行は構造なので、行番号を付けて書き出す
            print NR ":" emitted

            # スカラー開始かどうかは、コメント・大文字小文字を揃えた写しで判定する
            probe = emitted
            sub(/[[:space:]]*#.*$/, "", probe)
            probe = tolower(probe)

            # **次の行の行頭にある引用符を開始と認めてよいか**を、この行の形から決めておく。
            # 素のスカラーは次の行へ続けられるので、行頭の引用符は「新しい値の始まり」かも
            # 「続きの文字」かもしれず、行だけ見ても区別できない（だから既定では開始と認めない）。
            # ただし**この行が値を持たない鍵（`- name:` や `steps:`）で終わっていた**なら、
            # YAML は次に必ず新しい節点を要求する＝続きの行ではありえないので、そのときだけ認める。
            # これが無いと、`- name:` の次行に引用した手順名を置く**ブロック形式の書き方**で
            # issue #93 の 2 件目（幻の参照）がそのまま残る（実測）。
            # **コメントだけの行では記憶を書き換えない。** YAML のコメントは鍵と値のあいだにも置け、
            # そこで「値を持たない鍵で終わった」ことを忘れると次の行の引用符が開始と認められず、
            # 同じ幻の参照が戻る（実測。空行が `next` で読み飛ばされるのと同じ扱いに揃える）
            if (probe !~ /^[[:space:]]*$/) bare_key = (probe ~ /:[[:space:]]*$/) ? 1 : 0
            # `run: |` や `prompt: >-` のような行なら、次の行から本文として読み飛ばす
            if (probe ~ /^[[:space:]]*(-[[:space:]]+)?[a-z_][a-z0-9_.-]*[[:space:]]*:[[:space:]]*[|>]([0-9]*[+-]?|[+-]?[0-9]*)[[:space:]]*$/) {
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
        BEGIN {
            jobs_indent = -1; job_indent = -1; steps_indent = -1
            step_dash_indent = -1; env_indent = -1; step_key_indent = -1; defaults_indent = -1; job_key_indent = -1
            # ブロックスカラーの基準字下げも同じ規約（-1 = まだ決まっていない）。
            # 0 で始まると「基準は 0 桁と確定済み」の意味になり、字下げを 1 桁も落とさなくなる
            run_base_indent = -1
            # ヒアドキュメントの待ち行列（`hd_i` が消化中の位置、`hd_n` が積まれた数）。
            # **明示的に初期化する**のが要点で、awk の未初期化変数は数値として 0 なので
            # 放置すると `hd_i <= hd_n` が 0 <= 0 で真になり、`run:` の 1 行目から
            # 「本文の読み飛ばし中」と誤読して**全ステップの中身が消える**
            hd_n = 0
            hd_i = 1

            # **ワークフロー直下の `defaults:` は先に 1 度だけ読んでおく。**
            # 出力はジョブ 1 つ分を確定させてから行うため、`jobs:` より後ろに書かれた既定を
            # 本文と同じ 1 回の走査で拾うと、既に確定したジョブには反映できない
            # （YAML のキー順は自由で、Actions は位置に関わらずトップレベルの `defaults:` を適用する）。
            # 桁 0 の行だけを見るので、`run: |` の本文（必ず字下げされる）と取り違えることはない
            while ((getline preline < ARGV[1]) > 0) {
                # Windows 改行が混じっていても桁の判定が狂わないよう CR を落とす
                sub(/\r$/, "", preline)
                # **行末コメントを落としてから判定する。** 本文側の走査は既にそうしており
                # （`if: false  # 理由` を取りこぼさないため）、ここだけ生の行を見ると
                # `defaults:  # 全ジョブ共通` がフロー形式に、`shell: bash  # 明示` が未知のシェルに見え、
                # **全ジョブの全ステップが合否の証拠から外れて**すべて「配線されていない」と誤報される
                sub(/(^|[[:space:]])#.*$/, "", preline)
                # **鍵の引用符も本文の走査と同じ規則で落とす。** ここだけ素の綴りを見ていると
                # `"defaults":` / `"shell":` の 2 文字で既定シェルの検出をすり抜けられ、
                # `-e` を落とすワークフロー既定が「無い」ものとして扱われる（レビューで実測）
                preline = unquote_key(preline)
                # 空行（コメントだけの行を含む）はブロックの内外を変えない
                if (preline ~ /^[[:space:]]*$/) { continue }
                # 桁 0 の鍵が来たら、直前のトップレベルブロックは終わっている
                if (preline !~ /^[[:space:]]/) { in_top_defaults = (preline ~ /^defaults:/) }
                # フロー形式（`defaults: {run: {shell: …}}`）は中身を構造として読めないので未知扱い
                if (preline ~ /^defaults:[[:space:]]*[^[:space:]]/) { workflow_shell = "?" ; in_top_defaults = 0 }
                # `run:` がフロー形式なら中の `shell:` を読めないので、未知のシェル扱いにする
                if (in_top_defaults && preline ~ /^[[:space:]]+run:[[:space:]]*[^[:space:]]/) {
                    workflow_shell = "?"
                }
                # ブロック形式の中に現れた `shell:` を既定として控える
                if (in_top_defaults && preline ~ /^[[:space:]]+shell:[[:space:]]*[^[:space:]]/) {
                    workflow_shell = read_shell_value(preline)
                }
            }
            # 本文の走査に影響しないよう読み終えたファイルを閉じる
            close(ARGV[1])
        }

        # **シェルの引用符の扱いはこの 1 か所に集約する。** 以前は「コメントの開始位置」「括弧の釣り合い」
        # 「行が閉じているか」「区切り記号かどうか」で同じ状態機械を 4 回書いており、
        # どれか 1 つにだけ修正が入ると「どこでコマンドが終わるか」と「行が続いているか」の
        # 答えが食い違う（§6 DRY。レビューで指摘）。
        #
        # **`emit_structural_lines` の `mask_quoted_flow_punctuation` とは別物**（統合しないこと）。
        # あちらは **YAML** の引用規則（`'"'"''"'"'` と `\"` の脱出、値が始まりうる位置だけを開始と認める）を
        # 見て、フロー形式の区切り文字だけを伏せて**中身は残す**。こちらは **シェル** の引用規則
        # （単一引用符の外ではバックスラッシュが次の 1 文字を打ち消す）を見て、**中身ごと空白へ潰す**。
        # 対象の言語も、残すものも違うので、片方の規則をもう片方へ持ち込むとどちらも壊れる
        # （例: シェルの `\` 打ち消しを YAML 側へ入れると `<<\MARK` と同種の取り違えが起きる）。
        #
        # 引用符で囲まれた部分を**同じ長さの空白**へ置き換えた写しを返す。桁がずれないので、
        # 呼び出し側は写しの上で位置を探して、元の文字列を同じ位置で切れる。
        # 閉じずに行が終わったかどうかは `MASK_UNCLOSED` に入れる（awk に多値返却が無いため）。
        # 規則は 1 つ: **単一引用符の外側では、バックスラッシュが次の 1 文字を打ち消す**
        function mask_quoted(t,   i, c, out, in_single, in_double) {
            out = ""; in_single = 0; in_double = 0
            for (i = 1; i <= length(t); i++) {
                c = substr(t, i, 1)
                # 打ち消された 2 文字は、区切りにもコメントにも括弧にもならない
                if (c == "\\" && !in_single && i < length(t)) { out = out "  "; i++; continue }
                # 引用符そのものは中身と同じく空白にする（開閉の状態だけ更新する）
                if (c == "\"" && !in_single) { in_double = !in_double; out = out " "; continue }
                if (c == "\047" && !in_double) { in_single = !in_single; out = out " "; continue }
                # 引用符の内側は文字列なので、すべて空白へ潰す
                if (in_single || in_double) { out = out " "; continue }
                # 引用符の外側はそのまま残す
                out = out c
            }
            # 閉じないまま行が終わったか（次の行へ続いているか）を控える
            MASK_UNCLOSED = (in_single || in_double) ? 1 : 0
            return out
        }

        # コメント部分（行頭、または空白に続く # から行末まで）を落とす。
        # 引用符の内側の `#` は落とさない——素の正規表現で切ると
        # `bash x --label \047issue # 94\047 || true` が途中で切られ、**後ろの `|| true` ごと消える**
        function strip_comment(t,   masked, i, prev) {
            masked = mask_quoted(t)
            for (i = 1; i <= length(masked); i++) {
                # 引用符の外側に現れた `#` だけが候補
                if (substr(masked, i, 1) != "#") { continue }
                # 行頭か、空白の直後であればそこからがコメント（判定は元の文字列で行う）
                prev = (i > 1) ? substr(t, i - 1, 1) : ""
                if (i == 1 || prev == " " || prev == "\t") { return substr(t, 1, i - 1) }
            }
            return t
        }
        # 前後の空白を落とす
        function trim(t) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); return t }

        # **先頭のスペースの数を数える。** YAML の字下げはスペースのみで、タブは字下げに
        # 使えない（＝本文先頭のタブは内容の一部）。基準字下げを**測る側**と、終端判定で
        # **落とす側**の両方がここを使う。2 か所へ書き写すと、片方だけ直したときに
        # 落とす量がずれて issue #108 の穴が開き直る
        function leading_spaces(t,   n) {
            n = match(t, /[^ ]/)
            # 全部スペースの行（空行扱い）は長さそのものが字下げ
            return (n ? n - 1 : length(t))
        }

        # **ヒアドキュメントの終端行かどうかを bash と同じ厳しさで判定する。**
        # bash が終端と認めるのは「区切り語だけが置かれた行」だけで、行末コメントが
        # 付いた行や余分な字下げが残る行は本文のまま。ここを緩くすると本文の途中で
        # 読み飛ばしが終わり、**ただのデータが「実行されるコマンド」に化ける**
        # （issue #108）。`ci_coverage_test.sh` はこの記録を根拠に「全スイートが
        # 実行されるか」を判定するので、ワークフローから外されたスイートが
        # ヒアドキュメントの中で名前を挙げられているだけで「実行されている」と通る
        # ——このライブラリが塞ぐために作られた「不在＝合格」そのものの形になる。
        # 判定できないものは呼び出し側で「本文が続く」に倒れる（fail-closed）。
        # 引数: raw=生の行 / dash=`<<-` で開いたか /
        #       base_indent=ブロックスカラーの基準字下げ / word=区切り語
        # **引数名は `indent` にしない。** awk の引数は関数スコープだが、同名のグローバル
        # `indent`（構造行の入れ子判定に使う）を黙って隠すため、ここで代入する編集が
        # 外側に効かない／外側の値を読むつもりの編集が別物を読む、という罠になる
        function heredoc_terminates(raw, dash, base_indent, word,   lead, drop, rest) {
            # YAML のブロックスカラーは本文全体が字下げされている。bash が実際に見るのは
            # **その基準字下げ分だけ**を落とした後の行なので、まず同じ分を落として揃える。
            # 先頭の**スペース**の長さを 1 度測り、基準字下げとの小さい方だけを落とす
            # （基準より深い字下げは bash にも残るので、ここでも残す）。
            # タブは YAML の字下げではなく内容なので、ここでは落とさない
            # ——落とすのは `<<-` の規則に従って下で行う
            lead = leading_spaces(raw)
            # 実際の字下げと基準の**小さい方**だけを落とす。基準より浅い本文行は
            # YAML ではブロックスカラーを終える（＝ここへ来ない）ので、この下限が効くのは
            # 全部スペースの行だけで、どちらに倒れても `rest` は区切り語と一致しない。
            # なお heredoc が開いている時点で基準は必ず確定済み（開いた行自身が
            # 非空の本文行として決めている）なので、base_indent が負になる経路は無い
            drop = (lead < base_indent) ? lead : base_indent
            rest = substr(raw, drop + 1)
            # **`<<-` が落とすのは先頭のタブだけで、スペースは落とさない。**
            # YAML の字下げはスペースなので、ここを「字下げは何でも許す」と緩めると、
            # 実際のワークフローで書ける唯一の形がちょうど検査を素通りする（issue #108）
            if (dash) { sub(/^\t+/, "", rest) }
            # 残りが区切り語ちょうどのときだけ終端。**コメントを剥がしてから比べない**
            # ——`MARK # 説明` は bash にとって本文であって終端ではない
            return (rest == word)
        }

        # **鍵を囲む引用符を落として揃える。** YAML は `"shell": bash` を `shell: bash` と
        # 同じ鍵として読むので、素の綴りだけを見ると引用符 2 つで検出をすり抜けられる。
        # 値には触らない（値の引用符は `read_shell_value` / `is_disabling` 側で扱う）
        function unquote_key(t,   probe) {
            probe = t
            if (probe ~ /^[[:space:]]*-?[[:space:]]*["\047][A-Za-z0-9_.-]+["\047][[:space:]]*:/) {
                match(probe, /["\047][A-Za-z0-9_.-]+["\047]/)
                probe = substr(probe, 1, RSTART - 1) substr(probe, RSTART + 1, RLENGTH - 2) substr(probe, RSTART + RLENGTH)
            }
            return probe
        }

        # `shell:` の行から値だけを取り出す。**引用符は落とす**——YAML では `shell: "bash"` と
        # `shell: bash` は同じスカラーなので、引用の有無で「未知のシェル」に転ぶと、
        # 見た目だけの整形で「どこからも呼ばれていない」と事実と逆の診断が出る
        # （`is_disabling` が同じ理由で引用符を正規化しているのと揃える）。
        # 2 か所（ステップの `shell:` と `defaults:` の `shell:`）から呼ぶのでここに置く（§6 DRY）
        function read_shell_value(t,   value) {
            value = t
            sub(/^[[:space:]]*-?[[:space:]]*shell:[[:space:]]*/, "", value)
            gsub(/["\047]/, "", value)
            return trim(value)
        }

        # 断片の中の丸括弧の釣り合い（開き − 閉じ）を返す。引用符の中は数えない
        function paren_delta(t,   masked, i, c, delta) {
            masked = mask_quoted(t)
            delta = 0
            for (i = 1; i <= length(masked); i++) {
                c = substr(masked, i, 1)
                if (c == "(") { delta++ }
                else if (c == ")") { delta-- }
            }
            return delta
        }

        # 引用符が閉じていない（＝次の行へ続く）かどうかを返す
        function unbalanced_quotes(t) {
            mask_quoted(t)
            return MASK_UNCLOSED
        }

        # 指定した個数の空白を返す。**桁を保ったまま塗り潰す**ために使う
        # （長さの変わる置換をすると、写しの上で見つけた位置で元の行を切れなくなる）
        function spaces(n,   s) {
            s = ""
            while (length(s) < n) { s = s " " }
            return s
        }

        # 算術展開（`$(( … ))` / `(( … ))`）を**同じ長さの空白へ塗り潰した**写しを返す。
        # 内側の入れ子から順に潰すので `$(( (1 << A) + B ))` のような形も残らない。
        # heredoc の判定にだけ使う。
        # **長さを保つ**のが要点で、`collect_heredocs` はこの写しの上で `<<` の位置を探し、
        # 区切り語そのものは**元の行の同じ位置**から読む（引用符やバックスラッシュは
        # 写しの上では潰れているため）。1 文字へ縮める昔の版では桁がずれて別の場所を読む
        function strip_arithmetic(t,   guard) {
            # 置換のたびに減るのは括弧の数だけだが、万一に備えて回数にも上限を置く
            guard = 0
            while (guard < 100) {
                guard++
                # まず `((` … `))` の形を丸ごと塗り潰す
                if (match(t, /\$?\(\([^()]*\)\)/)) {
                    t = substr(t, 1, RSTART - 1) spaces(RLENGTH) substr(t, RSTART + RLENGTH)
                    continue
                }
                # **入れ子があると上の形に当たらない**（`$(( (1 << BIT) | FLAG ))` など）。
                # まだ算術式らしい `((` が残っているときに限り、内側の括弧を 1 つ潰して近づける。
                # `(` を無条件に潰すと `( cat <<EOF )` のような部分シェルの heredoc まで
                # 見えなくしてしまうので、`((` が残っていることを条件にする
                if (index(t, "((") > 0 && match(t, /\([^()]*\)/)) {
                    t = substr(t, 1, RSTART - 1) spaces(RLENGTH) substr(t, RSTART + RLENGTH)
                    continue
                }
                # これ以上潰せるものが無ければ終わり
                break
            }
            return t
        }

        # 元の行 `raw` の `start` 桁から**区切り語 1 つ**を読み、その文字列を返す。
        # 読み終えた次の桁は `HEREDOC_WORD_END` に入れる（awk に多値返却が無いため）。
        #
        # **区切り語の 4 綴りをここで一手に引き受ける**のが要点。bash は `<<EOF` / `<<"EOF"` /
        # `<<\047EOF\047` / `<<\EOF` を**すべて同じ区切り語 `EOF`** として扱う（引用は本文中の展開を
        # 抑止するだけで、終端の綴りは変えない）。以前は引用符だけを別関数で外し、残りを
        # `mask_quoted` に通してから正規表現で切り出していたため、
        #   - `<<\MARK` … `mask_quoted` が `\M` を空白 2 つへ潰して区切り語が `ARK` に化け、
        #     終端に一生出会えず**本文の後ろの実行まで捨てる**（issue #110・fail-closed）
        #   - `<<""`   … 空の区切り語に一致する綴りが無く**そもそも heredoc が開かない**ので、
        #     本文（＝実行されない文字列）が実行として記録される（issue #111 (2)・fail-open）
        # の 2 つが同時に起きていた。元の行から 1 文字ずつ読めばどちらも自然に消える
        function read_heredoc_word(raw, start,   len, i, c, quote, word) {
            len = length(raw)
            word = ""
            i = start
            while (i <= len) {
                c = substr(raw, i, 1)
                # バックスラッシュは次の 1 文字を「そのままの字」にする（`<<\MARK` → `MARK`）
                if (c == "\\" && i < len) { word = word substr(raw, i + 1, 1); i += 2; continue }
                # 引用符の内側は閉じ引用符まで丸ごと取り込む（`<<"EOF"` / `<<\047EOF\047`）。
                # **空の引用（`<<""`）もここを通る**ので、長さ 0 の区切り語が素直に得られる
                if (c == "\"" || c == "\047") {
                    quote = c
                    i++
                    while (i <= len && substr(raw, i, 1) != quote) { word = word substr(raw, i, 1); i++ }
                    i++
                    continue
                }
                # 空白・リダイレクト・制御演算子は区切り語の終わり
                if (c ~ /[[:space:];&|<>()]/) { break }
                # ここまで来た 1 文字は区切り語の一部
                word = word c
                i++
            }
            # 読み終えた次の桁を控える（呼び出し側が同じ行の続きを走査するために使う）
            HEREDOC_WORD_END = i
            return word
        }

        # 1 行が開くヒアドキュメントを**すべて**、bash が本文を読む順（＝行の左から右）に集め、
        # `hd_word[1..hd_n]` / `hd_dash[1..hd_n]` へ入れる。開いた数を返す。
        #
        # **1 行に 2 つ以上書ける**のが要点。`cat <<A > a; cat <<B > b` と書くと bash は
        # **A の本文を先に**読み、その後ろに B の本文が続く。以前は貪欲な `^.*<<-?` で
        # **行の最後の 1 つ**だけを覚えていたため、A の本文の中に現れた `B` で読み飛ばしを
        # 終えてしまい、まだ A の本文である行（＝実行されない文字列）が「実行されるコマンド」
        # として記録されていた（issue #111 (1)・fail-open）。
        #
        # **`<<-` は追跡中の区切り語ごとに覚える。** 以前は「行のどこかに `<<-` があるか」で
        # 一括判定しており、`cat <<-A; cat <<B` のように混在すると素の `<<` の終端判定にまで
        # タブ剥がしが伝染して早く終端した（issue #111 (3)・fail-open）
        function collect_heredocs(raw,   probe, len, i, j, dash) {
            # 開き直すたびに待ち行列を空にする（前の行の残りを引きずらない）
            hd_n = 0
            hd_i = 1
            # 引用符の中と算術展開を**桁を保ったまま**塗り潰した写しの上で `<<` を探す。
            # `echo "use << HERE"` の `<<` や `$(( 1 << 2 ))` の左シフトは heredoc ではない
            probe = strip_arithmetic(mask_quoted(raw))
            len = length(probe)
            i = 1
            while (i <= len) {
                # `<<` 以外の桁は読み飛ばす
                if (substr(probe, i, 2) != "<<") { i++; continue }
                # here-string（`<<<`）は 1 語を渡すだけで本文を持たない
                if (substr(probe, i, 3) == "<<<") { i += 3; continue }
                # `<<` の次の桁から見る
                j = i + 2
                dash = 0
                # `<<-` は本文と終端の**先頭のタブ**を落とす綴り
                if (substr(probe, j, 1) == "-") { dash = 1; j++ }
                # 区切り語の前の空白は読み飛ばす。**判定は元の行で行う**——写しの上では
                # 引用符が空白に潰れているので、`<<""` の引用符を「前置きの空白」と
                # 読み飛ばして別の場所を区切り語にしてしまう
                while (j <= len && (substr(raw, j, 1) == " " || substr(raw, j, 1) == "\t")) { j++ }
                # 区切り語を 1 つ読み、待ち行列の末尾へ足す
                hd_n++
                hd_word[hd_n] = read_heredoc_word(raw, j)
                hd_dash[hd_n] = dash
                # 同じ行にまだ `<<` が続くかもしれないので、読み終えた次の桁から探し直す
                i = HEREDOC_WORD_END
            }
            return hd_n
        }

        # 1 行を制御演算子（`;` `&&` `||` `|` `&`）で切り、seg[] に本文・ops[] に直後の演算子を入れる。
        # **区切りを見てはじめて「失敗が job に伝わるか」が決まる**のがこの分割の理由で、
        # 演算子をコマンド末尾に貼り付いた形でしか見ないと、間に引数やリダイレクトが 1 つ入るだけで
        # `bash x 2>&1 | tee log`（落ちてもステップは 0 で終わる）を「ゲートしている」と読む
        function split_commands(line, seg, ops,   i, n, c, nxt, prv, start, masked) {
            # 引用符の中を空白へ潰した写しの上で区切りを探す（桁が同じなので元の文字列を切れる）
            masked = mask_quoted(line)
            n = 0; start = 1
            for (i = 1; i <= length(masked); i++) {
                c = substr(masked, i, 1)
                nxt = substr(masked, i + 1, 1)
                prv = (i > 1) ? substr(masked, i - 1, 1) : ""
                # `;` は区切り。直後のコマンドは前の結果に関係なく走る
                if (c == ";") {
                    n++; seg[n] = substr(line, start, i - start); ops[n] = ";"; start = i + 1
                    continue
                }
                # `||`（前が失敗したときだけ走る）と `|`（パイプ）を見分ける
                if (c == "|") {
                    n++; seg[n] = substr(line, start, i - start)
                    if (nxt == "|") { ops[n] = "||"; i++ } else { ops[n] = "|" }
                    start = i + 1
                    continue
                }
                if (c == "&") {
                    # `2>&1` / `&>log` / `<&3` はリダイレクトであって区切りではない
                    if (prv == ">" || prv == "<" || nxt == ">") { continue }
                    # `&&`（前が成功したときだけ走る）と `&`（バックグラウンド実行）を見分ける
                    n++; seg[n] = substr(line, start, i - start)
                    if (nxt == "&") { ops[n] = "&&"; i++ } else { ops[n] = "&" }
                    start = i + 1
                    continue
                }
            }
            # 最後の断片は演算子を伴わない（行末まで続く）
            n++; seg[n] = substr(line, start); ops[n] = ""
            # 断片の数を返す（呼び出し側は 1..n だけを読む）
            return n
        }

        # その構造行がステップの中の鍵かどうかを返す。**ジョブ直下の鍵は `steps:` と同じ桁**に並ぶ
        # （どちらもジョブというマップの鍵なので）。ダッシュで始まる行はステップの先頭鍵なので中側。
        # その構造行が「ジョブ直下の鍵」「ステップ自身の鍵」「それより内側（入れ子の中身）」の
        # どれかを返す。**3 通りに分けるのが要点**で、真偽 2 通りにすると
        # `with:` の下の入れ子の並びに書かれた `- if: false` の行き先が無く、
        # ジョブ直下（＝ジョブ全体を止める）かステップ（＝外側のステップを止める）へ
        # 誤って割り当てられる（どちらも、実行されているスイートを「未配線」と誤報する。レビューで実測）
        function key_scope(probe, indent) {
            # `steps:` にまだ入っていない段階では、**ジョブ直下の鍵の桁**と比べる。
            # 「ジョブより深ければジョブ直下」と決めると、`steps:` より前に来ることの多い
            # `env:` / `strategy:` / `container:` の**中身**（`env: defaults: none` など）まで
            # ジョブ直下の鍵と読み、ジョブ全体を証拠から外してしまう（レビューで実測）
            if (steps_indent < 0 || step_dash_indent < 0) {
                if (job_indent < 0 || indent <= job_indent) { return "outside" }
                return (job_key_indent < 0 || indent == job_key_indent) ? "job" : "nested"
            }
            # ダッシュで始まる行は、**基準の桁にあるときだけ**ステップの 1 つ目の鍵（`- if: false`）
            if (probe ~ /^[[:space:]]*-([[:space:]]|$)/) {
                return (indent == step_dash_indent) ? "step" : "nested"
            }
            # `steps:` と同じ桁の鍵はジョブ直下のもの（`- name:` を同じ桁に書く書式でもここで分かれる）
            if (indent <= steps_indent) { return "job" }
            # ステップ自身の鍵の桁ならステップのもの、それより深ければ入れ子の中身
            return (indent == step_key_indent) ? "step" : "nested"
        }

        # 溜めた 1 ステップ分を、無効化されていなければジョブの控えへ移す。
        # **ここでは出力しない**のが要点で、ジョブ単位の無効化キー（`if: false` 等）は
        # YAML のキー順が自由である以上 `steps:` の**後ろ**にも書ける。書いた時点で
        # 出力済みのステップは取り消せないため、ジョブ 1 つ分を溜めてから出す
        function flush_step(   i, j, nseg, seg, ops, text, errexit, pipefail, joined, njoined, carry, depth, dead_depth, paren, paren_probe, case_depth, prev_op, unreachable, chain_status, uncertain, uncertain_at, subshell, subshell_at, closing, group_start, closed_group_start, inner, k) {
            # **シェルのオプションはステップごとにリセットする。** ステップは 1 つずつ
            # 別のシェルで走るので、前のステップの `set +e` / `pipefail` は引き継がれない。
            # **控えるのは `set` で明示された分だけ（-1 = 明示なし）。** シェルの既定と突き合わせるのは
            # ジョブが確定するとき（`flush_job`）で、ここではまだ決めない——ジョブの既定シェルは
            # `steps:` の**後ろ**にも書けるので、ステップを確定する時点では判明していないことがある
            # （1 ステップずつ決めると、後ろに書かれた既定が最後のステップにしか効かない。レビューで実測）
            errexit = -1
            pipefail = -1
            # 制御構造の深さもステップごとに数え直す
            depth = 0
            # そのうち「走るか分からない」側の数（実行の証拠と `set` の反映はこれで決める）
            uncertain = 0
            # 偽と分かる条件のブロックに入った深さ（-1 = 入っていない）
            dead_depth = -1
            # `case` の入れ子の数（パターン末尾の `)` を見分けるために数える）
            case_depth = 0
            # 直前の断片の後ろに置かれた区切り（「そもそも走らない」形の判定に使う）
            prev_op = ""
            # 直前までの連鎖が「そもそも走らない」状態か
            unreachable = 0
            # 連鎖の現在の状態（"" = 不明 / "t" = 真と分かる / "f" = 偽と分かる）。
            # `A && B || C` のように向きが変わる連鎖では、「B が走らない」ことと
            # 「C が走らない」ことは別物なので、区切りの種類だけでは決められない
            chain_status = ""
            # 部分シェル（`( … )`）の入れ子の数。**`set` はここでは外へ漏れない**
            subshell = 0
            if (!step_disabled) {
                # **行末の `\` は次の行へ続く 1 つの論理行。** 物理行のまま切ると、
                # 次の行に置かれた `|| true` やパイプが呼び出しと結び付かず、
                # 握り潰された実行を「ゲートしている」と読む（レビューで実測）
                njoined = 0
                carry = ""
                for (i = 1; i <= ncmd; i++) {
                    # 前の行が継続していれば、その続きとして繋ぐ
                    text = (carry != "") ? carry " " cmds[i] : cmds[i]
                    # まだ `\` で終わっていれば、次の行を待つ
                    if (text ~ /\\$/) { carry = substr(text, 1, length(text) - 1); continue }
                    # **引用符が閉じていない行も 1 つの論理行の途中。** 閉じるまで繋がないと、
                    # 複数行の引用符付き引数の**閉じ行**に付いた `|| true` が呼び出しと結び付かず、
                    # 握り潰された実行が「ゲートしている」と読まれる（レビューで実測）
                    if (unbalanced_quotes(text) && i < ncmd) { carry = text; continue }
                    # continuation が閉じたので 1 本の論理行として確定する
                    carry = ""
                    joined[++njoined] = text
                }
                # 最後の行が `\` で終わっていても取りこぼさない
                if (carry != "") { joined[++njoined] = carry }

                for (i = 1; i <= njoined; i++) {
                    # 1 つの論理行を断片に切る
                    nseg = split_commands(joined[i], seg, ops)
                    for (j = 1; j <= nseg; j++) {
                        # 前後の空白を落として本文だけにする。**内側のタブは空白へ潰す**——
                        # 控えはタブ区切りで持つので、本文にタブが残ると 6 列目がそこで切れ、
                        # 後ろにある呼び出しが記録から消える（YAML のブロックスカラーにタブは書ける）
                        text = trim(seg[j])
                        gsub(/\t/, " ", text)
                        # `set +e` 以降はエラーが伝わらない。`set -e` で元に戻る
                        # （`set +e … set -e` で囲った検査を「ゲートしない」と決め付けると、
                        #   実際には落ちるステップが「配線されていない」と逆の診断で赤くなる）
                        # **オプションは語をまたいで書ける**（`set -e -o pipefail` / `set -o pipefail -e`）。
                        # 1 語目だけを見ると、実際には落ちる書き方を「落ちない」と読んで誤報する
                        # **制御構造の中や、偽と分かるブロックの中の `set` は反映しない。**
                        # 走ったかどうかが分からないものをステップ全体の状態にすると、
                        # 通らない分岐の `set -e` で握り潰しが隠れ、通るとは限らない分岐の
                        # `set +e` で実際にはゲートするステップが「未配線」と誤報される（レビューで実測）
                        # **部分シェル（`( … )`）の中の `set` は外へ漏れない。** 子シェルの
                        # オプション変更なので、`set +e` のステップの中に `( set -e )` を置いても
                        # 親は握り潰したままである（ブレースグループ `{ … }` は同じシェルなので漏れる）
                        if (text ~ /^set([[:space:]]|$)/ && uncertain == 0 && dead_depth < 0 && subshell == 0) {
                            if (text ~ /(^|[[:space:]])\+[a-z]*e[a-z]*([[:space:]]|$)/) { errexit = 0 }
                            else if (text ~ /(^|[[:space:]])-[a-z]*e[a-z]*([[:space:]]|$)/) { errexit = 1 }
                            # **長い綴りも同じ意味。** `set +o errexit` は POSIX の書き方で、
                            # 短い綴りだけを見ると 1 行でゲートを外したまま「ゲートしている」と読む
                            if (text ~ /(^|[[:space:]])\+[a-z]*o[[:space:]]+errexit([[:space:]]|$)/) { errexit = 0 }
                            else if (text ~ /(^|[[:space:]])-[a-z]*o[[:space:]]+errexit([[:space:]]|$)/) { errexit = 1 }
                            # `pipefail` が立っていればパイプ越しでも失敗が伝わる
                            if (text ~ /(^|[[:space:]])-[a-z]*o[[:space:]]+pipefail([[:space:]]|$)/) { pipefail = 1 }
                            else if (text ~ /(^|[[:space:]])\+[a-z]*o[[:space:]]+pipefail([[:space:]]|$)/) { pipefail = 0 }
                        }
                        # 空の断片（`;;` や行頭の区切り）は記録しない
                        if (text == "") { continue }
                        # **制御構造の深さを追う。** `if` / `while` / `for` / `case` / 関数定義の中身は
                        # 条件や呼び出し元を読まないと実行されるか分からない。1 行で書かれた
                        # `if false; then bash x; fi` は `then` を実行ラッパに入れないことで弾けていたが、
                        # 同じ意味を 3 行で書くと弾けていなかった（2 行足すだけでスイートを止められる。レビューで実測）。
                        # 閉じ側を先に見るのは `fi` / `done` が自分の階層を閉じるため
                        # 閉じ側。**その階層が「走るか分からない」側だったかを覚えておき**、
                        # 対応する分だけ戻す（`uncertain_at[]` が階層ごとの印）
                        closed_group_start = -1
                        if (text ~ /^(fi|done|esac|\})([[:space:]]|;|$)/ && depth > 0) {
                            if (uncertain_at[depth]) { uncertain--; uncertain_at[depth] = 0 }
                            else if (group_start[depth] >= 1) { closed_group_start = group_start[depth] }
                            if (subshell_at[depth]) { subshell--; subshell_at[depth] = 0 }
                            group_start[depth] = -1
                            depth--
                        }
                        # **括弧は釣り合いで測る。** 閉じ側が断片の**先頭**に来るとは限らず、
                        # `( cd /tmp; echo hi )` のように末尾で閉じる書き方だと深さが戻らない
                        # ——この ci.yml も 1 行の部分シェルを使っており、その後ろに呼び出しを
                        # 足した瞬間に「配線されていない」と逆の診断で赤くなる（レビューで実測）。
                        # `$(foo)` のようなコマンド置換は開閉が揃うので差し引き 0 になる
                        # **`case` のパターン（`never)`）の `)` は部分シェルの閉じではない。**
                        # 数えてしまうと `case` が開いた深さがその場で打ち消され、
                        # 一致しないアームの中身が「最上位で実行される」と読まれる（レビューで実測）
                        paren_probe = text
                        if (case_depth > 0 && paren_probe ~ /^[^()]*\)([[:space:]]|;|$)/) {
                            sub(/^[^()]*\)/, "", paren_probe)
                        }
                        paren = paren_delta(paren_probe)
                        if (paren < 0) {
                            # 括弧で閉じる分も、階層ごとの印を見て戻す
                            for (closing = 0; closing < -paren && depth > 0; closing++) {
                                if (uncertain_at[depth]) { uncertain--; uncertain_at[depth] = 0 }
                                else if (group_start[depth] >= 1) { closed_group_start = group_start[depth] }
                                if (subshell_at[depth]) { subshell--; subshell_at[depth] = 0 }
                                group_start[depth] = -1
                                depth--
                            }
                        }
                        # **条件がその場で偽と分かるブロックの中身は、どの照会からも証拠にしない。**
                        # 深さで除くのは実行の照会だけなので、`if false; then shellcheck $LIST; fi` は
                        # リンタの照合（ステップの形を見る側）を素通りしてしまう——2 行で lint を止められる
                        # （実行の証拠にならないだけでなく、そもそも走らないので合否にも効かない。レビューで実測）
                        if (dead_depth >= 0 && depth <= dead_depth) { dead_depth = -1 }
                        # **直前の区切りも見る。** `true || bash x` / `false && bash x` は
                        # その場で偽と分かる条件なので、その断片は 1 度も走らない
                        # ——`|| true` より 1 トークン短くスイートを止められる（レビューで実測）
                        # **連鎖の途中で終わらせない。** `false && a && bash x` のように
                        # 2 つ先へ続く形でも、その先はすべて走らない（レビューで実測）。
                        # `;` や行末で連鎖が切れたら、そこで伝播も終わる
                        # **向きが変わる連鎖を取り違えない。** `false && echo mid || bash x` の
                        # `bash x` は走る（`&&` が外れた時点の状態は失敗なので `||` の右が動く）。
                        # 「直前が `||`／`&&` なら伝播を続ける」とだけ書くと、走る呼び出しを
                        # 「未配線」と事実と逆に診断して赤くする（レビューで実測）。
                        # 走らなかった断片は連鎖の状態を変えない（判定は最後に走った結果で決まる）
                        if (prev_op != "||" && prev_op != "&&") { unreachable = 0; chain_status = "" }
                        else if (prev_op == "&&") { unreachable = (chain_status == "f") }
                        else { unreachable = (chain_status == "t") }
                        if (!unreachable && dead_depth < 0) {
                            if (text == "true" || text == ":") { chain_status = "t" }
                            else if (text == "false") { chain_status = "f" }
                            else { chain_status = "" }
                        }
                        # ジョブの控えへ積む。**判定に要る材料（直後の区切り・`set` の明示・深さ）ごと**渡し、
                        # ゲートかどうかの結論はジョブが確定するときに出す
                        nbuf++
                        buf[nbuf] = step_id "\t" ops[j] "\t" ((dead_depth >= 0 || unreachable) ? 0 : errexit) "\t" pipefail "\t" uncertain "\t" text
                        # 偽と分かる条件のブロックに入るところを覚える（この深さより深い間は無効）
                        if (dead_depth < 0 && text ~ /^(if|while)[[:space:]]+false([[:space:]]|;|$)/) { dead_depth = depth }
                        else if (dead_depth < 0 && text ~ /^until[[:space:]]+true([[:space:]]|;|$)/) { dead_depth = depth }
                        # **grouping を閉じた断片に付いた区切りは、その中身すべてに掛かる。**
                        # `( bash x ) || true` は中の `bash x` も「失敗が伝わらない」——
                        # 中身だけを見ると区切りが無いので「ゲートしている」と読まれる（レビューで実測）
                        # **開いた断片そのものも中身になりうる。** `( bash x; ) || true` では
                        # `(` と呼び出しが同じ断片に載るので、控えた位置の**次**から書き換えると
                        # 呼び出しだけが取り残され、握り潰された実行が「ゲートしている」と読まれる
                        if (closed_group_start >= 0 && (ops[j] == "||" || ops[j] == "&" || ops[j] == "|")) {
                            for (k = closed_group_start; k <= nbuf; k++) {
                                split(buf[k], inner, "\t")
                                buf[k] = inner[1] "\t" ops[j] "\t" inner[3] "\t" inner[4] "\t" inner[5] "\t" inner[6]
                            }
                        }
                        # 次の断片から見た「直前」を控える
                        prev_op = ops[j]
                        # 開き側はこの断片の後ろから効く（`if` 自身は外側の階層にある）
                        # `case` の入れ子を数えておく（上のパターン判定に使う）
                        if (text ~ /^case([[:space:]]|$)/) { case_depth++ }
                        else if (text ~ /^esac([[:space:]]|;|$)/ && case_depth > 0) { case_depth-- }
                        # **「必ず走る入れ子」と「走るか分からない入れ子」を分ける。**
                        # `( … )` / `{ … }` の grouping と `if true` / `while true` の本体は必ず走るので、
                        # 中の `set +e` は効くし、中の呼び出しは実行の証拠になる。
                        # 一方 `if <条件>` / ループ / 関数定義の中身は、条件や呼び出し元を読まないと決まらない
                        # （両者を深さ 1 本で扱うと、grouping の中の呼び出しが「未配線」と誤報され、
                        #   通る分岐の `set +e` が握り潰しを隠す。どちらもレビューで実測）
                        if (text ~ /^(if|while)[[:space:]]+(true|:)([[:space:]]|;|$)/) { depth++ }
                        else if (text ~ /^(if|while|until|for|case|select)([[:space:]]|$)/) {
                            depth++; uncertain++; uncertain_at[depth] = 1
                        }
                        # bash の `function name { … }` 形式（`()` を伴わない綴り）も 1 階層開く
                        else if (text ~ /^function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*([[:space:]]*\{)?$/) {
                            depth++; uncertain++; uncertain_at[depth] = 1
                        }
                        # 関数定義は `{` を伴う形だけを開き側に数える。`f()` と次行の `{` を
                        # どちらも数えると 2 つ開いて 1 つしか閉じず、以降ずっと「入れ子の中」に見える
                        else if (text ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{$/) {
                            depth++; uncertain++; uncertain_at[depth] = 1
                        }
                        # **ブレースグループ（`cmd || { echo bad; exit 1; }`）も 1 階層開く。**
                        # 閉じ側の `}` だけを数えると深さが 1 つ足りなくなり、以降の断片が
                        # 「最上位」に見える——条件の中でしか走らない呼び出しが実行の証拠に化ける（レビューで実測）
                        # grouping（`{ … }` / `( … )`）は必ず走るので uncertain は増やさない。
                        # ただし**閉じたところに付く区切りは中身にも掛かる**ので、開始位置を控える
                        else if (text ~ /^\{([[:space:]]|$)/) { depth++; group_start[depth] = nbuf }
                        # 部分シェルの開き分（釣り合いの正側）を足す。
                        # **部分シェルであることを階層ごとに覚える**（中の `set` を外へ持ち出さない）
                        else if (paren > 0) {
                            for (closing = 0; closing < paren; closing++) {
                                depth++; group_start[depth] = nbuf
                                subshell_at[depth] = 1; subshell++
                            }
                        }
                    }
                }
            }
            # 次のステップに備えて溜めた内容を捨てる
            for (i = 1; i <= ncmd; i++) { delete cmds[i] }
            ncmd = 0
            step_disabled = 0
        }

        # 溜めた 1 ジョブ分を、ジョブ単位で止められていなければ出力する。
        # ステップ番号にジョブ名を冠するのは、呼び出し側が「どのジョブが実行するか」まで
        # 問えるようにするため（env は同じジョブからしか見えないので、ジョブを跨いだ
        # 分割は「配線されている」と答えてはいけない）
        function flush_job(   i, parts, shell_name, errexit_on, pipefail_on, gate) {
            # 未確定のステップをジョブの控えへ移してから判断する
            flush_step()
            # **env の記録は無効化に関わらず出す。** これは「何が実行されるか」ではなく
            # 「そのジョブがどんな変数を定義しているか」という構造の記述であり、
            # 止まっているジョブの定義を「定義が 0 件」と報告すると、
            # 一覧の書式が壊れたのか job が止まっているのかを取り違えた診断になる
            for (i = 1; i <= nenv; i++) { print jobname "#" envbuf[i] }
            # ジョブごと止められていなければ、コマンドの控えをまとめて出す。
            # **ここで初めて実効シェルが確定する**（ステップ自身の指定 > ジョブの既定 > ワークフローの既定）
            if (!job_disabled) {
                for (i = 1; i <= nbuf; i++) {
                    # 控えた 1 件を「ステップ番号・直後の区切り・errexit・pipefail・本文」に分ける
                    split(buf[i], parts, "\t")
                    # そのステップの実効シェルを決める
                    shell_name = (shells[parts[1]] != "") ? shells[parts[1]] : ((job_shell != "") ? job_shell : workflow_shell)
                    # `set` で明示されていなければシェルの既定に従う。既定（指定なし）と
                    # `bash` / `sh` は `-e` を含むが、自前テンプレートや `python` 等は含むとは限らない
                    errexit_on = (parts[3] == "-1") ? ((shell_name == "" || shell_name == "bash" || shell_name == "sh") ? 1 : 0) : (parts[3] + 0)
                    # `bash` キーワードは `-o pipefail` も含む
                    pipefail_on = (parts[4] == "-1") ? ((shell_name == "bash") ? 1 : 0) : (parts[4] + 0)
                    # 直後の区切りから、その失敗が job に伝わるかを決める
                    gate = 1
                    if (parts[2] == "||" || parts[2] == "&") { gate = 0 }
                    if (parts[2] == "|") { gate = pipefail_on }
                    if (!errexit_on) { gate = 0 }
                    # 断片は trim 済みでタブを含まないので、6 列目がそのまま本文
                    print jobname "#" parts[1] "\t" gate "\t" parts[5] "\t" parts[6]
                }
            }
            # 次のジョブに備えて控えと状態を捨てる
            for (i = 1; i <= nenv; i++) { delete envbuf[i] }
            nenv = 0
            for (i = 1; i <= nbuf; i++) { delete buf[i] }
            nbuf = 0
            # ステップごとのシェル指定はジョブをまたいで持ち越さない
            for (i in shells) { delete shells[i] }
            job_disabled = 0
            step_id = 0
        }

        # 無効化を表すキーかどうかを返す（コメント除去済みの行を渡すこと）。
        # **引用符と大文字小文字を先に正規化する**のが要点。YAML は引用符付きの偽を
        # 素の `if: false` と同じスカラーとして読み、GitHub Actions は `FALSE` / `False` も
        # 偽として評価する。素の綴りだけを見ると、**止めたステップが「実行されている」と読まれる**
        # ——本ライブラリが塞ぐと宣言している当の穴が、引用符 2 つで開く（レビューで実測）
        function is_disabling(t,   probe, value) {
            # 引用符を落とし、小文字に揃えた写しで判定する。YAML は引用符付きの偽を素の
            # `if: false` と同じスカラーとして読み、Actions は `FALSE` / `False` も偽として評価する
            probe = t
            gsub(/["\047]/, "", probe)
            probe = tolower(probe)
            # `if:` / `continue-on-error:` の行でなければ、そもそも無効化の話ではない
            if (probe !~ /^[[:space:]]*-?[[:space:]]*(if|continue-on-error):/) { return 0 }
            # 鍵を取り除いて値だけにする
            value = probe
            sub(/^[[:space:]]*-?[[:space:]]*(if|continue-on-error):[[:space:]]*/, "", value)
            value = trim(value)
            # **「止めていない」と確かめられる形だけを通し、残りはすべて無効化として扱う（fail-closed）。**
            # 値が式（`${{ … }}`）やブロックスカラー（`>-`）だと、その場では真偽を評価できない。
            # 評価できないものを「実行され、しかも合否に効く」と主張する資格はこのライブラリに無い
            # ——`action_pin_test.sh` が `permissions:` をブロックスカラーで書かれたとき特権側へ倒すのと同じ判断。
            # 逆に倒すと、`continue-on-error: ${{ … }}` の 1 行でゲートを外しながら全表明が緑のままになる（レビューで実測）
            if (probe ~ /^[[:space:]]*-?[[:space:]]*if:/) {
                # `if: true` だけが「止めていない」と言い切れる形
                return (value == "true") ? 0 : 1
            }
            # `continue-on-error: false` だけが「失敗が job に伝わる」と言い切れる形
            return (value == "false") ? 0 : 1
        }

        {
            # 判定に使う 1 行分の文字列を取り出し、CR を落とす
            line = $0
            sub(/\r$/, "", line)

            # 非構造行＝ブロックスカラーの本文。run: の本体か env の折りたたみブロックのときだけ拾う
            if (!structural[NR]) {
                if (in_run) {
                    # **ブロックスカラーの基準字下げは最初の非空行が決める**（YAML の規則）。
                    # bash が実際に受け取るのはこの分を落とした後の本文なので、
                    # ヒアドキュメントの終端判定もここを基準にする。
                    # **開いた行の桁を基準にすると落としすぎる**——`if …; then` の中など
                    # 基準より深い位置で開いたヒアドキュメントでは、本文中の字下げされた
                    # 区切り語まで終端と読み、以降の本文（＝ただのデータ）が実行と読まれる
                    # （issue #108 と同じ穴が入れ子の形で開く。レビューで実測）
                    # **字下げはスペースだけで測る。** YAML の字下げにタブは使えないので、
                    # 本文の先頭に現れたタブは字下げではなく**内容の一部**。これを字下げと
                    # 数えると後で落としすぎ、タブ字下げされた区切り語を終端と読む（実測）
                    if (run_base_indent < 0 && line ~ /[^[:space:]]/) {
                        run_base_indent = leading_spaces(line)
                    }
                    # **heredoc の本文はデータであってコマンドではない。**
                    # `cat <<EOF` … `bash test/x_test.sh` … `EOF` の中身を実行と読むと、
                    # ファイルへ書き出しているだけの文字列が「配線されている」証拠に化ける
                    # **待ち行列を先頭から 1 つずつ**終端させる。1 行が 2 つ以上開いたときは
                    # bash が本文を読むのと同じ順（開いた順）に消化する
                    if (hd_i <= hd_n) {
                        # 終端の行に来たら**その 1 つ**の本文の読み飛ばしを終える。判定は
                        # `heredoc_terminates` に集約してあり、**bash と同じく「区切り語だけの行」**
                        # だけを終端と認める。見つけられなければ「本文が続く」に倒れるので
                        # 判定は fail-closed 側に寄る。`<<-` かどうかは**その区切り語のもの**を渡す
                        if (heredoc_terminates(line, hd_dash[hd_i], run_base_indent, hd_word[hd_i])) {
                            hd_i++
                        }
                        next
                    }
                    text = trim(strip_comment(line))
                    # 折りたたみ本文なら直前の行に空白で繋ぎ、そうでなければ新しい 1 行として足す
                    if (text != "" && run_folded && ncmd > 0) { cmds[ncmd] = cmds[ncmd] " " text }
                    else if (text != "") { cmds[++ncmd] = text }
                    # この行が heredoc を開いていれば、終端までの本文を読み飛ばす。
                    # **開いた数だけ待ち行列に積む**——1 行に 2 つ以上書けるので、最後の 1 つ
                    # だけを覚えると先に読まれる本文が実行と読まれる（issue #111 (1)）。
                    # 区切り語の切り出し・引用の 3 綴り・`<<-` の別・here-string と算術式の
                    # 除外は、すべて `collect_heredocs` に集約してある
                    collect_heredocs(text)
                } else if (in_env) {
                    # **空白で区切って 1 エントリずつ**控える。折りたたみブロックは最終的に
                    # 1 本の空白区切り文字列になり、消費側（`shellcheck $SHELL_FILES` と
                    # `for f in $SHELL_FILES`）も空白で分割する。1 行 1 パスと決め打つと、
                    # 2 つを同じ行に書いた（消費側には何の影響も無い）だけで誤報する
                    text = trim(strip_comment(line))
                    nvalue = split(text, values, /[[:space:]]+/)
                    for (vi = 1; vi <= nvalue; vi++) {
                        if (values[vi] != "") { envbuf[++nenv] = "env\tval\t" env_var " " values[vi] }
                    }
                }
                next
            }

            # 構造行が来た時点で、直前のブロックスカラー本文は終わっている
            in_run = 0
            in_env = 0
            # 未消化の待ち行列も捨てる（構造行が来た時点で本文は終わっている）
            hd_n = 0
            hd_i = 1
            # コメントを落としてから構造を判定する
            # （`if: false  # 理由` のように理由を添えるのが最も自然な書き方なので、
            #   コメント付きを取りこぼすと「止めたステップが動いている」ことになる）
            probe = unquote_key(strip_comment(line))
            # 空になった行（コメントだけの行）は構造として扱わない
            if (trim(probe) == "") { next }
            # 字下げ幅を測る（入れ子の深さの判定に使う）
            indent = match(probe, /[^[:space:]]/) - 1

            # `env:` と同じかそれより浅い鍵が来たら、その env ブロックは終わっている。
            # **中に居る間の深さは env の桁を基準に測る**（`steps:` の桁を基準にすると、
            # `steps:` より後ろに書かれた `env:` の中身が「ステップの鍵」に見えて読み落とす）
            if (env_indent >= 0 && indent <= env_indent) { env_indent = -1 }
            # 同じ理由で `defaults:` ブロックも、同じか浅い桁の鍵が来たら終わっている
            if (defaults_indent >= 0 && indent <= defaults_indent) { defaults_indent = -1 }

            # **`jobs:` と同じかそれより浅い鍵が来たら、jobs マッピングの外に出ている。**
            # ここでジョブの解釈を閉じないと、`jobs:` の後ろに置かれたトップレベルの
            # `defaults:` の中の `run:` が「run という名前の新しいジョブ」に見え、
            # 直前のジョブが確定されたうえで既定シェルも読めなくなる（レビューで実測）
            if (jobs_indent >= 0 && job_indent >= 0 && indent <= jobs_indent) {
                flush_job()
                # **`jobs:` の位置も忘れる。** 覚えたままだと、`jobs:` の後ろに置かれた
                # 別のトップレベルのブロックの中身が新しいジョブとして読まれ、
                # `jobs:` の外にある `run:` が「CI が実行するコマンド」として記録される（レビューで実測）
                jobs_indent = -1
                job_indent = -1
                steps_indent = -1
                step_dash_indent = -1
                step_key_indent = -1
                env_indent = -1
            }

            # ダッシュだけの行で始まったステップは、次に現れた鍵の桁をステップの鍵の桁とする
            if (step_dash_indent >= 0 && step_key_indent < 0 && indent > step_dash_indent) {
                step_key_indent = indent
            }

            # ジョブに入って最初に現れた鍵の桁を、そのジョブ直下の鍵の桁として覚える
            if (job_indent >= 0 && job_key_indent < 0 && indent > job_indent) { job_key_indent = indent }

            # `jobs:` の位置を覚える
            if (jobs_indent < 0 && probe ~ /^[[:space:]]*jobs:[[:space:]]*$/) { jobs_indent = indent; next }

            # ジョブ名の行（`jobs:` より深く、かつ最初に見つけた深さと同じ）が新しいジョブの始まり
            if (jobs_indent >= 0 && indent > jobs_indent && probe ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*$/ \
                && (job_indent < 0 || indent == job_indent)) {
                # **前のジョブをここで確定させて出力する**（次のジョブの無効化キーを被せない）
                flush_job()
                job_indent = indent
                # ジョブ名を控える（末尾のコロンを落とした識別子がそのまま名前）
                jobname = trim(probe)
                sub(/:$/, "", jobname)
                # 次に現れる鍵の桁が、このジョブ直下の鍵の桁になる
                job_key_indent = -1
                steps_indent = -1
                step_dash_indent = -1
                step_key_indent = -1
                env_indent = -1
                defaults_indent = -1
                job_shell = ""
                next
            }

            # `steps:` の位置を覚える（以降の同じ深さのダッシュがステップの区切り）。
            # **ジョブ直下の `steps:` だけを見る**——`with:` の下に `steps:` という名前の入力があると、
            # そこを新しいステップの並びと読み、入れ子の `- run:` が実行として拾われる（レビューで実測）
            if (job_indent >= 0 && indent > job_indent && probe ~ /^[[:space:]]*steps:[[:space:]]*$/ \
                && (steps_indent < 0 || key_scope(probe, indent) == "job")) {
                steps_indent = indent
                step_dash_indent = -1
                next
            }

            # `defaults:` ブロックの開始。ワークフロー直下なら全ジョブ、ジョブ直下ならそのジョブの既定。
            # **ステップの `shell:` だけを見ても網は閉じない**——`defaults: run: shell: bash {0}` を
            # 3 行足せば全ステップから `-e` が消え、どのステップも自分では `shell:` を書いていない
            # ので「既定どおり」と読まれてしまう（レビューで実測）
            # **ステップの中の `defaults` は別物**（action への入力や env の名前でありうる）。
            # 桁で見分けないと、`with: defaults: enabled` の 1 行でそのジョブ全体が
            # 合否の証拠から外れ、すべてのスイートが「配線されていない」と誤報される
            if (probe ~ /^[[:space:]]*defaults:/ && key_scope(probe, indent) == "job") {
                # ジョブに入った後のジョブ直下ならそのジョブ限定、それ以外はワークフロー全体
                defaults_scope = (job_indent >= 0 && indent > job_indent) ? "job" : "workflow"
                # ワークフロー直下のものは BEGIN の先読みが既に拾っているので、ここでは触らない
                if (defaults_scope == "workflow") { next }
                if (probe ~ /^[[:space:]]*defaults:[[:space:]]*$/) {
                    # ブロック形式。以降の深い行から `shell:` を読む
                    defaults_indent = indent
                } else {
                    # **フロー形式（`defaults: {run: {shell: bash {0}}}`）は 1 行に畳まれていて、
                    # 中の `shell:` を構造行として読めない。** 確かめられない以上「既定どおり
                    # `bash -e` で走る」とは主張できないので、未知のシェル扱いにして
                    # そのジョブ（またはワークフロー全体）の実行を合否の証拠から外す
                    job_shell = "?"
                }
                next
            }

            # `defaults:` の中の `run:` がフロー形式（`run: {shell: bash {0}}`）なら、
            # 中の `shell:` は構造行として現れない。確かめられない以上は未知のシェル扱いにする
            # （ブロック形式だけを見ていると、2 行で全ステップから `-e` を外せる。レビューで実測）
            if (defaults_indent >= 0 && indent > defaults_indent \
                && probe ~ /^[[:space:]]*run:[[:space:]]*[^[:space:]]/) {
                # `defaults_indent` はジョブ直下の `defaults:` でしか立たない
                # （ワークフロー直下は BEGIN の先読みが持つ）ので、ここは常にジョブ側
                job_shell = "?"
                next
            }

            # `defaults:` の中に書かれた `shell:` を既定として控える
            if (defaults_indent >= 0 && indent > defaults_indent \
                && probe ~ /^[[:space:]]*shell:[[:space:]]*[^[:space:]]/) {
                shell_value = read_shell_value(probe)
                # 適用範囲に応じて控え先を分ける（ジョブ側はジョブが変わればリセットされる）
                job_shell = shell_value
                next
            }

            # ジョブ直下の `env:` の位置を覚える（この下の折りたたみブロックがそのジョブの変数）
            # **`steps:` の後ろに書かれていても読む。** YAML のキー順は自由なので `env:` を後ろへ
            # 動かすのは意味を変えない整形だが、読み落とすと「定義 0 件」＝一覧が壊れたという
            # 事実と違う診断で落ちる。ステップ自身の `env:`（より深い桁）とは桁で見分ける
            if (job_indent >= 0 && indent > job_indent && key_scope(probe, indent) == "job" \
                && probe ~ /^[[:space:]]*env:[[:space:]]*$/) {
                env_indent = indent
                next
            }

            # `env:` の下の折りたたみブロック（`NAME: >-` / `NAME: |`）の開始。
            # **どのジョブの env かまで控える**のが要点で、変数は定義したジョブからしか見えない。
            # 一覧だけを合流させて読むと、別のジョブへ移された一覧が「載っている」と見える一方、
            # lint するジョブから見た `$SHELL_FILES` は空になる（レビューで実測）
            if (env_indent >= 0 && indent > env_indent \
                && probe ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*[|>]([0-9]*[+-]?|[+-]?[0-9]*)[[:space:]]*$/) {
                # 変数名を取り出す（コロンより前が名前）
                env_var = trim(probe)
                sub(/:.*$/, "", env_var)
                # 定義が現れたこと自体を 1 件として控える（定義箇所の数はこれで数えられる）
                envbuf[++nenv] = "env\tdef\t" env_var
                # 以降の非構造行がこの変数の値
                in_env = 1
                next
            }

            # ステップの区切り（`steps:` の下で最初に現れたダッシュと**同じ字下げ**のダッシュ）
            if (steps_indent >= 0 && probe ~ /^[[:space:]]*-([[:space:]]|$)/) {
                # 最初のダッシュの字下げを、このジョブのステップの基準にする
                if (step_dash_indent < 0) { step_dash_indent = indent }
                # 基準と同じ深さのときだけ新しいステップとして扱う（入れ子の並びでは切らない）
                if (indent == step_dash_indent) {
                    flush_step()
                    step_id++
                    # **ステップ自身の鍵が並ぶ桁**を覚える（`- ` の直後の桁）。
                    # `run:` をこの桁に限らないと、`with:` の下に書かれた `run:` という
                    # **action への入力**まで「実行されるコマンド」として拾う（レビューで実測）
                    # **鍵がダッシュと同じ行にあるとは限らない。** `-` だけの行で始めるのも
                    # 正当な YAML で、その場合は次に現れた鍵の桁がステップの鍵の桁になる
                    if (probe ~ /^[[:space:]]*-[[:space:]]*$/) {
                        step_key_indent = -1
                    } else {
                        match(probe, /^[[:space:]]*-[[:space:]]+/)
                        step_key_indent = RLENGTH
                    }
                }
            }

            # 無効化キーの扱いは、ステップの中かジョブ直下かで宛先が変わる。
            # **判定は「ジョブの鍵と同じ桁か」で行う。** ダッシュの桁との比較で決めると、
            # `steps:` と `- name:` を同じ桁に書く（YAML として等しく正しい）書式のとき、
            # ジョブ直下の鍵がステップの鍵と同じ深さになり、**ジョブ全体を止めるキーが
            # 最後の 1 ステップしか止めない**（レビューで実測。round 11 で塞いだはずの形が書式違いで開く）
            if (is_disabling(probe)) {
                scope = key_scope(probe, indent)
                # ステップ自身の鍵ならそのステップだけを止める
                if (scope == "step") { step_disabled = 1 }
                # ジョブ直下ならそのジョブの全ステップが対象
                else if (scope == "job") { job_disabled = 1 }
                # 入れ子の中身（action への入力など）はワークフローの制御ではないので何もしない
                next
            }

            # ここから先は run: の取り出し。ステップの中でなければ関係ない
            if (step_dash_indent < 0) { next }

            # ステップ自身の鍵でない `run:` / `shell:`（`with:` 配下の入力など）は実行の指定ではない。
            # ダッシュ始まりを無条件に通すと、入れ子の並びの `- run:` が実行として拾われる（レビューで実測）
            if (key_scope(probe, indent) != "step") { next }

            # **そのステップがどのシェルで走るかを控える。** 既定（Linux）は `bash -e {0}` なので
            # コマンドが落ちればステップも落ちるが、`shell: bash {0}` のように**テンプレートを
            # 自分で書くと `-e` が消える**——ループの途中の失敗が握り潰され、最後の 1 回の結果だけが
            # ステップの成否になる。1 行足すだけでリンタがゲートでなくなる形なので、
            # 確かめられない綴りは「合否に効かない」側へ倒す（fail-closed）
            if (probe ~ /^[[:space:]]*-?[[:space:]]*shell:[[:space:]]*[^[:space:]]/) {
                shells[step_id] = read_shell_value(probe)
                next
            }

            # `run: |` / `run: >` のブロック開始。以降の非構造行が本体
            if (probe ~ /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[|>]/) {
                in_run = 1
                # **明示字下げ指示子（`run: |2`）があれば、基準字下げはそちらが決める。**
                # YAML では指示子の数値が「親ノードの字下げからの相対桁」を表すので、
                # 本文をそれより深く書くと**深い分は内容の一部として残る**。
                # 最初の非空行から決めると、その残る分まで字下げと見なして落としすぎ、
                # 本文中の字下げされた区切り語を終端と読む（＝本文が実行と読まれる。実測）
                scalar_head = probe
                sub(/^.*run:[[:space:]]*/, "", scalar_head)
                # **指示子はヘッダの形に錨を打って読む。** `run:` の後ろから数字を拾い集めると、
                # ヘッダの綴りが少しでも緩んだ瞬間に無関係な数字が指示子に化ける
                # （`run: | # issue 108` → 基準字下げ 108 桁 → 字下げを丸ごと落として
                #   どんな深さの区切り語も終端になる＝ issue #108 が開き直る）。
                # 認めるのは `|` / `>` の直後（chomping 記号は前後どちらでもよい）に来た数字だけ
                if (match(scalar_head, /^[|>][+-]?[0-9]/)) {
                    sub(/^[|>][+-]?/, "", scalar_head)
                    sub(/[^0-9].*$/, "", scalar_head)
                } else {
                    scalar_head = ""
                }
                if (scalar_head != "") {
                    # 親ノードの桁は鍵の桁。`- run: |2` のようにダッシュが付く場合は
                    # その分を進めた位置が鍵の桁になる（`- ` の桁で測ると浅く出る）
                    run_base_indent = (match(probe, /^[[:space:]]*-[[:space:]]+/) ? RLENGTH : indent) + scalar_head
                } else {
                    # 指示子が無ければ、基準字下げは最初の非空行が決める（未確定は -1）
                    run_base_indent = -1
                }
                # **`>` は「折りたたみ」で、本文の改行は空白に畳まれて 1 つのコマンドになる。**
                # 1 行ずつ別のコマンドとして読むと、次の行に置かれた `|| true` が
                # 呼び出しと結び付かず、握り潰された実行を「ゲートしている」と読む（レビューで実測）。
                # 段落の区切り（空行）まで再現はしないので、そこでも繋いだ結果は
                # 「握り潰されている」側＝より安全な方に倒れる
                run_folded = (probe ~ /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*>/)
                next
            }

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
        # 最後のジョブ（とその最後のステップ）を取りこぼさない
        END { flush_job() }
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

# **合否に効くコマンドだけ**を `<ジョブ名>#<ステップ番号><TAB><コマンド>` の形で書き出す。
# 第 1 引数はジョブ名の絞り込み（空文字列なら全ジョブ）。
#
# ここを 1 か所に持つ理由は、照会が 3 つ（コマンド単位・ステップ単位・スクリプトの実行）あり、
# **「ゲートに効くか」の判定を写すと片方だけが古くなる**ため。実際、`|| true` を弾く判定は
# スクリプト実行の照会にしか入っておらず、リンタ側は `shellcheck $SHELL_FILES || true` を
# 「動いている」と読んだまま緑で通っていた（レビューで実測）
ci_workflow_gating_commands() {
    # 絞り込むジョブ名（空なら絞り込まない）
    local job_filter="${1-}"
    # 第 2 引数に `top` を渡すと、制御構造（`if` / ループ / 関数）の**中**にある断片を除く。
    # 「本当に実行されるか」を問う照会（スクリプトの実行）はこれを使う——中身が走るかは
    # 条件や呼び出し元を読まないと決まらないため。一方でリンタの形を見る照会は
    # `for … do bash -n "$f"` のようにループの**中**を見たいので、除かない
    local top_only="${2-}"
    # 走査中の 1 行・`ジョブ名#ステップ番号`・ゲートに効くかの印・制御構造の深さ・コマンド本文
    local record key gate depth text
    while IFS= read -r record; do
        # 1 行を「キー」「ゲート印」「深さ」「本文」の 4 列に分ける
        key="${record%%$'\t'*}"
        record="${record#*$'\t'}"
        gate="${record%%$'\t'*}"
        record="${record#*$'\t'}"
        depth="${record%%$'\t'*}"
        text="${record#*$'\t'}"
        # 失敗が job に伝わらないコマンドは、実行の証拠として数えない
        [ "${gate}" = "1" ] || continue
        # 最上位だけを求められていれば、制御構造の中は除く
        [ "${top_only}" != "top" ] || [ "${depth}" = "0" ] || continue
        # ジョブの絞り込みが指定されていれば、そのジョブのものだけを通す
        [ -z "${job_filter}" ] || [ "${key%%#*}" = "${job_filter}" ] || continue
        # 呼び出し側が読む形（キーと本文）で書き出す
        printf '%s\t%s\n' "${key}" "${text}"
    done < "${CI_WORKFLOW_COMMANDS}"
}

# ジョブ直下の `env:` に折りたたみブロックで書かれた変数の記録を読み出す。
# 第 1 引数が種別（`def` = 定義箇所 / `val` = 値のエントリ）、第 2 引数が変数名。
# `def` はその定義があるジョブ名を、`val` はエントリを 1 行 1 件で出す。
#
# **ワークフローを読むのはこのライブラリだけにする**ための関数。呼び出し側が独自に
# 一覧ブロックを探すと YAML の解析器が 2 つになり、`run: |` の本文に同じ見た目の行が
# あったときに片方だけが食い付く（本ライブラリを切り出した理由と同じ）
ci_workflow_env_records() {
    # 読み出す種別と変数名を受け取る
    local kind="$1" name="$2"
    # 走査中の 1 行・`ジョブ名#env` のキー・種別の列・本文
    local record key column text
    while IFS= read -r record; do
        # 1 行を「キー」「種別」「本文」の 3 列に分ける
        key="${record%%$'\t'*}"
        record="${record#*$'\t'}"
        column="${record%%$'\t'*}"
        text="${record#*$'\t'}"
        # 求められた種別の行でなければ読み飛ばす
        [ "${column}" = "${kind}" ] || continue
        # 定義箇所の記録なら、変数名が一致したときにジョブ名を返す
        if [ "${kind}" = "def" ]; then
            [ "${text}" = "${name}" ] && printf '%s\n' "${key%%#*}"
            continue
        fi
        # 値の記録は `<変数名> <エントリ>` の形なので、名前を確かめてからエントリだけを返す
        [ "${text%% *}" = "${name}" ] && printf '%s\n' "${text#* }"
    done < "${CI_WORKFLOW_COMMANDS}"
}

# 合否に効くコマンドのうち **1 つが** 渡したすべての正規表現に一致するかを返す。
# 第 1 引数はジョブ名の絞り込み（空文字列なら全ジョブ）、以降が正規表現。
# 照合は bash 組み込みの `[[ =~ ]]`（ERE）で行う。1 行 1 パターンごとに `grep` を起動すると、
# 現状の ci.yml でも 1 回の照会で百数十プロセスを生む（挙動は同じで費用だけ違う）。
#
# 読み出しはプロセス置換だが、ここで隠れる失敗は無い——`ci_workflow_gating_commands` が
# 失敗しうるのは保存先が読めないときだけで、それは `ci_workflow_load` が既に確かめている。
# かつ出力が空なら一致 0 件＝この関数は非ゼロを返すので、結論は fail-closed に倒れる
ci_workflow_command_matches() {
    # 絞り込むジョブ名を取り出し、残りをパターンとして扱う
    local job_filter="${1-}"
    shift
    # 走査中の 1 行・コマンド本文・当てるパターン・全一致したかの目印
    local record text pattern matched_all
    while IFS= read -r record; do
        # 行頭のキーとタブを落として、コマンド本文だけにする
        text="${record#*$'\t'}"
        # そのコマンドがすべてのパターンを満たすかを確かめる
        matched_all=1
        for pattern in "$@"; do
            # 1 つでも外れたらこのコマンドは候補から外す
            [[ "${text}" =~ $pattern ]] || { matched_all=0; break; }
        done
        # すべて満たすコマンドが見つかれば成功
        [ "${matched_all}" -eq 1 ] && return 0
    done < <(ci_workflow_gating_commands "${job_filter}")
    # 最後まで見つからなければ失敗
    return 1
}

# **1 ステップの中で**（行はまたいでよい）渡したすべての正規表現に一致するかを返す。
# 第 1 引数はジョブ名の絞り込み（空文字列なら全ジョブ）、以降が正規表現。
# `for f in $SHELL_FILES` と `bash -n "$f"` のように、2 行で 1 つの意味を成す形のため
ci_workflow_step_matches() {
    # 絞り込むジョブ名を取り出し、残りをパターンとして扱う
    local job_filter="${1-}"
    shift
    # 各パターンがどのステップで見つかったかを記録する
    local -A hits=()
    # 走査中の 1 行・ステップのキー・コマンド本文・当てるパターン・何番目のパターンかの目印
    local record step text pattern index
    while IFS= read -r record; do
        # ステップのキーとコマンド本文に分ける
        step="${record%%$'\t'*}"
        text="${record#*$'\t'}"
        # パターンを順に当てる
        index=0
        for pattern in "$@"; do
            index=$((index + 1))
            # 一致したら「このステップでこのパターンが見つかった」と印を付ける
            [[ "${text}" =~ $pattern ]] && hits["${step}:${index}"]=1
        done
    done < <(ci_workflow_gating_commands "${job_filter}")

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

# 指定したスクリプトを実行し、**その結果がジョブの合否に効く** `run:` ステップがあるかを返す。
#
# **「コマンドの位置に現れること」まで見る**のが要点。パスが行のどこかに現れるだけで良しとすると、
# `echo "skipping bash test/foo_test.sh until the flake is fixed"` や `ls -l test/foo_test.sh` が
# 「実行している」と読まれる——実行をやめた当のコミットが緑で通る。
#
# **失敗が握り潰された呼び出しも数えない。** `bash test/x_test.sh || true` / 末尾の `&` /
# `pipefail` の無いパイプ / `set +e` の下は、いずれもスイートを走らせはするが
# **落ちても job を止めない**。効果は `continue-on-error: true` と同じで、しかも 1 トークン足すだけで済む
# （このライブラリのヘッダが「削除より足す方が見落としやすい」と言っている当の形。レビューで実測）。
# 判定そのものは `ci_workflow_gating_commands` が持ち、ここは「コマンドの位置に現れるか」だけを見る。
#
# 第 1 引数がスクリプトのパス、第 2 引数（省略可）が絞り込むジョブ名。
#
# 一方で呼び出しの書き方の揺れ（`bash -x path` / `bash ./path` / `bash "path"` /
# `FOO=1 bash path` / `timeout 300 bash path` / 実行権限に頼った `./path`）は吸収する。
# **条件部（`if ! bash path` など）は吸収しない**——下の `wrapper` の説明のとおり、
# 条件に置かれたコマンドは落ちても job を止めないため。厳密な `bash <path>` だけを認めると、
# 意味の変わらない書き換えで「どこからも呼ばれていない」という事実と逆の診断とともに赤くなる
ci_workflow_runs_script() {
    # パスを正規表現リテラルとしてエスケープする
    local escaped
    escaped="$(ci_workflow_regex_escape "$1")"
    # 第 2 引数があればそのジョブに絞り込む（省略時は全ジョブ）
    local job_filter="${2-}"

    # 実行を許すオプションの綴り。短いまとめ書き（`-x` / `-eu`）は **n を含まないもの**だけ——
    # `-n` / `-nx` は構文を見るだけで実行しない。長いオプション（`--norc` 等）は許すが、
    # `--noexec` は下で別に弾く（`n` を含む長オプションを一律に拒むと `--norc` が誤って赤くなる）
    # `-o pipefail` のように**引数を取るオプション**も 1 つの綴りとして認める。
    # 認めないと、`bash -euo pipefail test/x_test.sh` のように厳しくしただけの書き換えで
    # 「どこからも呼ばれていない」と事実と逆の診断で赤くなる（レビューで実測）
    local option='(--[a-zA-Z0-9][a-zA-Z0-9-]*|-[a-mo-zA-MO-Z0-9]*o[[:space:]]+[a-z]+|-[a-mo-zA-MO-Z0-9]+)'
    # **区切りで切られた断片の先頭**がコマンドの開始位置（`;` `&&` `||` `|` `&` は分割済み）。
    # 環境変数の前置きは読み飛ばし、**実行ラッパの語も許す**: `timeout 300 bash x` /
    # `sudo bash x` はどれも終了コードをそのまま通す書き方で、認めないと
    # 「どこからも呼ばれていない」と事実と逆の診断で赤くなる
    # （この repo の e2e も `timeout 5 bash -c …` を使っている）。
    # 許すのは**終了コードをそのまま通す実行ラッパだけ**——`echo` / `ls` を許すと言及が実行に化ける。
    # **制御構文の語は 1 つも許さない。** `if bash x; then …` の判定に置かれたコマンドは落ちても
    # `set -e` を発動させず job も止めないし、`if false; then bash x; fi` に至っては 1 度も走らない
    # のに `then` を許すと「実行されている」と読まれる（2 語足すだけでスイートを止められる。レビューで実測）。
    # 条件やループの本体に置いた呼び出しがゲートになるかは、その本体が何をするかを読まないと決まらない
    # ——読めない以上は主張しない（fail-closed。現行 ci.yml はどのスイートも素の `run: bash …` で呼ぶ）
    # コマンドの開始位置の綴りは 1 か所（`CI_WORKFLOW_COMMAND_START`）に置いてある
    # パスの直後は空白（引数・リダイレクトが続く）か `)` か断片の終わり。
    # **直後の演算子までここで見ようとしない**のが要点で、`bash x 2>&1 | tee log` のように
    # 間にリダイレクトが 1 つ入るだけで「握り潰し」の判定が外れる。
    # 失敗が job に伝わるかは断片の区切り（`ci_workflow_gating_commands` が渡す印）が答える
    # パスの前に付く**ワークスペース由来の接頭辞**（`$GITHUB_WORKSPACE/` / `${GITHUB_WORKSPACE}/` /
    # `${{ github.workspace }}/` / `./`）だけを許す。この ci.yml が既に
    # `"$GITHUB_WORKSPACE/bin/aidock"` の形を使っており、認めないと同じ書き方へ揃えた瞬間に
    # 「どこからも呼ばれていない」と事実と逆の診断で赤くなる。
    # **変数一般に広げない**——`\$HOME/test/x_test.sh` や `\$FIXTURE_DIR/test/x_test.sh` は
    # 同じ名前の**別のファイル**を指しうるので、それを配線の証拠にしてはいけない
    # （リテラルのディレクトリを許さないのと同じ理由。レビューで実測）
    local base='([$]GITHUB_WORKSPACE/|[$][{]GITHUB_WORKSPACE[}]/|[$][{][{][[:space:]]*github\.workspace[[:space:]]*[}][}]/|\./)?'
    local invocation="${CI_WORKFLOW_COMMAND_START}(bash([[:space:]]+${option})*[[:space:]]+)?[\"']?${base}${escaped}[\"']?([[:space:]]|[)]|\$)"

    # 合否に効くコマンドだけを見る（`|| true` や `set +e` の下にあるものは渡ってこない）
    local record text
    while IFS= read -r record; do
        # キーを落としてコマンド本文だけにする
        text="${record#*$'\t'}"
        # コマンドの位置に現れていなければ対象外
        [[ "${text}" =~ $invocation ]] || continue
        # `--noexec` と `-o noexec`（`-n` の別綴り）は構文を見るだけなので実行の証拠にならない
        [[ "${text}" =~ (^|[[:space:]])(--noexec|-[a-zA-Z]*o[[:space:]]+noexec)([[:space:]]|$) ]] && continue
        # ここまで来れば「実行され、その結果が job の合否に効く」と言える
        return 0
    done < <(ci_workflow_gating_commands "${job_filter}" top)
    # 最後まで見つからなければ失敗
    return 1
}
