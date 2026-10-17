#!/usr/bin/env bash
# ═══ IDE: ничего не знает про прокси/VPN ═══
# Живёт в network namespace контейнера vpn (network_mode: service:vpn).
set -euo pipefail
log(){ echo "[ide] $*"; }

# ── env-настройки ────────────────────────────────────────────
PORT="${PORT:-8080}"
AUTH="${AUTH:-password}"                 # password | none
PASSWORD="${PASSWORD:-}"
TZ="${TZ:-UTC}"
WORKSPACE="${WORKSPACE:-/root/workspace}"   # стартовая папка проекта
EXTRA_EXTENSIONS="${EXTRA_EXTENSIONS:-}"    # "publisher.ext1,publisher.ext2" (первый старт)
CS_ARGS="${CS_ARGS:-}"                      # любые доп. флаги code-server
GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"
# расширение Claude Code: по умолчанию ДЕРЖИМ СВЕЖИМ автоматически —
# при старте: claude update (CLI) + переустановка расширения через галерею
CLAUDE_EXTENSION_AUTOUPDATE="${CLAUDE_EXTENSION_AUTOUPDATE:-1}"  # 0 = не трогать после первой установки
CLAUDE_EXTENSION_REFRESH="${CLAUDE_EXTENSION_REFRESH:-0}"        # 1 = переустанавливать ВСЕГДА (игнорируя сравнение)

# ── часовой пояс ─────────────────────────────────────────────
if [[ -e "/usr/share/zoneinfo/$TZ" ]]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime 2>/dev/null || true
    log "часовой пояс: $TZ ($(date +%H:%M:%S))"
else
    log "WARN: TZ=$TZ не найден в /usr/share/zoneinfo, оставляю системный"
fi

# ── локаль: LOCALE генерирует, LANG/LC_ALL прокидывайте в .env ──
if [[ -n "${LOCALE:-}" && "$LOCALE" != "C.UTF-8" ]]; then
    if ! locale -a 2>/dev/null | grep -qi "^${LOCALE%.*}\.utf-\?8$"; then
        log "генерирую локаль $LOCALE..."
        echo "$LOCALE ${LOCALE#*.}" >> /etc/locale.gen
        locale-gen "$LOCALE" >/dev/null 2>&1 || log "WARN: не удалось сгенерировать $LOCALE"
    fi
fi

# ── git-identity ─────────────────────────────────────────────
[[ -n "$GIT_USER_NAME" ]]  && git config --global user.name  "$GIT_USER_NAME"
[[ -n "$GIT_USER_EMAIL" ]] && git config --global user.email "$GIT_USER_EMAIL"

mkdir -p "$WORKSPACE"

# ── ждём, пока vpn-sidecar поднимет туннель ─────────────────
# ide стартует сразу после vpn (depends_on), но туннель поднимается секунды:
# fail-closed уже режет трафик, а маршрутов ещё нет.
wait_for_net() {
    local i
    for i in $(seq 1 45); do
        # marketplace отдаёт curl 403 (бот-детект) — важен сам факт связности
        if curl -4 -s -o /dev/null --connect-timeout 3 --max-time 6 https://marketplace.visualstudio.com 2>/dev/null; then
            log "сеть через туннель доступна"
            return 0
        fi
        sleep 2
    done
    log "WARN: сеть не поднялась за 90 секунд — продолжаю"
    return 1
}

# ── установка/обновление расширения Claude Code ──
# Основной путь (проверен вручную): штатная галерея code-server сама резолвит
# последнюю доступную версию — `code-server --install-extension
# anthropic.claude-code --force` ставит версию вплоть до совпадения с CLI.
# Fallback, если галерея лежит/отстаёт: прямое скачивание .vsix с MS
# Marketplace с перебором кандидатов (обходит staged-rollout 404).
CC_UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
CC_VSIX=/tmp/claude-code.vsix

installed_ext_version() {
    ls -d /root/.local/share/code-server/extensions/anthropic.claude-code-* 2>/dev/null | sed 's/.*claude-code-//' | head -1 || true
}

# список версий из gallery API (свежие сверху)
list_version_candidates() {
    curl -4 -sSL --compressed --connect-timeout 10 --max-time 30 \
        -A "$CC_UA" \
        -H 'Accept: application/json;api-version=7.1-preview.1' \
        -H 'Content-Type: application/json' \
        -X POST \
        -d '{"filters":[{"criteria":[{"filterType":7,"value":"anthropic.claude-code"}]}],"flags":2151}' \
        'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery?api-version=7.1-preview.1' \
        2>/dev/null | jq -r '.results[0].extensions[0].versions[].version // empty' 2>/dev/null || true
}

