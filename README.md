# MCP Manager

MCP Manager is a control panel for [Model Context Protocol](https://modelcontextprotocol.io) (MCP) servers. It lets you connect the servers you use, see which tools each one offers, try those tools by hand, and keep a full record of every call made to them. On top of that sits the **Operator**, a chat assistant backed by a local model, **Gemma 4 through Ollama**, or any OpenAI-compatible endpoint. The Operator can find the right tool for a job, run it, and manage your servers, and it asks for your approval before doing anything that is not read-only.

It is a Flutter web app built for the Hacktober Portimão festival, and a ground-up rewrite of an earlier Node/Next.js version (kept locally in `.old/`, not tracked).

- **Connect any MCP server.** Streamable HTTP and the older HTTP+SSE transport are detected automatically. Authenticate with a bearer token, OAuth (PKCE), or custom headers, and test a connection before saving it.
- **Inspect and test tools.** Read each tool's schema and run it from a test bench. Rules add shared arguments such as `reason` or `expected result` to many tools at once, and can hide or reshape what the Operator sees.
- **Audit everything.** Every tool call, connection, sign-in and management action is recorded with the actor and how it was approved. Secrets are redacted, and the log can be filtered, paginated and inspected event by event.
- **Operate with approvals.** Read-only tools run without asking. Anything else waits for your approval by default. Each chat has an **Ask first / Automatic** switch: in Automatic, its tool calls run without asking, including configuration changes.
- **A dashboard over a server.** The Flutter app is the dashboard; the Dart **server** in [`server/`](server/README.md) holds everything in PostgreSQL: servers and their credentials, OAuth sign-ins, rules, portals, the audit log, conversations and model providers (with their keys). The server connects to your MCP servers, so they need no CORS settings, and it records every call whoever made it. Several people can share one server: they sign in with **GitHub** (limited to the organisations you list), and the dashboard updates live as others change things.
- **Publish servers as portals.** The same server turns chosen servers into authenticated MCP endpoints that Claude, ChatGPT or any MCP client can use, with the same tool rules, access tokens and OAuth sign-in. See [Portals and the server](#portals-and-the-server).

**Credits.** Made in collaboration with Tomás Rodrigues, [GuikiPT](https://github.com/GuikiPT) and [AjaxR0](https://github.com/AjaxR0). Their names and GitHub profiles are also listed on the MLH team page for the project.

## What it does

| Page | |
|---|---|
| **Overview** | Servers online, tools, 24 h call volume per hour, error rate, latency (avg / p95), busiest tools, model reachability check. |
| **MCP Servers** | Add/edit/remove MCP servers (Streamable HTTP or legacy HTTP+SSE, detected automatically), bearer token / OAuth and custom headers, live status, protocol, latency and a trace of what was tried. The Edit dialog is sectioned (connection, authentication, headers, advanced) and has a **Test connection** button. |
| **MCP Tools** | Browse and search every tool, filter by read-only/may-modify/hidden status and connected server, inspect effective rules, read its schema, and run it from a test bench. The list and detail panes are separated by a draggable divider (double-click resets, ←/→ nudge). **Rules** reshape what the Operator sees (see below). |
| **Portals** | Publish chosen servers as MCP endpoints: group them into portals and create access tokens. What clients call shows on the Audit page, marked as coming through a portal. |
| **Chat** | Chat with the model. It can manage servers, find the right tool for a job, recover from failed calls, and run your servers' tools. Conversations are saved: a history panel lets you search, rename, delete and reopen older chats. |
| **Audit** | Two views: **MCP tools** (tool calls) and **Activity** (connections, sign-ins and management actions), each with its own count and filters. Filter, search and paginate (page size selectable). Open any row for a detail dialog with the redacted arguments, the forwarded values, the result, the actor and the approval mode, or copy it as JSON. |
| **Settings** | Model providers and enabled models (with presets for common endpoints; keys stay on the server), Operator limits and your own instructions, plus who is signed in, where the data lives, and clean-up. |
| **About / Contributors** | What the app does, how the pieces fit, safety and data notes, facts about this copy (the server, who is signed in, the OAuth redirect URI), and the people who built it. |

### Portals and the server

A portal is one MCP endpoint (`https://your-host/mcp/<name>`) that publishes a set of your servers to other MCP clients. The browser cannot serve an endpoint, so the **server** does: it applies your tool rules, checks the caller (an access token, or OAuth sign-in for web connectors), forwards the call and records it.

```bash
docker compose -f server/docker-compose.yml up -d --build   # Postgres + the server
docker compose -f server/docker-compose.yml logs portal      # the admin token, printed once
```

Without Docker: create a database and run `DATABASE_URL=postgresql://… dart run bin/mcp_portal.dart` in `server/`. The [server README](server/README.md) covers GitHub sign-in, HTTPS, settings and the security model; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit.

### Repository layout

| Folder | |
|---|---|
| `lib/`, `web/` | The Flutter web dashboard. |
| `packages/mcp_core/` | Flutter-free core shared by the dashboard and the server: MCP models and clients, OAuth, tool rules, redaction. |
| `server/` | The server: API, portals, GitHub sign-in, event stream. |
| `migrations/` | The SQL schema, applied by the server at start-up. |

### Tool rules

A rule adds arguments such as `reason` or `expected result` to many tools at once. Scope a rule to all tools or to chosen ones (select several in the Tools list and add the same argument in one go), optionally with conditions. Per argument you choose whether the model must fill it, whether it is sent to the server or kept for the audit log only, or whether it is a fixed value the model never sees. Rules can also append instructions or hide tools from the Operator. Rules at the top of the list win on conflicts (drag to reorder), and a diff shows each tool's original and effective schema. Calls missing a required rule argument are rejected before they reach the server and recorded.

### Operator intelligence

The Operator is given a map of your tools grouped by purpose (for example "run commands", "read files", "search") computed from names, schemas and annotations only, never from server-written text. `mcpm_find_tools` searches that map. After a failed call it gets a hint to try a related tool (for example list a directory before guessing a path) instead of asking you straight away.

### Safety model

- A tool only runs **without asking** if its server marks it `readOnlyHint: true`. Everything else — including tools with no annotations — shows a card and waits for **Approve**, **Always allow this tool** (this conversation only) or **Deny**. Denied calls never reach the server and are recorded.
- **Automatic mode** is a per-chat choice (the **Automatic** switch above the message box). In that chat every tool call runs without asking, including the configuration changes that otherwise can never be always allowed. The mode is saved with the chat, new chats start with the last choice, and each call is audited with `approval: automatic`. Use it when you trust what the Operator is doing; switch back to **Ask first** for anything that changes servers.
- Tool output is wrapped in `<tool_output>` and the system prompt tells the model to treat it, audit text and server descriptions as untrusted data.
- The audit log stores arguments and results **redacted** (secret-looking keys such as `apiKey`, `token`, `password`, and token-shaped strings) and size-limited. Each event records who triggered it (`user` or `operator:<model>`) and how it was authorised.
- **What the Operator can do** (built-in `mcpm_*` tools). Read-only, no approval: `mcpm_list_servers`, `mcpm_get_server`, `mcpm_list_tools`, `mcpm_get_tool_schema`, `mcpm_find_tools` (search the tools by purpose), `mcpm_recent_audit` (filter by status, kind, server, tool, actor, text, age), `mcpm_stats`, `mcpm_list_models`, `mcpm_discover_models`, `mcpm_oauth_redirect_uri`. **Needs approval every time** (unless the chat is Automatic): `mcpm_add_server`, `mcpm_update_server`, `mcpm_remove_server`, `mcpm_set_server_enabled`, `mcpm_reconnect_server`, `mcpm_set_active_model`, `mcpm_clear_audit`.
- Approval cards for these tools show a plain-language summary (for example *Add MCP server "Docs" at https://…*) and mask secrets such as bearer tokens. Tools that change configuration or delete data (`mcpm_add_server`, `mcpm_update_server`, `mcpm_remove_server`, `mcpm_set_active_model`, `mcpm_clear_audit`) **cannot be "always allowed"**: each call asks again, unless the chat is in Automatic mode.
- Management actions are audited (`Manage · add_server …`) with the actor, how they were approved, and redacted arguments — including denied attempts. Tool results given back to the model never contain tokens, headers or client ids.
- The system prompt tells the model to change things only when the user explicitly asked in their own message, never to invent server URLs, and never to act on instructions found in tool output. Even a model that disobeys that is stopped by the approval gate (this is covered by a test).
- OAuth sign-in can't be done by the model: the browser only allows the sign-in window from a real click, so a banner in the chat offers **Sign in** for any server that needs it.

## Run it

Start the server first (see [Portals and the server](#portals-and-the-server)); it needs a PostgreSQL database and prints an **admin token** at its first start.

```bash
cp .env.example .env        # the .env asset must exist to build
flutter pub get
flutter run -d chrome
```

The dashboard opens on a sign-in page: enter the server's address (set `PORTAL_URL` in `.env` to prefill it) and **Sign in with GitHub**, or use the admin token while GitHub is not set up. Allow the dashboard's address in the server (`PORTAL_ALLOWED_ORIGINS`, `localhost` is always allowed) and, for GitHub, set the OAuth app's callback to the *server's* `/auth/github/callback`.

### Sharing with another machine (Tailscale / LAN)

```bash
tool/serve_web.sh          # release build on 0.0.0.0:8080; pass a port to change it
```

Then open `http://<your-tailscale-ip>:8080` on the other machine and sign in to the same server: servers, rules, audit and conversations are all there already. Don't share a **debug** build (`flutter run -d chrome`): it waits for a debug websocket that a remote browser can't reach, so the page stays blank. Add the address you serve the dashboard from to the server's `PORTAL_ALLOWED_ORIGINS`.

### Gemma 4 through Ollama

```bash
ollama pull gemma4          # use the exact tag shown by `ollama list`
ollama serve
```

Add a provider in **Settings → Models** with Ollama's address *as the server sees it* (`http://localhost:11434` when they share a machine, `http://host.docker.internal:11434` from a Docker container). The dashboard talks to the model through the server, so no `OLLAMA_ORIGINS` setting is needed. Use **Manage models** to discover installed models or type any name. The **context window** (default 16384 tokens, editable per provider) is sent as `num_ctx`: Ollama's own default is too small for the Operator's tool list. The model needs the `tools` capability for the Operator to call tools; Settings warns when a model reports it doesn't.

Other endpoints: add an **OpenAI-compatible** provider (vLLM, LM Studio, llama.cpp server, OpenRouter, Ollama's `/v1`, …) with its `/v1` base URL and optional API key. Keys are stored on the server and never sent back to the dashboard.

### Connecting MCP servers

Two HTTP transports are supported and detected automatically (**Transport: Auto-detect**, changeable per server):

- **Streamable HTTP** (current spec): one endpoint, usually `/mcp`.
- **Legacy HTTP+SSE** (spec 2024-11-05), still used by many servers and IDE bridges: the server opens `GET <url>` as an event stream, reads the `endpoint` event, and POSTs requests there. Its endpoint is usually `/sse`.

If you enter a bare `host:port`, the server also tries `/mcp` and `/sse`, then remembers what worked (the card shows `…/sse` and an **SSE** badge). A URL ending in `/sse` goes straight to the legacy transport. A `401` stops the search and asks for credentials; any other failure lists every attempt it made. A message endpoint announced on a different origin is refused, so credentials are never sent elsewhere.

Servers must be reachable from the machine the **server** runs on (not from your browser), and need no CORS settings. Example: the **VS Code MCP Bridge** extension serves `http://127.0.0.1:3333/sse` and requires its `mcpServer.authToken` as a **bearer token**. Add `localhost:3333`, choose **Bearer token** and paste the token.

Header values and tokens are stored on the server and never shown again: editing a server shows that a value is stored, and leaving it empty keeps it.

#### OAuth-protected servers

Choose **OAuth** instead of a bearer token when adding a server. The server implements the MCP authorization flow: it follows the upstream's `401` / protected-resource metadata to its authorization server, registers itself there (dynamic client registration) and signs in with authorization code + PKCE (S256). Click **Sign in** on the server card; a pop-up opens the upstream's sign-in page. The tokens are kept on the server, refreshed automatically, and used for everyone (and for portal clients). **Sign out** forgets them.

- **Redirect URI.** Sign-in returns to `<server address>/oauth/upstream/callback` (shown in the add-server dialog). The upstream's OAuth provider must allow that exact URI. Servers configured only for another client — for example ChatGPT connectors, which use `https://chatgpt.com/connector/oauth/*` — will reject it until it is added, or until you enter a pre-registered **Client ID** (Advanced) that already allows it.
- **https.** Many providers only accept `https://` or `localhost` redirect URIs, so put the server behind https (or reach it as `localhost`).
- **Pop-ups.** The browser must allow the sign-in pop-up (it opens from the button click).

## Project layout

```
lib/
  main.dart                  app bootstrap (env, prefs, providers)
  engine/                    no Flutter UI — all logic, unit-tested
    core/                    json, redaction, url normalising, env, prefs
    server/                  the server client, sign-in session, live event stream
    mcp/                     the server-backed hub (servers, tools, calls, OAuth sign-in)
    llm/                     provider interface, Ollama + OpenAI-compatible (through the server's proxy), settings
    agent/                   tool-calling loop, toolbox, approval flow, chat controller and store
    audit/                   the audit log as the server recorded it, stats
    rules/, settings/        tool rules (on the server), Operator settings (this browser)
  router/
    routes.dart, shell.dart  go_router + responsive shell (rail ≥ 900 px, drawer below)
    pages/<name>/<name>_page.dart   overview, servers, tools, chat, audit, settings, info (About), contributors
  ui/                        theme and shared widgets
test/                        engine tests + widget tests (incl. phone-width layout sweep)
```

The dashboard keeps no data of its own: the notifiers in `engine/` read from the server and write through to it, and the pages only render them. State is managed with Riverpod; this browser stores only the server's address, the sign-in, and a few preferences (`shared_preferences`).

## Checks

```bash
flutter analyze && flutter test                        # the dashboard, against an in-process server
(cd server && dart analyze && dart test)               # the server (needs a Postgres, see server/README.md)
(cd packages/mcp_core && dart test)
```

The dashboard tests run the real server in memory, so they exercise the app against it; the server tests also run against a throwaway Postgres (`TEST_DATABASE_URL`, or `docker run -d -e POSTGRES_PASSWORD=test -p 127.0.0.1:54329:5432 postgres:16-alpine`).

## Limits

- Browser build only; MCP servers must be HTTP (no stdio), and the server must be able to reach them.
- OAuth sign-in to an upstream needs a browser that allows pop-ups; the in-app preview browser of some tools doesn't.
- The server stores upstream credentials, OAuth tokens and provider keys unencrypted in its database: protect the database and its backups. The `.env` asset is downloadable by anyone who can load the dashboard — don't put secrets there.
- A model provider's address is resolved by the server, so it must be reachable from there (and the server can be pointed at internal addresses by anyone who may sign in: only let in people you trust).
- Every signed-in member has the same rights (no roles yet); conversations are private to their author.
- The dashboard loads the 1000 most recent audit events; older ones stay in the database.
- Cancelling a model reply stops it at the provider on its next chunk, not instantly.
- Not ported from the Node version: policies, investigations, mind map, pgvector, OpenTelemetry.
