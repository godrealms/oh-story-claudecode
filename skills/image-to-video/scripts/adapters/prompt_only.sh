#!/usr/bin/env bash
# adapters/prompt_only.sh — 视频后端 prompt-only:导出多家后端的提示词文件

set -euo pipefail

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

# stdin 读 prompt JSON
PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
MOTION=$(echo "$PROMPT_JSON" | jq -r '.motion_prompt')
DURATION=$(echo "$PROMPT_JSON" | jq -r '.duration')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect')

# 校验必填字段:缺失时 fail-fast,避免 output 写出字面 "null"
if [[ -z "$PROMPT_EN" || "$PROMPT_EN" == "null" ]]; then
  echo "ERROR: prompt_only: stdin JSON missing required .prompt_en" >&2
  exit 1
fi
if [[ -z "$DURATION" || "$DURATION" == "null" ]]; then
  echo "ERROR: prompt_only: stdin JSON missing required .duration" >&2
  exit 1
fi
if [[ -z "$ASPECT" || "$ASPECT" == "null" ]]; then
  echo "ERROR: prompt_only: stdin JSON missing required .aspect" >&2
  exit 1
fi
# motion_prompt 可选:缺失时退化为空字符串
[[ "$MOTION" == "null" ]] && MOTION=""

# IMAGE 占位:为空时填提示文字
IMAGE_DISPLAY="${IMAGE:-<填入镜头图路径>}"

# OUT_DIR 是 镜头视频/,平级的 提示词视频/ 是它的兄弟目录
PROMPT_DIR=$(dirname "$OUT_DIR")/提示词视频
mkdir -p "$PROMPT_DIR"

# Kling 风格(中英混合,简洁)— 用 printf %s 避免 echo 把反斜杠当转义
{
  printf 'prompt: %s. %s\n' "$PROMPT_EN" "$MOTION"
  printf 'duration: %s\n' "$DURATION"
  printf 'aspect_ratio: %s\n' "$ASPECT"
  printf 'image: %s\n' "$IMAGE_DISPLAY"
} > "$PROMPT_DIR/$SHOT_ID.kling.txt"

# 即梦风格(中文为主)
{
  printf 'prompt: %s。%s\n' "$PROMPT_EN" "$MOTION"
  printf 'duration: %ss\n' "$DURATION"
  printf '比例: %s\n' "$ASPECT"
  printf 'image: %s\n' "$IMAGE_DISPLAY"
} > "$PROMPT_DIR/$SHOT_ID.jimeng.txt"

# Runway 风格(英文,详细)
{
  printf 'prompt: %s\n\n' "$PROMPT_EN"
  printf '%s\n\n' "$MOTION"
  printf 'cinematic quality, professional cinematography\n\n'
  printf 'duration: %ss\n' "$DURATION"
  printf 'aspect_ratio: %s\n' "$ASPECT"
  printf 'input_image: %s\n' "$IMAGE_DISPLAY"
} > "$PROMPT_DIR/$SHOT_ID.runway.txt"

# 通用 JSON(给写自定义脚本的用户)— 用 jq -n --arg 安全构造
jq -n \
  --arg prompt_en "$PROMPT_EN" \
  --arg motion "$MOTION" \
  --argjson duration "$DURATION" \
  --arg aspect "$ASPECT" \
  --arg image "${IMAGE:-}" \
  '{
    prompt_en: $prompt_en,
    motion_prompt: $motion,
    duration: $duration,
    aspect: $aspect,
    image: $image
  }' > "$PROMPT_DIR/$SHOT_ID.json"

# 在 OUT_DIR 写一个伴随 .json 标记"提示词已导出但无视频"
mkdir -p "$OUT_DIR"
jq -n \
  --arg id "$SHOT_ID" \
  --arg kling_path "$PROMPT_DIR/$SHOT_ID.kling.txt" \
  --arg jimeng_path "$PROMPT_DIR/$SHOT_ID.jimeng.txt" \
  --arg runway_path "$PROMPT_DIR/$SHOT_ID.runway.txt" \
  --arg json_path "$PROMPT_DIR/$SHOT_ID.json" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    shot_id: $id,
    backend: "prompt-only",
    status: "prompt_exported_no_video",
    prompt_files: [$kling_path, $jimeng_path, $runway_path, $json_path],
    generated_at: $ts
  }' > "$OUT_DIR/$SHOT_ID.json"

echo "OK $SHOT_ID (prompt-only, see $PROMPT_DIR/$SHOT_ID.*)" >&2
exit 0
