# 小说转视频流水线 Plan 3:image-to-video

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 `image-to-video` skill — 把 `镜头图/*.png` + 运动提示词转成 `镜头视频/*.mp4`。本 plan 实现 prompt-only 和 kling 两个 adapter;其他(jimeng/runway/sora/veo)留给 Plan 4。

**Architecture:** 结构对称 Plan 2 的 shot-to-image:SKILL.md 主体 + references/ + scripts/(lib + route + adapters)。复用 Plan 2 的 lib/poll.sh 模式。视频后端默认异步(提交 → 拿 task_id → 轮询)。

**Tech Stack:** bash 4+ / jq / curl / 复用 Plan 2 的 lib/poll.sh

**前置:** Plan 2 完成(`shot-to-image` 产 `镜头图/*.png` + `镜头表.json` 含 motion 描述)

---

## File Structure

**新建**:
- `skills/image-to-video/SKILL.md`
- `skills/image-to-video/references/motion-prompts.md`
- `skills/image-to-video/references/backend-cheatsheet.md`
- `skills/image-to-video/references/image-to-video-pitfalls.md`
- `skills/image-to-video/references/post-production-handoff.md`
- `skills/image-to-video/scripts/route.sh`
- `skills/image-to-video/scripts/lib/json.sh`(从 shot-to-image 复制 + 适配)
- `skills/image-to-video/scripts/lib/poll.sh`(从 shot-to-image 复制)
- `skills/image-to-video/scripts/adapters/prompt_only.sh`
- `skills/image-to-video/scripts/adapters/kling.sh`

**修改**:
- `.claude-plugin/marketplace.json`(注册 image-to-video)

---

## Phase 0:注册与骨架

### Task 0.1:在 marketplace.json 注册 image-to-video

**Files:**
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: 在 plugins 数组末尾追加**

```json
,
    {
      "name": "image-to-video",
      "description": "图片转视频。把镜头图 + 运动提示词转成视频片段(每镜 5s 默认),支持多生视频后端(可灵 / 即梦 / Runway / Sora / Veo / prompt-only)。",
      "source": "./",
      "strict": false,
      "version": "1.0.0",
      "category": "novel-video",
      "keywords": ["video", "i2v", "image-to-video", "镜头视频", "可灵", "即梦", "Runway", "chinese"],
      "skills": ["./skills/image-to-video"]
    }
```

- [ ] **Step 2: 校验 + commit**

```bash
jq '.plugins[] | select(.name == "image-to-video") | .name' .claude-plugin/marketplace.json
git add .claude-plugin/marketplace.json
git commit -m "chore: register image-to-video in marketplace"
```

---

### Task 0.2:创建目录骨架 + 复用 lib

**Files:**
- Create: 各目录
- Create: `skills/image-to-video/scripts/lib/json.sh`
- Create: `skills/image-to-video/scripts/lib/poll.sh`

- [ ] **Step 1: 创建目录**

```bash
mkdir -p skills/image-to-video/references
mkdir -p skills/image-to-video/scripts/adapters
mkdir -p skills/image-to-video/scripts/lib
```

- [ ] **Step 2: 复制 lib(从 shot-to-image)**

```bash
cp skills/shot-to-image/scripts/lib/poll.sh skills/image-to-video/scripts/lib/poll.sh
cp skills/shot-to-image/scripts/lib/json.sh skills/image-to-video/scripts/lib/json.sh
```

(`poll.sh` 完全通用,可以直接复用;`json.sh` 也通用,但 `build_prompt_json` 函数会在本 plan Task 1.1 替换为视频专用版本。)

- [ ] **Step 3: 替换 build_prompt_json 为视频版**

打开 `skills/image-to-video/scripts/lib/json.sh`,把 `build_prompt_json` 函数整段替换为:

```bash
# 构造视频 prompt JSON
# 用法:build_video_prompt_json <shot_json> <duration> <aspect>
build_video_prompt_json() {
  local shot_json="$1" duration="${2:-5}" aspect="$3"
  local description_en lighting mood camera

  description_en=$(echo "$shot_json" | jq -r '.description_en')
  lighting=$(echo "$shot_json" | jq -r '.lighting')
  mood=$(echo "$shot_json" | jq -r '.mood')
  camera=$(echo "$shot_json" | jq -r '.camera')

  # 运镜 → 英文运动模板(简版,详见 references/motion-prompts.md)
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

  jq -n \
    --arg p "$description_en" \
    --arg cm "$camera_motion" \
    --arg l "$lighting" \
    --arg m "$mood" \
    --argjson d "$duration" \
    --arg a "$aspect" \
    --argjson sm "$shot_json" \
    '{
       prompt_en: $p,
       motion_prompt: ("Camera: " + $cm + ". Atmosphere: " + $l + ", " + $m + "."),
       duration: $d,
       aspect: $a,
       shot_meta: $sm
     }'
}
```

(保留原文件里的 `json_get` / `json_set` / `json_merge` 不变;把 `build_prompt_json` 改为 `build_video_prompt_json`。)

- [ ] **Step 4: 加可执行权限 + 语法检查**

```bash
chmod +x skills/image-to-video/scripts/lib/poll.sh
bash -n skills/image-to-video/scripts/lib/json.sh && echo "json.sh OK"
bash -n skills/image-to-video/scripts/lib/poll.sh && echo "poll.sh OK"
```

Expected: 两个都输出 OK。

- [ ] **Step 5: Commit**

```bash
git add skills/image-to-video/
git commit -m "chore(image-to-video): scaffold dirs and lib"
```

---

## Phase 1:reference 文档

### Task 1.1:写 references/motion-prompts.md

