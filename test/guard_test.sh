#!/usr/bin/env bash
# guard_test.sh - unit tests for guard_workspace() (SEC-8 / AC-2) and the
# host-root rejection guard (SEC-18) in bin/aidock.
#
# Black-box: invokes `bin/aidock run` as a subprocess from controlled working
# directories and asserts the SEC-8 fail-closed exit code (2). The host home is
# faked via a PATH-injected `getent` stub so these tests never touch the real
# $HOME, and a `docker` stub stands in for the container so the "guard passes"
# path is observable without Docker -- the rejection paths exit 2 before Docker
# is ever reached. Runs in CI's type-check job (no Docker daemon required).
#
# bin/aidock is invoked unmodified; the stubs only shadow getent/docker/realpath/id
# on PATH, exactly the seams guard_workspace() and the SEC-18 guard read through.

# エラー発生時に即座に停止し、未定義変数の参照もエラーにする（安全なスクリプト実行の基本設定）
set -euo pipefail

# このスクリプト自身が置かれているディレクトリの絶対パスを取得する
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# リポジトリのルートディレクトリ（SCRIPT_DIR の一つ上）を絶対パスで求める
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
# テスト対象となる aidock スクリプトのパスを設定する
AIDOCK="${REPO_ROOT}/bin/aidock"

# ガードを通過したことを示すセンチネル文字列（docker スタブが出力する）
GUARD_PASS_SENTINEL="__AIDOCK_GUARD_PASSED__"

# スタブが PATH を上書きする前に、本物の realpath コマンドのパスを取得しておく
AIDOCK_TEST_REAL_REALPATH="$(command -v realpath)"
# 本物の realpath パスを環境変数として子プロセスに継承させる
export AIDOCK_TEST_REAL_REALPATH
# スタブが PATH を上書きする前に、本物の id コマンドのパスを取得しておく（SEC-18 試験用）
AIDOCK_TEST_REAL_ID="$(command -v id)"
# 本物の id パスを環境変数として子プロセスに継承させる
export AIDOCK_TEST_REAL_ID

# テスト用の一時ディレクトリを作成する
WORK="$(mktemp -d)"
# フェイクのホームディレクトリパスを設定する（本物の $HOME を汚さないため）
FAKE_HOME="${WORK}/home"
# getent / docker / realpath スタブを置くディレクトリパスを設定する
STUB_DIR="${WORK}/stub"
# フェイクホームとスタブディレクトリを実際に作成する
mkdir -p "$FAKE_HOME" "$STUB_DIR"

# テスト終了時（EXIT シグナル）に一時ディレクトリを掃除するトラップを設定する
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- stubs ------------------------------------------------------------------
# getent: emit a passwd line whose 6th field is the fake home, so
# guard_workspace() derives its base from `getent passwd $(id -u)` (never $HOME).
# With AIDOCK_TEST_GETENT_EMPTY set, emit nothing to exercise the fail-closed
# "cannot resolve home" path.
# getent スタブを書き出す（guard_workspace() が参照する passwd エントリを偽装する）
cat >"${STUB_DIR}/getent" <<'EOF'
#!/usr/bin/env bash
# AIDOCK_TEST_GETENT_EMPTY が設定されている場合は空を返してフェイルクローズ経路を試験する
if [[ -n "${AIDOCK_TEST_GETENT_EMPTY:-}" ]]; then
    exit 0
fi
# フェイクのホームディレクトリを持つ passwd 形式の行を出力する
printf '%s:x:%s:%s::%s:/bin/bash\n' agent "$(id -u)" "$(id -g)" "$AIDOCK_TEST_FAKE_HOME"
EOF

# docker: the guard "pass" path runs `docker compose ... run ... claude`; print a
# sentinel so a passing guard is observable and never touch the real daemon.
# docker スタブを書き出す（ガード通過後の docker compose run 呼び出しをセンチネル出力に置き換える）
cat >"${STUB_DIR}/docker" <<EOF
#!/usr/bin/env bash
# ガードを通過したことを示すセンチネル文字列を標準出力に出力して終了する
printf '%s\n' "${GUARD_PASS_SENTINEL}"
exit 0
EOF

