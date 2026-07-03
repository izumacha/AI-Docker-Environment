#!/usr/bin/env bash
# Default-deny egress firewall with an ipset-based allowlist.
# Derived from anthropics/claude-code .devcontainer/init-firewall.sh.
# Must be invoked as root (entrypoint.sh runs this before dropping privileges via gosu).

# エラー発生時に即座に停止し、未定義変数の参照もエラーにする（安全なスクリプト実行の基本設定）
set -euo pipefail

# AIDOCK_PROFILE 環境変数からプロファイルを取得する（未設定なら "run" を使う）
PROFILE="${AIDOCK_PROFILE:-run}"

# ログ出力ヘルパー関数: "[firewall]" プレフィックス付きで標準エラー出力に書く
log() { printf '[firewall] %s\n' "$*" >&2; }

# root ユーザーでなければ iptables を操作できないためエラーで終了する
if [[ "$(id -u)" -ne 0 ]]; then
    log "must run as root"
    exit 1
fi

# 既存の filter テーブルのルールとチェーンをすべてリセットする（再初期化の準備）
iptables -F
iptables -X
# Intentionally do NOT flush the nat/mangle tables: flushing nat removes
# Docker's embedded-DNS DNAT (127.0.0.11:53) and breaks all name resolution
# for the allowlist built below. The egress policy lives in the filter table.
# 前回の実行で作成した ipset（許可 IP の集合）を削除する（存在しない場合はエラーを無視する）
ipset destroy allowed-hosts 2>/dev/null || true
# 前回の実行で作成した DNS 許可 ipset を削除する（存在しない場合はエラーを無視する）
ipset destroy allowed-dns 2>/dev/null || true

# INPUT チェーンのデフォルトポリシーを DROP（全拒否）にする
iptables -P INPUT   DROP
# FORWARD チェーンのデフォルトポリシーを DROP にする（コンテナ間転送も拒否）
iptables -P FORWARD DROP
# OUTPUT チェーンのデフォルトポリシーを DROP にする（外向き通信はデフォルト拒否）
iptables -P OUTPUT  DROP

# ループバックインターフェース（lo）への受信は許可する（自分自身への通信）
iptables -A INPUT  -i lo -j ACCEPT
# ループバックインターフェースへの送信は許可する（自分自身への通信）
iptables -A OUTPUT -o lo -j ACCEPT
# すでに確立した接続・関連する通信の受信は許可する（TCP の応答パケット等）
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
# すでに確立した接続・関連する通信の送信は許可する（TCP の応答パケット等）
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# ---------------------------------------------------------------------------
# IPv6 default-deny (issue #32 / SEC-16).
#
# Previously this script configured IPv4 only. The Linux ip6tables default
# OUTPUT policy is ACCEPT, so on ANY IPv6-enabled Docker network the entire
# IPv4 allowlist below could be bypassed over IPv6 (arbitrary AAAA hosts or
# IPv6 literals reachable with no allowlist; DNS over an IPv6 resolver
# unconstrained). That defeats the product's headline egress control.
#
# We mirror the IPv4 ruleset fail-closed: set the v6 policies to DROP and only
# allow loopback / ESTABLISHED / the v6 nameservers / the AAAA-resolved
# allowlist.
#
# Detection keys off the KERNEL state, not a read-only ip6tables probe. An
# earlier version gated on `ip6tables -L -n` succeeding, but that fails OPEN: a
# transient list failure (xtables lock contention, module-autoload timing)
# would set IPV6=0 and skip the v6 deny rules while v6 connectivity persisted,
# re-opening the exact bypass this fixes. Instead we check /proc/sys/net/ipv6,
# which exists iff the kernel ipv6 module is loaded (absent under boot-time
# `ipv6.disable=1`). When it is present we are committed to filtering v6, so any
# ip6tables failure is FATAL via set -e (fail-closed: no firewall => no start),
# and we install the DROP policy first so deny is in place before any allow.
# When it is absent there is genuinely no v6 stack and thus no attack surface.
# IPv6 スタックが有効かどうかを示すフラグ（0=なし / 1=あり）
IPV6=0
# カーネルに IPv6 モジュールが読み込まれているか /proc で確認する
if [[ -d /proc/sys/net/ipv6 ]]; then
    # IPv6 スタックが存在するので v6 のファイアウォール設定を行う
    IPV6=1
    # 既存の ip6tables ルールをリセットする
    ip6tables -F
    # 既存の ip6tables チェーンをリセットする
    ip6tables -X
    # 前回の IPv6 許可 ipset を削除する（存在しない場合はエラーを無視する）
    ipset destroy allowed-hosts6 2>/dev/null || true
    # 前回の IPv6 DNS 許可 ipset を削除する（存在しない場合はエラーを無視する）
    ipset destroy allowed-dns6 2>/dev/null || true
    # IPv6 INPUT チェーンのデフォルトポリシーを DROP にする
    ip6tables -P INPUT   DROP
    # IPv6 FORWARD チェーンのデフォルトポリシーを DROP にする
    ip6tables -P FORWARD DROP
    # IPv6 OUTPUT チェーンのデフォルトポリシーを DROP にする（外向き通信はデフォルト拒否）
    ip6tables -P OUTPUT  DROP
    # IPv6 ループバック（::1）への受信は許可する
    ip6tables -A INPUT  -i lo -j ACCEPT
    # IPv6 ループバックへの送信は許可する
    ip6tables -A OUTPUT -o lo -j ACCEPT
    # すでに確立した IPv6 接続の受信は許可する
    ip6tables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
    # すでに確立した IPv6 接続の送信は許可する
    ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
