#!/usr/bin/env bash
# guard_test.sh - unit tests for guard_workspace() in bin/aidock (SEC-8 / AC-2).
#
# Black-box: invokes `bin/aidock run` as a subprocess from controlled working
# directories and asserts the SEC-8 fail-closed exit code (2). The host home is
# faked via a PATH-injected `getent` stub so these tests never touch the real
# $HOME, and a `docker` stub stands in for the container so the "guard passes"
# path is observable without Docker -- the rejection paths exit 2 before Docker
# is ever reached. Runs in CI's type-check job (no Docker daemon required).
#
# bin/aidock is invoked unmodified; the stubs only shadow getent/docker/realpath
# on PATH, exactly the seams guard_workspace() reads through.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
AIDOCK="${REPO_ROOT}/bin/aidock"

GUARD_PASS_SENTINEL="__AIDOCK_GUARD_PASSED__"

# Resolve the real realpath now, before the stub shadows it on PATH below.
AIDOCK_TEST_REAL_REALPATH="$(command -v realpath)"
export AIDOCK_TEST_REAL_REALPATH

WORK="$(mktemp -d)"
FAKE_HOME="${WORK}/home"
STUB_DIR="${WORK}/stub"
mkdir -p "$FAKE_HOME" "$STUB_DIR"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- stubs ------------------------------------------------------------------
# getent: emit a passwd line whose 6th field is the fake home, so
# guard_workspace() derives its base from `getent passwd $(id -u)` (never $HOME).
# With AIDOCK_TEST_GETENT_EMPTY set, emit nothing to exercise the fail-closed
# "cannot resolve home" path.
cat >"${STUB_DIR}/getent" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${AIDOCK_TEST_GETENT_EMPTY:-}" ]]; then
    exit 0
fi
printf '%s:x:%s:%s::%s:/bin/bash\n' agent "$(id -u)" "$(id -g)" "$AIDOCK_TEST_FAKE_HOME"
EOF

# docker: the guard "pass" path runs `docker compose ... run ... claude`; print a
# sentinel so a passing guard is observable and never touch the real daemon.
cat >"${STUB_DIR}/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "${GUARD_PASS_SENTINEL}"
exit 0
EOF

# realpath: pass through to the real binary, except map one sentinel cwd to
# /var/run/docker.sock. A socket cannot be a real cwd, so this is the only way to
# reach guard_workspace()'s docker-socket branch in a black-box test.
cat >"${STUB_DIR}/realpath" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${AIDOCK_TEST_SOCK_CWD:-}" && "$1" == "$AIDOCK_TEST_SOCK_CWD" ]]; then
    printf '/var/run/docker.sock\n'
    exit 0
fi
exec "$AIDOCK_TEST_REAL_REALPATH" "$@"
EOF
chmod +x "${STUB_DIR}/getent" "${STUB_DIR}/docker" "${STUB_DIR}/realpath"

export AIDOCK_TEST_FAKE_HOME="$FAKE_HOME"
export PATH="${STUB_DIR}:${PATH}"

# --- assertion helpers ------------------------------------------------------
PASS=0
FAIL=0

# aidock_run <workdir> -- run `bin/aidock run` from <workdir>; sets RC and OUT.
# Any per-test env (HOME, AIDOCK_TEST_*) is inherited from the calling subshell.
aidock_run() {
    local workdir="$1"
    RC=0
    OUT="$(cd "$workdir" && bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
}

assert_exit() {
    local want="$1" desc="$2"
    if [[ "$RC" -eq "$want" ]]; then
        printf 'ok   - %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf 'FAIL - %s (want exit %s, got %s)\n' "$desc" "$want" "$RC"
        printf '       output: %s\n' "$OUT"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local needle="$1" desc="$2"
    if [[ "$OUT" == *"$needle"* ]]; then
        printf 'ok   - %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf 'FAIL - %s (output did not contain %q)\n' "$desc" "$needle"
        printf '       output: %s\n' "$OUT"
        FAIL=$((FAIL + 1))
    fi
}

reject_from() {  # reject_from <relpath-under-fake-home> <desc>
    local rel="$1" desc="$2"
    mkdir -p "${FAKE_HOME}/${rel}"
    aidock_run "${FAKE_HOME}/${rel}"
    assert_exit 2 "$desc"
}

