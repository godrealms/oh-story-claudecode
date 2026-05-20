#!/usr/bin/env bash
# route.sh — 入口:按 IMG_BACKEND 优先级 dispatch 到具体 adapter

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"

# 解析命令行参数(直接透传给 adapter)
ARGS=("$@")

# 决定 backend
BACKEND="${IMG_BACKEND:-}"

if [[ -z "$BACKEND" ]]; then
  # 自动探测
  if [[ -n "${GPT_IMAGE_API_KEY:-}" ]]; then
    BACKEND="gpt-image"
  elif [[ -n "${MJ_API_KEY:-}" && -n "${MJ_BASE_URL:-}" ]]; then
    BACKEND="mj"
  elif [[ -n "${FAL_KEY:-}" ]]; then
    BACKEND="fal"
  elif [[ -n "${REPLICATE_API_TOKEN:-}" ]]; then
    BACKEND="replicate"
  elif curl -s --max-time 2 "http://${COMFY_HOST:-127.0.0.1:8188}/system_stats" 2>/dev/null \
       | jq -e 'has("system") or has("devices")' >/dev/null 2>&1; then
    BACKEND="comfy"
  else
    BACKEND="prompt-only"
  fi
fi

ADAPTER="$ADAPTERS_DIR/${BACKEND//-/_}.sh"

if [[ ! -f "$ADAPTER" ]]; then
  echo "ERROR: adapter for backend '$BACKEND' not found at $ADAPTER" >&2
  exit 1
fi

if [[ ! -x "$ADAPTER" ]]; then
  echo "ERROR: adapter not executable: $ADAPTER (run chmod +x)" >&2
  exit 1
fi

echo "[route] dispatching to backend=$BACKEND" >&2

# 把 stdin pipe 给 adapter
exec "$ADAPTER" "${ARGS[@]}"
