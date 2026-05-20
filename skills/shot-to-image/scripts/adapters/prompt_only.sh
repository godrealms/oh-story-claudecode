#!/usr/bin/env bash
# adapters/prompt_only.sh — 不调 API,只导出提示词到 .txt/.json

set -euo pipefail

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

# stdin 读 prompt JSON
PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect')
NEGATIVE=$(echo "$PROMPT_JSON" | jq -r '.negative // ""')
SEED=$(echo "$PROMPT_JSON" | jq -r '.seed // 42')

# 输出目录变更:写到 提示词/ 而不是 镜头图/
# OUT_DIR 是 镜头图/,平级的 提示词/ 是它的兄弟目录
PROMPT_DIR=$(dirname "$OUT_DIR")/提示词
mkdir -p "$PROMPT_DIR"

# MJ 风格:单行 + 参数
# 注意:MJ 不识别 --cref file://,本地路径无法直接粘贴。
# 当 REFER 设置时,跳过 --cref,改写 hint 注释让用户上传后手动补。
if [[ -n "$REFER" && -f "$REFER" ]]; then
  echo "WARNING: --cref file:// is not directly pasteable to MJ. Upload $REFER to an image host and replace --cref URL before running in MJ." >&2
  {
    echo "# Refer image: $REFER"
    echo "# For MJ: upload this PNG, get hosted URL, append --cref <URL> --cw 80 to prompt below."
    echo ""
    echo "$PROMPT_EN --ar $ASPECT --v 6 --style raw"
  } > "$PROMPT_DIR/$SHOT_ID.mj.txt"
else
  echo "$PROMPT_EN --ar $ASPECT --v 6 --style raw" > "$PROMPT_DIR/$SHOT_ID.mj.txt"
fi

# SD/Comfy 风格:JSON (用 jq -n --arg 安全构造,避免 echo 尾随 \n 污染)
jq -n \
  --arg prompt "$PROMPT_EN" \
  --arg neg "$NEGATIVE" \
  --arg aspect "$ASPECT" \
  --argjson seed "$SEED" \
  --arg refer "${REFER:-}" \
  '{
    prompt: $prompt,
    negative_prompt: $neg,
    aspect_ratio: $aspect,
    seed: $seed,
    refer_image: $refer
  }' > "$PROMPT_DIR/$SHOT_ID.sd.json"

# 同时在 OUT_DIR 写一个空 placeholder + .json,标记"提示词已导出但没有真图"
mkdir -p "$OUT_DIR"
jq -n \
  --arg id "$SHOT_ID" \
  --arg mj_path "$PROMPT_DIR/$SHOT_ID.mj.txt" \
  --arg sd_path "$PROMPT_DIR/$SHOT_ID.sd.json" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    shot_id: $id,
    backend: "prompt-only",
    status: "prompt_exported_no_image",
    prompt_files: [$mj_path, $sd_path],
    generated_at: $ts
  }' > "$OUT_DIR/$SHOT_ID.json"

echo "OK $SHOT_ID (prompt-only, see $PROMPT_DIR/$SHOT_ID.*)" >&2
exit 0