# realpath: pass through to the real binary, except map one sentinel cwd to
# /var/run/docker.sock. A socket cannot be a real cwd, so this is the only way to
# reach guard_workspace()'s docker-socket branch in a black-box test.
# realpath スタブを書き出す（通常は本物に委譲し、ソケット試験のみ /var/run/docker.sock を返す）
cat >"${STUB_DIR}/realpath" <<'EOF'
#!/usr/bin/env bash
# AIDOCK_TEST_SOCK_CWD が設定されており引数と一致した場合は docker ソケットパスを返す
if [[ -n "${AIDOCK_TEST_SOCK_CWD:-}" && "$1" == "$AIDOCK_TEST_SOCK_CWD" ]]; then
    printf '/var/run/docker.sock\n'
    exit 0
fi
# それ以外は本物の realpath コマンドに処理を委譲する
exec "$AIDOCK_TEST_REAL_REALPATH" "$@"
EOF
# id: always report a fixed non-root UID/GID (1000) for `-u`/`-g` unless
# AIDOCK_TEST_FAKE_UID/GID overrides it, so the suite is hermetic regardless of
# the *actual* UID the test runner happens to execute as (some CI/sandbox
# environments run tests as root, which would otherwise make every SEC-18
# guard fire unconditionally and mask the "guard passes" assertions below).
# bin/aidock's own `HOST_UID="$(id -u)"` / `HOST_GID="$(id -g)"` calls (and the
# getent stub's internal `$(id -u)` call) all resolve through this same stub.
# id スタブを書き出す（既定では固定の非 root UID/GID 1000 を返し、AIDOCK_TEST_FAKE_UID/GID
# が設定されている場合のみ SEC-18 試験用の偽の値を返す。実行ユーザーの実際の UID には依存しない）
cat >"${STUB_DIR}/id" <<'EOF'
#!/usr/bin/env bash
# -u が指定された場合、AIDOCK_TEST_FAKE_UID があればそれを、無ければ既定の非 root UID を返す
if [[ "${1:-}" == "-u" ]]; then
    printf '%s\n' "${AIDOCK_TEST_FAKE_UID:-1000}"
    exit 0
fi
# -g が指定された場合、AIDOCK_TEST_FAKE_GID があればそれを、無ければ既定の非 root GID を返す
if [[ "${1:-}" == "-g" ]]; then
    printf '%s\n' "${AIDOCK_TEST_FAKE_GID:-1000}"
    exit 0
fi
# それ以外（-u/-g 以外の引数）の呼び出しは本物の id コマンドに処理を委譲する
exec "$AIDOCK_TEST_REAL_ID" "$@"
EOF

# 4 つのスタブファイルに実行権限を付与する
chmod +x "${STUB_DIR}/getent" "${STUB_DIR}/docker" "${STUB_DIR}/realpath" "${STUB_DIR}/id"

# フェイクホームのパスを環境変数としてエクスポートし getent スタブから参照できるようにする
export AIDOCK_TEST_FAKE_HOME="$FAKE_HOME"
# スタブディレクトリを PATH の先頭に追加して本物のコマンドより優先させる
export PATH="${STUB_DIR}:${PATH}"

# --- assertion helpers ------------------------------------------------------
# テスト全体のパス数を 0 で初期化する
PASS=0
# テスト全体のフェイル数を 0 で初期化する
FAIL=0

# aidock_run <workdir> -- run `bin/aidock run` from <workdir>; sets RC and OUT.
# Any per-test env (HOME, AIDOCK_TEST_*) is inherited from the calling subshell.
# 指定ディレクトリから `bin/aidock run` を実行し、終了コードを RC、出力を OUT に格納する関数
aidock_run() {
    # 引数として渡された作業ディレクトリを受け取る
    local workdir="$1"
    # 終了コードを 0 でリセットする（次の実行結果が上書きする）
    RC=0
    # 指定ディレクトリに移動して aidock run を実行し、stdout/stderr を OUT に取り込む
    OUT="$(cd "$workdir" && bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
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
        # 含まれない場合は FAIL を記録し、詳細を出力する
        printf 'FAIL - %s (output did not contain %q)\n' "$desc" "$needle"
        printf '       output: %s\n' "$OUT"
        FAIL=$((FAIL + 1))
    fi
}

# 出力に特定の文字列が含まれ「ない」ことを確認し、結果を PASS/FAIL カウントに反映する関数
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
        # 含まれてしまっている場合は FAIL を記録し、詳細を出力する
        printf 'FAIL - %s (output unexpectedly contained %q)\n' "$desc" "$needle"
        printf '       output: %s\n' "$OUT"
        FAIL=$((FAIL + 1))
    fi
}

