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

    # secret を参照するワークフローは、漏洩すれば影響が出るため特権として扱う
    if grep -qE 'secrets\.[A-Za-z_]' "$path"; then
        return 0
    fi

    # 書き込み権限（`... : write`）を明示的に与えているワークフローは特権として扱う
    if grep -qE '^[[:space:]]*[a-z-]+:[[:space:]]*write[[:space:]]*$' "$path"; then
        return 0
    fi

    # `permissions:` の宣言自体が無い場合、既定値がリポジトリ設定次第で書き込み可能になりうるため、
    # 安全側に倒して特権として扱う（不明なら拒否＝fail-closed の方針に合わせる）
    if ! grep -qE '^[[:space:]]*permissions:' "$path"; then
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

# 1 行の `uses:` を検査する関数
# 第 1 引数: ワークフローのファイル名 / 第 2 引数: 行番号 / 第 3 引数: 行の内容
# 第 4 引数: その行が特権ワークフローのものなら "privileged"、それ以外は "plain"
check_uses_line() {
    # 引数をそれぞれ意味の分かる名前の変数に取り出す
    local wf_name="$1" lineno="$2" content="$3" scope="$4"
    local ref action pinned marker label

    # `uses:` の値（参照文字列の全体）を取り出す
    ref="$(printf '%s' "$content" | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*([^[:space:]]+).*/\2/')"
    # YAML では値を引用符で囲めるため、URL に混入しないよう `'` と `"` を取り除く
    ref="${ref//\'/}"
    ref="${ref//\"/}"
    # 行末のコメントに書かれたバージョンマーカーを取り出す（`v` 接頭辞は付かない上流もあるため任意とする）
    marker="$(printf '%s' "$content" | sed -nE 's/.*#[[:space:]]*(v?[0-9][^[:space:]]*).*/\1/p')"
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

    # `uses:` 行を行番号付きで 1 行ずつ読み取って検査する。
    # ここでは参照の形（`@` の有無・`docker://`・ローカル参照）で絞り込まない。
    # 絞り込むと「該当形式でない＝検査対象なし＝合格」という取りこぼしが生まれるため。
    # YAML では手順の先頭要素が `- uses:` と書かれることもあるため、行頭の `- ` も許容する
    while IFS= read -r entry; do
        # 「行番号:行の内容」の形なので、まず行番号を取り出す
        local lineno="${entry%%:*}"
        # 続けて実際の行の内容を取り出す
        local content="${entry#*:}"
        # `uses:` 行を 1 件見つけたことを記録する
        seen=1
        # 取り出した 1 行を検査する
        check_uses_line "$wf_name" "$lineno" "$content" "$scope"
    done < <(grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]' "$path" || true)

    # 特権ワークフローに `uses:` が 1 行も無いのは、抽出条件の破損か構成変更を意味するため失敗にする
    # （検査対象が消えたことを「合格」と読み替えないための歯止め）
    if [[ "$scope" == "privileged" && "$seen" -eq 0 ]]; then
        fail "${wf_name} contains at least one action to verify" \
            "no 'uses:' reference found; the workflow was restructured, or this checker's matcher no longer recognises its syntax"
    fi
}

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

# ワークフロー定義ファイルを 1 つずつ、特権かどうかを内容から判定したうえで検査する
while IFS= read -r wf_path; do
    # このファイルが特権かどうかを内容から判定し、適用する規則を決める
    if is_privileged_workflow "$wf_path"; then
        check_workflow_file "$wf_path" "privileged"
    else
        check_workflow_file "$wf_path" "plain"
    fi
# ワークフロー定義ファイルを名前順に列挙する（実行結果を再現しやすくするため）
done < <(find "$WORKFLOW_DIR" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)

# 検査結果の合計を、他のテストスイートと同じ書式で出力する
printf '\n# %d passed, %d failed\n' "$PASS" "$FAIL"

# 失敗が 1 件でもあれば異常終了して CI を赤くする
[[ "$FAIL" -eq 0 ]]
