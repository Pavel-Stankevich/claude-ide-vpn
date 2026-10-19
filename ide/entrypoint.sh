#!/usr/bin/env bash
# ═══ IDE: ничего не знает про прокси/VPN ═══
# Живёт в network namespace контейнера vpn (network_mode: service:vpn).
set -euo pipefail
EP_VER="1.1-sdkman"
log(){ echo "[ide] $*"; }
log "entrypoint v$EP_VER — если версия старая, файл не обновлён с диска/образа"

# ── env-настройки ────────────────────────────────────────────
PORT="${PORT:-8080}"
AUTH="${AUTH:-password}"                 # password | none
PASSWORD="${PASSWORD:-}"
TZ="${TZ:-UTC}"
WORKSPACE="${WORKSPACE:-/root/workspace}"   # стартовая папка проекта
IDE_EXTENSIONS="${IDE_EXTENSIONS:-${EXTRA_EXTENSIONS:-}}"   # расширения VS Code: "pub.ext1,pub.ext2" (первый старт; EXTRA_EXTENSIONS — устаревший алиас)
SDK_PKGS="${SDK_PKGS:-}"                    # тулчейны SDKMAN: "java:21.0.5-tem,maven:3.9.9,gradle:8.10"
CLAUDE_MARKETPLACES="${CLAUDE_MARKETPLACES:-}"       # маркетплейсы плагинов: "gh:owner/repo,..." через запятую
CLAUDE_PLUGINS="${CLAUDE_PLUGINS:-}"                 # плагины Claude Code: "имя@маркетплейс,..." через запятую
EXTRA_APT_PACKAGES="${EXTRA_APT_PACKAGES:-}" # любые apt-пакеты при старте: "postgresql-client redis-tools"
INSTALL_SCRIPTS="${INSTALL_SCRIPTS:-1}"             # 0 = не выполнять скрипты из install.d/
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
    [[ "${PROXY_MODE:-auto}" == "direct" ]] && return 0
    local i
    for i in $(seq 1 45); do
        if curl -4 -fsS -o /dev/null --connect-timeout 2 --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null || \
           curl -4 -s -o /dev/null --connect-timeout 2 --max-time 4 https://marketplace.visualstudio.com 2>/dev/null; then
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
    local ext_dir="/root/.local/share/code-server/extensions"
    [[ -d "$ext_dir" ]] || return 0
    if [[ -f "$ext_dir/.obsolete" ]]; then
        for obs in $(jq -r 'keys[]' "$ext_dir/.obsolete" 2>/dev/null || true); do
            [[ -n "$obs" && -d "$ext_dir/$obs" ]] && rm -rf "$ext_dir/$obs"
        done
        rm -f "$ext_dir/.obsolete" 2>/dev/null || true
    fi
    ls -d "$ext_dir"/anthropic.claude-code-* 2>/dev/null | sed 's/.*claude-code-//' | sort -V | tail -1 || true
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
        log "расширение Claude Code: $(installed_ext_version | sed 's/-linux-.*//')"
    else
        log "галерея code-server недоступна — пробую MS Marketplace напрямую..."
        install_from_vsix_fallback \
            || log "WARN: и MS Marketplace молчит — оставляю $(installed_ext_version || echo none). Запустите 'claude' в терминале"
    fi
}

# ── SDKMAN: бутстрап в ~/.sdkman (bind-mount перекрывает /root образа) ──
ensure_sdkman() {
    if [[ ! -d /root/.sdkman && -d /opt/sdkman ]]; then
        log "ставлю SDKMAN в ~/.sdkman (из образа)"
        cp -a /opt/sdkman /root/.sdkman
    fi
    touch /root/.bashrc 2>/dev/null || true
    if [[ -d /root/.sdkman ]] && ! grep -q 'sdkman-init.sh' /root/.bashrc 2>/dev/null; then
        echo 'source "$HOME/.sdkman/bin/sdkman-init.sh"' >> /root/.bashrc
        log "добавил инициализацию SDKMAN в ~/.bashrc"
    fi
}

# ── первая инициализация (домашняя папка пустая) ─────────────
if [[ ! -f /root/.ide-initialized ]]; then
    log "первая инициализация: копирую предустановленные расширения..."
    mkdir -p /root/.local/share/code-server/extensions
    cp -rn /opt/default-ext/. /root/.local/share/code-server/extensions/ 2>/dev/null || true
    if [[ -n "$IDE_EXTENSIONS" ]]; then
        IFS=',' read -ra exts <<< "$IDE_EXTENSIONS"
        for e in "${exts[@]}"; do log "ставлю $e"; code-server --install-extension "$e" || true; done
    fi
    ensure_sdkman
    touch /root/.ide-initialized
fi

