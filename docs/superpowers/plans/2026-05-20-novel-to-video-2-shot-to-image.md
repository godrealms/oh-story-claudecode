# 小说转视频流水线 Plan 2:shot-to-image

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 `shot-to-image` skill — 把 `镜头表.json` 转成 `镜头图/*.png`,含角色卡预生成 + 复用,通过适配层支持 GPT-Image-2(实现)和 prompt-only(实现)。其余适配器(MJ/Replicate/Fal/Comfy)留给 Plan 4。

**Architecture:** SKILL.md 主体 + references/ 拆领域知识 + scripts/ 含 lib(共用工具)+ route.sh(分发)+ adapters/(每后端一个)。Adapter 统一 stdin JSON 契约,加一个 adapter 就是加一个 .sh + 在 route.sh 加一行 case。

**Tech Stack:** bash 4+ / jq / curl / base64 / 复用 story-cover 的 GPT-Image-2 调用模式

**前置:** Plan 1 完成(`script-to-shot` 能产 `镜头表.json`)

---

## File Structure

**新建**:
- `skills/shot-to-image/SKILL.md`
- `skills/shot-to-image/references/prompt-construction.md`
- `skills/shot-to-image/references/backend-cheatsheet.md`
- `skills/shot-to-image/references/character-consistency.md`
- `skills/shot-to-image/references/failure-modes.md`
- `skills/shot-to-image/references/cost-table.md`
- `skills/shot-to-image/scripts/route.sh`
- `skills/shot-to-image/scripts/lib/json.sh`
- `skills/shot-to-image/scripts/lib/poll.sh`
- `skills/shot-to-image/scripts/adapters/prompt_only.sh`
- `skills/shot-to-image/scripts/adapters/gpt_image.sh`
- `skills/shot-to-image/scripts/character_card.sh`(角色卡预生成入口)
- `tests/fixtures/shot-to-image/test-shotlist.json`(已含角色的小镜头表)

**修改**:
- `.claude-plugin/marketplace.json`(注册 shot-to-image)

---

## Phase 0:注册与骨架

### Task 0.1:在 marketplace.json 注册 shot-to-image

**Files:**
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: 在 plugins 数组末尾追加(`script-to-shot` 之后)**

```json
,
    {
      "name": "shot-to-image",
      "description": "镜头转图片。把镜头表.json 转成镜头图,含角色卡预生成 + 复用,支持多生图后端(GPT-Image-2 / MJ / Replicate / Fal / ComfyUI / prompt-only)。",
      "source": "./",
      "strict": false,
      "version": "1.0.0",
      "category": "novel-video",
      "keywords": ["image", "storyboard-image", "镜头图", "GPT-Image", "Midjourney", "FLUX", "chinese"],
      "skills": ["./skills/shot-to-image"]
    }
```

- [ ] **Step 2: 校验**

Run: `jq '.plugins[] | select(.name == "shot-to-image") | .name' .claude-plugin/marketplace.json`
Expected: `"shot-to-image"`

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/marketplace.json
git commit -m "chore: register shot-to-image in marketplace"
```

---

### Task 0.2:创建目录骨架

**Files:**
- Create: 各目录的 .gitkeep

- [ ] **Step 1: 创建目录**

```bash
mkdir -p skills/shot-to-image/references
mkdir -p skills/shot-to-image/scripts/adapters
mkdir -p skills/shot-to-image/scripts/lib
touch skills/shot-to-image/references/.gitkeep
touch skills/shot-to-image/scripts/adapters/.gitkeep
touch skills/shot-to-image/scripts/lib/.gitkeep
```

- [ ] **Step 2: Commit**

```bash
git add skills/shot-to-image
git commit -m "chore: scaffold shot-to-image dirs"
```

---

## Phase 1:lib(共用工具)

### Task 1.1:写 lib/json.sh(jq 包装)

**Files:**
- Create: `skills/shot-to-image/scripts/lib/json.sh`

- [ ] **Step 1: 写脚本**

```bash
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
```

- [ ] **Step 2: 测试**

```bash
source skills/shot-to-image/scripts/lib/json.sh

# 测 json_get
echo '{"foo": "bar"}' > /tmp/t.json
[[ "$(json_get /tmp/t.json '.foo')" == "bar" ]] && echo OK || echo FAIL

# 测 build_prompt_json
SHOT='{"id":"S001","description_en":"woman in robes","lighting":"candlelight","mood":"tense","characters":["沈栀"]}'
build_prompt_json "$SHOT" "/some/dir" "9:16" | jq .
```

Expected:
- 第一个测试输出 `OK`
- 第二个测试输出合法 JSON,含 prompt_en/negative/aspect/seed/characters/character_card_dir/shot_meta

```bash
rm /tmp/t.json
```

- [ ] **Step 3: Commit**

```bash
git add skills/shot-to-image/scripts/lib/json.sh
git commit -m "feat(shot-to-image): add lib/json.sh utilities"
```

---

### Task 1.2:写 lib/poll.sh(异步任务轮询)

**Files:**
- Create: `skills/shot-to-image/scripts/lib/poll.sh`

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# lib/poll.sh — 异步任务轮询的统一封装

# 用法:
#   poll_task --check-url URL --auth-header H --status-jq EXPR \
#             --done-values "v1,v2" --fail-values "v3,v4" \
#             --result-jq EXPR --interval N --timeout N
poll_task() {
  local check_url="" auth_header="" status_jq="" done_values=""
  local fail_values="" result_jq="" interval=5 timeout=300

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check-url) check_url="$2"; shift 2 ;;
      --auth-header) auth_header="$2"; shift 2 ;;
      --status-jq) status_jq="$2"; shift 2 ;;
      --done-values) done_values="$2"; shift 2 ;;
      --fail-values) fail_values="$2"; shift 2 ;;
      --result-jq) result_jq="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      *) echo "ERROR: unknown arg $1" >&2; return 2 ;;
    esac
  done

  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local response status
    response=$(curl -s -H "$auth_header" "$check_url") || {
      echo "ERROR: poll request failed" >&2
      return 1
    }
    status=$(echo "$response" | jq -r "$status_jq")

    if [[ ",$done_values," == *",$status,"* ]]; then
      echo "$response" | jq -r "$result_jq"
      return 0
    fi
    if [[ ",$fail_values," == *",$status,"* ]]; then
      echo "ERROR: task failed (status=$status)" >&2
      echo "$response" >&2
      return 1
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "ERROR: task timeout after ${timeout}s" >&2
  return 1
}
```