**Files:**
- Create: `skills/image-to-video/references/motion-prompts.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 运动提示词模板

视频后端不是看图片本身决定怎么动,而是看 prompt 决定。prompt 不写动作 → 出来是个静态图飘几秒。

---

## 运动提示词三层

1. **Camera motion**:相机怎么动
2. **Subject motion**:被摄主体怎么动
3. **Atmosphere**:氛围(光线 + 情绪),保持画面连贯

完整 prompt:
```
Camera: {camera_motion}, {speed}.
Subject motion: {character_action}.
Atmosphere: {lighting}, {mood}.
Duration: {N}s.
```

---

## Camera motion 模板

| 镜头表 camera 值 | 英文运动提示词 |
|---|---|
| `static` | `static camera, locked-off shot, subtle natural motion only` |
| `pan` | `camera pans slowly left to right` 或 `slow right pan` |
| `tilt` | `camera tilts up slowly from feet to face` 或 `slow tilt down` |
| `push` | `camera slowly pushes in toward subject, dolly-in` |
| `pull` | `camera slowly pulls out from subject, dolly-out` |
| `track` | `camera tracks behind subject, following motion` |
| `handheld` | `handheld shaky camera, documentary feel, slight wobble` |
| `orbit` | `camera orbits around subject 180 degrees` |

速度修饰:
- `very slow` — 几乎察觉不到
- `slow` — 默认
- `moderate` — 中速
- `fast` — 快速(慎用,容易乱)

---

## Subject motion 模板

从镜头表的 `description_cn` / `description_en` 抽动作动词,转为视频语言:

| 描述里有 | Subject motion |
|---|---|
| "推开门" | `subject pushes door open slowly` |
| "走进来" | `subject walks into frame` |
| "抬头" | `subject looks up slowly` |
| "回头" | `subject turns head and looks back` |
| "笑了一下" | `subject smiles briefly` |
| "手停了一下" | `subject's hand pauses mid-motion` |
| "雨水滴落" | `rain drops slowly from above` |
| "烛火摇晃" | `candle flame flickers gently` |
| (静态对白,无明显动作) | `subject speaks calmly, subtle facial expression` |

如果实在没有可拍动作 → `subtle ambient motion, slight breathing, gentle environment movement`(微动)。

---

## Atmosphere 模板

直接复用镜头表的 `lighting` + `mood` 字段:

```
Atmosphere: {lighting}, {mood} mood, cinematic quality, film grain
```

---

## 完整 prompt 示例

镜头表里的 S001(沈栀推门):

```json
{
  "id": "S001",
  "camera": "static",
  "duration": 3.0,
  "description_en": "A young Asian woman in dark robes pushes open heavy wooden doors of an ancient sorcery bureau. Rain drips from the eaves...",
  "lighting": "moody candlelight, cool blue rain backlight",
  "mood": "tense, foreboding"
}
```

构造的视频 prompt:

```
A young Asian woman in dark robes pushes open heavy wooden doors of an ancient sorcery bureau. Rain drips from the eaves above her.

Camera: static camera, locked-off shot, subtle natural motion only.
Subject motion: subject pushes door open slowly, walks into frame.
Atmosphere: moody candlelight, cool blue rain backlight, tense and foreboding mood.
Duration: 3 seconds.
```

---

## 按后端微调

不同后端对 prompt 长度和风格偏好不一样:

### 可灵(kling)
- 偏好简洁,300 字以内
- 支持中英文混合
- camera 控制有专门字段(`camera_control`),可以不放 prompt 而走结构化参数

### 即梦(jimeng)
- 偏好中文 prompt(它的训练数据中文权重高)
- 镜头控制可用「镜头语言」字段

### Runway Gen-3
- 偏好英文,长 prompt 可以(500+ 字)
- 用 `Camera: ...` 起首加强相机控制
- 推荐每 prompt 加 `cinematic quality, professional cinematography`

### Sora 2
- 偏好详细英文叙述
- 时长可以更长(10s+),但每秒成本更高

### prompt-only
- 完整保留所有信息,用户自己挑后端
````

- [ ] **Step 2: Commit**

```bash
git add skills/image-to-video/references/motion-prompts.md
git commit -m "docs(image-to-video): add motion prompts guide"
```

---

### Task 1.2:写 references/backend-cheatsheet.md

**Files:**
- Create: `skills/image-to-video/references/backend-cheatsheet.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 视频后端速查表

---

## 可灵(`kling`)

- **环境变量**:`KLING_API_KEY`,`KLING_BASE_URL`(默认 `https://api.klingai.com`)
- **特长**:图生视频质量高,中文 prompt 友好,人物运动自然
- **弱点**:任务排队时间长(2-5 分钟),API 异步
- **时长**:5s / 10s 两档(10s 成本翻倍)
- **价格**:5s 约 ¥3.5 / $0.5,10s 约 ¥7 / $1
- **API endpoint**:`POST {BASE_URL}/v1/videos/image2video`(提交)/ `GET {BASE_URL}/v1/videos/image2video/{task_id}`(查询)
- **参数**:`image`(base64 或 URL)、`prompt`、`duration`(5/10)、`aspect_ratio`
- **角色一致性机制**:有"主体参考"功能,可上传角色卡作 subject_id(本 plan 暂不接,Plan 4 补)

## 即梦 / 火山方舟(`jimeng`)

- **环境变量**:`JIMENG_API_KEY`,`JIMENG_BASE_URL`(默认 `https://ark.cn-beijing.volces.com`)
- **特长**:中文 prompt 一流,有"角色"功能可锁人物
- **弱点**:API 文档以中文为主,字段命名跟英文圈不一样
- **时长**:5s 起,可到 10s
- **价格**:5s 约 ¥3
- **API endpoint**:`POST {BASE_URL}/api/v3/contents/generations/tasks`(提交)/ `GET {BASE_URL}/api/v3/contents/generations/tasks/{task_id}`(查询)
- **角色一致性机制**:`character_id` 字段(本 plan 暂不接)

