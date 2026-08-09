#!/usr/bin/env bash
# action_pin_test.sh - verifies that every SHA-pinned GitHub Action in
# .github/workflows/ still resolves to the release tag named by its trailing
# `# vX.Y.Z` marker (FR-9.6b).
#
# Why this exists: FR-9.6(b) pins the actions used by the privileged
# post-ci-verify job (pull-requests: write + CLAUDE_CODE_OAUTH_TOKEN) to full
# commit SHAs, and now names the trailing marker as the single source of truth
# for which release each SHA is. That promotion is only meaningful if the two
# actually agree -- and nothing enforced it. The pin and the marker are edited
# by different actors (Dependabot rewrites both together; a human bumping by
# hand can easily touch one and not the other), so a marker naming a different
# release than the SHA would sail through CI green. The next person to audit
# the pin then follows the documented procedure correctly, gets a mismatch
# against a perfectly good SHA, and is pushed toward the exact failure FR-9.6
# exists to prevent: "correcting" a sound pin, or distrusting it.
#
# This closes that gap the same way test/guard_test.sh covers SEC-8 and
# test/entrypoint_test.sh covers SEC-13 -- by making the invariant a CI
# assertion rather than a documented intention. It doubles as tamper
# detection: if an upstream force-moves a release tag away from the commit we
# pinned, this fails instead of going unnoticed.
#
# Not hermetic: resolving a tag requires reaching the upstream repository, so
# unlike the other suites this one needs network. It runs in the type-check
# job, which already fetches pinned lint tools over the network. Network or
# resolution failure is treated as FAILURE, never as a skip -- a supply-chain
# check that quietly passes when it cannot verify anything is worse than none.

# エラー発生時に即座に停止し、未定義変数の参照もエラーにする（安全なスクリプト実行の基本設定）
set -euo pipefail

# このスクリプト自身が置かれているディレクトリの絶対パスを取得する
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# リポジトリのルートディレクトリ（SCRIPT_DIR の一つ上）を絶対パスで求める
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
# 検査対象となるワークフロー定義の置き場所を決める
WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"

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
    [ $# -ge 2 ] && printf '       %s\n' "$2"
    # 失敗件数を 1 つ増やす
    FAIL=$((FAIL + 1))
}

# 指定したリポジトリのタグが実際に指しているコミット SHA を求める関数
# 第 1 引数: リポジトリの URL / 第 2 引数: タグ名（例 v1.0.186）
resolve_tag_commit() {
    # 引数で受け取ったリポジトリ URL を変数に入れる
    local url="$1"
    # 引数で受け取ったタグ名を変数に入れる
    local tag="$2"
    # ls-remote の出力を受け取る変数をあらかじめ用意する
    local out

    # タグ本体と peel 済み参照の両方をまとめて問い合わせる。
    # annotated タグは `^{}` 行に実コミットを返すが、lightweight タグには
    # `^{}` 行が無くタグ自身が直接コミットを指すため、両方を聞かないと
    # 一方の種類でだけ 0 行になる（上流は両方の種類を混在させている）。
    if ! out="$(git ls-remote "$url" "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null)"; then
        # 問い合わせ自体が失敗した場合は、黙って通さず空文字で失敗を知らせる
        printf ''
        return 0
    fi

    # `^{}` 行があれば、それが annotated タグの指す実コミットなので最優先で採用する
    local peeled
    peeled="$(printf '%s\n' "$out" | awk -v t="refs/tags/${tag}^{}" '$2 == t {print $1; exit}')"
    # peel 済みの SHA が得られたら、それを結果として返して終了する
    if [ -n "$peeled" ]; then
        printf '%s' "$peeled"
        return 0
    fi

    # `^{}` 行が無い＝lightweight タグなので、タグ自身が指す SHA を採用する
    printf '%s\n' "$out" | awk -v t="refs/tags/${tag}" '$2 == t {print $1; exit}'
}

