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

# лёгкий оконный менеджер для корректного отображения диалогов, меню и фокуса
DISPLAY=:0 openbox &

# VNC-сервер: пароль передаём через файл auth, чтобы он не светился в ps aux
if [[ -n "$VNC_PASSWORD" ]]; then
    mkdir -p /tmp/.vnc
    x11vnc -storepasswd "$VNC_PASSWORD" /tmp/.vnc/passwd
    chmod 600 /tmp/.vnc/passwd
    x11vnc -display :0 -forever -shared -rfbport 5900 -rfbauth /tmp/.vnc/passwd &
else
    x11vnc -display :0 -forever -shared -rfbport 5900 -nopw &
fi

# noVNC (веб-клиент поверх websockify)
websockify --web /usr/share/novnc 6080 localhost:5900 &

# сам браузер: перезапускаем при закрытии вкладки или сбое без падения всего контейнера
WIDTH="${RESOLUTION%x*}"; HEIGHT="${RESOLUTION#*x}"
(
    while true; do
        DISPLAY=:0 chromium \
            --no-sandbox --disable-gpu --disable-dev-shm-usage \
            --window-size="${WIDTH},${HEIGHT}" --window-position=0,0 \
            --disable-session-crashed-bubble \
            --remote-debugging-port=9222 \
            "$START_URL" || true
        sleep 1
    done
) &

echo "[browser] noVNC: http://localhost:${BROWSER_PORT:-6080}/vnc.html  (или через IDE: /proxy/6080/vnc.html)"
wait -n
