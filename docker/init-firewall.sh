#!/usr/bin/env bash
# Default-deny egress firewall with an ipset-based allowlist.
# Derived from anthropics/claude-code .devcontainer/init-firewall.sh.
# Must be invoked as root (via the scoped sudoers entry).

set -euo pipefail

PROFILE="${AIDOCK_PROFILE:-run}"

log() { printf '[firewall] %s\n' "$*" >&2; }

if [[ "$(id -u)" -ne 0 ]]; then
    log "must run as root"
    exit 1
fi

iptables -F
iptables -X
# Intentionally do NOT flush the nat/mangle tables: flushing nat removes
# Docker's embedded-DNS DNAT (127.0.0.11:53) and breaks all name resolution
# for the allowlist built below. The egress policy lives in the filter table.
ipset destroy allowed-hosts 2>/dev/null || true
ipset destroy allowed-dns 2>/dev/null || true

iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
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
IPV6=0
if [[ -d /proc/sys/net/ipv6 ]]; then
    IPV6=1
    ip6tables -F
    ip6tables -X
    ipset destroy allowed-hosts6 2>/dev/null || true
    ipset destroy allowed-dns6 2>/dev/null || true
    ip6tables -P INPUT   DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT  DROP
    ip6tables -A INPUT  -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
else
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
ipset create allowed-dns hash:ip family inet hashsize 64 maxelem 256
dns_count=0
while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    ipset add allowed-dns "$ns" -exist
    dns_count=$((dns_count + 1))