- [ ] **Step 2: 单元测试(用 mock HTTP server,可选;最低限度过 shell 语法)**

```bash
bash -n skills/shot-to-image/scripts/lib/poll.sh && echo "syntax OK"
```

Expected: `syntax OK`

完整 HTTP 行为测试留到具体 adapter 用到时再做。

- [ ] **Step 3: Commit**

```bash
git add skills/shot-to-image/scripts/lib/poll.sh
git commit -m "feat(shot-to-image): add lib/poll.sh for async task polling"
```

---

## Phase 2:reference 文档

### Task 2.1:写 references/prompt-construction.md

**Files:**
- Create: `skills/shot-to-image/references/prompt-construction.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 提示词构造

把 `镜头表.json` 一条 shot 记录构造成各后端能吃的提示词。

---

## 通用 prompt 公式

```
{description_en}, {lighting}, {mood},
cinematic film still, {aspect_keyword},
shot on {camera_lens_keyword},
{framing_keyword} shot,
featuring {character_refer_hint}
```

各字段:
- `description_en`:从 `shots[i].description_en` 来,**已经包含**角色外观描述、构图、电影感(由 script-to-shot 写好)
- `lighting`:`shots[i].lighting`
- `mood`:`shots[i].mood`
- `aspect_keyword`:横屏 → `16:9 aspect ratio, widescreen` / 竖屏 → `9:16 aspect ratio, vertical`
- `camera_lens_keyword`:默认 `35mm anamorphic lens`,特写镜可换 `85mm portrait lens`
- `framing_keyword`:景别 ELS/LS/MS/MCU/CU/ECU → `extreme wide / wide / medium / medium close-up / close-up / extreme close-up`
- `character_refer_hint`:见下

---

## 角色参考提示词构造

每个后端机制不一样,见 [character-consistency.md](character-consistency.md)。这里给统一的 fallback:

```
featuring the character matching reference: {character_card_dir}/{character_name}.png
```

具体怎么传参考图给后端,各 adapter 处理。

---

## negative prompt(通用)

```
blurry, low quality, watermark, text overlay, ugly, deformed,
extra fingers, mutated hands, signature, logo,
bad anatomy, disfigured, oversaturated
```

(MJ 不支持 negative prompt;Comfy/SD/FLUX 支持。)

---

## 角色卡 prompt(角色卡预生成专用)

跟镜头 prompt 不同——角色卡要"正面胸像,纯色背景,中性表情,清晰五官"。

```
{character_description_en}, centered portrait, frontal view, neutral expression, plain gray studio background, even soft lighting, clear facial features, cinematic film still, shot on 85mm portrait lens, shallow depth of field, 9:16 aspect ratio
```

注意:
- 不带场景 / 不带情绪 / 不带运镜
- 用纯色背景,避免背景元素干扰下游"指认"
- 用 85mm portrait lens,标准人像头
- 即使最终是横屏,角色卡也用 9:16 — 给下游做 refer 时更稳定
````

- [ ] **Step 2: Commit**

```bash
git add skills/shot-to-image/references/prompt-construction.md
git commit -m "docs(shot-to-image): add prompt construction guide"
```

---

### Task 2.2:写 references/backend-cheatsheet.md

**Files:**
- Create: `skills/shot-to-image/references/backend-cheatsheet.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 后端速查表

每个后端的提示词风格、参数范围、限制。

---

## GPT-Image-2(`gpt-image`)

- **环境变量**:`GPT_IMAGE_API_KEY`,可选 `GPT_IMAGE_BASE_URL`(默认 `https://api.openai.com/v1`)
- **提示词风格**:自然语言英文,跟 DALL-E 风格类似
- **特长**:文字渲染好(可在画面里写中文字)
- **弱点**:电影感弱,人物一致性差(仅靠 prompt)
- **参数范围**:size 支持 `1024x1024 / 1536x1024 / 1024x1536`
- **价格**(参考 2026 年):约 $0.04/张(1024×1024)
- **角色一致性机制**:只能靠 prompt 描述,无 refer 图机制
- **API endpoint**:`POST {BASE_URL}/images/generations`

---

## Midjourney 第三方代理(`mj`)

- **环境变量**:`MJ_API_KEY`,`MJ_BASE_URL`(必填,各代理不一样)
- **提示词风格**:关键词堆叠,加 `--ar 9:16 --v 6 --style raw` 等参数
- **特长**:电影感最强,审美在线
- **弱点**:文字渲染差,API 异步(要轮询)
- **参数范围**:`--ar`,`--v`,`--style`,`--cref`(角色参考),`--sref`(风格参考)
- **价格**:取决于代理服务商,约 $0.05-0.15/张
- **角色一致性机制**:`--cref {URL}`(传角色卡 URL)+ `--cw 100`(权重)
- **API 流程**:提交任务 → 拿 task_id → 轮询 → 拿到图 URL

---

## Replicate(`replicate`)

- **环境变量**:`REPLICATE_API_TOKEN`
- **提示词风格**:看模型,FLUX 用自然语言,SDXL 用 tag 式
- **特长**:模型多(FLUX/SDXL/IP-Adapter),价格透明
- **弱点**:略慢(冷启动 10-30s)
- **价格**:FLUX-dev 约 $0.003/张,FLUX-pro 约 $0.04/张
- **角色一致性机制**:image input + IP-Adapter
- **API endpoint**:`POST https://api.replicate.com/v1/predictions`(同步等待或异步轮询)

---

## Fal.ai(`fal`)

- **环境变量**:`FAL_KEY`
- **提示词风格**:同 Replicate(主力 FLUX 系列)
- **特长**:延迟低(2-5s)
- **价格**:FLUX-schnell 约 $0.003/张,FLUX-pro 约 $0.05/张
- **角色一致性机制**:image input + IP-Adapter
- **API endpoint**:`POST https://fal.run/{model_id}`

---

## ComfyUI 本地(`comfy`)

- **环境变量**:`COMFY_HOST`(默认 `127.0.0.1:8188`)
- **提示词风格**:依赖加载的 checkpoint(FLUX/SDXL/SD1.5)
- **特长**:免费,可控性最高(workflow.json),支持 LoRA
- **弱点**:要求用户有显卡 + 已部署 ComfyUI
- **角色一致性机制**:自定义 workflow 含 IP-Adapter 或 LoRA
- **API endpoint**:`POST http://{COMFY_HOST}/prompt`

