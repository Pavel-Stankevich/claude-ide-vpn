# claude-ide-vpn

**[Русский](README.md) | English**

A full-featured browser IDE (**code-server**) with **Claude Code** built in
(CLI + extension), isolated in Docker. All container traffic goes through
**WireGuard** or a **SOCKS5/HTTP proxy** living in a separate **sidecar
container**. The IDE knows nothing about the proxy — it simply lives inside
its network namespace. Fail-closed: without a working tunnel the containers
have **no internet access at all**.

## Features

- 🖥️ VS Code in the browser (code-server) with Claude Code preinstalled (CLI + extension)
- 🔒 All traffic through a tunnel: WireGuard (`*.conf` auto-discovered) or SOCKS5/HTTP (`PROXY_URL`)
- 🧱 Fail-closed by default: `iptables -P OUTPUT DROP` until the tunnel is up; direct mode = full isolation
- 🧩 Sidecar architecture: the IDE has zero knowledge of the proxy (no NET_ADMIN, no tun, no iptables)
- 🌐 Optional **in-container browser** (Chromium + noVNC) — for OAuth logins entirely inside the network, including localhost callbacks
- 💾 The IDE home directory (`/root`: settings, extensions, Claude tokens) lives on the host disk
- 🕐 Timezone, locale, git identity, workspace — all via `.env`
- ♻️ Self-healing: tunnel crash = sidecar restart; netns loss = IDE restart

## Architecture

```
+------------------ network namespace (owned by: vpn) ------------------+
|  eth0 -> tun0/wg0 -> SOCKS5/HTTP/WireGuard                            |
|  fail-closed: iptables -P OUTPUT DROP (lo/tun/upstream/DNS:53)        |
|                                                                       |
|  code-server (ide)   chromium+x11vnc+noVNC (browser, optional)        |
|       :8080 <-------------- :6080 (vnc.html)                          |
+-----------------------------------------------------------------------+
      ^ http://localhost:8080            ^ http://localhost:6080/
      +---------------- host (view/input only) ------------------------+
```

## Quick start

```bash
cp .env.example .env          # set PROXY_URL or drop a wireguard/*.conf
docker compose up -d --build
# IDE: http://localhost:8080  (password in .env / docker logs claude-ide)
```

Verify the route:

```bash
docker exec claude-ide-vpn curl -fsS ifconfig.me   # tunnel IP, not yours
```

## Signing in to Claude

The recommended path is **signing in entirely inside the container**: the
OAuth localhost callback reaches the CLI on its own, no codes to copy.

1. In the IDE terminal (``Ctrl+` ``) run:
   ```
   claude
   ```
   The CLI prints a link like `https://claude.ai/oauth/authorize?...` and waits.
2. In a browser on your PC open noVNC: `http://localhost:6080/` — you will see
   Chromium **inside the container** (all its traffic already goes through the
   tunnel). Tip: set `BROWSER_START_URL=https://claude.ai` in `.env` to have
   the login page open as soon as the browser starts.
3. Hand the link to the container's clipboard: noVNC side panel (arrow on the
   left edge) → **Clipboard** tab → paste the link there (Ctrl+V) — the sync
   daemon puts it into the container's X clipboard.
4. In Chromium press **Ctrl+L** (focus the address bar) → **Ctrl+V** → Enter.
5. Log in to your Anthropic account → **Authorize**.
6. The browser navigates to `http://localhost:<port>/callback?code=...` —
   localhost is shared by all containers in the stack, so the CLI receives
   the tokens automatically.
7. Switch back to the IDE terminal — the authorized prompt appears.
   Verify: `claude "hi"` answers without asking you to log in.

