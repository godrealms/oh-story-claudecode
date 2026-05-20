# 小说转视频流水线 Plan 4:story-pipeline 编排 + 其余 adapter + /story 路由

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 `story-pipeline` 编排 skill(6 个分步闸门,state.json 续跑/回退),补齐 image/video adapter 池(MJ/Replicate/Fal/Comfy/jimeng/runway,Sora/Veo 仅占位),整合 `/story` 路由让用户能一句话开拍。

**Architecture:** 编排 skill 调用 5 个子 skill 时通过环境变量 `STORY_PIPELINE_EPISODE`/`STORY_PIPELINE_GATE` 让子 skill 知道自己在编排里跑。state.json 在每集根目录,记录每个闸门状态。

**Tech Stack:** bash + jq;复用 Plan 1-3 的所有基础设施

**前置:** Plan 1-3 完成

---

## File Structure

**新建**:
- `skills/story-pipeline/SKILL.md`
- `skills/story-pipeline/references/gate-workflow.md`
- `skills/story-pipeline/references/state-schema.md`
- `skills/story-pipeline/scripts/state.sh`(state.json 读写工具)
- `skills/story-pipeline/scripts/run-pipeline.sh`(主编排入口)
- `skills/shot-to-image/scripts/adapters/mj.sh`
- `skills/shot-to-image/scripts/adapters/replicate.sh`
- `skills/shot-to-image/scripts/adapters/fal.sh`
- `skills/shot-to-image/scripts/adapters/comfy.sh`
- `skills/image-to-video/scripts/adapters/jimeng.sh`
- `skills/image-to-video/scripts/adapters/runway.sh`
- `skills/image-to-video/scripts/adapters/sora.sh`(占位,exit 1)
- `skills/image-to-video/scripts/adapters/veo.sh`(占位,exit 1)

**修改**:
- `.claude-plugin/marketplace.json`(注册 story-pipeline)
- `skills/story/SKILL.md`(整合 5 个新 skill 到 /story 路由)
- `skills/story-long-write/SKILL.md`(Phase 5 末尾加跳转提示)

---

## Phase 0:注册 story-pipeline

### Task 0.1:marketplace.json 注册 + 创建目录骨架

**Files:**
- Modify: `.claude-plugin/marketplace.json`
- Create: `skills/story-pipeline/{references,scripts}/`

- [ ] **Step 1: 在 marketplace 追加**

```json
,
    {
      "name": "story-pipeline",
      "description": "小说转视频编排器。6 个分步闸门(剧本/镜头表/角色卡/镜头图/镜头视频/交付包),每闸暂停等用户确认,支持续跑和回退。",
      "source": "./",
      "strict": false,
      "version": "1.0.0",
      "category": "novel-video",
      "keywords": ["pipeline", "orchestrator", "短剧", "拍短剧", "开拍", "novel-to-video", "chinese"],
      "skills": ["./skills/story-pipeline"]
    }
```

- [ ] **Step 2: 创建目录**

```bash
mkdir -p skills/story-pipeline/references
mkdir -p skills/story-pipeline/scripts
touch skills/story-pipeline/references/.gitkeep
touch skills/story-pipeline/scripts/.gitkeep
```

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/marketplace.json skills/story-pipeline
git commit -m "chore: register story-pipeline and scaffold dirs"
```

---

## Phase 1:其余 image adapter(MJ/Replicate/Fal/Comfy)

### Task 1.1:写 adapters/mj.sh(Midjourney 代理)

**Files:**
- Create: `skills/shot-to-image/scripts/adapters/mj.sh`

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# adapters/mj.sh — Midjourney 第三方代理 API
# 注:MJ 没官方 API,各代理服务商接口不一,本脚本写主流模式,用户按服务商微调

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/poll.sh"

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

API_KEY="${MJ_API_KEY:?ERROR: MJ_API_KEY required}"
BASE_URL="${MJ_BASE_URL:?ERROR: MJ_BASE_URL required (your proxy's endpoint)}"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect')

mkdir -p "$OUT_DIR"

# 构造 MJ prompt:加 --ar --v --style 参数,有 refer 加 --cref --cw
MJ_PROMPT="$PROMPT_EN --ar $ASPECT --v 6 --style raw"

if [[ -n "$REFER" && -f "$REFER" ]]; then
  # 多数代理要求 refer 图先上传拿 URL,或者 base64
  # 这里假设代理支持本地路径上传(各家不一,按文档调)
  REFER_B64=$(base64 -w 0 "$REFER" 2>/dev/null || base64 "$REFER" | tr -d '\n')
  MJ_PROMPT="$MJ_PROMPT --cref data:image/png;base64,$REFER_B64 --cw 80"
fi

# 1. 提交
SUBMIT_RESPONSE=$(mktemp)
trap "rm -f $SUBMIT_RESPONSE" EXIT

curl -s "${BASE_URL}/imagine" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"prompt\": $(echo "$MJ_PROMPT" | jq -Rs .)}" \
  > "$SUBMIT_RESPONSE"

ERROR_MSG=$(jq -r '.error // .message // empty' "$SUBMIT_RESPONSE")
TASK_ID=$(jq -r '.task_id // .id // .data.id // empty' "$SUBMIT_RESPONSE")

if [[ -z "$TASK_ID" ]]; then
  echo "ERROR: MJ submit failed: $ERROR_MSG" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

echo "[mj] submitted task=$TASK_ID, polling..." >&2

# 2. 轮询(MJ 单图通常 20-60s)
IMAGE_URL=$(poll_task \
  --check-url "${BASE_URL}/task/${TASK_ID}" \
  --auth-header "Authorization: Bearer ${API_KEY}" \
  --status-jq '.status' \
  --done-values "SUCCESS,success,completed,FINISHED" \
  --fail-values "FAILED,failed,error,FAILURE" \
  --result-jq '.image_url // .result.url // .data.url' \
  --interval 5 \
  --timeout 300)

if [[ -z "$IMAGE_URL" ]]; then
  echo "ERROR: MJ poll returned empty URL" >&2
  exit 1
fi

# 3. 下载
curl -sL "$IMAGE_URL" -o "$OUT_DIR/$SHOT_ID.png"

if [[ ! -s "$OUT_DIR/$SHOT_ID.png" ]]; then
  echo "ERROR: downloaded image is empty" >&2
  exit 1
fi

# 4. 写伴随 .json
cat > "$OUT_DIR/$SHOT_ID.json" <<EOF
{
  "shot_id": "$SHOT_ID",
  "backend": "mj",
  "task_id": $(echo "$TASK_ID" | jq -Rs .),
  "image_url": $(echo "$IMAGE_URL" | jq -Rs .),
  "prompt": $(echo "$MJ_PROMPT" | jq -Rs .),
  "refer_image": $(echo "${REFER:-}" | jq -Rs .),
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.png" >&2
exit 0
```

- [ ] **Step 2: 加可执行权限 + 语法检查**

```bash
chmod +x skills/shot-to-image/scripts/adapters/mj.sh
bash -n skills/shot-to-image/scripts/adapters/mj.sh && echo "syntax OK"
```

- [ ] **Step 3: Commit**

```bash
git add skills/shot-to-image/scripts/adapters/mj.sh
git commit -m "feat(shot-to-image): add mj adapter (third-party proxy)"
```

---

### Task 1.2:写 adapters/replicate.sh

