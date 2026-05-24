#!/usr/bin/env bash
set -euo pipefail

# Runs as root: initialize the egress firewall (needs root), then drop to the
# unprivileged agent user via gosu before exec'ing the requested command.
if [[ "${AIDOCK_SKIP_FIREWALL:-0}" != "1" ]]; then
    /usr/local/bin/init-firewall.sh
fi

exec gosu agent "$@"
