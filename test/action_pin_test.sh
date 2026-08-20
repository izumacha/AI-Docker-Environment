#!/usr/bin/env bash
# action_pin_test.sh - enforces FR-9.6(b): every action used by a privileged
# workflow is pinned immutably, and every SHA pin anywhere under
# .github/workflows/ still resolves to the release named by its `# vX.Y.Z`
# marker.
#
# Why this exists: FR-9.6(b) pins the actions used by the privileged
# post-ci-verify job (pull-requests: write + CLAUDE_CODE_OAUTH_TOKEN) to full
# commit SHAs, and names the trailing marker as the single source of truth for
# which release each SHA is. That only means something if the two actually
# agree -- and nothing enforced it. The pin and the marker are edited by
# different actors (Dependabot rewrites both together; a human bumping by hand
# can easily touch one and not the other), so a marker naming a different
# release than the SHA would sail through CI green. The next person to audit
# the pin then follows the documented procedure correctly, gets a mismatch
# against a perfectly good SHA, and is pushed toward the exact failure FR-9.6
# exists to prevent: "correcting" a sound pin, or distrusting it.
#
# Everything here is shaped by one recurring failure: absence reading as
# compliance. Successive drafts of this script each passed something they
# should have caught, because the thing to catch had dropped out of the set
# being looked at -- an action reverted to `@v1` stopped matching a "find the
# SHA pins" pattern; a newly added action was not on a list of known action
# names; a `docker://` step has no `@` to match; a brand-new privileged
# workflow was not on a list of known filenames. So the checks here are
# written to enumerate obligations, not sightings:
#
#   - privilege is DERIVED from each workflow's own permissions/secrets, not
#     from a filename list, and a workflow with no explicit `permissions:` is
#     treated as privileged (the repository default may grant write);
#   - EVERY `uses:` in a privileged workflow must be immutably pinned, whatever
#     its form, so a new unpinned entry is a failure rather than a non-match;
#   - a privileged workflow that goes missing, or yields no `uses:` at all, is
#     a failure rather than a quiet zero.
#
# Non-privileged workflows (ci.yml) are outside FR-9.6(b), which scopes the
# pinning duty to the privileged job -- ci.yml legitimately uses mutable tags
# such as actions/checkout@v7. Any SHA pin found there is still marker-checked
# as defence in depth, but pinning is not required.
#
# This closes the gap the same way test/guard_test.sh covers SEC-8 and
# test/entrypoint_test.sh covers SEC-13 -- by making the invariant a CI
# assertion rather than a documented intention. It doubles as tamper
# detection: if an upstream force-moves a release tag away from the commit we
# pinned, this fails instead of going unnoticed.
#
# Not hermetic: resolving a tag requires reaching the upstream repository, so
# unlike the other suites this one needs network. Resolution failure is a
# FAILURE, never a skip -- a supply-chain check that quietly passes when it
# cannot verify anything is worse than none.

# エラー発生時に即座に停止し、未定義変数の参照もエラーにする（安全なスクリプト実行の基本設定）
set -euo pipefail

# このスクリプト自身が置かれているディレクトリの絶対パスを取得する
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# リポジトリのルートディレクトリ（SCRIPT_DIR の一つ上）を絶対パスで求める
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
# 検査対象となるワークフロー定義の置き場所を決める
WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"

# ci.yml の構造読み取り（ブロックスカラー本文を構造と読み違えない `emit_structural_lines` と、
# 「その run: ステップが実際に何を実行するか」の判定）は共有ライブラリに置いてある。
# 同じ問いを複数のスイートが持つため、写しを増やさず 1 実装を共有する（§6）
# shellcheck source=test/lib/ci_workflow.sh
source "${SCRIPT_DIR}/lib/ci_workflow.sh"

# 必ず特権として扱うワークフローの下限リスト（自動判定が取りこぼしても検査を緩めないための保険）。
# 通常はファイル内容からの判定で足りるが、FR-9.6(b) が名指しする本体だけは明示的に固定する
ALWAYS_PRIVILEGED=(
    "post-ci-verify.yml"
)

# 上流への問い合わせが応答しないまま CI の実行枠を食い潰さないよう、1 回あたりの制限時間を秒で決める
LS_REMOTE_TIMEOUT_SECONDS=30
# 一時的な通信断で必須ジョブが赤くなるのを避けるため、到達不能時のみ再試行する回数
LS_REMOTE_ATTEMPTS=3

# 成功したチェックの件数を数えるカウンタ
PASS=0
# 失敗したチェックの件数を数えるカウンタ
FAIL=0

# 特権判定の回帰ケース用に、仮のワークフローを置く一時ディレクトリを 1 つだけ作る
TEST_TMP="$(mktemp -d)"
# 途中で中断された場合も含め、終了時に必ず一時ディレクトリを片付ける（他のテストスイートと同じ流儀）
# **素の `rm` にしない**: EXIT トラップの本体も `set -e` の対象で、削除に失敗すると
# その終了コードが**成功した実行を乗っ取り**、1 件も失敗していないのに赤くなる
trap 'rm -rf "${TEST_TMP}" || true' EXIT
# 仮のワークフローに連番の名前を付けるためのカウンタ
FIXTURE_SEQ=0

# 1 件の検査に成功したときの共通処理（合格を表示して成功数を増やす）
pass() {
    # 合格した内容を「ok   - ...」の形式で表示する
    printf 'ok   - %s\n' "$1"
    # 成功件数を 1 つ増やす
    PASS=$((PASS + 1))
}

