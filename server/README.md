# MCP portal gateway

The gateway turns the MCP servers you already use into **portals**: one authenticated MCP endpoint per portal (`https://your-host/mcp/<name>`) that Claude, ChatGPT, Claude Code or any other MCP client can connect to. A portal publishes a chosen set of servers, reshapes their tools with the same rules the app uses, checks who is calling, and records every call.

```
Claude / ChatGPT / any MCP client
        │  Authorization: Bearer … (or OAuth sign-in)
        ▼
  /mcp/<portal>        ← one endpoint per portal
        │  tools from the portal's servers, after rules
        ▼
  upstream MCP servers  (Streamable HTTP or legacy SSE)
```

It is a small Dart program with no database: its state is one JSON file and an audit log in the data directory. The MCP Manager app (Portals page) is its control panel, but everything it does is also a plain HTTP API.

## Run it

```bash
cd server
dart pub get
dart run bin/mcp_portal.dart
```

On the first start it prints an **admin token** once. Copy it: the gateway keeps only a fingerprint. To choose your own instead, set `PORTAL_ADMIN_TOKEN` (at least 16 characters).

With Docker (from this folder):

```bash
docker compose up -d --build
docker compose logs portal      # the admin token is printed on the first start
```

The image is a single static program on an empty base, runs as an unprivileged user with a read-only root filesystem, and keeps its state in the `portal-data` volume.

### Settings

| Variable | Default | |
|---|---|---|
| `PORTAL_HOST` | `127.0.0.1` | Interface to listen on. The Docker image uses `0.0.0.0` and publishes the port on loopback. |
| `PORTAL_PORT` | `8787` | |
| `PORTAL_DATA_DIR` | `data` | Holds `state.json` (mode 600) and `audit.jsonl`. Back this up. |
| `PORTAL_ADMIN_TOKEN` | generated | Manages the gateway and signs web connectors in. |
| `PORTAL_PUBLIC_URL` | from the request | The address clients use, for example `https://mcp.example.com`. Set it when running behind a proxy. |
| `PORTAL_ALLOWED_ORIGINS` | none | Comma-separated browser origins allowed to call the admin API, besides `localhost`. Add the address the app is served from. |

### Put HTTPS in front of it

The gateway speaks plain HTTP. Anything beyond your own machine needs TLS, or the admin token and every client token travel in the clear: use a reverse proxy (Caddy, nginx), a Cloudflare Tunnel or Tailscale Funnel, pointing at `127.0.0.1:8787`, and set `PORTAL_PUBLIC_URL` to the public address. A proxy must pass `Authorization` and not buffer responses.

## Using it

1. **Connect the app.** Open **Portals** in MCP Manager, enter the gateway address and the admin token.
2. **Put servers on the gateway.** *Servers → Put on gateway* sends a server (address and headers) under the same id it has in the app, so tool rules written there apply here. Servers that use OAuth sign-in through the browser cannot be used by a gateway; give them a token instead.
3. **Create a portal.** Choose a name, an address (`/mcp/<address>`) and the servers it publishes. *Tools* shows what clients will see and lets you leave tools out of this portal.
4. **Let a client in.**
   * **Claude, ChatGPT and other web connectors** add a custom connector with the portal address. The client registers itself, opens the gateway's sign-in page, and you enter the admin token there. Tokens last an hour and refresh by themselves.
   * **Claude Code, scripts, MCP Inspector** use an access token from *Access*: `claude mcp add --transport http dev https://mcp.example.com/mcp/dev --header "Authorization: Bearer mcp_…"`. A token can be limited to some portals and can expire. Its secret is shown once.
5. **Watch it.** *Activity* lists each call with who made it, the arguments the client sent, what was forwarded to the server, and the result.

### Tool names and rules

Tools appear as `<server prefix>__<tool>` (the prefix is the server's slug, which you can change). The rules and per-tool settings sent from the app (*Servers → Tool rules → Send to gateway*) apply to every portal: extra arguments the client must fill in, values kept only in the audit log, fixed values injected on the server's behalf, added instructions, and hidden tools. Calls missing a required rule argument are refused before they reach the server and are recorded.

## What it protects, and what it does not

* **Credentials.** Upstream headers (tokens) are stored in `state.json`, readable only by its owner, and are never returned by the API. They are not encrypted at rest: protect the data directory and its backups. Access and OAuth tokens are stored only as SHA-256 fingerprints.
* **Callers.** Every `/mcp/*` request needs a valid token or OAuth access token. A token can be limited to portals, revoked, and can expire. The admin token does not open portals, and an access token does not open the admin API.
* **The sign-in page** names the client and the portal, cannot be framed, only redirects to the address the client registered, and locks for 15 minutes after 10 wrong tokens from one address.
* **The audit log** records arguments, forwarded arguments, results and errors with secret-looking values masked. It is a file that rotates at 10 MB and is also kept in memory (the latest 1000).
* **Not covered.** There is no per-user identity (one owner, one admin token), no rate limiting of MCP calls, no server-initiated notifications or sessions (each request stands alone), and no OAuth towards upstream servers.

## API

All admin routes need `Authorization: Bearer <admin token>` and return JSON.

| Route | |
|---|---|
| `GET /health` | Liveness, no credential. |
| `GET /api/status` | Version, public address, counts. |
| `GET/POST /api/servers`, `GET/PUT/DELETE /api/servers/{id}` | Upstream servers. `PUT` creates under the id you choose. Header values are never returned, only their names. |
| `POST /api/servers/{id}/test`, `GET /api/servers/{id}/tools` | Connect and list tools. |
| `GET/POST /api/portals`, `GET/PUT/DELETE /api/portals/{id}` | Portals (`name`, `slug`, `description`, `enabled`, `servers`, `excludedTools`). |
| `GET /api/portals/{id}/tools?includeHidden=1&refresh=1` | The tools the portal exposes, with hidden and excluded ones on request. |
| `GET/POST /api/tokens`, `DELETE /api/tokens/{id}` | Access tokens; `POST` returns the secret once. |
| `GET/PUT /api/rules` | Tool rules and per-tool settings, in the app's format. |
| `GET /api/audit?limit=&portal=&status=&q=` | Recorded calls, newest first. |
| `POST /mcp/{slug}` | The MCP endpoint (JSON-RPC over Streamable HTTP). |
| `/.well-known/oauth-*`, `/oauth/register`, `/oauth/authorize`, `/oauth/token` | OAuth 2.1 with PKCE and dynamic client registration. |

## Development

```bash
dart analyze
dart test        # protocol, rules, OAuth, persistence and admin API tests
```

The gateway shares its MCP clients, models and rule engine with the app through `packages/mcp_core`. The app's own tests start this gateway in memory, so the Portals page and the app's MCP client are tested against the real thing.