**Files:**
- Create: `skills/shot-to-image/scripts/adapters/replicate.sh`

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# adapters/replicate.sh — Replicate(FLUX 默认)
# 模型可通过 REPLICATE_MODEL_VERSION 覆盖,默认 black-forest-labs/flux-dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/poll.sh"

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

API_TOKEN="${REPLICATE_API_TOKEN:?ERROR: REPLICATE_API_TOKEN required}"
MODEL="${REPLICATE_MODEL_VERSION:-black-forest-labs/flux-dev}"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
NEGATIVE=$(echo "$PROMPT_JSON" | jq -r '.negative')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect')
SEED=$(echo "$PROMPT_JSON" | jq -r '.seed')

mkdir -p "$OUT_DIR"

# 构造 input
INPUT=$(jq -n \
  --arg p "$PROMPT_EN" \
  --arg n "$NEGATIVE" \
  --arg a "$ASPECT" \
  --argjson s "$SEED" \
  '{prompt: $p, negative_prompt: $n, aspect_ratio: $a, seed: $s, output_format: "png"}')

# 如果有 refer 图,加 image 字段(IP-Adapter)
if [[ -n "$REFER" && -f "$REFER" ]]; then
  REFER_B64=$(base64 -w 0 "$REFER" 2>/dev/null || base64 "$REFER" | tr -d '\n')
  INPUT=$(echo "$INPUT" | jq --arg img "data:image/png;base64,$REFER_B64" '. + {image: $img, ip_adapter_scale: 0.7}')
fi

# 1. 提交
SUBMIT_RESPONSE=$(mktemp)
trap "rm -f $SUBMIT_RESPONSE" EXIT

curl -s "https://api.replicate.com/v1/models/$MODEL/predictions" \
  -H "Authorization: Token ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"input\": $INPUT}" \
  > "$SUBMIT_RESPONSE"

PREDICTION_ID=$(jq -r '.id // empty' "$SUBMIT_RESPONSE")
GET_URL=$(jq -r '.urls.get // empty' "$SUBMIT_RESPONSE")

if [[ -z "$PREDICTION_ID" || -z "$GET_URL" ]]; then
  echo "ERROR: Replicate submit failed" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

echo "[replicate] submitted prediction=$PREDICTION_ID, polling..." >&2

# 2. 轮询
IMAGE_URL=$(poll_task \
  --check-url "$GET_URL" \
  --auth-header "Authorization: Token ${API_TOKEN}" \
  --status-jq '.status' \
  --done-values "succeeded" \
  --fail-values "failed,canceled" \
  --result-jq '.output | if type == "array" then .[0] else . end' \
  --interval 3 \
  --timeout 180)

# 3. 下载
curl -sL "$IMAGE_URL" -o "$OUT_DIR/$SHOT_ID.png"

# 4. 伴随 .json
cat > "$OUT_DIR/$SHOT_ID.json" <<EOF
{
  "shot_id": "$SHOT_ID",
  "backend": "replicate",
  "model": $(echo "$MODEL" | jq -Rs .),
  "prediction_id": $(echo "$PREDICTION_ID" | jq -Rs .),
  "image_url": $(echo "$IMAGE_URL" | jq -Rs .),
  "prompt": $(echo "$PROMPT_EN" | jq -Rs .),
  "refer_image": $(echo "${REFER:-}" | jq -Rs .),
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.png" >&2
exit 0
```

- [ ] **Step 2: 加权限 + 语法检查 + commit**

```bash
chmod +x skills/shot-to-image/scripts/adapters/replicate.sh
bash -n skills/shot-to-image/scripts/adapters/replicate.sh && echo "syntax OK"
git add skills/shot-to-image/scripts/adapters/replicate.sh
git commit -m "feat(shot-to-image): add replicate adapter (FLUX default)"
```

---

### Task 1.3:写 adapters/fal.sh

**Files:**
- Create: `skills/shot-to-image/scripts/adapters/fal.sh`

- [ ] **Step 1: 写脚本(结构类似 Replicate,API 不同)**

```bash
#!/usr/bin/env bash
# adapters/fal.sh — Fal.ai(FLUX 默认)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/poll.sh"

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

API_KEY="${FAL_KEY:?ERROR: FAL_KEY required}"
MODEL="${FAL_MODEL:-fal-ai/flux/dev}"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect')
SEED=$(echo "$PROMPT_JSON" | jq -r '.seed')

# Fal 用 image_size 而非 aspect_ratio
case "$ASPECT" in
  "9:16") IMAGE_SIZE="portrait_16_9" ;;
  "16:9") IMAGE_SIZE="landscape_16_9" ;;
  "1:1")  IMAGE_SIZE="square_hd" ;;
  *) IMAGE_SIZE="portrait_16_9" ;;
esac

mkdir -p "$OUT_DIR"

INPUT=$(jq -n \
  --arg p "$PROMPT_EN" \
  --arg s "$IMAGE_SIZE" \
  --argjson seed "$SEED" \
  '{prompt: $p, image_size: $s, seed: $seed, num_inference_steps: 28}')

if [[ -n "$REFER" && -f "$REFER" ]]; then
  REFER_B64=$(base64 -w 0 "$REFER" 2>/dev/null || base64 "$REFER" | tr -d '\n')
  INPUT=$(echo "$INPUT" | jq --arg img "data:image/png;base64,$REFER_B64" '. + {image_url: $img}')
fi

# Fal 同步 API(简单的小模型同步,慢的异步)
RESPONSE=$(mktemp)
trap "rm -f $RESPONSE" EXIT

curl -s "https://fal.run/$MODEL" \
  -H "Authorization: Key ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$INPUT" > "$RESPONSE"

IMAGE_URL=$(jq -r '.images[0].url // .image.url // empty' "$RESPONSE")

if [[ -z "$IMAGE_URL" ]]; then
  echo "ERROR: Fal response missing image URL" >&2
  cat "$RESPONSE" >&2
  exit 1
fi

curl -sL "$IMAGE_URL" -o "$OUT_DIR/$SHOT_ID.png"

