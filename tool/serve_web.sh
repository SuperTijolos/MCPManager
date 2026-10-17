#!/usr/bin/env bash
# Serve MCP Manager to other machines (e.g. over Tailscale) as a release build.
#
# Don't share a debug build: it waits for a debug-service websocket at
# ws://0.0.0.0:<port>, which a remote browser cannot reach, so the page never
# finishes loading. Use `flutter run -d chrome` for local debugging only.
#
# Usage: tool/serve_web.sh [port]      (default 8080)
set -euo pipefail
cd "$(dirname "$0")/.."
exec flutter run -d web-server --release --web-hostname=0.0.0.0 --web-port="${1:-8080}"
