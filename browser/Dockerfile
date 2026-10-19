FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# Chromium + виртуальный дисплей + VNC + noVNC (веб-клиент)
RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium xvfb x11vnc websockify openbox \
        fonts-liberation fonts-noto-color-emoji \
        curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Апстримовый noVNC вместо устаревшего debian-пакета (1.2, 2021): начиная
# с 1.4 буфер обмена синхронизируется с хостом АВТОМАТИЧЕСКИ (Clipboard API:
# Ctrl+V прямо на удалённом экране, копирование — сразу в локальный буфер),
# а не только вручную через панель Clipboard.
ARG NOVNC_VERSION=1.7.0
RUN curl -fsSL "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz" | tar xz -C /tmp \
    && mv /tmp/noVNC-${NOVNC_VERSION} /usr/share/novnc \
    && rm -rf /tmp/noVNC-${NOVNC_VERSION}

# index.html: корень отдавал listing noVNC — делаем редирект на клиент,
# который подключается сам и масштабирует удалённый экран под окно браузера.
# &v=<версия> — cache-buster: после обновления noVNC браузер гарантированно
# берёт свежий vnc.html, а не закэшированную старую разметку (микс старого
# HTML с новым app/ui.js падает с 'Cannot read properties of null').
RUN printf '%s\n' \
      '<!DOCTYPE html><html><head>' \
      '<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&resize=scale&v=NOVNC_VER">' \
      '<meta http-equiv="Cache-Control" content="no-store">' \
      '</head><body></body></html>' > /usr/share/novnc/index.html \
    && sed -i "s/NOVNC_VER/${NOVNC_VERSION}/" /usr/share/novnc/index.html

COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# 6080 = noVNC (веб-интерфейс). Порт виден наружу только через прокси code-server:
#   http://localhost:8080/proxy/6080/vnc.html
EXPOSE 6080

ENTRYPOINT ["/usr/local/bin/start.sh"]