## Runway Gen-3(`runway`)

- **环境变量**:`RUNWAY_API_KEY`
- **特长**:运动幅度大,西式审美强,镜头语言响应好
- **弱点**:成本高
- **时长**:5s / 10s
- **价格**:5s 约 $0.5,10s 约 $1
- **API endpoint**:`POST https://api.dev.runwayml.com/v1/image_to_video`
- **角色一致性机制**:仅靠输入图(image_url),不支持独立 character refer

## Sora 2(`sora`,占位)

- **环境变量**:`SORA_API_KEY`,`SORA_BASE_URL`
- **状态**:2026 年 API 对企业开放,个人未必能接。adapter 仅占位,Plan 4 补
- **特长**:运动最真实,可生超长(20s+)
- **价格**:高

## Veo / Google(`veo`,占位)

- **环境变量**:`VEO_API_KEY`
- **状态**:Google AI Studio 部分支持。adapter 仅占位

## prompt-only(`prompt-only`)

- **环境变量**:无
- **行为**:导出 `.kling.txt`、`.jimeng.txt`、`.runway.txt` 等多家后端的提示词文件到 `提示词视频/`
- **用途**:零接入,用户自己挑后端复制粘贴

---

## 后端选择优先级

1. CLI 显式 → 用
2. 环境变量 `VIDEO_BACKEND` 显式 → 用
3. 按顺序扫:
   - `kling`(`KLING_API_KEY` + `KLING_BASE_URL`)
   - `jimeng`(`JIMENG_API_KEY` + `JIMENG_BASE_URL`)
   - `runway`(`RUNWAY_API_KEY`)
   - `sora`(`SORA_API_KEY` + `SORA_BASE_URL`,且 adapter 已实现)
   - `veo`(`VEO_API_KEY`,且 adapter 已实现)
4. 全没齐 → 降级 `prompt-only`

注:Sora/Veo adapter 默认占位 `exit 1` 报"暂未实现",自动路由跳过它们落到 prompt-only。

---

## 每集预算估算

按 50 镜 × 5s/镜:

| 后端 | 单镜成本 | 50 镜总成本 |
|---|---|---|
| 可灵 | $0.5 | $25 |
| 即梦 | ¥3(~$0.4) | $20 |
| Runway | $0.5 | $25 |
| prompt-only | 0 | 0 |

每集成本数十美元 — 比 shot-to-image 贵得多。用户跑前必须确认。
````

- [ ] **Step 2: Commit**

```bash
git add skills/image-to-video/references/backend-cheatsheet.md
git commit -m "docs(image-to-video): add backend cheatsheet"
```

---

### Task 1.3:写 references/image-to-video-pitfalls.md

**Files:**
- Create: `skills/image-to-video/references/image-to-video-pitfalls.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 图生视频常见坑

---

## 1. 图片不动(出来跟静态图一样)

**症状**:5s 视频里画面几乎不动

**原因**:prompt 没写 motion / 运镜是 static / 模型偏保守

**修复**:
- prompt 加 subject motion(参考 [motion-prompts.md](motion-prompts.md))
- 即使 camera=static,也加 `subtle natural motion, breathing, gentle environment movement`
- 换后端(Runway 比可灵更"敢动")

---

## 2. 人物畸变(脸变形、肢体扭曲)

**症状**:开始几帧还好,后面脸越来越歪

**原因**:模型在补帧时丢失锚点

**修复**:
- 输入图本身的人物姿态尽量简单(不要复杂手势/复杂角度)
- prompt 加 `consistent facial features, stable anatomy`
- 时长缩到 5s(10s 畸变概率翻倍)

---

## 3. 运动方向错(本该推,出来是拉)

**症状**:prompt 写 push 但视频是 pull

**原因**:模型对 camera 词理解不一致

**修复**:
- 用更直白的描述:`camera moves closer to subject` 代替 `push in`
- 用结构化 camera_control 字段(可灵/即梦支持)
- 重试 2-3 次(同一 prompt 不同种子)

---

## 4. 文字闪烁(画面里的字一帧一变)

**症状**:墙上的字、招牌的字每帧不一样

**原因**:模型不能稳定渲染文字

**修复**:
- 避免画面里出现关键文字
- 如必须有,在 shot-to-image 阶段就规避(描述里写"a blank wooden sign" 而不是 "a sign saying 'Welcome'")
- 后期 Pr 加文字遮罩盖住

---

## 5. 色调漂移(镜头里色温变了)

**症状**:开头暖色调,结尾冷色调

**原因**:模型自由发挥光线

**修复**:
- prompt 强化 lighting:`consistent warm candlelight throughout, no lighting changes`
- 缩短时长

---

## 6. 任务排队超时

**症状**:可灵/即梦提交后等了 10 分钟还没好

**原因**:服务高峰,任务排队

**修复**:
- 增加 timeout(默认 300s,调到 600s)
- 错峰跑(避免国内晚高峰)
- 实在不行 → 换 Runway(国外节点)

---

## 7. 角色一致性丢失(同人不同脸)

**症状**:S001 的脸 ≠ S002 的脸(即使两张图来自同一个角色卡)

**原因**:image-to-video 默认只看输入图,不知道全集还有别的镜

**修复**:
- shot-to-image 阶段保证镜头图本身已经一致(用了角色卡)
- 接受小幅差异(图生视频会有 5-10% 漂移,无法完全消除)
- 后期剪辑:把面孔差异大的镜头换景别或换角度,降低关注度

---

## 8. 整段画面崩了(像水彩晕开)

**症状**:几秒后画面糊掉

**原因**:输入图清晰度不够 / prompt 跟图差太远

**修复**:
- 输入图至少 1024×1024(再小后端会拒/糊)
- prompt 不要描述图里没有的元素(描述要跟图一致)
- 减少时长

---

## 调试流程

某镜视频不好,按顺序:
1. 看 `镜头视频/{shot_id}.json` 的 motion_prompt → 是不是不合理
2. 改 motion_prompt 重生:`/image-to-video --redo S017`
3. 换 duration(10 → 5)
4. 换 backend
5. 重做镜头图(回 shot-to-image)
6. 重做镜头表(回 script-to-shot,改运镜 camera 字段)
````

- [ ] **Step 2: Commit**

```bash
git add skills/image-to-video/references/image-to-video-pitfalls.md
git commit -m "docs(image-to-video): add pitfalls troubleshoot guide"
```

---

### Task 1.4:写 references/post-production-handoff.md

**Files:**
- Create: `skills/image-to-video/references/post-production-handoff.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 后期交付手册

