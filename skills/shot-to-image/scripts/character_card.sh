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
CARD_JSON="$CARD_DIR/${NAME}.card.json"

# 已存在跳过(只在 PNG + card.json 都存在时跳过,避免 prompt-only 模式假阳性)
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

# route.sh 写的是 {NAME}.png 和 {NAME}.json(伴随 .json,adapter sidecar 审计信息)
# 把适配器 sidecar 的 backend 字段提取出来,写入独立的 {NAME}.card.json
# 注意:adapter sidecar 保持不变,角色卡 schema 写到 .card.json 避免覆盖
ADAPTER_SIDECAR="$CARD_DIR/${NAME}.json"
BACKEND=""
[[ -f "$ADAPTER_SIDECAR" ]] && BACKEND=$(jq -r '.backend // empty' "$ADAPTER_SIDECAR")

# reference_png 仅当 PNG 实际生成时才指向文件,否则为 null
if [[ -f "$CARD_PNG" ]]; then
  REF_PNG_ARG="$CARD_PNG"
else
  REF_PNG_ARG=""
fi

# 用 jq -n --arg 安全构造,避免 raw shell interpolation 的 C2 bug
jq -n \
  --arg name "$NAME" \
  --arg desc_en "$DESC_EN" \
  --arg ref_png "$REF_PNG_ARG" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg backend "$BACKEND" \
  '{
    name: $name,
    description_cn: null,
    description_en: $desc_en,
    reference_png: (if $ref_png == "" then null else $ref_png end),
    mj_cref_url: null,
    jimeng_refer_id: null,
    kling_subject_id: null,
    comfy_lora_path: null,
    generated_at: $ts,
    generated_by_backend: $backend
  }' > "$CARD_JSON"

echo "[card] $NAME -> $CARD_PNG" >&2
exit 0
