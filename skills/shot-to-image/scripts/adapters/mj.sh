#!/usr/bin/env bash
# adapters/mj.sh — Midjourney 第三方代理 API

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

API_KEY="${MJ_API_KEY:?ERROR: MJ_API_KEY required}"
BASE_URL="${MJ_BASE_URL:?ERROR: MJ_BASE_URL required}"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en // empty')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect // "9:16"')

[[ -z "$PROMPT_EN" ]] && { echo "ERROR: stdin JSON missing required .prompt_en" >&2; exit 1; }

mkdir -p "$OUT_DIR"

MJ_PROMPT="$PROMPT_EN --ar $ASPECT --v 6 --style raw"

if [[ -n "$REFER" ]]; then
  [[ ! -f "$REFER" ]] && { echo "ERROR: --refer path not found: $REFER" >&2; exit 1; }
  REFER_B64=$(base64 -w 0 < "$REFER" 2>/dev/null || base64 < "$REFER" | tr -d '\n')
  [[ -z "$REFER_B64" ]] && { echo "ERROR: base64 produced empty output for $REFER" >&2; exit 1; }
  MJ_PROMPT="$MJ_PROMPT --cref data:image/png;base64,$REFER_B64 --cw 80"
fi

SUBMIT_RESPONSE=$(mktemp)
trap 'rm -f "$SUBMIT_RESPONSE"' EXIT

REQUEST_BODY=$(jq -n --arg p "$MJ_PROMPT" '{prompt: $p}')

HTTP_CODE=$(curl -sS --max-time 60 -o "$SUBMIT_RESPONSE" -w '%{http_code}' \
  "${BASE_URL}/imagine" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY")

if [[ "$HTTP_CODE" != 2* ]]; then
  echo "ERROR: MJ submit HTTP $HTTP_CODE" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

TASK_ID=$(jq -r '.task_id // .id // .data.id // empty' "$SUBMIT_RESPONSE")
if [[ -z "$TASK_ID" ]]; then
  echo "ERROR: MJ response missing task_id" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

echo "[mj] submitted task=$TASK_ID, polling..." >&2

IMAGE_URL=$(poll_task \
  --check-url "${BASE_URL}/task/${TASK_ID}" \
  --auth-header "Authorization: Bearer ${API_KEY}" \
  --status-jq '.status' \
  --done-values "SUCCESS,success,completed,FINISHED" \
  --fail-values "FAILED,failed,error,FAILURE" \
  --result-jq '.image_url // .result.url // .data.url' \
  --interval 5 \
  --timeout 300)

[[ -z "$IMAGE_URL" ]] && { echo "ERROR: MJ poll returned empty URL" >&2; exit 1; }

curl -sSL --max-time 120 "$IMAGE_URL" -o "$OUT_DIR/$SHOT_ID.png"
[[ ! -s "$OUT_DIR/$SHOT_ID.png" ]] && { echo "ERROR: downloaded image is empty" >&2; exit 1; }

jq -n \
  --arg id "$SHOT_ID" \
  --arg backend "mj" \
  --arg task_id "$TASK_ID" \
  --arg image_url "$IMAGE_URL" \
  --arg prompt "$MJ_PROMPT" \
  --arg refer "${REFER:-}" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    shot_id: $id,
    backend: $backend,
    task_id: $task_id,
    image_url: $image_url,
    prompt: $prompt,
    refer_image: $refer,
    generated_at: $ts
  }' > "$OUT_DIR/$SHOT_ID.json"

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.png" >&2
exit 0