本 skill **不做**视频合成、BGM、TTS、字幕。这些交给后期工具。

---

## 交付物清单

每集跑完 image-to-video 后,产物在 `{工作根}/第NNN集/镜头视频/`:

- `S001.mp4` ~ `SNNN.mp4`:逐镜视频片段
- `S001.json` ~ `SNNN.json`:每镜元数据(用了哪张图、prompt、后端、时长)
- `_manifest.json`(末尾汇总):全集镜头清单 + 总时长 + 失败列表

---

## 推荐后期工具

### 国内
- **剪映专业版**(免费)
  - 支持中文字幕自动识别(把每镜的对白整理成字幕脚本)
  - 内置 TTS(可生成 OS 旁白)
  - 海量 BGM 库
- **达芬奇 DaVinci**(免费版够用)
  - 调色专业
  - 复杂的转场和合成
- **Pr / Adobe Premiere**(付费)
  - 全功能,行业标准

### 海外
- **CapCut**(剪映海外版)
- **DaVinci Resolve**
- **Premiere Pro**

---

## 推荐工作流(剪映)

1. 新建项目,纵向比例(短剧默认竖屏)
2. 导入 `镜头视频/` 整个目录
3. 按文件名(S001-SNNN)拖到时间轴,顺序拼接
4. 加 BGM 轨(从剪映音乐库挑,网文配乐推荐"国风器乐"/"史诗大气"/"悬疑紧张")
5. 字幕:
   - 把拍摄本里的对白 + OS 整理成字幕脚本(可手动或用剪映"自动字幕")
   - 对白用底部字幕,OS 用顶部小字
6. 转场:相邻场景之间用 0.2s 黑场过渡;同场内不加转场
7. 输出:1080×1920(竖屏)或 1920×1080(横屏),H.264,30fps

---

## 字幕脚本生成

skill 在最后生成 `第NNN集/字幕脚本.txt`,格式:

```
00:00 - 00:03  [S001]  (沈栀推门)
00:03 - 00:05  [S002]  司长:你来晚了。
00:05 - 00:07  [S003]  沈栀:我母亲死了。
00:07 - 00:08  [S004]  OS:三年前她也说过同样的话。
```

剪映可以直接导入这个格式做字幕(或者用户手动拷)。

---

## BGM 选型建议

按集情绪(从镜头表汇总的 mood 字段)推荐:

| 主导情绪 | BGM 类型 |
|---|---|
| tense / foreboding | 悬疑配乐,大鼓 + 弦乐持续低音 |
| somber / melancholy | 钢琴独奏,慢节奏 |
| romantic / intimate | 弦乐 + 钢琴,中速 |
| epic / heroic | 史诗大气配乐 |
| eerie / unsettling | 电子环境音 + 古怪音效 |

---

## TTS 旁白

OS(画外音)和 OS-style 对白可以用 TTS 生成:
- 剪映"文字转语音":免费,声线多(古风男声/古风女声/旁白男声)
- 海螺 AI:商用合规
- ElevenLabs:海外,英文短剧用

---

## 输出参数

| 平台 | 分辨率 | 帧率 | 码率 | 文件大小目标 |
|---|---|---|---|---|
| 抖音(竖屏) | 1080×1920 | 30 fps | 6 Mbps | < 30MB(限制) |
| 视频号(竖屏) | 1080×1920 | 30 fps | 6 Mbps | < 100MB |
| B 站(横屏) | 1920×1080 | 30 fps | 8-10 Mbps | < 4GB |
| YouTube Shorts | 1080×1920 | 30 fps | 8 Mbps | 无限制 |
````

- [ ] **Step 2: Commit**

```bash
git add skills/image-to-video/references/post-production-handoff.md
git commit -m "docs(image-to-video): add post-production handoff guide"
```

---

## Phase 2:adapter 实现

### Task 2.1:写 adapters/prompt_only.sh

**Files:**
- Create: `skills/image-to-video/scripts/adapters/prompt_only.sh`

- [ ] **Step 1: 写脚本**

