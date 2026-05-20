#!/usr/bin/env bash
# lib/json.sh — jq 包装,统一 JSON 读写
# NOTE: json_get / json_set / json_merge are duplicated in
#   skills/image-to-video/scripts/lib/json.sh — keep these generic helpers in sync.
#   Only build_prompt_json (image) vs build_video_prompt_json (video) differs.

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

# 构造 shot 提示词 JSON(stdout 输出,供 adapter 通过 stdin 读)
# 用法:build_prompt_json <shot_json> <character_card_dir> <aspect>
build_prompt_json() {
  local shot_json="$1" card_dir="$2" aspect="$3"
  local prompt_en lighting mood characters

  # Validate input is an object
  if ! echo "$shot_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "ERROR: build_prompt_json: shot_json is not a valid JSON object" >&2
    return 1
  fi

  prompt_en=$(echo "$shot_json" | jq -r '.description_en // empty')
  if [[ -z "$prompt_en" ]]; then
    echo "ERROR: build_prompt_json: shot_json missing required .description_en" >&2
    return 1
  fi

  lighting=$(echo "$shot_json" | jq -r '.lighting // ""')
  mood=$(echo "$shot_json" | jq -r '.mood // ""')
  characters=$(echo "$shot_json" | jq -c '.characters // []')

  # Build the combined prompt, omitting empty segments
  local combined="$prompt_en"
  [[ -n "$lighting" ]] && combined="$combined, $lighting"
  [[ -n "$mood" ]] && combined="$combined, $mood"

  jq -n \
    --arg p "$combined" \
    --arg a "$aspect" \
    --argjson c "$characters" \
    --arg cd "$card_dir" \
    --argjson sm "$shot_json" \
    '{
       prompt_en: $p,
       negative: "blurry, low quality, watermark, text overlay, ugly, deformed",
       aspect: $a,
       seed: 42,
       characters: $c,
       character_card_dir: $cd,
       shot_meta: $sm
     }'
}
