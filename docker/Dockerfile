# Pin the base image by digest for supply-chain reproducibility (issue #35):
# `node:22-slim` is a moving tag, so a later rebuild could silently pull a
# different image. The tag is kept alongside the digest only for readability;
# the digest is authoritative. Refresh both together when bumping Node
# (NFR-5.2) by re-resolving `docker buildx imagetools inspect node:22-slim`.
FROM node:22-slim@sha256:7af03b14a13c8cdd38e45058fd957bf00a72bbe17feac43b1c15a689c029c732

ARG HOST_UID=1000
ARG HOST_GID=1000
ARG CLAUDE_CODE_VERSION=1.0.40

ENV DEBIAN_FRONTEND=noninteractive

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

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

RUN if id -u node >/dev/null 2>&1; then userdel -r node 2>/dev/null || true; fi \
 && if getent group node >/dev/null; then groupdel node 2>/dev/null || true; fi \
 && groupadd -g "${HOST_GID}" agent \
 && useradd -l -m -u "${HOST_UID}" -g "${HOST_GID}" -s /bin/bash agent \
 && mkdir -p /home/agent/.claude /workspace \
 && chown -R agent:agent /home/agent /workspace

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh   /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

ENV HOME=/home/agent
WORKDIR /workspace

# The container starts as root so the entrypoint can initialize the egress
# firewall (iptables/ipset require root, and no-new-privileges forbids sudo's
# setuid escalation). entrypoint.sh drops to the unprivileged agent user via
# gosu before exec'ing the workload, so claude-code never runs as root.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