else
    # IPv6 スタックがカーネルに存在しないことをログに記録する（v6 の攻撃面なし）
    log "IPv6 stack absent in kernel (/proc/sys/net/ipv6 missing); no v6 attack surface"
fi

# DNS: allow port 53 only to the nameservers declared in /etc/resolv.conf
# instead of every destination (defense-in-depth, SEC-15). This blocks a
# process from sending 53 directly to an attacker-controlled resolver (a crude
# DNS-tunnel / covert channel), but does NOT stop query-name exfiltration that
# recurses through the legitimate resolver to an attacker's authoritative NS
# (e.g. <secret>.attacker.example) -- that residual risk is accepted, since
# query-name filtering is not expressible here and dropping 53 after the
# allowlist is built would break runtime re-resolution. Docker rewrites
# /etc/resolv.conf inside the container (commonly the embedded resolver
# 127.0.0.11), so reading it at startup is reliable; `firewall-refresh`
# re-reads it if the host DNS later changes.
# IPv4 DNS サーバーの IP を格納する ipset を作成する（ハッシュテーブル形式）
ipset create allowed-dns hash:ip family inet hashsize 64 maxelem 256
# 追加した DNS サーバーの数を数えるカウンタ
dns_count=0
# The shape regex above (like SEC-12.1 for CIDRs) only checks digit-dot
# formatting, not per-octet range, so a value such as 999.999.999.999 would
# still reach here. Guard the ipset add so a single malformed nameserver
# cannot abort the whole init under set -e -- mirror the IPv6 nameserver loop
# below (and the AAAA/CIDR paths), which already guard for the same reason.
# /etc/resolv.conf から nameserver 行を読み取り、IPv4 アドレスだけを抽出して ipset に追加する
while IFS= read -r ns; do
    # 空行はスキップする
    [[ -z "$ns" ]] && continue
    # 抽出した IPv4 アドレスを DNS 許可リストに追加する（既存なら上書きしない）。
    # 正常に追加できた場合のみカウンタを増やし、値域外などの不正な形式はスキップして警告する
    if ipset add allowed-dns "$ns" -exist 2>/dev/null; then
        dns_count=$((dns_count + 1))
    else
        # 不正な形式の IPv4 ネームサーバーアドレスをスキップしてログに記録する
        log "WARN: skipping unparseable IPv4 nameserver: $ns"
    fi
