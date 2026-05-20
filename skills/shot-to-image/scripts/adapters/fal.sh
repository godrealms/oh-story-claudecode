#!/usr/bin/env bash
# adapters/fal.sh — Fal.ai FLUX 后端(同步)

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

API_KEY="${FAL_KEY:?ERROR: FAL_KEY required}"
MODEL="${FAL_MODEL:-fal-ai/flux/dev}"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en // empty')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect // "9:16"')
NEGATIVE=$(echo "$PROMPT_JSON" | jq -r '.negative // ""')
SEED=$(echo "$PROMPT_JSON" | jq -r '(.seed // 42) | tonumber' 2>/dev/null || echo 42)

[[ -z "$PROMPT_EN" ]] && { echo "ERROR: stdin JSON missing required .prompt_en" >&2; exit 1; }

# aspect → image_size
case "$ASPECT" in
  "9:16") IMAGE_SIZE="portrait_16_9" ;;
  "16:9") IMAGE_SIZE="landscape_16_9" ;;
  "1:1")  IMAGE_SIZE="square_hd" ;;
  *)      IMAGE_SIZE="portrait_16_9" ;;
esac

mkdir -p "$OUT_DIR"

# 构造请求体
REQUEST_BODY=$(jq -n \
  --arg p "$PROMPT_EN" \
  --arg n "$NEGATIVE" \
  --arg sz "$IMAGE_SIZE" \
  --argjson s "$SEED" \
  '{prompt: $p, negative_prompt: $n, image_size: $sz, seed: $s, num_images: 1, enable_safety_checker: false}')

if [[ -n "$REFER" ]]; then
  [[ ! -f "$REFER" ]] && { echo "ERROR: --refer path not found: $REFER" >&2; exit 1; }
  REFER_B64=$(base64 -w 0 < "$REFER" 2>/dev/null || base64 < "$REFER" | tr -d '\n')
  [[ -z "$REFER_B64" ]] && { echo "ERROR: base64 produced empty output for $REFER" >&2; exit 1; }
  REQUEST_BODY=$(echo "$REQUEST_BODY" | jq --arg img "data:image/png;base64,$REFER_B64" '. + {image_url: $img, strength: 0.7}')
fi

RESPONSE=$(mktemp)
trap 'rm -f "$RESPONSE"' EXIT

HTTP_CODE=$(curl -sS --max-time 180 -o "$RESPONSE" -w '%{http_code}' \
  "https://fal.run/${MODEL}" \
  -H "Authorization: Key ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY")

if [[ "$HTTP_CODE" != 2* ]]; then
  echo "ERROR: Fal HTTP $HTTP_CODE" >&2
  cat "$RESPONSE" >&2
  exit 1
fi

IMAGE_URL=$(jq -r '.images[0].url // .image.url // empty' "$RESPONSE")
if [[ -z "$IMAGE_URL" ]]; then
  echo "ERROR: Fal response missing image URL" >&2
  cat "$RESPONSE" >&2
  exit 1
fi

curl -sSL --max-time 120 "$IMAGE_URL" -o "$OUT_DIR/$SHOT_ID.png"
[[ ! -s "$OUT_DIR/$SHOT_ID.png" ]] && { echo "ERROR: downloaded image is empty" >&2; exit 1; }

jq -n \
  --arg id "$SHOT_ID" \
  --arg backend "fal" \
  --arg model "$MODEL" \
  --arg image_url "$IMAGE_URL" \
  --arg prompt "$PROMPT_EN" \
  --arg image_size "$IMAGE_SIZE" \
  --arg refer "${REFER:-}" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    shot_id: $id,
    backend: $backend,
    model: $model,
    image_url: $image_url,
    prompt: $prompt,
    image_size: $image_size,
    refer_image: $refer,
    generated_at: $ts
  }' > "$OUT_DIR/$SHOT_ID.json"

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.png" >&2
exit 0
