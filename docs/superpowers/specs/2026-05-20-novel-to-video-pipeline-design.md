# 小说 → 视频影视化流水线设计

**日期**: 2026-05-20
**状态**: 待实现
**作者**: brainstorming session(用户:wujie)

---

## 0. 背景与目标

oh-story-claudecode 项目当前已有完整的网文写作流水线(扫榜→拆文→写作→去 AI 味),但写完之后无法把成品转成短视频形态。本设计新增一条"影视化"流水线,把小说一路转成 AI 短剧。

**最终交付物**:AI 短剧(横屏或竖屏,完整短剧)。

**5 个新 skill**:

| skill 名 | 角色 |
|---|---|
| `story-to-script` | 小说 → 拍摄本/分镜本 |
| `script-to-shot` | 剧本 → 镜头表 |
| `shot-to-image` | 镜头表 → 镜头图(含角色卡预生成) |
| `image-to-video` | 镜头图 → 镜头视频片段 |
| `story-pipeline` | 编排 5 步,分步闸门 |

**关键设计决策**:
- 适配层走重工程方案,生图/生视频每个后端都配齐 bash 适配器
- 角色一致性走"角色卡预生成 + 复用"工程方案
- 默认 1 章 = 1 集,用户可指定其他粒度
- 剧本默认中文短剧拍摄本,可选分镜本
- 流水线默认分步闸门,每个阶段交付后暂停等用户确认
- 不做视频合成/BGM/字幕——这些交后期工具(剪映/Pr/DaVinci)

---

## 1. Skill 命名与触发

跟现有 `story-long-*` / `story-short-*` 命名一致。

| skill 名 | 触发词 |
|---|---|
| `story-to-script` | `/story-to-script` `/小说转剧本` 「转剧本」「改编」 |
| `script-to-shot` | `/script-to-shot` `/剧本转镜头` 「分镜」「画分镜」 |
| `shot-to-image` | `/shot-to-image` `/镜头转图片` 「生镜头图」 |
| `image-to-video` | `/image-to-video` `/图片转视频` 「图生视频」 |
| `story-pipeline` | `/story-pipeline` `/小说转视频` 「拍短剧」「开拍」 |

每个 skill 同时写入 `.claude-plugin/marketplace.json`,跟现有条目同 schema,category 用新分类 `novel-video`。

`/story` 路由表(`skills/story/SKILL.md`)增加这 5 个出口,放在"写作"流水线后面接一段"影视化"流水线。

---

## 2. 工作目录与产物布局

跟 long-write 现有 `{书名}/` 结构无缝共存,在书名目录下加 `短剧/` 子目录,每集独立:

```
{书名}/
├── 设定/...                       # ← long-write 已有
├── 大纲/...                       # ← long-write 已有
├── 正文/第001章_*.md              # ← long-write 已有
├── 追踪/...                       # ← long-write 已有
└── 短剧/                          # ← 新增,本流水线产物
    ├── 角色卡/                    # 整书共享(写一次,各集复用)
    │   ├── 沈栀.png
    │   ├── 沈栀.json              # {prompt_en, refer_url, mj_cref_url, ...}
    │   └── ...
    ├── 第001集/                   # 对应小说第 1 章(默认 1 章 = 1 集)
    │   ├── 拍摄本.md              # story-to-script 产物
    │   ├── 分镜本.md              # 可选,story-to-script 二档产物
    │   ├── 镜头表.md              # script-to-shot 产物(人读)
    │   ├── 镜头表.json            # script-to-shot 产物(机器读,给下游)
    │   ├── 提示词/                # shot-to-image 提示词导出
    │   │   ├── S001.mj.txt
    │   │   ├── S001.sd.json
    │   │   └── ...
    │   ├── 镜头图/                # shot-to-image 产物
    │   │   ├── S001.png
    │   │   ├── S001.json          # {prompt, backend, seed, refer, ...}
    │   │   └── ...
    │   ├── 镜头视频/              # image-to-video 产物
    │   │   ├── S001.mp4
    │   │   ├── S001.json          # {motion_prompt, backend, duration, ...}
    │   │   └── ...
    │   ├── .failures.json         # 失败镜清单,供 --retry 使用
    │   └── .pipeline.state.json   # 编排 skill 的闸门状态
    └── 第002集/
```

