# Pin the base image by digest for supply-chain reproducibility (issue #35):
# `node:22-slim` is a moving tag, so a later rebuild could silently pull a
# different image. The tag is kept alongside the digest only for readability;
# the digest is authoritative. Refresh both together when bumping Node
# (NFR-5.2) by re-resolving `docker buildx imagetools inspect node:22-slim`.
# ベースイメージを取得する（タグではなく digest 固定で、後日 node:22-slim の中身が変わっても同じイメージを使い続ける）
FROM node:22-slim@sha256:7af03b14a13c8cdd38e45058fd957bf00a72bbe17feac43b1c15a689c029c732

# ビルド時引数: コンテナ内 agent ユーザーの UID（ホストのユーザーと合わせてファイル所有権のズレを防ぐ、既定値 1000）
ARG HOST_UID=1000
# ビルド時引数: コンテナ内 agent ユーザーの GID（ホストのグループと合わせる、既定値 1000）
ARG HOST_GID=1000
# ビルド時引数: インストールする claude-code のバージョン（既定値 1.0.40）
ARG CLAUDE_CODE_VERSION=1.0.40

# 環境変数: apt-get 実行中に対話的な質問プロンプトを出さないようにする（自動ビルドを止めないため）
ENV DEBIAN_FRONTEND=noninteractive

