#!/usr/bin/env bash
# adapters/comfy.sh — 本地 ComfyUI
# 用户需准备 workflow.json 模板,放在 ${COMFY_WORKFLOW:-./comfy-workflow.json}
# skill 把 prompt/seed/image 注入到 workflow 后提交

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

COMFY_HOST="${COMFY_HOST:-127.0.0.1:8188}"
WORKFLOW_FILE="${COMFY_WORKFLOW:-./comfy-workflow.json}"
TIMEOUT="${COMFY_TIMEOUT:-180}"

# 可被覆盖的节点 ID(默认值匹配 SDXL/FLUX 常见模板)
NODE_CLIP="${COMFY_NODE_CLIP:-6}"
NODE_KSAMPLER="${COMFY_NODE_KSAMPLER:-3}"
NODE_LOAD_IMAGE="${COMFY_NODE_LOAD_IMAGE:-10}"

if [[ ! -f "$WORKFLOW_FILE" ]]; then
  echo "ERROR: workflow file not found: $WORKFLOW_FILE" >&2
  echo "Set COMFY_WORKFLOW to your workflow JSON path." >&2
  echo "Tip: in ComfyUI UI, Settings > Enable Dev mode, then 'Save (API Format)' to export." >&2
  echo "If your node IDs differ from defaults (CLIP=6, KSampler=3, LoadImage=10), set COMFY_NODE_CLIP/COMFY_NODE_KSAMPLER/COMFY_NODE_LOAD_IMAGE." >&2
  exit 1
fi

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en // empty')
SEED=$(echo "$PROMPT_JSON" | jq -r '(.seed // 42) | tonumber' 2>/dev/null || echo 42)

[[ -z "$PROMPT_EN" ]] && { echo "ERROR: stdin JSON missing required .prompt_en" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# 注入前先验证 workflow 中存在目标节点 ID(否则 jq 会静默创建顶层 key,Comfy 会回 500)
WORKFLOW_RAW=$(cat "$WORKFLOW_FILE")
HAS_CLIP=$(echo "$WORKFLOW_RAW" | jq -r --arg n "$NODE_CLIP" 'has($n)')
HAS_KSAMPLER=$(echo "$WORKFLOW_RAW" | jq -r --arg n "$NODE_KSAMPLER" 'has($n)')

if [[ "$HAS_CLIP" != "true" ]]; then
  echo "ERROR: workflow $WORKFLOW_FILE does not contain CLIP node ID '$NODE_CLIP'" >&2
  echo "       Set COMFY_NODE_CLIP env var to match your workflow's CLIP text encode node ID" >&2
  exit 1
fi
if [[ "$HAS_KSAMPLER" != "true" ]]; then
  echo "ERROR: workflow $WORKFLOW_FILE does not contain KSampler node ID '$NODE_KSAMPLER'" >&2
  echo "       Set COMFY_NODE_KSAMPLER env var to match your workflow's KSampler node ID" >&2
  exit 1
fi

if [[ -n "$REFER" ]]; then
  HAS_LOAD_IMAGE=$(echo "$WORKFLOW_RAW" | jq -r --arg n "$NODE_LOAD_IMAGE" 'has($n)')
  if [[ "$HAS_LOAD_IMAGE" != "true" ]]; then
    echo "ERROR: workflow $WORKFLOW_FILE does not contain LoadImage node ID '$NODE_LOAD_IMAGE'" >&2
    echo "       Set COMFY_NODE_LOAD_IMAGE env var or remove --refer" >&2
    exit 1
  fi
fi

# 注入 prompt 和 seed 到 workflow(用 jq --arg 安全构造,节点 ID 通过变量参数化)
WORKFLOW=$(jq \
  --arg p "$PROMPT_EN" \
  --argjson s "$SEED" \
  --arg clip "$NODE_CLIP" \
  --arg ksampler "$NODE_KSAMPLER" \
  '.[$clip].inputs.text = $p | .[$ksampler].inputs.seed = $s' \
  "$WORKFLOW_FILE")

if [[ -z "$WORKFLOW" ]] || [[ "$WORKFLOW" == "null" ]]; then
  echo "ERROR: failed to inject prompt/seed into workflow (check node IDs CLIP=$NODE_CLIP / KSampler=$NODE_KSAMPLER)" >&2
  exit 1
fi

UPLOAD_RESPONSE=$(mktemp)
SUBMIT_RESPONSE=$(mktemp)
HISTORY_RESPONSE=$(mktemp)
trap 'rm -f "$UPLOAD_RESPONSE" "$SUBMIT_RESPONSE" "$HISTORY_RESPONSE"' EXIT

if [[ -n "$REFER" ]]; then
  [[ ! -f "$REFER" ]] && { echo "ERROR: --refer path not found: $REFER" >&2; exit 1; }
  # 通过 /upload/image 端点上传 refer 图
  HTTP_CODE=$(curl -sS --max-time 60 -o "$UPLOAD_RESPONSE" -w '%{http_code}' \
    -F "image=@${REFER}" \
    "http://${COMFY_HOST}/upload/image")

  if [[ "$HTTP_CODE" != 2* ]]; then
    echo "ERROR: Comfy upload HTTP $HTTP_CODE" >&2
    cat "$UPLOAD_RESPONSE" >&2
    exit 1
  fi

  UPLOADED_NAME=$(jq -r '.name // empty' "$UPLOAD_RESPONSE")
  if [[ -z "$UPLOADED_NAME" ]]; then
    echo "ERROR: Comfy upload response missing .name" >&2
    cat "$UPLOAD_RESPONSE" >&2
    exit 1
  fi
  WORKFLOW=$(echo "$WORKFLOW" | jq --arg n "$UPLOADED_NAME" --arg load "$NODE_LOAD_IMAGE" '.[$load].inputs.image = $n')
fi

CLIENT_ID=$(uuidgen 2>/dev/null || echo "story-pipeline-$$")

# 1. 提交(用 jq -n --argjson 安全构造请求体)
REQUEST_BODY=$(jq -n --argjson workflow "$WORKFLOW" --arg cid "$CLIENT_ID" '{prompt: $workflow, client_id: $cid}')

HTTP_CODE=$(curl -sS --max-time 30 -o "$SUBMIT_RESPONSE" -w '%{http_code}' \
  "http://${COMFY_HOST}/prompt" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY")

if [[ "$HTTP_CODE" != 2* ]]; then
  echo "ERROR: Comfy submit HTTP $HTTP_CODE" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

PROMPT_ID=$(jq -r '.prompt_id // empty' "$SUBMIT_RESPONSE")
if [[ -z "$PROMPT_ID" ]]; then
  echo "ERROR: Comfy submit response missing prompt_id" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

echo "[comfy] submitted prompt=$PROMPT_ID, polling..." >&2

# 2. 轮询 /history/<prompt_id>(完成时 .[prompt_id].status.completed == true)
HISTORY_URL="http://${COMFY_HOST}/history/${PROMPT_ID}"
ELAPSED=0
INTERVAL=2
COMPLETED=""

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  HTTP_CODE=$(curl -sS --max-time 15 -o "$HISTORY_RESPONSE" -w '%{http_code}' "$HISTORY_URL" || echo "000")

  if [[ "$HTTP_CODE" == 2* ]]; then
    COMPLETED=$(jq -r --arg pid "$PROMPT_ID" '.[$pid].status.completed // empty' "$HISTORY_RESPONSE")
    if [[ "$COMPLETED" == "true" ]]; then
      break
    fi
    # 检测失败
    STATUS_STR=$(jq -r --arg pid "$PROMPT_ID" '.[$pid].status.status_str // empty' "$HISTORY_RESPONSE")
    if [[ "$STATUS_STR" == "error" ]]; then
      echo "ERROR: Comfy task failed" >&2
      cat "$HISTORY_RESPONSE" >&2
      exit 1
    fi
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ "$COMPLETED" != "true" ]]; then
  echo "ERROR: Comfy task timeout after ${TIMEOUT}s" >&2
  exit 1