# フェイクホーム配下の相対パスから絶対パスを作り、そこから aidock を実行して exit 2 を期待する補助関数
reject_from() {  # reject_from <relpath-under-fake-home> <desc>
    # フェイクホーム配下の相対パスを受け取る
    local rel="$1"
    # テストの説明文を受け取る
    local desc="$2"
    # 指定パスをディレクトリとして作成する（存在しない場合）
    mkdir -p "${FAKE_HOME}/${rel}"
    # 作成したディレクトリから aidock を実行する
    aidock_run "${FAKE_HOME}/${rel}"
    # 終了コード 2（SEC-8 拒否）を期待してアサートする
    assert_exit 2 "$desc"
}

# SEC-8 sensitive directories (bin/aidock case stmt, directory form).
# bin/aidock の case 文で拒否される機密ディレクトリの一覧
SENSITIVE_DIRS=(
    .ssh .aws .gcloud .config/gcloud .azure .config/azure
    .config/aws .config/git .config/gh .config/op .config/doctl
    .config/rclone .config/hub .config/github-copilot .claude .kube .docker .gnupg
    .terraform.d .cargo .m2 .gem .oci .gradle
)
# SEC-8 sensitive file names (matched exactly, no trailing /*).
# bin/aidock の case 文で拒否される機密ファイル名の一覧（ディレクトリとして作成して試験する）
SENSITIVE_FILES=(
    .gitconfig .git-credentials .netrc .npmrc .pypirc .pgpass .vault-token .terraformrc .claude.json
)

# テスト開始を示すヘッダーを出力する
echo "# guard_workspace() unit tests (SEC-8 / AC-2)"

# --- 0. SEC-18: reject host UID/GID 0 (root) --------------------------------
# require_non_root_host() is called from the top of cmd_build/login/run/shell
# (the commands that actually build an image or create a container), so a
# safe non-sensitive directory is used here deliberately: a rejection from
# `run`/`login`/`build`/`shell` must come from the UID/GID=0 check itself, not
# from SEC-8's guard_workspace().
# フェイクホーム配下に安全なプロジェクトディレクトリを用意する（SEC-8 とは無関係な場所で試験するため）
mkdir -p "${FAKE_HOME}/project/root-guard"

# ホスト UID が 0（root）の場合は SEC-18 により拒否されることを確認する（run 経由）
RC=0
OUT="$(cd "${FAKE_HOME}/project/root-guard" && AIDOCK_TEST_FAKE_UID=0 bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
assert_exit 2 "reject host UID 0 (root) via run"
assert_contains "refusing to build/run as host UID 0" "SEC-18 message emitted for UID 0"

# ホスト GID が 0（root グループ）の場合も SEC-18 により拒否されることを確認する（run 経由）
RC=0
OUT="$(cd "${FAKE_HOME}/project/root-guard" && AIDOCK_TEST_FAKE_GID=0 bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
assert_exit 2 "reject host GID 0 (root group) via run"
assert_contains "refusing to build/run as host GID 0" "SEC-18 message emitted for GID 0"

# build / login / shell も同じガードを通ることを確認する（コンテナを作る 4 コマンドすべてが対象）
RC=0
OUT="$(cd "${FAKE_HOME}/project/root-guard" && AIDOCK_TEST_FAKE_UID=0 bash "$AIDOCK" build </dev/null 2>&1)" || RC=$?
assert_exit 2 "reject host UID 0 (root) via build"
RC=0
OUT="$(cd "${FAKE_HOME}/project/root-guard" && AIDOCK_TEST_FAKE_UID=0 bash "$AIDOCK" shell </dev/null 2>&1)" || RC=$?
assert_exit 2 "reject host UID 0 (root) via shell"
RC=0
OUT="$(cd "${FAKE_HOME}/project/root-guard" && AIDOCK_TEST_FAKE_UID=0 bash "$AIDOCK" login </dev/null 2>&1)" || RC=$?
assert_exit 2 "reject host UID 0 (root) via login"

