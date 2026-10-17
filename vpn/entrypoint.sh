#!/usr/bin/env bash
# ═══ SIDEAR: владеет network namespace ═══
# FAIL-CLOSED: выхода в интернет НЕТ, пока туннель (wireguard|socks5/http)
# не поднят. В direct-режиме контейнер полностью изолирован (air-gapped).
# Wireguard-конфиг ищется автоматически: первый *.conf в /config/wireguard.
set -euo pipefail
log(){ echo "[vpn] $*"; }
die(){ log "ERROR: $*"; exit 1; }

# ── env-настройки ────────────────────────────────────────────
PROXY_MODE="${PROXY_MODE:-auto}"         # auto | direct | proxy | wireguard
PROXY_URL="${PROXY_URL:-}"               # socks5://[user:pass@]host:port | http://[user:pass@]host:port
WG_DIR="/config/wireguard"               # mount с хоста: ./wireguard
T2S_LOGLEVEL="${T2S_LOGLEVEL:-warn}"     # debug|info|warn|error|silent
NET_HOOK="${NET_HOOK:-}"                 # путь к скрипту после поднятия сети (escape hatch)

IFACE=""; T2S_PID=""

# ── шаг 0: FAIL-CLOSED — блокируем ВСЁ до поднятия туннеля ───
log "fail-closed: весь исходящий трафик заблокирован до поднятия туннеля"
iptables -P OUTPUT DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -P OUTPUT DROP 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
fi

# ── DNS: открываем резолверам только 53-й порт ───────────────
allow_dns() {
    local ns
    for ns in $(awk '$1=="nameserver"{print $2}' /etc/resolv.conf | grep -v ':' || true); do
        iptables -A OUTPUT -d "$ns/32" -p udp --dport 53 -j ACCEPT
        iptables -A OUTPUT -d "$ns/32" -p tcp --dport 53 -j ACCEPT
    done
    log "DNS (53) разрешён резолверам из resolv.conf"
}

# ── разрешить исходящий ЧЕРЕЗ интерфейс туннеля ─────────────
# Без этого правила пакеты, завёрнутые в tun0/wg0, умирают на policy DROP:
# filter OUTPUT видит oif=туннель, а раньше разрешались lo/est/DNS/upstream.
allow_iface() {
    iptables -A OUTPUT -o "$1" -j ACCEPT
    ip6tables -A OUTPUT -o "$1" -j ACCEPT 2>/dev/null || true
    log "разрешён исходящий через $1"
}

