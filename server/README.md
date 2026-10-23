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

It is a small Dart program that keeps everything (servers, rules, portals, tokens, OAuth grants, the audit log) in **PostgreSQL**. The MCP Manager app (Portals page) is its control panel, but everything it does is also a plain HTTP API.

## Run it

```bash
cd server
dart pub get
DATABASE_URL='postgresql://user:pass@localhost:5432/mcp?sslmode=disable' dart run bin/mcp_portal.dart
```

The database must exist; the server creates its tables itself (SQL files in [`../migrations`](../migrations), applied once each at start-up).

On the first start it prints an **admin token** once. Copy it: the gateway keeps only a fingerprint. To choose your own instead, set `PORTAL_ADMIN_TOKEN` (at least 16 characters).

With Docker (from this folder):

```bash
docker compose up -d --build
docker compose logs portal      # the admin token is printed on the first start
```

The image is a single static program on an empty base, runs as an unprivileged user with a read-only root filesystem, and the compose file starts a Postgres next to it (data in the `db-data` volume; set `POSTGRES_PASSWORD`).

### Settings

| Variable | Default | |
|---|---|---|
| `PORTAL_HOST` | `127.0.0.1` | Interface to listen on. The Docker image uses `0.0.0.0` and publishes the port on loopback. |
| `PORTAL_PORT` | `8787` | |
| `DATABASE_URL` | required | `postgresql://user:pass@host:5432/db`; add `?sslmode=disable` for a database without TLS. Back it up. |
| `PORTAL_MIGRATIONS_DIR` | auto | Where the SQL migrations are; found by itself when run from the repository. |
| `PORTAL_ADMIN_TOKEN` | generated | Manages the gateway and signs web connectors in. |
| `PORTAL_PUBLIC_URL` | from the request | The address clients use, for example `https://mcp.example.com`. Set it when running behind a proxy. |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | none | A GitHub OAuth app. Turns on "Sign in with GitHub" (see below). |
| `DASHBOARD_GITHUB_ORGS` | none | Comma-separated organisations whose members may sign in. |
| `DASHBOARD_GITHUB_USERS` | none | Comma-separated GitHub logins that may sign in without belonging to those organisations. |
| `PORTAL_SESSION_DAYS` | `7` | How long a sign-in lasts. |
| `PORTAL_HEALTH_SECONDS` | `60` | How often upstream servers are checked (`0` turns it off). |
| `GITHUB_URL`, `GITHUB_API_URL` | github.com | Only for GitHub Enterprise Server. |
| `PORTAL_ALLOWED_ORIGINS` | none | Comma-separated browser origins allowed to call the admin API, besides `localhost`. Add the address the app is served from. |

### Sign in with GitHub

1. On GitHub, create an **OAuth app** (Settings → Developer settings → OAuth Apps; for an organisation, the organisation's own settings). Set the *Authorization callback URL* to `<PORTAL_PUBLIC_URL>/auth/github/callback`, for example `https://mcp.example.com/auth/github/callback`.
2. Give the server the client id and secret, and say who may in:

   ```bash
   GITHUB_CLIENT_ID=… GITHUB_CLIENT_SECRET=… DASHBOARD_GITHUB_ORGS=my-org
   ```
3. Members of `my-org` can now sign in. The server asks GitHub for the person's profile and organisations (`read:user read:org`), keeps neither the GitHub token nor anything beyond the login, name, avatar and organisation names, and gives the browser its own session token.

With neither `DASHBOARD_GITHUB_ORGS` nor `DASHBOARD_GITHUB_USERS` set, nobody can sign in. Organisations that restrict third-party apps must approve the OAuth app (or the person must make their membership public), or GitHub hides the membership and the sign-in is refused. The allow-list is checked on every request, so removing an organisation from it locks its members out at once; removing someone's membership on GitHub takes effect at their next sign-in (at most `PORTAL_SESSION_DAYS` later), or immediately if you delete them under `/api/members`.

The admin token keeps working next to this, for scripts and for first set-up. When a web connector (Claude, ChatGPT) asks to be connected, the consent page offers *Sign in with GitHub* as well as the admin token.

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

* **Credentials.** Upstream headers (tokens) are stored in the `server_credentials` table and are never returned by the API. They are not encrypted at rest: protect the database and its backups. Access and OAuth tokens are stored only as SHA-256 fingerprints.
* **Callers.** Every `/mcp/*` request needs a valid token or OAuth access token. A token can be limited to portals, revoked, and can expire. The admin token does not open portals, and an access token does not open the admin API.
* **The sign-in page** names the client and the portal, cannot be framed, only redirects to the address the client registered, and locks for 15 minutes after 10 wrong tokens from one address.
* **The audit log** records arguments, forwarded arguments, results and errors with secret-looking values masked. It lives in the `audit_events` table.
* **Not covered.** Every signed-in member has the same rights (no roles yet), no rate limiting of MCP calls, no server-initiated notifications or sessions (each request stands alone), and no encryption of stored credentials (upstream headers, OAuth tokens, provider keys) at rest.

## API

All admin routes need `Authorization: Bearer <admin token or session token>` and return JSON.

| Route | |
|---|---|
| `GET /health` | Liveness, no credential. |
| `GET /auth/config` | Whether GitHub sign-in is set up, no credential. |
| `GET /auth/github?return_to=` | Starts the GitHub sign-in. `return_to` is a path on the server, or an address of an allowed origin (that one gets `#session=<token>`). |
| `GET /api/me`, `POST /api/logout` | Who is calling; end this session. |
| `GET /api/members`, `DELETE /api/members/{id}` | Signed-in people; removing one ends their sessions. |
| `GET /api/events` | A Server-Sent Events stream: `audit` (a call was recorded), `changed` (what stored setting changed), `health` (a server went up or down), `oauth` (a server was signed in or out), `chat` (a conversation changed). Nothing is replayed after a reconnect. |
| `GET /api/tools?refresh=1` | The tools of every enabled server, with errors, in one call. |
| `POST /api/servers/{id}/call` | Calls a tool for the dashboard: `{tool, arguments, source: dashboard\|chat, conversationId}`. The rules apply and the call is recorded like a portal call; tools hidden from the Operator are refused for `chat`. |
| `GET /api/health`, `POST /api/health/check` | Which servers are up, how many tools, and why not. The gateway also checks every `PORTAL_HEALTH_SECONDS`. |
| `GET/DELETE /api/servers/{id}/oauth`, `POST /api/servers/{id}/oauth/start` | The gateway signing in to an upstream that uses OAuth: status (never a token), sign out (`?forget=1` also drops the registration), and the address to open in a browser. The browser returns to `/oauth/upstream/callback`. |
| `GET /api/chats`, `GET/PUT/DELETE /api/chats/{id}` | Operator conversations, private to the person who owns them. `PUT` creates or updates (`title`, `autoApprove`, and `items` with `history`, up to 16 MB). |
| `GET/POST /api/llm/providers`, `GET/PUT/DELETE /api/llm/providers/{id}` | Language-model providers (`name`, `kind`, `baseUrl`, `models`, `contextLength`, `apiKey`). The key is never returned, only `hasKey`. |
| `GET/POST /api/llm/providers/{id}/proxy/{path}` | Forwards to the provider below its address, adds its key, and streams the answer back. Stopping the request stops it at the provider on its next chunk. |
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