# 検査対象となった行が 1 件でもあったかを記録するフラグ
FOUND_ANY=0

# ワークフロー内の「SHA でピンされた action」の行をすべて洗い出して 1 件ずつ検査する
# 対象は `uses: owner/repo@<40桁のSHA>` の形をした行に限る（可変タグ指定は対象外）
while IFS= read -r entry; do
    # 抽出結果は「ファイル名:行番号:行の内容」の形なので、まずファイル名を取り出す
    file="${entry%%:*}"
    # 残りの「行番号:行の内容」部分を取り出す
    rest="${entry#*:}"
    # そこから行番号だけを取り出す
    lineno="${rest%%:*}"
    # 実際の行の内容を取り出す
    content="${rest#*:}"

    # 検査対象の行が見つかったことを記録する
    FOUND_ANY=1

    # 行から「owner/repo」の部分（`uses:` と `@` の間）を取り出す
    action="$(printf '%s' "$content" | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*([^@[:space:]]+)@.*/\2/')"
    # 行からピンされている 40 桁のコミット SHA を取り出す
    pinned="$(printf '%s' "$content" | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^@[:space:]]+@([0-9a-f]{40}).*/\2/')"
    # 行末のコメントに書かれたバージョンマーカー（例 v1.0.186）を取り出す
    marker="$(printf '%s' "$content" | sed -nE 's/.*#[[:space:]]*(v[0-9][^[:space:]]*).*/\1/p')"

    # 表示用に「ファイル名:行番号 の action 名」という短いラベルを組み立てる
    label="$(basename "$file"):${lineno} ${action}"

    # マーカーが無いとどの版にピンしているか機械的に判定できないため、失敗として扱う
    if [ -z "$marker" ]; then
        fail "${label} has a version marker" \
            "SHA-pinned but no trailing '# vX.Y.Z' marker; FR-9.6b makes that marker the source of truth for the pinned release"
        continue
    fi

    # マーカーが指すタグが実際に指しているコミットを上流に問い合わせて求める
    actual="$(resolve_tag_commit "https://github.com/${action}" "$marker")"

    # 問い合わせに失敗した／該当タグが見つからない場合は、通さずに失敗にする（fail-closed）
    if [ -z "$actual" ]; then
        fail "${label} marker ${marker} resolves upstream" \
            "could not resolve refs/tags/${marker} at https://github.com/${action} (network failure, or the tag was deleted or renamed upstream)"
        continue
    fi

    # 求めたコミットとピンされている SHA が一致すればマーカーは正しい
    if [ "$actual" = "$pinned" ]; then
        pass "${label} is pinned to ${marker} (${pinned:0:12}…)"
    else
        # 一致しない場合は、どちらが正しいか人が判断できるよう両方の SHA を出す
        fail "${label} marker ${marker} matches the pinned SHA" \
            "pinned ${pinned} but ${marker} points at ${actual}; either the SHA or the marker was changed without the other"
    fi
# `uses: owner/repo@<40桁のSHA>` にあたる行だけを、ファイル名と行番号付きで拾い上げる。
# YAML では手順の先頭要素が `- uses:` と書かれることもあるため、行頭の `- ` も許容する
# （これを取りこぼすと、ピンされた action が検査されないまま CI が緑になる）
done < <(grep -rnE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}' "${WORKFLOW_DIR}" || true)

# ピンされた action が 1 件も見つからないのは、抽出条件の破損かピンの撤去を意味するため失敗にする
if [ "$FOUND_ANY" -eq 0 ]; then
    fail "at least one SHA-pinned action is present" \
        "found none under ${WORKFLOW_DIR}; FR-9.6b requires the privileged workflow's actions to be SHA-pinned"
fi

# 検査結果の合計を、他のテストスイートと同じ書式で出力する
printf '\n# %d passed, %d failed\n' "$PASS" "$FAIL"

# 失敗が 1 件でもあれば異常終了して CI を赤くする
[ "$FAIL" -eq 0 ]
