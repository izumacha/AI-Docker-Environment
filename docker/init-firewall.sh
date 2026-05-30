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
# instead of every destination. A wide-open DNS egress is the one hole in the
# default-deny policy that lets a low-bandwidth DNS-tunnel exfiltration channel
# slip secrets out via query names to an attacker-controlled resolver. Pinning
# 53 to the configured resolvers closes that channel while keeping normal name
# resolution working. Docker rewrites /etc/resolv.conf inside the container
# (commonly the embedded resolver 127.0.0.11), so reading it at startup is
# reliable; `firewall-refresh` re-reads it if the host DNS later changes.
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

META_JSON="$(curl -fsSL --max-time 10 https://api.github.com/meta || true)"
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
    log "WARN: github meta fetch failed; continuing with hostname-resolved IPs only"
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