# logout と firewall-refresh は gosu 降格を経由しない（コンテナの UID/GID は作成時点で
# 既に確定済み）ため、SEC-18 の対象外であることを確認する。ホスト root でもこれらの
# コマンドはブロックされず、docker スタブ（常に exit 0 でセンチネルを出す）まで到達する。
RC=0
OUT="$(cd "${FAKE_HOME}/project/root-guard" && AIDOCK_TEST_FAKE_UID=0 bash "$AIDOCK" logout </dev/null 2>&1)" || RC=$?
assert_exit 0 "SEC-18 does not block logout for host UID 0"
RC=0
OUT="$(cd "${FAKE_HOME}/project/root-guard" && AIDOCK_TEST_FAKE_UID=0 bash "$AIDOCK" firewall-refresh </dev/null 2>&1)" || RC=$?
assert_exit 0 "SEC-18 does not block firewall-refresh for host UID 0"

# 通常の非 root UID/GID（実際のテスト実行ユーザー）ではガードを通過することを回帰確認する
aidock_run "${FAKE_HOME}/project/root-guard"
assert_exit 0 "allow non-root host UID/GID"
assert_contains "$GUARD_PASS_SENTINEL" "guard passed (reached docker) for non-root UID/GID"

# --- 1. Hard-coded path rejections -----------------------------------------
# ルートディレクトリ（/）からの実行を拒否することを確認する
aidock_run "/"
assert_exit 2 "reject CWD = /"

# フェイクホームディレクトリを作成する
mkdir -p "$FAKE_HOME"
# passwd から導出したホームディレクトリからの実行を拒否することを確認する
aidock_run "$FAKE_HOME"
assert_exit 2 "reject CWD = \$HOME (passwd home)"

# $HOME の祖先ディレクトリ（例: 実運用の /home に相当する親ディレクトリ）からの実行も
# 拒否されることを確認する。祖先を許すと $HOME 自身が /workspace 配下のサブディレクトリと
# して現れ、機密パスチェック（$HOME からの相対パス比較）を素通りしてしまう。
# フェイクホームの親ディレクトリ（$WORK）は $HOME の祖先そのものにあたる
aidock_run "$WORK"
assert_exit 2 "reject CWD = ancestor of \$HOME (parent dir)"
assert_contains "ancestor of" "ancestor-of-\$HOME message emitted"

# --- 2. SEC-8 sensitive directories (bare and nested subdir) ----------------
# 機密ディレクトリ直下および配下のサブディレクトリを順に試験する
for d in "${SENSITIVE_DIRS[@]}"; do
    reject_from "$d"        "reject sensitive dir ~/$d"
    reject_from "$d/sub"    "reject under ~/$d/"
done

# --- 3. SEC-8 sensitive file names (created as dirs; guard string-matches) ---
# 機密ファイル名に一致するパスを順に試験する
for f in "${SENSITIVE_FILES[@]}"; do
    reject_from "$f"        "reject sensitive file name ~/$f"
done

# --- 4. HOME spoofing must not bypass the passwd-derived base ---------------
# ~/.aws/spoof ディレクトリを用意し、$HOME を偽装しても拒否されることを確認する
mkdir -p "${FAKE_HOME}/.aws/spoof"
# 様々な偽の HOME 値を試してそれぞれ拒否されることを確認する
for h in "$HOME" "" "/nonexistent" "/tmp"; do
    RC=0
    # 偽の HOME を設定して aidock を実行し結果を取り込む
    OUT="$(cd "${FAKE_HOME}/.aws/spoof" && HOME="$h" bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
    assert_exit 2 "reject ~/.aws/spoof with spoofed HOME='${h}'"
done
# HOME を完全に未設定にした場合も拒否されることを確認する
RC=0
OUT="$(cd "${FAKE_HOME}/.aws/spoof" && env -u HOME bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
assert_exit 2 "reject ~/.aws/spoof with HOME unset"

# --- 4b. symlink resolution: realpath must defeat symlinked cwds -------------
# A cwd that is a symlink into a SEC-8 directory must still be rejected. This is
# the property guard_workspace()'s `realpath "$PWD"` canonicalization exists to
# enforce: a regression that compared the logical (un-resolved) path would let a
# symlink like ~/proj -> ~/.ssh slip through.
# ~/.ssh ディレクトリを作成し、それへのシンボリックリンクから実行した場合も拒否されることを確認する
mkdir -p "${FAKE_HOME}/.ssh"
# ssh-symlink は ~/.ssh を指すシンボリックリンク（realpath で解決されて拒否されるべき）
ln -s "${FAKE_HOME}/.ssh" "${FAKE_HOME}/ssh-symlink"
aidock_run "${FAKE_HOME}/ssh-symlink"
assert_exit 2 "reject symlinked cwd resolving into ~/.ssh"