```bash
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

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
MOTION=$(echo "$PROMPT_JSON" | jq -r '.motion_prompt')
DURATION=$(echo "$PROMPT_JSON" | jq -r '.duration')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect')

PROMPT_DIR=$(dirname "$OUT_DIR")/提示词视频
mkdir -p "$PROMPT_DIR"

# Kling 风格(中英混合,简洁)
cat > "$PROMPT_DIR/$SHOT_ID.kling.txt" <<EOF
prompt: $PROMPT_EN. $MOTION
duration: $DURATION
aspect_ratio: $ASPECT
image: ${IMAGE:-<填入镜头图路径>}
EOF

# 即梦风格(中文为主)
cat > "$PROMPT_DIR/$SHOT_ID.jimeng.txt" <<EOF
prompt: ${PROMPT_EN}。${MOTION}
duration: ${DURATION}s
比例: $ASPECT
image: ${IMAGE:-<填入镜头图路径>}
EOF

# Runway 风格(英文,详细)
cat > "$PROMPT_DIR/$SHOT_ID.runway.txt" <<EOF
prompt: $PROMPT_EN

$MOTION

cinematic quality, professional cinematography

duration: ${DURATION}s
aspect_ratio: $ASPECT
input_image: ${IMAGE:-<填入镜头图路径>}
EOF

# 通用 JSON(给写自定义脚本的用户)
cat > "$PROMPT_DIR/$SHOT_ID.json" <<EOF
{
  "prompt_en": $(echo "$PROMPT_EN" | jq -Rs .),
  "motion_prompt": $(echo "$MOTION" | jq -Rs .),
  "duration": $DURATION,
  "aspect": $(echo "$ASPECT" | jq -Rs .),
  "image": $(echo "${IMAGE:-}" | jq -Rs .)
}
EOF

# 在 OUT_DIR 写一个伴随 .json 标记"提示词已导出但无视频"
mkdir -p "$OUT_DIR"
cat > "$OUT_DIR/$SHOT_ID.json" <<EOF
{
  "shot_id": "$SHOT_ID",
  "backend": "prompt-only",
  "status": "prompt_exported_no_video",
  "prompt_files": [
    "$PROMPT_DIR/$SHOT_ID.kling.txt",
    "$PROMPT_DIR/$SHOT_ID.jimeng.txt",
    "$PROMPT_DIR/$SHOT_ID.runway.txt",
    "$PROMPT_DIR/$SHOT_ID.json"
  ],
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "OK $SHOT_ID (prompt-only, see $PROMPT_DIR/$SHOT_ID.*)" >&2
exit 0
```

- [ ] **Step 2: 加可执行权限 + 测试**

```bash
chmod +x skills/image-to-video/scripts/adapters/prompt_only.sh

mkdir -p /tmp/test-v
echo '{
  "prompt_en": "Young Asian woman pushes door open, cinematic",
  "motion_prompt": "Camera: static. Subject motion: pushes door slowly.",
  "duration": 5,
  "aspect": "9:16",
  "shot_meta": {}
}' | ./skills/image-to-video/scripts/adapters/prompt_only.sh \
  --shot-id S001 \
  --out-dir /tmp/test-v/镜头视频 \
  --image /tmp/test-v/镜头图/S001.png

ls /tmp/test-v/提示词视频/ /tmp/test-v/镜头视频/
cat /tmp/test-v/提示词视频/S001.kling.txt
jq . /tmp/test-v/镜头视频/S001.json
```

Expected: 提示词文件 4 个(.kling/.jimeng/.runway/.json),镜头视频/ 下 `S001.json` 含 `backend: prompt-only`。

```bash
rm -rf /tmp/test-v
```

- [ ] **Step 3: Commit**

```bash
git add skills/image-to-video/scripts/adapters/prompt_only.sh
git commit -m "feat(image-to-video): add prompt_only adapter"
```

---

### Task 2.2:写 adapters/kling.sh

**Files:**
- Create: `skills/image-to-video/scripts/adapters/kling.sh`

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# adapters/kling.sh — 可灵后端

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
[[ -z "$IMAGE" ]] && { echo "ERROR: --image required" >&2; exit 2; }
[[ ! -f "$IMAGE" ]] && { echo "ERROR: image not found: $IMAGE" >&2; exit 1; }

API_KEY="${KLING_API_KEY:?ERROR: KLING_API_KEY required}"
BASE_URL="${KLING_BASE_URL:-https://api.klingai.com}"

PROMPT_JSON=$(cat)
PROMPT_EN=$(echo "$PROMPT_JSON" | jq -r '.prompt_en')
MOTION=$(echo "$PROMPT_JSON" | jq -r '.motion_prompt')
DURATION=$(echo "$PROMPT_JSON" | jq -r '.duration | tonumber | floor')
ASPECT=$(echo "$PROMPT_JSON" | jq -r '.aspect')

# 可灵只支持 5 或 10
if [[ "$DURATION" -lt 8 ]]; then
  DURATION=5
else
  DURATION=10
fi

mkdir -p "$OUT_DIR"

# 1. 把图片转 base64
IMAGE_B64=$(base64 -w 0 "$IMAGE" 2>/dev/null || base64 "$IMAGE" | tr -d '\n')

# 2. 提交任务
SUBMIT_RESPONSE=$(mktemp)
trap "rm -f $SUBMIT_RESPONSE" EXIT

FULL_PROMPT="${PROMPT_EN}. ${MOTION}"

curl -s "${BASE_URL}/v1/videos/image2video" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"image\": \"${IMAGE_B64}\",
    \"prompt\": $(echo "$FULL_PROMPT" | jq -Rs .),
    \"duration\": ${DURATION},
    \"aspect_ratio\": $(echo "$ASPECT" | jq -Rs .)
  }" > "$SUBMIT_RESPONSE"

ERROR_MSG=$(jq -r '.error.message // empty' "$SUBMIT_RESPONSE")
if [[ -n "$ERROR_MSG" ]]; then
  echo "ERROR: Kling submit failed: $ERROR_MSG" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

TASK_ID=$(jq -r '.data.task_id // .task_id // empty' "$SUBMIT_RESPONSE")
if [[ -z "$TASK_ID" ]]; then
  echo "ERROR: Kling response missing task_id" >&2
  cat "$SUBMIT_RESPONSE" >&2
  exit 1
fi

echo "[kling] submitted task=$TASK_ID, polling..." >&2