Fallback (without the in-container browser): open the link in your PC's
browser → after authorization the browser will fail to open
`localhost:<port>` (that's expected) — copy the `code` parameter from the
address bar and paste it into the terminal at the `Paste code here if
prompted` prompt. To skip the browser entirely, use `ANTHROPIC_API_KEY` in
`.env`.

Tokens are stored in `IDE_HOME` (`~/.claude` + `~/.claude.json`) and survive rebuilds.

## In-container browser

A full Chromium in the shared netns: all its traffic goes through the
tunnel, and `localhost` is shared with the IDE — so OAuth callbacks (Claude,
GitHub, etc.) reach the right place without copying any codes. Starts
together with the stack.

- Open: `http://localhost:6080/` (port via `BROWSER_PORT`; also available
  through the IDE proxy: `/proxy/6080/vnc.html`).
- Clipboard: noVNC side panel → **Clipboard** → paste text (Ctrl+V into the
  panel field) — it goes to the container's clipboard → **Ctrl+V** in Chromium.
  Backward: copy text in Chromium → the same Clipboard panel shows it — select
  and copy it from there. Fully automatic sync is impossible for a web
  clipboard (browser limitation); the intermediate step is mandatory.
- Settings: `BROWSER_PORT`/`BROWSER_BIND` (set `VNC_PASSWORD` with
  `0.0.0.0`!), `BROWSER_START_URL` (defaults to ifconfig.me —
  instantly shows the tunnel's exit IP), `BROWSER_RESOLUTION`.
- IMPORTANT: noVNC ≥ 1.4 requires a secure context. `http://localhost:6080`
  is fine (localhost is trusted), but `http://<LAN-IP>:6080` will NOT work —
  use an SSH tunnel/proxy to localhost or TLS for remote access.

## Toolchains: JDK, Maven, Gradle and more

**SDKMAN** is preinstalled. Install any JDK (Temurin, Corretto, GraalVM…),
Maven, Gradle, Kotlin, Scala in two ways:

1. Declaratively, via `.env` (applied on container start, idempotent):
   ```bash
   SDK_PKGS=java:21.0.5-tem,java:17.0.13-tem,maven:3.9.9
   ```
2. Manually in the IDE terminal:
   ```
   sdk list java
   sdk install java 25-tem
   sdk default java 21.0.5-tem
   ```

The first `java` in `SDK_PKGS` becomes the default (`JAVA_HOME` for
code-server and terminals). Everything installs into `~/.sdkman` → on the
host disk (`IDE_HOME`), survives rebuilds.

For non-JVM tooling — any apt packages:
```bash
EXTRA_APT_PACKAGES=postgresql-client redis-tools
```

## Docker inside the IDE

The stack includes a nested docker daemon (DinD): build and run containers
right from the IDE terminal. It starts together with all other services.

- The ide image contains only the **docker-cli**; the daemon lives in the
  `dind` service (privileged, `docker:27-dind` image), its data is stored in
  the `docker-data` volume (doesn't bloat `IDE_HOME`; purge cache with
  `docker compose down -v`).
- `DOCKER_HOST` is preconfigured: `docker build/run/pull` work out of the box.
- **Nested containers' traffic goes through the tunnel** (shared netns,
  default route → tun0): `docker run curlimages/curl ifconfig.me` shows the
  tunnel IP.
- Ports of nested containers (`-p 8080:8080`) are reachable inside the stack
  (ide, in-container browser) at `localhost:8080`; from the host only if you
  add a port mapping to the vpn service.
- To disable nested docker, comment out the `dind` service in
  `docker-compose.yml` (the `docker` command in ide will stop connecting —
  that's expected).

## Tunnel modes

| `PROXY_MODE` | Behavior |
|---|---|
| `auto` (default) | `wireguard/*.conf` present → WireGuard; else `PROXY_URL` → proxy; else isolated direct |
| `wireguard` | WireGuard only (fails without a config) |
| `proxy` | `PROXY_URL` only |
| `direct` | no tunnel, full isolation (air-gap) |

`PROXY_URL=socks5://user:pass@host:1080` or `http://user:pass@host:8080`.
WireGuard: drop any `*.conf` into `wireguard/` (name doesn't matter, searched
recursively, first alphabetically wins). Keep `DNS=` out of the config — DNS
is managed via compose `dns:`.

## Environment variables (.env)

| Variable | Scope | Purpose |
|---|---|---|
| `IMAGE_TAG` | compose | image tag (default `latest`; handy for releases) |
| `PASSWORD` | ide | IDE login password; empty → generated, shown in logs |
| `AUTH` | ide | `password` \| `none` |
| `PORT` / `BIND` | compose | code-server port and host bind address |
| `IDE_HOME` | compose | host path to the IDE home directory (default `./ide-home`) |
| `TZ` | ide | timezone (`Europe/Moscow`, …) |
| `LOCALE` / `LANG` | ide | locale generation / env passthrough (`ru_RU.UTF-8`) |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | ide | `git config --global` on startup |
| `WORKSPACE` | ide | starting project folder |
| `CS_ARGS` | ide | extra code-server flags (e.g. `--cert`) |
| `IDE_EXTENSIONS` | ide | extensions to install on first start, comma-separated |
| `SDK_PKGS` | ide | SDKMAN toolchains: `java:21.0.5-tem,maven:3.9.9` (version optional) |
| `CLAUDE_MARKETPLACES` | ide | Claude Code plugin marketplaces: `owner/repo` (or a full URL), comma-separated |
| `CLAUDE_PLUGINS` | ide | Claude Code plugins: `name@marketplace`, comma-separated (marketplace part = the short name from `claude plugin marketplace list`) |
| `EXTRA_APT_PACKAGES` | ide | apt packages on startup: `postgresql-client redis-tools` |
| `CLAUDE_EXTENSION_AUTOUPDATE` | ide | `1` (default) = on startup: `claude update` (CLI always from npm, published instantly) + extension updated to the newest version available on the gallery |
| `CLAUDE_EXTENSION_REFRESH` | ide | `1` = always reinstall the extension, skip version comparison |
| `PROXY_MODE` / `PROXY_URL` | vpn | see tunnel modes table |
| `T2S_LOGLEVEL` | vpn | tun2socks log: `debug`\|`info`\|`warn`\|`error`\|`silent` |
| `NET_HOOK` | vpn | executable script run after the network is up (put it in `wireguard/hooks/`) |
| `DNS1` / `DNS2` | compose | DNS resolvers (queries go through the tunnel) |
| `BROWSER_PORT` / `BROWSER_BIND` | compose | noVNC host port/address |
| `VNC_PASSWORD` | browser | noVNC password (required with `BROWSER_BIND=0.0.0.0`) |
| `BROWSER_START_URL` / `BROWSER_RESOLUTION` | browser | start page / display resolution |

## Repository layout

```
├── vpn/          # sidecar: owns the netns (wireguard/tun2socks, fail-closed)
├── ide/          # code-server + Claude Code (zero knowledge of the proxy)
├── browser/      # in-container Chromium (noVNC), starts with the stack
├── wireguard/    # your *.conf go here (never commit!) + hooks/
├── docker-compose.yml
└── .env.example
```

## Persistence & security

- `IDE_HOME` — the container's whole `/root` on the host: IDE settings,
  extensions, `~/.claude`, `~/.claude.json`, ssh keys, git config.
- `wireguard/*.conf` contains private keys — never committed (see `.gitignore`).
- noVNC listens on `127.0.0.1` by default; set `VNC_PASSWORD` when using
  `BROWSER_BIND=0.0.0.0`.
- `--dangerously-skip-permissions` is rejected by the CLI under root — use auto mode instead.

## Troubleshooting

- **No DNS in proxy mode** → the SOCKS5 server lacks UDP support: set a LAN resolver (`DNS1=192.168.1.1`).
- **"Could not resolve host" in direct mode** → by design: no tunnel = no network.
- **400 on the Claude sign-in screen** → stale extension version. The entrypoint waits for the tunnel before installing, but if an old one slipped in: set `CLAUDE_EXTENSION_REFRESH=1` in `.env` → `docker compose up -d` — a fresh .vsix will be downloaded from the MS Marketplace through the tunnel. Manual fix: `claude update`, then `code-server --uninstall-extension anthropic.claude-code` and run `claude` (the CLI will install a compatible version itself).
- **Region**: traffic exits from your tunnel's IP — make sure the country/IP is supported by Anthropic.
- **Cyrillic garbled logs on Windows** → run `chcp 65001` first.

## License

MIT