# ~/.aws へのシンボリックリンク経由のサブディレクトリも拒否されることを確認する
ln -s "${FAKE_HOME}/.aws" "${FAKE_HOME}/aws-symlink"
aidock_run "${FAKE_HOME}/aws-symlink/sub"
assert_exit 2 "reject symlinked cwd resolving under ~/.aws/"

# --- 5. docker socket branch (reachable only via the realpath sentinel) -----
# realpath スタブを使って CWD が /var/run/docker.sock に見える状況をシミュレートする
mkdir -p "${FAKE_HOME}/sockcwd"
RC=0
# AIDOCK_TEST_SOCK_CWD を設定して realpath スタブが docker ソケットパスを返すようにする
OUT="$(cd "${FAKE_HOME}/sockcwd" \
    && AIDOCK_TEST_SOCK_CWD="${FAKE_HOME}/sockcwd" bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
# docker ソケットパスからの実行が exit 2 で拒否されることを確認する
assert_exit 2 "reject CWD = /var/run/docker.sock"
# エラーメッセージに "docker socket" が含まれることを確認する
assert_contains "docker socket" "docker socket message emitted"

# --- 6. fail-closed when passwd home cannot be resolved ---------------------
# getent スタブが空を返す場合（ホームが解決できない場合）にフェイルクローズすることを確認する
mkdir -p "${FAKE_HOME}/project/app"
RC=0
# AIDOCK_TEST_GETENT_EMPTY=1 を設定して getent スタブに空を返させる
OUT="$(cd "${FAKE_HOME}/project/app" && AIDOCK_TEST_GETENT_EMPTY=1 bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
# ホーム解決失敗時に exit 2 で終了することを確認する
assert_exit 2 "fail-closed when passwd home unresolvable"
# エラーメッセージに "cannot resolve home" が含まれることを確認する
assert_contains "cannot resolve home" "fail-closed message emitted"

# --- 7. Allowed (non-sensitive) directories pass the guard ------------------
# Guard passes -> cmd_run reaches the docker stub, which prints the sentinel.
# 安全なプロジェクトディレクトリからの実行がガードを通過することを確認する
mkdir -p "${FAKE_HOME}/project/app" "${FAKE_HOME}/.config/htop"
aidock_run "${FAKE_HOME}/project/app"
# ガード通過時は exit 0 を期待する
assert_exit 0 "allow non-sensitive project dir"
# docker スタブがセンチネルを出力していることを確認してガード通過を検証する
assert_contains "$GUARD_PASS_SENTINEL" "guard passed (reached docker) for project dir"

# ~/.config そのもの（親ディレクトリ）は SEC-8 で拒否されることを確認する。
# 親を丸ごとマウントすると .config/aws / .config/gcloud 等の列挙済み資格情報
# ディレクトリが一括露出するため、完全一致で拒否する（SEC-8）。
# reject_from ヘルパーが対象ディレクトリの作成まで行うため、他テストの mkdir 順序に依存しない
reject_from ".config" "reject ~/.config itself (parent of SEC-8 credential dirs)"
assert_contains "sensitive directory" "SEC-8 message emitted for ~/.config"

# ~/.config/htop は SEC-8 拒否リストに含まれないため通過することを確認する
# （.config は完全一致のみの拒否であり、非機密の子は許可される契約）
aidock_run "${FAKE_HOME}/.config/htop"
assert_exit 0 "allow ~/.config/htop (not a SEC-8 path)"
assert_contains "$GUARD_PASS_SENTINEL" "guard passed for ~/.config/htop"

