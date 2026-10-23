# Dashboard / server split

The Flutter app becomes a **dashboard**. The Dart **server** becomes the system
of record, with **PostgreSQL** as its only storage.

```
 Flutter dashboard ── GitHub login, REST + live event stream ──▶ Portal server ──▶ PostgreSQL
                                                                     ▲   │
                                          MCP clients (Claude, …) ───┘   └──▶ upstream MCP servers
```

## Who does what

| Concern | Owner |
|---|---|
| Sign-in (GitHub OAuth, org/user allow-list) | Server |
| Every write, every MCP call, upstream OAuth and credentials | Server |
| Live updates (new audit rows, server status) | Server → dashboard over Server-Sent Events |
| Storage | PostgreSQL (the server is the only client) |
| Rendering and local preferences (theme, server address) | Dashboard |

The dashboard never talks to an upstream MCP server again: the test bench, Chat
and health checks all go through the server, so every call lands in the audit
log whoever made it (`source`: `portal`, `dashboard`, `chat`). Upstream
credentials never leave the server.

## Data

`members`, `servers`, `server_credentials`, `tool_rules`, `tool_overrides`,
`portals`, `access_tokens`, `oauth_clients`, `oauth_grants`, `audit_events`,
`settings`, `sessions`, `server_oauth`, `chats`, `chat_content`, `llm_providers`
and `llm_provider_secrets`.

Migrations are plain SQL in `migrations/`, applied by the server on start
(under an advisory lock, each in a transaction, recorded in
`schema_migrations`).

## Persistence

The server keeps its in-memory model, so the gateway logic is unchanged, and
writes every `StateStore.update` through to Postgres: only the rows that
differ from what is stored, in one transaction. Audit events are inserted as
they happen. Secrets sit in their own tables (`server_credentials`,
`access_tokens`, `oauth_*`) and are never returned by an API. One server
instance is the writer.

## Access

1. The dashboard sends the user to the server's `/auth/github`; GitHub returns
   to the server, which exchanges the code, reads the login and organisations,
   and checks them against `DASHBOARD_GITHUB_ORGS` / `DASHBOARD_GITHUB_USERS`.
2. Allowed users become rows in `members` and get a session token for the
   dashboard. Real user accounts later are more rows in `members` with a role.
3. Portal OAuth consent (for MCP clients) uses the same sign-in instead of
   pasting the admin token.
4. The admin token stays as a bootstrap / headless credential.

## Steps

1. **Done** — Postgres data layer: migrations, write-through state, audit table, tests against a real Postgres.
2. **Done** — GitHub login, sessions, `members`, OAuth consent through login.
3. **Done** — Server API for the dashboard: tool catalogue and calls (audited by source), upstream OAuth held server-side, health monitor, chats, LLM providers with a streaming proxy, and the event stream.
4. Dashboard rewrite onto that API.
5. Remove the local-only engine code from the app.
