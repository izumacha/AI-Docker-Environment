#!/usr/bin/env bash
# harness.sh - shared PASS/FAIL counters and assertions for the test suites.
#
# Why this exists: guard_test.sh, entrypoint_test.sh and action_pin_test.sh each
# grew their own copy of the same counters, report() formatter and assert_*
# helpers. CLAUDE.md §6 asks for extraction at the second or third occurrence,
# and docs/requirements.md's 2026-08-09 entry deferred it because retrofitting
# those three suites means touching 148 established cases. This file stops the
# count from growing: new suites source it instead of copying, and the existing
# three can be migrated later without that migration blocking anything.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/harness.sh"
#   assert_status 0 "..."      # compares against LAST_STATUS
#   assert_contains "x" "..."  # searches LAST_OUTPUT
#   harness_summary            # prints the tally and returns non-zero on failure
#
# The caller sets LAST_STATUS / LAST_OUTPUT before the assertions that read them.

# 成功したテストの件数
PASS=0
# 失敗したテストの件数
FAIL=0

# 直近の実行の終了コード（呼び出し側が設定する）
LAST_STATUS=0
# 直近の実行の出力（標準出力＋標準エラー。呼び出し側が設定する）
LAST_OUTPUT=""

# 期待どおりなら PASS、違えば FAIL を数えて内容を表示する共通ヘルパー
report() {
    # 第 1 引数が 0 なら成功として数える
    if [[ "$1" -eq 0 ]]; then
        PASS=$((PASS + 1))
        printf 'ok   - %s\n' "$2"
    else
        FAIL=$((FAIL + 1))
        # 失敗の表記は既存 3 スイート（guard / entrypoint / action_pin）の `FAIL - ` に揃える。
        # 揃えておかないと、それらを本ハーネスへ移行した時点で 148 ケースの出力書式が
        # 一斉に変わり、移行の差分にログ書式の変更が混ざる（§6 変更は最小スコープに）
        printf 'FAIL - %s\n' "$2"
        # 失敗時は原因調査のため直近の実行結果を出す
        printf '       status=%s\n' "${LAST_STATUS}"
        printf '       output=%s\n' "${LAST_OUTPUT}"
    fi
}

# 終了コードが期待値と一致することを確認する
assert_status() {
    # set -e で中断しないよう if で受ける
    if [[ "${LAST_STATUS}" -eq "$1" ]]; then
        report 0 "$2"
    else
        report 1 "$2"
    fi
}

# 出力に指定した文字列が含まれることを確認する
assert_contains() {
    # 部分一致で探す
    if [[ "${LAST_OUTPUT}" == *"$1"* ]]; then
        report 0 "$2"
    else
        report 1 "$2"
    fi
}

# 出力に指定した文字列が**含まれない**ことを確認する。
# 「余計なことを言っていない」ことを主張したい場面で使う（案内・警告の出しすぎの検出）
assert_not_contains() {
    # 部分一致で探し、見つからなければ成功
    if [[ "${LAST_OUTPUT}" != *"$1"* ]]; then
        report 0 "$2"
    else
        report 1 "$2"
    fi
}

# 指定したファイルに文字列が含まれることを確認する
assert_file_contains() {
    # **複数行の needle を拒否する**: grep -F は改行を「候補の区切り」として扱うため、
    # 抽出結果をそのまま渡して想定より多い行が来ると「どれか 1 行でも当たれば合格」に化け、
    # 全部揃っていなくても緑になる（当たってほしい文字列が消えたことに気付けない）。
    # 1 行に絞るのは呼び出し側の責任なので、崩れたら検査できなかったものとして失敗させる
    if [[ "$2" == *$'\n'* ]]; then
        report 1 "$3"
        return
    fi
    # 固定文字列として探す（見つからない・ファイルが無い、いずれも失敗側に倒れる）
    if grep -qF -- "$2" "$1" 2> /dev/null; then
        report 0 "$3"
    else
        report 1 "$3"
    fi
}

