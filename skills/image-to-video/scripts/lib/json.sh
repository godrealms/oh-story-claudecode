#!/usr/bin/env bash
# lib/json.sh — jq 包装,统一 JSON 读写

# 读单字段(找不到返回空串)
json_get() {
  local file="$1" path="$2"
  jq -r "$path // empty" "$file"
}

# 写单字段(原地修改)
json_set() {
  local file="$1" path="$2" value="$3"
  local tmp
  tmp=$(mktemp)
  if jq --arg v "$value" "$path = \$v" "$file" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    echo "ERROR: json_set failed for $path in $file" >&2
    return 1
  fi
}

# 合并两个 JSON 对象(后者覆盖前者)
json_merge() {
  local base="$1" overlay="$2"
  jq -s '.[0] * .[1]' "$base" "$overlay"
}

# 构造视频 prompt JSON
# 用法: build_video_prompt_json <shot_json> <duration> <aspect>
build_video_prompt_json() {
  local shot_json="$1" duration="${2:-5}" aspect="$3"
  local description_en lighting mood camera

  # Validate input is an object
  if ! echo "$shot_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "ERROR: build_video_prompt_json: shot_json is not a valid JSON object" >&2
    return 1
  fi

  description_en=$(echo "$shot_json" | jq -r '.description_en // empty')
  if [[ -z "$description_en" ]]; then
    echo "ERROR: build_video_prompt_json: shot_json missing required .description_en" >&2
    return 1
  fi

  lighting=$(echo "$shot_json" | jq -r '.lighting // ""')
  mood=$(echo "$shot_json" | jq -r '.mood // ""')
  camera=$(echo "$shot_json" | jq -r '.camera // "static"')

  # 运镜 → 英文运动模板（简版,详见 references/motion-prompts.md）
  local camera_motion
  case "$camera" in
    static)    camera_motion="static camera, locked-off shot" ;;
    pan)       camera_motion="camera pans slowly left to right" ;;
    tilt)      camera_motion="camera tilts up slowly" ;;
    push)      camera_motion="camera slowly pushes in toward subject" ;;
    pull)      camera_motion="camera slowly pulls out from subject" ;;
    track)     camera_motion="camera tracks behind subject" ;;
    handheld)  camera_motion="handheld shaky cam, documentary feel" ;;
    orbit)     camera_motion="camera orbits around subject" ;;
    *)         camera_motion="static camera" ;;
  esac

  # Build the combined atmosphere line, omitting empty segments
  local atmosphere=""
  [[ -n "$lighting" ]] && atmosphere="$lighting"
  if [[ -n "$mood" ]]; then
    [[ -n "$atmosphere" ]] && atmosphere="$atmosphere, $mood" || atmosphere="$mood"
  fi
  local motion_prompt
  if [[ -n "$atmosphere" ]]; then
    motion_prompt="Camera: $camera_motion. Atmosphere: $atmosphere."
  else
    motion_prompt="Camera: $camera_motion."
  fi

  jq -n \
    --arg p "$description_en" \
    --arg mp "$motion_prompt" \
    --argjson d "$duration" \
    --arg a "$aspect" \
    --argjson sm "$shot_json" \
    '{
       prompt_en: $p,
       motion_prompt: $mp,
       duration: $d,
       aspect: $a,
       shot_meta: $sm
     }'
}
