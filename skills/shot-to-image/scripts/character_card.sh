#!/usr/bin/env bash
# character_card.sh — 角色卡预生成入口
# 用法:character_card.sh <角色名> <description_en> <角色卡目录> [aspect]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

NAME="${1:?usage: $0 <name> <description_en> <card_dir> [aspect]}"
DESC_EN="${2:?usage: $0 <name> <description_en> <card_dir> [aspect]}"
CARD_DIR="${3:?usage: $0 <name> <description_en> <card_dir> [aspect]}"
ASPECT="${4:-9:16}"

mkdir -p "$CARD_DIR"

CARD_PNG="$CARD_DIR/${NAME}.png"
CARD_JSON="$CARD_DIR/${NAME}.json"

# 已存在跳过
if [[ -f "$CARD_PNG" && -f "$CARD_JSON" ]]; then
  echo "[card] $NAME exists, skipping" >&2
  exit 0
fi

# 角色卡 prompt(参考 prompt-construction.md)
CARD_PROMPT="${DESC_EN}, centered portrait, frontal view, neutral expression, plain gray studio background, even soft lighting, clear facial features, cinematic film still, shot on 85mm portrait lens, shallow depth of field"

PROMPT_JSON=$(jq -n \
  --arg p "$CARD_PROMPT" \
  --arg a "$ASPECT" \
  '{
     prompt_en: $p,
     negative: "blurry, low quality, watermark, text overlay, ugly, deformed, multiple people",
     aspect: $a,
     seed: 1,
     characters: []
   }')

# 调 route.sh,无 refer
echo "$PROMPT_JSON" | "$SCRIPT_DIR/route.sh" \
  --shot-id "$NAME" \
  --out-dir "$CARD_DIR"

# route.sh 写的是 {NAME}.png 和 {NAME}.json(伴随 .json)
# 把伴随 .json 转成角色卡 .json schema
ADAPTER_JSON="$CARD_DIR/${NAME}.json"
if [[ -f "$ADAPTER_JSON" ]]; then
  # 备份适配器写的 backend 字段
  BACKEND=$(jq -r '.backend // empty' "$ADAPTER_JSON")

  # 用 jq -n --arg 安全构造,避免 raw shell interpolation 的 C2 bug
  jq -n \
    --arg name "$NAME" \
    --arg desc_en "$DESC_EN" \
    --arg ref_png "$CARD_PNG" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg backend "$BACKEND" \
    '{
      name: $name,
      description_cn: null,
      description_en: $desc_en,
      reference_png: $ref_png,
      mj_cref_url: null,
      jimeng_refer_id: null,
      kling_subject_id: null,
      comfy_lora_path: null,
      generated_at: $ts,
      generated_by_backend: $backend
    }' > "$CARD_JSON"
fi

echo "[card] $NAME -> $CARD_PNG" >&2
exit 0