---

## prompt-only(`prompt-only`)

- **环境变量**:无
- **行为**:不调任何 API,只输出 .mj.txt(MJ 风格)和 .sd.json(SD/Comfy 风格)到 `提示词/` 目录
- **用途**:零接入门槛,用户自己拿提示词去 Discord/A1111/Comfy 跑

---

## 后端选择优先级(给 SKILL.md 抄)

1. CLI 用户显式说用某后端 → 直接路由
2. 环境变量 `IMG_BACKEND` 显式 → 路由
3. 按以下顺序扫,第一个 env 齐的就用:
   - `gpt-image`(`GPT_IMAGE_API_KEY`)
   - `mj`(`MJ_API_KEY` + `MJ_BASE_URL`)
   - `fal`(`FAL_KEY`)
   - `replicate`(`REPLICATE_API_TOKEN`)
   - `comfy`(`COMFY_HOST`,默认 `127.0.0.1:8188`,但要 curl 探测端口可达)
4. 全没齐 → 降级 `prompt-only`,提示用户配 key
````

- [ ] **Step 2: Commit**

```bash
git add skills/shot-to-image/references/backend-cheatsheet.md
git commit -m "docs(shot-to-image): add backend cheatsheet"
```

---

### Task 2.3:写 references/character-consistency.md

**Files:**
- Create: `skills/shot-to-image/references/character-consistency.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 角色一致性

AI 短剧最大的工程难点。本流水线走"角色卡预生成 + 复用"方案。

---

## 整体流程

```
1. 第一次跑 shot-to-image:
   - 扫镜头表.json 的 characters[] → 去重得角色清单
   - 为每个角色生成角色卡(正面胸像,纯色背景)
     - 写入 短剧/角色卡/{角色名}.png
     - 写入 短剧/角色卡/{角色名}.json(含 description_en + 后端 refer 字段位置)
   - 上传到后端拿 refer ID/URL,回填到 .json
2. 后续每镜生图:
   - 读 角色卡/{角色名}.json
   - 按当前后端的机制传 refer
   - 生图
```

---

## 各后端的角色 refer 机制

### GPT-Image-2

不支持图像 refer。只能在 prompt 里反复 reinforce 角色外观描述:

```
A young Asian woman, early twenties, waist-length black hair, dark high-collar robe, faint scar above left eyebrow, pale skin, sharp eyes — standing at the temple gate at dusk...
```

效果一般。GPT-Image-2 后端的角色一致性靠"描述精确度",不是参考图。

### Midjourney `--cref`

```
{prompt} --cref {character_card_url} --cw 100 --ar 9:16 --v 6
```

- `--cref`:角色参考图 URL(必须公网可访问)
- `--cw 0-100`:权重,100 = 最贴近参考,0 = 只参考脸不参考服饰

工作流:
1. 角色卡生成后,上传到代理提供的图床(各代理服务商 API 不一,通常返回一个 https URL)
2. 把 URL 写入 `角色卡/{name}.json` 的 `mj_cref_url` 字段
3. 后续每镜 prompt 加 `--cref {mj_cref_url} --cw 80`

### Replicate / Fal(IP-Adapter)

通过 `image` 参数传角色卡 base64 或 URL:

```json
{
  "version": "<model_id>",
  "input": {
    "prompt": "...",
    "image": "data:image/png;base64,...",
    "ip_adapter_scale": 0.7
  }
}
```

`ip_adapter_scale` 0-1,越高越贴近参考。

### ComfyUI

需要 workflow.json 含 IP-Adapter 节点。用户自己准备 workflow 模板,skill 把角色卡作为 IP-Adapter 输入注入。

复杂度高,Plan 4 再做。

---

## 角色卡生成 prompt(标准化)

详见 [prompt-construction.md](prompt-construction.md) 的"角色卡 prompt"段。要点:

- 正面胸像
- 纯色灰背景
- 中性表情
- 85mm portrait lens(标准人像头)
- 9:16(给下游做 refer 时更稳定)
- 不带场景 / 情绪 / 运镜

---

## 角色卡 .json schema

```json
{
  "name": "沈栀",
  "description_cn": "二十出头女性,长发及腰,深色道袍,左眉有疤",
  "description_en": "Young Asian woman, early twenties, waist-length black hair, dark high-collar robe, faint scar above left eyebrow, pale skin, sharp eyes",
  "reference_png": "角色卡/沈栀.png",
  "mj_cref_url": null,
  "jimeng_refer_id": null,
  "kling_subject_id": null,
  "comfy_lora_path": null,
  "generated_at": "2026-05-20T11:00:00Z",
  "generated_by_backend": "gpt-image"
}
```

各后端用到时回填对应字段。

---

## 一致性失败的兜底

如果某镜生图后明显跟角色卡长得不一样(用户标记):
1. 删掉那张图
2. 跑 `/shot-to-image --retry-failures` 重生
3. 如果重生 3 次还不像 → 提示用户考虑换后端,或者用更详细的 prompt 描述
````

- [ ] **Step 2: Commit**

```bash
git add skills/shot-to-image/references/character-consistency.md
git commit -m "docs(shot-to-image): add character consistency engineering guide"
```

---

### Task 2.4:写 references/failure-modes.md

**Files:**
- Create: `skills/shot-to-image/references/failure-modes.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 失败模式 & 修复

生图常见烂图模式 + 怎么 prompt 工程改善。

---

## 1. 文字渲染失败(画面里出现乱码)

**症状**:背景里出现奇怪的英文字符串或乱码方块字

**原因**:模型试图渲染描述里的中文专有名词

**修复**:
- prompt 不出现中文(全英文)
- 加 negative:`text overlay, watermark, signature, logo, gibberish text`

如果就是要画面有字(比如对联、招牌),用 GPT-Image-2(它的中文文字渲染好),其他后端避免。

---

## 2. 人物变形(六指、两个头)

**症状**:手指多/少、肢体扭曲、表情诡异

**原因**:复杂动作 + 模型理解不到位

**修复**:
- prompt 加 `clear anatomy, natural pose`
- negative 加 `extra fingers, mutated hands, deformed, bad anatomy, disfigured`
- 复杂动作拆成简单姿势("she's pouring tea while looking at him" → "she pours tea, looking down at the cup")
- 如果用 MJ,加 `--style raw` 抑制美化

---

## 3. 机位错乱(明明要中景出了远景)

