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
    log "allowed DNS servers: $(ipset list allowed-dns | grep -E '^[0-9]' | tr '\n' ' ')"
fi

iptables -A OUTPUT -p udp --dport 53 -m set --match-set allowed-dns dst -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -m set --match-set allowed-dns dst -j ACCEPT

ipset create allowed-hosts hash:net family inet hashsize 1024 maxelem 65536

resolve_and_add() {
    local host="$1"
    local ips
    ips="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    if [[ -z "$ips" ]]; then
        log "WARN: failed to resolve $host"
        return 0
    fi
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        ipset add allowed-hosts "$ip" -exist
    done <<< "$ips"
    log "added $host -> $(echo "$ips" | tr '\n' ' ')"
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

for h in "${CORE_HOSTS[@]}"; do resolve_and_add "$h"; done
if [[ "$PROFILE" == "login" ]]; then
    log "profile=login -> widening allowlist for OAuth"
    for h in "${LOGIN_EXTRA_HOSTS[@]}"; do resolve_and_add "$h"; done
fi

# Pull GitHub CIDR blocks from the meta API (api.github.com is already allowed
# via core resolution above, so this curl works after the rule is installed).
iptables -A OUTPUT -m set --match-set allowed-hosts dst -j ACCEPT

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
        fi
    done < <(echo "$META_JSON" | jq -r '.web[]?, .api[]?, .git[]?' 2>/dev/null | grep -E '^[0-9]+\.')
    log "added GitHub meta CIDRs"
else
    log "WARN: github meta fetch failed after retries; continuing with hostname-resolved IPs only (retry later with firewall-refresh)"
fi

iptables -A OUTPUT -j DROP

log "verifying probes..."
if curl -fsS --max-time 3 https://example.com >/dev/null 2>&1; then
    log "FAIL: example.com is reachable but should be blocked"
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
log "ok: deny-by-default + allowlist active (profile=$PROFILE)"
