FROM ubuntu:24.04

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# VPN/proxy-sidecar: владеет network namespace, весь трафик — через туннель
# openresolv в noble отсутствует и не нужен: DNS задаётся через compose dns:,
# а поле DNS= в wg-конфиге у нас по дизайну не используется
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip iproute2 iptables dnsutils \
        wireguard-tools \
    # no-op заглушка resolvconf: wg-конфиг с DNS= не роняет wg-quick,
    # DNS просто игнорируется (управляется compose dns:)
    && printf '#!/bin/sh\necho "resolvconf stub: DNS= из wg-конфига игнорируется — задайте DNS через compose dns:" >&2\nexit 0\n' > /usr/sbin/resolvconf \
    && chmod +x /usr/sbin/resolvconf \
    # tun2socks: заворачиваем весь трафик netns в socks5/http
    && T2S_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo arm64 || echo amd64) \
    && curl -fsSL "https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-${T2S_ARCH}.zip" -o /tmp/t2s.zip \
    && unzip -o /tmp/t2s.zip -d /tmp/t2s \
    && install -m 0755 /tmp/t2s/tun2socks* /usr/local/bin/tun2socks \
    && rm -rf /tmp/t2s.zip /tmp/t2s /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Проверка реальной доступности интернета через туннель (в direct-режиме — no-op)
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -fsS --max-time 3 https://1.1.1.1 >/dev/null 2>&1 || [ "${PROXY_MODE:-auto}" = "direct" ] || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