**症状**:景别词被忽略

**原因**:prompt 里景别词放在末尾,模型权重低

**修复**:
- 景别词放在 prompt 最前面:`Medium close-up of a young woman...` 而不是 `A young woman ... medium close-up`
- 加额外强化:`tight framing` / `close framing` / `wide framing`

---

## 4. 角色长得不一样

**症状**:同一个角色每镜面孔不同

**原因**:没传 refer 图 / refer 权重低

**修复**:
- 用支持 refer 的后端(MJ / FLUX with IP-Adapter)
- 提高 `--cw` 或 `ip_adapter_scale`
- 见 [character-consistency.md](character-consistency.md)

---

## 5. 风格漂移(每镜画风不一样)

**症状**:有的镜像电影海报,有的像插画,有的像 3D 渲染

**原因**:没有锚定风格关键词

**修复**:
- 每镜 prompt 都强制加 `cinematic film still`
- 如果用 MJ,统一加 `--sref {style_reference_url}`(用第一张满意的图做风格锚)
- 如果用 Comfy/FLUX,固定 seed(同一集所有镜用同一个 seed 段)

---

## 6. 光线全是大白光

**症状**:无论是夜戏白天戏都白花花一片

**原因**:lighting 字段没传 / 模型默认偏好高 key

**修复**:
- 确保 prompt 含 lighting 描述(由 script-to-shot 注入)
- 加强化:`dramatic lighting, chiaroscuro, low-key lighting, deep shadows`
- 夜戏:`moody nighttime, candlelit, warm orange highlights against cool blue shadows`

---

## 7. 服饰错乱(本应古装却出了现代装)

**症状**:角色穿现代衣服

**原因**:描述不够具体

**修复**:
- description_en 必须明确服饰:`Tang dynasty robe with embroidered sleeves` / `dark Qing dynasty official robe with mandarin collar`
- 一旦角色服饰定了,所有镜头都重复同一描述

---

## 调试流程

某镜效果不好,按以下顺序排查:

1. 看 `镜头图/{shot_id}.json` 的 prompt 字段 → 检查 prompt 是否合理
2. 改 prompt 重生一次:`/shot-to-image --redo S017`
3. 改不好 → 换后端:`IMG_BACKEND=mj /shot-to-image --redo S017`
4. 换不好 → 改 `镜头表.json` 里的 `description_en`,然后 redo
5. 还不好 → 改 `镜头表.json` 里的 `framing` 或 `camera`(可能是镜头语言决策本身有问题)
````

- [ ] **Step 2: Commit**

```bash
git add skills/shot-to-image/references/failure-modes.md
git commit -m "docs(shot-to-image): add failure modes troubleshoot guide"
```

---

### Task 2.5:写 references/cost-table.md

**Files:**
- Create: `skills/shot-to-image/references/cost-table.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 价格速查表

每个后端单图价格(参考价,2026 年实际以服务商最新报价为准)+ 每集预算估算。

---

## 单图价格(参考 USD)

| 后端 | 模型/规格 | 价格/张 |
|---|---|---|
| `gpt-image` | gpt-image-2, 1024×1024 | ~$0.04 |
| `gpt-image` | gpt-image-2, 1024×1536 | ~$0.06 |
| `mj`(代理) | v6, 标准 | $0.05 - $0.15 |
| `replicate` | FLUX-schnell | ~$0.003 |
| `replicate` | FLUX-dev | ~$0.025 |
| `replicate` | FLUX-pro | ~$0.04 |
| `replicate` | SDXL | ~$0.005 |
| `fal` | FLUX-schnell | ~$0.003 |
| `fal` | FLUX-pro | ~$0.05 |
| `comfy` | 本地 | $0(电费忽略) |
| `prompt-only` | 不调 API | $0 |

---

## 每集预算估算

横屏 30-50 镜:

| 后端 | 30 镜成本 | 50 镜成本 |
|---|---|---|
| `gpt-image`(1024×1536) | $1.80 | $3.00 |
| `mj`(代理,平均 $0.08) | $2.40 | $4.00 |
| `replicate`(FLUX-dev) | $0.75 | $1.25 |
| `replicate`(FLUX-pro) | $1.20 | $2.00 |
| `fal`(FLUX-pro) | $1.50 | $2.50 |
| `comfy` | $0 | $0 |

竖屏 40-60 镜:同比例 ×1.2 — ×1.3。

加角色卡预生成(本集首次):每个角色 + 1-2 张试错 = ×3 角色数。

---

## 完整短剧成本(10 集)

按"50 镜/集,横屏,FLUX-pro" → $20-25。

按"60 镜/集,竖屏,MJ" → $40-60。

按"60 镜/集,竖屏,Comfy 本地" → $0(只算电费)。

---

## 预算给用户的话术

skill 开跑前告知用户:

> 本次预计跑 50 镜 + 3 张角色卡 = 53 张图。
> 后端:fal(FLUX-pro)。
> 预计成本:~$2.65 USD。
> 是否继续?
````

- [ ] **Step 2: Commit**

```bash
git add skills/shot-to-image/references/cost-table.md
git commit -m "docs(shot-to-image): add cost estimation table"
```

---

## Phase 3:adapter 实现

### Task 3.1:写 adapters/prompt_only.sh

**Files:**
- Create: `skills/shot-to-image/scripts/adapters/prompt_only.sh`

- [ ] **Step 1: 写脚本**

```bash
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

# 输出目录变更:写到 提示词/ 而不是 镜头图/
# OUT_DIR 是 镜头图/,平级的 提示词/ 是它的兄弟目录
PROMPT_DIR=$(dirname "$OUT_DIR")/提示词
mkdir -p "$PROMPT_DIR"

# MJ 风格:单行 + 参数
MJ_ARGS="--ar $ASPECT --v 6 --style raw"
if [[ -n "$REFER" && -f "$REFER" ]]; then
  MJ_ARGS="$MJ_ARGS --cref file://$REFER --cw 80"
fi
echo "$PROMPT_EN $MJ_ARGS" > "$PROMPT_DIR/$SHOT_ID.mj.txt"

# SD/Comfy 风格:JSON
cat > "$PROMPT_DIR/$SHOT_ID.sd.json" <<EOF
{
  "prompt": $(echo "$PROMPT_EN" | jq -Rs .),
  "negative_prompt": $(echo "$PROMPT_JSON" | jq '.negative'),
  "aspect_ratio": $(echo "$ASPECT" | jq -Rs .),
  "seed": $(echo "$PROMPT_JSON" | jq '.seed'),
  "refer_image": $(echo "${REFER:-}" | jq -Rs .)
}
EOF