# ── авто-поиск wireguard-конфига: первый *.conf в $WG_DIR ────
find_wg_conf() {
    local confs=()
    mapfile -t confs < <(find "$WG_DIR" -type f -name '*.conf' ! -name '*.example.conf' 2>/dev/null | sort)
    [[ ${#confs[@]} -eq 0 ]] && return 0
    [[ ${#confs[@]} -gt 1 ]] && log "найдено ${#confs[@]} конфигов, беру первый: ${confs[0]}"
    printf '%s\n' "${confs[0]}"
}

# ── wireguard ────────────────────────────────────────────────
start_wireguard() {
    local conf="$1"
    log "wireguard: использую $conf"
    # endpoint из конфига: разрешаем ДО wg-quick up (handshake идёт сразу)
    local eph eip
    eph="$(awk -F'=' '/^[[:space:]]*Endpoint[[:space:]]*=/{v=$2; gsub(/[[:space:]]/,"",v); print v; exit}' "$conf" | cut -d: -f1)"
    if [[ -n "$eph" ]]; then
        allow_dns
        eip="$(getent ahostsv4 "$eph" 2>/dev/null | awk 'NR==1{print $1}' || true)"
        [[ -z "$eip" ]] && die "wg endpoint не резолвится: $eph"
        iptables -A OUTPUT -d "$eip/32" -j ACCEPT
        log "wireguard: endpoint $eph -> $eip (разрешён)"
    else
        die "wireguard: в $conf нет поля Endpoint"
    fi
    install -m 600 "$conf" /run/wg0.conf          # имя файла = имя интерфейса
    wg-quick up /run/wg0.conf
    allow_iface wg0
    IFACE=wg0
}

# ── socks5/http через tun2socks ──────────────────────────────
start_tun2socks() {
    local re='^([a-zA-Z0-9]+)://(([^:@]*)(:([^@]*))?@)?([^:/]+):([0-9]+)/?$'
    [[ "$PROXY_URL" =~ $re ]] || die "не могу разобрать PROXY_URL: '$PROXY_URL'"
    local scheme="${BASH_REMATCH[1]}" user="${BASH_REMATCH[3]}" pass="${BASH_REMATCH[5]}"
    local host="${BASH_REMATCH[6]}" port="${BASH_REMATCH[7]}"
    [[ "$scheme" =~ ^(socks5|http)$ ]] || die "схема должна быть socks5:// или http://"

    allow_dns
    local up_ip; up_ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    [[ -n "$up_ip" ]] || die "хост прокси не резолвится: $host"
    local orig_gw; orig_gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}' || true)"
    [[ -n "$orig_gw" ]] || die "default gateway не найден"
    iptables -A OUTPUT -d "$up_ip/32" -j ACCEPT      # tun2socks -> прокси (напрямую)

    local creds=""; [[ -n "$user" ]] && { creds="$user"; [[ -n "$pass" ]] && creds+=":$pass"; creds+="@"; }

    log "tun2socks: весь трафик netns -> $scheme://$host:$port"
    tun2socks --device tun://tun0 --proxy "$scheme://${creds}${up_ip}:${port}" --loglevel "$T2S_LOGLEVEL" &
    T2S_PID=$!
    sleep 1
    kill -0 "$T2S_PID" 2>/dev/null || die "tun2socks не запустился"

    ip addr add 198.18.0.1/30 dev tun0 2>/dev/null || true
    ip link set tun0 up
    ip route replace "$up_ip/32" via "$orig_gw"      # сам прокси — мимо туннеля (антипетля)
    ip route replace default dev tun0                # всё остальное — в туннель
    allow_iface tun0
    IFACE=tun0
}

# ── выбор режима ─────────────────────────────────────────────
MODE="$PROXY_MODE"
WG_CONF="$(find_wg_conf)"
if [[ "$MODE" == "auto" ]]; then
    if   [[ -n "$WG_CONF" ]];  then MODE=wireguard;
    elif [[ -n "$PROXY_URL" ]]; then MODE=proxy;
    else MODE=direct; fi
fi
case "$MODE" in
    direct)    log "direct: контейнер ИЗОЛИРОВАН — выхода в интернет нет (fail-closed)" ;;
    wireguard) [[ -n "$WG_CONF" ]] || die "wireguard: в $WG_DIR нет ни одного *.conf"
               start_wireguard "$WG_CONF" ;;
    proxy)     start_tun2socks ;;
    *) die "PROXY_MODE=$PROXY_MODE (ожидалось: auto|direct|proxy|wireguard)" ;;
esac

# ── пользовательский hook после поднятия сети ────────────────
if [[ -n "$NET_HOOK" && -x "$NET_HOOK" ]]; then
    log "NET_HOOK: $NET_HOOK"
    "$NET_HOOK" || log "WARN: NET_HOOK завершился с ошибкой (продолжаю)"
fi

trap 'log "остановка..."; kill -TERM $T2S_PID 2>/dev/null || true; exit 0' TERM INT

# ── держим netns живым; смерть туннеля = рестарт контейнера ──
if [[ -n "$T2S_PID" ]]; then
    wait "$T2S_PID" || true
    log "tun2socks упал — рестарт контейнера (docker restart)"; exit 1
elif [[ -n "$IFACE" ]]; then
    while ip link show "$IFACE" >/dev/null 2>&1; do
        sleep 5 & wait $!
    done
    log "интерфейс $IFACE исчез — рестарт контейнера (docker restart)"; exit 1
else
    log "direct: держу netns (изолированный)"
    while true; do sleep 3600 & wait $!; done
fi
