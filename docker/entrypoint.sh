#!/usr/bin/env bash
# エラー発生時に即座に停止し、未定義変数の参照もエラーにする（安全なスクリプト実行の基本設定）
set -euo pipefail

# Helper: prefix every line with "[entrypoint]" and write to stderr.
# Defined at the top so it is available in all branches below.
# ログ出力ヘルパー関数: "[entrypoint]" プレフィックス付きで標準エラー出力に書く
log() { printf '[entrypoint] %s\n' "$*" >&2; }

# Runs as root: initialize the egress firewall (needs root), then drop to the
# unprivileged agent user via gosu before exec'ing the requested command.
# AIDOCK_SKIP_FIREWALL=1 が設定されているかチェックする（デバッグ用ファイアウォールスキップ）
if [[ "${AIDOCK_SKIP_FIREWALL:-0}" == "1" ]]; then
    # Skipping the firewall disables the product's PRIMARY defense (the
    # default-deny egress allowlist). It is debug-only (SEC-13). To prevent a
    # single stray env var -- inherited through the shell, a compose.override,
    # or a future env-forwarding path -- from silently turning the sandbox into
    # an open-egress container, require a SECOND explicit acknowledgement var.
    # Without it we fail closed rather than launching the workload unprotected
    # (issue #33). The two-key requirement makes "skip" a deliberate act, not an
    # accident of the environment.
    # 2 つ目の確認変数（AIDOCK_INSECURE_ACK=1）が設定されていなければ起動を拒否する（二重キー SEC-13）
    if [[ "${AIDOCK_INSECURE_ACK:-0}" != "1" ]]; then
        log "REFUSING TO START: AIDOCK_SKIP_FIREWALL=1 disables the egress"
        log "firewall (the sandbox's primary defense). This is debug-only."
        log "To proceed you MUST also set AIDOCK_INSECURE_ACK=1, acknowledging"
        log "that this container will run with UNRESTRICTED network egress."
        # ファイアウォールなしの起動は安全側に倒して拒否する（fail-closed）
        exit 1
    fi
    # Acknowledged: emit a loud, persistent warning so the insecure posture is
    # never silent in the logs.
    # 両方のキーが設定されている場合でも、無制限ネットワークアクセスであることを大きく警告する
    printf '[entrypoint] %s\n' \
        "############################################################" \
        "# WARNING: egress firewall SKIPPED (AIDOCK_SKIP_FIREWALL=1) #" \
        "# This container has UNRESTRICTED network access. Debug use #" \
        "# ONLY -- never on shared hosts or in CI (SEC-13).          #" \
        "############################################################" >&2
else
    # 通常起動: egress ファイアウォールを初期化して許可リストを構築する（root 権限が必要）
    /usr/local/bin/init-firewall.sh
fi

# ファイアウォール初期化後に gosu で非特権ユーザー agent に降格し、要求されたコマンドを実行する
# exec で置き換えるため、このプロセスは entrypoint.sh から claude（または bash）になる
exec gosu agent "$@"
