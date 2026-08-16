#!/usr/bin/env bash
# sec18_denylist_e2e.sh - assert that docker/Dockerfile's SEC-18 sensitive-GID
# reuse denylist (shadow/sudo/adm/disk/systemd-journal) still refuses to make a
# sensitive system group the agent user's primary group.
#
# Why this exists as a script rather than an inline `run:` block: the check used
# to live in .github/workflows/ci.yml, where the linters never saw it (the
# type-check job runs shellcheck and `bash -n` over scripts, not over workflow
# bodies) and it could not be tested at all. issue #94 is what that blind spot
# produced -- see below.
#
# What the check must keep apart (issue #94):
#
#   1. "the denylist did not reject"  -- a real SEC-18 regression.
#   2. "the check could not be run"   -- the base image would not pull, the
#                                        probe returned nothing, the build died
#                                        for an unrelated reason.
#
# The previous version collapsed both into verdict 1. It resolved shadow's GID
# with `docker run … getent group shadow | cut -d: -f3` without inspecting
# docker's exit status (the pipe hands back cut's status, which is 0 even when
# docker printed nothing) and without validating the result. An empty result
# then became `HOST_GID=""`, which compose.yaml's `${HOST_GID:-1000}` resolves
# to 1000 -- a GID that collides with nothing, so the build legitimately
# succeeded and the step reported a SEC-18 regression that had not happened.
# Two runs of the same commit disagreed for exactly this reason (issue #94).
#
# The reverse mistake is just as easy and was also present: `[ "$code" -ne 0 ]`
# accepts *any* failing build as proof that the denylist works, so an apt-get or
# npm hiccup -- or a genuinely deleted denylist on a day the build happens to
# break -- would print "SEC-18 ok". This script therefore requires the build to
# fail *with the denylist's own rejection message naming the GID we passed*,
# which is the only evidence that (a) the intended HOST_GID actually reached the
# build and (b) the denylist is what stopped it.
#
# Every failure path is fail-closed (non-zero exit); the two verdicts differ
# only in the message, so a red run tells the reader which one happened.
#
# Requires Docker, so CI runs it from the e2e job. The hermetic contract test
# for the logic above is test/sec18_denylist_test.sh (no Docker needed).

# 未定義変数の参照とパイプ途中の失敗をエラーにする。errexit は付けない:
# 本スクリプトは「失敗するはずのビルド」を意図的に実行し、その終了コードを読むため
set -uo pipefail

# このスクリプト自身が置かれているディレクトリの絶対パスを取得する
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# リポジトリのルートディレクトリ（SCRIPT_DIR の一つ上）を絶対パスで求める
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"

# 検査対象の Dockerfile（デニーリスト本体が書かれているファイル）
DOCKERFILE="${REPO_ROOT}/docker/Dockerfile"
# ビルドに使う compose ファイル
COMPOSE_FILE="${REPO_ROOT}/compose.yaml"

# 衝突させる機密システムグループの名前。デニーリストの先頭要素であり、
# node:22-slim に必ず存在する（GID は将来のリベースで動きうるので値は固定しない）
SENSITIVE_GROUP="shadow"

# Dockerfile の拒否メッセージのうち、GID やグループ名に依存しない固定部分。
# **1 か所に置く**（§6）: 下の 2 つの照合（Dockerfile 側に文言が実在すること／
# ビルドログにその文言が出たこと）が別々に文字列を持つと、文言を変えたときに
# 片方だけが古くなり、「当たらない＝素通り」に化ける
DENYLIST_REJECTION_FRAGMENT="collides with the base image's sensitive system group"

# 検査そのものが成立しなかったときの報告。**SEC-18 の結論とは別の言葉で出す**のが要点で、
# issue #94 はこの区別が無かったために probe の失敗が「退行」と報告された
fail_probe() {
    # 原因を明示して stderr に出す（CI ログでの見出しになる）
    printf 'FAIL(probe): %s\n' "$1" >&2
    # 検査できなかったことを合格に倒さない（fail-closed）
    exit 1
}

# デニーリストが実際に拒否しなかったときの報告（こちらが本物の SEC-18 退行）
fail_sec18() {
    # 退行として stderr に出す
    printf 'FAIL(SEC-18): %s\n' "$1" >&2
    # 非ゼロで終了して CI を赤くする
    exit 1
}

# compose のビルドコンテキストは compose.yaml からの相対パスなので、実行位置を固定する
cd "${REPO_ROOT}" || fail_probe "could not cd to the repository root (${REPO_ROOT})"

# compose.yaml の ${HOST_WORKSPACE:?…} は build でも展開されるため、未設定なら
# 非機密のプレースホルダを補う（type-check の compose config ステップと同じ流儀。
# build はボリュームをマウントしないので実体は不要）
: "${HOST_WORKSPACE:=/nonexistent}"
# 子プロセス（docker compose）から見えるようにエクスポートする
export HOST_WORKSPACE

# --- 1. デニーリストの拒否メッセージが Dockerfile に実在することを確かめる ---------

# Dockerfile が読めなければ以降の検査が成立しない
[ -f "${DOCKERFILE}" ] || fail_probe "docker/Dockerfile not found at ${DOCKERFILE}"

# 拒否メッセージの固定部分が Dockerfile に無ければ、文言が変わったか
# デニーリストごと消えている。**ここで止める**のが要点で、そのまま進むと
# 下のビルドログ照合が「何にも当たらない」状態になり、退行を見逃す側に倒れる
grep -qF -- "${DENYLIST_REJECTION_FRAGMENT}" "${DOCKERFILE}" \
    || fail_probe "docker/Dockerfile no longer contains the denylist rejection message (\"${DENYLIST_REJECTION_FRAGMENT}\"); either SEC-18's check was removed -- which is itself the regression -- or its wording changed and this script must be updated with it"