# 3. 轮询
VIDEO_URL=$(poll_task \
  --check-url "${BASE_URL}/v1/videos/image2video/${TASK_ID}" \
  --auth-header "Authorization: Bearer ${API_KEY}" \
  --status-jq '.data.task_status // .status' \
  --done-values "succeed,completed,success" \
  --fail-values "failed,error" \
  --result-jq '.data.videos[0].url // .video_url' \
  --interval 10 \
  --timeout 600)

if [[ -z "$VIDEO_URL" ]]; then
  echo "ERROR: Kling poll returned empty URL" >&2
  exit 1
fi

# 4. 下载视频
curl -sL "$VIDEO_URL" -o "$OUT_DIR/$SHOT_ID.mp4"

if [[ ! -s "$OUT_DIR/$SHOT_ID.mp4" ]]; then
  echo "ERROR: downloaded video is empty" >&2
  exit 1
fi

# 5. 写伴随 .json
cat > "$OUT_DIR/$SHOT_ID.json" <<EOF
{
  "shot_id": "$SHOT_ID",
  "backend": "kling",
  "task_id": $(echo "$TASK_ID" | jq -Rs .),
  "video_url": $(echo "$VIDEO_URL" | jq -Rs .),
  "duration": $DURATION,
  "aspect": $(echo "$ASPECT" | jq -Rs .),
  "input_image": $(echo "$IMAGE" | jq -Rs .),
  "prompt": $(echo "$FULL_PROMPT" | jq -Rs .),
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "OK $SHOT_ID -> $OUT_DIR/$SHOT_ID.mp4" >&2
exit 0
```

- [ ] **Step 2: 加可执行权限 + 语法检查**

```bash
chmod +x skills/image-to-video/scripts/adapters/kling.sh
bash -n skills/image-to-video/scripts/adapters/kling.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 3: 真 API 测试(可选,需要 KLING_API_KEY)**

```bash
if [[ -n "${KLING_API_KEY:-}" ]]; then
  # 需要一张测试图
  if [[ ! -f /tmp/test-image.png ]]; then
    echo "skipping: no /tmp/test-image.png" >&2
  else
    mkdir -p /tmp/test-v
    echo '{
      "prompt_en": "Young Asian woman in dark robes",
      "motion_prompt": "Camera: static. Subject motion: subtle natural motion.",
      "duration": 5,
      "aspect": "9:16"
    }' | ./skills/image-to-video/scripts/adapters/kling.sh \
      --shot-id S001 \
      --out-dir /tmp/test-v \
      --image /tmp/test-image.png
    ls -la /tmp/test-v/
    jq . /tmp/test-v/S001.json
    rm -rf /tmp/test-v
  fi
fi
```

注:可灵 API 的具体字段(`.data.task_status` vs `.status`,`.data.videos[0].url` vs `.video_url`)在不同代理服务商有差异,真测时按服务商文档微调 `--status-jq` / `--result-jq`。

- [ ] **Step 4: Commit**

```bash
git add skills/image-to-video/scripts/adapters/kling.sh
git commit -m "feat(image-to-video): add kling adapter"
```

---

## Phase 3:route.sh

### Task 3.1:写 scripts/route.sh

**Files:**
- Create: `skills/image-to-video/scripts/route.sh`

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# image-to-video/scripts/route.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"

ARGS=("$@")
BACKEND="${VIDEO_BACKEND:-}"

if [[ -z "$BACKEND" ]]; then
  if [[ -n "${KLING_API_KEY:-}" && -n "${KLING_BASE_URL:-}" ]]; then
    BACKEND="kling"
  elif [[ -n "${JIMENG_API_KEY:-}" && -n "${JIMENG_BASE_URL:-}" ]] && [[ -x "$ADAPTERS_DIR/jimeng.sh" ]]; then
    BACKEND="jimeng"
  elif [[ -n "${RUNWAY_API_KEY:-}" ]] && [[ -x "$ADAPTERS_DIR/runway.sh" ]]; then
    BACKEND="runway"
  elif [[ -n "${SORA_API_KEY:-}" && -n "${SORA_BASE_URL:-}" ]] && [[ -x "$ADAPTERS_DIR/sora.sh" ]]; then
    BACKEND="sora"
  elif [[ -n "${VEO_API_KEY:-}" ]] && [[ -x "$ADAPTERS_DIR/veo.sh" ]]; then
    BACKEND="veo"
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
  echo "ERROR: adapter not executable: $ADAPTER" >&2
  exit 1
fi

echo "[route] dispatching to backend=$BACKEND" >&2
exec "$ADAPTER" "${ARGS[@]}"
```

注:Plan 3 没实现 jimeng/runway/sora/veo,所以 route.sh 检查 `-x` 文件存在再用 — 文件不存在时跳过这个 backend,继续尝试下一个。

- [ ] **Step 2: 加可执行权限 + 测试 prompt-only 路由**

```bash
chmod +x skills/image-to-video/scripts/route.sh

mkdir -p /tmp/test-v
echo '{
  "prompt_en": "x",
  "motion_prompt": "y",
  "duration": 5,
  "aspect": "9:16"
}' | env -i PATH="$PATH" HOME="$HOME" \
  ./skills/image-to-video/scripts/route.sh \
    --shot-id S001 \
    --out-dir /tmp/test-v/镜头视频 \
    --image /tmp/test-v/dummy.png
