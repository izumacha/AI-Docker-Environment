#!/usr/bin/env bash
# README のデモブロック用に、代表フローの端末録画 (asciinema cast + GIF) を生成するスクリプト。
#
# 録画する代表フロー (CLAUDE.md「見せ方 (§15 の具体化)」に対応):
#   1. `aidock build`  — イメージのビルド (HOST_UID/HOST_GID 注入)
#   2. `aidock shell`  — コンテナ起動 → ファイアウォール初期化 → `agent` ユーザーへの降格を確認
#                        し、許可外ホスト (example.com) の遮断と api.anthropic.com への到達を確認
#
# 注意 (CLAUDE.md「見せ方」の制約):
#   - OAuth トークンやホストの実パス ($HOME 配下の個人情報が分かるパス) を録画に写さないため、
#     デモ用の一時ディレクトリへ移動してから aidock を起動する。
#   - `aidock login` / `run` の対話部分 (OAuth コード貼り付け・Claude Code の対話画面) は
#     自動化に向かないため本スクリプトでは録画しない。必要なら手動で
#     `asciinema rec -c './bin/aidock run' docs/demo/aidock-run.cast` のように録る。
#
# 実行環境: Linux ホスト (Docker デーモン必須)。依存: asciinema, agg。
#   asciinema: https://asciinema.org/ (例: pipx install asciinema)
#   agg:       https://github.com/asciinema/agg (cast → GIF 変換)
#
# 使い方: リポジトリルートで  ./docs/demo/record-demo.sh
# 生成物: docs/demo/aidock-demo.cast / docs/demo/aidock-demo.gif

set -euo pipefail

# このスクリプト自身の場所からリポジトリルートを求める (docs/demo/ の 2 つ上)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# 生成物の置き場所 (README から参照するパスと一致させる)
DEMO_DIR="${REPO_ROOT}/docs/demo"
CAST_FILE="${DEMO_DIR}/aidock-demo.cast"
GIF_FILE="${DEMO_DIR}/aidock-demo.gif"

# ログはすべて stderr へ (共通規約)
log() { printf '%s\n' "$*" >&2; }

# 依存コマンドの存在確認 (無ければ導入方法を案内して fail-closed で終了)
require() {
    if ! command -v "$1" > /dev/null 2>&1; then
        log "error: '$1' が見つかりません。$2"
        exit 1
    fi
}
require docker "Docker デーモンが動く Linux ホストで実行してください。"
require asciinema "例: pipx install asciinema"
require agg "https://github.com/asciinema/agg の手順で導入してください。"

# 録画に個人情報を写さないための中立な作業ディレクトリ (デモ用サンプルプロジェクト)
DEMO_WORKSPACE="$(mktemp -d /tmp/aidock-demo-workspace.XXXXXX)"
# スクリプト終了時に一時ディレクトリを必ず片付ける
trap 'rm -rf "${DEMO_WORKSPACE}"' EXIT
# 画面に映っても差し支えないダミーファイルを 1 つ置く
printf '# aidock demo sample project\n' > "${DEMO_WORKSPACE}/README.md"

# 録画の中で実行する一連のコマンド。
#   - build はそのまま実行 (キャッシュが効いていれば短い)
#   - shell は遮断確認 → 到達確認 → ユーザー確認だけを流して終了する
# 遮断確認の curl は失敗が期待値なので `|| echo` で明示的に受け止める。
DEMO_STEPS="$(cat << EOF
cd '${REPO_ROOT}'
./bin/aidock build
cd '${DEMO_WORKSPACE}'
'${REPO_ROOT}/bin/aidock' shell << 'INNER'
whoami
curl -sS --max-time 5 https://example.com > /dev/null || echo '=> example.com は遮断 (default-deny)'
curl -sSI --max-time 10 https://api.anthropic.com | head -n 1
INNER
EOF
)"

log "録画を開始します → ${CAST_FILE}"
# --idle-time-limit でビルド待ちなどの無操作時間を 2 秒に圧縮する
asciinema rec --overwrite --idle-time-limit 2 \
    --command "bash -c \"${DEMO_STEPS//\"/\\\"}\"" \
    "${CAST_FILE}"

log "GIF へ変換します → ${GIF_FILE}"
# 幅は README 掲載基準 (目安 1280px) に合わせ、フォントサイズで調整する
agg --font-size 16 "${CAST_FILE}" "${GIF_FILE}"

# GIF は 10MB 以下が基準 (CLAUDE.md §15)。超過していたら警告する。
GIF_SIZE="$(stat -c %s "${GIF_FILE}")"
if [ "${GIF_SIZE}" -gt $((10 * 1024 * 1024)) ]; then
    log "warning: GIF が 10MB を超えています (${GIF_SIZE} bytes)。--idle-time-limit や解像度を調整してください。"
fi

log "完了: ${CAST_FILE} と ${GIF_FILE} を生成しました。"
log "内容を目視確認し、個人情報やトークンが写っていないことを確認してからコミットしてください。"
