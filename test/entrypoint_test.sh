#!/usr/bin/env bash
# entrypoint_test.sh - unit tests for docker/entrypoint.sh's SEC-13 double-key
# fail-closed logic (AIDOCK_SKIP_FIREWALL / AIDOCK_INSECURE_ACK).
#
# Why this exists: every other fail-closed security mechanism in this repo
# (guard_workspace()'s SEC-8 paths, the SEC-18 host-root guard, SEC-19's
# AIDOCK_PROFILE pinning, FR-1.5's firewall-refresh discovery flags) has a
# hermetic regression test in test/guard_test.sh. entrypoint.sh's SEC-13
# double-key requirement -- arguably the single most consequential fail-closed
# check in the repo, since it decides whether the egress firewall (the
# product's primary defense) is allowed to be skipped at all -- had no
# automated coverage anywhere (neither type-check nor e2e): a regression that
# weakened the check (e.g. accepting any truthy value, or dropping the second
# key) would go undetected until someone noticed unrestricted egress in
# production. This closes that gap the same way test/guard_test.sh closes it
# for bin/aidock.
#
# Hermetic: entrypoint.sh's two SEC-13 "skip" branches never reach
# /usr/local/bin/init-firewall.sh (the failure path `exit 1`s first; the
# acknowledged-skip path explicitly skips it), so only `gosu` needs a PATH
# stub. The default/no-skip path still does not RUN the real init-firewall.sh
# (that needs root/iptables/ipset and is covered by the e2e job's AC-1 startup
# probes against a real container), but it is asserted on: the suite checks
# that the default path takes neither SEC-13 branch AND that it actually
# reaches the init-firewall.sh invocation -- otherwise deleting, backgrounding
# or `|| true`-ing that line would go undetected (all three were measured
# green before those assertions existed).
#
# That check assumes /usr/local/bin/init-firewall.sh is ABSENT on the test
# host, which is true on CI (runs-on: ubuntu-latest, no container) but false
# inside this project's own image, where the Dockerfile installs it. A
# precondition below fails fast with that reason rather than reporting a
# confusing assertion failure.

# エラー発生時に即座に停止し、未定義変数の参照もエラーにする（安全なスクリプト実行の基本設定）
set -euo pipefail

# このスクリプト自身が置かれているディレクトリの絶対パスを取得する
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# リポジトリのルートディレクトリ（SCRIPT_DIR の一つ上）を絶対パスで求める
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
# テスト対象となる entrypoint.sh のパスを設定する
ENTRYPOINT="${REPO_ROOT}/docker/entrypoint.sh"

# gosu 呼び出しに到達したことを示すセンチネル文字列（gosu スタブが出力する）
GOSU_SENTINEL="__AIDOCK_ENTRYPOINT_GOSU_REACHED__"

# 既定パスの検査は「/usr/local/bin/init-firewall.sh がこのホストに存在しない」ことを
# 前提にしている（存在しなければ起動が必ず失敗し、gosu に到達しないため）。
#
# **このスイートをコンテナの中で走らせるとその前提が崩れる。** docker/Dockerfile は
# init-firewall.sh をまさにそのパスへ COPY して 0755 を与えるので、`./bin/aidock shell`
# の中から実行すると (a) 前提が成り立たず検査が理由の分からない赤になり、
# (b) root + NET_ADMIN なら**本物のファイアウォール初期化が走って稼働中の
# iptables / ipset を作り直す**という副作用まで出る。
#
# 黙って誤検出するより、前提が崩れていることを名指しして止める（fail-closed）。
if [[ -e /usr/local/bin/init-firewall.sh ]]; then
    printf 'precondition failed: /usr/local/bin/init-firewall.sh exists on this host.\n' >&2
    printf '  This suite must run OUTSIDE the container (CI does: runs-on ubuntu-latest).\n' >&2
    printf '  Inside the image that path is installed, so the default-path assertions\n' >&2
    printf '  cannot hold and running them would re-execute the real firewall init.\n' >&2
    exit 1
fi

# テスト用の一時ディレクトリを作成する
WORK="$(mktemp -d)"
# gosu スタブを置くディレクトリパスを設定する
STUB_DIR="${WORK}/stub"
# スタブディレクトリを実際に作成する
mkdir -p "$STUB_DIR"

# テスト終了時（EXIT シグナル）に一時ディレクトリを掃除するトラップを設定する
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- stubs ------------------------------------------------------------------
# gosu: entrypoint.sh の最終行 `exec gosu agent "$@"` を横取りし、実際の
# 権限降格を行わずに到達をセンチネルと引数で可観測にする（本物の gosu は
# root 権限や実際の agent ユーザーを要求するためテスト環境では動かせない）
cat >"${STUB_DIR}/gosu" <<EOF
#!/usr/bin/env bash
# 到達したことを示すセンチネルと、渡された引数全体を標準出力に出力する
printf '%s %s\n' "${GOSU_SENTINEL}" "\$*"
exit 0
EOF
# スタブに実行権限を付与する
chmod +x "${STUB_DIR}/gosu"