# ── тулчейны: SDKMAN (JDK/Maven/Gradle/...) + доп. apt-пакеты ──
setup_toolchains() {
    if [[ -n "$EXTRA_APT_PACKAGES" ]]; then
        log "ставлю apt-пакеты: $EXTRA_APT_PACKAGES"
        apt-get update -qq \
            && apt-get install -y --no-install-recommends $EXTRA_APT_PACKAGES \
            || log "WARN: установка apt-пакетов не вышла"
    fi
    if [[ -n "$SDK_PKGS" ]]; then
        ensure_sdkman
    fi
    if [[ -n "$SDK_PKGS" && -d /root/.sdkman ]]; then
        # shellcheck disable=SC1091
        # sdkman-init и сам sdk не объявляют часть переменных —
        # под set -u падают; отключаем nounset на весь блок
        set +u
        source /root/.sdkman/bin/sdkman-init.sh
        local item cand ver first_java=""
        IFS=',' read -ra items <<< "$SDK_PKGS"
        for item in "${items[@]}"; do
            item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"  # trim
            [[ -z "$item" ]] && continue
            cand="${item%%:*}"; ver="${item#*:}"
            if [[ "$cand" == "$ver" ]]; then
                log "sdk install $cand (последняя stable)"
                yes | sdk install "$cand" || true
                ver="$(ls /root/.sdkman/candidates/$cand 2>/dev/null | grep -v '^current$' | sort -V | tail -1 || true)"
            else
                log "sdk install $cand $ver"
                yes | sdk install "$cand" "$ver" || true
            fi
            if [[ "$cand" == "java" && -z "$first_java" && -n "$ver" ]]; then
                first_java="$ver"
            fi
        done
        set -u
        if [[ -n "$first_java" ]]; then
            sdk default java "$first_java" || true
            export JAVA_HOME="/root/.sdkman/candidates/java/$first_java"
            export PATH="$JAVA_HOME/bin:$PATH"
            log "JAVA_HOME=$JAVA_HOME"
        fi
    elif [[ -n "$SDK_PKGS" ]]; then
        log "WARN: SDK_PKGS задан, но SDKMAN недоступен (в образе нет /opt/sdkman — пересоберите ide)"
    fi
}

# ── кастомные скрипты установки: /opt/install.d (смонтировано с хоста) ──
# Каждый исполняемый *.sh выполняется при старте (root, сеть через туннель).
# Идемпотентность — на совести скрипта. Ставьте в $HOME — это IDE_HOME.
run_install_scripts() {
    [[ "${INSTALL_SCRIPTS:-1}" == "1" ]] || return 0
    local dir=/opt/install.d s
    [[ -d "$dir" ]] || return 0
    for s in "$dir"/*.sh; do
        [[ -f "$s" ]] || continue
        log "install-script: $(basename "$s")"
        bash "$s" || log "WARN: $(basename "$s") завершился с ошибкой — см. вывод выше"
    done
}

# ── держим CLI и расширение свежими при каждом старте ────────
if [[ -n "$SDK_PKGS" || -n "$EXTRA_APT_PACKAGES" || "${INSTALL_SCRIPTS:-1}" == "1" ]]; then
    wait_for_net
    setup_toolchains
    run_install_scripts
fi

[[ "$AUTH" == "password" && -z "$PASSWORD" ]] && PASSWORD="$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)"
export PASSWORD
if [[ -n "$PASSWORD" ]]; then
    mkdir -p /root/.config/code-server
    echo "$PASSWORD" > /root/.config/code-server/password
    chmod 600 /root/.config/code-server/password 2>/dev/null || true
fi
log "code-server: http://localhost:$PORT (auth=$AUTH, workspace=$WORKSPACE)"
[[ -n "$PASSWORD" ]] && log "пароль: $PASSWORD (сохранён в ~/.config/code-server/password)"

# shellcheck disable=SC2086
code-server --bind-addr "0.0.0.0:$PORT" --auth "$AUTH" --disable-telemetry ${CS_ARGS:-} "$WORKSPACE" &
CS_PID=$!
trap 'kill -TERM $CS_PID 2>/dev/null; exit 0' TERM INT

if [[ "$CLAUDE_EXTENSION_AUTOUPDATE" == "1" || "$CLAUDE_EXTENSION_REFRESH" == "1" || -z "$(installed_ext_version)" ]]; then
    (
        if ! command -v claude >/dev/null 2>&1; then
            log "устанавливаю Claude Code CLI через туннель..."
            npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 || log "WARN: npm install claude-code не вышел"
        else
            timeout 300 claude update >/dev/null 2>&1 || log "WARN: claude update не вышел (сеть/таймаут) — оставляю текущий CLI"
        fi
        update_claude_extension

        if [[ -n "$CLAUDE_MARKETPLACES" ]]; then
            local_m="${CLAUDE_MARKETPLACES//[[:space:]]/}"
            IFS=',' read -ra ms <<< "$local_m"
            for m in "${ms[@]}"; do
                [[ -z "$m" ]] && continue
                claude plugin marketplace add "$m" >/dev/null 2>&1 \
                    || log "WARN: маркетплейс $m не добавлен (нужен вход в Claude?)"
            done
        fi
        if [[ -n "$CLAUDE_PLUGINS" ]]; then
            local_p="${CLAUDE_PLUGINS//[[:space:]]/}"
            IFS=',' read -ra ps <<< "$local_p"
            for plg in "${ps[@]}"; do
                [[ -z "$plg" ]] && continue
                claude plugin install "$plg" >/dev/null 2>&1 \
                    || log "WARN: плагин $plg не установлен (маркетплейс добавлен? вход в Claude?)"
            done
        fi

        log "версии: CLI $(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true) | расширение $(installed_ext_version | sed 's/-linux-.*//')" || true
    ) &
fi

# ── watchdog: netns принадлежит vpn-контейнеру ───────────────
while true; do
    kill -0 "$CS_PID" 2>/dev/null || { log "code-server завершился"; break; }
    [[ -d /sys/class/net/eth0 ]] || { log "сетевой namespace исчез (vpn перезапущен) — рестарт"; break; }
    sleep 2 & wait $!
done
kill -TERM "$CS_PID" 2>/dev/null || true
exit 1