**独立模式**(用户没走 long-write,只丢了一段小说):`./短剧产物/{时间戳}-{标题}/...` 起一个临时根,内部结构同上(`角色卡/` + `第001集/`)。

**智能识别**:skill 启动时按顺序检测:
1. 当前目录有 `设定/` + `大纲/` + `正文/` → 判定为 long-write 项目,在 `{当前目录}/短剧/` 下写
2. 否则 → 询问用户给一段文本/一个 md 文件,落到 `./短剧产物/{时间戳}-{用户给的标题}/`

---

## 3. 数据流与跨 skill 契约

5 个 skill 之间用文件传递,每个 skill 的输入输出都是文件路径,不在对话里堆内容。

### 3.1 拍摄本格式(`拍摄本.md`)

中文短剧行业标准,场号 + 场景抬头 + 动作 + 对白 + OS(画外音/内心独白)。

```
# 第 001 集:{集名}

## 场 1 — 内·巫术司大厅·夜

(沈栀推门而入,雨水顺着发梢滴落。烛火在她脸上摇晃。)

司长:你来晚了。
沈栀:我母亲死了。
(OS:三年前她也说过同样的话。)

## 场 2 — 内·档案室·夜
...
```

**约定**:
- 场号严格自增、不跳号
- 场景抬头必带"内/外·地点·时辰"(三段式)
- 对白前缀用角色名加冒号
- OS 用括号包裹,以 `OS:` 开头
- 动作描述用括号包裹,不加前缀

### 3.2 镜头表(`镜头表.md` + `镜头表.json`)

**镜头表.md**(给人审、给用户改):

| 镜号 | 场号 | 景别 | 运镜 | 时长 | 画面描述 | 角色 | 对白/OS | 备注 |
|---|---|---|---|---|---|---|---|---|
| S001 | 场1 | 中景 | 固定 | 3s | 沈栀推开巫术司大门,雨水从屋檐滴落 | 沈栀 | — | 开场氛围 |
| S002 | 场1 | 特写 | 推 | 2s | 沈栀眼眸,睫毛挂着水珠 | 沈栀 | OS:三年前她也说过同样的话 | 情绪铺垫 |

**镜头表.json**(给下游 skill 机器读):

```json
{
  "episode": 1,
  "shots": [
    {
      "id": "S001",
      "scene": 1,
      "framing": "MS",
      "camera": "static",
      "duration": 3.0,
      "description_cn": "沈栀推开巫术司大门,雨水从屋檐滴落",
      "description_en": "A young woman in dark robes pushes open heavy wooden doors of a sorcery bureau, rain dripping from the eaves...",
      "characters": ["沈栀"],
      "dialogue": null,
      "os": null,
      "location": "巫术司大厅",
      "time_of_day": "夜",
      "lighting": "moody candlelight, cool blue rain backlight",
      "mood": "tense, foreboding"
    }
  ]
}
```

**枚举约束**:
- 景别:`ELS / LS / MS / MCU / CU / ECU`(远全中近特特写,字段用英文缩写避免歧义)
- 运镜:`static / pan / tilt / push / pull / track / handheld / orbit`

**关键设计**:`description_en` 由 script-to-shot 同步翻译并扩写出来,下游所有提示词都基于这一字段构造,不重复翻译。

### 3.3 角色卡(`角色卡/{角色名}.png + .json`)

**.json schema**:

```json
{
  "name": "沈栀",
  "description_cn": "二十出头女性,长发及腰,深色道袍,左眉有疤",
  "description_en": "Asian woman, early twenties, waist-length black hair, dark high-collar robe, faint scar above left eyebrow, pale skin, sharp eyes",
  "reference_png": "角色卡/沈栀.png",
  "mj_cref_url": "https://...",       // 上传到 MJ 代理后回填
  "jimeng_refer_id": "...",            // 即梦回填
  "kling_subject_id": "...",           // 可灵回填
  "comfy_lora_path": null              // SD 后端走 LoRA 时手动填
}
```

