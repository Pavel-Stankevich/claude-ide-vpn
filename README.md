# claude-ide-vpn

**Русский | [English](README.en.md)**

Полноценная IDE в браузере (**code-server**) с интегрированным **Claude Code**
(CLI + расширение), изолированная в Docker. Весь трафик контейнеров идёт через
**WireGuard** или **SOCKS5/HTTP-прокси**, который живёт в отдельном
**sidecar-контейнере**. IDE о прокси ничего не знает — она просто находится
внутри его network namespace. Fail-closed: без рабочего туннеля выхода в
интернет у контейнеров **нет вообще**.

## Возможности

- 🖥️ VS Code в браузере (code-server) с предустановленным Claude Code (CLI + расширение)
- 🔒 Весь трафик через туннель: WireGuard (`*.conf` подхватывается автоматически) или SOCKS5/HTTP (`PROXY_URL`)
- 🧱 Fail-closed по умолчанию: `iptables -P OUTPUT DROP` до поднятия туннеля; direct-режим = полная изоляция
- 🧩 Sidecar-архитектура: IDE имеет zero knowledge о прокси (нет NET_ADMIN, tun, iptables)
- 🌐 Опциональный браузер **внутри контейнера** (Chromium + noVNC) — для OAuth-логинов целиком внутри сети, включая localhost-callback
- 💾 Домашняя папка IDE (`/root`: настройки, расширения, токены Claude) — на диске хоста
- 🕐 Часовой пояс, локаль, git-identity, workspace — всё через `.env`
- ♻️ Самовосстановление: падение туннеля = рестарт sidecar'а; пропажа netns = рестарт IDE

## Архитектура

```
┌────────────────── network namespace (владелец: vpn) ────────────────┐
│  eth0 ─► tun0/wg0 ─► SOCKS5/HTTP/WireGuard                          │
│  fail-closed: iptables -P OUTPUT DROP (lo/tun/upstream/DNS:53)      │
│                                                                     │
│  code-server (ide)   chromium+x11vnc+noVNC (browser, опционально)   │
│       :8080 ◄────────────── :6080 (vnc.html)                        │
└─────────────────────────────────────────────────────────────────────┘
      ▲ http://localhost:8080            ▲ http://localhost:6080/
      └──────────── хост (только просмотр/ввод) ──────────────────────┘
```

## Быстрый старт

```bash
cp .env.example .env          # укажите PROXY_URL или положите wireguard/*.conf
docker compose up -d --build
# IDE: http://localhost:8080  (пароль в .env / docker logs claude-ide)
```

Проверка маршрута:

```bash
docker exec claude-ide-vpn curl -fsS ifconfig.me   # IP туннеля, не ваш
```

## Вход в Claude

Рекомендуемый путь — **вход целиком внутри контейнера**: OAuth-callback по
localhost дойдёт до CLI сам, коды копировать не нужно.