download_vsix() {  # 0 = $CC_VSIX скачан и является zip. $1 = версия
    curl -4 -fsSL --compressed --connect-timeout 20 --max-time 300 --retry 1 --retry-all-errors \
         -A "$CC_UA" \
         -H "Accept: application/octet-stream;api-version=3.0-preview.1" \
         "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/anthropic/vsextensions/claude-code/${1:-latest}/vspackage" \
         -o "$CC_VSIX" \
    && head -c 2 "$CC_VSIX" | grep -q '^PK'
}

download_first_available() {  # качает первую версию из списка $1, что отдаётся
    local v
    while IFS= read -r v; do
        [[ -z "$v" ]] && continue
        if download_vsix "$v"; then
            echo "$v"
            return 0
        fi
    done <<< "$1"
    return 1
}

resolve_and_download() {  # 0 = $CC_VSIX готов; печатает выбранную версию
    local cands picked=""
    cands="$(list_version_candidates)"
    if [[ -n "$cands" ]]; then
        picked="$(download_first_available "$cands" || true)"
        [[ -n "$picked" ]] && { echo "$picked"; return 0; }
    fi
    picked="$(npm view @anthropic-ai/claude-code version 2>/dev/null | tail -n1 || true)"
    if [[ -n "$picked" ]] && download_vsix "$picked"; then
        echo "$picked"; return 0
    fi
    if download_vsix "latest"; then
        echo "latest"; return 0
    fi
    return 1
}

install_from_vsix_fallback() {
    local picked
    picked="$(resolve_and_download || true)"
    if [[ -z "$picked" ]]; then
        rm -f "$CC_VSIX"
        return 1
    fi
    code-server --install-extension "$CC_VSIX" --force \
        && log "расширение Claude Code установлено с MS Marketplace (версия: $picked)"
    rm -f "$CC_VSIX"
}

update_claude_extension() {
    wait_for_net || return 0
    log "обновляю расширение Claude Code (штатная галерея)..."
    if code-server --install-extension anthropic.claude-code --force; then
        log "расширение Claude Code: $(installed_ext_version)"
    else
        log "галерея code-server недоступна — пробую MS Marketplace напрямую..."
        install_from_vsix_fallback \
            || log "WARN: и MS Marketplace молчит — оставляю $(installed_ext_version || echo none). Запустите 'claude' в терминале"
    fi
}

# ── первая инициализация (домашняя папка пустая) ─────────────
if [[ ! -f /root/.ide-initialized ]]; then
    log "первая инициализация: копирую предустановленные расширения..."
    mkdir -p /root/.local/share/code-server/extensions
    cp -rn /opt/default-ext/. /root/.local/share/code-server/extensions/ 2>/dev/null || true
    if [[ -n "$EXTRA_EXTENSIONS" ]]; then
        IFS=',' read -ra exts <<< "$EXTRA_EXTENSIONS"
        for e in "${exts[@]}"; do log "ставлю $e"; code-server --install-extension "$e" || true; done
    fi
    touch /root/.ide-initialized
fi

# ── держим CLI и расширение свежими при каждом старте ────────
if [[ "$CLAUDE_EXTENSION_AUTOUPDATE" == "1" || "$CLAUDE_EXTENSION_REFRESH" == "1" || -z "$(installed_ext_version)" ]]; then
    # расширение ставим ВСЕГДА, если его нет (даже при AUTOUPDATE=0) —
    # иначе при сбое скачивания на сборке IDE осталась бы без расширения
    # CLI: npm-паблиш мгновенен — это всегда самая свежая версия (тот же
    # "claude update", что вручную). Расширение догонит CLI в окно раскатки.
    log "обновляю Claude Code CLI (npm, через туннель)..."
    timeout 180 claude update >/dev/null 2>&1 || log "WARN: claude update не вышел (сеть/таймаут) — оставляю текущий CLI"
    update_claude_extension
fi
log "версии: CLI $(claude --version 2>/dev/null | awk '{print $2}' || true) | расширение $(installed_ext_version)" || true

[[ "$AUTH" == "password" && -z "$PASSWORD" ]] && PASSWORD="$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)"
export PASSWORD
log "code-server: http://localhost:$PORT (auth=$AUTH, workspace=$WORKSPACE)"
[[ -n "$PASSWORD" ]] && log "пароль: $PASSWORD"

# shellcheck disable=SC2086
code-server --bind-addr "0.0.0.0:$PORT" --auth "$AUTH" --disable-telemetry ${CS_ARGS:-} "$WORKSPACE" &
CS_PID=$!
trap 'kill -TERM $CS_PID 2>/dev/null; exit 0' TERM INT

# ── watchdog: netns принадлежит vpn-контейнеру ───────────────
while true; do
    kill -0 "$CS_PID" 2>/dev/null || { log "code-server завершился"; break; }
    [[ -d /sys/class/net/eth0 ]] || { log "сетевой namespace исчез (vpn перезапущен) — рестарт"; break; }
    sleep 2 & wait $!
done
kill -TERM "$CS_PID" 2>/dev/null || true
exit 1