每个生图/生视频后端"指认这是同一个人"的字段都给好位置。某后端不用就留 null。

### 3.4 镜头图与镜头视频伴随的 .json

每张图、每条视频都配一个 .json,记录生成它的真实参数(prompt/backend/seed/refer/duration/...),用于追溯和复跑。

---

## 4. 适配层架构(方案 A 重工程的核心)

### 4.1 后端枚举与环境变量

**生图(`shot-to-image`)**

| backend 值 | 后端 | 必填环境变量 | 角色一致性机制 |
|---|---|---|---|
| `gpt-image` | GPT-Image-2(复用 story-cover) | `GPT_IMAGE_API_KEY` | 提示词描述 |
| `mj` | Midjourney 第三方代理 | `MJ_API_KEY`,`MJ_BASE_URL` | `--cref` 角色卡 URL |
| `replicate` | Replicate(FLUX/SDXL) | `REPLICATE_API_TOKEN` | IP-Adapter / image input |
| `fal` | Fal.ai(FLUX) | `FAL_KEY` | IP-Adapter / image input |
| `comfy` | 本地 ComfyUI | `COMFY_HOST`(默认 127.0.0.1:8188) | 自定义 workflow.json |
| `prompt-only` | 不调 API,只导出 .txt/.json | 无 | — |

**生视频(`image-to-video`)**

| backend 值 | 后端 | 必填环境变量 |
|---|---|---|
| `kling` | 可灵 | `KLING_API_KEY`,`KLING_BASE_URL` |
| `jimeng` | 即梦(火山方舟) | `JIMENG_API_KEY`,`JIMENG_BASE_URL` |
| `runway` | Runway Gen-3 | `RUNWAY_API_KEY` |
| `sora` | Sora 2(占位,API 受限) | `SORA_API_KEY`,`SORA_BASE_URL` |
| `veo` | Google Veo(占位) | `VEO_API_KEY` |
| `prompt-only` | 仅导出提示词 | 无 |

**后端选择优先级**:
1. CLI 用户显式说"用可灵"/"用 MJ" → 直接路由
2. 环境变量 `IMG_BACKEND` / `VIDEO_BACKEND` 显式指定 → 路由
3. 没指定 → 按上表从上往下扫,第一个环境变量齐的就用
4. 全没齐 → 降级到 `prompt-only`,提示用户配 key

### 4.2 适配器目录结构

```
skills/shot-to-image/
├── SKILL.md
├── references/
│   ├── prompt-construction.md      # 中→英画面描述、镜头语言提示词模板
│   ├── backend-cheatsheet.md       # 每个后端的提示词风格差异、参数范围
│   ├── character-consistency.md    # 角色一致性的 4 套工程方案
│   ├── failure-modes.md            # 文字渲染失败、人物变形、机位错乱怎么修
│   └── cost-table.md               # 各后端单图价格 / 每集预算估算
└── scripts/
    ├── route.sh                    # 入口:读 IMG_BACKEND,dispatch 到具体 adapter
    ├── adapters/
    │   ├── gpt_image.sh
    │   ├── mj.sh
    │   ├── replicate.sh
    │   ├── fal.sh
    │   ├── comfy.sh
    │   └── prompt_only.sh
    └── lib/
        ├── poll.sh                 # MJ/Kling 等异步任务的轮询封装
        └── json.sh                 # jq 包装,统一 .json 读写
```

`skills/image-to-video/` 结构对称(adapters/ 下放 kling.sh / jimeng.sh / runway.sh / sora.sh / veo.sh / prompt_only.sh)。

### 4.3 适配器统一接口契约

每个 adapter 是一个 bash 脚本,调用约定:

```bash
# 输入:命令行参数 + stdin JSON
./scripts/adapters/mj.sh \
  --shot-id S001 \
  --out-dir 第001集/镜头图 \
  --refer 角色卡/沈栀.png \
  < prompt.json

# stdin JSON schema(由 route.sh 构造):
# {
#   "prompt_en": "...",
#   "negative": "...",
#   "aspect": "9:16",
#   "seed": 42,
#   "shot_meta": {...}     # 整条镜头记录,adapter 按需读
# }

# 输出:
# - 成功:写 S001.png + S001.json 到 out-dir,exit 0
# - 失败:错误打 stderr,exit 非 0;route.sh 捕获后给用户清晰报错
```