# --- 7b. HOST_WORKSPACE must be the resolved path, not the raw symlinked cwd -
# Regression guard for the TOCTOU fix: guard_workspace() validates the
# realpath-resolved cwd, but cmd_run() used to re-read the raw (unresolved)
# $PWD for HOST_WORKSPACE. If $PWD were a symlink, the path Docker actually
# bind-mounts could diverge from the path that was validated, leaving a
# window (between the guard check and the `docker compose run` invocation)
# where retargeting the symlink would mount a different directory than the
# one the guard approved. Assert that the mounted path is the canonicalized
# target, identical to what guard_workspace() validated.
# 非機密プロジェクトディレクトリの実体と、そこへのシンボリックリンクを用意する
mkdir -p "${FAKE_HOME}/project/target"
ln -s "${FAKE_HOME}/project/target" "${FAKE_HOME}/project/via-symlink"
# シンボリックリンク先の実パス（realpath 解決済み）を期待値として求めておく
REAL_TARGET="$("$AIDOCK_TEST_REAL_REALPATH" "${FAKE_HOME}/project/target")"
# docker スタブを HOST_WORKSPACE の値を出力するものに一時的に差し替える
cat >"${STUB_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
# ガード通過時に実際に export された HOST_WORKSPACE の値を出力する
printf 'HOST_WORKSPACE=%s\n' "${HOST_WORKSPACE:-}"
exit 0
EOF
chmod +x "${STUB_DIR}/docker"
# シンボリックリンク経由のディレクトリから aidock run を実行する
aidock_run "${FAKE_HOME}/project/via-symlink"
assert_exit 0 "allow project dir reached via symlink"
# docker に渡された HOST_WORKSPACE がシンボリックリンクの解決先と一致することを確認する
assert_contains "HOST_WORKSPACE=${REAL_TARGET}" "HOST_WORKSPACE is the resolved realpath, not the raw symlinked cwd"

# --- 8. FR-1.5: firewall-refresh discovers one-off containers ----------------
# `aidock` がコンテナを作る経路はすべて `compose run --rm`（one-off）であり、
# 素の `compose ps` は one-off を一覧から除外するため、`--all --filter status=running`
# が無いと refresh は常に「no running claude container」で失敗する。ここでは
# docker スタブを「必須フラグが揃った ps 呼び出しにだけ CID を返す」ものに
# 差し替え、フラグの回帰（--all の削除等）を exit 1 として検出できるようにする。
# docker スタブを firewall-refresh 試験用に上書きする
cat >"${STUB_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
# 全引数を 1 つの文字列に連結して呼び出し内容を判定する
args="$*"
# compose ps 呼び出しの場合: 必須フラグ（--all と --filter status=running と claude）が
# すべて揃っているときだけ偽の CID を 1 件返す（揃っていなければ 0 件 = 回帰を模擬）
if [[ "$args" == *" ps "* ]]; then
    if [[ "$args" == *"--all"* && "$args" == *"--filter status=running"* && "$args" == *"claude"* ]]; then
        printf 'stub-cid-1\n'
    fi
    exit 0
fi
# docker exec 呼び出しの場合: 到達を示すセンチネルを出力して成功を返す
if [[ "$args" == exec* ]]; then
    printf '__AIDOCK_REFRESH_EXEC__ %s\n' "$args"
    exit 0
fi
# それ以外の docker 呼び出しは何もせず成功を返す
exit 0
EOF
# 上書きしたスタブに実行権限を付与する
chmod +x "${STUB_DIR}/docker"

# firewall-refresh を実行し、one-off コンテナが発見されて exec まで到達することを確認する
RC=0
OUT="$(bash "$AIDOCK" firewall-refresh </dev/null 2>&1)" || RC=$?
assert_exit 0 "firewall-refresh finds one-off containers (--all --filter status=running)"
assert_contains "__AIDOCK_REFRESH_EXEC__" "refresh reached docker exec for the discovered CID"

# --- 8b. FR-1.5: firewall-refresh is best-effort across multiple containers ---
# FR-1.5 は複数 claude コンテナの並行稼働（例: `run` と `shell`）を想定し、
# (a) CID を改行連結の単一引数ではなく必ず 1 件ずつ `docker exec` へ渡すこと、
# (b) あるコンテナの失敗で残りのコンテナの再実行を中断しないこと（best-effort）、
# (c) 1 件でも失敗があれば最終的に非ゼロ exit すること、を契約している。
# ここでは docker スタブを「ps は 3 件の CID を返し、exec は 2 件目だけ失敗する」
# ものに差し替え、3 契約すべてを 1 回の実行で回帰検証する。
# docker スタブを複数 CID ＋ 途中 1 件失敗の firewall-refresh 試験用に上書きする
cat >"${STUB_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
# 全引数を 1 つの文字列に連結して呼び出し内容を判定する
args="$*"
# compose ps 呼び出しの場合: 必須フラグが揃っていれば偽の CID を 3 件（改行区切り）返す
if [[ "$args" == *" ps "* ]]; then
    if [[ "$args" == *"--all"* && "$args" == *"--filter status=running"* && "$args" == *"claude"* ]]; then
        printf 'stub-cid-1\nstub-cid-2\nstub-cid-3\n'
    fi
    exit 0
