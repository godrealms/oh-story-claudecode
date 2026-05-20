#!/usr/bin/env bash
# adapters/kling.sh — 可灵后端

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
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

API_KEY="${KLING_API_KEY:?ERROR: KLING_API_KEY required}"
BASE_URL="${KLING_BASE_URL:-https://api.klingai.com}"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
MOTION=$(echo "$PROMPT_JSON" | jq -r '.motion_prompt')
DURATION=$(echo "$PROMPT_JSON" | jq -r '.duration | tonumber | floor')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect')

# 可灵只支持 5 或 10 秒
if [[ "$DURATION" -lt 8 ]]; then
  DURATION=5
else
  DURATION=10
fi

mkdir -p "$OUT_DIR"

# 1. 把图片转 base64(用 stdin 重定向,兼容 BSD/macOS 和 GNU/Linux)
#    BSD base64 不支持 -w 也不接受位置文件参数,必须走 stdin
IMAGE_B64=$(base64 -w 0 < "$IMAGE" 2>/dev/null || base64 < "$IMAGE" | tr -d '\n')

# 安全网:即使 base64 退出码为 0,也确认输出非空
if [[ -z "$IMAGE_B64" ]]; then
  echo "ERROR: kling: base64 produced empty output for $IMAGE (file size: $(wc -c < "$IMAGE" 2>/dev/null || echo unknown))" >&2
  exit 1
fi

# 2. 提交任务
SUBMIT_RESPONSE=$(mktemp)
trap 'rm -f "$SUBMIT_RESPONSE"' EXIT

FULL_PROMPT="${PROMPT_EN}. ${MOTION}"

# 安全构造请求体(jq -n --arg,避免 echo 尾随 \n 和反斜杠转义问题)
REQUEST_BODY=$(jq -n \
  --arg image "$IMAGE_B64" \
  --arg prompt "$FULL_PROMPT" \
  --argjson duration "$DURATION" \
  --arg aspect "$ASPECT" \
  '{
    image: $image,
    prompt: $prompt,
    duration: $duration,
    aspect_ratio: $aspect
  }')

HTTP_CODE=$(curl -sS --max-time 120 -o "$SUBMIT_RESPONSE" -w '%{http_code}' \
  "${BASE_URL}/v1/videos/image2video" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY")

# 检查 HTTP 状态码
if [[ "$HTTP_CODE" != 2* ]]; then
  echo "ERROR: Kling submit returned HTTP $HTTP_CODE" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

# 检查 API 业务错误
ERROR_MSG=$(jq -r '.error.message // empty' "$SUBMIT_RESPONSE")
if [[ -n "$ERROR_MSG" ]]; then
  echo "ERROR: Kling submit failed: $ERROR_MSG" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

TASK_ID=$(jq -r '.data.task_id // .task_id // empty' "$SUBMIT_RESPONSE")
if [[ -z "$TASK_ID" ]]; then
  echo "ERROR: Kling response missing task_id" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

echo "[kling] submitted task=$TASK_ID, polling..." >&2

# 3. 轮询
VIDEO_URL=$(poll_task \
  --check-url "${BASE_URL}/v1/videos/image2video/${TASK_ID}" \
  --auth-header "Authorization: Bearer ${API_KEY}" \
  --status-jq '.data.task_status // .status' \
  --done-values "succeed,completed,success" \
  --fail-values "failed,error" \
  --result-jq '.data.videos[0].url // .video_url' \
  --interval 10 \
  --timeout 600)

if [[ -z "$VIDEO_URL" ]]; then
  echo "ERROR: Kling poll returned empty URL" >&2
  exit 1
fi

# 4. 下载视频
curl -sSL --max-time 300 "$VIDEO_URL" -o "$OUT_DIR/$SHOT_ID.mp4"

if [[ ! -s "$OUT_DIR/$SHOT_ID.mp4" ]]; then
  echo "ERROR: downloaded video is empty" >&2
  exit 1
fi

# 5. 写伴随 .json(jq -n --arg 安全构造)
jq -n \
  --arg id "$SHOT_ID" \
  --arg backend "kling" \
  --arg task_id "$TASK_ID" \
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
    video_url: $video_url,
    duration: $duration,
    aspect: $aspect,
    input_image: $image,
    prompt: $prompt,
    generated_at: $ts
  }' > "$OUT_DIR/$SHOT_ID.json"

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.mp4" >&2
exit 0
