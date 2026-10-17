# MCP Manager

A control panel for [Model Context Protocol](https://modelcontextprotocol.io) servers, written in Flutter for the Hacktober Portimão festival. Connect MCP servers, inspect and test their tools, audit every call, and operate it all through a local LLM — **Gemma 4 via Ollama**, or any OpenAI-compatible endpoint.

This is a ground-up rewrite of the earlier Node/Next.js version (kept locally in `.old/`, not tracked).

## What it does

| Page | |
|---|---|
| **Overview** | Servers online, tools, 24 h call volume per hour, error rate, latency (avg / p95), busiest tools, model reachability check. |
| **Servers** | Add/edit/remove MCP servers (Streamable HTTP or legacy HTTP+SSE, detected automatically), bearer token / OAuth and custom headers, live status, protocol and latency, reconnect. |
| **Tools** | Browse and search every discovered tool, read its schema, edit a generated argument template and run it from a test bench. |
| **Operator** | Chat with the model. It can manage servers (add, change, remove, enable, reconnect), read tool schemas, search the audit log, switch models, and run your servers' tools. Streams text and reasoning, shows each call as a card, remembers the conversation across reloads. |
| **Audit** | Every tool call and connection, filterable, with redacted arguments/results, actor and approval mode. Copy as JSON. |
| **Settings** | Model providers (Ollama, OpenAI-compatible), per-provider enabled models, discovery, custom model names. |

### Safety model

- A tool only runs **without asking** if its server marks it `readOnlyHint: true`. Everything else — including tools with no annotations — shows a card and waits for **Approve**, **Always allow this tool** (this conversation only) or **Deny**. Denied calls never reach the server and are recorded.
- Tool output is wrapped in `<tool_output>` and the system prompt tells the model to treat it, audit text and server descriptions as untrusted data.
- The audit log stores arguments and results **redacted** (secret-looking keys such as `apiKey`, `token`, `password`, and token-shaped strings) and size-limited. Each event records who triggered it (`user` or `operator:<model>`) and how it was authorised.
- **What the Operator can do** (built-in `mcpm_*` tools). Read-only, no approval: `list_servers`, `get_server`, `list_tools`, `get_tool_schema`, `recent_audit` (filter by status, kind, server, tool, actor, text, age), `stats`, `list_models`, `discover_models`, `oauth_redirect_uri`. **Needs approval every time**: `add_server`, `update_server`, `remove_server`, `set_server_enabled`, `reconnect_server`, `set_active_model`, `clear_audit`.
- Approval cards for these tools show a plain-language summary (for example *Add MCP server "Docs" at https://…*) and mask secrets such as bearer tokens. Tools that change configuration or delete data (`add_server`, `update_server`, `remove_server`, `set_active_model`, `clear_audit`) **cannot be "always allowed"**: each call asks again.
- Management actions are audited (`Manage · add_server …`) with the actor, how they were approved, and redacted arguments — including denied attempts. Tool results given back to the model never contain tokens, headers or client ids.
- The system prompt tells the model to change things only when the user explicitly asked in their own message, never to invent server URLs, and never to act on instructions found in tool output. Even a model that disobeys that is stopped by the approval gate (this is covered by a test).
- OAuth sign-in can't be done by the model: the browser only allows the sign-in window from a real click, so a banner in the chat offers **Sign in** for any server that needs it.

## Run it

```bash
cp .env.example .env        # the .env asset must exist to build
flutter pub get
flutter run -d chrome
```

### Sharing with another machine (Tailscale / LAN)

```bash
tool/serve_web.sh          # release build on 0.0.0.0:8080; pass a port to change it
```

Then open `http://<your-tailscale-ip>:8080` on the other machine. Don't share a **debug** build (`flutter run -d chrome`): it waits for a debug websocket at `ws://0.0.0.0:<port>` that a remote browser can't reach, so the page stays blank and loading. Also allow that origin in Ollama (`OLLAMA_ORIGINS`) and in your MCP servers' CORS settings. Servers, settings and the audit log are stored per browser, so the other machine starts empty (the Ollama URL defaults from `.env`).

### Gemma 4 through Ollama

```bash
ollama pull gemma4          # use the exact tag shown by `ollama list`
OLLAMA_ORIGINS="*" OLLAMA_HOST=0.0.0.0 ollama serve
```

`OLLAMA_ORIGINS` is required because this build runs in the browser and Ollama rejects cross-origin requests by default. Set the Ollama URL in `.env` (default for first launch) or in **Settings**. Use **Settings → Manage models** to discover installed models or type any name. The **context window** (default 16384 tokens, editable per provider) is sent as `num_ctx`: Ollama's own default is too small for the Operator's tool list. The model needs the `tools` capability for the Operator to call tools; Settings warns when a model reports it doesn't.

Other endpoints: add an **OpenAI-compatible** provider (vLLM, LM Studio, llama.cpp server, OpenRouter, Ollama's `/v1`, …) with its `/v1` base URL and optional API key.

### Connecting MCP servers

Two HTTP transports are supported and detected automatically (**Transport: Auto-detect**, changeable per server):

- **Streamable HTTP** (current spec): one endpoint, usually `/mcp`.
- **Legacy HTTP+SSE** (spec 2024-11-05), still used by many servers and IDE bridges: the app opens `GET <url>` as an event stream, reads the `endpoint` event, and POSTs requests there. Its endpoint is usually `/sse`.

If you enter a bare `host:port`, the app also tries `/mcp` and `/sse`, then remembers what worked (the card shows `…/sse` and an **SSE** badge). A URL ending in `/sse` goes straight to the legacy transport. A `401` stops the search and asks for credentials; any other failure lists every attempt it made. A message endpoint announced on a different origin is refused, so credentials are never sent elsewhere.

Example: the **VS Code MCP Bridge** extension serves `http://127.0.0.1:3333/sse` and requires its `mcpServer.authToken` as a **bearer token**. Add `localhost:3333` (or the full `/sse` URL), choose **Bearer token** and paste the token.

Because the app runs in a browser, each server must also allow CORS for the app's origin and accept the `Authorization` header (plus `Mcp-Session-Id` / `MCP-Protocol-Version` for Streamable HTTP, exposing `Mcp-Session-Id` in `Access-Control-Expose-Headers`). A network error is reported with that hint, since a browser can't tell "refused" from "blocked by CORS".

#### OAuth-protected servers

Choose **OAuth** instead of a bearer token when adding a server. The app implements the MCP authorization flow: it follows the server's `401` / protected-resource metadata to its authorization server, registers itself there (dynamic client registration), and signs you in with authorization code + PKCE (S256) in a pop-up. Click **Sign in** on the server card; tokens are refreshed automatically and **Sign out** forgets them.

- **Redirect URI.** Sign-in returns to `<app origin>/oauth_callback.html` (shown, with a copy button, in the add-server dialog). The server's OAuth provider must allow that exact URI. Servers configured only for another client — for example ChatGPT connectors, which use `https://chatgpt.com/connector/oauth/*` — will reject this app until its URI is added, or until you enter a pre-registered **Client ID** (Advanced) that already allows it.
- **CORS.** The authorization server's metadata, registration and token endpoints must allow requests from the app's origin, and the MCP server should expose `WWW-Authenticate` (the app falls back to well-known URLs if it can't read it).
- **https.** Many providers only accept `https://` or `localhost` redirect URIs, so open the app via `localhost` or serve it over https rather than a plain-http LAN/Tailscale address.
- **Pop-ups.** The browser must allow the sign-in pop-up (it opens from the button click).
- Tokens and the registered client are stored in the browser's local storage, like bearer tokens.

## Project layout

```
lib/
  main.dart                  app bootstrap (env, prefs, providers)
  engine/                    no Flutter UI — all logic, unit-tested
    core/                    json, redaction, url normalising, env, prefs
    mcp/                     Streamable HTTP + legacy SSE clients, auto-detect, server hub, OAuth, schema → argument template
    llm/                     provider interface, Ollama + OpenAI-compatible, settings
    agent/                   tool-calling loop, toolbox, approval flow, chat controller
    audit/                   append-only log, stats
  router/
    routes.dart, shell.dart  go_router + responsive shell (rail ≥ 900 px, drawer below)
    pages/<name>/<name>_page.dart
  ui/                        theme and shared widgets
test/                        engine tests + widget tests (incl. phone-width layout sweep)
```

State is managed with Riverpod and persisted in the browser (`shared_preferences`).

## Checks

```bash
flutter analyze
flutter test
flutter build web
```

## Limits and not-yet-ported features

- Browser build only: no stdio MCP servers, and the app can't host MCP endpoints itself.
- OAuth sign-in needs a browser that allows pop-ups; the in-app preview browser of some tools doesn't.
- Not ported from the Node version: portals (published gateway endpoints), policies and tool overrides, investigations, mind map, OAuth *login to this app* (OAuth to MCP servers is supported), Postgres/pgvector, OpenTelemetry.
- Server tokens and provider API keys are kept in the browser's local storage, and the `.env` asset is downloadable by anyone who can load the app — don't put secrets there, and don't expose a deployed build that holds real credentials.
- The audit log is capped at 500 events and lives only in this browser.