# --- 2. ベースイメージ参照を Dockerfile の FROM 行から取得する -----------------------

# GID を決め打ちにすると node:22-slim のリベースで陳腐化するため、
# ピン留めされたベースイメージから実際に解決する
base_image="$(awk '/^FROM /{print $2; exit}' "${DOCKERFILE}")"
# FROM 行の書式が変わって取れなかった場合を「検査できなかった」として止める
[ -n "${base_image}" ] || fail_probe "could not read the base image from docker/Dockerfile's FROM line"

# --- 3. 機密グループの GID をベースイメージから解決する -------------------------------

# **パイプを挟まずに** docker の終了コードを受け取る。`docker … | cut` にすると
# cut の 0 が返り、イメージの pull 失敗やレート制限が黙って空の GID になる（issue #94）
group_line="$(docker run --rm "${base_image}" getent group "${SENSITIVE_GROUP}")"
# 直前のコマンド置換の終了コードを控える
probe_status=$?
# docker 自体が失敗したなら、SEC-18 の結論ではなく probe の失敗として報告する
[ "${probe_status}" -eq 0 ] \
    || fail_probe "\`docker run --rm ${base_image} getent group ${SENSITIVE_GROUP}\` exited ${probe_status} (image pull, registry rate limit, or network); the SEC-18 denylist was NOT exercised"

# getent が 0 で終わりながら何も返さない場合（グループ自体が消えた等）も検査不能
[ -n "${group_line}" ] \
    || fail_probe "\`getent group ${SENSITIVE_GROUP}\` returned no output in ${base_image}; the group may have been removed from the base image"

# group エントリの 3 番目のフィールドが GID（例: shadow:x:42:）
shadow_gid="$(printf '%s\n' "${group_line}" | cut -d: -f3)"

# GID が「正の整数」であることを確かめる。数字以外・空はすべて probe の失敗に倒す
case "${shadow_gid}" in
    # 空、または数字以外の文字を含むものを弾く
    '' | *[!0-9]*)
        fail_probe "could not parse a numeric GID for '${SENSITIVE_GROUP}' from \"${group_line}\" (got \"${shadow_gid}\")"
        ;;
esac
# 0 は root グループを指すため、これを渡すと SEC-18 の**別の分岐**（HOST_GID=0 の拒否）を
# 検査してしまい、デニーリストを通ったことにならない
[ "${shadow_gid}" -gt 0 ] \
    || fail_probe "resolved GID for '${SENSITIVE_GROUP}' is ${shadow_gid}; expected a positive GID (0 would exercise SEC-18's root-GID branch, not the denylist)"

# ここまでで検査の前提が揃ったことを示す（値も残して後からログで追える）
printf 'probe ok: %s GID in base image (%s) is %s\n' "${SENSITIVE_GROUP}" "${base_image}" "${shadow_gid}"

# --- 4. その GID でビルドし、デニーリストに拒否されることを確かめる ---------------------

# ビルドログを一時ファイルに控える（終了コードだけでなく**理由**を照合するため）
build_log="$(mktemp)" || fail_probe "could not create a temporary file for the build log"
# どの経路で終わっても一時ファイルを残さない
trap 'rm -f "${build_log}"' EXIT

# HOST_GID だけを差し替えてビルドする。HOST_UID は呼び出し元の値のまま使い、
# AC-1 のビルドとレイヤーキャッシュを共有させる（デニーリストの RUN だけが再実行される）。
# --progress=plain は BuildKit の出力を行単位の決定的な形にして、下の照合を可能にする
HOST_GID="${shadow_gid}" docker compose -f "${COMPOSE_FILE}" build --progress=plain > "${build_log}" 2>&1
# ビルドの終了コードを控える
build_status=$?
# 成否にかかわらずビルドログを CI に出す（失敗時の原因調査に必要）
cat "${build_log}"
# 終了コードも明示的に残す
printf 'docker compose build exit (HOST_GID=%s): %s\n' "${shadow_gid}" "${build_status}"

# ビルドが成功したなら、デニーリストは機密グループの再利用を止めていない（本物の退行）
[ "${build_status}" -ne 0 ] \
    || fail_sec18 "build succeeded with HOST_GID=${shadow_gid}, which collides with the sensitive system group '${SENSITIVE_GROUP}'; the denylist should have rejected it"

# 期待する拒否メッセージ。**渡した GID とグループ名を埋め込む**ことで、
# 「意図した値でビルドされたか」と「止めたのはデニーリストか」を 1 度に確かめる。
# issue #94 の誤判定時に実際にビルドへ渡っていた 1000 は、この照合では通らない
expected_rejection="docker build: HOST_GID=${shadow_gid} ${DENYLIST_REJECTION_FRAGMENT} '${SENSITIVE_GROUP}'"

# ビルドは失敗したが、それがデニーリストによるものだと確かめられない場合。
# apt-get / npm の一時的な失敗でも非ゼロにはなるため、**終了コードだけでは合格にしない**
grep -qF -- "${expected_rejection}" "${build_log}" \
    || fail_probe "the build failed (exit ${build_status}) but its log does not contain the denylist's rejection for the GID we passed (\"${expected_rejection}\"); the failure may be unrelated (network, apt-get, npm) or the denylist may have been reworded, so this run proves nothing about SEC-18"

# ここまで来れば「意図した GID でビルドし、デニーリストがそれを拒否した」ことが確定する
printf "SEC-18 ok: HOST_GID=%s (the base image's '%s' group) is refused by the denylist as documented\n" "${shadow_gid}" "${SENSITIVE_GROUP}"