这套契约让每个 adapter 独立可测、独立可换。新增后端就是加一个 `.sh` + 在 route.sh 加一行 case。

### 4.4 异步任务轮询

MJ 代理、可灵、Sora 都是异步(提交 → 拿 task_id → 轮询)。`lib/poll.sh` 提供统一 polling:

```bash
poll_task \
  --check-url "${MJ_BASE_URL}/task/${TASK_ID}" \
  --auth-header "Authorization: Bearer ${MJ_API_KEY}" \
  --status-jq '.status' \
  --done-values "SUCCESS,success,completed" \
  --fail-values "FAILED,failed,error" \
  --result-jq '.image_url' \
  --interval 5 \
  --timeout 300
```

超时 / 失败 / 限流统一处理,各 adapter 不重复写轮询。

---

## 5. 5 个 skill 各自的内部流程

每个 skill 都跟现有 story-* 一脉相承:中文 SKILL.md / 必要的 references/ 拆分 / 优先用对话路由,大于一定复杂度走子 agent。

### 5.1 `story-to-script`(小说 → 拍摄本)

**输入**:
- long-write 模式:`{书名}/正文/第N章_*.md`(可指定单章/范围/卷)
- 独立模式:用户给的一段文本或 md 文件

**Phase 1 — 智能识别 + 集划分**
- 探测目录 → 选模式
- 跟用户确认:转哪几章、几章成一集(默认 1 章 = 1 集)、横屏/竖屏(影响后续宽高比)

**Phase 2 — 上下文召回**(long-write 模式)
- 读 `设定/角色/*.md` 中本章涉及角色 → 提取角色外貌、性格、口头禅
- 读 `追踪/角色状态.md`(如存在)→ 当前状态、关系
- 读 `大纲/细纲_第N章.md`(如存在)→ 章节情绪目标、爽点设计、钩子

**Phase 3 — 改编决策(关键)**
- 短剧不是逐字还原,要做删/合/加:
  - 心理描写 → 外化为台词、动作、OS、物件
  - 多线叙事 → 收敛到主角视角
  - 长对话 → 砍到 3 句以内,留最重要的一句
  - 没有动作的章节 → 加一个外部事件锚定
- 用户可指定改编强度(忠于原著 / 节奏优先 / 大刀阔斧)

**Phase 4 — 输出**
- 默认 → `短剧/第N集/拍摄本.md`
- 用户要分镜本 → 额外产 `短剧/第N集/分镜本.md`(在拍摄本基础上加镜号、景别、运镜列)