done < <(awk '/^nameserver/ { print $2 }' /etc/resolv.conf 2>/dev/null \
    | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$')
# DNS サーバーが 1 件も見つからなかった場合は警告を出す（DNS 通信がブロックされる）
if [[ "$dns_count" -eq 0 ]]; then
    log "WARN: no IPv4 nameserver in /etc/resolv.conf; DNS egress will be blocked"
else
    # 許可した DNS サーバーの一覧をログに出力する
    log "allowed DNS servers (v4): $(ipset list allowed-dns | grep -E '^[0-9]' | tr '\n' ' ')"
fi

# UDP ポート 53 の DNS クエリを許可リストのサーバーにのみ許可する
iptables -A OUTPUT -p udp --dport 53 -m set --match-set allowed-dns dst -j ACCEPT
# TCP ポート 53 の DNS クエリを許可リストのサーバーにのみ許可する
iptables -A OUTPUT -p tcp --dport 53 -m set --match-set allowed-dns dst -j ACCEPT

# Same DNS treatment for IPv6 nameservers (SEC-15/SEC-16). Embedded Docker DNS
# is usually IPv4 (127.0.0.11), so this set is often empty -- harmless: v4 DNS
# already resolves names, and an empty set just means no v6 resolver is allowed.
# IPv6 スタックが有効な場合のみ IPv6 DNS 許可リストを設定する
if (( IPV6 )); then
    # IPv6 DNS サーバーの IP を格納する ipset を作成する
    ipset create allowed-dns6 hash:ip family inet6 hashsize 64 maxelem 256
    # 追加した IPv6 DNS サーバーの数を数えるカウンタ
    dns6_count=0
    # /etc/resolv.conf から nameserver 行を読み取り、IPv6 アドレス（":"を含む）だけを抽出する
    while IFS= read -r ns; do
        # 空行はスキップする
        [[ -z "$ns" ]] && continue
        # The `grep -E ':'` prefilter is not a validating regex, so a
        # zone-scoped or otherwise malformed v6 nameserver (e.g. fe80::1%eth0)
        # can reach here. Guard the add: an unparseable entry must NOT abort the
        # whole init under set -e -- skip it with a warning instead.
        # 正常に ipset に追加できた場合はカウンタを増やす（不正な形式はスキップして警告する）
        if ipset add allowed-dns6 "$ns" -exist 2>/dev/null; then
            dns6_count=$((dns6_count + 1))
        else
            # 不正な形式の IPv6 ネームサーバーアドレスをスキップしてログに記録する
            log "WARN: skipping unparseable IPv6 nameserver: $ns"
        fi
    done < <(awk '/^nameserver/ { print $2 }' /etc/resolv.conf 2>/dev/null \
        | grep -E ':')
    # IPv6 DNS サーバーが見つからなかった場合はブロックされたままであることを記録する
    if [[ "$dns6_count" -eq 0 ]]; then
        log "no IPv6 nameserver in /etc/resolv.conf; v6 DNS egress stays blocked"
    else
        # 許可した IPv6 DNS サーバーの一覧をログに出力する
        log "allowed DNS servers (v6): $(ipset list allowed-dns6 | grep -E ':' | tr '\n' ' ')"
    fi
    # IPv6 の UDP ポート 53 を許可リストのサーバーにのみ許可する
    ip6tables -A OUTPUT -p udp --dport 53 -m set --match-set allowed-dns6 dst -j ACCEPT
    # IPv6 の TCP ポート 53 を許可リストのサーバーにのみ許可する
    ip6tables -A OUTPUT -p tcp --dport 53 -m set --match-set allowed-dns6 dst -j ACCEPT
fi

# IPv4 の許可 IP ネットワーク（CIDR）を格納する ipset を作成する
ipset create allowed-hosts hash:net family inet hashsize 1024 maxelem 65536
# IPv6 スタックが有効な場合は IPv6 の許可 IP ネットワークの ipset も作成する
(( IPV6 )) && ipset create allowed-hosts6 hash:net family inet6 hashsize 1024 maxelem 65536

resolve_and_add() {
    # ホスト名を A レコードで解決し、得られた IPv4 アドレスを許可リスト ipset に追加する
    local host="$1"
    local ips
    # getent で IPv4 アドレスを取得し、重複を除いてソートする（失敗した場合は空文字列）
    ips="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    # 解決できなかった場合は警告を出して関数を正常終了する（best-effort なので abort しない）
    if [[ -z "$ips" ]]; then
        log "WARN: failed to resolve $host (A)"
        return 0
    fi
    # 取得した各 IPv4 アドレスを ipset に追加する
    while IFS= read -r ip; do
        # 空行はスキップする
        [[ -z "$ip" ]] && continue
        # IP アドレスを許可リストに追加する（既存なら上書きしない）
        ipset add allowed-hosts "$ip" -exist
    done <<< "$ips"
    # 追加した IP アドレスをログに記録する
    log "added $host (A) -> $(echo "$ips" | tr '\n' ' ')"
}

# IPv6 counterpart: pin the AAAA records into the inet6 allowlist (issue #32).
# Best-effort like the v4 path -- a host with no AAAA record is skipped without
# aborting (FR-4.3/FR-4.7). Only invoked when an IPv6 stack is present.
resolve_and_add6() {
    # ホスト名を AAAA レコードで解決し、得られた IPv6 アドレスを許可リスト ipset に追加する
    local host="$1"
    local ips
    # getent で IPv6 アドレスを取得し、重複を除いてソートする（失敗した場合は空文字列）
    ips="$(getent ahostsv6 "$host" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    # AAAA レコードがない場合はスキップして正常終了する（許可リストは変更しない）
    if [[ -z "$ips" ]]; then
        log "no AAAA for $host (v6 allowlist unchanged)"
        return 0
    fi
    # 取得した各 IPv6 アドレスを ipset に追加する
    while IFS= read -r ip; do
        # 空行はスキップする
        [[ -z "$ip" ]] && continue
        # Guard the add (mirrors the github-meta v6 path): a scoped/malformed
        # address from getent must not abort init under set -e.
        # ipset への追加を試みる（スコープ付き等の不正形式は警告してスキップする）
        ipset add allowed-hosts6 "$ip" -exist 2>/dev/null \
            || log "WARN: ipset rejected AAAA for $host: $ip"
    done <<< "$ips"
    # 追加した IPv6 アドレスをログに記録する
    log "added $host (AAAA) -> $(echo "$ips" | tr '\n' ' ')"
}

# Range-validate a dotted-quad CIDR beyond its regex shape (SEC-12.2): every
# octet must be 0-255 and the prefix length 0-32. The caller guarantees the
# string already matched CIDR_RE, so all five fields are present and numeric.
# `10#` forces base-10 so values like `010` are not read as octal. Returns 0
# when valid, 1 otherwise.
cidr_in_range() {
    # 引数で受け取った IPv4 CIDR 文字列が有効な範囲内かを検証する（各オクテット 0-255、プレフィックス 0-32）
    local cidr="$1" o1 o2 o3 o4 plen octet
    # CIDR 文字列をドットとスラッシュで分割して各オクテットとプレフィックス長に格納する
    IFS='./' read -r o1 o2 o3 o4 plen <<< "$cidr"
    # 各オクテットが 255 以下であるか確認する（10# で 8 進数読み取りを防ぐ）
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        (( 10#$octet <= 255 )) || return 1
    done
    # プレフィックス長が 32 以下であるか確認する
    (( 10#$plen <= 32 )) || return 1
    # 全チェックが通ったので有効な CIDR として 0（成功）を返す
    return 0
}

# Validate an IPv6 CIDR's prefix length (0-128). The caller has already matched
# the v6 shape regex (hex groups + optional ::, then /prefix), so we only need
# to bound the prefix here; ipset itself rejects any residual malformed address.
cidr6_in_range() {
    # 引数で受け取った IPv6 CIDR のプレフィックス長が 0-128 の範囲内かを検証する
    local cidr="$1" plen="${1##*/}"
    # スラッシュがない文字列（プレフィックスなし）は不正として拒否する
    [[ "$cidr" == */* ]] || return 1
    # プレフィックス長が 128 以下であるか確認する（10# で 8 進数読み取りを防ぐ）
    (( 10#$plen <= 128 )) || return 1
    # 有効な IPv6 CIDR として 0（成功）を返す
    return 0
}

# 通常起動時に常に許可するホスト名のリスト（Claude Code 動作に必要なもの）
CORE_HOSTS=(
    api.anthropic.com
    statsig.anthropic.com
    sentry.io
    registry.npmjs.org
    api.github.com
    github.com
    codeload.github.com
    objects.githubusercontent.com
    raw.githubusercontent.com
)

# ログインプロファイル時のみ追加で許可するホスト名のリスト（OAuth 認証に必要）
LOGIN_EXTRA_HOSTS=(
    claude.ai
    console.anthropic.com
    auth.anthropic.com
    login.anthropic.com
)

# CORE_HOSTS の各ホストを A レコードで解決して許可リストに追加する
for h in "${CORE_HOSTS[@]}"; do
    resolve_and_add "$h"
    # IPv6 スタックが有効な場合は AAAA レコードも解決して許可リストに追加する
    (( IPV6 )) && resolve_and_add6 "$h"
done
# ログインプロファイルの場合は OAuth 用の追加ホストも許可リストに加える
if [[ "$PROFILE" == "login" ]]; then
    log "profile=login -> widening allowlist for OAuth"
    # LOGIN_EXTRA_HOSTS の各ホストを解決して許可リストに追加する
    for h in "${LOGIN_EXTRA_HOSTS[@]}"; do
        resolve_and_add "$h"
        # IPv6 スタックが有効な場合は AAAA レコードも解決して許可リストに追加する
        (( IPV6 )) && resolve_and_add6 "$h"
    done
fi

# Install the allowlist ACCEPT *and* the terminal DROP before doing any
# allowlist-dependent network fetch (issue #34). Previously the terminal DROP
# was appended only after the GitHub meta fetch, leaving the deny posture to
# rely solely on the chain's default policy during the fetch/DNS phase. That
# held (policy was DROP), but it was fragile: any future change that flipped
# the policy to ACCEPT "temporarily" before the fetch would open a full
# fail-open window. By pinning ACCEPT-then-DROP up front, the deny rule is
# explicit and the meta fetch below still succeeds because api.github.com was
# already admitted to allowed-hosts via CORE_HOSTS resolution, and subsequent
# `ipset add` mutations take effect live under the already-installed ACCEPT.
#
# Note on allowlist breadth (residual risk, issue #34): this is IP/ipset-based
# matching. Any host sharing an allowlisted IP on a multi-tenant CDN (Fastly /
# Cloudflare / GitHub) is reachable, and short-TTL/rebinding can later map a
# pinned IP to a different tenant. The GitHub /meta import below widens this
# further (large netblocks). This is an accepted limitation of IP allowlisting;
# an SNI/Host-aware egress proxy would be required to constrain it precisely.
# 許可リストに含まれる IPv4 アドレスへの通信を ACCEPT するルールを追加する
iptables -A OUTPUT -m set --match-set allowed-hosts dst -j ACCEPT
# 上記以外の全 OUTPUT をここで DROP する（終端 DROP で明示的に拒否する）
iptables -A OUTPUT -j DROP
# IPv6 スタックが有効な場合は v6 の許可ルールと終端 DROP も設置する
if (( IPV6 )); then
    # 許可リストに含まれる IPv6 アドレスへの通信を ACCEPT するルールを追加する
    ip6tables -A OUTPUT -m set --match-set allowed-hosts6 dst -j ACCEPT
    # 上記以外の全 IPv6 OUTPUT を終端 DROP する
    ip6tables -A OUTPUT -j DROP
fi

# Pull GitHub CIDR blocks from the meta API (api.github.com is already allowed
# via core resolution above, so this curl works after the rule is installed).
#
# best-effort fetch with a hand-rolled bounded retry loop (issue #13).
#
# Why a shell loop instead of curl's --retry flags: we want to retry *only*
# transient failures -- a flaky first DNS lookup (curl exit 6), a momentary
# connect/timeout error, or an HTTP 429/5xx -- so a GitHub IP rotation between
# resolve and connect time does not leave us with no CIDR coverage. curl's own
# flags cannot express exactly that set: plain --retry skips name-resolution
# failures, while --retry-all-errors (with -f) also retries *hard* HTTP errors
# like 403/404, which contradicts the FR-4.5 contract that a 403 falls straight
# into the warn-and-continue path and would add avoidable startup delay on every
# boot under a persistent rate-limit/forbidden response. The loop below retries
# transient cases and lets hard 4xx fall through immediately.
#
# Bounds: at most 3 attempts AND a cumulative ~20s wall-clock deadline, so a
# server that keeps returning transient errors cannot stall container startup.
# Response body goes to a temp file (-o) and is read only after a clean 2xx, so
# partial bytes from a failed attempt can never corrupt the JSON we hand to jq.
# /tmp is a tmpfs (compose.yaml), writable under the read-only rootfs.
# GitHub /meta API から取得した JSON 本文を格納する変数（初期値は空）
META_JSON=""
# レスポンスを一時的に書き込むテンポラリファイルを作成する（/tmp は tmpfs）
META_TMP="$(mktemp)"
# Ensure the temp file is removed even if set -e fires mid-loop (e.g. an
# iptables/ipset command fails after mktemp but before the explicit rm below).
# スクリプト終了時（正常・異常問わず）にテンポラリファイルを確実に削除するトラップを設定する
trap 'rm -f "${META_TMP:-}"' EXIT
# フェッチの累積タイムアウト（現在時刻 + 20 秒）を Unix 時間で計算する
meta_deadline=$(( $(date +%s) + 20 ))
# 現在の試行回数を追跡するカウンタ（最大 3 回）
meta_attempt=0
# リトライループ: 成功するか試行回数・時間制限に達するまで繰り返す
while :; do
    # 試行回数をインクリメントする
    meta_attempt=$((meta_attempt + 1))
    # curl の失敗でスクリプト全体が停止しないよう一時的に set -e を無効化する
    set +e
    # GitHub の /meta API に HTTPS でアクセスし、HTTP ステータスコードとレスポンス本文を取得する
    http_code="$(curl -sSL --max-time 10 -o "$META_TMP" -w '%{http_code}' \
        https://api.github.com/meta 2>/dev/null)"
    # curl の終了コードを記録する（0 = 成功、それ以外 = 通信エラー）
    curl_rc=$?
    # set -e を再度有効にする
    set -e
    # curl が成功し、かつ HTTP ステータスが 2xx であればレスポンスを変数に格納してループを抜ける
    if [[ "$curl_rc" -eq 0 && "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        META_JSON="$(cat "$META_TMP")"
        break
    fi
    # Stop once attempts are exhausted or the cumulative deadline has passed.
    # 試行回数が 3 回に達したか、累積タイムアウトを超えた場合はリトライをやめてループを抜ける
    if (( meta_attempt >= 3 )) || (( $(date +%s) >= meta_deadline )); then
        break
    fi
    # Retry only transient failures: any curl transport error (DNS exit 6,
    # connect, timeout, connrefused...) or a retryable HTTP status. A hard HTTP
    # error (e.g. 403/404) breaks out immediately to warn-and-continue.
    # curl の通信エラー（DNS 失敗・接続失敗・タイムアウト等）の場合はリトライする
    if [[ "$curl_rc" -ne 0 ]]; then
        # Transport failure. If the earlier CORE_HOSTS resolve_and_add missed
        # api.github.com (the very initial-DNS-failure case this targets), its
        # IP is absent from allowed-hosts and the ACCEPT rule above would drop
        # any freshly-resolved address, so the retry could only time out. Re-
        # resolve and admit it (idempotent) before retrying; also picks up an
        # IP that rotated since the first resolution.
        # DNS 失敗の可能性があるため api.github.com を再解決して許可リストに追加してからリトライする
        resolve_and_add api.github.com
        # IPv6 スタックが有効な場合は IPv6 アドレスも再解決する
        (( IPV6 )) && resolve_and_add6 api.github.com
        # 少し待ってからリトライする（一時的な障害からの回復時間を確保する）
        sleep 2
        continue
    fi
    # 再試行可能な HTTP エラー（408=タイムアウト / 429=レート制限 / 5xx=サーバーエラー）の場合はリトライする
    if [[ "$http_code" == "408" || "$http_code" == "429" \
        || "$http_code" =~ ^5[0-9][0-9]$ ]]; then
        # The connection already succeeded (so the IP is admitted); just retry.
        # 少し待ってからリトライする
        sleep 2
        continue
    fi
    # 上記以外（403/404 等のハード HTTP エラー）はリトライせずループを抜ける
    break
done
# テンポラリファイルを明示的に削除する（EXIT トラップのバックアップとして）
rm -f "$META_TMP"
# フェッチが成功して JSON が取得できた場合は GitHub の CIDR ブロックを許可リストに追加する
if [[ -n "$META_JSON" ]]; then
    # IPv4 CIDR の正規表現パターン（形式チェック用、値域チェックは cidr_in_range で行う）
    CIDR_RE='^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'
    # IPv6 CIDR の正規表現パターン（形式チェック用）
    CIDR6_RE='^[0-9a-fA-F:]+/[0-9]{1,3}$'
    # JSON から web / api / git の CIDR を抽出して 1 行ずつ処理する
    while IFS= read -r cidr; do
        # 空行はスキップする
        [[ -z "$cidr" ]] && continue
        # IPv4 CIDR の形式チェック（SEC-12.1）を行う
        if [[ "$cidr" =~ $CIDR_RE ]]; then
            # SEC-12.1 (regex shape) passed; now enforce SEC-12.2 (octet/prefix
            # ranges). Out-of-range values (e.g. 999.999.999.999/33) are skipped
            # with a warning per FR-4.7 best-effort; initialization continues.
            # 値域チェック（SEC-12.2）も通過した場合のみ ipset に追加する
            if cidr_in_range "$cidr"; then
                ipset add allowed-hosts "$cidr" -exist
            else
                # 値域外の CIDR は警告を出してスキップする（起動は継続する）
                log "WARN: skipping out-of-range CIDR from github meta: $cidr"
            fi
        # IPv6 スタックが有効かつ IPv6 CIDR の形式チェックに通過した場合
        elif (( IPV6 )) && [[ "$cidr" =~ $CIDR6_RE ]]; then
            # IPv6 CIDR (issue #32): only admitted when an IPv6 stack is present.
            # Validate the prefix length; ipset rejects any malformed address.
            # プレフィックス長の値域チェックも通過した場合のみ IPv6 許可リストに追加する
            if cidr6_in_range "$cidr"; then
                # ipset への追加を試みる（不正な形式は警告してスキップする）
                ipset add allowed-hosts6 "$cidr" -exist 2>/dev/null \
                    || log "WARN: ipset rejected v6 CIDR from github meta: $cidr"
            else
                # 値域外の IPv6 CIDR は警告を出してスキップする
                log "WARN: skipping out-of-range v6 CIDR from github meta: $cidr"
            fi
        fi
    done < <(echo "$META_JSON" | jq -r '.web[]?, .api[]?, .git[]?' 2>/dev/null \
        | grep -E '^[0-9]+\.|:')
    # GitHub meta の CIDR ブロックを許可リストに追加し終えたことをログに記録する
    log "added GitHub meta CIDRs"
else
    # フェッチが全試行回数内で成功しなかった場合は警告を出して続行する（hostname 解決済み IP のみで動作）
    log "WARN: github meta fetch failed after retries; continuing with hostname-resolved IPs only (retry later with firewall-refresh)"
fi

# 検証プローブ: ファイアウォールが正しく機能しているか確認する
log "verifying probes..."
# example.com がブロックされているか確認する（到達可能なら設定ミスなので失敗させる）
if curl -fsS --max-time 3 https://example.com >/dev/null 2>&1; then
    log "FAIL: example.com is reachable but should be blocked"
    exit 1
fi
# IPv6 negative probe (issue #32): example.com must NOT be reachable over IPv6.
# Run UNCONDITIONALLY (not gated on IPV6): if v6 detection were ever wrong and
# the stack were actually live, a reachable example.com over v6 must still fail
# the init rather than be masked by the same flag that skipped configuration.
# Returns non-zero whether blocked by the v6 DROP policy or simply no v6 route
# (incl. no v6 stack, where curl -6 errors immediately) -- all desired. A zero
# exit (reachable over v6) means the allowlist was bypassed -> fail.
# IPv6 で example.com に到達できないか確認する（IPV6 フラグに関係なく常に実行する）
if curl -6 -fsS --max-time 3 https://example.com >/dev/null 2>&1; then
    log "FAIL: example.com is reachable over IPv6 but should be blocked"
    exit 1
fi
# api.anthropic.com に到達できるか確認する（到達できなければ Claude Code が動作しないため失敗させる）
if ! curl -fsS --max-time 8 -o /dev/null https://api.anthropic.com 2>/dev/null; then
    # api.anthropic.com returns 404 on /; -fsS makes 4xx a failure, that's fine.
    # We only care that the TCP/TLS handshake completed.
    # -fsS は 4xx もエラーにするため、HTTP レスポンスコードが返っていれば到達成功とみなす
    if ! curl -sS --max-time 8 -o /dev/null -w '%{http_code}\n' https://api.anthropic.com 2>/dev/null | grep -qE '^[1-9][0-9]{2}$'; then
        log "FAIL: api.anthropic.com unreachable"
        exit 1
    fi
fi
# ファイアウォールの初期化が完了したことを記録する（プロファイルと IPv6 の状態を出力）
log "ok: deny-by-default + allowlist active (profile=$PROFILE, ipv6=$IPV6)"
