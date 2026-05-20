#!/usr/bin/env bash
# adapters/replicate.sh — Replicate FLUX 后端

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/poll.sh
source "$SCRIPT_DIR/lib/poll.sh"

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

API_TOKEN="${REPLICATE_API_TOKEN:?ERROR: REPLICATE_API_TOKEN required}"
MODEL="${REPLICATE_MODEL_VERSION:-black-forest-labs/flux-dev}"
TIMEOUT="${REPLICATE_TIMEOUT:-180}"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en // empty')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect // "9:16"')
NEGATIVE=$(echo "$PROMPT_JSON" | jq -r '.negative // ""')
SEED=$(echo "$PROMPT_JSON" | jq -r '(.seed // 42) | tonumber' 2>/dev/null || echo 42)

[[ -z "$PROMPT_EN" ]] && { echo "ERROR: stdin JSON missing required .prompt_en" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# 构造 input(用 jq -n --arg 安全构造,避免 shell 注入与 \n 污染)
INPUT=$(jq -n \
  --arg p "$PROMPT_EN" \
  --arg n "$NEGATIVE" \
  --arg a "$ASPECT" \
  --argjson s "$SEED" \
  '{prompt: $p, negative_prompt: $n, aspect_ratio: $a, seed: $s, output_format: "png"}')

if [[ -n "$REFER" ]]; then
  [[ ! -f "$REFER" ]] && { echo "ERROR: --refer path not found: $REFER" >&2; exit 1; }
  REFER_B64=$(base64 -w 0 < "$REFER" 2>/dev/null || base64 < "$REFER" | tr -d '\n')
  [[ -z "$REFER_B64" ]] && { echo "ERROR: base64 produced empty output for $REFER" >&2; exit 1; }
  INPUT=$(echo "$INPUT" | jq --arg img "data:image/png;base64,$REFER_B64" '. + {image: $img, ip_adapter_scale: 0.7}')
fi

SUBMIT_RESPONSE=$(mktemp)
trap 'rm -f "$SUBMIT_RESPONSE"' EXIT

REQUEST_BODY=$(jq -n --argjson input "$INPUT" '{input: $input}')

HTTP_CODE=$(curl -sS --max-time 60 -o "$SUBMIT_RESPONSE" -w '%{http_code}' \
  "https://api.replicate.com/v1/models/${MODEL}/predictions" \
  -H "Authorization: Token ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY")

if [[ "$HTTP_CODE" != 2* ]]; then
  echo "ERROR: Replicate submit HTTP $HTTP_CODE" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

PREDICTION_ID=$(jq -r '.id // empty' "$SUBMIT_RESPONSE")
GET_URL=$(jq -r '.urls.get // empty' "$SUBMIT_RESPONSE")

if [[ -z "$PREDICTION_ID" ]] || [[ -z "$GET_URL" ]]; then
  echo "ERROR: Replicate response missing id or urls.get" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

echo "[replicate] submitted prediction=$PREDICTION_ID, polling..." >&2

IMAGE_URL=$(poll_task \
  --check-url "$GET_URL" \
  --auth-header "Authorization: Token ${API_TOKEN}" \
  --status-jq '.status' \
  --done-values "succeeded" \
  --fail-values "failed,canceled" \
  --result-jq '.output | if type == "array" then .[0] else . end' \
  --interval 5 \
  --timeout "$TIMEOUT")

[[ -z "$IMAGE_URL" ]] && { echo "ERROR: Replicate poll returned empty URL" >&2; exit 1; }

curl -sSL --max-time 120 "$IMAGE_URL" -o "$OUT_DIR/$SHOT_ID.png"
[[ ! -s "$OUT_DIR/$SHOT_ID.png" ]] && { echo "ERROR: downloaded image is empty" >&2; exit 1; }

jq -n \
  --arg id "$SHOT_ID" \
  --arg backend "replicate" \
  --arg model "$MODEL" \
  --arg prediction_id "$PREDICTION_ID" \
  --arg image_url "$IMAGE_URL" \
  --arg prompt "$PROMPT_EN" \
  --arg refer "${REFER:-}" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    shot_id: $id,
    backend: $backend,
    model: $model,
    prediction_id: $prediction_id,
    image_url: $image_url,
    prompt: $prompt,
    refer_image: $refer,
    generated_at: $ts
  }' > "$OUT_DIR/$SHOT_ID.json"

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.png" >&2
exit 0