# 1 件の検査に失敗したときの共通処理（失敗理由を表示して失敗数を増やす）
fail() {
    # 失敗した内容を「FAIL - ...」の形式で表示する
    printf 'FAIL - %s\n' "$1"
    # 補足の説明文が渡されていれば、字下げして続けて表示する
    [[ $# -ge 2 ]] && printf '       %s\n' "$2"
    # 失敗件数を 1 つ増やす
    FAIL=$((FAIL + 1))
}

# ワークフローの構造を 1 度だけ走査し、特権の根拠が本文にあるかどうかを調べる関数
# 第 1 引数: ワークフローファイルのパス
# 判定を必ず標準出力へ出す（`privileged` = 特権の根拠がある / `read-only` = 根拠が無い）。
#
# 見るのは次の 2 つで、どちらも「YAML の構造としてその位置に置かれているか」で判定する:
#   - `permissions:` の宣言が `read` / `none` 以外の権限を 1 つでも与えているか
#   - `secrets:` を鍵に持つ行があるか（reusable workflow への `inherit` と、名前を挙げるブロック形式）
# 2 つを同じ走査にまとめてあるのは、どちらも**ブロックスカラー（`run: |` 等）の本文を
# 構造と読み違えない**という同じ前提を必要とするため。行単位の grep では字下げを追えないので、
# `run:` の本文にたまたま `permissions: write-all` と書いただけで特権と誤判定し、
# **意図的に可変タグを使っている `ci.yml`** を違反扱いにして CI を恒常的に赤くしてしまう（実測）。
#
# **無出力を「根拠なし」と読み替えない**のが要点: awk 自体が異常終了した場合や、POSIX 文字クラスを
# 解釈できない awk に当たった場合に無出力になるため、「何も出なかった＝合格」にすると解析の失敗が
# そのまま特権判定の取りこぼしに化ける（このファイルが繰り返し踏んだ「不在＝合格」）。
# 呼び出し側は `read-only` と明示されたときだけ非特権と判断する。
#
# 権限は「write という文字列を探す」のではなく「read / none 以外が 1 つでもあるか」で見る。
# GitHub Actions は同じ許可を何通りにも書けるため（`write-all` / フロー形式 `{contents: write}` /
# 行末コメント付き `contents: write  # 説明`）、write の綴りを直接探す方式は書き方を変えるだけで
# すり抜ける（issue #87 で 3 形態すべての取りこぼしを実測）。解釈できない書き方に出会った場合も
# 「読めなかった＝合格」ではなく特権に倒す（このファイル全体を貫く fail-closed の方針）。
scan_workflow_structure() {
    # 検査対象のファイルパスを、呼び出し側の変数に依存しないよう自前の変数へ取り出す
    local path="$1"

    # YAML を 1 行ずつたどり、`permissions:` の値（同一行のスカラー／フロー形式／続く字下げブロック）を解釈する。
    # 引用符の文字集合は awk の変数として渡す（awk のプログラムはシェルの単一引用符で囲まれており、
    # その中に `'` を直接書けないため）
    emit_structural_lines "$path" | awk -v quote_chars='["'"'"']' '
        # ブロック形式の `permissions:` を読んでいる最中かどうか、結論を出したかどうか、
        # そして構造行を 1 行でも受け取ったかどうかを表す旗
        BEGIN { in_block = 0; block_indent = 0; decided = 0; seen = 0 }
        {
            # 構造行を 1 行受け取ったことを記録する（1 行も来ないのは抽出側の異常なので後段で特権に倒す）
            seen = 1
            # `行番号:内容` の形で渡されるので、行番号を落として内容だけを取り出す
            line = $0
            sub(/^[0-9]+:/, "", line)

            # 最初に現れる非空白文字の位置から、その行の字下げ幅を求める
            indent = match(line, /[^[:space:]]/) - 1

            # 構造として解釈するので、行末コメントを落とす
            # （`contents: write  # 説明` のような書き方でも値だけを見るため）
            sub(/[[:space:]]*#.*$/, "", line)
            # 引用符をすべて取り除き、`"permissions":` と `permissions:`、`"write"` と `write` を同じ形に揃える。
            # YAML は鍵も値も引用できるため、引用の有無を綴りとして数え上げると必ず取りこぼす
            # （`"permissions": write-all` が非特権と誤判定される穴を実測）
            gsub(quote_chars, "", line)
            # 大文字小文字の揺れも同様に潰しておく（`WRITE` と `write`、`Secrets:` と `secrets:` を同じ形にする）
            line = tolower(line)
            # コメントだけの行はここで読み飛ばす
            if (line ~ /^[[:space:]]*$/) next

            # `permissions:` / `secrets:` 自身がブロックスカラー（`permissions: >-` 等）で書かれている場合、
            # 本文は抽出側で落とされるため宣言の中身が見えない。解釈できない宣言として特権に倒す
            if (line ~ /^[[:space:]]*(-[[:space:]]+)?(permissions|secrets)[[:space:]]*:[[:space:]]*[|>][0-9]*[+-]?[[:space:]]*$/) {
                print "privileged"; decided = 1; exit
            }

            # `secrets:` を鍵に持つ行は、reusable workflow へ secret を渡す形（`inherit` もブロック形式も）
            # なので、値の綴りを見ずに特権と判断する
            if (line ~ /^[[:space:]]*(-[[:space:]]+)?secrets[[:space:]]*:/) {
                print "privileged"; decided = 1; exit
            }

            # 1 行のフローマッピングでジョブを書くと（`j: {runs-on: …, permissions: {contents: write}}`）、
            # 鍵が行頭に来ないため上の行頭一致では見えない。フローの区切り（`{` か `,`）の直後に
            # `permissions` / `secrets` が現れる形を、解釈できない宣言として特権に倒す
            # （この経路で `secrets: inherit` のバイパスが 1 行の書き換えで復活することを実測）
            if (line ~ /[{,][[:space:]]*(permissions|secrets)[[:space:]]*:/) {
                print "privileged"; decided = 1; exit
            }

            # 字下げブロックの内側にいる場合は、1 項目ずつ許可の値を確かめる
            if (in_block) {
                # 字下げが浅くなった＝ブロックの終わりなので、この行は通常の行として読み直す
                if (indent <= block_indent) {
                    in_block = 0
                } else {
                    # `contents: read` のような「名前: 値」1 項目の形かどうかを確かめる
                    if (line ~ /^[[:space:]]*[a-z][a-z0-9_-]*:[[:space:]]*[a-z-]+[[:space:]]*$/) {
                        # コロンより後ろを値として取り出す
                        value = line
                        sub(/^[^:]*:[[:space:]]*/, "", value)
                        sub(/[[:space:]]*$/, "", value)
                        # read でも none でもない値は、何らかの書き込み権限を与えているとみなす
                        if (value != "read" && value != "none") { print "privileged"; decided = 1; exit }
                    } else {
                        # 想定外の書き方は解釈できないので、安全側（特権）に倒す
                        print "privileged"; decided = 1; exit
                    }
                    # この行の処理は済んだので次の行へ進む
                    next
                }
            }

            # `permissions:` の宣言行かどうかを調べる（ワークフロー全体・ジョブ単位のどちらも対象）。
            # `permissions :` のようにコロンの前に空白を挟む書き方も YAML では正しいので許容する
            if (line ~ /^[[:space:]]*permissions[[:space:]]*:/) {
                # 最初のコロンより後ろを値として取り出す
                value = line
                sub(/^[^:]*:[[:space:]]*/, "", value)
                sub(/[[:space:]]*$/, "", value)
                # 値が空＝この下に字下げブロックが続く形なので、ブロック読み取りに切り替える
                if (value == "") { in_block = 1; block_indent = indent; next }
                # `read-all` は全スコープ読み取り専用なので特権ではない
                if (value == "read-all") next
                # `{...}` の 1 行フロー形式は、中身をカンマで分けて 1 項目ずつ確かめる
                if (value ~ /^\{.*\}$/) {
                    # 前後の波括弧を外して中身だけにする
                    inner = value
                    sub(/^\{[[:space:]]*/, "", inner)
                    sub(/[[:space:]]*\}$/, "", inner)
                    # `permissions: {}` は全スコープ none と同義なので特権ではない
                    if (inner == "") next
                    # カンマ区切りの項目に分割する
                    n = split(inner, items, ",")
                    # 取り出した項目を 1 つずつ検査する
                    for (i = 1; i <= n; i++) {
                        # 前後の空白を落として「名前: 値」だけにする
                        item = items[i]
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                        # 想定した「名前: 値」の形でなければ解釈できないので特権に倒す
                        if (item !~ /^[a-z][a-z0-9_-]*:[[:space:]]*[a-z-]+$/) { print "privileged"; decided = 1; exit }
                        # コロンより後ろを値として取り出す
                        v = item
                        sub(/^[^:]*:[[:space:]]*/, "", v)
                        # read でも none でもなければ書き込み権限を与えているとみなす
                        if (v != "read" && v != "none") { print "privileged"; decided = 1; exit }
                    }
                    # フロー形式の全項目が読み取り専用だったので次の行へ進む
                    next
                }
                # `write-all` を含め、ここまでで扱えなかった値はすべて特権として扱う
                print "privileged"; decided = 1; exit
            }
        }
        # 最後まで read / none 以外が出てこなかったときだけ「読み取り専用」と結論する。
        # exit で抜けた場合も END は実行されるため、旗で二重出力を防ぐ。
        # 構造行が 1 行も来なかった場合は抽出側が壊れているので、「根拠なし」ではなく特権に倒す
        END {
            if (decided) exit
            if (seen) print "read-only"; else print "privileged"
        }
    '
}

# 渡されたワークフローが「特権」かどうかをファイルの内容から判定する関数
# 第 1 引数: ワークフローファイルのパス
# 特権と判定したら 0 を返す（ファイル名の一覧に頼らないことで、新設された特権ジョブも拾える）
is_privileged_workflow() {
    # 判定対象のファイルパスを変数に入れる
    local path="$1"
    # 表示・比較に使う短いファイル名を求める
    local name
    name="$(basename "$path")"

    # 下限リストに載っているファイルは、内容にかかわらず必ず特権として扱う
    local always
    for always in "${ALWAYS_PRIVILEGED[@]}"; do
        if [[ "$name" == "$always" ]]; then
            return 0
        fi
    done

    # secret がこのワークフローを通るなら、漏洩すれば影響が出るため特権として扱う。
    # 判定は綴りを数え上げず、**`secrets` が構文上どの位置に置かれているか**の 2 通りだけで行う。
    # 綴りの列挙が続かない理由: Actions は同じ意味を何通りにも書ける（`secrets.NAME` /
    # `secrets['NAME']` / `secrets ["NAME"]` / `toJSON(secrets)` / `secrets: inherit` /
    # `secrets: 'inherit'` / `"secrets": inherit` / 行末コメント付き / 文脈名は大文字小文字を
    # 区別しないので `Secrets.NAME` も有効……）。issue #87 とその後のセルフレビューで
    # 3 度、列挙の穴を突かれている。
    # 逆に「`secrets` という語がどこかにあれば特権」まで広げると今度は行き過ぎで、
    # 例えば `ci.yml` のステップ名に `secrets` の語が入っただけで、**意図的に可変タグを使っている**
    # 同ファイルが違反扱いになり CI が恒常的に赤くなる（この取り違えも実測した）。
    # そこで「語があるか」ではなく「鍵として使われているか／式の中で参照されているか」を見る

    # (a) `${{ … }}` の式の中で参照される形。`secrets.NAME` も `toJSON(secrets)` も
    #     添字形式もすべてここに当たる。
    #     式は改行をまたげるのでファイル全体を 1 本につなぎ、**式の終端 `}}` で区切り直してから**探す。
    #     「最初の `}` まで」で区切ると `${{ format('{0}', secrets.X) }}` のように式の内側に `}` を
    #     含む書き方で照合が途中で切れ、参照を見落とす（実測）。逆に区切らずに探すと、
    #     ファイルのどこかにある `${{ … }}` と、無関係な場所の `secrets` の語が結び付いてしまう
    if awk '
        # 全行を 1 本の文字列につなぐ（式が改行をまたいでいても 1 つのまとまりとして扱うため）
        { joined = joined " " $0 }
        END {
            # 式の終端をすべて改行に置き換え、1 つの式が 1 行に収まる形にする
            gsub(/}}/, "\n", joined)
            # 式の開始から終端までの間に secrets が現れれば参照とみなす（大文字小文字は問わない）
            if (tolower(joined) ~ /\$\{\{[^\n]*secrets/) exit 0
            # どの式にも現れなければ、この形での参照は無い
            exit 1
        }
    ' "$path"; then
        return 0
    fi

    # (b) `secrets:` を鍵に持つ形は、後段の構造走査（`scan_workflow_structure`）が
    #     `permissions:` と同じ 1 回の走査で拾う。`run:` などのブロックスカラー本文を
    #     構造として読み違えないためには字下げの追跡が要るので、行単位の grep では足りない

    # ワークフロー全体に効く `permissions:`（字下げ 0 の宣言）が無い場合は特権として扱う。
    # ジョブ単位の宣言しか無いワークフローでは、宣言を書き忘れたジョブが
    # リポジトリ既定（書き込み可能になりうる）のまま動くため、
    # 「全ジョブに効く宣言がある」ことを非特権の必要条件にする（fail-closed）
    if ! grep -qE "^[\"']?permissions[\"']?[[:space:]]*:" "$path"; then
        return 0
    fi

    # `permissions:` の宣言を解析した結論を受け取る
    local verdict
    verdict="$(scan_workflow_structure "$path")"

    # **`read-only` と明示されたときだけ**非特権と認める。
    # `privileged` はもちろん、解析器が異常終了して無出力になった場合や想定外の出力が来た場合も、
    # 「判定できなかった」として特権に倒す（不明なら拒否＝fail-closed）
    if [[ "$verdict" != "read-only" ]]; then
        return 0
    fi

    # 上記のいずれにも当たらなければ、明示的に読み取り専用の非特権ワークフローと判断する
    return 1
}

# 指定したリポジトリのタグが指しているコミット SHA を求める関数
# 第 1 引数: リポジトリの URL / 第 2 引数: タグ名（例 v1.0.186）
# 解決できたら SHA を出力して 0 を返す。
# 戻り値 2 = 上流に到達できたがタグが存在しない（マーカーの綴り誤り等。再試行しても無駄）
# 戻り値 3 = 上流に到達できない（通信断・時間切れ。再試行済み）
# 戻り値 4 = リポジトリ自体に到達できない（改名・削除・非公開。再試行しても無駄）
resolve_tag_commit() {
    # 引数で受け取ったリポジトリ URL を変数に入れる
    local url="$1"
    # 引数で受け取ったタグ名を変数に入れる
    local tag="$2"
    # ls-remote の出力・エラー出力・終了コードを受け取る変数をあらかじめ用意する
    local out err rc attempt
    # エラー出力を一時的に受け取るファイルを作る（原因の切り分けに使う）
    err="$(mktemp)"

    # 到達できない場合に備えて、指定回数まで間隔を空けて問い合わせをやり直す
    for ((attempt = 1; attempt <= LS_REMOTE_ATTEMPTS; attempt++)); do
        # タグ本体と peel 済み参照の両方をまとめて問い合わせる。
        # annotated タグは `^{}` 行に実コミットを返すが、lightweight タグには
        # `^{}` 行が無くタグ自身が直接コミットを指すため、両方を聞かないと
        # 一方の種類でだけ 0 行になる（上流は両方の種類を混在させている）。
        # 応答が返らない場合に備えて timeout で頭打ちにする
        rc=0
        out="$(GIT_TERMINAL_PROMPT=0 timeout "${LS_REMOTE_TIMEOUT_SECONDS}" \
            git ls-remote "$url" "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>"$err")" || rc=$?

        # 問い合わせが成功した（＝上流に到達できた）ならループを抜けて結果を解釈する
        if [[ "$rc" -eq 0 ]]; then
            break
        fi

        # リポジトリが見つからない／権限が無い場合は、待って試し直しても結果は変わらないので即座に打ち切る。
        # GitHub は存在しないリポジトリの有無を伏せるため 404 ではなく認証要求を返す。
        # そのため「認証情報を求められた」を、改名・削除・非公開の合図として扱う
        if grep -qiE 'could not read Username|Authentication failed|repository not found|not found' "$err"; then
            rm -f "$err"
            return 4
        fi

        # まだ試行回数が残っていれば、少し待ってからやり直す（一時的な通信断の吸収）
        if [[ "$attempt" -lt "$LS_REMOTE_ATTEMPTS" ]]; then
            sleep $((attempt * 2))
        fi
    done

    # 一時ファイルはここまでで役目を終えるので削除する
    rm -f "$err"

    # 規定回数試しても到達できなかった場合は「到達不能」として呼び出し側に知らせる
    if [[ "$rc" -ne 0 ]]; then
        return 3
    fi

    # `^{}` 行があれば、それが annotated タグの指す実コミットなので最優先で採用する
    local resolved
    resolved="$(printf '%s\n' "$out" | awk -v t="refs/tags/${tag}^{}" '$2 == t {print $1; exit}')"
    # `^{}` 行が無い＝lightweight タグなので、タグ自身が指す SHA を採用する
    if [[ -z "$resolved" ]]; then
        resolved="$(printf '%s\n' "$out" | awk -v t="refs/tags/${tag}" '$2 == t {print $1; exit}')"
    fi

    # 到達はできたのに該当行が無い＝そのタグが上流に存在しない、と確定できる
    if [[ -z "$resolved" ]]; then
        return 2
    fi

    # 解決できた SHA を出力して正常終了する
    printf '%s' "$resolved"
}

# SHA ピンされた action 参照について、マーカーとの整合を検証する関数
# 第 1 引数: 表示用ラベル / 第 2 引数: owner/repo[/path] / 第 3 引数: ピンされた SHA / 第 4 引数: マーカー
verify_marker_against_pin() {
    # 引数をそれぞれ意味の分かる名前の変数に取り出す
    local label="$1" action="$2" pinned="$3" marker="$4"
    local repo_slug actual rc

    # `owner/repo/path@ref`（サブディレクトリ指定）も正式な書き方なので、
    # clone 先の URL には先頭 2 セグメント（owner/repo）だけを使う
    repo_slug="$(printf '%s' "$action" | cut -d/ -f1,2)"

    # 想定した `owner/repo` の形になっていない場合は、URL を組み立てず「未対応の書き方」として失敗させる
    # （そのまま連結すると 404 になり、通信障害と区別できない誤った診断が出るため）
    if [[ ! "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        fail "${label} uses a supported owner/repo form" \
            "cannot derive a repository URL from '${action}'; this checker only understands owner/repo[/path]@ref"
        return 0
    fi

    # マーカーが無いとどの版にピンしているか機械的に判定できないため、失敗として扱う
    if [[ -z "$marker" ]]; then
        fail "${label} has a version marker" \
            "SHA-pinned but no trailing version marker (e.g. '# v1.2.3'); FR-9.6(b) makes that marker the source of truth for the pinned release"
        return 0
    fi

    # マーカーが指すタグが実際に指しているコミットを上流に問い合わせて求める
    rc=0
    actual="$(resolve_tag_commit "https://github.com/${repo_slug}" "$marker")" || rc=$?

    # 上流には届いたがタグが無い＝マーカーの綴り誤りか、上流でのタグ削除・改名と確定できる
    if [[ "$rc" -eq 2 ]]; then
        fail "${label} marker ${marker} exists upstream" \
            "https://github.com/${repo_slug} has no tag '${marker}'; the marker names a release that does not exist (typo?), or it was deleted or renamed upstream"
        return 0
    fi

    # リポジトリ自体に届かない＝action 名の誤り・改名・非公開化と確定できる（通信障害ではない）
    if [[ "$rc" -eq 4 ]]; then
        fail "${label} repository is reachable" \
            "https://github.com/${repo_slug} could not be read (renamed, deleted, or private); check the action name rather than the network"
        return 0
    fi

    # 上流にそもそも到達できなかった場合は、検証できていないので通さない（fail-closed）
    if [[ "$rc" -eq 3 ]]; then
        fail "${label} marker ${marker} resolves upstream" \
            "could not reach https://github.com/${repo_slug} after ${LS_REMOTE_ATTEMPTS} attempts (network failure or timeout); the pin was NOT verified"
        return 0
    fi

    # 求めたコミットとピンされている SHA が一致すればマーカーは正しい
    if [[ "$actual" == "$pinned" ]]; then
        pass "${label} is pinned to ${marker} (${pinned:0:12}…)"
    else
        # 一致しない場合は、どちらが正しいか人が判断できるよう両方の SHA を出す
        fail "${label} marker ${marker} matches the pinned SHA" \
            "pinned ${pinned} but ${marker} points at ${actual}; either the SHA or the marker was changed without the other"
    fi
}

# 構造行を「`uses:` の出現ごとに 1 件」へばらして書き出す関数
# 第 1 引数: 検査対象のファイルパス
#
# **1 行に `uses:` は何個でも書ける**。フロー形式なら `steps: [{uses: a}, {uses: b}]` と 1 行に
# 並べられるし、行末コメントに `# 以前は uses: … だった` と書くこともできる。にもかかわらず
# 消費側は「1 行 = 参照 1 個」を前提に貪欲一致（`.*uses:`）で 1 個だけ取り出していたため、
# **最後の 1 個以外が検査対象から丸ごと外れていた**（特権ワークフローに未ピンの可変タグを置き、
# 同じ行の後ろにローカル action を並べると指摘 0 件で通ることを実測）。
# 出現ごとにばらしてから渡すことで、消費側は 1 個だけを見ればよくなる。
#
# **行末コメントは値の探索対象から外す**: 構造としての `uses:` はコメントより前にしか置けない。
# バージョンマーカーはコメント側にあるので、切り離したうえで**1 件しかない行に限り**付けて渡す。
#
# **鍵として置ける位置だけを見る**（「空白の後ろならどこでも」にしない）: 引用符は
# `emit_structural_lines()` が一律に落とすため、`- name: Verify that every workflow uses: a pinned SHA`
# のような**値の中の散文**が素の文字列として届く。空白の後ろを一律に鍵と見なすと、これを参照
# `a` と読んで違反を報告し、特権ワークフロー（`post-ci-verify.yml`）に同種の文言が入った時点で
# CI が恒常的に赤くなる。鍵になれるのは行頭（字下げと `- ` を挟んでよい）か、フロー集合の内側にある
# `{` / `,` の直後だけ（集合の外のカンマは散文の読点なので区切りと認めない）。
#
# 出力は「行番号 <TAB> 参照 <TAB> マーカー」。**値の切り出しをここだけに持たせる**ため、
# 消費側は受け取った値をそのまま使う（両方で切り出すと、鍵の表記ゆれへの対応が片方だけ古くなる）
split_uses_occurrences() {
    # 検査対象のファイルパスを変数に入れる
    local path="$1"

    # 構造行（ブロックスカラーの本文を除いた行）を出現ごとにばらす
    emit_structural_lines "$path" | awk '
        # コメント本文の先頭語が「版の注記らしい形」かどうかを調べる関数。
        # 引用符が落ちた値の中の `#`（`release #1}` 等）を注記と取り違えないための歯止めで、
        # タグに現れない構造文字（`}` `)` `,` など）を含む語は注記として認めない
        function looks_like_marker(w) {
            # まずタグに使える文字だけでできているかを見る（構造文字を含む語は注記ではない）
            if (w !~ /^v?[0-9][0-9A-Za-z._+-]*$/) return 0
            # さらに `v` 始まりか、版らしい区切りのドットを含むことを求める。
            # これが無いと `# bump #12 -> v5` の `12` のような issue 番号を版と誤読し、
            # 存在しないタグを上流へ問い合わせて原因を指し違えた診断を出す
            return (w ~ /^v/ || index(w, ".") > 0)
        }
        # 参照の後ろに続く文字列から版注記（`# vX.Y.Z`）を取り出す関数。
        # **参照より後ろに現れる `#` を順に見て、最初に「版らしい語」が続くものを注記とする。**
        # 1 つ目で打ち切らないのは、引用符が落ちた `, name: release #1}  # v4` のように
        # 値の中の `#` が先に来ることがあるため（そこで打ち切ると `1}` を注記と誤読する）。
        # 逆に最後まで貪欲に採ると `# v1.2.3 (fixes #42)` で `42)` を拾うので「版らしい形か」で選ぶ。
        # 単一行の参照（値の後ろ）と、値を次行に置いた参照（続きの行）の**両方**がこれを使う（§6 DRY）
        function marker_from(tail,   body, word) {
            # `#` を順に探し、直後の最初の語が版らしければそれを注記として返す
            while (match(tail, /(^|[[:space:]])#/)) {
                # `#` の直後から後ろをコメント本文の候補として取り出す
                body = substr(tail, RSTART + RLENGTH)
                # 候補の先頭にある空白を落として、最初の語の頭に合わせる
                sub(/^[[:space:]]*/, "", body)
                # 最初の語（次の空白まで）を切り出す
                word = body
                sub(/[[:space:]].*$/, "", word)
                # 版らしい形ならそれを注記として採用する
                if (looks_like_marker(word)) { return word }
                # そうでなければ、この `#` の次の文字から探索を続ける
                tail = body
            }
            # どの `#` も版らしくなければ注記なし
            return ""
        }
        {
            # 「行番号:行の内容」の形なので、最初のコロンで 2 つに分ける
            pos = index($0, ":")
            # コロンより前が行番号
            lineno = substr($0, 1, pos - 1)
            # コロンより後ろが行の内容
            content = substr($0, pos + 1)
            # この行の字下げ幅（先頭の非空白文字の位置）を求める。値を次行に置く記法の判定に使う
            line_indent = match(content, /[^[:space:]]/) - 1

            # 直前の行が「値をこの行に持たない uses:」だったら、この行で値を解決する（issue #104）。
            # YAML は `- uses:` の値を次の行に**より深く字下げして**置ける。片行しか見ないと、
            # その値（可変タグを含みうる）が抽出から丸ごと落ち、ピン検査を静かに素通りする
            if (pending) {
                # より深く字下げされた行だけが、その uses: の値（次行記法）になりうる
                if (line_indent > pend_indent) {
                    # 先頭の字下げを落として値の先頭に合わせる
                    cval = content
                    sub(/^[[:space:]]+/, "", cval)
                    # 値は最初の区切り（空白・`,`・`}`・`]`）までとする（単一行の切り出しと同じ規則）
                    token = cval
                    sub(/[][[:space:],}].*$/, "", token)
                    # 版注記は値の後ろのコメントから取る（単一行と共通の関数を使う）
                    marker = marker_from(cval)
                    if (token != "") {
                        # 参照が読めたので、uses: の行番号のものとして書き出す
                        print pend_line "\t" token "\t" marker
                    } else {
                        # 深いが参照が読めない＝黙って飛ばさず失敗させる（fail-closed）
                        print pend_line "\t" "\t"
                    }
                    # この保留は解決したので閉じ、この行は値として消費済みなので通常走査しない
                    pending = 0
                    next
                }
                # 続きが無い（浅い／兄弟キー）＝ uses: に値が無い。空欄で書き出し検査を赤くする（fail-closed）
                print pend_line "\t" "\t"
                pending = 0
                # この行そのものは通常どおり走査を続ける（自身の uses: を持ちうる）
            }

            # 行を先頭から走査し、見つけた `uses:` の値をいったん配列へ集める。
            # **コメントの手前で行を切らない**: 引用符は抽出時に一律で落ちるため、
            # `- {name: release #1, uses: actions/checkout@v1}` の `#` は素の文字として届く。
            # そこで切ると後ろの本物の参照ごと捨ててしまい、未ピンの可変タグが検査から消える
            # （＝このファイルが繰り返し塞いできた「不在＝合格」に戻る）。
            # コメント中の `uses:` は下の位置規則（行頭 / 集合内の `{` `,` の直後）で自然に除かれる
            n = 0
            rest = content
            # 値をこの行に持たない uses: 鍵を見つけたかどうか（次行に値がある記法の候補）
            empty_uses = 0
            # `rest` より前にある文字数（絶対位置を求めるために持ち歩く）
            scanned = 0
            # 行頭の形（字下げ＋任意の `- `）を許すのは**最初の 1 回だけ**。
            # 2 個目以降は走査位置が行の途中なので、行頭扱いにすると値の続きを鍵と読みかねない
            at_line_head = 1
            while (1) {
                # 見つかったかどうかを初期化する
                found = 0
                # 行頭に置かれた鍵かどうかを先に見る（該当すれば必ず最も手前の一致になる）
                if (at_line_head && match(rest, /^[[:space:]]*(-[[:space:]]+)?uses[[:space:]]*:[[:space:]]*/)) found = 1
                # 行頭でなければ、フロー形式の区切り（`[` / `{` / `,`）の直後に置かれた鍵を探す。
                # **`[` を入れる**: `steps: [uses: …]`（シーケンスの先頭要素が単一対のマッピング）も
                # 正しい YAML で実際に実行されるステップになるため、外すと丸ごと検査対象から消える。
                # **カンマに「集合の内側か」の条件は付けない**: 一度その条件を入れたところ、
                # 集合が複数行に跨る書き方（`steps: [` の次の行に `name: a, uses: …`）で
                # 開き括弧が前の行にあるため区切りと認められず、**参照を丸ごと取り逃がした**（実測）。
                # 条件を外すと散文の読点で偽の参照を報告しうるが、それは余分に赤くなるだけで
                # 見逃しは生まない（`]` は集合を閉じる文字なので、こちらは区切りに含めない）
                if (!found && match(rest, /[[{,][[:space:]]*uses[[:space:]]*:[[:space:]]*/)) {
                    found = 1
                }
                # どちらでも見つからなければ、この行の走査は終わり
                if (!found) break
                # 一度探索したら以降は行頭ではない
                at_line_head = 0
                # マッチの直後から値が始まるので、そこから後ろを取り出す
                after = substr(rest, RSTART + RLENGTH)
                # 値の候補をいったん丸ごと受け取る
                value = after
                # フロー形式では値の直後に区切り（空白・`,`・`}`・`]`）が続くので、そこまでを値とする
                sub(/[][[:space:],}].*$/, "", value)
                # 値が取れたものだけを控える（鍵だけで値が無い行は対象外）。
                # **「参照らしい形か」で絞り込まない**: 一度その絞り込みを入れたところ、
                # `uses: ${{ inputs.action_ref }}` のような**実際に動く動的参照**まで落として
                # 特権ワークフローで指摘 0 件になった（main は検出していた。実測）。
                # 散文の取り違えは「余分に赤くなる」だけだが、こちらは見逃しを生む
                if (value != "") {
                    values[++n] = value
                    # 値の終わりが行の何文字目かを覚えておく（版注記をこの後ろから探すため）
                    value_end = scanned + RSTART + RLENGTH + length(value) - 1
                } else {
                    # 鍵はあるが値がこの行に無い。値を次の行に置く記法かもしれないので控える（issue #104）
                    empty_uses = 1
                    # 値は**鍵より深く**字下げされていなければならない（`- uses:` の場合、鍵の桁は
                    # ダッシュではなく `uses` の位置）。ここでは matched 部分から `uses` の桁を取り出す
                    matched = substr(rest, RSTART, RLENGTH)
                    prefix = matched
                    sub(/uses.*/, "", prefix)
                    empty_uses_indent = length(prefix)
                }
                # 次の `uses:` を探すため、いま処理した位置より後ろへ進める
                scanned += RSTART + RLENGTH - 1
                rest = after
            }

            # 値をこの行に持たない uses: だけで、他に参照が無ければ、次の行を値として解決するため保留する。
            # **他に参照があるときは保留しない**（`n == 0` の条件）: 値の無い鍵は誤検出の断片かもしれず、
            # 同じ行に本物の参照があるなら次行を巻き込む必要はない。保留したら以降の走査は次の行で行う
            if (empty_uses && n == 0) {
                pending = 1
                pend_line = lineno
                # **鍵より深く字下げされている行だけ**をその値と見なす（YAML の block mapping 規則）。
                # ダッシュの桁で比べると、同じ手順の兄弟キー（`with:` など）まで飲み込んでしまう
                pend_indent = empty_uses_indent
                # この行に出力すべき参照は無いので、そのまま次の行へ進む
                delete values
                next
            }

            # バージョンマーカーを行末コメントから取り出す（`v` 接頭辞は付かない上流もあるため任意）。
            # **参照より後ろだけを探す**: 先頭から最初のコメント開始を探すと、引用符が落ちた
            # `- {name: release #1, uses: …}  # v4` で値の中の `#1` を拾い、`1,` をマーカーと誤読する。
            # **1 行に複数の参照があるときは注記を誰にも渡さない**（`n == 1` の条件）:
            # どの参照を指す注記か決められないため。全件へ配ると (a) 別々の SHA に同じ版を
            # 突き合わせて偽の改竄警告を出し、(b) 自分の注記を持たない参照が隣の注記を借りて
            # 「マーカーが無い」検査をすり抜ける。空のままなら各参照は自分の注記だけで判定され、
            # 曖昧な書き方は素直に赤くなる（fail-closed）
            marker = ""
            if (n == 1) {
                # 参照の終わりより後ろの部分だけを渡して、版注記を取り出す
                marker = marker_from(substr(content, value_end + 1))
            }

            # 集めた値を 1 件ずつ書き出す
            # （`marker` は上の `n == 1` の中でしか埋まらないので、複数件の行では必ず空になる）
            for (i = 1; i <= n; i++) {
                print lineno "\t" values[i] "\t" marker
            }
            # 次の行のために、この行で使った配列を空にする
            delete values
        }
        END {
            # ファイルの末尾が「値の無い uses:」で終わっていたら、黙って落とさず失敗させる（fail-closed）
            if (pending) { print pend_line "\t" "\t" }
        }
    '
}

# `uses:` 1 件を検査する関数
# 第 1 引数: ワークフローのファイル名 / 第 2 引数: 行番号
# 第 3 引数: 参照文字列 / 第 4 引数: バージョンマーカー（無ければ空文字列）
# 第 5 引数: その行が特権ワークフローのものなら "privileged"、それ以外は "plain"
#
# 値の切り出しは `split_uses_occurrences()` が済ませてあるので、ここでは**受け取った値をそのまま使う**
check_uses_line() {
    # 引数をそれぞれ意味の分かる名前の変数に取り出す
    local wf_name="$1" lineno="$2" ref="$3" marker="$4" scope="$5"
    local action pinned label
    # 表示用に「ファイル名:行番号 の参照」という短いラベルを組み立てる
    label="${wf_name}:${lineno} ${ref%%@*}"

    # リポジトリ内のローカル action（`./…`）は外部から取り込まないため、供給網ピンの対象外とする
    if [[ "$ref" == ./* || "$ref" == ../* ]]; then
        # 特権ワークフローでも、この参照はリポジトリ自身の内容なので合格として扱う
        if [[ "$scope" == "privileged" ]]; then
            pass "${label} is a local action (in-repo, no external pin required)"
        fi
        return 0
    fi

    # Docker イメージ参照（`docker://…`）は SHA ではなくダイジェストで固定する必要がある
    if [[ "$ref" == docker://* ]]; then
        # 特権ワークフローではダイジェスト（`@sha256:…`）で固定されていなければ可変参照として失敗させる
        if [[ "$scope" == "privileged" ]]; then
            if [[ "$ref" =~ @sha256:[0-9a-f]{64}$ ]]; then
                pass "${label} is pinned to an image digest"
            else
                fail "${label} is pinned immutably (FR-9.6(b))" \
                    "container action '${ref}' uses a mutable image reference; pin it by digest (docker://image@sha256:<64 hex>)"
            fi
        fi
        return 0
    fi

    # ここから先は `owner/repo[/path]@ref` 形式の action 参照として扱う
    # `@` を含まない参照は版を固定できていないので、特権ワークフローでは失敗させる
    if [[ "$ref" != *@* ]]; then
        if [[ "$scope" == "privileged" ]]; then
            fail "${label} is pinned immutably (FR-9.6(b))" \
                "action reference '${ref}' names no version at all; pin it to a 40-char commit SHA"
        fi
        return 0
    fi

    # `@` の前の部分（owner/repo あるいは owner/repo/path）を取り出す
    action="${ref%%@*}"
    # `@` の後ろの部分（コミット SHA か、v1 のような可変タグ）を取り出す
    pinned="${ref##*@}"

    # 参照が 40 桁の 16 進数（＝コミット SHA）かどうかを判定する
    if [[ ! "$pinned" =~ ^[0-9a-f]{40}$ ]]; then
        # 特権ワークフローでは可変タグ参照そのものが FR-9.6(b) 違反なので失敗させる
        if [[ "$scope" == "privileged" ]]; then
            fail "${label} is pinned to a full commit SHA (FR-9.6(b))" \
                "referenced by the mutable ref '${pinned}'; every action in a privileged workflow must be pinned to a 40-char commit SHA"
        fi
        # 非特権ワークフローの可変タグは FR-9.6(b) の対象外なので、何も言わず次へ進む
        return 0
    fi

    # SHA ピンされている行は、特権かどうかによらずマーカーとの整合を確認する（多層防御）
    verify_marker_against_pin "$label" "$action" "$pinned" "$marker"
}

# 指定した 1 つのワークフローファイル内の `uses:` 行をすべて検査する関数
# 第 1 引数: ワークフローファイルのパス / 第 2 引数: "privileged" か "plain"
check_workflow_file() {
    # 引数をそれぞれ意味の分かる名前の変数に取り出す
    local path="$1" scope="$2"
    # 表示に使う短いファイル名を求める
    local wf_name
    wf_name="$(basename "$path")"
    # そのファイルで `uses:` 行が 1 つでも見つかったかを記録する
    local seen=0
    # 読み取りループが 1 件ずつ受け取る 3 列（関数の外へ漏らさないよう先に宣言する）
    local lineno ref marker

    # `uses:` を 1 件ずつ行番号付きで読み取って検査する。
    # ここでは参照の形（`@` の有無・`docker://`・ローカル参照）で絞り込まない。
    # 絞り込むと「該当形式でない＝検査対象なし＝合格」という取りこぼしが生まれるため。
    # 「行番号 <TAB> 参照 <TAB> マーカー」の 3 列で渡ってくるので、タブ区切りで受け取る
    while IFS=$'\t' read -r lineno ref marker; do
        # `uses:` を 1 件見つけたことを記録する
        seen=1
        # 取り出した 1 件を検査する
        check_uses_line "$wf_name" "$lineno" "$ref" "$marker" "$scope"
    # 抽出は `split_uses_occurrences` に任せる（構造行の抽出 → 出現ごとの分解までを 1 本で行う）。
    # **選別条件をここに書き写さない**: 以前はこの位置の `grep` と消費側の取り出し式が
    # 「何を `uses:` と見なすか」を二重に持っており、片方だけが 1 行複数の出現に対応できていなかった。
    # 単一の参照元にまとめることで、鍵の表記ゆれへの対応が片方だけ古くなる事故を防ぐ（§6 一元管理）
    done < <(split_uses_occurrences "$path")

    # 特権ワークフローに `uses:` が 1 行も無いのは、抽出条件の破損か構成変更を意味するため失敗にする
    # （検査対象が消えたことを「合格」と読み替えないための歯止め）
    if [[ "$scope" == "privileged" && "$seen" -eq 0 ]]; then
        fail "${wf_name} contains at least one action to verify" \
            "no 'uses:' reference found; the workflow was restructured, or this checker's matcher no longer recognises its syntax"
    fi
}

# 1 つのワークフローについて、特権判定から `uses:` 検査までを一続きに行う関数
# 第 1 引数: ワークフローファイルのパス
#
# 本番の走査ループと回帰テストの**両方がこの 1 本を呼ぶ**ことに意味がある。
# 判定と検査を別々に書くと、判定の回帰テストが緑のまま「判定結果を検査へ渡す配線」だけが
# 壊れうる（例: 常に `plain` を渡すよう書き換えても、分類器の単体検査は全件通る）。
# 経路を 1 本に束ねることで、その配線自体を回帰テストの射程に入れる
check_workflow_path() {
    # 検査対象のファイルパスを変数に入れる
    local path="$1"

    # このファイルが特権かどうかを内容から判定し、適用する規則を決める
    if is_privileged_workflow "$path"; then
        check_workflow_file "$path" "privileged"
    else
        check_workflow_file "$path" "plain"
    fi
}

# 検査用の仮ワークフローをファイルへ書き出し、そのパスを `FIXTURE_PATH` に置く関数
# 第 1 引数: ファイル名の接頭辞（どの検査が作ったものか分かるようにする）/ 第 2 引数: ワークフローの中身
#
# **3 つの表明関数が同じ前置きを書き写していたのでまとめた**（§6 DRY）。
# ファイル名は下限リスト `ALWAYS_PRIVILEGED` のどれとも衝突しない形にする必要がある
# （衝突すると、内容ではなくファイル名で特権と判定されてしまい、検査の意味が変わる）。
# 1 か所に集めておけば、この制約を満たす場所も 1 か所で済む。
#
# **パスを標準出力へ返さずグローバル変数に置く**のが要点: 呼び出し側が `$(write_fixture …)` で
# 受け取ると本体がサブシェルで走り、連番 `FIXTURE_SEQ` の増加が呼び出し元へ戻らない。
# その状態では同じ接頭辞の仮ワークフローが毎回同じ 1 ファイルを上書きし、
# 失敗したケースを調べようとしたときにディスクへ残っているのは別のケースの内容になる（実測）
write_fixture() {
    # 引数をそれぞれ意味の分かる名前の変数に取り出す
    local prefix="$1" body="$2"
    # 検査ごとに別名のファイルを作るための連番を 1 つ進める
    FIXTURE_SEQ=$((FIXTURE_SEQ + 1))
    # 仮のワークフローの置き場所を決めて、呼び出し側から見えるようにする
    FIXTURE_PATH="${TEST_TMP}/${prefix}-${FIXTURE_SEQ}.yml"
    # 渡されたワークフローの中身を仮のファイルへ書き出す
    printf '%s\n' "$body" > "${FIXTURE_PATH}"
}

# 仮のワークフローを実際の検査経路へ通し、違反として数えられるかどうかを確かめる関数
# 第 1 引数: 期待する結果（enforced = 違反として検出される / accepted = 何も咎められない）
# 第 2 引数: 表示用の説明 / 第 3 引数: ワークフローの中身
#
# なぜ分類器の判定を見るだけでは足りないか: FR-9.6(b) の実効性は
# 「特権と判定する」→「その中の `uses:` すべてに不変なピンを要求する」の 2 段で成り立つ。
# 前段だけを固定すると後段を丸ごと削っても回帰テストが緑のままになるため、
# ここでは `check_workflow_path()` に通し、集計カウンタの増分で結果を観測する。
# 上流問い合わせを起こさないよう、仮のワークフローには SHA ピンを書かない（可変参照だけを使う）

assert_pin_enforcement() {
    # 引数をそれぞれ意味の分かる名前の変数に取り出す
    local expected="$1" label="$2" body="$3"
    # 仮のワークフローを書き出し、そのパスを受け取る（サブシェルにしないため戻り値は使わない）
    write_fixture enforce "$body"
    local fixture="${FIXTURE_PATH}"

    # 仮のワークフローの検査結果が本物の集計に混ざらないよう、現在の値を退避する
    local saved_pass="$PASS" saved_fail="$FAIL"
    # 本番と同じ経路へ通す（表示は集計だけを見たいので捨てる）
    check_workflow_path "$fixture" > /dev/null
    # この仮のワークフローが何件の違反を生んだかを増分から求める
    local violations=$((FAIL - saved_fail))
    # 退避しておいた集計を元に戻す
    PASS="$saved_pass"
    FAIL="$saved_fail"

    # 違反が 1 件以上あれば「強制された」、0 件なら「受理された」とみなす
    local actual="accepted"
    if [[ "$violations" -gt 0 ]]; then
        actual="enforced"
    fi

    # 期待どおりかどうかを、他の検査と同じ書式で報告する
    if [[ "$actual" == "$expected" ]]; then
        pass "pin enforcement: ${label} → ${expected}"
    else
        fail "pin enforcement: ${label} → ${expected}" \
            "the workflow was ${actual} (${violations} violation(s)); privilege classification and pin enforcement are wired together by check_workflow_path(), so this covers both"
    fi
}

# 特権判定そのものを、既知の書き方を並べた仮のワークフローで検査する関数
# 第 1 引数: 期待する判定（privileged / plain）/ 第 2 引数: 表示用の説明 / 第 3 引数: ワークフローの中身
#
# なぜここに置くか: この分類器が「特権なのに plain」と誤れば、そのワークフロー内の可変タグは
# 一切検査されないまま CI が緑になる（issue #87 で 4 形態の取りこぼしを実測）。
# 実在のワークフローを見るだけでは、今そのリポジトリに無い書き方の取りこぼしに気付けないため、
# 負例・正例を仮のファイルとして持ち込み、分類器を直接固定する。
# 上流への問い合わせを伴わないので、ネットワーク不要でここだけ先に結果が出る。
assert_privilege_classification() {
    # 引数をそれぞれ意味の分かる名前の変数に取り出す
    local expected="$1" label="$2" body="$3"
    # 判定にかけるための仮のワークフローを書き出し、そのパスを受け取る
    write_fixture fixture "$body"
    local fixture="${FIXTURE_PATH}"

    # 実際の判定結果を、期待値と同じ語彙（privileged / plain）で受け取る
    local actual="plain"
    if is_privileged_workflow "$fixture"; then
        actual="privileged"
    fi

    # 期待どおりかどうかを、他の検査と同じ書式で報告する
    if [[ "$actual" == "$expected" ]]; then
        pass "privilege classifier: ${label} → ${expected}"
    else
        fail "privilege classifier: ${label} → ${expected}" \
            "classified as '${actual}'; a workflow misread as 'plain' has its mutable action refs skipped entirely, so FR-9.6(b) stops applying to it"
    fi
}

# `split_uses_occurrences()` の出力そのものを固定する関数
# 第 1 引数: 表示用の説明 / 第 2 引数: 期待する出力（「行番号 <TAB> 参照 <TAB> マーカー」の並び）
# 第 3 引数: 仮のワークフローの中身
#
# **違反件数だけでは見分けられない性質があるため、出力を直接見る**: 版注記をどの参照へ配るかを
# 間違えても「何かしら違反になる」点は変わらず、`assert_pin_enforcement` では素通りしてしまう。
# 配り方を誤ると偽の改竄警告や注記の借用（マーカー必須検査のすり抜け）が起きるうえ、
# 本来不要な `git ls-remote` を呼んでハーメティックであるべき検査に通信を持ち込む
assert_split_output() {
    # 引数をそれぞれ意味の分かる名前の変数に取り出す
    local label="$1" expected="$2" body="$3"
    # 仮のワークフローを書き出し、そのパスを受け取る
    write_fixture split "$body"
    local fixture="${FIXTURE_PATH}"

    # 実際の分解結果を受け取る
    local actual
    actual="$(split_uses_occurrences "$fixture")"

    # 期待どおりかどうかを、他の検査と同じ書式で報告する（タブは見えないので矢印に置き換えて示す）
    if [[ "$actual" == "$expected" ]]; then
        pass "uses: splitting: ${label}"
    else
        fail "uses: splitting: ${label}" \
            "expected «${expected//$'\t'/→}» but got «${actual//$'\t'/→}»"
    fi
}

# --- 特権と判定しなければならない書き方（issue #87 の負例と、その周辺） ---

# すべてのスコープに書き込みを与える省略形。`... : write` 行が現れないため綴り探索では拾えない
assert_privilege_classification privileged 'permissions: write-all' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# 1 行で書くフロー形式。値が行末に来ないため、行末一致の綴り探索では拾えない
assert_privilege_classification privileged 'flow mapping {contents: write}' \
'name: X
permissions: {contents: write}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# 行末コメント付き。値の後ろに文字が続くため、行末一致の綴り探索では拾えない
assert_privilege_classification privileged 'trailing comment after the value' \
'name: X
permissions:
  contents: write  # explanatory note
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# reusable workflow へ全 secret を渡す形。個々の secret 名が現れないためドット付き参照では拾えない
assert_privilege_classification privileged 'secrets: inherit on a reusable workflow call' \
'name: X
permissions:
  contents: read
jobs:
  j:
    uses: some-org/some-repo/.github/workflows/verify.yml@main
    secrets: inherit'

# `secrets: inherit` に行末コメントが付く形（`inherit` の綴り一致では行末が合わず拾えない）
assert_privilege_classification privileged 'secrets: inherit with a trailing comment' \
'name: X
permissions:
  contents: read
jobs:
  j:
    uses: some-org/some-repo/.github/workflows/verify.yml@main
    secrets: inherit  # forward everything'

# `secrets: inherit` が引用符で囲まれる形（同上）
assert_privilege_classification privileged 'secrets: quoted inherit' \
"name: X
permissions:
  contents: read
jobs:
  j:
    uses: some-org/some-repo/.github/workflows/verify.yml@main
    secrets: 'inherit'"

# 名前を挙げて secret を渡すブロック形式（鍵の存在だけで拾う）
assert_privilege_classification privileged 'secrets block forwarding named secrets' \
'name: X
permissions:
  contents: read
jobs:
  j:
    uses: some-org/some-repo/.github/workflows/verify.yml@main
    secrets:
      TOKEN: placeholder'

# 添字形式の式参照。Actions の正式な書き方だがドット付き参照では拾えない
# shellcheck disable=SC2016
assert_privilege_classification privileged "indexed \${{ secrets['NAME'] }} reference" \
'name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          token: ${{ secrets['"'"'SOME_TOKEN'"'"'] }}'

# 文脈名の大文字小文字を変えた形。Actions の文脈名は大文字小文字を区別しないため、
# `secrets` の小文字だけを見ると綴りではなく「字の大小」で迂回できてしまう
# shellcheck disable=SC2016
assert_privilege_classification privileged 'capitalised ${{ Secrets.NAME }} reference' \
'name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          token: ${{ Secrets.SOME_TOKEN }}'

# 鍵側の大文字小文字（同上）
assert_privilege_classification privileged 'capitalised Secrets: inherit key' \
'name: X
permissions:
  contents: read
jobs:
  j:
    uses: some-org/some-repo/.github/workflows/verify.yml@main
    Secrets: inherit'

# 式が改行をまたぐ形。1 行ずつ見ると `${{` と `secrets` が別の行に分かれて当たらない
# shellcheck disable=SC2016
assert_privilege_classification privileged 'secrets reference split across lines' \
'name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          token: >-
            ${{
              secrets.SOME_TOKEN
            }}'

# 式の内側に `}` を含む形。式の終端ではなく最初の `}` で区切ると、参照を見落とす
# shellcheck disable=SC2016
assert_privilege_classification privileged 'secrets reference after a brace inside the expression' \
'name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          token: ${{ format('"'"'{0}'"'"', secrets.SOME_TOKEN) }}'

# `permissions:` 自身をブロックスカラーで書く形。本文を読み飛ばすと宣言ごと見えなくなるので特権に倒す
assert_privilege_classification privileged 'permissions written as a folded block scalar' \
'name: X
permissions: >-
  write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# ジョブを 1 行のフローマッピングで書く形。鍵が行頭に来ないため、行頭一致だけでは宣言が見えない
assert_privilege_classification privileged 'job written as a single-line flow mapping with permissions' \
'name: X
permissions:
  contents: read
jobs:
  j: {runs-on: ubuntu-latest, permissions: {contents: write}, steps: [{uses: actions/checkout@v7}]}'

# 同じくフローマッピングでの `secrets: inherit`。1 行に書き換えるだけでバイパスが復活してはならない
assert_privilege_classification privileged 'secrets: inherit inside a flow mapping' \
'name: X
permissions:
  contents: read
jobs:
  j: {uses: org/repo/.github/workflows/verify.yml@main, secrets: inherit}'

# ジョブ単位でだけ書き込みを与える形（ワークフロー全体の宣言は読み取り専用）
assert_privilege_classification privileged 'job-level write under a read-only workflow default' \
'name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - uses: actions/checkout@v7'

# ジョブ単位の宣言しか無い形。宣言の無いジョブがリポジトリ既定のまま動くため安全側に倒す
assert_privilege_classification privileged 'job-level permissions only (no workflow-wide default)' \
'name: X
jobs:
  j:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v7'

# `permissions:` の宣言が一切無い形（従来から特権扱い。退行させないため固定する）
assert_privilege_classification privileged 'no permissions declaration at all' \
'name: X
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# `${{ secrets.NAME }}` のドット付き参照（従来から特権扱い。退行させないため固定する）
# GitHub Actions の式をそのまま検査対象にするため、シェルに展開させず単一引用で literal のまま渡す
# shellcheck disable=SC2016
assert_privilege_classification privileged 'dotted ${{ secrets.NAME }} reference' \
'name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          token: ${{ secrets.SOME_TOKEN }}'

# 鍵を二重引用符で囲む形。鍵の綴りを 1 通りだけ数え上げると、宣言そのものが見えなくなる
assert_privilege_classification privileged 'double-quoted permissions key at job level' \
'name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    "permissions": write-all
    steps:
      - uses: actions/checkout@v7'

# 鍵を単一引用符で囲む形（同上）
assert_privilege_classification privileged 'single-quoted permissions key at job level' \
"name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    'permissions': write-all
    steps:
      - uses: actions/checkout@v7"

# コロンの前に空白を挟む形（YAML では正しい書き方）
assert_privilege_classification privileged 'space before the colon of the permissions key' \
'name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    permissions : write-all
    steps:
      - uses: actions/checkout@v7'

# 値を引用符で囲んだ書き込み権限（引用符を落として解釈できていることの確認）
assert_privilege_classification privileged 'quoted write value in a block mapping' \
'name: X
permissions:
  contents: "write"
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# 解釈できない書き方（複数行にまたがるフロー形式）は、読めた範囲で通さず特権に倒す
assert_privilege_classification privileged 'unparseable multi-line flow mapping' \
'name: X
permissions: {contents: read,
              actions: read}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# --- 非特権と判定しなければならない書き方（分類器が「常に特権」へ振り切れていないことの確認） ---
# ここが崩れると ci.yml の正当な可変タグまで違反扱いになり、CI が恒常的に赤くなる

# ブロック形式の読み取り専用宣言（ci.yml が実際に採っている形）
assert_privilege_classification plain 'read-only block mapping' \
'name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# 全スコープ読み取り専用の省略形
assert_privilege_classification plain 'permissions: read-all' \
'name: X
permissions: read-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# 空のフロー形式（全スコープ none と同義で、最も権限が狭い）
assert_privilege_classification plain 'permissions: {} (all scopes none)' \
'name: X
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# 散文として `secrets` の語が出るだけの形。ステップ名やコメントでの言及を特権扱いにすると、
# **意図的に可変タグを使っている `ci.yml`** が違反扱いになり CI が恒常的に赤くなるため、
# 「語があるか」ではなく「構文上どこに置かれているか」で判定していることを固定する
assert_privilege_classification plain 'the word secrets only in prose (step name)' \
'name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: lint (also greps for secrets)
        run: echo hi
      - uses: actions/checkout@v7'

# `run:` のブロックスカラー本文に構造そっくりの行が混じる形。本文は YAML の構造ではなくただの文字列で、
# ここを宣言と読み違えると、**意図的に可変タグを使っている `ci.yml`** が違反扱いになり CI が恒常的に赤くなる
assert_privilege_classification plain 'permissions-looking line inside a run: block scalar' \
'name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          cat <<SNIP
          permissions: write-all
          secrets: inherit
          SNIP
      - uses: actions/checkout@v7'

# 無関係な式（`${{ github.ref }}` 等）と、散文としての `secrets` が同じファイルに同居する形。
# 式の終端で区切らずに探すと、この 2 つが結び付いて「式の中の secret 参照」に見えてしまう。
# `ci.yml` は実際に `concurrency` で `${{ github.ref }}` を使っているため、これは机上の話ではない
# shellcheck disable=SC2016
assert_privilege_classification plain 'unrelated expression plus the word secrets in prose' \
'name: X
permissions:
  contents: read
concurrency:
  group: ci-${{ github.ref }}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: lint (also greps for secrets)
        run: echo hi
      - uses: actions/checkout@v7'

# 引用符付きの読み取り専用宣言（引用符を落とした結果、過剰に特権へ倒れていないことの確認）
assert_privilege_classification plain 'quoted read-only keys and values' \
'name: X
"permissions":
  "contents": "read"
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# 読み取り専用のフロー形式（フロー形式そのものを特権扱いにしていないことの確認）
assert_privilege_classification plain 'read-only flow mapping {contents: read}' \
'name: X
permissions: {contents: read}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# --- 分類とピン強制の接続（判定結果が実際に規則へ効いているか） ---

# 特権ワークフロー中の可変タグは違反として検出されなければならない（FR-9.6(b) の中心）
assert_pin_enforcement enforced 'privileged workflow with a mutable tag' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - uses: actions/checkout@v7'

# 版の指定が無い参照も、固定できていないので違反として検出されなければならない
assert_pin_enforcement enforced 'privileged workflow with an unversioned action ref' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - uses: actions/checkout'

# コンテナ参照はダイジェスト固定が必要で、タグ参照は違反として検出されなければならない
assert_pin_enforcement enforced 'privileged workflow with a mutable docker:// ref' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - uses: docker://alpine:3.20'

# 特権ワークフローに `uses:` が 1 行も無いのは、抽出条件の破損か構成変更なので違反として扱う
assert_pin_enforcement enforced 'privileged workflow with no uses: at all' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello'

# リポジトリ内のローカル action は外部から取り込まないため、特権でも咎めない
assert_pin_enforcement accepted 'privileged workflow using a local action' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local'

# `run:` のブロックスカラー本文に `uses:` そっくりの行が混じる形。本文は YAML の構造ではないので、
# 違反として数えてはならない（`post-ci-verify.yml` は常に特権扱いで、実際に長い `prompt:` ブロックを
# 持つため、ここを構造として読むと正しくピンされているファイルで CI が恒常的に赤くなる）
assert_pin_enforcement accepted 'privileged workflow with a uses:-looking line inside a run: block' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - run: |
          cat <<SNIP
          - uses: actions/checkout@v7
          SNIP'

# ブロックスカラーを値に持つ鍵（`- if: >-`）と**同じ手順の兄弟キー**が続く形。
# 本文の範囲をダッシュの桁で決めると兄弟の `uses:` まで飲み込み、可変タグが検査対象から外れる
assert_pin_enforcement enforced 'mutable tag as a sibling key of a block-scalar key' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - if: >-
          github.event_name == '"'"'push'"'"'
        uses: actions/checkout@v7'

# 鍵を引用符で囲む形。特権判定側では引用符を落としているので、抽出側も同じ形で揃っていなければならない
assert_pin_enforcement enforced 'mutable tag under a quoted uses key' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - "uses": actions/checkout@v7'

# 手順を 1 行のフローマッピングで書く形。値の直後に `}` が続くため、参照の切り出しも合わせる必要がある
assert_pin_enforcement enforced 'mutable tag inside a flow-mapping step' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - {uses: actions/checkout@v7}'

# フローマッピングの中で**正しくダイジェスト固定された**コンテナ参照。値の直後の `}` を
# 切り落とさないと固定済みの参照が未固定に見え、正しい書き方を違反として誤報する
assert_pin_enforcement accepted 'digest-pinned docker:// step inside a flow mapping' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - {uses: docker://alpine@sha256:0000000000000000000000000000000000000000000000000000000000000000}'

# コロンの前に空白を挟む鍵（YAML では正しい書き方）。特権判定側で同じ揺れを 3 度取りこぼしているので、
# 強制側でも 1 通りの綴りに絞らない
assert_pin_enforcement enforced 'mutable tag under a uses key with a space before the colon' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - uses : actions/checkout@v7'

# 1 行に `uses:` が複数あるとき、**最後の 1 個以外が検査から外れない**こと。
# 抽出が貪欲一致（`.*uses:`）だった頃は最後の 1 個しか見ておらず、後ろにローカル action を
# 並べるだけで前の可変タグが指摘 0 件で通っていた（実測。特権ワークフローで供給網ピンが無効化される）
assert_pin_enforcement enforced 'mutable tag before another uses on the same flow-sequence line' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{uses: actions/checkout@v7}, {uses: ./.github/actions/local}]'

# 同じ穴のうち、**行末コメントに `uses:` と書かれている**場合。
# 構造としての `uses:` はコメントより前にしか置けないので、値の探索対象から外す必要がある
assert_pin_enforcement enforced 'mutable tag whose trailing comment also mentions a uses key' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7  # 以前は uses: ./.github/actions/local だった'

# 1 行に並んだ複数の参照が**どちらも**検査されること（前だけ見て後ろを落とす逆向きの取りこぼし防止）
assert_pin_enforcement enforced 'mutable tag after another uses on the same flow-sequence line' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{uses: ./.github/actions/local}, {uses: actions/checkout@v7}]'

# **値の中の散文を参照と読み違えない**こと。引用符は構造行の抽出時に一律で落とされるため、
# `- name: "… workflow uses: a pinned SHA"` は素の文字列として届く。鍵になれる位置（行頭・`{` / `,` の直後）
# ではなく「空白の後ろならどこでも」で拾うと、これを参照 `a` と読んで違反を報告し、
# 特権ワークフローに同種の文言が入った時点で CI が恒常的に赤くなる（実測）
assert_pin_enforcement accepted 'prose mentioning a uses key inside a quoted value' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: "Verify that every workflow uses: a pinned SHA"
        run: echo ok
      - uses: ./.github/actions/local'

# 1 行 1 件のときは、行末の版注記をその参照のものとして渡す（従来どおりの正常系）
assert_split_output 'a single ref keeps its own trailing version marker' \
"7"$'\t'"actions/checkout@1111111111111111111111111111111111111111"$'\t'"v4" \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111  # v4'

# 仮ワークフローは検査ごとに別ファイルになること。`$(write_fixture …)` の形で受けると本体が
# サブシェルで走って連番が呼び出し元へ戻らず、同じ接頭辞のケースが 1 ファイルを上書きし続ける。
# そうなると、失敗したケースを調べようとしたときにディスクに残っているのは別ケースの内容になる
write_fixture seqcheck 'name: X'
SEQCHECK_FIRST="${FIXTURE_PATH}"
write_fixture seqcheck 'name: Y'
if [[ "${SEQCHECK_FIRST}" != "${FIXTURE_PATH}" ]]; then
    pass "fixtures: each case is written to its own file"
else
    fail "fixtures: each case is written to its own file" \
        "both calls wrote ${FIXTURE_PATH}; the sequence counter is not surviving the call, so a failing case's fixture is overwritten by a later one"
fi

# 値の途中に `#` があっても、その後ろの参照を捨てないこと。引用符は抽出時に一律で落ちるため
# `- {name: "release #1", uses: …}` の `#` は素の文字として届く。そこで行を切ると
# **未ピンの可変タグごと検査対象から消える**（「不在＝合格」への逆戻り。実測）
assert_pin_enforcement enforced 'mutable tag after a hash character inside a value' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - {name: "release #1", uses: actions/checkout@v7}'

# 値の中に閉じ括弧が紛れていても、後ろの参照を取り逃がさないこと。引用符が落ちるため
# `- {name: "a}b", uses: …}` の `}` は素の文字として届く。括弧の釣り合いを数えると深さ 0 と誤り、
# カンマを散文の読点と判定して**未ピンの参照ごと検査から消える**（「不在＝合格」への逆戻り。実測）
# **健全な `uses:` を 1 行足しておく**のが要点: これが無いと参照を取り逃がしたときに
# 「特権ワークフローに `uses:` が 1 つも無い」歯止め（`seen == 0`）の方が先に鳴ってしまい、
# 取りこぼしを入れても違反件数が 1 のままでこの表明が素通りする（実測）
assert_pin_enforcement enforced 'mutable tag after a closing brace inside a value' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - {name: "a}b", uses: actions/checkout@v7}'

# フローシーケンスの**先頭要素**に置かれた `uses:` も検査対象にすること。
# `steps: [uses: …]` は単一対のマッピングとして解釈され、実際に実行されるステップになる。
# 区切りに `[` を入れないと 1 件も抽出されず、可変タグが指摘 0 件で通る
# フロー集合が**複数行に跨る**場合も、続きの行にある `uses:` を取り逃がさないこと。
# カンマに「集合の内側か」の条件を付けると、開き括弧が前の行にあるため区切りと認められず、
# 未ピンの参照が丸ごと検査から消える（main は検出していた。実測して条件を撤回した）
assert_pin_enforcement enforced 'mutable tag reached through a comma on a continuation line' \
'name: X
permissions: write-all
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
  b:
    runs-on: ubuntu-latest
    steps: [
      name: a, uses: actions/checkout@v7
    ]'

# `uses:` の**値を次の行に置く**記法（YAML として正当）でも参照を取り逃がさないこと（issue #104）。
# 片行しか見ないと、次行の可変タグ（`@v7`）がピン検査から丸ごと外れる。しかも同じワークフローに
# 別の `uses:` が 1 つでもあれば `seen` が立つため「`uses:` が 1 つも無い」歯止めも鳴らず、
# その参照についてだけ供給網ピンが静かに無効化される（「不在＝合格」への逆戻り。実測）。
# 健全な `uses:` を 1 行足しておくのは、取りこぼしたときに歯止め側が先に鳴るのを避けるため
assert_pin_enforcement enforced 'mutable tag whose value sits on the next line' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - uses:
          actions/checkout@v7'

# 値を次行に置いた参照の**行末コメントの版注記**も、その参照のものとして取り出すこと。
# 抽出を単一行の値と共通化したので、注記の付け方は同じ規則で読める
assert_split_output 'a ref whose value sits on the next line keeps its trailing marker' \
"7"$'\t'"actions/checkout@1111111111111111111111111111111111111111"$'\t'"v4" \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses:
          actions/checkout@1111111111111111111111111111111111111111  # v4'

# `uses:` に値が一切無い（次行にも値が来ない）壊れた形は、黙って飛ばさず参照なしで書き出して
# 検査を赤くすること（fail-closed）。GitHub Actions では `uses:` の空値はそもそも実行不能で、
# 「読めなかった＝合格」に倒すのはこのファイルが繰り返し塞いできた「不在＝合格」そのもの
assert_split_output 'a uses key with no value at all yields a failing empty reference' \
"7"$'\t'$'\t' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses:
        with:
          token: x'

# 式で組み立てた**動的な参照**も検査対象から外さないこと。`${{ … }}` は実際に動く書き方であり、
# 版を固定できていないので特権ワークフローでは違反。値の形で絞り込む実装にすると
# ここが指摘 0 件になり、供給網ピンが黙って無効になる（実測して差し戻した経緯がある）
# shellcheck disable=SC2016  # YAML の中身をそのまま書くので `${{ }}` は展開させない
assert_pin_enforcement enforced 'a reference built from an expression is still checked' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - uses: ${{ inputs.action_ref }}'

# 行末コメントの中の `] uses:` を鍵と読み違えないこと。`]` はフロー集合を**閉じる**文字なので
# 鍵の直前に来ることはない。区切りの文字集合に紛れ込ませると、散文で偽の参照を報告する
assert_pin_enforcement accepted 'prose containing a closing bracket before a uses key' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
      - name: see FR-9.6(b)] uses: acme/thing for details
        run: echo ok'

# 健全な `uses:` は**別のジョブ**に置く（同じ行に足すと `[` を外した退行を隠してしまうため）
assert_pin_enforcement enforced 'mutable tag as the first entry of a flow sequence' \
'name: X
permissions: write-all
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/local
  b:
    runs-on: ubuntu-latest
    steps: [uses: actions/checkout@v7]'

# 版注記は**参照より後ろのコメント**から取ること。先頭から最初のコメント開始を探すと、
# 引用符が落ちた値の中の `#1` を拾って `1,` をマーカーと誤読し、存在しないタグを上流へ
# 問い合わせて「タグの綴り誤りでは」と的外れな診断を出す（通信も無駄に発生する）
assert_split_output 'the version marker is taken from the comment that follows the ref' \
"7"$'\t'"actions/checkout@1111111111111111111111111111111111111111"$'\t'"v4" \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - {name: "release #1", uses: actions/checkout@1111111111111111111111111111111111111111}  # v4'

# 参照より後ろに値の中の `#` が現れても、それを注記と取り違えないこと。
# `- {uses: …, name: "release #1"}  # v4` では `#1}` が先に現れるので、
# 最初の `#` で打ち切ると `1}` を注記と誤読し、存在しないタグを上流へ問い合わせる
assert_split_output 'a hash inside a value after the ref does not steal the version marker' \
"7"$'\t'"actions/checkout@1111111111111111111111111111111111111111"$'\t'"v4" \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - {uses: actions/checkout@1111111111111111111111111111111111111111, name: "release #1"}  # v4'

# 裸の数字列は版注記として認めないこと。`# bump #12 -> v5` の `12` を版と読むと、
# 存在しないタグを上流へ問い合わせて「綴り誤りでは」と原因を指し違えた診断を出す。
# 注記として認めないので「マーカーが無い」として赤くなる（＝注記の書き方を直せ、という正しい指摘）
assert_split_output 'a bare issue number is not accepted as a version marker' \
"7"$'\t'"e/f@1111111111111111111111111111111111111111"$'\t' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: e/f@1111111111111111111111111111111111111111  # bump #12 -> v5'

# 版注記は**コメントの最初の語**だけを見ること。`#` がもう一度出てくる書き方（issue 番号の参照など）で
# 貪欲一致すると `42)` をマーカーと誤読し、存在しないタグを上流へ問い合わせて
# 「タグの綴り誤りでは」と原因を指し違えた診断を出す（fail-closed だが誤診で、通信も無駄に発生する）
assert_split_output 'a version marker followed by another hash is read as the first word only' \
"7"$'\t'"actions/checkout@1111111111111111111111111111111111111111"$'\t'"v1.2.3" \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111  # v1.2.3 (fixes #42)'

# 1 行に複数の参照があるとき、**行末の版注記を全件へ配らない**こと。
# 配ると (a) 別々の SHA に同じ版を突き合わせて偽の改竄警告を出し、
# (b) 自分の注記を持たない参照が隣の注記を借りて「マーカーが無い」検査をすり抜ける。
# どちらを指す注記か決められない以上、各参照は注記なしとして扱う（fail-closed）
assert_split_output 'two refs on one line do not share the single trailing marker' \
"6"$'\t'"a/b@1111111111111111111111111111111111111111"$'\t'"
6"$'\t'"c/d@2222222222222222222222222222222222222222"$'\t' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{uses: a/b@1111111111111111111111111111111111111111}, {uses: c/d@2222222222222222222222222222222222222222}]  # v1.2.3'

# 注記を配らない結果として、各参照は「マーカーが無い」として素直に赤くなる（通信も発生しない）
assert_pin_enforcement enforced 'one trailing version marker shared by two refs on the same line' \
'name: X
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{uses: a/b@1111111111111111111111111111111111111111}, {uses: c/d@2222222222222222222222222222222222222222}]  # v1.2.3'

# 非特権ワークフローの可変タグは FR-9.6(b) の対象外なので咎めない（`ci.yml` が実際に依存している挙動）
assert_pin_enforcement accepted 'plain workflow with a mutable tag' \
'name: X
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7'

# 下限リストに挙げた特権ワークフローが実在することを先に確かめる
# （改名・削除で検査対象ごと消えた場合に「対象なし＝合格」とならないようにする）
for wf in "${ALWAYS_PRIVILEGED[@]}"; do
    # 対象ファイルの絶対パスを組み立てる
    wf_path="${WORKFLOW_DIR}/${wf}"
    # ファイルが存在しない＝改名・削除・移動なので、黙って飛ばさず失敗として報告する
    if [[ ! -f "$wf_path" ]]; then
        fail "${wf} exists (FR-9.6(b))" \
            "expected a privileged workflow at ${wf_path} but it is missing; it was renamed, moved, or deleted"
    fi
done

# ワークフロー定義ファイルを 1 つずつ、実際の検査経路（`check_workflow_path`）に通す
while IFS= read -r wf_path; do
    # 特権判定から `uses:` 検査までを、回帰テストと同じ 1 本の経路で実行する
    check_workflow_path "$wf_path"
# ワークフロー定義ファイルを名前順に列挙する（実行結果を再現しやすくするため）
done < <(find "$WORKFLOW_DIR" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)

# --- 網羅性テスト自身の配線を、別のスイートから固定する -------------------------------
#
# `test/ci_coverage_test.sh` は「全スイートが ci.yml から実行されているか」を検査するが、
# **自分のステップが無効化された場合だけは自分で気付けない**（走らなくなるので何も言わない）。
# その結果、以後の追記漏れ・未配線スイートが一切検出されないまま CI は緑で通る。
# 検査の連鎖はどこかで別のスイートに支えさせる必要があるので、常時実行される本スイートから
# 1 件だけ固定する（`test/sec18_denylist_test.sh` が e2e 側の配線を固定しているのと同じ前例）。
#
# 判定は**共有ライブラリに委ねる**（読み込みはこのファイルの冒頭で済ませてある）。
# ここに独自の grep を書くと、当初そうしたように行末コメントや `name:` の言及でも
# 「配線されている」と読む弱い版になり、**支え役のはずの表明が最初に破れる**（レビューで実測）

# 抽出結果を置く一時ファイル（このスイートが既に持っている TEST_TMP の下に作る）
COVERAGE_WIRING_TMP="${TEST_TMP}/ci-commands"
# ci.yml の実行内容を読み込む
if ! ci_workflow_load "${WORKFLOW_DIR}/ci.yml" "${COVERAGE_WIRING_TMP}"; then
    fail 'ci.yml still runs test/ci_coverage_test.sh (coverage net is wired)' \
        "could not read the run: steps from ${WORKFLOW_DIR}/ci.yml, so the coverage step's wiring could not be verified"
# 網羅性テストが実際に実行されていることを確かめる
elif ci_workflow_runs_script 'test/ci_coverage_test.sh'; then
    pass 'ci.yml still runs test/ci_coverage_test.sh (coverage net is wired)'
else
    fail 'ci.yml still runs test/ci_coverage_test.sh (coverage net is wired)' \
        "the CI coverage step no longer gates in ${WORKFLOW_DIR}/ci.yml; without it, scripts missing from SHELL_FILES and unwired suites stop being detected and CI stays green"
fi

# 検査結果の合計を、他のテストスイートと同じ書式で出力する
printf '\n# %d passed, %d failed\n' "$PASS" "$FAIL"

# 失敗が 1 件でもあれば異常終了して CI を赤くする
[[ "$FAIL" -eq 0 ]]
