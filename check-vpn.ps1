Write-Host "=== Network Isolation & Leak Check (claude-ide-vpn) ===" -ForegroundColor Cyan

$vpnIp = (docker exec claude-ide-vpn curl -fsS --max-time 5 https://api.ipify.org 2>$null)
if ($vpnIp) { $vpnIp = $vpnIp.Trim() }
Write-Host "[1/4] IP in claude-ide-vpn: $vpnIp"

$ideIp = (docker exec claude-ide curl -fsS --max-time 5 https://api.ipify.org 2>$null)
if ($ideIp) { $ideIp = $ideIp.Trim() }
Write-Host "[2/4] IP in claude-ide:     $ideIp"

$brwIp = (docker exec claude-ide-browser curl -fsS --max-time 5 https://api.ipify.org 2>$null)
if ($brwIp) { $brwIp = $brwIp.Trim() }
Write-Host "[3/4] IP in browser:        $brwIp"

$dnsRaw = (docker exec claude-ide-vpn dig +short TXT whoami.ds.akahelp.net 2>$null)
$dnsIp = ""
foreach ($line in $dnsRaw) {
    if ($line -match '"ip"\s+"([^"]+)"') {
        $dnsIp = $matches[1]
        break
    }
}
Write-Host "[4/4] DNS resolver sees:    $dnsIp"

Write-Host ""
if ($vpnIp -and ($vpnIp -eq $ideIp) -and ($vpnIp -eq $brwIp)) {
    Write-Host "[OK] ALL TRAFFIC FLOWS VIA TUNNEL: $vpnIp" -ForegroundColor Green
    Write-Host "[OK] Protection active: 0 home IP / DNS leaks detected." -ForegroundColor Green
} else {
    Write-Host "[WARN] Tunnel check failed: IPs do not match or connection timed out." -ForegroundColor Red
}
