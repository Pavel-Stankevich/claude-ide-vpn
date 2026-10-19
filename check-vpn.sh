#!/usr/bin/env bash
set -e

echo "=== Проверка сетевой изоляции claude-ide-vpn ==="
echo ""

VPN_IP=$(docker exec claude-ide-vpn curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "ОШИБКА")
echo "[1/4] IP в claude-ide-vpn: $VPN_IP"

IDE_IP=$(docker exec claude-ide curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "ОШИБКА")
echo "[2/4] IP в claude-ide:     $IDE_IP"

BRW_IP=$(docker exec claude-ide-browser curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "ОШИБКА")
echo "[3/4] IP в browser:        $BRW_IP"

DNS_RAW=$(docker exec claude-ide-vpn dig +short TXT whoami.ds.akahelp.net 2>/dev/null || echo "")
DNS_IP=$(echo "$DNS_RAW" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
echo "[4/4] DNS резолвер видит:  $DNS_IP"

echo ""
if [[ "$VPN_IP" != "ОШИБКА" && "$VPN_IP" == "$IDE_IP" && "$VPN_IP" == "$BRW_IP" ]]; then
    echo "✅ ВСЕ ЗАПРОСЫ ИДУТ ЧЕРЕЗ ТУННЕЛЬ: $VPN_IP"
    echo "🔒 Защита активна: утечки домашнего IP отсутствуют."
else
    echo "⚠️ ВНИМАНИЕ: Проверьте работу туннеля (IP не совпадают или ошибка связи)"
fi