**references/**:
- `adaptation-principles.md`(改编三档:还原/节奏/重写)
- `script-format-spec.md`(拍摄本/分镜本格式规范、例子)
- `dialogue-compression.md`(对白怎么砍、怎么留)
- `os-monologue-tricks.md`(内心戏怎么改成 OS / 物件 / 配角嘴里讲出来)

### 5.2 `script-to-shot`(拍摄本 → 镜头表)

**输入**:`短剧/第N集/拍摄本.md`

**Phase 1 — 解析拍摄本**
- 用正则切场号 → 抓动作、对白、OS

**Phase 2 — 分镜决策**
每场按节奏决定镜头数:
- 平均 1 个对白 = 1-2 镜
- 1 个动作 = 1-3 镜
- 1 个 OS = 1 镜(通常配特写或环境镜)
- 一集目标镜头数:横屏 30-50 镜、竖屏 40-60 镜(竖屏节奏更快)

**Phase 3 — 镜头语言注入**
每镜补:
- **景别**:对白以中近为主,情绪点用特写,环境/场景切换用全景
- **运镜**:静态为主,关键情绪用推/拉,动作戏用跟/手持
- **时长**:对白镜按台词节奏(中文约 3 字/秒,1 句典型 2-4s)、纯画面镜 2-3s、特写情绪 1-2s
- **lighting/mood**:从场景抬头的"内外/时辰"推断 + 拍摄本氛围词

**Phase 4 — 同步翻译并扩写英文画面描述**
- `description_en` 字段:中文画面描述 → 英文,同时扩写视觉细节(光线、色温、构图角度、纵深),为下游生图提示词省一步
- 这是 script-to-shot 最值钱的产出,翻译质量直接决定后面所有图的下限

**Phase 5 — 双写输出**
- `镜头表.md`(人审、可改)
- `镜头表.json`(机器读)
- 二者必须一致;skill 退出前做一次校验(镜号、场号、字段名、duration 总和 ≈ 集长目标)

**references/**:
- `shot-language.md`(景别/运镜/构图/光线词表)
- `pacing-templates.md`(对白镜/动作镜/情绪镜各自的时长经验值)
- `cn-to-en-visual-translation.md`(中文画面描述 → 英文电影感描述的对照模板)

### 5.3 `shot-to-image`(镜头表 → 镜头图)

**Phase 1 — 后端选择**
- 按节 4.1 优先级决定 `IMG_BACKEND`
- 告知用户:本次用什么后端、为什么、跑全集预估多少张/多少钱(每张图大致价格表 references 里给)

**Phase 2 — 角色卡预生成(关键)**
- 扫 `镜头表.json` 中所有 `characters[]` → 去重得"本集角色清单"
- 对每个角色:`角色卡/{name}.png` 不存在则生成
  - 调 `route.sh` 走"角色卡生成"模式(prompt 模板见 references):正面胸像、纯色背景、中性表情、清晰五官
  - 写 `角色卡/{name}.png` + `.json`(含描述,以及该后端的"指认 ID"字段——MJ 走上传得 `--cref` URL,可灵/即梦走上传得 subject_id)
- 已存在 → 跳过(用户想重做就删了重跑)

**Phase 3 — 逐镜生图**
- 遍历 `镜头表.json` 的 shots
- 对每镜构造 prompt(prompt-construction.md 模板):
  ```
  {description_en}, {lighting}, {mood},
  cinematic film still, {aspect_keyword},
  shot on {camera_lens_keyword},
  {framing_keyword} shot,
  featuring {character_refer_hint}
  ```
- 调 `route.sh` → adapter
- 写 `镜头图/{shot_id}.png` + `.json`

**Phase 4 — 一致性自检(可选)**
- 对每个角色出现的镜头,跟其角色卡做相似度检查(用户开了 `--check-consistency` 才跑,基础版用 LLM 多模态对比,advanced 走 face embedding)
- 不一致 → 标记 + 提示用户重生

**Phase 5 — 失败重试**
- 单镜失败不阻塞全集,失败镜记到 `第N集/.failures.json`
- 末尾汇总:成功 X 镜、失败 Y 镜,提示用户 `/shot-to-image --retry-failures`

**references/**:
- `prompt-construction.md`(中→英画面描述、镜头语言提示词模板)
- `backend-cheatsheet.md`(每个后端的提示词风格差异、参数范围)
- `character-consistency.md`(MJ --cref / SD IP-Adapter / 即梦 Refer / 可灵主体参考 四套方案)
- `failure-modes.md`(文字渲染失败、人物变形、机位错乱怎么修)
- `cost-table.md`(各后端单图价格 / 每集预算估算)

### 5.4 `image-to-video`(镜头图 → 镜头视频)

**Phase 1 — 后端选择**(同上,按 `VIDEO_BACKEND` 优先级)

**Phase 2 — 运动提示词构造**
- 每镜的 `camera`(运镜) + `description_en` + 角色动作 → 视频运动提示词
- 模板(因后端略调):
  ```
  Camera: {camera_motion}, {camera_speed}
  Subject motion: {character_action}
  Atmosphere: {mood}, {duration}s
  ```

**Phase 3 — 逐镜生视频**
- 输入:`镜头图/{shot_id}.png` + 上面构造的运动提示词
- 调 `route.sh` → adapter(可灵/即梦/Runway/...)
- 异步任务通过 `lib/poll.sh` 轮询
- 写 `镜头视频/{shot_id}.mp4` + `.json`(记录后端、时长、用了哪张参考图、运动提示词)

**Phase 4 — 失败重试 + 汇总**
- 失败单独记录,不阻塞
- 末尾汇总:成功 X 段、总时长 Y 秒、预估剪辑后片长

**Phase 5 — 不做合成**
- 不做拼接 / 不做 BGM / 不做字幕——这超出本流水线
- 输出说明里告诉用户:剪映/Pr/DaVinci 拖进去,按镜号顺序拼,加 BGM 和 TTS 配音

**references/**:
- `motion-prompts.md`(每种运镜/运动的英文模板)
- `backend-cheatsheet.md`(可灵/即梦/Runway 提示词风格差异、时长上限、价格)
- `image-to-video-pitfalls.md`(图片不动、人物畸变、运动方向错的 troubleshoot)
- `post-production-handoff.md`(后期工具链推荐和导入指南)

### 5.5 `story-pipeline`(编排)

见第 6 节。

---

## 6. `story-pipeline` 的分步闸门

```
                                            +-- 用户改 → 重跑某节
                                            |
[gate-0] 准备                                v
   └─ 集划分确认                       (任何闸门都可循环)
   └─ 后端探测报告(图/视频)
   └─ 预算预估
        |
        v
[gate-1] 拍摄本   ← story-to-script
   └─ 产物:拍摄本.md
   └─ ★ 暂停 → 用户读、改、批"继续"
        |
        v
[gate-2] 镜头表   ← script-to-shot
   └─ 产物:镜头表.md + .json
   └─ ★ 暂停 → 用户改镜号/景别/英文描述,批"继续"
        |
        v
[gate-3] 角色卡   ← shot-to-image(Phase 2 only)
   └─ 产物:角色卡/*.png + .json
   └─ ★ 暂停 → 用户看脸,不满意删了重跑这一闸,批"继续"
        |
        v
[gate-4] 镜头图   ← shot-to-image(Phase 3+)
   └─ 产物:镜头图/*.png + .json
   └─ ★ 暂停 → 用户看图,标记要重生的镜号,跑 --retry,批"继续"
        |
        v
[gate-5] 镜头视频 ← image-to-video
   └─ 产物:镜头视频/*.mp4 + .json
   └─ ★ 暂停 → 用户看片段,标记要重生的镜号,跑 --retry
        |
        v
[gate-6] 交付包
   └─ 产物:第N集/README.md(后期手册 + 镜号清单 + 字幕台词单)
```

### 6.1 状态持久化

每集根目录写 `.pipeline.state.json`:

```json
{
  "episode": 1,
  "current_gate": "gate-4",
  "gates": {
    "gate-1": {"status": "approved", "approved_at": "2026-05-20T10:00:00", "artifacts": ["拍摄本.md"]},
    "gate-2": {"status": "approved", "approved_at": "2026-05-20T10:30:00", "artifacts": ["镜头表.md", "镜头表.json"]},
    "gate-3": {"status": "approved", "approved_at": "2026-05-20T11:00:00", "artifacts": ["角色卡/沈栀.png"]},
    "gate-4": {"status": "waiting_approval", "shots_total": 42, "shots_done": 40, "shots_failed": 2}
  },
  "config": {
    "img_backend": "mj",
    "video_backend": "kling",
    "aspect": "9:16"
  }
}
```

闸门状态枚举:`pending / running / waiting_approval / approved / stale`。

### 6.2 续跑与回退

- `/story-pipeline` 启动时 → 读 state.json → 从 `current_gate` 续跑
- `/story-pipeline --redo gate-2` → 回退到 gate-2,后续闸门重置为 pending(产物保留但标记 stale)
- `/story-pipeline --skip gate-5` → 用户手动指定某闸门通过(比如视频后端没接,跳过到 gate-6)

### 6.3 单 skill 独立使用与编排的关系

- 5 个子 skill 完全可以脱开编排单独跑
- 单独跑时不写 state.json,只产文件
- 编排 skill 调子 skill 时,通过环境变量 `STORY_PIPELINE_EPISODE=1`、`STORY_PIPELINE_GATE=gate-2` 让子 skill 知道自己在编排里跑,产物落到对应路径并更新 state.json

---

## 7. 与现有 story 生态的集成

### 7.1 `/story` 路由表更新

`skills/story/SKILL.md` 已有"扫榜→拆文→写作→去AI"四步流水线。新增"影视化"流水线:

```
| 流水线 | skill | 触发场景 |
|---|---|---|
| 长篇.写作 | story-long-write | ... |
| ... | ... | ... |
| 影视化.剧本 | story-to-script | "转剧本"/"改编" |
| 影视化.分镜 | script-to-shot | "分镜"/"画分镜" |
| 影视化.出图 | shot-to-image | "生镜头图" |
| 影视化.生视频 | image-to-video | "图生视频" |
| 影视化.全流程 | story-pipeline | "拍短剧"/"开拍" |
```

`/story` 接到"拍短剧"/"开拍" → 直接 dispatch 到 `story-pipeline`。
接到中间步骤的关键词 → dispatch 到对应单 skill,并提示"你也可以跑 `/story-pipeline` 走完整流程"。

### 7.2 跟 long-write 的衔接

`story-long-write` 的 Phase 5(质量检查)末尾加一条:
> 「检查通过后,如果想把这章拍成短剧,跑 `/story-pipeline` 或 `/story-to-script`。」

### 7.3 跟 story-cover 的复用

`story-cover` 已经做了 GPT-Image-2 的 curl 调用、b64 解码、保存。`shot-to-image/scripts/adapters/gpt_image.sh` 直接抽 story-cover 那段封装,不重复写。

### 7.4 与 setup 的关系

`story-setup` 部署 hooks/rules/agents。本流水线不需要新 hook(每集自己有 state.json 兜底),也不需要新 agent(默认主线程跑),所以 setup 暂不改。如果以后跑量大想 agent 化,再加 `shot-image-worker` 子 agent。

---

## 8. 非目标(YAGNI)

明确不做的事情,免得后续被推着加:

- **不做视频拼接合成**:不调 ffmpeg 拼镜头、不渲染最终视频。交剪映/Pr/DaVinci。
- **不做 BGM**:不集成音乐库、不做配乐选型。
- **不做 TTS 配音**:留给剪映/海螺 AI/eleven labs。
- **不做字幕烧录**:输出台词单 .txt,剪映自己加字幕轨。
- **不做演员实拍替换**:本流水线纯 AI 路线,不混实拍。
- **不做发布平台对接**:不自动传抖音/视频号。
- **不做版权检测**:不扫 BGM/画面是否侵权,用户自己把握。

---

## 9. 开放问题(留给实施阶段决定)

- **MJ 第三方代理 API 的具体 schema**:不同代理服务商接口不一,implementation 时按用户实际用的服务商微调 `mj.sh`。skill 文档里列 2-3 个主流代理,并约定 `MJ_BASE_URL` 可覆盖。
- **可灵 / 即梦 / Sora 的 API 接入方式**:这些后端的 API 在 2026 年的开放度需要 implementation 阶段验证。占位 `sora.sh` / `veo.sh` 默认 `exit 1` 报"暂未实现",等用户配齐 key 再补 schema。
- **角色卡一致性自检的实现**:Phase 4 的"用 LLM 多模态对比"具体怎么调,需要 implementation 阶段决定走哪个 vision API。advanced 的 face embedding 路线作为可选优化。
- **state.json 的并发安全**:如果用户同时跑两个 episode,要不要文件锁?目前假定单进程,implementation 阶段决定。

---

## 10. 实施顺序建议

按依赖顺序逐 skill 落地,每个 skill 自带 prompt-only adapter 兜底,这样即使没接 API key 也能 end-to-end 跑通(到提示词导出为止):

1. `story-to-script` — 纯 LLM,不调 API,先跑通格式
2. `script-to-shot` — 纯 LLM,加 .json 校验
3. `shot-to-image` 的 `prompt-only` adapter + `gpt-image` adapter(复用 story-cover)
4. `image-to-video` 的 `prompt-only` adapter + 1 个真后端(优先 `kling` 或 `jimeng`,看用户偏好)
5. `story-pipeline` 编排 + state.json
6. 其余 adapter(`mj` / `replicate` / `fal` / `comfy` / `runway` / `sora` / `veo`)按用户实际使用频次补