# スタブディレクトリを PATH の先頭に追加して本物の gosu より優先させる
# （本物の gosu が入っていないホストでも動くよう、意図的に PATH 全体を
# 差し替えるのではなく前置するだけに留める）
export PATH="${STUB_DIR}:${PATH}"

# --- assertion helpers (mirrors test/guard_test.sh) -------------------------
# テスト全体のパス数を 0 で初期化する
PASS=0
# テスト全体のフェイル数を 0 で初期化する
FAIL=0

# run_entrypoint <extra-env-assignments-as-string> -- run entrypoint.sh with
# AIDOCK_SKIP_FIREWALL/AIDOCK_INSECURE_ACK explicitly cleared unless overridden
# by the caller-supplied env(1) assignments; sets RC and OUT.
# entrypoint.sh を指定した環境変数で実行し、終了コードを RC、出力を OUT に格納する関数
run_entrypoint() {
    # env(1) に渡す "KEY=VALUE" 形式の引数をそのまま受け取る（可変長）
    RC=0
    # env -i ではなく env で現在の環境を維持しつつ、呼び出し元が指定したキーだけ上書きする
    # （AIDOCK_SKIP_FIREWALL/AIDOCK_INSECURE_ACK は毎回明示的に渡し、アンビエント値に依存しない）
    OUT="$(env "$@" bash "$ENTRYPOINT" some-cmd 2>&1)" || RC=$?
}

# 終了コードが期待値と一致するか確認し、結果を PASS/FAIL カウントに反映する関数
assert_exit() {
    # 期待する終了コード
    local want="$1"
    # テストの説明文
    local desc="$2"
    # 実際の終了コードが期待値と一致すれば合格とする
    if [[ "$RC" -eq "$want" ]]; then
        printf 'ok   - %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        # 不一致の場合は FAIL を記録し、詳細を出力する
        printf 'FAIL - %s (want exit %s, got %s)\n' "$desc" "$want" "$RC"
        printf '       output: %s\n' "$OUT"
        FAIL=$((FAIL + 1))
    fi
}

# 出力に特定の文字列が含まれるか確認し、結果を PASS/FAIL カウントに反映する関数
assert_contains() {
    # 出力に含まれるべき文字列（針）
    local needle="$1"
    # テストの説明文
    local desc="$2"
    # OUT に needle が含まれていれば合格とする
    if [[ "$OUT" == *"$needle"* ]]; then
        printf 'ok   - %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf 'FAIL - %s (output did not contain %q)\n' "$desc" "$needle"
        printf '       output: %s\n' "$OUT"
        FAIL=$((FAIL + 1))
    fi
}

# 出力に特定の文字列が含まれないことを確認する関数
assert_not_contains() {
    # 出力に含まれてはいけない文字列（針）
    local needle="$1"
    # テストの説明文
    local desc="$2"
    # OUT に needle が含まれていなければ合格とする
    if [[ "$OUT" != *"$needle"* ]]; then
        printf 'ok   - %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf 'FAIL - %s (output unexpectedly contained %q)\n' "$desc" "$needle"
        printf '       output: %s\n' "$OUT"
        FAIL=$((FAIL + 1))
    fi
}

# テスト開始を示すヘッダーを出力する
echo "# entrypoint.sh SEC-13 unit tests (AIDOCK_SKIP_FIREWALL / AIDOCK_INSECURE_ACK)"

# --- 1. skip alone must fail-closed ------------------------------------------
# AIDOCK_SKIP_FIREWALL=1 だけを設定し、AIDOCK_INSECURE_ACK は明示的に未設定
# （unset）にして実行する。二重キーが揃っていないため fail-closed で exit 1
# となることを確認する（issue #33 / SEC-13）。
run_entrypoint -u AIDOCK_INSECURE_ACK AIDOCK_SKIP_FIREWALL=1
assert_exit 1 "AIDOCK_SKIP_FIREWALL=1 alone (ACK unset) fails closed with exit 1"
assert_contains "REFUSING TO START" "refusal message emitted for missing ACK"
assert_contains "AIDOCK_INSECURE_ACK=1" "refusal message names the required second key"
assert_not_contains "WARNING: egress firewall SKIPPED" "insecure-skip warning banner NOT printed on refusal"

# --- 2. skip with an explicit non-affirmative ACK must still fail-closed ----
# AIDOCK_INSECURE_ACK が明示的に "0" の場合も（未設定と同様に）拒否されることを
# 確認する。unset と "0" で挙動が分岐しない（どちらも「未確認」として扱われる）
# ことの回帰検出。
run_entrypoint AIDOCK_SKIP_FIREWALL=1 AIDOCK_INSECURE_ACK=0
assert_exit 1 "AIDOCK_SKIP_FIREWALL=1 with AIDOCK_INSECURE_ACK=0 still fails closed"
assert_contains "REFUSING TO START" "refusal message emitted for ACK=0"