1. В терминале IDE (``Ctrl+` ``) запустите:
   ```
   claude
   ```
   CLI выдаст ссылку вида `https://claude.ai/oauth/authorize?...` и будет ждать.
2. В браузере вашего ПК откройте noVNC: `http://localhost:6080/` — перед вами
   Chromium **внутри контейнера** (весь его трафик уже идёт через туннель).
   Совет: задайте `BROWSER_START_URL=https://claude.ai` в `.env` — страница
   логина будет открыта сразу при старте браузера.
3. Передайте ссылку в буфер контейнера: боковая панель noVNC (стрелка на
   левом краю экрана) → вкладка **Clipboard** → вставьте ссылку туда
   (Ctrl+V) — демон синхронизации положит её в X-буфер контейнера.
4. В Chromium нажмите **Ctrl+L** (фокус в адресную строку) → **Ctrl+V** → Enter.
5. Войдите в аккаунт Anthropic → **Authorize**.
6. Браузер уйдёт на `http://localhost:<порт>/callback?code=...` — этот
   localhost общий для всех контейнеров стека, CLI примет токены автоматически.
7. Вернитесь в терминал IDE — там появится авторизованное приглашение.
   Проверка: `claude "hi"` ответит без запроса логина.

Запасной вариант (без контейнерного браузера): откройте ссылку в браузере ПК →
после авторизации браузер не сможет открыть `localhost:<порт>` (это нормально)
— скопируйте параметр `code` из адресной строки и вставьте в терминал по
приглашению `Paste code here if prompted`. Совсем без браузера —
`ANTHROPIC_API_KEY` в `.env`.

Токены сохраняются в `IDE_HOME` (`~/.claude` + `~/.claude.json`) и переживают пересборку.

## Браузер внутри контейнера

Полноценный Chromium в общем netns: весь его трафик идёт через туннель, а
`localhost` общий с IDE — поэтому OAuth-callback'и (Claude, GitHub и др.)
попадают куда нужно, без копирования кодов. Поднимается вместе со стеком.

- Открыть: `http://localhost:6080/` (порт — `BROWSER_PORT`; также доступно
  через прокси IDE: `/proxy/6080/vnc.html`).
- Буфер обмена: noVNC боковая панель → **Clipboard** → вставьте текст
  (Ctrl+V в поле панели) — он уйдёт в буфер контейнера → в Chromium **Ctrl+V**.
  Обратно: скопируйте текст в Chromium → тот же раздел Clipboard покажет его —
  выделите и скопируйте оттуда. Полностью автоматической синхронизации web-
  клипборд не даёт (ограничение браузеров), промежуточный шаг обязателен.
- Настройки: `BROWSER_PORT`/`BROWSER_BIND` (при `0.0.0.0` задайте
  `VNC_PASSWORD`!), `BROWSER_START_URL` (по умолчанию ifconfig.me —
  сразу видно IP туннеля), `BROWSER_RESOLUTION`.
- ВАЖНО: noVNC ≥ 1.4 требует secure context. `http://localhost:6080` — ОК
  (localhost доверенный), а доступ по `http://<LAN-IP>:6080` работать НЕ будет —
  для удалённого доступа используйте SSH-туннель/прокси на localhost или TLS.

## Режимы туннеля

| `PROXY_MODE` | Поведение |
|---|---|
| `auto` (по умолчанию) | есть `wireguard/*.conf` → WireGuard; иначе `PROXY_URL` → прокси; иначе изолированный direct |
| `wireguard` | только WireGuard (упадёт без конфига) |
| `proxy` | только `PROXY_URL` |
| `direct` | без туннеля, полная изоляция (air-gap) |

`PROXY_URL=socks5://user:pass@host:1080` или `http://user:pass@host:8080`.
Wireguard: положите любой `*.conf` в `wireguard/` (имя не важно, ищется
рекурсивно, берётся первый по алфавиту). Без `DNS=` в конфиге — DNS задаётся
через compose `dns:`.

## Переменные окружения (.env)

| Переменная | Где | Назначение |
|---|---|---|
| `IMAGE_TAG` | compose | тег образов (по умолчанию `latest`; удобно для релизов) |
| `PASSWORD` | ide | пароль входа в IDE; пусто → генерируется в логи |
| `AUTH` | ide | `password` \| `none` |
| `PORT` / `BIND` | compose | порт code-server и адрес публикации на хосте |
| `IDE_HOME` | compose | путь на хосте к домашней папке IDE (дефолт `./ide-home`) |
| `TZ` | ide | часовой пояс (`Europe/Moscow`, …) |
| `LOCALE` / `LANG` | ide | генерация локали / прокидка в окружение (`ru_RU.UTF-8`) |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | ide | `git config --global` при старте |
| `WORKSPACE` | ide | стартовая папка проекта |
| `CS_ARGS` | ide | доп. флаги code-server (напр. `--cert`) |
| `EXTRA_EXTENSIONS` | ide | расширения при первом старте, через запятую |
| `CLAUDE_EXTENSION_AUTOUPDATE` | ide | `1` (дефолт) = при старте: `claude update` (CLI всегда с npm, мгновенный паблиш) + расширение до самой свежей доступной на галерее версии |
| `CLAUDE_EXTENSION_REFRESH` | ide | `1` = переустанавливать расширение всегда, без сравнения версий |
| `PROXY_MODE` / `PROXY_URL` | vpn | см. таблицу режимов |
| `T2S_LOGLEVEL` | vpn | лог tun2socks: `debug`\|`info`\|`warn`\|`error`\|`silent` |
| `NET_HOOK` | vpn | исполняемый скрипт после поднятия сети (класть в `wireguard/hooks/`) |
| `DNS1` / `DNS2` | compose | DNS-резолверы (запросы идут через туннель) |
| `BROWSER_PORT` / `BROWSER_BIND` | compose | порт/адрес noVNC на хосте |
| `VNC_PASSWORD` | browser | пароль noVNC (обязателен при `BROWSER_BIND=0.0.0.0`) |
| `BROWSER_START_URL` / `BROWSER_RESOLUTION` | browser | стартовая страница / разрешение дисплея |

## Структура

```
├── vpn/          # sidecar: владеет netns (wireguard/tun2socks, fail-closed)
├── ide/          # code-server + Claude Code (zero knowledge о прокси)
├── browser/      # Chromium в контейнере (noVNC), поднимается вместе со стеком
├── wireguard/    # ваши *.conf сюда (в git не коммитятся!) + hooks/
├── docker-compose.yml
└── .env.example
```

## Персистентность и безопасность

- `IDE_HOME` — весь `/root` контейнера на хосте: настройки IDE, расширения,
  `~/.claude`, `~/.claude.json`, ssh-ключи, git-config.
- `wireguard/*.conf` содержат приватные ключи — в репозиторий не коммитятся
  (см. `.gitignore`).
- noVNC по умолчанию слушает `127.0.0.1`; при `BROWSER_BIND=0.0.0.0` задайте `VNC_PASSWORD`.
- `--dangerously-skip-permissions` под root CLI отклоняет — используйте auto mode.

## Траблшутинг

- **Нет DNS** в proxy-режиме → SOCKS5 без UDP: поставьте LAN-резолвер (`DNS1=192.168.1.1`).
- **«Could not resolve host» при direct** → так задумано: нет туннеля = нет сети.
- **400 на экране входа Claude** → старая версия расширения. Entrypoint ждёт поднятия туннеля перед установкой, но если всё же встало старое: `CLAUDE_EXTENSION_REFRESH=1` в `.env` → `docker compose up -d` — свежий .vsix скачается с MS Marketplace через туннель. Вручную: `claude update`, затем `code-server --uninstall-extension anthropic.claude-code` и `claude` (CLI доустановит совместимую версию сам).
- **Регион**: трафик выходит с IP вашего туннеля — убедитесь, что страна/IP поддерживаются Anthropic.
- **Кириллица в логах под Windows** → `chcp 65001`.

## License

MIT
