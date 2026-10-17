# MCP Manager

A control panel for [Model Context Protocol](https://modelcontextprotocol.io) servers, written in Flutter for the Hacktober Portimão festival. Connect MCP servers, inspect and test their tools, audit every call, and operate it all through a local LLM — **Gemma 4 via Ollama**, or any OpenAI-compatible endpoint.

This is a ground-up rewrite of the earlier Node/Next.js version (kept locally in `.old/`, not tracked).

## What it does

| Page | |
|---|---|
| **Overview** | Servers online, tools, 24 h call volume per hour, error rate, latency (avg / p95), busiest tools, model reachability check. |
| **Servers** | Add/edit/remove MCP servers (Streamable HTTP, JSON or SSE replies), bearer token and custom headers, live status, protocol and latency, reconnect. |
| **Tools** | Browse and search every discovered tool, read its schema, edit a generated argument template and run it from a test bench. |
| **Operator** | Chat with the model. It can answer questions about your servers and audit log and call your MCP tools. Streams text and reasoning, shows each tool call as a card. |
| **Audit** | Every tool call and connection, filterable, with redacted arguments/results, actor and approval mode. Copy as JSON. |
| **Settings** | Model providers (Ollama, OpenAI-compatible), per-provider enabled models, discovery, custom model names. |

### Safety model

- A tool only runs **without asking** if its server marks it `readOnlyHint: true`. Everything else — including tools with no annotations — shows a card and waits for **Approve**, **Always allow this tool** (this conversation only) or **Deny**. Denied calls never reach the server and are recorded.
- Tool output is wrapped in `<tool_output>` and the system prompt tells the model to treat it, audit text and server descriptions as untrusted data.
- The audit log stores arguments and results **redacted** (secret-looking keys such as `apiKey`, `token`, `password`, and token-shaped strings) and size-limited. Each event records who triggered it (`user` or `operator:<model>`) and how it was authorised.
- The operator can also use built-in `mcpm_*` tools: list servers/tools, recent audit events, stats, and `mcpm_reconnect_server` (needs approval).

## Run it

```bash
cp .env.example .env        # the .env asset must exist to build
flutter pub get
flutter run -d chrome
```

### Gemma 4 through Ollama

```bash
ollama pull gemma4          # use the exact tag shown by `ollama list`
OLLAMA_ORIGINS="*" OLLAMA_HOST=0.0.0.0 ollama serve
```

`OLLAMA_ORIGINS` is required because this build runs in the browser and Ollama rejects cross-origin requests by default. Set the Ollama URL in `.env` (default for first launch) or in **Settings**. Use **Settings → Manage models** to discover installed models or type any name. The model needs the `tools` capability for the Operator to call tools; Settings warns when a model reports it doesn't.

Other endpoints: add an **OpenAI-compatible** provider (vLLM, LM Studio, llama.cpp server, OpenRouter, Ollama's `/v1`, …) with its `/v1` base URL and optional API key.

### Connecting MCP servers

Servers must speak **Streamable HTTP**. Because the app runs in a browser, each server must also allow CORS for the app's origin, accept the `Authorization`, `Mcp-Session-Id` and `MCP-Protocol-Version` request headers, and expose `Mcp-Session-Id` in `Access-Control-Expose-Headers`. A network error is reported with that hint, since a browser can't tell "refused" from "blocked by CORS".

## Project layout

```
lib/
  main.dart                  app bootstrap (env, prefs, providers)
  engine/                    no Flutter UI — all logic, unit-tested
    core/                    json, redaction, url normalising, env, prefs
    mcp/                     Streamable HTTP client, server hub, schema → argument template
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
- Legacy HTTP+SSE MCP transport is not implemented (Streamable HTTP only).
- Not ported from the Node version: portals (published gateway endpoints), policies and tool overrides, investigations, mind map, OAuth login, Postgres/pgvector, OpenTelemetry.
- Server tokens and provider API keys are kept in the browser's local storage, and the `.env` asset is downloadable by anyone who can load the app — don't put secrets there, and don't expose a deployed build that holds real credentials.
- The audit log is capped at 500 events and lives only in this browser.