fi
# docker exec 呼び出しの場合: 到達を示すセンチネルと引数全体を出力する
if [[ "$args" == exec* ]]; then
    printf '__AIDOCK_REFRESH_EXEC__ %s\n' "$args"
    # 2 件目のコンテナ（stub-cid-2）だけ init-firewall.sh の失敗を模擬して非ゼロで終了する
    if [[ "$args" == *"stub-cid-2"* ]]; then
        exit 1
    fi
    exit 0
fi
# それ以外の docker 呼び出しは何もせず成功を返す
exit 0
EOF
# 上書きしたスタブに実行権限を付与する
chmod +x "${STUB_DIR}/docker"

# firewall-refresh を実行し、途中 1 件の失敗が best-effort として扱われることを確認する
RC=0
OUT="$(bash "$AIDOCK" firewall-refresh </dev/null 2>&1)" || RC=$?
# (c) 1 件でも失敗があれば最終的に exit 1 になることを確認する
assert_exit 1 "firewall-refresh exits non-zero when one container's refresh fails"
# (a) 各 CID が単独の引数として exec に渡ることを、CID ごとの完全な exec 呼び出し文字列で確認する
#     （改行連結の単一引数だと "exec -u root stub-cid-1 /usr/local/bin/..." という形にはならない）
assert_contains "__AIDOCK_REFRESH_EXEC__ exec -u root stub-cid-1 /usr/local/bin/init-firewall.sh" "CID 1 passed to docker exec as a single distinct argument"
assert_contains "__AIDOCK_REFRESH_EXEC__ exec -u root stub-cid-2 /usr/local/bin/init-firewall.sh" "CID 2 (the failing one) still exec'd individually"
# (b) 2 件目の失敗後も 3 件目のコンテナが exec されること（中断しないこと）を確認する
assert_contains "__AIDOCK_REFRESH_EXEC__ exec -u root stub-cid-3 /usr/local/bin/init-firewall.sh" "refresh continues to CID 3 after CID 2 fails (best-effort)"
# 失敗したコンテナについて stderr の診断メッセージが記録されることを確認する
assert_contains "firewall refresh failed for container stub-cid-2" "failure for CID 2 is reported on stderr"

# --- 9. firewall-refresh: compose ps 自体の失敗を「no running claude container」と
#        取り違えず、実際の原因（Docker デーモン停止等）を示す診断メッセージにする ---
# docker スタブを「compose ps 呼び出しを常に失敗させる」ものに差し替え、
# compose ps 自体の失敗（例: Docker デーモン停止）が「コンテナが1つも無い」という
# 誤った一次診断メッセージに落ちてしまわないことを確認する。
cat >"${STUB_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
# 全引数を1つの文字列に連結して呼び出し内容を判定する
args="$*"
# compose ps 呼び出しの場合: Docker デーモン停止等を模擬し、常に非ゼロで失敗させる
if [[ "$args" == *" ps "* ]]; then
    echo "Cannot connect to the Docker daemon" >&2
    exit 1
fi
# それ以外の docker 呼び出しは何もせず成功を返す
exit 0
EOF
# 上書きしたスタブに実行権限を付与する
chmod +x "${STUB_DIR}/docker"

# firewall-refresh を実行し、compose ps 失敗時に専用の診断メッセージで exit 1 することを確認する
RC=0
OUT="$(bash "$AIDOCK" firewall-refresh </dev/null 2>&1)" || RC=$?
assert_exit 1 "firewall-refresh reports failure when compose ps itself fails"
assert_contains "failed to list containers" "diagnostic message distinguishes compose ps failure from an empty container list"