```

Expected:
- stderr 含 `[route] dispatching to backend=prompt-only`
- 提示词文件落到 `/tmp/test-v/提示词视频/`
- exit 0

```bash
ls /tmp/test-v/提示词视频/ /tmp/test-v/镜头视频/
rm -rf /tmp/test-v
```

- [ ] **Step 3: Commit**

```bash
git add skills/image-to-video/scripts/route.sh
git commit -m "feat(image-to-video): add route.sh dispatcher"
```

---

## Phase 4:SKILL.md

### Task 4.1:写 SKILL.md

**Files:**
- Create: `skills/image-to-video/SKILL.md`

- [ ] **Step 1: 写完整文件**

````markdown
---
name: image-to-video
version: 1.0.0
description: |
  图片转视频。把镜头图 + 运动提示词转成视频片段(每镜 5s 默认),支持多生视频后端(可灵 / 即梦 / Runway / Sora / Veo / prompt-only)。
  触发方式:/image-to-video、/图片转视频、「图生视频」「出视频」
metadata:
  openclaw:
    requires:
      bins:
        - jq
        - curl
        - base64
    source: https://github.com/worldwonderer/oh-story-claudecode
---

# image-to-video:图片转视频

你是图生视频执行者。把每镜的 PNG + 运动提示词转成 5-10s 视频片段,失败不阻塞,末尾汇总。

---

## 核心方法

1. **多后端适配层** — 参考 [references/backend-cheatsheet.md](references/backend-cheatsheet.md)
2. **prompt 决定运动** — 模型不看图猜动作,要靠 prompt 写明白。参考 [references/motion-prompts.md](references/motion-prompts.md)
3. **不做合成** — 只产逐镜 .mp4,后期工具拼接。参考 [references/post-production-handoff.md](references/post-production-handoff.md)

---

## Phase 1:后端选择

按 [references/backend-cheatsheet.md](references/backend-cheatsheet.md) 优先级。

告知用户:
- 后端、单镜成本、全集预算
- 异步任务等待时间(可灵典型 2-5 min/镜)

---

## Phase 2:运动提示词构造

每镜的 motion prompt 由 [references/motion-prompts.md](references/motion-prompts.md) 模板构造:

```
{description_en}

Camera: {camera_motion}.
Subject motion: {subject_action}.
Atmosphere: {lighting}, {mood}.
Duration: {N}s.
```

`camera_motion` 从 `镜头表.json` 的 `camera` 字段映射(详见 motion-prompts.md)。

---

## Phase 3:逐镜生视频

```bash
EPISODE_DIR="{工作根}/第NNN集"
mkdir -p "$EPISODE_DIR/镜头视频"

source ./scripts/lib/json.sh

for SHOT_ID in $(jq -r '.shots[].id' "$EPISODE_DIR/镜头表.json"); do
  SHOT=$(jq -c ".shots[] | select(.id == \"$SHOT_ID\")" "$EPISODE_DIR/镜头表.json")
  DURATION=$(echo "$SHOT" | jq -r '.duration')
  IMAGE="$EPISODE_DIR/镜头图/${SHOT_ID}.png"
  
  if [[ ! -f "$IMAGE" ]]; then
    echo "$SHOT_ID:missing_image" >> "$EPISODE_DIR/.failures.json"
    continue
  fi
  
  PROMPT_JSON=$(build_video_prompt_json "$SHOT" "$DURATION" "{aspect}")
  
  if echo "$PROMPT_JSON" | ./scripts/route.sh \
       --shot-id "$SHOT_ID" \
       --out-dir "$EPISODE_DIR/镜头视频" \
       --image "$IMAGE"; then
    : # 成功
  else
    echo "$SHOT_ID:adapter_failed" >> "$EPISODE_DIR/.failures.json"
  fi
done
```

注:可灵等后端是异步,单镜 2-5 分钟。50 镜串行跑 ≈ 2-4 小时。如要并行,用 `xargs -P 4` 包裹(后端通常有并发限制,慎用)。

---

## Phase 4:失败重试

```
/image-to-video --retry-failures
```

逻辑同 `shot-to-image`。

---

## Phase 5:生成 manifest + 字幕脚本

跑完后生成两份汇总:

### _manifest.json(在 `{EPISODE_DIR}/`)

```json
{
  "episode": NNN,
  "total_shots": 50,
  "succeeded": 47,
  "failed": 3,
  "total_duration": 195.5,
  "shots": [
    {"id": "S001", "duration": 5, "video": "镜头视频/S001.mp4", "status": "ok"},
    ...
  ]
}
```

### 字幕脚本.txt(在 `{EPISODE_DIR}/`)

按 [references/post-production-handoff.md](references/post-production-handoff.md) 格式累加每镜对白/OS + 时间码。

---

## Phase 6:交付提示

- 成功 X 镜 / 失败 Y 镜
- 总时长 / 总成本
- 产物路径
- 下一步:打开剪映/Pr,按 [references/post-production-handoff.md](references/post-production-handoff.md) 做后期

---

## 参考资料索引

| 场景 | 文件 |
|---|---|
| 运动提示词模板 | [references/motion-prompts.md](references/motion-prompts.md) |
| 后端速查 | [references/backend-cheatsheet.md](references/backend-cheatsheet.md) |
| 失败排查 | [references/image-to-video-pitfalls.md](references/image-to-video-pitfalls.md) |
| 后期交付 | [references/post-production-handoff.md](references/post-production-handoff.md) |

---

## 流程衔接

| 时机 | 跳转到 | 命令 |
|---|---|---|
| 视频出完 | 后期工具(剪映/Pr) | 见 post-production-handoff.md |
| 某镜不满意 | 单镜重生 | `/image-to-video --redo S017` |
| 失败重试 | `--retry-failures` | — |

---

## 语言

- 跟随用户的语言回复
````

- [ ] **Step 2: Commit**

```bash
git add skills/image-to-video/SKILL.md
git commit -m "feat(image-to-video): add main SKILL.md"
```

---

## Phase 5:集成测试

### Task 5.1:端到端测试(prompt-only 后端)

**Files:**
- 无新建

- [ ] **Step 1: 准备测试目录(含镜头图)**

```bash
mkdir -p /tmp/test-i2v/短剧/第001集/{镜头图,镜头视频}
cp tests/fixtures/expected-shotlist.json /tmp/test-i2v/短剧/第001集/镜头表.json