# SEC-8 sensitive directories (bin/aidock case stmt, directory form).
SENSITIVE_DIRS=(
    .ssh .aws .gcloud .config/gcloud .azure .config/azure
    .config/aws .config/git .config/gh .kube .docker
)
# SEC-8 sensitive file names (matched exactly, no trailing /*).
SENSITIVE_FILES=(
    .gitconfig .git-credentials .netrc .npmrc .pypirc
)

echo "# guard_workspace() unit tests (SEC-8 / AC-2)"

# --- 1. Hard-coded path rejections -----------------------------------------
aidock_run "/"
assert_exit 2 "reject CWD = /"

mkdir -p "$FAKE_HOME"
aidock_run "$FAKE_HOME"
assert_exit 2 "reject CWD = \$HOME (passwd home)"

# --- 2. SEC-8 sensitive directories (bare and nested subdir) ----------------
for d in "${SENSITIVE_DIRS[@]}"; do
    reject_from "$d"        "reject sensitive dir ~/$d"
    reject_from "$d/sub"    "reject under ~/$d/"
done

# --- 3. SEC-8 sensitive file names (created as dirs; guard string-matches) ---
for f in "${SENSITIVE_FILES[@]}"; do
    reject_from "$f"        "reject sensitive file name ~/$f"
done

# --- 4. HOME spoofing must not bypass the passwd-derived base ---------------
mkdir -p "${FAKE_HOME}/.aws/spoof"
for h in "$HOME" "" "/nonexistent" "/tmp"; do
    RC=0
    OUT="$(cd "${FAKE_HOME}/.aws/spoof" && HOME="$h" bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
    assert_exit 2 "reject ~/.aws/spoof with spoofed HOME='${h}'"
done
RC=0
OUT="$(cd "${FAKE_HOME}/.aws/spoof" && env -u HOME bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
assert_exit 2 "reject ~/.aws/spoof with HOME unset"

# --- 4b. symlink resolution: realpath must defeat symlinked cwds -------------
# A cwd that is a symlink into a SEC-8 directory must still be rejected. This is
# the property guard_workspace()'s `realpath "$PWD"` canonicalization exists to
# enforce: a regression that compared the logical (un-resolved) path would let a
# symlink like ~/proj -> ~/.ssh slip through.
mkdir -p "${FAKE_HOME}/.ssh"
ln -s "${FAKE_HOME}/.ssh" "${FAKE_HOME}/ssh-symlink"
aidock_run "${FAKE_HOME}/ssh-symlink"
assert_exit 2 "reject symlinked cwd resolving into ~/.ssh"

ln -s "${FAKE_HOME}/.aws" "${FAKE_HOME}/aws-symlink"
aidock_run "${FAKE_HOME}/aws-symlink/sub"
assert_exit 2 "reject symlinked cwd resolving under ~/.aws/"

# --- 5. docker socket branch (reachable only via the realpath sentinel) -----
mkdir -p "${FAKE_HOME}/sockcwd"
RC=0
OUT="$(cd "${FAKE_HOME}/sockcwd" \
    && AIDOCK_TEST_SOCK_CWD="${FAKE_HOME}/sockcwd" bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
assert_exit 2 "reject CWD = /var/run/docker.sock"
assert_contains "docker socket" "docker socket message emitted"

# --- 6. fail-closed when passwd home cannot be resolved ---------------------
mkdir -p "${FAKE_HOME}/project/app"
RC=0
OUT="$(cd "${FAKE_HOME}/project/app" && AIDOCK_TEST_GETENT_EMPTY=1 bash "$AIDOCK" run </dev/null 2>&1)" || RC=$?
assert_exit 2 "fail-closed when passwd home unresolvable"
assert_contains "cannot resolve home" "fail-closed message emitted"

# --- 7. Allowed (non-sensitive) directories pass the guard ------------------
# Guard passes -> cmd_run reaches the docker stub, which prints the sentinel.
mkdir -p "${FAKE_HOME}/project/app" "${FAKE_HOME}/.config/htop"
aidock_run "${FAKE_HOME}/project/app"
assert_exit 0 "allow non-sensitive project dir"
assert_contains "$GUARD_PASS_SENTINEL" "guard passed (reached docker) for project dir"

aidock_run "${FAKE_HOME}/.config/htop"
assert_exit 0 "allow ~/.config/htop (not a SEC-8 path)"
assert_contains "$GUARD_PASS_SENTINEL" "guard passed for ~/.config/htop"

# --- summary ----------------------------------------------------------------
printf '\n# %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