done < <(awk '/^nameserver/ { print $2 }' /etc/resolv.conf 2>/dev/null \
    | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$')
if [[ "$dns_count" -eq 0 ]]; then
    log "WARN: no IPv4 nameserver in /etc/resolv.conf; DNS egress will be blocked"
else
    log "allowed DNS servers (v4): $(ipset list allowed-dns | grep -E '^[0-9]' | tr '\n' ' ')"
fi

iptables -A OUTPUT -p udp --dport 53 -m set --match-set allowed-dns dst -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -m set --match-set allowed-dns dst -j ACCEPT

# Same DNS treatment for IPv6 nameservers (SEC-15/SEC-16). Embedded Docker DNS
# is usually IPv4 (127.0.0.11), so this set is often empty -- harmless: v4 DNS
# already resolves names, and an empty set just means no v6 resolver is allowed.
if (( IPV6 )); then
    ipset create allowed-dns6 hash:ip family inet6 hashsize 64 maxelem 256
    dns6_count=0
    while IFS= read -r ns; do
        [[ -z "$ns" ]] && continue
        # The `grep -E ':'` prefilter is not a validating regex, so a
        # zone-scoped or otherwise malformed v6 nameserver (e.g. fe80::1%eth0)
        # can reach here. Guard the add: an unparseable entry must NOT abort the
        # whole init under set -e -- skip it with a warning instead.
        if ipset add allowed-dns6 "$ns" -exist 2>/dev/null; then
            dns6_count=$((dns6_count + 1))
        else
            log "WARN: skipping unparseable IPv6 nameserver: $ns"
        fi
    done < <(awk '/^nameserver/ { print $2 }' /etc/resolv.conf 2>/dev/null \
        | grep -E ':')
    if [[ "$dns6_count" -eq 0 ]]; then
        log "no IPv6 nameserver in /etc/resolv.conf; v6 DNS egress stays blocked"
    else
        log "allowed DNS servers (v6): $(ipset list allowed-dns6 | grep -E ':' | tr '\n' ' ')"
    fi
    ip6tables -A OUTPUT -p udp --dport 53 -m set --match-set allowed-dns6 dst -j ACCEPT
    ip6tables -A OUTPUT -p tcp --dport 53 -m set --match-set allowed-dns6 dst -j ACCEPT
fi

ipset create allowed-hosts hash:net family inet hashsize 1024 maxelem 65536
(( IPV6 )) && ipset create allowed-hosts6 hash:net family inet6 hashsize 1024 maxelem 65536

resolve_and_add() {
    local host="$1"
    local ips
    ips="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    if [[ -z "$ips" ]]; then
        log "WARN: failed to resolve $host (A)"
        return 0
    fi
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        ipset add allowed-hosts "$ip" -exist
    done <<< "$ips"
    log "added $host (A) -> $(echo "$ips" | tr '\n' ' ')"
}

# IPv6 counterpart: pin the AAAA records into the inet6 allowlist (issue #32).
# Best-effort like the v4 path -- a host with no AAAA record is skipped without
# aborting (FR-4.3/FR-4.7). Only invoked when an IPv6 stack is present.
resolve_and_add6() {
    local host="$1"
    local ips
    ips="$(getent ahostsv6 "$host" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    if [[ -z "$ips" ]]; then
        log "no AAAA for $host (v6 allowlist unchanged)"
        return 0
    fi
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        # Guard the add (mirrors the github-meta v6 path): a scoped/malformed
        # address from getent must not abort init under set -e.
        ipset add allowed-hosts6 "$ip" -exist 2>/dev/null \
            || log "WARN: ipset rejected AAAA for $host: $ip"
    done <<< "$ips"
    log "added $host (AAAA) -> $(echo "$ips" | tr '\n' ' ')"
}

# Range-validate a dotted-quad CIDR beyond its regex shape (SEC-12.2): every
# octet must be 0-255 and the prefix length 0-32. The caller guarantees the
# string already matched CIDR_RE, so all five fields are present and numeric.
# `10#` forces base-10 so values like `010` are not read as octal. Returns 0
# when valid, 1 otherwise.
cidr_in_range() {
    local cidr="$1" o1 o2 o3 o4 plen octet
    IFS='./' read -r o1 o2 o3 o4 plen <<< "$cidr"
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        (( 10#$octet <= 255 )) || return 1
    done
    (( 10#$plen <= 32 )) || return 1
    return 0
}

# Validate an IPv6 CIDR's prefix length (0-128). The caller has already matched
# the v6 shape regex (hex groups + optional ::, then /prefix), so we only need
# to bound the prefix here; ipset itself rejects any residual malformed address.
cidr6_in_range() {
    local cidr="$1" plen="${1##*/}"
    [[ "$cidr" == */* ]] || return 1
    (( 10#$plen <= 128 )) || return 1
    return 0
}

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

LOGIN_EXTRA_HOSTS=(
    claude.ai
    console.anthropic.com
    auth.anthropic.com
    login.anthropic.com
)

for h in "${CORE_HOSTS[@]}"; do
    resolve_and_add "$h"
    (( IPV6 )) && resolve_and_add6 "$h"
done
if [[ "$PROFILE" == "login" ]]; then
    log "profile=login -> widening allowlist for OAuth"
    for h in "${LOGIN_EXTRA_HOSTS[@]}"; do
        resolve_and_add "$h"
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
iptables -A OUTPUT -m set --match-set allowed-hosts dst -j ACCEPT
iptables -A OUTPUT -j DROP
if (( IPV6 )); then
    ip6tables -A OUTPUT -m set --match-set allowed-hosts6 dst -j ACCEPT
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
META_JSON=""
META_TMP="$(mktemp)"
# Ensure the temp file is removed even if set -e fires mid-loop (e.g. an
# iptables/ipset command fails after mktemp but before the explicit rm below).
trap 'rm -f "${META_TMP:-}"' EXIT
meta_deadline=$(( $(date +%s) + 20 ))
meta_attempt=0
while :; do
    meta_attempt=$((meta_attempt + 1))
    set +e
    http_code="$(curl -sSL --max-time 10 -o "$META_TMP" -w '%{http_code}' \
        https://api.github.com/meta 2>/dev/null)"
    curl_rc=$?
    set -e
    if [[ "$curl_rc" -eq 0 && "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        META_JSON="$(cat "$META_TMP")"
        break
    fi
    # Stop once attempts are exhausted or the cumulative deadline has passed.
    if (( meta_attempt >= 3 )) || (( $(date +%s) >= meta_deadline )); then
        break
    fi
    # Retry only transient failures: any curl transport error (DNS exit 6,
    # connect, timeout, connrefused...) or a retryable HTTP status. A hard HTTP
    # error (e.g. 403/404) breaks out immediately to warn-and-continue.
    if [[ "$curl_rc" -ne 0 ]]; then
        # Transport failure. If the earlier CORE_HOSTS resolve_and_add missed
        # api.github.com (the very initial-DNS-failure case this targets), its
        # IP is absent from allowed-hosts and the ACCEPT rule above would drop
        # any freshly-resolved address, so the retry could only time out. Re-
        # resolve and admit it (idempotent) before retrying; also picks up an
        # IP that rotated since the first resolution.
        resolve_and_add api.github.com
        (( IPV6 )) && resolve_and_add6 api.github.com
        sleep 2
        continue
    fi
    if [[ "$http_code" == "408" || "$http_code" == "429" \
        || "$http_code" =~ ^5[0-9][0-9]$ ]]; then
        # The connection already succeeded (so the IP is admitted); just retry.
        sleep 2
        continue
    fi
    break
done
rm -f "$META_TMP"
if [[ -n "$META_JSON" ]]; then
    CIDR_RE='^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'
    CIDR6_RE='^[0-9a-fA-F:]+/[0-9]{1,3}$'
    while IFS= read -r cidr; do
        [[ -z "$cidr" ]] && continue
        if [[ "$cidr" =~ $CIDR_RE ]]; then
            # SEC-12.1 (regex shape) passed; now enforce SEC-12.2 (octet/prefix
            # ranges). Out-of-range values (e.g. 999.999.999.999/33) are skipped
            # with a warning per FR-4.7 best-effort; initialization continues.
            if cidr_in_range "$cidr"; then
                ipset add allowed-hosts "$cidr" -exist
            else
                log "WARN: skipping out-of-range CIDR from github meta: $cidr"
            fi
        elif (( IPV6 )) && [[ "$cidr" =~ $CIDR6_RE ]]; then
            # IPv6 CIDR (issue #32): only admitted when an IPv6 stack is present.
            # Validate the prefix length; ipset rejects any malformed address.
            if cidr6_in_range "$cidr"; then
                ipset add allowed-hosts6 "$cidr" -exist 2>/dev/null \
                    || log "WARN: ipset rejected v6 CIDR from github meta: $cidr"
            else
                log "WARN: skipping out-of-range v6 CIDR from github meta: $cidr"
            fi
        fi
    done < <(echo "$META_JSON" | jq -r '.web[]?, .api[]?, .git[]?' 2>/dev/null \
        | grep -E '^[0-9]+\.|:')
    log "added GitHub meta CIDRs"
else
    log "WARN: github meta fetch failed after retries; continuing with hostname-resolved IPs only (retry later with firewall-refresh)"
fi

log "verifying probes..."
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
if curl -6 -fsS --max-time 3 https://example.com >/dev/null 2>&1; then
    log "FAIL: example.com is reachable over IPv6 but should be blocked"
    exit 1
fi
if ! curl -fsS --max-time 8 -o /dev/null https://api.anthropic.com 2>/dev/null; then
    # api.anthropic.com returns 404 on /; -fsS makes 4xx a failure, that's fine.
    # We only care that the TCP/TLS handshake completed.
    if ! curl -sS --max-time 8 -o /dev/null -w '%{http_code}\n' https://api.anthropic.com 2>/dev/null | grep -qE '^[1-9][0-9]{2}$'; then
        log "FAIL: api.anthropic.com unreachable"
        exit 1
    fi
fi
log "ok: deny-by-default + allowlist active (profile=$PROFILE, ipv6=$IPV6)"