cat > "$OUT_DIR/$SHOT_ID.json" <<EOF
{
  "shot_id": "$SHOT_ID",
  "backend": "fal",
  "model": $(echo "$MODEL" | jq -Rs .),
  "image_url": $(echo "$IMAGE_URL" | jq -Rs .),
  "prompt": $(echo "$PROMPT_EN" | jq -Rs .),
  "refer_image": $(echo "${REFER:-}" | jq -Rs .),
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.png" >&2
exit 0
```

- [ ] **Step 2: 加权限 + 语法检查 + commit**

```bash
chmod +x skills/shot-to-image/scripts/adapters/fal.sh
bash -n skills/shot-to-image/scripts/adapters/fal.sh && echo "syntax OK"
git add skills/shot-to-image/scripts/adapters/fal.sh
git commit -m "feat(shot-to-image): add fal adapter"
```

---

### Task 1.4:写 adapters/comfy.sh(本地 ComfyUI)

**Files:**
- Create: `skills/shot-to-image/scripts/adapters/comfy.sh`

- [ ] **Step 1: 写脚本(需要用户准备 workflow.json 模板,本脚本只做调用)**

```bash
#!/usr/bin/env bash
# adapters/comfy.sh — 本地 ComfyUI
# 用户需准备 workflow.json 模板,放在 ${COMFY_WORKFLOW:-./comfy-workflow.json}
# skill 把 prompt/seed/image 注入到 workflow 后提交

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/poll.sh"

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

if [[ ! -f "$WORKFLOW_FILE" ]]; then
  echo "ERROR: workflow file not found: $WORKFLOW_FILE" >&2
  echo "Set COMFY_WORKFLOW to your workflow JSON path." >&2
  echo "Tip: in ComfyUI UI, Settings > Enable Dev mode, then 'Save (API Format)' to export." >&2
  exit 1
fi

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
SEED=$(echo "$PROMPT_JSON" | jq -r '.seed')

mkdir -p "$OUT_DIR"

# 注入 prompt 和 seed 到 workflow
# 假设 workflow 里有标准节点:
#   - "6": CLIPTextEncode (positive prompt)
#   - "3": KSampler (seed)
#   - "10": LoadImage (可选,refer image)
# 用户的 workflow 如不一样,要按节点 ID 改 jq 路径

WORKFLOW=$(jq \
  --arg p "$PROMPT_EN" \
  --argjson s "$SEED" \
  '.["6"].inputs.text = $p | .["3"].inputs.seed = $s' \
  "$WORKFLOW_FILE")

if [[ -n "$REFER" && -f "$REFER" ]]; then
  # 通过 /upload/image 端点上传 refer 图
  UPLOAD_RESPONSE=$(curl -s -F "image=@${REFER}" "http://${COMFY_HOST}/upload/image")
  UPLOADED_NAME=$(echo "$UPLOAD_RESPONSE" | jq -r '.name // empty')
  if [[ -n "$UPLOADED_NAME" ]]; then
    WORKFLOW=$(echo "$WORKFLOW" | jq --arg n "$UPLOADED_NAME" '.["10"].inputs.image = $n')
  fi
fi

CLIENT_ID=$(uuidgen 2>/dev/null || echo "story-pipeline-$$")

# 1. 提交
SUBMIT_RESPONSE=$(mktemp)
trap "rm -f $SUBMIT_RESPONSE" EXIT

curl -s "http://${COMFY_HOST}/prompt" \
  -H "Content-Type: application/json" \
  -d "{\"prompt\": $WORKFLOW, \"client_id\": \"$CLIENT_ID\"}" \
  > "$SUBMIT_RESPONSE"

PROMPT_ID=$(jq -r '.prompt_id // empty' "$SUBMIT_RESPONSE")
if [[ -z "$PROMPT_ID" ]]; then
  echo "ERROR: Comfy submit failed" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

echo "[comfy] submitted prompt=$PROMPT_ID, polling..." >&2

# 2. 轮询 /history/<prompt_id>
HISTORY_URL="http://${COMFY_HOST}/history/${PROMPT_ID}"
ELAPSED=0
TIMEOUT=180
INTERVAL=2

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  HISTORY=$(curl -s "$HISTORY_URL")
  STATUS=$(echo "$HISTORY" | jq -r ".[\"$PROMPT_ID\"].status.completed // empty")
  if [[ "$STATUS" == "true" ]]; then
    break
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ "$STATUS" != "true" ]]; then
  echo "ERROR: Comfy task timeout" >&2
  exit 1
fi

# 3. 找输出图(SaveImage 节点的输出)
HISTORY=$(curl -s "$HISTORY_URL")
IMAGE_NAME=$(echo "$HISTORY" | jq -r ".[\"$PROMPT_ID\"].outputs | to_entries[].value.images[0].filename // empty" | head -n1)
SUBFOLDER=$(echo "$HISTORY" | jq -r ".[\"$PROMPT_ID\"].outputs | to_entries[].value.images[0].subfolder // empty" | head -n1)

if [[ -z "$IMAGE_NAME" ]]; then
  echo "ERROR: Comfy output image not found" >&2
  exit 1
fi

# 4. 下载
VIEW_URL="http://${COMFY_HOST}/view?filename=${IMAGE_NAME}&subfolder=${SUBFOLDER}&type=output"
curl -sL "$VIEW_URL" -o "$OUT_DIR/$SHOT_ID.png"

cat > "$OUT_DIR/$SHOT_ID.json" <<EOF
{
  "shot_id": "$SHOT_ID",
  "backend": "comfy",
  "workflow_file": $(echo "$WORKFLOW_FILE" | jq -Rs .),
  "prompt_id": $(echo "$PROMPT_ID" | jq -Rs .),
  "comfy_image": $(echo "$IMAGE_NAME" | jq -Rs .),
  "prompt": $(echo "$PROMPT_EN" | jq -Rs .),
  "seed": $SEED,
  "refer_image": $(echo "${REFER:-}" | jq -Rs .),
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.png" >&2
exit 0
```

- [ ] **Step 2: 加权限 + 语法检查 + commit**

```bash
chmod +x skills/shot-to-image/scripts/adapters/comfy.sh
bash -n skills/shot-to-image/scripts/adapters/comfy.sh && echo "syntax OK"
git add skills/shot-to-image/scripts/adapters/comfy.sh
git commit -m "feat(shot-to-image): add comfy adapter (local ComfyUI)"
```

---

## Phase 2:其余 video adapter

### Task 2.1:写 adapters/jimeng.sh(即梦/火山方舟)

**Files:**
- Create: `skills/image-to-video/scripts/adapters/jimeng.sh`

- [ ] **Step 1: 写脚本(结构同 kling,字段名按火山方舟 v3 API)**

```bash
#!/usr/bin/env bash
# adapters/jimeng.sh — 即梦/火山方舟

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
[[ -z "$IMAGE" || ! -f "$IMAGE" ]] && { echo "ERROR: image required and must exist" >&2; exit 2; }

API_KEY="${JIMENG_API_KEY:?ERROR: JIMENG_API_KEY required}"
BASE_URL="${JIMENG_BASE_URL:-https://ark.cn-beijing.volces.com}"
MODEL="${JIMENG_MODEL:-doubao-seedance-1.0-pro}"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
MOTION=$(echo "$PROMPT_JSON" | jq -r '.motion_prompt')
DURATION=$(echo "$PROMPT_JSON" | jq -r '.duration | tonumber | floor')

mkdir -p "$OUT_DIR"

IMAGE_B64=$(base64 -w 0 "$IMAGE" 2>/dev/null || base64 "$IMAGE" | tr -d '\n')
FULL_PROMPT="${PROMPT_EN}。${MOTION}"

# 1. 提交
SUBMIT_RESPONSE=$(mktemp)
trap "rm -f $SUBMIT_RESPONSE" EXIT

curl -s "${BASE_URL}/api/v3/contents/generations/tasks" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL}\",
    \"content\": [
      {\"type\": \"text\", \"text\": $(echo "$FULL_PROMPT" | jq -Rs .)},
      {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/png;base64,${IMAGE_B64}\"}}
    ]
  }" > "$SUBMIT_RESPONSE"

TASK_ID=$(jq -r '.id // .task_id // empty' "$SUBMIT_RESPONSE")
if [[ -z "$TASK_ID" ]]; then
  echo "ERROR: Jimeng submit failed" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

echo "[jimeng] submitted task=$TASK_ID, polling..." >&2

# 2. 轮询
VIDEO_URL=$(poll_task \
  --check-url "${BASE_URL}/api/v3/contents/generations/tasks/${TASK_ID}" \
  --auth-header "Authorization: Bearer ${API_KEY}" \
  --status-jq '.status' \
  --done-values "succeeded,completed" \
  --fail-values "failed,error" \
  --result-jq '.content.video_url // .outputs[0].url' \
  --interval 10 \
  --timeout 600)

# 3. 下载
curl -sL "$VIDEO_URL" -o "$OUT_DIR/$SHOT_ID.mp4"

