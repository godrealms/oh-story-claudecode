#!/usr/bin/env bash
# adapters/jimeng.sh — 即梦 / 火山方舟（doubao-seedance）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/poll.sh
source "$SCRIPT_DIR/lib/poll.sh"

SHOT_ID=""
OUT_DIR=""
IMAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shot-id) SHOT_ID="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 2 ;;
  esac
done

[[ -z "$SHOT_ID" ]] && { echo "ERROR: --shot-id required" >&2; exit 2; }
[[ -z "$OUT_DIR" ]] && { echo "ERROR: --out-dir required" >&2; exit 2; }
[[ -z "$IMAGE" ]] && { echo "ERROR: --image required" >&2; exit 2; }
[[ ! -f "$IMAGE" ]] && { echo "ERROR: image not found: $IMAGE" >&2; exit 1; }

API_KEY="${JIMENG_API_KEY:?ERROR: JIMENG_API_KEY required}"
BASE_URL="${JIMENG_BASE_URL:-https://ark.cn-beijing.volces.com}"
MODEL="${JIMENG_MODEL:-doubao-seedance-1.0-pro}"
TIMEOUT="${JIMENG_TIMEOUT:-600}"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en // empty')
MOTION=$(echo "$PROMPT_JSON" | jq -r '.motion_prompt // empty')
DURATION=$(echo "$PROMPT_JSON" | jq -r '.duration | tonumber | floor')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect // "9:16"')

[[ -z "$PROMPT_EN" ]] && { echo "ERROR: stdin JSON missing required .prompt_en" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# 1. 把图片转 base64（stdin 重定向，兼容 BSD/macOS 和 GNU/Linux）
IMAGE_B64=$(base64 -w 0 < "$IMAGE" 2>/dev/null || base64 < "$IMAGE" | tr -d '\n')

# 安全网：即使 base64 退出码为 0，也确认输出非空
if [[ -z "$IMAGE_B64" ]]; then
  echo "ERROR: jimeng: base64 produced empty output for $IMAGE (file size: $(wc -c < "$IMAGE" 2>/dev/null || echo unknown))" >&2
  exit 1
fi

FULL_PROMPT="${PROMPT_EN}。${MOTION}"

# 2. 提交任务
SUBMIT_RESPONSE=$(mktemp)
trap 'rm -f "$SUBMIT_RESPONSE"' EXIT

# 安全构造请求体（jq -n --arg/--argjson 避免转义问题）
REQUEST_BODY=$(jq -n \
  --arg model "$MODEL" \
  --arg prompt "$FULL_PROMPT" \
  --arg b64 "$IMAGE_B64" \
  '{
    model: $model,
    content: [
      {type: "text", text: $prompt},
      {type: "image_url", image_url: {url: ("data:image/png;base64," + $b64)}}
    ]
  }')

HTTP_CODE=$(curl -sS --max-time 120 -o "$SUBMIT_RESPONSE" -w '%{http_code}' \
  "${BASE_URL}/api/v3/contents/generations/tasks" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY")

# 检查 HTTP 状态码
if [[ "$HTTP_CODE" != 2* ]]; then
  echo "ERROR: Jimeng submit returned HTTP $HTTP_CODE" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

# 检查 API 业务错误
ERROR_MSG=$(jq -r '.error.message // empty' "$SUBMIT_RESPONSE")
if [[ -n "$ERROR_MSG" ]]; then
  echo "ERROR: Jimeng submit failed: $ERROR_MSG" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

TASK_ID=$(jq -r '.id // .task_id // empty' "$SUBMIT_RESPONSE")
if [[ -z "$TASK_ID" ]]; then
  echo "ERROR: Jimeng response missing task_id" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

echo "[jimeng] submitted task=$TASK_ID, polling..." >&2

# 3. 轮询
VIDEO_URL=$(poll_task \
  --check-url "${BASE_URL}/api/v3/contents/generations/tasks/${TASK_ID}" \
  --auth-header "Authorization: Bearer ${API_KEY}" \
  --status-jq '.status' \
  --done-values "succeeded,completed" \
  --fail-values "failed,error" \
  --result-jq '.content.video_url // .outputs[0].url' \
  --interval 10 \
  --timeout "$TIMEOUT")

if [[ -z "$VIDEO_URL" ]]; then
  echo "ERROR: Jimeng poll returned empty URL" >&2
  exit 1
fi

# 4. 下载视频
curl -sSL --max-time 300 "$VIDEO_URL" -o "$OUT_DIR/$SHOT_ID.mp4"

if [[ ! -s "$OUT_DIR/$SHOT_ID.mp4" ]]; then
  echo "ERROR: downloaded video is empty" >&2
  exit 1
fi

# 5. 写伴随 .json（jq -n --arg 安全构造）
jq -n \
  --arg id "$SHOT_ID" \
  --arg backend "jimeng" \
  --arg task_id "$TASK_ID" \
  --arg model "$MODEL" \
  --arg video_url "$VIDEO_URL" \
  --argjson duration "$DURATION" \
  --arg aspect "$ASPECT" \
  --arg image "$IMAGE" \
  --arg prompt "$FULL_PROMPT" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    shot_id: $id,
    backend: $backend,
    task_id: $task_id,
    model: $model,
    video_url: $video_url,
    duration: $duration,
    aspect: $aspect,
    input_image: $image,
    prompt: $prompt,
    generated_at: $ts
  }' > "$OUT_DIR/$SHOT_ID.json"

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.mp4" >&2
exit 0
