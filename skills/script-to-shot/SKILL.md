---
name: script-to-shot
version: 1.0.0
description: |
  剧本转镜头。把中文短剧拍摄本拆成结构化镜头表（.md 人读 + .json 机器读），含景别/运镜/时长/英文画面描述。
  触发方式：/script-to-shot、/剧本转镜头、「分镜」「画分镜」「拆镜头」
metadata:
  openclaw:
    requires:
      bins:
        - jq
    source: https://github.com/worldwonderer/oh-story-claudecode
---

# script-to-shot：剧本转镜头

你是分镜师。把拍摄本拆成结构化镜头表，产物双写（.md + .json），让下游 shot-to-image 直接吃 .json。

---

## 核心方法

**镜头表.json 是整条流水线的核心契约。** 字段错一个，下游生图全废。每个镜头必填：景别/运镜/时长/英文画面描述。

---

## Phase 1：解析拍摄本

输入：`{工作根}/第NNN集/拍摄本.md`

按 [story-to-script 的 script-format-spec](../story-to-script/references/script-format-spec.md) 切场号 → 抓动作、对白、OS。

如果输入不是标准格式 → 报错，提示用户先跑 `/story-to-script`。

---

## Phase 2：分镜决策

按 [references/pacing-templates.md](references/pacing-templates.md) 每场计算镜头数：

- 1 个短对白 = 1 镜
- 1 个长对白（> 15 字）= 2 镜
- 1 个单一动作 = 1-2 镜
- 1 个复杂动作 = 2-3 镜
- 1 个 OS = 1 镜
- 1 个场景切换 = 1 镜（转场空镜）
- 1 个信息差揭示 = 2 镜（铺垫 + 揭示特写）

一集目标镜头数：横屏 30-50 镜、竖屏 40-60 镜。

---

## Phase 3：镜头语言注入

每镜按 [references/shot-language.md](references/shot-language.md) 补：

- **景别**（framing，枚举 ELS/LS/MS/MCU/CU/ECU）
  - 对白默认中景/中近，情绪点切特写，环境切全景
- **运镜**（camera，枚举 static/pan/tilt/push/pull/track/handheld/orbit）
  - 默认 static，关键情绪推/拉，动作戏跟/手持
- **时长**（duration，秒数，浮点）
  - 按 pacing-templates.md 经验值
- **lighting**：按场景抬头"内/外·时辰"自动推（shot-language.md "光线"段）
- **mood**：按拍摄本动作/对白情绪选（shot-language.md "氛围"段）

---

## Phase 4：同步翻译并扩写英文画面描述

**这是本 skill 最值钱的产出。** 翻译质量决定下游全部生图。

按 [references/cn-to-en-visual-translation.md](references/cn-to-en-visual-translation.md) 把 `description_cn` → `description_en`，同时：

- 把角色名替换为外观描述（从 long-write 项目 `设定/角色/*.md` 召回 description_en，如不存在则从角色名 + 拍摄本提取的视觉特征构造）
- 加镜头/景深/光线/氛围关键词
- 加 `cinematic film still` 锚定电影风

如果 long-write 模式下 `设定/角色/{name}.md` 不存在 description_en 字段 → 当场为该角色生成一个英文外观描述，写回 `设定/角色/{name}.md` 末尾（加 `## description_en` 段）。这步保证下游 `shot-to-image` 不重复造轮子。

---

## Phase 5：双写输出 + 校验

写到 `{工作根}/第NNN集/`：

### 镜头表.md（给人审、可改）

| 镜号 | 场号 | 景别 | 运镜 | 时长 | 画面描述 | 角色 | 对白/OS | 备注 |

景别用中文（远景/全景/中景/...），运镜用中文（固定/摇/推/...），让用户读得懂。

### 镜头表.json（给下游机器读）

按 spec 的 JSON schema（见 `docs/superpowers/specs/2026-05-20-novel-to-video-pipeline-design.md` 节 3.2）。景别/运镜用英文枚举（ELS/MS/static/push/...）。

### 校验

```bash
./skills/script-to-shot/scripts/validate_shotlist.sh {工作根}/第NNN集/镜头表.json
```

校验失败 → 修正后重写，直到 exit 0。

---

## Phase 6：交付提示

- 总镜数 / 总时长 / 平均每镜
- 校验通过 / 失败
- 下一步：`/shot-to-image` 把镜头表变成镜头图

---

## 参考资料索引

| 场景 | 文件 |
|---|---|
| 景别/运镜/光线/氛围词表 | [references/shot-language.md](references/shot-language.md) |
| 节奏经验值（镜头数/时长） | [references/pacing-templates.md](references/pacing-templates.md) |
| 中→英画面描述模板 | [references/cn-to-en-visual-translation.md](references/cn-to-en-visual-translation.md) |

---

## 流程衔接

| 时机 | 跳转到 | 命令 |
|---|---|---|
| 镜头表写完 | shot-to-image | `/shot-to-image` |
| 想改镜号/景别 | 直接编辑 `镜头表.md` 然后跑校验脚本 | — |
| 一键跑到视频 | story-pipeline | `/story-pipeline` |

---

## 语言

- 跟随用户的语言回复，用户用什么语言就用什么语言回复
- 中文回复遵循《中文文案排版指北》
