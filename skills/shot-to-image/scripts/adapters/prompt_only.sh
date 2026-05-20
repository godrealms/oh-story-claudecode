#!/usr/bin/env bash
# adapters/prompt_only.sh — 不调 API,只导出提示词到 .txt/.json

set -euo pipefail

SHOT_ID=""
OUT_DIR=""
REFER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shot-id) SHOT_ID="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --refer) REFER="$2"; shift 2 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 2 ;;
  esac
done

[[ -z "$SHOT_ID" ]] && { echo "ERROR: --shot-id required" >&2; exit 2; }
[[ -z "$OUT_DIR" ]] && { echo "ERROR: --out-dir required" >&2; exit 2; }

# stdin 读 prompt JSON
PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect')

# 输出目录变更:写到 提示词/ 而不是 镜头图/
# OUT_DIR 是 镜头图/,平级的 提示词/ 是它的兄弟目录
PROMPT_DIR=$(dirname "$OUT_DIR")/提示词
mkdir -p "$PROMPT_DIR"

# MJ 风格:单行 + 参数
MJ_ARGS="--ar $ASPECT --v 6 --style raw"
if [[ -n "$REFER" && -f "$REFER" ]]; then
  MJ_ARGS="$MJ_ARGS --cref file://$REFER --cw 80"
fi
echo "$PROMPT_EN $MJ_ARGS" > "$PROMPT_DIR/$SHOT_ID.mj.txt"

# SD/Comfy 风格:JSON
cat > "$PROMPT_DIR/$SHOT_ID.sd.json" <<EOF
{
  "prompt": $(echo "$PROMPT_EN" | jq -Rs .),
  "negative_prompt": $(echo "$PROMPT_JSON" | jq '.negative'),
  "aspect_ratio": $(echo "$ASPECT" | jq -Rs .),
  "seed": $(echo "$PROMPT_JSON" | jq '.seed'),
  "refer_image": $(echo "${REFER:-}" | jq -Rs .)
}
EOF

# 同时在 OUT_DIR 写一个空 placeholder + .json,标记"提示词已导出但没有真图"
mkdir -p "$OUT_DIR"
cat > "$OUT_DIR/$SHOT_ID.json" <<EOF
{
  "shot_id": "$SHOT_ID",
  "backend": "prompt-only",
  "status": "prompt_exported_no_image",
  "prompt_files": [
    "$PROMPT_DIR/$SHOT_ID.mj.txt",
    "$PROMPT_DIR/$SHOT_ID.sd.json"
  ],
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "OK $SHOT_ID (prompt-only, see $PROMPT_DIR/$SHOT_ID.*)" >&2
exit 0