# 同时在 OUT_DIR 写一个空 placeholder + .json,标记"提示词已导出但没有真图"
mkdir -p "$OUT_DIR"
cat > "$OUT_DIR/$SHOT_ID.json" <<EOF
{
  "shot_id": "$SHOT_ID",
  "backend": "prompt-only",
  "status": "prompt_exported_no_image",
  "prompt_files": [
    "$PROMPT_DIR/$SHOT_ID.mj.txt",
    "$PROMPT_DIR/$SHOT_ID.sd.json"
  ],
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "OK $SHOT_ID (prompt-only, see $PROMPT_DIR/$SHOT_ID.*)" >&2
exit 0
```

- [ ] **Step 2: 加可执行权限并测试**

```bash
chmod +x skills/shot-to-image/scripts/adapters/prompt_only.sh

mkdir -p /tmp/test-out

# 准备一个 prompt JSON
PROMPT_JSON='{
  "prompt_en": "Young Asian woman in dark robes, candlelight, tense",
  "negative": "blurry, low quality",
  "aspect": "9:16",
  "seed": 42,
  "characters": ["沈栀"]
}'

echo "$PROMPT_JSON" | ./skills/shot-to-image/scripts/adapters/prompt_only.sh \
  --shot-id S001 \
  --out-dir /tmp/test-out/镜头图
```

Expected:
- stderr 输出 `OK S001 (prompt-only, see ...)`
- exit 0
- `/tmp/test-out/提示词/S001.mj.txt` 存在,内容是 MJ 行
- `/tmp/test-out/提示词/S001.sd.json` 存在,合法 JSON
- `/tmp/test-out/镜头图/S001.json` 存在,含 `backend: prompt-only`

```bash
ls -la /tmp/test-out/提示词/ /tmp/test-out/镜头图/
cat /tmp/test-out/提示词/S001.mj.txt
jq . /tmp/test-out/提示词/S001.sd.json
jq . /tmp/test-out/镜头图/S001.json
```

- [ ] **Step 3: 清理 + commit**

```bash
rm -rf /tmp/test-out
git add skills/shot-to-image/scripts/adapters/prompt_only.sh
git commit -m "feat(shot-to-image): add prompt_only adapter"
```

---

### Task 3.2:写 adapters/gpt_image.sh(复用 story-cover 的 GPT-Image-2 调用)

**Files:**
- Create: `skills/shot-to-image/scripts/adapters/gpt_image.sh`

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# adapters/gpt_image.sh — GPT-Image-2 后端

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

API_KEY="${GPT_IMAGE_API_KEY:?ERROR: GPT_IMAGE_API_KEY required}"
BASE_URL="${GPT_IMAGE_BASE_URL:-https://api.openai.com/v1}"
MODEL="gpt-image-2"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect')

# 宽高比 → size
case "$ASPECT" in
  "9:16") SIZE="1024x1536" ;;
  "16:9") SIZE="1536x1024" ;;
  "1:1")  SIZE="1024x1024" ;;
  *) SIZE="1024x1536" ;;
esac

mkdir -p "$OUT_DIR"

# 调 API
RESPONSE=$(mktemp)
trap "rm -f $RESPONSE" EXIT

if [[ -n "$REFER" && -f "$REFER" ]]; then
  # 图生图(用角色卡作 refer)
  curl -s "${BASE_URL}/images/edits" \
    -H "Authorization: Bearer ${API_KEY}" \
    -F "model=${MODEL}" \
    -F "prompt=${PROMPT_EN}" \
    -F "image=@${REFER}" \
    -F "size=${SIZE}" \
    -F "response_format=b64_json" \
    > "$RESPONSE"
else
  # 文生图
  curl -s "${BASE_URL}/images/generations" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL}\",
      \"prompt\": $(echo "$PROMPT_EN" | jq -Rs .),
      \"size\": \"${SIZE}\",
      \"response_format\": \"b64_json\"
    }" > "$RESPONSE"
fi

# 检查错误
ERROR_MSG=$(jq -r '.error.message // empty' "$RESPONSE")
if [[ -n "$ERROR_MSG" ]]; then
  echo "ERROR: GPT-Image API error: $ERROR_MSG" >&2
  exit 1
fi

# 解码 base64 → PNG
B64=$(jq -r '.data[0].b64_json // empty' "$RESPONSE")
if [[ -z "$B64" ]]; then
  echo "ERROR: response missing .data[0].b64_json" >&2
  cat "$RESPONSE" >&2
  exit 1
fi
echo "$B64" | base64 --decode > "$OUT_DIR/$SHOT_ID.png"

# 写伴随 .json
cat > "$OUT_DIR/$SHOT_ID.json" <<EOF
{
  "shot_id": "$SHOT_ID",
  "backend": "gpt-image",
  "model": "${MODEL}",
  "size": "${SIZE}",
  "prompt": $(echo "$PROMPT_EN" | jq -Rs .),
  "refer_image": $(echo "${REFER:-}" | jq -Rs .),
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.png" >&2
exit 0
```

- [ ] **Step 2: 加可执行权限 + 语法检查**

```bash
chmod +x skills/shot-to-image/scripts/adapters/gpt_image.sh
bash -n skills/shot-to-image/scripts/adapters/gpt_image.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 3: 手动 API 测试(可选,需要 GPT_IMAGE_API_KEY)**

只在用户有 API key 时跑:
```bash
if [[ -n "${GPT_IMAGE_API_KEY:-}" ]]; then
  mkdir -p /tmp/test-out
  echo '{
    "prompt_en": "A young Asian woman in dark robes, candlelit ancient temple, cinematic film still",
    "negative": "blurry",
    "aspect": "9:16",
    "seed": 42,
    "characters": ["沈栀"]
  }' | ./skills/shot-to-image/scripts/adapters/gpt_image.sh \
    --shot-id S001 \
    --out-dir /tmp/test-out
  ls -la /tmp/test-out/
  jq . /tmp/test-out/S001.json
  rm -rf /tmp/test-out