# 指定したファイルに文字列が**含まれない**ことを確認する。
# **「見つからない」と「検査できなかった」を必ず分ける**のが要点: grep は文字列が無いとき
# （終了コード 1）だけでなく、ファイルが無い・ディレクトリを渡された・読めない
# （いずれも 2）でも非ゼロを返す。素直に `if ! grep …; then 合格` と書くと後者まで
# 合格へ倒れ、パスの打ち間違いや捕捉ファイルの作り忘れが緑のまま通る
# （このリポジトリが繰り返し踏んだ「不在＝合格」）。
assert_file_not_contains() {
    # 通常ファイルであることをまず要求する（姉妹の assert_file_ascii / assert_file_empty と同じ理由）。
    # -r だけでは足りない: 読めるディレクトリは -r を満たしつつ grep を 2 で失敗させる
    if [[ ! -f "$1" ]]; then
        report 1 "$3"
        return
    fi
    # 終了コードを捨てずに受け取る。**`|| 代入` の形にする**のは、呼び出し元が `set -e` の
    # ときに grep の 1（＝合格に相当する結果）でスクリプトが止まってしまうため
    local grep_status=0
    grep -qF -- "$2" "$1" || grep_status=$?
    # 1 = 見つからなかった（これだけが合格）。0 = 見つかった、2 以上 = grep が検査できなかった
    if [[ "${grep_status}" -eq 1 ]]; then
        report 0 "$3"
    else
        report 1 "$3"
    fi
}

# 指定したファイルが ASCII だけで構成されていることを確認する。
# **判定の失敗を「合格」に倒さない**のが要点: `grep -qP` は PCRE 非対応の grep や
# ファイル不在で終了コード 2 を返すため、`if grep …; then 失敗; else 合格; fi` と書くと
# 「検査できなかった」が黙って PASS になる（このリポジトリが繰り返し踏んだ「不在＝合格」）。
# ここでは tr で ASCII 範囲の文字をすべて捨て、**残りが空かどうか**という
# 移植性のある形で判定する（tr はどの環境にもあり、PCRE も要らない）。
assert_file_ascii() {
    # ファイルが無ければ検査不能なので失敗にする
    if [[ ! -f "$1" ]]; then
        report 1 "$2"
        return
    fi
    # 0x00-0x7F（ASCII）を削除した残りを取り出す。非 ASCII バイトがあればここに残る
    local non_ascii
    non_ascii="$(LC_ALL=C tr -d '\000-\177' < "$1")"
    # 残りが空なら ASCII のみ
    if [[ -z "${non_ascii}" ]]; then
        report 0 "$2"
    else
        report 1 "$2"
    fi
}

# 指定したファイルが**存在したうえで空**であることを確認する。
# **不在を合格に倒さない**: 「何も記録されなかったこと」を主張したい場面で使うため、
# ファイルが無い（＝そもそも記録の仕組みが動いていない）場合は失敗にする
assert_file_empty() {
    # ファイルが無ければ検査不能なので失敗にする
    if [[ ! -f "$1" ]]; then
        report 1 "$2"
        return
    fi
    # 中身が空（サイズ 0）なら成功
    if [[ ! -s "$1" ]]; then
        report 0 "$2"
    else
        report 1 "$2"
    fi
}

# 指定したファイルが存在しないことを確認する
assert_missing() {
    # ファイルが無ければ成功
    if [[ ! -e "$1" ]]; then
        report 0 "$2"
    else
        report 1 "$2"
    fi
}

# 指定したファイルが存在することを確認する
assert_exists() {
    # ファイルがあれば成功
    if [[ -e "$1" ]]; then
        report 0 "$2"
    else
        report 1 "$2"
    fi
}

# パス数とフェイル数を集計して概要を出し、失敗があれば非ゼロを返す
harness_summary() {
    printf '\n# %d passed, %d failed\n' "${PASS}" "${FAIL}"
    # フェイルが 1 件でもあればテストスイートを失敗させる
    [[ "${FAIL}" -eq 0 ]]
}
