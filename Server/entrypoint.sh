#!/bin/sh
set -eu

uvicorn app.main:app --host 0.0.0.0 --port 8080 &
server_pid=$!

tunnel_pid=""
if [ -n "${CONTROL_PLANE_API_KEY:-}" ] && [ -n "${CONTROL_PLANE_TUNNEL_ID:-}" ]; then
  tunnel-client run \
    --control-plane.tunnel-id "$CONTROL_PLANE_TUNNEL_ID" \
    --mcp.server-url "url=http://127.0.0.1:8080/mcp,channel=main" \
    --mcp.extra-headers "Authorization: env:KIES_DRIVE_MCP_AUTHORIZATION" \
    --mcp.discovery-extra-headers "Authorization: env:KIES_DRIVE_MCP_AUTHORIZATION" \
    --mcp.startup-wait-timeout 30s \
    --health.listen-addr 0.0.0.0:18181 &
  tunnel_pid=$!
fi

shutdown() {
  kill "$server_pid" 2>/dev/null || true
  if [ -n "$tunnel_pid" ]; then
    kill "$tunnel_pid" 2>/dev/null || true
  fi
  wait || true
}

trap shutdown INT TERM

while kill -0 "$server_pid" 2>/dev/null; do
  if [ -n "$tunnel_pid" ] && ! kill -0 "$tunnel_pid" 2>/dev/null; then
    echo "Kies Drive MCP tunnel stopped unexpectedly" >&2
    shutdown
    exit 1
  fi
  sleep 2
done

shutdown