# パッケージ一覧を最新化してから、サンドボックスに必要なツール群を最小構成でインストールする
RUN apt-get update && apt-get install -y --no-install-recommends \
        gosu \
        iptables \
        ipset \
        ca-certificates \
        jq \
        curl \
        git \
        openssh-client \
        less \
        dnsutils \
        ripgrep \
        gh \
        python3 \
        tini \
    && rm -rf /var/lib/apt/lists/*
    # apt のキャッシュ（パッケージ一覧）を削除し、イメージサイズを小さく保つ

# claude-code 本体を npm でグローバルインストールする（バージョンは ARG で固定）
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# 以下の RUN は 1 つのシェルコマンドとして連結されているため、途中に # コメント行を挟むと
# それより後ろ全体が1つの行コメント扱いになり残りのコマンドが実行されなくなる（シェルの仕様）。
# そのためコメントはこの直前にまとめて記載する。処理順序は次の通り:
#   1. ベースイメージ由来の node ユーザーが存在すればホームディレクトリごと削除する（失敗しても続行）
#   2. node グループが存在すれば削除する（agent 用の GID を衝突なく使うため）
#   3. HOST_GID が 0（root）なら明示的にビルドを失敗させる（SEC-18）。agent のプライマリ
#      グループが root になると、group-root で読める既存ファイルへのアクセスが意図せず
#      広がる。bin/aidock の require_non_root_host() が通常経路では先に拒否するが、
#      bin/aidock を経由しない直接の `docker build --build-arg HOST_GID=0` 等に対する
#      二次防御として Dockerfile 側にも同じ拒否を置く。0 でなければ、ホストと同じ GID を
#      持つグループが（node:22-slim の dialout/sudo/staff/users 等、既に）存在すればそれを
#      再利用し、無ければホストと同じ GID で agent グループを新規作成する。存在チェックを
#      せず常に `groupadd -g "${HOST_GID}" agent` すると、ホストの GID がベースイメージの
#      既存グループと衝突するユーザー環境で `groupadd: GID '...' already exists` により
#      docker build が失敗する。
#   4. HOST_UID がベースイメージの既存ユーザー（node:22-slim の _apt/messagebus/systemd-network
#      等、UID_MIN=1000 未満の予約 UID を持つシステムアカウント）と衝突する場合は、docker build を
#      明示的に失敗させ、原因と対処（別の HOST_UID を使う等）が分かるエラーメッセージを出す。
#      3 の GID 衝突とは異なり、既存アカウントを黙って再乗っ取り（ホームディレクトリやシェルを
#      書き換え）すると、そのシステムアカウントの用途を破壊しうるうえ、entrypoint.sh の
#      `gosu agent` はユーザー名 "agent" を前提にしているため単純な再利用では動作しない。
#      衝突が無ければ、ホストと同じ UID・（3 で決まった）GID でホームディレクトリ付きの
#      agent ユーザーを新規作成する（シェルは bash）
#      （実際には desktop/laptop Linux の UID_MIN は通常 1000 のため、この衝突は稀な
#      エッジケースだが、無条件の `useradd` に任せると `useradd: UID '...' is not unique`
#      という汎用的なエラーで終わり、原因が分かりにくい）
#   3a. (3 の追加防御) 再利用しようとした既存グループ名が、node:22-slim にあらかじめ存在する
#      「読み取り範囲の広いシステムグループ」（shadow=/etc/shadow 読み取り、sudo/adm=ログ・特権関連、
#      disk=生ブロックデバイス、systemd-journal=ジャーナルログ）のいずれかと一致する場合はビルドを
#      拒否する。HOST_GID=0 だけを弾く 3 のチェックのみだと、ホストの GID がこれらシステムグループの
#      GID と偶然一致する環境（複数ユーザー・LDAP 管理の Linux 等で GID が低番号に割り当てられる場合）で、
#      agent の実質的な読み取り権限が意図せず広がってしまう（このブロック冒頭のコメントが述べる
#      least-privilege の意図に反する）ため。
#   5. claude-code の設定ディレクトリと作業ディレクトリを作成する
#   6. 作成したディレクトリの所有者を agent:（3 で決まったグループ）に変更する（root 所有のままにしない）
#   7. `~/.gitconfig` と `~/.claude.json`（Claude Code 本体の設定ファイル。`~/.claude/` 配下の
#      OAuth 資格情報ボリュームとは別物）を、書き込み可能な tmpfs（`/home/agent/.config`）配下へ
#      向けたシンボリックリンクとして作る。`/home/agent` 自体は read_only rootfs 上にあり
#      `.cache`/`.npm`/`.config`/`.claude` の tmpfs/named volume 以外は書き込めないため、
#      これらのファイルへ `git config --global` や claude-code 自身の初回起動時保存が
#      素のままでは失敗する（issue: HOME 直下の設定ファイル書き込み不可）。シンボリックリンク自体は
#      ビルド時に焼き込む読み取り専用の実体だが、リンク先は既存の tmpfs 内なので実行時に書き込める。
# 再利用を拒否するシステムグループ名の一覧（このファイル内で唯一の定義箇所、直下の 3a で使用）。
# node:22-slim (Debian系) にデフォルトで存在し、そのグループに属するだけで読み取り範囲が
# 広がる代表的なグループを列挙している。ARG/ENV にせず RUN 内のローカル変数にしているのは、
# `docker build --build-arg` から上書きしてこの拒否リスト自体を無効化できないようにするため。
RUN SENSITIVE_GID_REUSE_DENYLIST="shadow,sudo,adm,disk,systemd-journal" \
 && if id -u node >/dev/null 2>&1; then userdel -r node 2>/dev/null || true; fi \
 && if getent group node >/dev/null; then groupdel node 2>/dev/null || true; fi \
 && if [ "${HOST_GID}" = "0" ]; then \
        echo "docker build: refusing HOST_GID=0 (root); agent's primary group must not be root (SEC-18)" >&2; \
        exit 1; \
    elif getent group "${HOST_GID}" >/dev/null; then \
        AGENT_GROUP="$(getent group "${HOST_GID}")"; \
        AGENT_GROUP="${AGENT_GROUP%%:*}"; \
        case ",${SENSITIVE_GID_REUSE_DENYLIST}," in \
            *",${AGENT_GROUP},"*) \
                echo "docker build: HOST_GID=${HOST_GID} collides with the base image's sensitive system group '${AGENT_GROUP}'; refusing to make it agent's primary group (SEC-18 widening) -- pass a different --build-arg HOST_GID" >&2; \
                exit 1; \
                ;; \
        esac; \
    else \
        groupadd -g "${HOST_GID}" agent && AGENT_GROUP="agent"; \
    fi \
 && if getent passwd "${HOST_UID}" >/dev/null; then \
        EXISTING_USER="$(getent passwd "${HOST_UID}")"; \
        EXISTING_USER="${EXISTING_USER%%:*}"; \
        echo "docker build: HOST_UID=${HOST_UID} collides with existing user '${EXISTING_USER}' in the base image; refusing to reuse it (would break entrypoint.sh's \"gosu agent\") -- pass a different --build-arg HOST_UID" >&2; \
        exit 1; \
    fi \
 && useradd -l -m -u "${HOST_UID}" -g "${AGENT_GROUP}" -s /bin/bash agent \
 && mkdir -p /home/agent/.claude /workspace \
 && ln -s .config/gitconfig /home/agent/.gitconfig \
 && ln -s .config/claude.json /home/agent/.claude.json \
 && chown -R agent:"${AGENT_GROUP}" /home/agent /workspace

# ホスト側のファイアウォール初期化スクリプトをイメージにコピーする
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
# エントリポイントスクリプトをイメージにコピーする
COPY entrypoint.sh   /usr/local/bin/entrypoint.sh
# コピーした 2 つのスクリプトに実行権限を付与する
RUN chmod 0755 /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

# HOME を agent のホームディレクトリに設定する（claude-code の設定保存先などに影響）
ENV HOME=/home/agent
# コンテナのデフォルト作業ディレクトリを /workspace に設定する
WORKDIR /workspace

# The container starts as root so the entrypoint can initialize the egress
# firewall (iptables/ipset require root, and no-new-privileges forbids sudo's
# setuid escalation). entrypoint.sh drops to the unprivileged agent user via
# gosu before exec'ing the workload, so claude-code never runs as root.
# コンテナ起動時は tini を PID 1 として entrypoint.sh を実行する（root 起動 → firewall 初期化 → gosu で agent へ降格という流れの入口）
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
# entrypoint.sh に渡すデフォルトコマンド（claude-code 本体を起動する）
CMD ["claude"]
