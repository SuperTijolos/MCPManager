# MCP Manager server

This is the server behind the MCP Manager dashboard: it holds everything in PostgreSQL, connects to your MCP servers on the dashboard's behalf, and turns them into **portals**: one authenticated MCP endpoint per portal (`https://your-host/mcp/<name>`) that Claude, ChatGPT, Claude Code or any other MCP client can connect to. A portal publishes a chosen set of servers, reshapes their tools with the same rules the dashboard edits, checks who is calling, and records every call (portal clients, the dashboard's test bench and its chat alike).

```
Claude / ChatGPT / any MCP client
        │  Authorization: Bearer … (or OAuth sign-in)
        ▼
  /mcp/<portal>        ← one endpoint per portal
        │  tools from the portal's servers, after rules
        ▼
  upstream MCP servers  (Streamable HTTP or legacy SSE)
```

It is a small Dart program that keeps everything (servers, rules, portals, tokens, OAuth grants, the audit log) in **PostgreSQL**. The dashboard is a thin client of its HTTP API (and its live event stream), which is also open to scripts.

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

### Signing in: GitHub and Google

People sign in with one or more providers. Set them up in the dashboard under **Settings → Sign-in**: paste the OAuth client id and secret, say who is let in, and the button appears on the sign-in page and on the page web connectors (Claude, ChatGPT) send you to. The client secret is stored on the server and is never sent back to the dashboard.

1. **Register the server as an OAuth app** with the provider, with the callback URL the dialog shows, `<PORTAL_PUBLIC_URL>/auth/<id>/callback`:
   * **GitHub:** Settings → Developer settings → OAuth Apps (or the organisation's own settings). Callback `https://mcp.example.com/auth/github/callback`.
   * **Google:** Google Cloud console → APIs & Services → Credentials → OAuth client ID, type *Web application*; add the callback as an authorised redirect URI.
2. **Add it under Settings → Sign-in** and choose who is let in. Anyone who matches *any* entry gets in:
   * **GitHub logins** and **GitHub organisations** (GitHub only);
   * **Email domains** (`example.com`) and **email addresses** (both providers). Only addresses the provider has *verified* count: GitHub's verified emails, Google's `email_verified`.
3. With nothing on the list nobody can sign in through that provider. A provider can be turned off with its switch; that signs its members out at once.

The server asks for the profile and, on GitHub, organisations and verified emails (`read:user read:org user:email`); on Google, `openid email profile`. It keeps neither provider's token, only the login, name, avatar, organisation names and verified emails, and gives the browser its own session token. Organisations that restrict third-party apps must approve the OAuth app (or the person must make their membership public), or GitHub hides the membership and the sign-in is refused.

The list is checked on every request, so removing an entry or turning a provider off locks people out at once. Removing someone from GitHub takes effect at their next sign-in (at most `PORTAL_SESSION_DAYS` later), or immediately if you delete them under `/api/members`.

**From the environment.** `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `DASHBOARD_GITHUB_ORGS` and `DASHBOARD_GITHUB_USERS` still work and appear as a read-only *GitHub* provider (marked "Set by the server"); that is the way to have sign-in from the first start, before anyone can open Settings.

The admin token keeps working next to this, for scripts and for first set-up. When a web connector (Claude, ChatGPT) asks to be connected, the consent page offers a *Sign in with …* button for each provider as well as the admin token.

### Put HTTPS in front of it

The gateway speaks plain HTTP. Anything beyond your own machine needs TLS, or the admin token and every client token travel in the clear: use a reverse proxy (Caddy, nginx), a Cloudflare Tunnel or Tailscale Funnel, pointing at `127.0.0.1:8787`, and set `PORTAL_PUBLIC_URL` to the public address. A proxy must pass `Authorization` and not buffer responses.

## Using it

1. **Sign in.** Open the dashboard and sign in with GitHub or Google (see above), or with the admin token.
2. **Add servers.** On *MCP Servers*, add each MCP server once: the address and any token or OAuth sign-in. Servers that use OAuth are signed in by this server, once, for everyone and every portal.
3. **Create a portal.** On *MCP Portals*, choose a name, an address (`/mcp/<address>`) and the servers it publishes. *Tools* shows what clients will see and lets you leave tools out of this portal.
4. **Let a client in.**
   * **Claude, ChatGPT and other web connectors** add a custom connector with the portal address. The client registers itself and opens this server's sign-in page, where you sign in (or enter the admin token). Tokens last an hour and refresh by themselves.
   * **Claude Code, scripts, MCP Inspector** use an access token from *Access*: `claude mcp add --transport http dev https://mcp.example.com/mcp/dev --header "Authorization: Bearer mcp_…"`. A token can be limited to some portals and can expire. Its secret is shown once.
5. **Watch it.** The dashboard's *Audit* page lists each call with who made it, the arguments the client sent, what was forwarded to the server, and the result; calls through a portal are marked as such.

### Tool names and rules

Tools appear as `<server prefix>__<tool>` (the prefix is the server's slug, which you can change). The rules and per-tool settings edited on the dashboard's *MCP Tools* page apply to every portal and to the dashboard's own calls: extra arguments the client must fill in, values kept only in the audit log, fixed values injected on the server's behalf, added instructions, and hidden tools. Calls missing a required rule argument are refused before they reach the server and are recorded.

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
| `GET /auth/config` | The sign-in providers that are on (`providers: [{id, kind, name}]`), no credential. |
| `GET /auth/<id>?return_to=` | Starts the sign-in through provider `<id>` (`github`, `google`, …); the provider returns to `/auth/<id>/callback`. `return_to` is a path on the server, or an address of an allowed origin (that one gets `#session=<token>`). |
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
| `GET/POST /api/auth/providers`, `GET/PUT/DELETE /api/auth/providers/{id}` | Sign-in providers: `kind` (`github`/`google`), `name`, `clientId`, `clientSecret` (write-only: omitted keeps it, empty clears it), `enabled`, `orgs`, `users`, `domains`, `emails`. The environment's GitHub app is listed read-only. |
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

The gateway shares its MCP clients, models and rule engine with the app through `packages/mcp_core`. The dashboard's tests start this server in memory, so the dashboard is tested against the real thing.
