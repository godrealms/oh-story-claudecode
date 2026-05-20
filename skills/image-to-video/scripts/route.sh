#!/usr/bin/env bash
# image-to-video/scripts/route.sh — 入口:按 VIDEO_BACKEND 优先级 dispatch 到具体 adapter

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"

# 解析命令行参数(直接透传给 adapter)
ARGS=("$@")

# 决定 backend
BACKEND="${VIDEO_BACKEND:-}"

# 判断 adapter 是否为占位（Plan 4 之后 sora/veo 暂时占位）
# 显式 VIDEO_BACKEND=sora 仍然会走到占位脚本（适合开发者测试），
# 但自动探测时即便环境变量齐备也跳过占位，落到下一个后端
is_placeholder() {
  local adapter="$1"
  [[ -f "$adapter" ]] || return 0
  grep -q '^# adapters/.*占位' "$adapter" 2>/dev/null
}

if [[ -z "$BACKEND" ]]; then
  # 自动探测优先级：kling → jimeng → runway → sora → veo → prompt-only
  # adapter 文件不存在 / 非可执行 / 占位脚本 都会被跳过
  if [[ -n "${KLING_API_KEY:-}" && -n "${KLING_BASE_URL:-}" ]] && [[ -x "$ADAPTERS_DIR/kling.sh" ]] && ! is_placeholder "$ADAPTERS_DIR/kling.sh"; then
    BACKEND="kling"
  elif [[ -n "${JIMENG_API_KEY:-}" && -n "${JIMENG_BASE_URL:-}" ]] && [[ -x "$ADAPTERS_DIR/jimeng.sh" ]] && ! is_placeholder "$ADAPTERS_DIR/jimeng.sh"; then
    BACKEND="jimeng"
  elif [[ -n "${RUNWAY_API_KEY:-}" ]] && [[ -x "$ADAPTERS_DIR/runway.sh" ]] && ! is_placeholder "$ADAPTERS_DIR/runway.sh"; then
    BACKEND="runway"
  elif [[ -n "${SORA_API_KEY:-}" && -n "${SORA_BASE_URL:-}" ]] && [[ -x "$ADAPTERS_DIR/sora.sh" ]] && ! is_placeholder "$ADAPTERS_DIR/sora.sh"; then
    BACKEND="sora"
  elif [[ -n "${VEO_API_KEY:-}" ]] && [[ -x "$ADAPTERS_DIR/veo.sh" ]] && ! is_placeholder "$ADAPTERS_DIR/veo.sh"; then
    BACKEND="veo"
  else
    BACKEND="prompt-only"
  fi
fi

ADAPTER="$ADAPTERS_DIR/${BACKEND//-/_}.sh"

if [[ ! -f "$ADAPTER" ]]; then
  echo "ERROR: adapter for backend '$BACKEND' not found at $ADAPTER" >&2
  echo "       Available: kling, jimeng, runway, prompt-only (and sora/veo placeholders)." >&2
  exit 1
fi

if [[ ! -x "$ADAPTER" ]]; then
  echo "ERROR: adapter not executable: $ADAPTER (run chmod +x)" >&2
  exit 1
fi

echo "[route] dispatching to backend=$BACKEND" >&2

# 把 stdin pipe 给 adapter
# 注意:bash 3.2 (macOS 默认) 下 ${ARGS[@]} 在数组为空时会触发 unbound variable,
# 显式判长度后再展开,避免 set -u 导致的崩溃
if [[ ${#ARGS[@]} -gt 0 ]]; then
  exec "$ADAPTER" "${ARGS[@]}"
else
  exec "$ADAPTER"
fi