fi
```

Expected:
- `S001.png` 存在(非零字节)
- `S001.json` 含 `backend: gpt-image`、`prompt: ...`、`generated_at: ...`

- [ ] **Step 4: Commit**

```bash
git add skills/shot-to-image/scripts/adapters/gpt_image.sh
git commit -m "feat(shot-to-image): add gpt-image adapter"
```

---

## Phase 4:route.sh + character_card.sh

### Task 4.1:写 scripts/route.sh

**Files:**
- Create: `skills/shot-to-image/scripts/route.sh`

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# route.sh — 入口:按 IMG_BACKEND 优先级 dispatch 到具体 adapter

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"

# 解析命令行参数(直接透传给 adapter)
ARGS=("$@")

# 决定 backend
BACKEND="${IMG_BACKEND:-}"

if [[ -z "$BACKEND" ]]; then
  # 自动探测
  if [[ -n "${GPT_IMAGE_API_KEY:-}" ]]; then
    BACKEND="gpt-image"
  elif [[ -n "${MJ_API_KEY:-}" && -n "${MJ_BASE_URL:-}" ]]; then
    BACKEND="mj"
  elif [[ -n "${FAL_KEY:-}" ]]; then
    BACKEND="fal"
  elif [[ -n "${REPLICATE_API_TOKEN:-}" ]]; then
    BACKEND="replicate"
  elif curl -s -o /dev/null -w "%{http_code}" "http://${COMFY_HOST:-127.0.0.1:8188}/" --max-time 2 2>/dev/null | grep -q "200\|404"; then
    BACKEND="comfy"
  else
    BACKEND="prompt-only"
  fi
fi

ADAPTER="$ADAPTERS_DIR/${BACKEND//-/_}.sh"

if [[ ! -f "$ADAPTER" ]]; then
  echo "ERROR: adapter for backend '$BACKEND' not found at $ADAPTER" >&2
  exit 1
fi

if [[ ! -x "$ADAPTER" ]]; then
  echo "ERROR: adapter not executable: $ADAPTER (run chmod +x)" >&2
  exit 1
fi

echo "[route] dispatching to backend=$BACKEND" >&2

# 把 stdin pipe 给 adapter
exec "$ADAPTER" "${ARGS[@]}"
```

- [ ] **Step 2: 加可执行权限 + 测试**

```bash
chmod +x skills/shot-to-image/scripts/route.sh

# 测试 prompt-only 路由(unset 所有 env)
mkdir -p /tmp/test-out
env -i PATH="$PATH" HOME="$HOME" bash -c '
  echo "{\"prompt_en\":\"x\",\"negative\":\"y\",\"aspect\":\"9:16\",\"seed\":1,\"characters\":[]}" | \
    ./skills/shot-to-image/scripts/route.sh \
      --shot-id S001 \
      --out-dir /tmp/test-out/镜头图
'
```

Expected:
- stderr 含 `[route] dispatching to backend=prompt-only`
- `/tmp/test-out/提示词/S001.mj.txt` 存在
- `/tmp/test-out/镜头图/S001.json` 含 `backend: prompt-only`

```bash
rm -rf /tmp/test-out
```

- [ ] **Step 3: 测试显式 backend 覆盖**

```bash
mkdir -p /tmp/test-out
echo '{"prompt_en":"x","negative":"y","aspect":"9:16","seed":1,"characters":[]}' | \
  IMG_BACKEND=prompt-only ./skills/shot-to-image/scripts/route.sh \
    --shot-id S002 \
    --out-dir /tmp/test-out/镜头图

ls /tmp/test-out/镜头图/
rm -rf /tmp/test-out
```

Expected: `S002.json` 存在。

- [ ] **Step 4: Commit**

```bash
git add skills/shot-to-image/scripts/route.sh
git commit -m "feat(shot-to-image): add route.sh dispatcher"
```

---

### Task 4.2:写 scripts/character_card.sh(角色卡预生成入口)

**Files:**
- Create: `skills/shot-to-image/scripts/character_card.sh`

- [ ] **Step 1: 写脚本**

```bash
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
  
  cat > "$CARD_JSON" <<EOF
{
  "name": $(echo "$NAME" | jq -Rs .),
  "description_cn": null,
  "description_en": $(echo "$DESC_EN" | jq -Rs .),
  "reference_png": $(echo "$CARD_PNG" | jq -Rs .),
  "mj_cref_url": null,
  "jimeng_refer_id": null,
  "kling_subject_id": null,
  "comfy_lora_path": null,
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "generated_by_backend": $(echo "$BACKEND" | jq -Rs .)
}
EOF
fi

echo "[card] $NAME -> $CARD_PNG" >&2
exit 0
```

- [ ] **Step 2: 加可执行权限 + 测试(走 prompt-only 后端)**

```bash
chmod +x skills/shot-to-image/scripts/character_card.sh

mkdir -p /tmp/test-cards
env -i PATH="$PATH" HOME="$HOME" \
  ./skills/shot-to-image/scripts/character_card.sh \
    "沈栀" \
    "Young Asian woman, early twenties, waist-length black hair, dark high-collar robe, faint scar above left eyebrow, pale skin, sharp eyes" \
    /tmp/test-cards \
    9:16

ls -la /tmp/test-cards/
cat /tmp/test-cards/沈栀.json | jq .
```

Expected:
- `/tmp/test-cards/沈栀.json` 存在,schema 符合角色卡 .json schema
- 由于走 prompt-only,没有 PNG,但提示词文件应该在 /tmp/test-cards/../提示词/ 下(具体看 prompt_only.sh 的输出逻辑)

```bash
ls /tmp/提示词/ 2>/dev/null || echo "no prompt dir at /tmp (depends on adapter)"
rm -rf /tmp/test-cards /tmp/提示词
```

- [ ] **Step 3: Commit**

```bash
git add skills/shot-to-image/scripts/character_card.sh
git commit -m "feat(shot-to-image): add character_card.sh prefab entry"
```

---

## Phase 5:SKILL.md 主体

### Task 5.1:写 SKILL.md

**Files:**
- Create: `skills/shot-to-image/SKILL.md`

- [ ] **Step 1: 写完整文件**

````markdown
---
name: shot-to-image
version: 1.0.0
description: |
  镜头转图片。把镜头表.json 转成镜头图,含角色卡预生成 + 复用,支持多生图后端(GPT-Image-2 / MJ / Replicate / Fal / ComfyUI / prompt-only)。
  触发方式:/shot-to-image、/镜头转图片、「生镜头图」「出图」
metadata:
  openclaw:
    requires:
      bins:
        - jq
        - curl
        - base64
    source: https://github.com/worldwonderer/oh-story-claudecode