# --- 10. SEC-19: AIDOCK_PROFILE must not leak from the ambient environment ---
# `cmd_login()` explicitly sets AIDOCK_PROFILE=login, but `cmd_run()`/`cmd_shell()`
# used to leave the variable untouched and rely on compose.yaml's own
# `${AIDOCK_PROFILE:-run}` default. If the calling shell happened to still have
# AIDOCK_PROFILE=login exported (e.g. left over from a prior `aidock login`
# session in the same terminal that was never `unset`), that ambient value was
# inherited unchanged all the way into the container, silently widening the
# egress allowlist to include OAuth hosts (claude.ai, console.anthropic.com,
# ...) even for an ordinary `run`/`shell` session -- defeating the
# profile-based least-privilege design. Assert that `run` and `shell` always
# pin AIDOCK_PROFILE=run regardless of what the ambient shell exports.
# docker スタブを、実際にコンテナへ渡る AIDOCK_PROFILE の値を出力するものに差し替える
cat >"${STUB_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
# 呼び出し時点で見えている AIDOCK_PROFILE の値（未設定なら "unset"）を出力する
printf 'AIDOCK_PROFILE=%s\n' "${AIDOCK_PROFILE:-unset}"
exit 0
EOF
# 上書きしたスタブに実行権限を付与する
chmod +x "${STUB_DIR}/docker"

# アンビエントに AIDOCK_PROFILE=login を残したまま `run` を実行しても run プロファイルに固定されることを確認する
RC=0
OUT="$(cd "${FAKE_HOME}/project/app" && AIDOCK_PROFILE=login bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
assert_exit 0 "run succeeds even with ambient AIDOCK_PROFILE=login"
assert_contains "AIDOCK_PROFILE=run" "run pins AIDOCK_PROFILE=run despite ambient login value (SEC-19)"

# アンビエントに AIDOCK_PROFILE=login を残したまま `shell` を実行しても run プロファイルに固定されることを確認する
RC=0
OUT="$(cd "${FAKE_HOME}/project/app" && AIDOCK_PROFILE=login bash "$AIDOCK" shell </dev/null 2>&1)" || RC=$?
assert_exit 0 "shell succeeds even with ambient AIDOCK_PROFILE=login"
assert_contains "AIDOCK_PROFILE=run" "shell pins AIDOCK_PROFILE=run despite ambient login value (SEC-19)"

# --- 11. FR-1.6: logout must not claim success when compose down -v fails -----
# `cmd_logout()` は `compose down -v` の終了コードを伝播し、失敗時は
# (a) success メッセージ（credential volume removed）を出さない、
# (b) stderr に警告（logout failed ...）を出す、(c) 非ゼロで exit する、
# ことを契約している（AC-5 / SEC-10 / FR-1.6）。失敗が握りつぶされると、
# 共有ホスト上で資格情報ボリュームが残ったまま「削除済み」と誤報告されてしまう。
# docker スタブを「compose down 呼び出しを常に失敗させる」ものに差し替える
cat >"${STUB_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
# 全引数を 1 つの文字列に連結して呼び出し内容を判定する
args="$*"
# compose down 呼び出しの場合: Docker デーモン側の失敗を模擬し、常に非ゼロで失敗させる
if [[ "$args" == *" down "* ]]; then
    echo "Error response from daemon" >&2
    exit 1
fi
# それ以外の docker 呼び出しは何もせず成功を返す
exit 0
EOF
# 上書きしたスタブに実行権限を付与する
chmod +x "${STUB_DIR}/docker"

# logout を実行し、compose down -v の失敗が握りつぶされないことを確認する
RC=0
OUT="$(bash "$AIDOCK" logout </dev/null 2>&1)" || RC=$?
# (c) compose down -v の終了コード（1）がそのまま伝播することを確認する
assert_exit 1 "logout propagates compose down -v failure as non-zero exit (FR-1.6)"
# (b) stderr に失敗の警告メッセージが出力されることを確認する
assert_contains "logout failed" "logout warns on stderr when compose down -v fails"
# (a) 失敗時に success メッセージが出力されないことを確認する
assert_not_contains "credential volume removed" "logout does not claim success when compose down -v fails"

# --- summary ----------------------------------------------------------------
# パス数とフェイル数を集計してテスト結果の概要を出力する
printf '\n# %d passed, %d failed\n' "$PASS" "$FAIL"
# フェイルが 1 件でもあれば非ゼロで終了してテストスイートを失敗させる
[[ "$FAIL" -eq 0 ]]
