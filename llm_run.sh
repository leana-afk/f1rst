#!/usr/bin/env bash
# llm-tunnel.sh: start llama-server locally, expose it to a VPS via reverse SSH tunnel.
# Usage: ./llm-tunnel.sh        (Ctrl+C stops everything)
# Override any setting with env vars, e.g.  VPS=me@1.2.3.4 CTX=16384 ./llm-tunnel.sh

set -euo pipefail

# ---------------- config ----------------
MODEL="${MODEL:-$HOME/.cache/llmfit/models/DeepSeek-R1-0528-Qwen3-8B-Q8_0.gguf}"
ALIAS="${ALIAS:-deepseek-r1-8b}" # model name your agent will request
CTX="${CTX:-65536}"
NGL="${NGL:-99}" # GPU layers; set 0 for CPU-only
LOCAL_PORT="${LOCAL_PORT:-7891}"

VPS="${VPS:-}"
SSH_PORT="${SSH_PORT:-}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}" # optional, e.g. ~/.ssh/id_ed25519
REMOTE_PORT="${REMOTE_PORT:-7891}"
# 127.0.0.1 = reachable only from the VPS itself (recommended).
# Use 172.17.0.1 if the agent runs in Docker (needs GatewayPorts clientspecified on the VPS).
REMOTE_BIND="${REMOTE_BIND:-127.0.0.1}"

CONF_DIR="$HOME/.config/llm-tunnel"
KEY_FILE="$CONF_DIR/api_key"
LOG_FILE="$CONF_DIR/llama-server.log"
# ----------------------------------------

mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"

if [[ ! -f "$KEY_FILE" ]]; then
  openssl rand -hex 32 >"$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo ">> Generated new API key: $KEY_FILE"
fi
API_KEY="$(cat "$KEY_FILE")"

[[ -f "$MODEL" ]] || {
  echo "Model not found: $MODEL" >&2
  exit 1
}
command -v llama-server >/dev/null || {
  echo "llama-server not in PATH" >&2
  exit 1
}

SSH_OPTS=(-p "$SSH_PORT"
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -o ExitOnForwardFailure=yes
  -o BatchMode=yes)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

LLAMA_PID=""
TAIL_PID=""
cleanup() {
  echo
  echo ">> Shutting down..."
  [[ -n "$LLAMA_PID" ]] && kill "$LLAMA_PID" 2>/dev/null || true
  [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------- 1. llama-server ----------
echo ">> Starting llama-server on 127.0.0.1:$LOCAL_PORT (log: $LOG_FILE)"
llama-server \
  -m "$MODEL" \
  --alias "$ALIAS" \
  --host 127.0.0.1 --port "$LOCAL_PORT" \
  --api-key "$API_KEY" \
  -c "$CTX" \
  --jinja \
  >"$LOG_FILE" 2>&1 &
#--temp 0.7 --top-p 0.95 \
#-ngl "$NGL" \
LLAMA_PID=$!

echo -n ">> Waiting for model to load"
for _ in $(seq 1 180); do
  if curl -sf "http://127.0.0.1:$LOCAL_PORT/health" >/dev/null 2>&1; then
    echo " ... ready."
    break
  fi
  if ! kill -0 "$LLAMA_PID" 2>/dev/null; then
    echo
    echo "llama-server exited. Last log lines:" >&2
    tail -n 20 "$LOG_FILE" >&2
    exit 1
  fi
  echo -n "."
  sleep 1
done
curl -sf "http://127.0.0.1:$LOCAL_PORT/health" >/dev/null || {
  echo "Timed out waiting for llama-server" >&2
  exit 1
}

echo ">> API key is in: $KEY_FILE"
tail -F /home/k4ndar3c/.config/llm-tunnel/llama-server.log &
TAIL_PID=$!
while kill -0 "$LLAMA_PID" 2>/dev/null; do
  sleep 5
done
echo "llama-server stopped." >&2
