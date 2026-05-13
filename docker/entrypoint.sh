#!/usr/bin/env bash
set -euo pipefail

if [[ "${AIDOCK_SKIP_FIREWALL:-0}" != "1" ]]; then
    sudo /usr/local/bin/init-firewall.sh
fi

exec "$@"