fi

# 3. 找输出图(SaveImage 节点的输出)
IMAGE_NAME=$(jq -r --arg pid "$PROMPT_ID" '.[$pid].outputs | to_entries[].value.images[0].filename // empty' "$HISTORY_RESPONSE" | head -n1)
SUBFOLDER=$(jq -r --arg pid "$PROMPT_ID" '.[$pid].outputs | to_entries[].value.images[0].subfolder // ""' "$HISTORY_RESPONSE" | head -n1)

if [[ -z "$IMAGE_NAME" ]]; then
  echo "ERROR: Comfy output image not found in history" >&2
  cat "$HISTORY_RESPONSE" >&2
  exit 1
fi

# 4. 下载(用 --data-urlencode 让 curl 处理 query 参数转义)
curl -sSL --max-time 120 -G \
  --data-urlencode "filename=${IMAGE_NAME}" \
  --data-urlencode "subfolder=${SUBFOLDER}" \
  --data-urlencode "type=output" \
  "http://${COMFY_HOST}/view" \
  -o "$OUT_DIR/$SHOT_ID.png"

[[ ! -s "$OUT_DIR/$SHOT_ID.png" ]] && { echo "ERROR: downloaded image is empty" >&2; exit 1; }

jq -n \
  --arg id "$SHOT_ID" \
  --arg backend "comfy" \
  --arg workflow_file "$WORKFLOW_FILE" \
  --arg prompt_id "$PROMPT_ID" \
  --arg comfy_image "$IMAGE_NAME" \
  --arg prompt "$PROMPT_EN" \
  --argjson seed "$SEED" \
  --arg refer "${REFER:-}" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    shot_id: $id,
    backend: $backend,
    workflow_file: $workflow_file,
    prompt_id: $prompt_id,
    comfy_image: $comfy_image,
    prompt: $prompt,
    seed: $seed,
    refer_image: $refer,
    generated_at: $ts
  }' > "$OUT_DIR/$SHOT_ID.json"

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.png" >&2
exit 0
