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
  jq "$path = \"$value\"" "$file" > "$tmp" && mv "$tmp" "$file"
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
  prompt_en=$(echo "$shot_json" | jq -r '.description_en')
  lighting=$(echo "$shot_json" | jq -r '.lighting')
  mood=$(echo "$shot_json" | jq -r '.mood')
  characters=$(echo "$shot_json" | jq -c '.characters')

  jq -n \
    --arg p "$prompt_en" \
    --arg l "$lighting" \
    --arg m "$mood" \
    --arg a "$aspect" \
    --argjson c "$characters" \
    --arg cd "$card_dir" \
    --argjson sm "$shot_json" \
    '{
       prompt_en: ($p + ", " + $l + ", " + $m),
       negative: "blurry, low quality, watermark, text overlay, ugly, deformed",
       aspect: $a,
       seed: 42,
       characters: $c,
       character_card_dir: $cd,
       shot_meta: $sm
     }'
}
