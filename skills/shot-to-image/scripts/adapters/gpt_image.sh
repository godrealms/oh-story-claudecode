#!/usr/bin/env bash
# adapters/gpt_image.sh — GPT-Image-2 后端

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

API_KEY="${GPT_IMAGE_API_KEY:?ERROR: GPT_IMAGE_API_KEY required}"
BASE_URL="${GPT_IMAGE_BASE_URL:-https://api.openai.com/v1}"
MODEL="gpt-image-2"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect')

# 宽高比 → size
case "$ASPECT" in
  "9:16") SIZE="1024x1536" ;;
  "16:9") SIZE="1536x1024" ;;
  "1:1")  SIZE="1024x1024" ;;
  *) SIZE="1024x1536" ;;
esac

mkdir -p "$OUT_DIR"

# 调 API
RESPONSE=$(mktemp)
trap "rm -f $RESPONSE" EXIT

if [[ -n "$REFER" && -f "$REFER" ]]; then
  # 图生图(用角色卡作 refer)
  curl -s "${BASE_URL}/images/edits" \
    -H "Authorization: Bearer ${API_KEY}" \
    -F "model=${MODEL}" \
    -F "prompt=${PROMPT_EN}" \
    -F "image=@${REFER}" \
    -F "size=${SIZE}" \
    -F "response_format=b64_json" \
    > "$RESPONSE"
else
  # 文生图
  curl -s "${BASE_URL}/images/generations" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL}\",
      \"prompt\": $(echo "$PROMPT_EN" | jq -Rs .),
      \"size\": \"${SIZE}\",
      \"response_format\": \"b64_json\"
    }" > "$RESPONSE"
fi

# 检查错误
ERROR_MSG=$(jq -r '.error.message // empty' "$RESPONSE")
if [[ -n "$ERROR_MSG" ]]; then
  echo "ERROR: GPT-Image API error: $ERROR_MSG" >&2
  exit 1
fi

# 解码 base64 → PNG
B64=$(jq -r '.data[0].b64_json // empty' "$RESPONSE")
if [[ -z "$B64" ]]; then
  echo "ERROR: response missing .data[0].b64_json" >&2
  cat "$RESPONSE" >&2
  exit 1
fi
echo "$B64" | base64 --decode > "$OUT_DIR/$SHOT_ID.png"

# 写伴随 .json
cat > "$OUT_DIR/$SHOT_ID.json" <<EOF
{
  "shot_id": "$SHOT_ID",
  "backend": "gpt-image",
  "model": "${MODEL}",
  "size": "${SIZE}",
  "prompt": $(echo "$PROMPT_EN" | jq -Rs .),
  "refer_image": $(echo "${REFER:-}" | jq -Rs .),
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.png" >&2
exit 0