---

# shot-to-image:镜头转图片

你是分镜出图执行者。把 `镜头表.json` 一条条 shot 转成 PNG,确保角色一致性。

---

## 核心方法

1. **角色卡预生成 + 复用** — 见 [references/character-consistency.md](references/character-consistency.md)
2. **多后端适配层** — 见 [references/backend-cheatsheet.md](references/backend-cheatsheet.md)
3. **失败不阻塞** — 单镜失败记录到 `.failures.json`,末尾汇总,用户跑 `--retry-failures`

---

## Phase 1:后端选择

```bash
./scripts/route.sh --dry-run  # 探测,无副作用
```

按 [references/backend-cheatsheet.md](references/backend-cheatsheet.md) 的优先级决定 `IMG_BACKEND`。

告知用户:
- 本次用什么后端、为什么
- 预算估算(参考 [references/cost-table.md](references/cost-table.md))

---

## Phase 2:角色卡预生成

### 扫角色

```bash
jq -r '[.shots[].characters[]] | unique | .[]' {工作根}/第NNN集/镜头表.json
```

得本集角色清单。

### 召回 description_en

按以下优先级:
1. `{工作根}/短剧/角色卡/{name}.json` 已存在 → 跳过生成
2. long-write 模式下 `设定/角色/{name}.md` 含 `## description_en` 段(由 script-to-shot 写) → 用它
3. 都没有 → 询问用户角色外观描述(或者从拍摄本/镜头表抽取构造)

### 跑预生成

对每个未生成的角色:

```bash
./scripts/character_card.sh \
  "{角色名}" \
  "{description_en}" \
  "{工作根}/短剧/角色卡" \
  "{aspect}"
```

---

## Phase 3:逐镜生图

遍历 `镜头表.json` 的 shots:

```bash
mkdir -p {工作根}/第NNN集/镜头图

for SHOT_ID in $(jq -r '.shots[].id' 镜头表.json); do
  SHOT=$(jq -c ".shots[] | select(.id == \"$SHOT_ID\")" 镜头表.json)
  
  # 构造 prompt JSON
  PROMPT_JSON=$(source ./scripts/lib/json.sh && build_prompt_json "$SHOT" "{工作根}/短剧/角色卡" "{aspect}")
  
  # 决定 refer(主角第一个角色的角色卡)
  FIRST_CHAR=$(echo "$SHOT" | jq -r '.characters[0] // empty')
  REFER=""
  [[ -n "$FIRST_CHAR" ]] && REFER="{工作根}/短剧/角色卡/${FIRST_CHAR}.png"
  
  # 跑 adapter
  if echo "$PROMPT_JSON" | ./scripts/route.sh \
       --shot-id "$SHOT_ID" \
       --out-dir "{工作根}/第NNN集/镜头图" \
       ${REFER:+--refer "$REFER"}; then
    : # 成功
  else
    # 失败记录
    echo "$SHOT_ID" >> {工作根}/第NNN集/.failures.json
  fi
done
```

---

## Phase 4:一致性自检(可选)

只在用户加 `--check-consistency` 时跑。基础版:对每个角色随机抽 3 张生成图,跟角色卡放一起,让用户人眼判断;不一致 → 标记重生。

advanced 版(face embedding)留给未来扩展。

---

## Phase 5:失败重试

```
/shot-to-image --retry-failures
```

→ 读 `.failures.json` → 只重生这些镜号 → 成功的从失败列表移除。

重试 3 次仍失败 → 提示用户考虑换后端或改 `description_en`(见 [references/failure-modes.md](references/failure-modes.md))。

---

## Phase 6:交付提示

- 成功 X 镜 / 失败 Y 镜
- 总成本(按 [references/cost-table.md](references/cost-table.md) 估算)
- 下一步:`/image-to-video` 把镜头图转成视频片段

---

## 参考资料索引

| 场景 | 文件 |
|---|---|
| 提示词构造 | [references/prompt-construction.md](references/prompt-construction.md) |
| 后端速查 | [references/backend-cheatsheet.md](references/backend-cheatsheet.md) |
| 角色一致性 | [references/character-consistency.md](references/character-consistency.md) |
| 失败模式排查 | [references/failure-modes.md](references/failure-modes.md) |
| 价格估算 | [references/cost-table.md](references/cost-table.md) |

---

## 流程衔接

| 时机 | 跳转到 | 命令 |
|---|---|---|
| 镜头图出完 | image-to-video | `/image-to-video` |
| 某镜不满意 | 单镜重生 | `/shot-to-image --redo S017` |
| 失败重试 | `/shot-to-image --retry-failures` | — |

---

## 语言

- 跟随用户的语言回复
````

- [ ] **Step 2: Commit**

```bash
git add skills/shot-to-image/SKILL.md
git commit -m "feat(shot-to-image): add main SKILL.md"
```

---

## Phase 6:集成测试

### Task 6.1:准备测试 fixture(小镜头表)

**Files:**
- Create: `tests/fixtures/shot-to-image/test-shotlist.json`

- [ ] **Step 1: 创建 fixture**

```bash
mkdir -p tests/fixtures/shot-to-image
cp tests/fixtures/expected-shotlist.json tests/fixtures/shot-to-image/test-shotlist.json
```

(用 Plan 1 已经写好的 expected-shotlist.json,内有 3 镜含两个角色。)

- [ ] **Step 2: Commit**

```bash
git add tests/fixtures/shot-to-image
git commit -m "test: add shot-to-image fixture"
```

---

### Task 6.2:端到端测试(prompt-only 后端)

**Files:**
- 无新建

- [ ] **Step 1: 准备工作目录**

```bash
mkdir -p /tmp/test-pipeline/短剧/{角色卡,第001集}
cp tests/fixtures/shot-to-image/test-shotlist.json /tmp/test-pipeline/短剧/第001集/镜头表.json
```

- [ ] **Step 2: 跑角色卡预生成**

```bash
SKILL_DIR="$(pwd)/skills/shot-to-image"

# 沈栀
env -i PATH="$PATH" HOME="$HOME" \
  "$SKILL_DIR/scripts/character_card.sh" \
    "沈栀" \
    "Young Asian woman, early twenties, waist-length black hair, dark high-collar robe, faint scar above left eyebrow, pale skin" \
    "/tmp/test-pipeline/短剧/角色卡" \
    "9:16"

# 司长
env -i PATH="$PATH" HOME="$HOME" \
  "$SKILL_DIR/scripts/character_card.sh" \
    "司长" \
    "Older Asian man, fifties, dark official robes, weathered face, salt-and-pepper beard" \
    "/tmp/test-pipeline/短剧/角色卡" \
    "9:16"

ls /tmp/test-pipeline/短剧/角色卡/
```

