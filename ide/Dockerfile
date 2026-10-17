FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    LANG=C.UTF-8

# IDE-контейнер: ничего не знает про прокси/VPN/iptables — только netns
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git jq gnupg tar unzip \
        locales tzdata \
        nano htop \
        python3 python3-pip python3-venv build-essential \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    # code-server (веб-IDE)
    && curl -fsSL https://code-server.dev/install.sh | sh \
    # Расширение "Claude Code" — официальный .vsix с MS Marketplace.
    # BEST-EFFORT: сбой скачивания НЕ ломает сборку — расширение доустановится
    # при первом старте контейнера (через туннель) или по команде `claude`.
    && ( curl -4 -fsSL --compressed --connect-timeout 20 --max-time 240 --retry 2 --retry-all-errors \
           -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36" \
           -H "Accept: application/octet-stream;api-version=3.0-preview.1" \
           "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/anthropic/vsextensions/claude-code/latest/vspackage" \
           -o /tmp/claude-code.vsix \
         && head -c 2 /tmp/claude-code.vsix | grep -q '^PK' \
         && code-server --install-extension /tmp/claude-code.vsix --extensions-dir /opt/default-ext \
         || echo "WARN: claude-code.vsix не скачался на этапе сборки — будет доустановлен при первом старте" ) \
    # Claude Code CLI (для терминала IDE)
    && npm install -g @anthropic-ai/claude-code \
    && rm -rf /tmp/claude-code.vsix /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -fsS http://localhost:8080/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
