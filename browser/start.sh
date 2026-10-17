#!/usr/bin/env bash
# Браузер внутри общего network namespace (vpn): весь его трафик идёт
# через туннель, а localhost-callback'и OAuth попадают куда нужно.
set -e

VNC_PASSWORD="${VNC_PASSWORD:-}"            # пусто = без пароля (BIND=127.0.0.1)
START_URL="${BROWSER_START_URL:-https://ifconfig.me/}"            # по умолчанию: проверка IP туннеля
RESOLUTION="${BROWSER_RESOLUTION:-1600x900}"  # разрешение виртуального дисплея
                                              # (resize=scale в noVNC всё равно растянет под окно)

# после 'docker restart' (в отличие от recreate) слой контейнера сохраняется —
# без очистки Xvfb увидит lock прошлого запуска и упадёт с
# 'Server is already active for display 0'
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0

# виртуальный дисплей
Xvfb :0 -screen 0 "${RESOLUTION}x24" &
sleep 1

# VNC-сервер. Буфер обмена — нативный: noVNC панель Clipboard (боковое меню)
# в обе стороны. Автоматической синхронизации web-клипборд не даёт (ограничение
# браузеров) — панель это штатный способ.
if [[ -n "$VNC_PASSWORD" ]]; then
    x11vnc -display :0 -forever -shared -rfbport 5900 -passwd "$VNC_PASSWORD" &
else
    x11vnc -display :0 -forever -shared -rfbport 5900 -nopw &
fi

# noVNC (веб-клиент поверх websockify)
websockify --web /usr/share/novnc 6080 localhost:5900 &

# сам браузер. Без оконного менеджера --start-maximized не работает —
# задаём окну явный размер дисплея и позицию 0,0 (адресная строка при этом сохраняется)
WIDTH="${RESOLUTION%x*}"; HEIGHT="${RESOLUTION#*x}"
DISPLAY=:0 chromium \
    --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --window-size="${WIDTH},${HEIGHT}" --window-position=0,0 \
    --disable-session-crashed-bubble \
    "$START_URL" &

echo "[browser] noVNC: http://localhost:${BROWSER_PORT:-6080}/vnc.html  (или через IDE: /proxy/6080/vnc.html)"
wait -n