# --- 3. a non-"1" truthy-looking ACK value must NOT satisfy the second key --
# "true"/"yes" のような真値っぽい文字列でもゲートを緩めてはならない
# （厳密に文字列 "1" のみを許可する契約の回帰検出）。
run_entrypoint AIDOCK_SKIP_FIREWALL=1 AIDOCK_INSECURE_ACK=true
assert_exit 1 "AIDOCK_INSECURE_ACK=true (not the literal \"1\") still fails closed"
assert_contains "REFUSING TO START" "refusal message emitted for ACK=true"

# --- 4. both keys set to \"1\" must skip the firewall and still reach gosu ---
# 二重キーが両方とも "1" で揃った場合のみ、ファイアウォール初期化をスキップし
# 恒久警告を出したうえで `exec gosu agent "$@"` に到達することを確認する。
run_entrypoint AIDOCK_SKIP_FIREWALL=1 AIDOCK_INSECURE_ACK=1
assert_exit 0 "AIDOCK_SKIP_FIREWALL=1 + AIDOCK_INSECURE_ACK=1 proceeds (exit 0)"
assert_contains "WARNING: egress firewall SKIPPED" "insecure-skip warning banner printed when acknowledged"
assert_contains "${GOSU_SENTINEL} agent some-cmd" "exec gosu agent \"\$@\" reached with the original args"
assert_not_contains "REFUSING TO START" "refusal message NOT printed once acknowledged"

# --- 5. default (neither var set) must take neither SEC-13 branch -----------
# スキップ関連の環境変数を両方とも未設定にした既定状態では、fail-closed の
# 拒否メッセージも insecure-skip の警告バナーも出ないこと（＝どちらの SEC-13
# 分岐にも入らず、通常の `else` 分岐で本物の init-firewall.sh 起動を試みる
# こと）を確認する。
#
# **「1 で終わらないこと」だけを見てはいけない（fail-open）。** それだと
# 「ファイアウォールを起動した」と「起動する行が消えた」を区別できず、実測で
# 次の 3 つの変異がどれも 17/17 緑のまま通った:
#   (a) 行を削除する            … 起動されないのに緑
#   (b) 末尾に & を付ける       … ルートが 1 本も入る前に exec してしまうのに緑
#   (c) 末尾に || true を付ける … いちばん危険。init-firewall.sh は自分の終端プローブで
#       example.com へ到達できたとき exit 1 する（FR-4.6 / FR-4.7 / SEC-5）ので、
#       || true はその fail-closed の判定を握り潰す。スクリプト自身が「壊れている」と
#       宣言したファイアウォールのままコンテナが起動し、agent へ降格する。
#       CI では init-firewall.sh が成功するため、緑の実行では挙動が同一になり
#       **他のどの検査にも現れない**。
#
# そこで「起動を試みた」ことを示す信号そのものを見る。上の precondition が
# /usr/local/bin/init-firewall.sh の不在を保証しているので、その行に到達すれば
# 起動は必ず失敗し、`set -e` がそこで打ち切るため **gosu には到達しない**。
#
# 主たる判定は「gosu の番兵が出ていないこと」にする。終了コードの数値ではなく
# 「ファイアウォールの失敗が起動を止めたか」という意味そのものを見ているので、
# 不在（127）と実行不可（126）のどちらでも同じ結論になり、環境で揺れない。
# 上の (a)(b)(c) はいずれも gosu へ到達してしまうので、この 1 本で全部落ちる。
# 併せてメッセージにパスが現れることも見る（`2>/dev/null` や改名を捕まえる）。
run_entrypoint -u AIDOCK_SKIP_FIREWALL -u AIDOCK_INSECURE_ACK
assert_not_contains "${GOSU_SENTINEL}" "default (no skip vars) aborts at init-firewall.sh and never reaches gosu"
assert_contains "init-firewall.sh" "default path names init-firewall.sh (the invocation was not removed or silenced)"
assert_not_contains "REFUSING TO START" "default path does not print the fail-closed refusal message"
assert_not_contains "WARNING: egress firewall SKIPPED" "default path does not print the insecure-skip warning banner"

# 明示的に AIDOCK_SKIP_FIREWALL=0（"1" 以外の値）を渡した場合も既定状態と
# 同じくどちらの分岐にも入らないことを確認する（unset と "0" が同義であること）。
# こちらも同じ理由で「起動を試みた」ことまで見る。
run_entrypoint -u AIDOCK_INSECURE_ACK AIDOCK_SKIP_FIREWALL=0
assert_not_contains "${GOSU_SENTINEL}" "AIDOCK_SKIP_FIREWALL=0 behaves the same as unset (aborts at init-firewall.sh)"
assert_contains "init-firewall.sh" "AIDOCK_SKIP_FIREWALL=0 names init-firewall.sh (invocation not removed or silenced)"
assert_not_contains "REFUSING TO START" "AIDOCK_SKIP_FIREWALL=0 does not print the fail-closed refusal message"

# --- summary ----------------------------------------------------------------
# パス数とフェイル数を集計してテスト結果の概要を出力する
printf '\n# %d passed, %d failed\n' "$PASS" "$FAIL"
# フェイルが 1 件でもあれば非ゼロで終了してテストスイートを失敗させる
[[ "$FAIL" -eq 0 ]]
