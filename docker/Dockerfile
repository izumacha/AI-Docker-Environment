FROM node:22-slim

ARG HOST_UID=1000
ARG HOST_GID=1000
ARG CLAUDE_CODE_VERSION=1.0.40

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo \
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

RUN echo 'agent ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh' > /etc/sudoers.d/agent \
 && chmod 0440 /etc/sudoers.d/agent \
 && visudo -cf /etc/sudoers.d/agent

ENV HOME=/home/agent
WORKDIR /workspace
USER agent

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