# 创建 dummy PNG(全黑 1x1)给 prompt-only 测试用
for SHOT_ID in S001 S002 S003; do
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x00\x00\x00\x00\x3a\x7e\x9b\x55\x00\x00\x00\nIDAT\x08\xd7c\x60\x00\x00\x00\x02\x00\x01\xe5\x27\xde\xfc\x00\x00\x00\x00IEND\xaeB\x60\x82' > /tmp/test-i2v/短剧/第001集/镜头图/${SHOT_ID}.png
done
```

- [ ] **Step 2: 跑全集**

```bash
EPISODE_DIR=/tmp/test-i2v/短剧/第001集
SKILL_DIR="$(pwd)/skills/image-to-video"

source "$SKILL_DIR/scripts/lib/json.sh"

for SHOT_ID in $(jq -r '.shots[].id' "$EPISODE_DIR/镜头表.json"); do
  SHOT=$(jq -c ".shots[] | select(.id == \"$SHOT_ID\")" "$EPISODE_DIR/镜头表.json")
  DURATION=$(echo "$SHOT" | jq -r '.duration')
  IMAGE="$EPISODE_DIR/镜头图/${SHOT_ID}.png"
  
  PROMPT_JSON=$(build_video_prompt_json "$SHOT" "$DURATION" "9:16")
  
  echo "$PROMPT_JSON" | env -i PATH="$PATH" HOME="$HOME" \
    "$SKILL_DIR/scripts/route.sh" \
      --shot-id "$SHOT_ID" \
      --out-dir "$EPISODE_DIR/镜头视频" \
      --image "$IMAGE"
done

ls "$EPISODE_DIR/提示词视频/"
ls "$EPISODE_DIR/镜头视频/"
```

Expected:
- `提示词视频/` 下:`S001.kling.txt`、`S001.jimeng.txt`、`S001.runway.txt`、`S001.json`(S002/S003 同)
- `镜头视频/` 下:`S001.json`、`S002.json`、`S003.json`(无 .mp4,因为 prompt-only)

- [ ] **Step 3: 校验单个提示词文件内容**

```bash
cat /tmp/test-i2v/短剧/第001集/提示词视频/S001.kling.txt
cat /tmp/test-i2v/短剧/第001集/提示词视频/S002.runway.txt
```

Expected: 含 prompt + motion + duration + image 路径。

- [ ] **Step 4: 清理 + commit(如有改动)**

```bash
rm -rf /tmp/test-i2v
```

如有改动:
```bash
git add skills/image-to-video
git commit -m "fix(image-to-video): refine based on integration test"
```

---

### Task 5.2:端到端测试(kling 后端,需要 API key,可选)

**Files:**
- 无新建

- [ ] **Step 1: 只在用户有 KLING_API_KEY 时跑,且只跑 1 镜 smoke test**

```bash
if [[ -z "${KLING_API_KEY:-}" || -z "${KLING_BASE_URL:-}" ]]; then
  echo "skipping kling integration test (no API key)"
  exit 0
fi

# 需要一张真测试图(从 shot-to-image 测试产物拿,或者用户提供)
if [[ ! -f /tmp/real-shot-image.png ]]; then
  echo "skipping: no /tmp/real-shot-image.png (need a real image to test image-to-video)"
  exit 0
fi
```

- [ ] **Step 2: 跑 1 镜**

```bash
mkdir -p /tmp/test-i2v-real
SHOT='{"id":"S001","camera":"static","duration":5,"description_en":"Young Asian woman in dark robes stands at temple gate","lighting":"moody candlelight","mood":"tense"}'
SKILL_DIR="$(pwd)/skills/image-to-video"

source "$SKILL_DIR/scripts/lib/json.sh"
PROMPT_JSON=$(build_video_prompt_json "$SHOT" "5" "9:16")

echo "$PROMPT_JSON" | "$SKILL_DIR/scripts/route.sh" \
  --shot-id S001 \
  --out-dir /tmp/test-i2v-real \
  --image /tmp/real-shot-image.png

ls -la /tmp/test-i2v-real/
jq . /tmp/test-i2v-real/S001.json
```

Expected:
- 等待 2-5 分钟(轮询)
- `S001.mp4` 存在,非零字节
- `S001.json` 含 `backend: kling`、`task_id`、`video_url`

- [ ] **Step 3: 清理**

```bash
rm -rf /tmp/test-i2v-real
```

- [ ] **Step 4: Commit(如 kling.sh 调整了 jq 路径或参数)**

实际跑可能发现可灵 API 的 status/result 字段路径跟脚本里写的不一样(`.data.task_status` vs `.status`)。按实际调用结果调整 `--status-jq` 和 `--result-jq` 参数。

如有改动:
```bash
git add skills/image-to-video/scripts/adapters/kling.sh
git commit -m "fix(image-to-video): adjust kling jq paths based on real API response"
```

---

## Plan 3 完成验收

跑通以下流程 → Plan 3 验收通过:

1. `VIDEO_BACKEND=prompt-only /image-to-video` 把 3 镜的镜头表 + dummy PNG 转出提示词文件 + 伴随 .json
2. `_manifest.json` 和 `字幕脚本.txt` 生成正确
3. (可选)`KLING_API_KEY` 配齐时,kling 后端能产真 .mp4

下一步:Plan 4(`story-pipeline` 编排 + 其余 adapter:MJ/Replicate/Fal/Comfy/jimeng/runway/sora/veo + `/story` 路由集成)。
