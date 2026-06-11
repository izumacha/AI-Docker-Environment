#!/usr/bin/env bash
set -euo pipefail

# Helper: prefix every line with "[entrypoint]" and write to stderr.
# Defined at the top so it is available in all branches below.
log() { printf '[entrypoint] %s\n' "$*" >&2; }

# Runs as root: initialize the egress firewall (needs root), then drop to the
# unprivileged agent user via gosu before exec'ing the requested command.
if [[ "${AIDOCK_SKIP_FIREWALL:-0}" == "1" ]]; then
    # Skipping the firewall disables the product's PRIMARY defense (the
    # default-deny egress allowlist). It is debug-only (SEC-13). To prevent a
    # single stray env var -- inherited through the shell, a compose.override,
    # or a future env-forwarding path -- from silently turning the sandbox into
    # an open-egress container, require a SECOND explicit acknowledgement var.
    # Without it we fail closed rather than launching the workload unprotected
    # (issue #33). The two-key requirement makes "skip" a deliberate act, not an
    # accident of the environment.
    if [[ "${AIDOCK_INSECURE_ACK:-0}" != "1" ]]; then
        log "REFUSING TO START: AIDOCK_SKIP_FIREWALL=1 disables the egress"
        log "firewall (the sandbox's primary defense). This is debug-only."
        log "To proceed you MUST also set AIDOCK_INSECURE_ACK=1, acknowledging"
        log "that this container will run with UNRESTRICTED network egress."
        exit 1
    fi
    # Acknowledged: emit a loud, persistent warning so the insecure posture is
    # never silent in the logs.
    printf '[entrypoint] %s\n' \
        "############################################################" \
        "# WARNING: egress firewall SKIPPED (AIDOCK_SKIP_FIREWALL=1) #" \
        "# This container has UNRESTRICTED network access. Debug use #" \
        "# ONLY -- never on shared hosts or in CI (SEC-13).          #" \
        "############################################################" >&2
else
    /usr/local/bin/init-firewall.sh
fi

exec gosu agent "$@"