Expected: `沈栀.json`、`司长.json` 存在(由于 prompt-only,无 .png)。

- [ ] **Step 3: 逐镜生图(prompt-only)**

```bash
EPISODE_DIR=/tmp/test-pipeline/短剧/第001集
SHOTLIST=$EPISODE_DIR/镜头表.json
CARD_DIR=/tmp/test-pipeline/短剧/角色卡
SKILL_DIR="$(pwd)/skills/shot-to-image"

source "$SKILL_DIR/scripts/lib/json.sh"

mkdir -p "$EPISODE_DIR/镜头图"

for SHOT_ID in $(jq -r '.shots[].id' "$SHOTLIST"); do
  SHOT=$(jq -c ".shots[] | select(.id == \"$SHOT_ID\")" "$SHOTLIST")
  PROMPT_JSON=$(build_prompt_json "$SHOT" "$CARD_DIR" "9:16")
  FIRST_CHAR=$(echo "$SHOT" | jq -r '.characters[0] // empty')
  REFER_ARG=""
  [[ -n "$FIRST_CHAR" ]] && REFER_ARG="--refer $CARD_DIR/${FIRST_CHAR}.png"
  
  echo "$PROMPT_JSON" | env -i PATH="$PATH" HOME="$HOME" \
    "$SKILL_DIR/scripts/route.sh" \
      --shot-id "$SHOT_ID" \
      --out-dir "$EPISODE_DIR/镜头图" \
      $REFER_ARG
done

ls "$EPISODE_DIR/提示词/"
ls "$EPISODE_DIR/镜头图/"
```

Expected:
- `提示词/` 下含 `S001.mj.txt`、`S001.sd.json`、`S002.mj.txt`、`S002.sd.json`、`S003.mj.txt`、`S003.sd.json`
- `镜头图/` 下含 `S001.json`、`S002.json`、`S003.json`(全部 backend: prompt-only)

- [ ] **Step 4: 校验 MJ 提示词含 --cref**

```bash
cat /tmp/test-pipeline/短剧/第001集/提示词/S001.mj.txt
```

Expected: 行末含 `--ar 9:16 --v 6 --style raw`,以及 `--cref file://...角色卡/沈栀.png --cw 80`(因为 S001 含角色"沈栀")。

- [ ] **Step 5: 清理 + commit(如有改动)**

```bash
rm -rf /tmp/test-pipeline
```

如 SKILL.md 或脚本有改动:
```bash
git add skills/shot-to-image
git commit -m "fix(shot-to-image): refine based on integration test"
```

---

### Task 6.3:端到端测试(gpt-image 后端,需要 API key,可选)

**Files:**
- 无新建

- [ ] **Step 1: 只在用户有 GPT_IMAGE_API_KEY 时跑**

```bash
if [[ -z "${GPT_IMAGE_API_KEY:-}" ]]; then
  echo "skipping gpt-image integration test (no API key)"
  exit 0
fi
```

- [ ] **Step 2: 重复 Task 6.2 流程,这次让 route.sh 自动选 gpt-image**

```bash
mkdir -p /tmp/test-pipeline-real/短剧/{角色卡,第001集/镜头图}
cp tests/fixtures/shot-to-image/test-shotlist.json /tmp/test-pipeline-real/短剧/第001集/镜头表.json

SKILL_DIR="$(pwd)/skills/shot-to-image"

# 只生 1 张角色卡作 smoke test
"$SKILL_DIR/scripts/character_card.sh" \
  "沈栀" \
  "Young Asian woman, early twenties, waist-length black hair, dark high-collar robe, faint scar above left eyebrow" \
  "/tmp/test-pipeline-real/短剧/角色卡" \
  "9:16"

ls -la /tmp/test-pipeline-real/短剧/角色卡/沈栀.png
```

Expected: `沈栀.png` 存在,非零字节。

- [ ] **Step 3: 跑一镜**

```bash
SHOT='{"id":"S001","scene":1,"framing":"MS","camera":"static","duration":3.0,"description_cn":"x","description_en":"A young Asian woman in dark robes pushes open ancient temple doors, cinematic film still, moody candlelight, tense","characters":["沈栀"],"dialogue":null,"os":null,"location":"x","time_of_day":"夜","lighting":"moody candlelight","mood":"tense"}'
source "$SKILL_DIR/scripts/lib/json.sh"
PROMPT_JSON=$(build_prompt_json "$SHOT" "/tmp/test-pipeline-real/短剧/角色卡" "9:16")

echo "$PROMPT_JSON" | "$SKILL_DIR/scripts/route.sh" \
  --shot-id S001 \
  --out-dir /tmp/test-pipeline-real/短剧/第001集/镜头图 \
  --refer /tmp/test-pipeline-real/短剧/角色卡/沈栀.png

ls -la /tmp/test-pipeline-real/短剧/第001集/镜头图/
jq . /tmp/test-pipeline-real/短剧/第001集/镜头图/S001.json
```

Expected:
- `S001.png` 存在,>10KB
- `S001.json` 含 `backend: gpt-image`、`prompt: ...`

- [ ] **Step 4: 清理**

```bash
rm -rf /tmp/test-pipeline-real
```

- [ ] **Step 5: Commit(如有改动)**

如 adapter 或 SKILL.md 有改动:
```bash
git add skills/shot-to-image
git commit -m "fix(shot-to-image): refine gpt-image adapter based on real API test"
```

---

## Plan 2 完成验收

跑通以下流程 → Plan 2 验收通过:

1. `IMG_BACKEND=prompt-only /shot-to-image` 把 3 镜的 fixture 镜头表全部转出提示词文件 + 伴随 .json
2. 角色卡预生成对两个角色都跑通(prompt-only 模式下产 .json)
3. (可选)`GPT_IMAGE_API_KEY` 配齐时,gpt-image 后端能产真 PNG
4. `--retry-failures` 流程跑通(可以模拟一个失败 shot 测试)

下一步:Plan 3(`image-to-video`,镜头图 → 视频片段,含 prompt-only + 至少 1 个真后端)。
