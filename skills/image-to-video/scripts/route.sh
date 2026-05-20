#!/usr/bin/env bash
# image-to-video/scripts/route.sh — 入口:按 VIDEO_BACKEND 优先级 dispatch 到具体 adapter

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"

# 解析命令行参数(直接透传给 adapter)
ARGS=("$@")

# 决定 backend
BACKEND="${VIDEO_BACKEND:-}"

if [[ -z "$BACKEND" ]]; then
  # 自动探测;Plan 3 只实现了 kling 和 prompt-only,
  # 其他后端(jimeng/runway/sora/veo)即便环境变量齐备,adapter 文件不存在也会跳过
  if [[ -n "${KLING_API_KEY:-}" && -n "${KLING_BASE_URL:-}" ]]; then
    BACKEND="kling"
  elif [[ -n "${JIMENG_API_KEY:-}" && -n "${JIMENG_BASE_URL:-}" ]] && [[ -x "$ADAPTERS_DIR/jimeng.sh" ]]; then
    BACKEND="jimeng"
  elif [[ -n "${RUNWAY_API_KEY:-}" ]] && [[ -x "$ADAPTERS_DIR/runway.sh" ]]; then
    BACKEND="runway"
  elif [[ -n "${SORA_API_KEY:-}" && -n "${SORA_BASE_URL:-}" ]] && [[ -x "$ADAPTERS_DIR/sora.sh" ]]; then
    BACKEND="sora"
  elif [[ -n "${VEO_API_KEY:-}" ]] && [[ -x "$ADAPTERS_DIR/veo.sh" ]]; then
    BACKEND="veo"
  else
    BACKEND="prompt-only"
  fi
fi

ADAPTER="$ADAPTERS_DIR/${BACKEND//-/_}.sh"

if [[ ! -f "$ADAPTER" ]]; then
  # Friendly hint for known-but-unimplemented backends
  case "$BACKEND" in
    jimeng|runway|sora|veo)
      echo "ERROR: backend '$BACKEND' is documented but not yet implemented (planned for Plan 4)." >&2
      echo "       Currently available: kling, prompt-only." >&2
      echo "       To proceed, set VIDEO_BACKEND=kling (requires KLING_API_KEY + KLING_BASE_URL) or VIDEO_BACKEND=prompt-only." >&2
      ;;
    *)
      echo "ERROR: adapter for backend '$BACKEND' not found at $ADAPTER" >&2
      ;;
  esac
  exit 1
fi

if [[ ! -x "$ADAPTER" ]]; then
  echo "ERROR: adapter not executable: $ADAPTER (run chmod +x)" >&2
  exit 1
fi

echo "[route] dispatching to backend=$BACKEND" >&2

# 把 stdin pipe 给 adapter
exec "$ADAPTER" "${ARGS[@]}"