cat > "$OUT_DIR/$SHOT_ID.json" <<EOF
{
  "shot_id": "$SHOT_ID",
  "backend": "jimeng",
  "task_id": $(echo "$TASK_ID" | jq -Rs .),
  "video_url": $(echo "$VIDEO_URL" | jq -Rs .),
  "duration": $DURATION,
  "input_image": $(echo "$IMAGE" | jq -Rs .),
  "prompt": $(echo "$FULL_PROMPT" | jq -Rs .),
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.mp4" >&2
exit 0
```

- [ ] **Step 2: 加权限 + 语法检查 + commit**

```bash
chmod +x skills/image-to-video/scripts/adapters/jimeng.sh
bash -n skills/image-to-video/scripts/adapters/jimeng.sh && echo "syntax OK"
git add skills/image-to-video/scripts/adapters/jimeng.sh
git commit -m "feat(image-to-video): add jimeng adapter"
```

---

### Task 2.2:写 adapters/runway.sh

**Files:**
- Create: `skills/image-to-video/scripts/adapters/runway.sh`

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# adapters/runway.sh — Runway Gen-3

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
[[ -z "$IMAGE" || ! -f "$IMAGE" ]] && { echo "ERROR: image required" >&2; exit 2; }

API_KEY="${RUNWAY_API_KEY:?ERROR: RUNWAY_API_KEY required}"
BASE_URL="https://api.dev.runwayml.com"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
MOTION=$(echo "$PROMPT_JSON" | jq -r '.motion_prompt')
DURATION=$(echo "$PROMPT_JSON" | jq -r '.duration | tonumber | floor')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect')

# Runway 只支持 5 或 10
[[ "$DURATION" -lt 8 ]] && DURATION=5 || DURATION=10

# Aspect → ratio 字符串
case "$ASPECT" in
  "9:16") RATIO="768:1280" ;;
  "16:9") RATIO="1280:768" ;;
  *) RATIO="768:1280" ;;
esac

mkdir -p "$OUT_DIR"

IMAGE_B64=$(base64 -w 0 "$IMAGE" 2>/dev/null || base64 "$IMAGE" | tr -d '\n')

# 1. 提交
SUBMIT_RESPONSE=$(mktemp)
trap "rm -f $SUBMIT_RESPONSE" EXIT

curl -s "${BASE_URL}/v1/image_to_video" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "X-Runway-Version: 2024-11-06" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gen3a_turbo\",
    \"promptImage\": \"data:image/png;base64,${IMAGE_B64}\",
    \"promptText\": $(echo "${PROMPT_EN}. ${MOTION}" | jq -Rs .),
    \"duration\": ${DURATION},
    \"ratio\": \"${RATIO}\"
  }" > "$SUBMIT_RESPONSE"

TASK_ID=$(jq -r '.id // empty' "$SUBMIT_RESPONSE")
if [[ -z "$TASK_ID" ]]; then
  echo "ERROR: Runway submit failed" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

echo "[runway] submitted task=$TASK_ID, polling..." >&2

# 2. 轮询
VIDEO_URL=$(poll_task \
  --check-url "${BASE_URL}/v1/tasks/${TASK_ID}" \
  --auth-header "Authorization: Bearer ${API_KEY}" \
  --status-jq '.status' \
  --done-values "SUCCEEDED" \
  --fail-values "FAILED,CANCELLED" \
  --result-jq '.output[0]' \
  --interval 10 \
  --timeout 600)

curl -sL "$VIDEO_URL" -o "$OUT_DIR/$SHOT_ID.mp4"

cat > "$OUT_DIR/$SHOT_ID.json" <<EOF
{
  "shot_id": "$SHOT_ID",
  "backend": "runway",
  "task_id": $(echo "$TASK_ID" | jq -Rs .),
  "video_url": $(echo "$VIDEO_URL" | jq -Rs .),
  "duration": $DURATION,
  "ratio": "$RATIO",
  "input_image": $(echo "$IMAGE" | jq -Rs .),
  "prompt": $(echo "${PROMPT_EN}. ${MOTION}" | jq -Rs .),
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.mp4" >&2
exit 0
```

- [ ] **Step 2: 加权限 + 语法检查 + commit**

```bash
chmod +x skills/image-to-video/scripts/adapters/runway.sh
bash -n skills/image-to-video/scripts/adapters/runway.sh && echo "syntax OK"
git add skills/image-to-video/scripts/adapters/runway.sh
git commit -m "feat(image-to-video): add runway adapter"
```

---

### Task 2.3:写 adapters/sora.sh 和 veo.sh(占位)

**Files:**
- Create: `skills/image-to-video/scripts/adapters/sora.sh`
- Create: `skills/image-to-video/scripts/adapters/veo.sh`

- [ ] **Step 1: 写 sora.sh 占位**

```bash
#!/usr/bin/env bash
# adapters/sora.sh — Sora 2(占位,API 对个人开发者尚未稳定开放)

cat <<'EOF' >&2
ERROR: sora adapter is a placeholder.

Sora 2 API is currently enterprise-only as of 2026. When OpenAI opens
the API to individuals, fill in this adapter following the same pattern
as adapters/kling.sh:

1. Submit task: POST $SORA_BASE_URL/v1/videos/generations
   with image (base64) + prompt + duration
2. Poll task: GET $SORA_BASE_URL/v1/videos/generations/$TASK_ID
3. Download result + write $SHOT_ID.mp4 + $SHOT_ID.json

Env vars expected: SORA_API_KEY, SORA_BASE_URL
EOF
exit 1
```

- [ ] **Step 2: 写 veo.sh 占位**

```bash
#!/usr/bin/env bash
# adapters/veo.sh — Google Veo(占位)

cat <<'EOF' >&2
ERROR: veo adapter is a placeholder.

Google Veo is accessible via Google AI Studio / Vertex AI as of 2026,
but the API surface depends on which product you have access to. Fill
in this adapter following adapters/kling.sh pattern when ready.

Env vars expected: VEO_API_KEY (and possibly VEO_PROJECT_ID)
EOF
exit 1
```

- [ ] **Step 3: 加权限(故意保持可执行,让 route.sh 知道这俩 adapter "存在",但调用必然 exit 1)**

```bash
chmod +x skills/image-to-video/scripts/adapters/sora.sh
chmod +x skills/image-to-video/scripts/adapters/veo.sh
```

- [ ] **Step 4: 调整 route.sh 让 sora/veo 占位时不自动选**

route.sh 的自动探测要跳过占位 adapter。打开 `skills/image-to-video/scripts/route.sh`,在 sora 探测分支加额外检查:

```bash
# sora/veo 是占位,即使 env 配了也不自动选(显式 VIDEO_BACKEND=sora 才用)
```

具体改:把现有的

```bash
  elif [[ -n "${SORA_API_KEY:-}" && -n "${SORA_BASE_URL:-}" ]] && [[ -x "$ADAPTERS_DIR/sora.sh" ]]; then
    BACKEND="sora"
  elif [[ -n "${VEO_API_KEY:-}" ]] && [[ -x "$ADAPTERS_DIR/veo.sh" ]]; then
    BACKEND="veo"
```

替换为(自动探测时跳过占位 adapter):

```bash
  # sora/veo 是占位,需要显式 VIDEO_BACKEND=sora 才用,自动探测不选
```

但显式 `VIDEO_BACKEND=sora` 仍然走 sora.sh(脚本里报错 exit 1)。这是有意为之 — 用户要明知它没实现还要试,就让他撞个明白错。

- [ ] **Step 5: Commit**

```bash
git add skills/image-to-video/scripts/adapters/sora.sh \
        skills/image-to-video/scripts/adapters/veo.sh \
        skills/image-to-video/scripts/route.sh
git commit -m "feat(image-to-video): add sora/veo placeholder adapters"
```

---

## Phase 3:state.sh(编排状态管理)

### Task 3.1:写 scripts/state.sh

**Files:**
- Create: `skills/story-pipeline/scripts/state.sh`

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# state.sh — .pipeline.state.json 读写工具

# 用法(source 进来用,而不是直接执行):
#   source state.sh
#   state_init <episode_dir> <episode_num>
#   state_set_gate <episode_dir> <gate> <status>
#   state_get_current_gate <episode_dir>
#   state_get_gate_status <episode_dir> <gate>
#   state_reset_from <episode_dir> <gate>

STATE_FILE_NAME=".pipeline.state.json"

# 初始化 state.json(如果不存在)
state_init() {
  local dir="$1" episode="$2" img_backend="${3:-prompt-only}" video_backend="${4:-prompt-only}" aspect="${5:-9:16}"
  local file="$dir/$STATE_FILE_NAME"
  
  if [[ -f "$file" ]]; then
    return 0  # 已存在,不覆盖
  fi
  
  cat > "$file" <<EOF
{
  "episode": $episode,
  "current_gate": "gate-0",
  "gates": {
    "gate-0": {"status": "pending"},
    "gate-1": {"status": "pending"},
    "gate-2": {"status": "pending"},
    "gate-3": {"status": "pending"},
    "gate-4": {"status": "pending"},
    "gate-5": {"status": "pending"},
    "gate-6": {"status": "pending"}
  },
  "config": {
    "img_backend": "$img_backend",
    "video_backend": "$video_backend",
    "aspect": "$aspect"
  },
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# 设置某 gate 状态
state_set_gate() {
  local dir="$1" gate="$2" status="$3"
  local file="$dir/$STATE_FILE_NAME"
  local tmp
  tmp=$(mktemp)
  
  jq --arg g "$gate" --arg s "$status" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.gates[$g].status = $s | .gates[$g].updated_at = $t | .current_gate = $g' \
    "$file" > "$tmp" && mv "$tmp" "$file"
}

# 给某 gate 加 artifact
state_add_artifact() {
  local dir="$1" gate="$2" artifact="$3"
  local file="$dir/$STATE_FILE_NAME"
  local tmp
  tmp=$(mktemp)
  
  jq --arg g "$gate" --arg a "$artifact" \
    '.gates[$g].artifacts = (.gates[$g].artifacts // []) + [$a]' \
    "$file" > "$tmp" && mv "$tmp" "$file"
}

# 读 current_gate
state_get_current_gate() {
  local dir="$1"
  local file="$dir/$STATE_FILE_NAME"
  jq -r '.current_gate' "$file"
}

# 读某 gate 状态
state_get_gate_status() {
  local dir="$1" gate="$2"
  local file="$dir/$STATE_FILE_NAME"
  jq -r ".gates[\"$gate\"].status" "$file"
}

# 从某 gate 起重置(把它和后续闸门置 pending,产物保留但标记 stale)
state_reset_from() {
  local dir="$1" from_gate="$2"
  local file="$dir/$STATE_FILE_NAME"
  local gate_num="${from_gate#gate-}"
  local tmp
  tmp=$(mktemp)
  
  jq --argjson n "$gate_num" '
    .gates | to_entries | map(
      if (.key | sub("gate-"; "") | tonumber) >= $n then
        .value.status = "pending"
        | .value.previous_artifacts = (.value.artifacts // [])
        | del(.value.artifacts)
      else .
      end
    ) | from_entries | {gates: .}
  ' "$file" > "$tmp"
  
  jq --slurpfile gates "$tmp" --arg g "$from_gate" \
    '.gates = $gates[0].gates | .current_gate = $g' \
    "$file" > "${tmp}.2" && mv "${tmp}.2" "$file"
  rm -f "$tmp"
}

# 读 config 字段
state_get_config() {
  local dir="$1" key="$2"
  local file="$dir/$STATE_FILE_NAME"
  jq -r ".config[\"$key\"] // empty" "$file"
}
```

- [ ] **Step 2: 测试**

```bash
chmod +x skills/story-pipeline/scripts/state.sh

# source 测试
mkdir -p /tmp/test-state
source skills/story-pipeline/scripts/state.sh

state_init /tmp/test-state 1 mj kling 9:16
cat /tmp/test-state/.pipeline.state.json | jq .

state_set_gate /tmp/test-state gate-1 approved
state_add_artifact /tmp/test-state gate-1 拍摄本.md

[[ "$(state_get_current_gate /tmp/test-state)" == "gate-1" ]] && echo "current_gate OK" || echo "FAIL"
[[ "$(state_get_gate_status /tmp/test-state gate-1)" == "approved" ]] && echo "gate-1 status OK" || echo "FAIL"
[[ "$(state_get_config /tmp/test-state img_backend)" == "mj" ]] && echo "config OK" || echo "FAIL"

state_reset_from /tmp/test-state gate-1
[[ "$(state_get_gate_status /tmp/test-state gate-1)" == "pending" ]] && echo "reset OK" || echo "FAIL"

rm -rf /tmp/test-state
```

Expected: 全部 OK。

- [ ] **Step 3: Commit**

```bash
git add skills/story-pipeline/scripts/state.sh
git commit -m "feat(story-pipeline): add state.sh for .pipeline.state.json"
```

---

## Phase 4:references + SKILL.md

### Task 4.1:写 references/gate-workflow.md

**Files:**
- Create: `skills/story-pipeline/references/gate-workflow.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 闸门工作流

6 个闸门,每个闸门由一个子 skill 执行,完成后暂停等用户确认。

---

## 闸门表

| Gate | 名 | 执行 skill | 产物 |
|---|---|---|---|
| gate-0 | 准备 | (主线程) | 集划分确认 + 后端探测 + 预算估算 |
| gate-1 | 拍摄本 | story-to-script | 拍摄本.md |
| gate-2 | 镜头表 | script-to-shot | 镜头表.md + 镜头表.json |
| gate-3 | 角色卡 | shot-to-image (Phase 2 only) | 角色卡/*.png + .json |
| gate-4 | 镜头图 | shot-to-image (Phase 3+) | 镜头图/*.png + .json |
| gate-5 | 镜头视频 | image-to-video | 镜头视频/*.mp4 + .json |
| gate-6 | 交付包 | (主线程) | README.md + 字幕脚本.txt |

---

## 闸门状态枚举

- `pending`:未开始
- `running`:正在执行
- `waiting_approval`:执行完成,等用户确认
- `approved`:用户批准,可进下一闸
- `stale`:已被回退,产物保留但下游闸门重置

---

## 子 skill 调用契约

编排 skill 调子 skill 时,设环境变量:

```bash
export STORY_PIPELINE_EPISODE=1
export STORY_PIPELINE_EPISODE_DIR="/path/to/{书名}/短剧/第001集"
export STORY_PIPELINE_GATE=gate-2
export IMG_BACKEND=...   # 从 state.json config 读
export VIDEO_BACKEND=...
```

子 skill 通过这些环境变量知道:
- 自己在编排里跑(vs 独立跑)
- 产物落到指定 episode_dir
- 不重新询问后端(用 config 里定的)

---

## 暂停与续跑

闸门完成 → 编排 skill 把 state.json 的 current_gate 置为 `waiting_approval` → 输出产物路径 + 评估 + 等待用户响应。

用户响应"继续" → 编排 skill 把这一闸置 approved,推进到下一闸。

用户响应"重做" → 编排 skill 跑 state_reset_from <gate>,重新执行这一闸。

用户响应"退出" → 编排 skill 不动 state,直接退出。下次启动续跑。

---

## 续跑逻辑

`/story-pipeline` 启动时:
1. 探测当前目录的 `{书名}/短剧/{第NNN集}/.pipeline.state.json`
   - 如果有多集 in_progress,询问用户跑哪集
   - 没有 → 跳到 gate-0 准备阶段
2. 读 current_gate
3. 从 current_gate 续跑

---

## 回退

`/story-pipeline --redo gate-2` → 在指定 episode 上跑 `state_reset_from gate-2` → 进入 gate-2

---

## 跳过

`/story-pipeline --skip gate-5` → 在当前 episode 把 gate-5 置 approved(无产物),推进到 gate-6
````

- [ ] **Step 2: Commit**

```bash
git add skills/story-pipeline/references/gate-workflow.md
git commit -m "docs(story-pipeline): add gate workflow guide"
```

---

### Task 4.2:写 references/state-schema.md

**Files:**
- Create: `skills/story-pipeline/references/state-schema.md`

- [ ] **Step 1: 写完整文件**

````markdown
# state.json schema

每集根目录 `.pipeline.state.json`:

```json
{
  "episode": 1,
  "current_gate": "gate-4",
  "gates": {
    "gate-0": {"status": "approved", "updated_at": "..."},
    "gate-1": {"status": "approved", "updated_at": "...", "artifacts": ["拍摄本.md"]},
    "gate-2": {"status": "approved", "updated_at": "...", "artifacts": ["镜头表.md", "镜头表.json"]},
    "gate-3": {"status": "approved", "updated_at": "...", "artifacts": ["角色卡/沈栀.png", "角色卡/司长.png"]},
    "gate-4": {"status": "waiting_approval", "updated_at": "...", "shots_total": 42, "shots_done": 40, "shots_failed": 2},
    "gate-5": {"status": "pending"},
    "gate-6": {"status": "pending"}
  },
  "config": {
    "img_backend": "mj",
    "video_backend": "kling",
    "aspect": "9:16",
    "duration_default": 5
  },
  "created_at": "2026-05-20T10:00:00Z"
}
```

---

## 字段说明

- `episode`:集号(int)
- `current_gate`:当前 in_progress 或 waiting_approval 的闸门
- `gates.<gate>`:每个闸门的状态对象
  - `status`:pending / running / waiting_approval / approved / stale
  - `updated_at`:ISO 8601 UTC
  - `artifacts`(可选):该闸门产出的文件相对路径列表
  - 闸门可加额外字段(如 gate-4 的 `shots_total/shots_done/shots_failed`)
- `config`:本集全局配置
  - `img_backend` / `video_backend`:用哪个后端(用户在 gate-0 决定)
  - `aspect`:9:16 或 16:9
  - `duration_default`:每镜默认时长(秒)
- `created_at`:state 创建时间

---

## 闸门特有字段

### gate-0(准备)
无额外字段。

### gate-1(拍摄本)
`artifacts`: `["拍摄本.md"]` 或 `["拍摄本.md", "分镜本.md"]`

### gate-2(镜头表)
`artifacts`: `["镜头表.md", "镜头表.json"]`
`total_shots`: 镜头总数(int)
`total_duration`: 总时长秒数(float)

### gate-3(角色卡)
`artifacts`: 每个角色一项,如 `["角色卡/沈栀.png", "角色卡/司长.png"]`(共享目录,相对于书目录而非集目录)
`characters_total`: int
`characters_done`: int

### gate-4(镜头图)
`shots_total`: int
`shots_done`: int
`shots_failed`: int
`failed_shot_ids`: ["S017", "S023"]

### gate-5(镜头视频)
同 gate-4 结构,但单位是视频片段
`total_video_duration`: float(实际产出视频总时长)

### gate-6(交付包)
`artifacts`: `["README.md", "字幕脚本.txt", "_manifest.json"]`

---

## 并发与文件锁

本流水线假定单 episode 单进程跑。如果用户同时跑两集(两个 terminal):
- 两集是独立目录,各自 state.json,互不干扰
- 但生图/生视频 API 限速可能冲突 → 用户自己控并发

如果同一 episode 被两个进程同时跑 → 行为未定义,后写者赢。implementation 阶段如果有需求可以加文件锁,默认不做。
````

- [ ] **Step 2: Commit**

```bash
git add skills/story-pipeline/references/state-schema.md
git commit -m "docs(story-pipeline): add state.json schema"
```

---

### Task 4.3:写 story-pipeline 的 SKILL.md

**Files:**
- Create: `skills/story-pipeline/SKILL.md`

- [ ] **Step 1: 写完整文件**

````markdown
---
name: story-pipeline
version: 1.0.0
description: |
  小说转视频编排器。6 个分步闸门(剧本/镜头表/角色卡/镜头图/镜头视频/交付包),每闸暂停等用户确认,支持续跑和回退。
  触发方式:/story-pipeline、/小说转视频、「拍短剧」「开拍」「跑流水线」
metadata:
  openclaw:
    requires:
      bins:
        - jq
        - curl
    source: https://github.com/worldwonderer/oh-story-claudecode
---

# story-pipeline:小说转视频编排器

你是流水线编排者。串起 5 个子 skill,在每个阶段产物完成后暂停,等用户确认才推进。

---

## 核心方法

**分步闸门 + 状态持久化。** 6 个闸门(参考 [references/gate-workflow.md](references/gate-workflow.md)),每集一份 [state.json](references/state-schema.md),支持续跑和回退。

---

## Phase 1:启动决策

### 探测续跑还是新跑

```bash
# 查当前书目录的所有 in-progress episode
find {当前目录}/短剧 -name ".pipeline.state.json" 2>/dev/null
```

- 找到 1 个 → 询问用户:"发现第 NNN 集还在 gate-X,要续跑吗?"
- 找到多个 → 列出让用户选
- 找不到 → 进 gate-0 启动新跑

### 命令行参数

- `/story-pipeline` → 续跑或新跑
- `/story-pipeline --episode 3` → 指定续跑第 3 集
- `/story-pipeline --redo gate-2` → 回退当前 episode 到 gate-2 重跑
- `/story-pipeline --skip gate-5` → 跳过 gate-5(不跑视频,直接到交付)
- `/story-pipeline --new` → 强制开新集

---

## Phase 2:gate-0 准备

```bash
source ./scripts/state.sh
```

### 集划分

调 `story-to-script` 的 Phase 1 集划分逻辑(智能识别 long-write / 独立模式),用户决定:
- 转哪几章
- 几章 = 1 集
- 横屏 / 竖屏
- 改编强度

### 后端探测

```bash
# 探测 image / video backend
IMG_BACKEND_DETECTED=$(./skills/shot-to-image/scripts/route.sh --dry-run 2>&1 | grep dispatching | sed 's/.*backend=//')
VIDEO_BACKEND_DETECTED=$(./skills/image-to-video/scripts/route.sh --dry-run 2>&1 | grep dispatching | sed 's/.*backend=//')
```

(`--dry-run` 在 route.sh 还没实现这个 flag — 这是简化伪代码,实际操作直接读环境变量决策。)

告知用户:
- 检测到的图后端、视频后端
- 全集预算估算
- 询问是否继续 / 是否换后端

### 创建 state.json

```bash
EPISODE_DIR={工作根}/短剧/第NNN集
mkdir -p "$EPISODE_DIR"
state_init "$EPISODE_DIR" $EPISODE_NUM "$IMG_BACKEND" "$VIDEO_BACKEND" "$ASPECT"
state_set_gate "$EPISODE_DIR" gate-0 approved
```

---

## Phase 3:gate-1 → gate-5 循环

通用模式:

```bash
for GATE in gate-1 gate-2 gate-3 gate-4 gate-5; do
  CURRENT=$(state_get_current_gate "$EPISODE_DIR")
  
  # 跳到 current_gate 起的位置(续跑)
  [[ "$GATE" < "$CURRENT" ]] && continue
  
  state_set_gate "$EPISODE_DIR" "$GATE" running
  
  # 调对应子 skill(带环境变量)
  STORY_PIPELINE_EPISODE_DIR="$EPISODE_DIR" \
  STORY_PIPELINE_GATE="$GATE" \
  IMG_BACKEND="$(state_get_config "$EPISODE_DIR" img_backend)" \
  VIDEO_BACKEND="$(state_get_config "$EPISODE_DIR" video_backend)" \
    {对应子 skill 调用}
  
  state_set_gate "$EPISODE_DIR" "$GATE" waiting_approval
  
  # 输出产物 + 评估 + 等用户响应
  echo "$GATE 完成,产物:..."
  echo "请确认(继续 / 重做 / 退出):"
  read RESPONSE
  
  case "$RESPONSE" in
    继续) state_set_gate "$EPISODE_DIR" "$GATE" approved ;;
    重做) state_reset_from "$EPISODE_DIR" "$GATE" ;;
    退出) exit 0 ;;
  esac
done
```

### gate-1:拍摄本(story-to-script)

调:`/story-to-script` 的 Phase 2-5(skip Phase 1 集划分,因为 gate-0 已做)
产物:`$EPISODE_DIR/拍摄本.md`(可选 分镜本.md)

### gate-2:镜头表(script-to-shot)

调:`/script-to-shot` Phase 1-5
产物:`$EPISODE_DIR/镜头表.md` + `镜头表.json`(校验通过)

### gate-3:角色卡(shot-to-image Phase 2)

调:`/shot-to-image` 只跑 Phase 1(后端选)+ Phase 2(角色卡预生成)
产物:`{书名}/短剧/角色卡/*.png` + `.json`

### gate-4:镜头图(shot-to-image Phase 3+)

调:`/shot-to-image` 跳过 Phase 2(角色卡已就绪),跑 Phase 3-5
产物:`$EPISODE_DIR/镜头图/*.png` + `.json`

### gate-5:镜头视频(image-to-video)

调:`/image-to-video` 全 Phase
产物:`$EPISODE_DIR/镜头视频/*.mp4` + `.json` + `_manifest.json` + `字幕脚本.txt`

---

## Phase 4:gate-6 交付包

汇总生成 `$EPISODE_DIR/README.md`:

```markdown
# 第 NNN 集 交付包

## 镜头清单
{从 _manifest.json 抽出来的镜号 + 时长 + 文件路径表}

## 字幕脚本
见 字幕脚本.txt

## 后期工作流
1. 打开剪映/Pr,新建 9:16(或 16:9)项目
2. 按文件名顺序导入镜头视频/
3. 加 BGM,挑 {根据 mood 推荐的 BGM 类型}
4. 用 字幕脚本.txt 加字幕轨
5. OS 段用剪映 TTS(古风男/女声),其他对白可不加配音(让画面+字幕承担)
6. 输出参数:见 references/post-production-handoff.md

## 统计
- 总镜数:{N}
- 视频总时长:{X.Y}s
- 估算成片时长(加转场+字幕):{X.Y}s × 1.1
```

完成 → `state_set_gate $EPISODE_DIR gate-6 approved`。

---

## Phase 5:收尾

- 打印总成本(从各 .json 里 backend 字段累加)
- 询问用户是否继续下一集:`/story-pipeline --episode {NEXT}`
- 告诉用户产物根路径

---

## 参考资料索引

| 场景 | 文件 |
|---|---|
| 闸门工作流 | [references/gate-workflow.md](references/gate-workflow.md) |
| state.json schema | [references/state-schema.md](references/state-schema.md) |
| 子 skill 内部细节 | 各子 skill 的 SKILL.md |

---

## 流程衔接

| 时机 | 跳转 | 命令 |
|---|---|---|
| 单步出错 | 直接调对应单 skill 修 | `/shot-to-image --redo S017` |
| 单独跑某 skill 不走编排 | 直接调 | `/script-to-shot` |
| 流水线完了想继续下一集 | 重新跑 | `/story-pipeline --new` |

---

## 语言

- 跟随用户的语言回复
- 中文回复遵循《中文文案排版指北》
````

- [ ] **Step 2: Commit**

```bash
git add skills/story-pipeline/SKILL.md
git commit -m "feat(story-pipeline): add main SKILL.md"
```

---

## Phase 5:/story 路由整合

### Task 5.1:更新 skills/story/SKILL.md

**Files:**
- Modify: `skills/story/SKILL.md`

- [ ] **Step 1: 读现有 SKILL.md 找到流水线表的位置**

```bash
grep -n "流水线\|pipeline\|story-long\|story-short" skills/story/SKILL.md | head -20
```

- [ ] **Step 2: 在现有流水线表末尾追加"影视化"流水线**

按现有表格 schema 追加:

```markdown
| 影视化.剧本 | story-to-script | 「转剧本」「改编」「改成短剧」 |
| 影视化.分镜 | script-to-shot | 「分镜」「画分镜」「拆镜头」 |
| 影视化.出图 | shot-to-image | 「生镜头图」「出图」 |
| 影视化.生视频 | image-to-video | 「图生视频」「出视频」 |
| 影视化.全流程 | story-pipeline | 「拍短剧」「开拍」「跑流水线」「小说转视频」 |
```

(具体格式参照现有表中 story-long-write 等条目的样式 — 列名可能不同,按实际调整。)

- [ ] **Step 3: 在 /story 路由匹配逻辑里加新关键词**

如果现有 SKILL.md 有"关键词→skill"的 dispatch 逻辑(if/else 或 case),加上:

```
- 关键词含 "拍短剧" / "开拍" / "跑流水线" / "小说转视频" → /story-pipeline
- 关键词含 "转剧本" / "改编" → /story-to-script
- 关键词含 "分镜" / "拆镜头" → /script-to-shot
- 关键词含 "生镜头图" / "出图" → /shot-to-image
- 关键词含 "图生视频" / "出视频" → /image-to-video
```

如果用户给的关键词命中"影视化全流程",优先推 story-pipeline;命中中间环节,推单 skill 并附 "你也可以跑 /story-pipeline 走完整流程"。

- [ ] **Step 4: Commit**

```bash
git add skills/story/SKILL.md
git commit -m "feat(story): integrate novel-to-video skills into router"
```

---

### Task 5.2:在 story-long-write 末尾加跳转提示

**Files:**
- Modify: `skills/story-long-write/SKILL.md`

- [ ] **Step 1: 找到 Phase 5(质量检查)末尾**

```bash
grep -n "Phase 5\|质量检查\|流程衔接" skills/story-long-write/SKILL.md | head
```

- [ ] **Step 2: 在 Phase 5 末尾(或"流程衔接"表格)加一行**

按现有"流程衔接"表格 schema 追加(`grep -A 3 "流程衔接" skills/story-long-write/SKILL.md` 看 schema):

```markdown
| 想拍成短剧 | story-pipeline 或 story-to-script | `/story-pipeline` 或 `/story-to-script` |
```

- [ ] **Step 3: Commit**

```bash
git add skills/story-long-write/SKILL.md
git commit -m "docs(story-long-write): add cross-link to novel-to-video pipeline"
```

---

## Phase 6:端到端集成测试

### Task 6.1:全流程 prompt-only 跑通

**Files:**
- 无新建

- [ ] **Step 1: 准备 mock long-write 项目**

```bash
mkdir -p /tmp/integration-test/{设定/角色,大纲,正文,追踪}
cp tests/fixtures/novel-sample-chapter.md /tmp/integration-test/正文/第001章_雨夜.md
cat > /tmp/integration-test/设定/角色/沈栀.md <<'EOF'
# 沈栀

- 年龄:二十出头
- 外貌:长发及腰,左眉一道旧疤
- 性格:平静、隐忍
EOF
cat > /tmp/integration-test/设定/角色/司长.md <<'EOF'
# 司长

- 年龄:五十岁
- 性格:谨慎、世故
EOF
```

- [ ] **Step 2: 在 mock 目录跑 /story-pipeline,全部 backend 用 prompt-only**

```bash
cd /tmp/integration-test
export IMG_BACKEND=prompt-only
export VIDEO_BACKEND=prompt-only
```

模拟跑(在 Claude Code 里):
```
/story-pipeline
```

跟着分步闸门走:
- gate-0:确认转第 1 章 → 1 集,竖屏,改编强度"节奏优先"
- gate-1 完成 → 看 `短剧/第001集/拍摄本.md` → 批继续
- gate-2 完成 → 跑 validator 通过 → 批继续
- gate-3 完成 → 角色卡 .json 生成(prompt-only 模式无 .png)→ 批继续
- gate-4 完成 → 提示词文件生成 → 批继续
- gate-5 完成 → 视频提示词文件生成 → 批继续
- gate-6 完成 → README.md + 字幕脚本.txt 生成

- [ ] **Step 3: 校验产物**

```bash
ls /tmp/integration-test/短剧/
ls /tmp/integration-test/短剧/角色卡/
ls /tmp/integration-test/短剧/第001集/
cat /tmp/integration-test/短剧/第001集/.pipeline.state.json | jq .
cat /tmp/integration-test/短剧/第001集/README.md
```

Expected:
- 短剧/ 下有 角色卡/ + 第001集/
- 第001集/ 下有:拍摄本.md / 镜头表.md / 镜头表.json / 提示词/ / 提示词视频/ / 镜头图/(只有 .json,无 .png) / 镜头视频/(只有 .json,无 .mp4) / .pipeline.state.json / README.md / 字幕脚本.txt / _manifest.json
- state.json 的 gate-0 ~ gate-6 全部 approved

- [ ] **Step 4: 测试续跑**

```bash
# 删 gate-5/6 状态模拟中断
jq '.gates["gate-5"].status = "waiting_approval" | .current_gate = "gate-5"' \
  /tmp/integration-test/短剧/第001集/.pipeline.state.json \
  > /tmp/test-state-modified.json
mv /tmp/test-state-modified.json /tmp/integration-test/短剧/第001集/.pipeline.state.json
```

再跑:
```
/story-pipeline
```

Expected: skill 探测到 gate-5 waiting_approval,询问"续跑还是新跑",选续跑 → 重跑 gate-5。

- [ ] **Step 5: 测试回退**

```
/story-pipeline --redo gate-3
```

Expected: state.json 中 gate-3 至 gate-6 都置 pending,current_gate = gate-3,然后从 gate-3 开始重跑。

- [ ] **Step 6: 清理 + commit(如有改动)**

```bash
cd -
rm -rf /tmp/integration-test
```

如 SKILL.md 或脚本有改动:
```bash
git add skills/story-pipeline
git commit -m "fix(story-pipeline): refine based on integration test"
```

---

### Task 6.2:测试单 skill 独立使用不写 state

**Files:**
- 无新建

- [ ] **Step 1: 准备 mock,不通过 pipeline 直接跑单 skill**

```bash
mkdir -p /tmp/test-standalone/短剧/第001集
cp tests/fixtures/expected-shotlist.json /tmp/test-standalone/短剧/第001集/镜头表.json
cd /tmp/test-standalone
```

- [ ] **Step 2: 单跑 /shot-to-image,不带 pipeline 环境变量**

```
/shot-to-image 短剧/第001集/镜头表.json
```

Expected:
- 产物落到 `短剧/第001集/镜头图/`、`短剧/角色卡/`、`短剧/第001集/提示词/`
- **不**生成 `.pipeline.state.json`

```bash
ls /tmp/test-standalone/短剧/第001集/ | grep state || echo "no state, OK"
```

Expected: 输出 `no state, OK`

- [ ] **Step 3: 清理**

```bash
cd -
rm -rf /tmp/test-standalone
```

---

### Task 6.3:更新 README 列出影视化流水线

**Files:**
- Modify: `README.md`
- Modify: `README_EN.md`

- [ ] **Step 1: 在 README 的 skill 列表追加 5 个新 skill**

按现有格式(参照 `story-long-write` 等条目),追加:

中文 README.md:
```markdown
### 影视化流水线

- **/story-to-script** — 小说转剧本(中文短剧拍摄本)
- **/script-to-shot** — 剧本转镜头(结构化镜头表 + 英文画面描述)
- **/shot-to-image** — 镜头转图片(含角色卡预生成,支持 6 个生图后端)
- **/image-to-video** — 图片转视频(支持 5 个生视频后端,可灵/即梦/Runway/Sora/Veo)
- **/story-pipeline** — 5 个 skill 编排,6 个分步闸门
```

英文 README_EN.md 对应英文版。

- [ ] **Step 2: Commit**

```bash
git add README.md README_EN.md
git commit -m "docs: add novel-to-video pipeline section to READMEs"
```

---

## Plan 4 完成验收

跑通以下流程 → Plan 4 验收通过,整条流水线 ship:

1. `/story-pipeline` 在 long-write mock 项目里跑完全部 6 个闸门(用 prompt-only 后端)
2. 续跑:从中断的 gate 继续
3. 回退:`--redo gate-N` 重跑指定闸门
4. 单 skill 独立使用不写 state.json
5. `/story` 路由能把"拍短剧"分发到 `/story-pipeline`
6. README 提到了 5 个新 skill

至此,小说转视频影视化流水线全部 5 个 skill + 适配层 + 编排器全部落地。

---

## 整条流水线交付清单(Plan 1-4 累计)

跑完 4 个 plan 后,项目新增:
- 5 个 SKILL.md
- 17+ 份 references 文档(领域知识)
- 11 个 bash adapter(image:gpt-image, mj, replicate, fal, comfy, prompt-only;video:kling, jimeng, runway, prompt-only;占位:sora, veo)
- 3 个共用 lib 脚本(state.sh、json.sh、poll.sh)
- 2 个 route.sh(image / video)
- 1 个 character_card.sh
- 1 个 validate_shotlist.sh
- 5 个 marketplace.json 条目
- `/story` 路由集成
- `story-long-write` 跳转点
- README 文档更新
