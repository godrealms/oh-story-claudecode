# 小说转视频流水线 Plan 1:基础设施 + story-to-script + script-to-shot

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地影视化流水线的前两个 LLM-only skill(story-to-script、script-to-shot),完成 marketplace 注册,跑通"小说 → 拍摄本 → 镜头表(.md + .json 双写)"链路。

**Architecture:** 两个纯 LLM skill,各自 SKILL.md 主体 + references/ 拆领域知识。本 plan 不调任何外部 API,产物全是 .md/.json 文件。`/story` 路由表的增量更新留给 Plan 4(因为 `story-pipeline` 才是最终路由整合点)。

**Tech Stack:** Markdown SKILL.md / bash + jq(JSON schema 校验)

---

## File Structure

**新建**:
- `skills/story-to-script/SKILL.md`
- `skills/story-to-script/references/adaptation-principles.md`
- `skills/story-to-script/references/script-format-spec.md`
- `skills/story-to-script/references/dialogue-compression.md`
- `skills/story-to-script/references/os-monologue-tricks.md`
- `skills/script-to-shot/SKILL.md`
- `skills/script-to-shot/references/shot-language.md`
- `skills/script-to-shot/references/pacing-templates.md`
- `skills/script-to-shot/references/cn-to-en-visual-translation.md`
- `skills/script-to-shot/scripts/validate_shotlist.sh`
- `tests/fixtures/novel-sample-chapter.md`
- `tests/fixtures/expected-script.md`
- `tests/fixtures/expected-shotlist.json`

**修改**:
- `.claude-plugin/marketplace.json`(注册 `story-to-script` + `script-to-shot` 两个新 plugin)

---

## Phase 0:基础设施

### Task 0.1:创建 skill 目录骨架

**Files:**
- Create: `skills/story-to-script/.gitkeep`
- Create: `skills/story-to-script/references/.gitkeep`
- Create: `skills/script-to-shot/.gitkeep`
- Create: `skills/script-to-shot/references/.gitkeep`
- Create: `skills/script-to-shot/scripts/.gitkeep`

- [ ] **Step 1: 创建目录与占位文件**

```bash
mkdir -p skills/story-to-script/references
mkdir -p skills/script-to-shot/references
mkdir -p skills/script-to-shot/scripts
touch skills/story-to-script/.gitkeep
touch skills/story-to-script/references/.gitkeep
touch skills/script-to-shot/.gitkeep
touch skills/script-to-shot/references/.gitkeep
touch skills/script-to-shot/scripts/.gitkeep
```

- [ ] **Step 2: 验证目录创建成功**

Run: `ls -la skills/story-to-script skills/script-to-shot`
Expected: 两个目录都存在,各自含 references/ 子目录(后者还含 scripts/)

- [ ] **Step 3: Commit**

```bash
git add skills/story-to-script skills/script-to-shot
git commit -m "chore: scaffold story-to-script and script-to-shot skill dirs"
```

---

### Task 0.2:在 marketplace.json 注册两个新 skill

**Files:**
- Modify: `.claude-plugin/marketplace.json`(在 `"plugins"` 数组末尾追加两个条目,紧跟现有 `story-cover` 条目之后)

- [ ] **Step 1: 在 plugins 数组末尾插入两个新条目**

打开 `.claude-plugin/marketplace.json`,定位到 `story-cover` 条目末尾的 `}`,在其后(`]` 之前)追加:

```json
    {
      "name": "story-to-script",
      "description": "小说转剧本。把网文(单章/范围/独立文本)转成中文短剧拍摄本,可选额外产出分镜本。",
      "source": "./",
      "strict": false,
      "version": "1.0.0",
      "category": "novel-video",
      "keywords": ["script", "adaptation", "shooting-script", "短剧", "拍摄本", "改编", "chinese"],
      "skills": ["./skills/story-to-script"]
    },
    {
      "name": "script-to-shot",
      "description": "剧本转镜头。把中文短剧拍摄本拆成结构化镜头表(.md 人读 + .json 机器读),含景别/运镜/时长/英文画面描述。",
      "source": "./",
      "strict": false,
      "version": "1.0.0",
      "category": "novel-video",
      "keywords": ["shot-list", "storyboard", "分镜", "镜头表", "shooting-list", "chinese"],
      "skills": ["./skills/script-to-shot"]
    }
```

注意是追加,前一个条目末尾要加逗号。

- [ ] **Step 2: 用 jq 校验 JSON 语法**

Run: `jq '.plugins | length' .claude-plugin/marketplace.json`
Expected: 数字增加 2(原有 plugin 数 + 2)

Run: `jq '.plugins[] | select(.name == "story-to-script" or .name == "script-to-shot") | .name' .claude-plugin/marketplace.json`
Expected: 两行输出 `"story-to-script"` 和 `"script-to-shot"`

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/marketplace.json
git commit -m "chore: register story-to-script and script-to-shot in marketplace"
```

---

## Phase 1:story-to-script

### Task 1.1:写 references/script-format-spec.md(剧本格式规范)

**Files:**
- Create: `skills/story-to-script/references/script-format-spec.md`

- [ ] **Step 1: 写完整文件**

```markdown
# 剧本格式规范

本 skill 产出两种剧本:**拍摄本**(默认)和 **分镜本**(可选)。下游 `script-to-shot` 默认吃拍摄本。

---

## 拍摄本格式

### 整体结构

```
# 第 NNN 集:{集名}

## 场 N — 内/外·{地点}·{时辰}

(动作描述,括号包裹)

角色名:对白
角色名:对白
(OS:内心独白或画外音)

## 场 N+1 — ...
```

### 字段约束(硬性)

1. **集名**:第一行 `# 第 001 集:{集名}`,集号三位数,补零
2. **场号自增**:从 1 开始连续递增,不跳号
3. **场景抬头**:`## 场 N — 内/外·{地点}·{时辰}`,三段式必填
   - 内/外:`内` 或 `外`,二选一
   - 地点:5-15 字短语
   - 时辰:`晨`/`上午`/`午`/`下午`/`黄昏`/`夜`/`深夜`,七选一
4. **动作描述**:括号包裹,可跨段
5. **对白**:`角色名:对白`,角色名后中文冒号,无空格
6. **OS/画外音**:`(OS:...)`,OS 前缀大写,中文冒号

### 完整示例

```
# 第 001 集:雨夜归来

## 场 1 — 内·巫术司大厅·夜

(沈栀推门而入,雨水顺着发梢滴落。烛火在她脸上摇晃。)

司长:你来晚了。
沈栀:我母亲死了。
(OS:三年前她也说过同样的话。)

## 场 2 — 内·档案室·夜

(档案柜被一格一格打开,沈栀的手指在卷宗上停下。)

沈栀:就是这卷。
```

---

## 分镜本格式(可选)

在拍摄本基础上,每段动作/对白前加镜号、景别、运镜列。结构:

```
## 场 1 — 内·巫术司大厅·夜

| 镜 | 景别 | 运镜 | 内容 |
|---|---|---|---|
| S001 | 中景 | 固定 | (沈栀推门而入,雨水顺着发梢滴落) |
| S002 | 特写 | 推 | 司长:你来晚了。 |
| S003 | 特写 | 固定 | 沈栀:我母亲死了。 |
| S004 | 特写 | 固定 | (OS:三年前她也说过同样的话。) |
```

景别枚举(中文表 → 英文缩写):`远景=ELS / 全景=LS / 中景=MS / 中近景=MCU / 近景=CU / 特写=ECU`
运镜枚举:`固定/摇/推/拉/跟/手持/环绕`

---

## 反例(必避免)

- ❌ 场号跳号:`场 1` → `场 3`
- ❌ 场景抬头缺时辰:`内·档案室`
- ❌ 对白用英文冒号:`沈栀: 我母亲死了`
- ❌ OS 不用括号:`沈栀: (OS) 三年前...`
- ❌ 多角色合并对白:`沈栀&司长:你们都听好...`(必须分两行)
```

- [ ] **Step 2: Commit**

```bash
git add skills/story-to-script/references/script-format-spec.md
git commit -m "docs(story-to-script): add script format spec"
```

---

### Task 1.2:写 references/adaptation-principles.md(改编三档)

**Files:**
- Create: `skills/story-to-script/references/adaptation-principles.md`

- [ ] **Step 1: 写完整文件**

```markdown
# 改编原则

短剧不是逐字还原小说。要做三件事:**删**(砍冗余)、**合**(并场景)、**加**(补外部锚点)。三档改编强度供用户选:

---

## 档 1:忠于原著(改编度 30%)

**适用**:文笔型小说、原文已经有强戏剧性、用户怕"魔改"

**操作**:
- 心理描写 → 大部分保留为 OS,少数关键的外化为动作
- 多线叙事 → 保留,但每场只走一线
- 长对话 → 保留 70% 关键句,砍寒暄/重复
- 没有动作的章节 → 一字不加

**风险**:节奏拖、戏剧密度低、AI 短剧不耐看

---

## 档 2:节奏优先(改编度 50%) — 默认

**适用**:大部分网文,尤其是爽文、悬疑、霸总

**操作**:
- 心理描写 → 80% 外化为台词/动作/物件/OS
- 多线叙事 → 收敛到主角视角,副线压缩为转场或一句 OS
- 长对话 → 砍到 3 句以内,留最爆点的那一句
- 没有动作的章节 → 加 1-2 个外部事件锚定(物件出现、电话响、外人推门)
- 章节里的过场叙述(如"接下来三天")→ 改为快剪 + 时间字幕

**风险**:可能丢失原文细腻处,但短剧节奏对

---

## 档 3:大刀阔斧(改编度 70%+)

**适用**:原文是日常流水账、要做大幅戏剧化

**操作**:
- 心理描写 → 几乎全部外化
- 多线叙事 → 砍掉 80%
- 长对话 → 重写,只保留"信息差揭示"和"冲突爆点"
- 没有动作的章节 → 跳过或合入相邻集
- 章节顺序可重排,把强戏剧片段前置

**风险**:改编后跟原文出入大,用户(原作者)可能不满意——必须事先确认

---

## 改编决策表(每场一次)

每场写之前问自己:

| 问题 | 处理 |
|---|---|
| 这场交付什么情绪? | 不能交付情绪 → 砍 |
| 主角在做什么"可拍的事"? | 没有 → 加外部事件 |
| 对白是否推进剧情? | 不推进 → 砍或改 OS |
| 有没有信息差揭示? | 有 → 给特写镜的位置 |
| 时辰/地点切换是否合理? | 不合理 → 调整场号 |

---

## 通用删除清单(任档都砍)

- 风景描写(短剧靠画面交代,文字描写没用)
- 重复信息(原文为了强调说三次的,留一次)
- 旁支角色的独立场景(收敛到主角视角)
- "突然想起"型回忆(改成实拍闪回,只用一镜)
```

- [ ] **Step 2: Commit**

```bash
git add skills/story-to-script/references/adaptation-principles.md
git commit -m "docs(story-to-script): add adaptation principles"
```

---

### Task 1.3:写 references/dialogue-compression.md

**Files:**
- Create: `skills/story-to-script/references/dialogue-compression.md`

- [ ] **Step 1: 写完整文件**

```markdown
# 对白压缩

短剧每秒钟都很贵,对白不能水。

---

## 压缩三原则

1. **一句话一个信息**:多个信息分多句,但每句必须独立有信息密度
2. **不说大家都知道的事**:寒暄、自我介绍、重复对方刚说的话 — 砍
3. **优先冲突,不优先解释**:"为什么这样"由后面剧情交代,当下让冲突先发生

---

## 压缩范式

### 范式 1:寒暄删除

原文:
> "好久不见啊司长,最近身体怎么样?"
> "托福托福,你呢?在大理寺还顺利吗?"
> "凑合。我今天来是想问一件事..."

压缩:
> 沈栀:司长,我要查一份卷宗。

省 3 句,直奔核心。

### 范式 2:解释合并到行动

原文:
> 司长:你知道吗,这份卷宗已经封存十年了。当年是你母亲亲手封的。
> 沈栀:我知道,所以才要查。

压缩:
> (司长抽出卷宗,封条上是沈栀母亲的字迹。)
> 沈栀:我知道是她封的。所以才要查。

把"卷宗封存"信息塞进画面,对白只留态度。

### 范式 3:三句砍一句

原文:
> "不可能!这绝对不可能!你一定是搞错了!"

压缩:
> "不可能。"

(留态度,砍重复。)

---

## 不能压的对白

以下对白即使啰嗦也要留:

- **关键信息差揭示**(比如"她不是你母亲")
- **角色弧光转折**(比如主角第一次说"我错了")
- **梗/金句**(可能成截屏传播)
- **悬念抛出**("如果你打开那道门,就不能回头了")

---

## 检查清单

写完每场后过一遍:
- [ ] 总对白行数 ≤ 5 行(对峙场可放宽到 8 行)
- [ ] 最长单行对白 ≤ 25 字
- [ ] 没有连续 3 行都是同一角色发言
- [ ] 没有寒暄/自我介绍
- [ ] 至少一句是"金句候选"(用户能截图传播的那种)
```

- [ ] **Step 2: Commit**

```bash
git add skills/story-to-script/references/dialogue-compression.md
git commit -m "docs(story-to-script): add dialogue compression rules"
```

---

### Task 1.4:写 references/os-monologue-tricks.md(内心戏外化)

**Files:**
- Create: `skills/story-to-script/references/os-monologue-tricks.md`

- [ ] **Step 1: 写完整文件**

```markdown
# 内心戏外化技法

网文心理描写多,短剧没法直接拍。四种处理方法:

---

## 方法 1:转 OS(画外音)

最简单,但**用多就 low**。一集 OS 不超过 5 处,且每处不超过 15 字。

原文:
> 沈栀心里一沉。十年前那个夜晚,雨也是这样下着...

转 OS:
> (OS:十年了,雨还是这样下。)

**适合**:点睛式的心理转折,或者人物已经无法说话(独处、压抑环境)。

---

## 方法 2:外化为动作/微表情

最高级,但最难。需要找一个可拍的"等价动作"。

原文:
> 沈栀知道司长在撒谎,但她不打算戳破。

外化:
> (沈栀的手指在桌沿停了一下。她笑了笑,什么也没说。)

动作 + 表情 + 沉默 = 心理。

---

## 方法 3:外化为物件

让一个物件承担心理。这是电影常用手法。

原文:
> 母亲的死成了沈栀心里过不去的坎。

外化:
> (沈栀的抽屉里,放着母亲的发簪。她从不戴,也不送人。)

物件 = 一个可拍的、可重复出现的、有重量的符号。

---

## 方法 4:外化为配角嘴里说出来

让另一个角色把心理"指出来"。

原文:
> 沈栀其实很怕,但她不肯承认。

外化:
> 司长:你怕什么?
> 沈栀:我没怕。
> 司长:你手在抖。

(配角的观察 + 主角的否认 + 物理证据 = 心理。)

---

## 决策树

```
有心理描写要处理?
├─ 是关键的情绪转折点? → 方法 1(OS,精炼到 15 字内)
├─ 有可拍的等价动作/微表情? → 方法 2(优先)
├─ 是反复出现的心结? → 方法 3(物件,贯穿全集)
└─ 在对话场景里? → 方法 4(配角指出)
```

---

## 反例(必避免)

- ❌ 大段连续 OS(超过 3 句):像 PPT 讲解
- ❌ OS 把动作要表达的东西重复说一遍:"她笑了。(OS:她其实在装。)" — 砍 OS
- ❌ OS 内容跟画面无关:观众不知道在配哪一镜
- ❌ 用 OS 解释"她为什么这样做":让观众猜,猜不到就让后面剧情揭示
```

- [ ] **Step 2: Commit**

```bash
git add skills/story-to-script/references/os-monologue-tricks.md
git commit -m "docs(story-to-script): add inner monologue externalization tricks"
```

---

### Task 1.5:写 story-to-script 的 SKILL.md(主体)

**Files:**
- Create: `skills/story-to-script/SKILL.md`

- [ ] **Step 1: 写完整文件**

````markdown
---
name: story-to-script
version: 1.0.0
description: |
  小说转剧本。把网文(单章/范围/独立文本)转成中文短剧拍摄本,可选额外产出分镜本。
  触发方式:/story-to-script、/小说转剧本、「转剧本」「改编」「改成短剧」
metadata:
  openclaw:
    source: https://github.com/worldwonderer/oh-story-claudecode
---

# story-to-script:小说转剧本

你是网文改编编剧。把小说转成中文短剧拍摄本,产物落到文件系统不堆在对话里。

---

## 核心方法

短剧不是逐字还原小说。三件事:**删**(砍冗余)、**合**(并场景)、**加**(补外部锚点)。详见 [references/adaptation-principles.md](references/adaptation-principles.md)。

---

## Phase 1:智能识别 + 集划分

### 输入源识别

按顺序检测当前目录:
1. 同时存在 `设定/` + `大纲/` + `正文/` 子目录 → 判定 **long-write 项目模式**
2. 否则 → **独立模式**,询问用户给一段文本或 md 文件路径

### long-write 模式

询问用户:
- 转哪几章?(默认问"第几章到第几章")
- 几章成一集?(默认 1 章 = 1 集)
- 横屏 / 竖屏?(影响后续 image-to-video 的宽高比;默认问)
- 改编强度?(忠于原著 / 节奏优先 / 大刀阔斧;默认"节奏优先",参考 [references/adaptation-principles.md](references/adaptation-principles.md))

工作目录:`{当前目录}/短剧/`,每集独立子目录 `第NNN集/`。

### 独立模式

用户给的文本落到临时根:`./短剧产物/{YYYYMMDD-HHMMSS}-{标题}/`,内部结构同 long-write 模式。
要求用户给个"标题",作为目录名一部分;若用户没给,用前 10 个字 + 时间戳。

---

## Phase 2:上下文召回(long-write 模式)

按需读取,缺失则跳过:

| 文件 | 用途 |
|---|---|
| `设定/角色/*.md`(本章涉及角色) | 提取外貌、性格、口头禅 |
| `追踪/角色状态.md` | 当前状态、关系 |
| `大纲/细纲_第N章.md` | 章节情绪目标、爽点、钩子 |
| `正文/第N章_*.md` | 原文 |

独立模式只读用户给的那段文本,无召回。

---

## Phase 3:改编决策

按用户选的强度(参考 [references/adaptation-principles.md](references/adaptation-principles.md))做:
- 心理描写外化(参考 [references/os-monologue-tricks.md](references/os-monologue-tricks.md))
- 对白压缩(参考 [references/dialogue-compression.md](references/dialogue-compression.md))
- 场景合并/拆分
- 外部锚点补充

每场写之前用决策表过一遍(决策表见 adaptation-principles.md)。

---

## Phase 4:输出

### 必输出:拍摄本.md

按 [references/script-format-spec.md](references/script-format-spec.md) 严格格式,落到 `{工作根}/第NNN集/拍摄本.md`。

字段硬性约束:
- 集号三位补零
- 场号自增不跳号
- 场景抬头三段式(内外·地点·时辰)
- OS 用括号包裹
- 角色名后中文冒号

### 可选输出:分镜本.md

用户额外要求分镜本时,在拍摄本基础上加镜号/景别/运镜列,落到 `{工作根}/第NNN集/分镜本.md`。

注意:分镜本不是 `script-to-shot` 的产物。`script-to-shot` 吃拍摄本输出结构化镜头表(.md + .json)。分镜本只是给用户"自己读"的中间档,默认不出。

---

## Phase 5:交付提示

写完后告知用户:
- 产物路径
- 总集数 / 总字数 / 估算时长(每集字数 × 0.4s/字)
- 下一步:`/script-to-shot` 把拍摄本变成结构化镜头表

---

## 参考资料索引

| 场景 | 文件 |
|---|---|
| 改编强度决策 | [references/adaptation-principles.md](references/adaptation-principles.md) |
| 拍摄本/分镜本格式 | [references/script-format-spec.md](references/script-format-spec.md) |
| 对白压缩范式 | [references/dialogue-compression.md](references/dialogue-compression.md) |
| 内心戏外化技法 | [references/os-monologue-tricks.md](references/os-monologue-tricks.md) |

---

## 流程衔接

| 时机 | 跳转到 | 命令 |
|---|---|---|
| 拍摄本写完 | script-to-shot | `/script-to-shot` |
| 一键跑到视频 | story-pipeline | `/story-pipeline` |
| 想改剧本 | 直接编辑 `拍摄本.md` 文件 | — |

---

## 语言

- 跟随用户的语言回复,中文回复遵循《中文文案排版指北》
````

- [ ] **Step 2: Commit**

```bash
git add skills/story-to-script/SKILL.md
git commit -m "feat(story-to-script): add main SKILL.md"
```

---

### Task 1.6:创建测试 fixture(小说样本 + 期望剧本)

**Files:**
- Create: `tests/fixtures/novel-sample-chapter.md`
- Create: `tests/fixtures/expected-script.md`

- [ ] **Step 1: 创建 tests/fixtures/ 目录并写小说样本**

```bash
mkdir -p tests/fixtures
```

写 `tests/fixtures/novel-sample-chapter.md`:

```markdown
# 第 1 章:雨夜

沈栀推开巫术司的大门,雨水顺着她的发梢滴落在青砖地上。烛火在她脸上摇晃,把她的影子拉得很长。

司长正坐在案前看卷宗,听见动静抬起头。他看见沈栀的样子,愣了一下,然后开口:"你来晚了。"

沈栀没有回话,把湿漉漉的斗篷脱下挂在门边的木架上。她走到司长对面坐下,平静地说:"我母亲死了。"

司长手里的笔停了一下。他记得三年前,沈栀也是这样推门进来,说过一模一样的话。那次是她父亲。

"什么时候?"司长问。
"三天前。我刚回来。"
"葬礼办了?"
"办了。"

沈栀的声音平静得像在说别人的事。司长看着她,看见她左眉上那道旧疤,在烛火下若隐若现。十年前的疤,她从来不肯说怎么来的。

"我需要查一份卷宗。"沈栀说。
"什么卷宗?"
"我母亲十年前封存的那一份。"

司长沉默了。那份卷宗,他知道。整个巫术司都知道,但没人敢碰。

"沈栀。"他放下笔,"那份卷宗一旦打开,就不能再封回去了。"
"我知道。"
"你确定?"
"我确定。"

司长站起来,走到墙边的密格,从最深处抽出一卷牛皮纸卷宗。封条上是沈栀母亲的字迹,墨色已经发黑。他把卷宗放在沈栀面前。

"那就开始吧。"他说。
```

- [ ] **Step 2: 写期望剧本(按 script-format-spec.md 标准)**

写 `tests/fixtures/expected-script.md`:

```markdown
# 第 001 集:雨夜归来

## 场 1 — 内·巫术司大厅·夜

(沈栀推门而入,雨水顺着发梢滴落在青砖上。烛火在她脸上摇晃。)

(司长抬头,看见她的样子愣了一下。)

司长:你来晚了。
沈栀:我母亲死了。

(司长手里的笔停了一下。)

司长:什么时候?
沈栀:三天前。
司长:葬礼办了?
沈栀:办了。

(沈栀左眉上一道旧疤,在烛火下若隐若现。)

沈栀:我需要查一份卷宗。我母亲十年前封存的那一份。

(司长沉默,然后放下笔。)

司长:那份卷宗一旦打开,就不能再封回去了。
沈栀:我知道。

## 场 2 — 内·密格·夜

(司长走到墙边密格,从最深处抽出一卷牛皮纸卷宗。封条上的字迹墨色发黑。)

(他把卷宗放在沈栀面前。)

司长:那就开始吧。
```

- [ ] **Step 3: Commit**

```bash
git add tests/fixtures/novel-sample-chapter.md tests/fixtures/expected-script.md
git commit -m "test: add story-to-script fixture (novel sample + expected script)"
```

---

### Task 1.7:手动端到端测试 story-to-script(独立模式)

**Files:**
- 无新建,只跑测试

- [ ] **Step 1: 用 fixture 跑一遍 skill**

在 Claude Code 里(或人工模拟):
```
/story-to-script tests/fixtures/novel-sample-chapter.md
```

期望 skill 完成以下:
1. 识别为独立模式(因为 tests/fixtures/ 不含 设定/大纲/正文/ 三个目录)
2. 询问"集划分(默认 1 章 = 1 集)"/"横竖屏"/"改编强度"
3. 用户全部用默认应答
4. 输出到 `./短剧产物/{时间戳}-{标题}/第001集/拍摄本.md`

- [ ] **Step 2: 对比产物与 expected-script.md**

```bash
diff tests/fixtures/expected-script.md ./短剧产物/*/第001集/拍摄本.md
```

允许差异:
- 场景拆分粒度可能不一样(可能是 1 场 vs 2 场)
- 对白用词可能略微不同(只要语义对)

不允许差异:
- 场号跳号 / 缺少时辰 / OS 没用括号 / 角色名后用英文冒号

如有不允许差异 → 回去改 SKILL.md 或 script-format-spec.md。

- [ ] **Step 3: 清理测试产物**

```bash
rm -rf ./短剧产物
```

- [ ] **Step 4: Commit(只 commit 改动,无新文件)**

如 SKILL.md 或 reference 有改动:
```bash
git add skills/story-to-script
git commit -m "fix(story-to-script): refine based on fixture test"
```

如无改动跳过。

---

### Task 1.8:手动端到端测试 story-to-script(long-write 模式)

**Files:**
- 无新建,只跑测试

- [ ] **Step 1: 准备一个 mock long-write 项目目录**

```bash
mkdir -p /tmp/mock-novel/{设定/角色,大纲,正文,追踪}
cp tests/fixtures/novel-sample-chapter.md /tmp/mock-novel/正文/第001章_雨夜.md
cat > /tmp/mock-novel/设定/角色/沈栀.md <<'EOF'
# 沈栀

- 年龄:二十出头
- 外貌:长发及腰,左眉一道旧疤
- 性格:平静、隐忍、决绝
- 口头禅:无
EOF
cat > /tmp/mock-novel/设定/角色/司长.md <<'EOF'
# 司长

- 年龄:五十岁
- 性格:谨慎、世故
- 与主角关系:沈栀母亲的旧交
EOF
```

- [ ] **Step 2: cd 到 mock 目录跑 skill**

```bash
cd /tmp/mock-novel
```

模拟:
```
/story-to-script 转第 1 章
```

期望:
1. 识别为 long-write 模式
2. 召回 `设定/角色/沈栀.md` 和 `设定/角色/司长.md`
3. 询问集划分/横竖屏/改编强度(可用默认)
4. 输出到 `/tmp/mock-novel/短剧/第001集/拍摄本.md`

- [ ] **Step 3: 校验输出**

```bash
ls -la /tmp/mock-novel/短剧/第001集/
cat /tmp/mock-novel/短剧/第001集/拍摄本.md
```

Expected:
- 拍摄本.md 存在
- 第一行 `# 第 001 集:{集名}`
- 至少 1 个场景抬头三段式 `## 场 1 — 内·巫术司大厅·夜`
- 至少 1 处 `沈栀:` 对白(中文冒号)

- [ ] **Step 4: 清理**

```bash
cd -
rm -rf /tmp/mock-novel
```

- [ ] **Step 5: Commit(如有改动)**

如 SKILL.md/refs 有改动:
```bash
git add skills/story-to-script
git commit -m "fix(story-to-script): refine long-write mode based on test"
```

---

### Task 1.9:手动测试可选分镜本档

**Files:**
- 无新建

- [ ] **Step 1: 跑 skill 并要分镜本**

```
/story-to-script tests/fixtures/novel-sample-chapter.md
```

中途明确说"也要分镜本"。

- [ ] **Step 2: 校验**

```bash
ls -la ./短剧产物/*/第001集/
```

Expected: 同时有 `拍摄本.md` 和 `分镜本.md`

```bash
cat ./短剧产物/*/第001集/分镜本.md | head -30
```

Expected:
- 包含 `| 镜 | 景别 | 运镜 | 内容 |` 表格头
- 镜号 `S001` 起,三位数补零
- 景别用中文(远景/全景/中景/中近景/近景/特写)
- 运镜用中文(固定/摇/推/拉/跟/手持/环绕)

- [ ] **Step 3: 清理 + commit**

```bash
rm -rf ./短剧产物
```

如 SKILL.md/refs 有改动:
```bash
git add skills/story-to-script
git commit -m "fix(story-to-script): refine optional storyboard output"
```

---

## Phase 2:script-to-shot

### Task 2.1:写 references/shot-language.md(镜头语言词表)

**Files:**
- Create: `skills/script-to-shot/references/shot-language.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 镜头语言词表

下游英文提示词全靠这一份的"中→英"对照。改这里 = 改下游全部生图/生视频效果。

---

## 景别(framing)

| 中文 | 英文缩写 | 英文全称 | 用途 |
|---|---|---|---|
| 远景 | `ELS` | extreme long shot | 环境/史诗感/小人物大场面 |
| 全景 | `LS` | long shot | 全身入镜,展示动作和环境关系 |
| 中景 | `MS` | medium shot | 半身,对白主用 |
| 中近景 | `MCU` | medium close-up | 胸像,情绪 + 对白 |
| 近景 | `CU` | close-up | 脸部,强情绪 |
| 特写 | `ECU` | extreme close-up | 眼/嘴/手/物件,极强情绪或细节 |

---

## 运镜(camera)

| 中文 | 英文 | 提示词模板 | 用途 |
|---|---|---|---|
| 固定 | `static` | `static camera, locked-off shot` | 默认,稳定 |
| 摇 | `pan` | `camera pans {left/right} slowly` | 横向扫场景 |
| 俯仰 | `tilt` | `camera tilts {up/down}` | 纵向揭示(从脚到脸) |
| 推 | `push` / `dolly in` | `camera slowly pushes in toward subject` | 情绪强化 |
| 拉 | `pull` / `dolly out` | `camera slowly pulls out` | 揭示环境/情绪释放 |
| 跟 | `track` / `follow` | `camera tracks behind subject` | 动作戏 |
| 手持 | `handheld` | `handheld shaky cam, documentary feel` | 紧张/真实感 |
| 环绕 | `orbit` | `camera orbits around subject` | 关键瞬间强调 |

---

## 光线(lighting)

按场景抬头的"内/外·时辰"自动推:

| 内/外 | 时辰 | 英文提示词 |
|---|---|---|
| 内 | 晨 | `soft morning light streaming through windows, warm golden hour interior` |
| 内 | 上午/午/下午 | `bright daylight through windows, soft natural interior lighting` |
| 内 | 黄昏 | `warm golden hour interior, long shadows, orange-amber light` |
| 内 | 夜 | `moody candlelight, low-key lighting, warm orange highlights against cool shadows` |
| 内 | 深夜 | `dim oil lamp, single light source, heavy shadows, noir lighting` |
| 外 | 晨 | `soft sunrise light, low golden sun, long shadows, misty atmosphere` |
| 外 | 上午/午/下午 | `bright sunny day, hard sunlight, clear visibility` |
| 外 | 黄昏 | `golden hour, warm sunset light, soft directional rays` |
| 外 | 夜 | `moonlight, cool blue tones, deep shadows, low ambient light` |
| 外 | 深夜 | `near-total darkness, distant lantern or moonlight only, deep noir` |

如场景明确有特殊光源(雨/雪/雷电/烛火/灯笼),叠加:
- `rain backlit by lanterns, dramatic backlight`
- `snow scene, overcast diffuse light`
- `lightning flash silhouette`
- `single candle on table, intimate close lighting`

---

## 氛围(mood)

从拍摄本的动作描述/对白情绪/场景抬头组合判断:

| 氛围词 | 英文提示词 |
|---|---|
| 紧张 | `tense, foreboding atmosphere` |
| 压抑 | `oppressive, claustrophobic mood` |
| 悲伤 | `melancholy, somber mood` |
| 浪漫 | `romantic, intimate atmosphere` |
| 激烈 | `intense, high-stakes` |
| 神秘 | `mysterious, enigmatic atmosphere` |
| 宁静 | `serene, calm` |
| 诡异 | `eerie, unsettling` |

---

## 构图(composition,可选,加分项)

提示词模板:
- `centered composition` — 中心构图,正式/对峙
- `rule of thirds` — 三分构图,自然
- `low angle` — 低角度,显威严
- `high angle` — 俯拍,显渺小
- `Dutch angle` — 倾斜,失衡感
- `over the shoulder` — 越肩,对话场用
- `wide shot with deep focus` — 大景深,展示空间纵深
- `shallow depth of field, bokeh background` — 浅景深,主体突出
````

- [ ] **Step 2: Commit**

```bash
git add skills/script-to-shot/references/shot-language.md
git commit -m "docs(script-to-shot): add shot language vocabulary"
```

---

### Task 2.2:写 references/pacing-templates.md(节奏经验值)

**Files:**
- Create: `skills/script-to-shot/references/pacing-templates.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 节奏经验值

每场拆多少镜、每镜多长 — 决定一集长不长、观感快不快。

---

## 一集目标镜头数

| 屏向 | 一集时长目标 | 镜头数 | 平均每镜 |
|---|---|---|---|
| 横屏 | 2-3 分钟 | 30-50 镜 | 3-5s |
| 竖屏 | 1-2 分钟 | 40-60 镜 | 1.5-3s |

竖屏节奏更快——抖音/视频号刷的人停留时间短,镜头要更频繁切换。

---

## 单镜时长经验

| 类型 | 时长 | 备注 |
|---|---|---|
| 对白镜 | 中文 ~3 字/秒,1 句典型 2-4s | 长句拆两镜 |
| 纯画面镜(无对白) | 2-3s | 太长观众走神 |
| 特写情绪镜 | 1-2s | 短促有力 |
| 全景/远景 | 3-5s | 给观众时间消化空间 |
| 转场空镜 | 1-2s | 不带信息只换氛围 |
| 高潮释放镜 | 2-4s | 可以长一点强化 |

---

## 分镜分配经验(每场)

| 场内单元 | 镜头数 |
|---|---|
| 1 个对白(短) | 1 镜 |
| 1 个对白(长,> 15 字) | 2 镜(说话人 + 反应) |
| 1 个动作(单一) | 1-2 镜 |
| 1 个动作(复杂,如开门 + 进屋 + 抬头) | 2-3 镜 |
| 1 个 OS | 1 镜(配特写或环境镜) |
| 1 个场景切换 | 1 镜(转场空镜) |
| 1 个信息差揭示 | 2 镜(铺垫 + 揭示特写) |

---

## 节奏模式速查

### 快节奏(动作戏/打脸/冲突高潮)
- 每镜平均 1.5-2.5s
- 多用特写、近景
- 运镜静态为主,偶尔推/拉强化情绪
- 切换频率高,信息密度高

### 中节奏(对白/日常推进)
- 每镜平均 3-4s
- 中景为主,情绪点切特写
- 运镜可有节制地用推/拉
- 信息密度均衡

### 慢节奏(情绪渲染/留白)
- 每镜平均 4-6s
- 多用全景、特写极端景别
- 运镜可用慢推/慢拉/环绕
- 信息密度低,靠氛围

---

## 校验:总时长 ≈ 集长目标

skill 跑完 Phase 5 双写前,加总每镜 `duration` → 校验 ≈ 集长目标(±20%)。

差太多:
- 镜头数过少 → 重新分镜,把动作拆细
- 单镜过长 → 砍掉冗余镜头或拆短
- 总时长过长 → 提示用户考虑分成两集
````

- [ ] **Step 2: Commit**

```bash
git add skills/script-to-shot/references/pacing-templates.md
git commit -m "docs(script-to-shot): add pacing templates"
```

---

### Task 2.3:写 references/cn-to-en-visual-translation.md(中→英画面描述模板)

**Files:**
- Create: `skills/script-to-shot/references/cn-to-en-visual-translation.md`

- [ ] **Step 1: 写完整文件**

````markdown
# 中文画面描述 → 英文电影感描述

这是本 skill 最值钱的产出。**翻译质量直接决定下游所有生图的下限。**

---

## 翻译原则

1. **不直译**:中文"沈栀推门"不能翻成"Shen Zhi pushes the door"——下游生图模型不知道"Shen Zhi"是谁
2. **替换为视觉描述**:"沈栀" → "young Asian woman, early twenties, long black hair, dark robes"(从角色卡的 description_en 来)
3. **加电影感关键词**:`cinematic film still`、`shot on 35mm`、`shallow depth of field`、`golden hour lighting`
4. **加构图线索**:景别 + 角度 + 焦点
5. **加纵深/光线/色温**:让画面"立体"

---

## 完整翻译范式

### 范式 1:动作镜

原文:
> 沈栀推开巫术司的大门,雨水从屋檐滴落。

英文:
> A young Asian woman in dark high-collar robes pushes open heavy wooden doors of an ancient sorcery bureau. Rain drips from the eaves above her, backlit by warm lantern light from inside. Cinematic film still, medium shot, shot on 35mm, shallow depth of field, moody nighttime atmosphere.

注意:
- 角色用外观描述替换姓名
- 加 "ancient sorcery bureau"(具体化场景)
- 加 "backlit by warm lantern light"(光线方向)
- 加 cinematic + 镜头 + 景深 + 氛围

### 范式 2:对白特写镜

原文:
> 沈栀:我母亲死了。

英文(画面描述,不是台词翻译):
> Extreme close-up of a young Asian woman's face. Her eyes are calm but heavy. Candlelight flickers across her left cheek, casting half her face in shadow. A faint old scar above her left eyebrow catches the light. Cinematic film still, shallow depth of field, intimate lighting.

注意:对白不翻译,只翻译"说这句话时的画面"。

### 范式 3:环境镜

原文:
> (档案室,昏暗。)

英文:
> A dimly lit ancient archive room. Tall wooden shelves filled with scroll cases stretch into darkness. A single oil lamp burns on a heavy desk, casting long shadows. Empty composition, no people. Cinematic film still, deep noir lighting, atmospheric.

---

## 角色一致性的关键

每个角色第一次出现时,**必须**用完整的 description_en 替换姓名:

> "Shen Zhi" → "young Asian woman, early twenties, waist-length black hair, dark high-collar robe, faint scar above left eyebrow, pale skin"

后续镜头出现同一角色时,可缩写为:

> "the young woman" / "the woman with the scarred eyebrow" / "the same woman"

但**关键外观特征**(发型、服饰、疤痕)每镜都重复,这是给下游生图模型的"身份锚点"。

---

## 必加关键词清单

每个镜头的英文描述,必加(否则下游生图烂):

- `cinematic film still` — 让模型走电影风,不走插画风
- `{lighting}` — 光线描述,来自 shot-language.md 的"光线"段
- `shallow depth of field` 或 `deep focus` — 景深
- `shot on 35mm` 或 `shot on anamorphic lens` — 镜头(可选,但加了更电影感)
- 景别词:`wide shot` / `medium shot` / `close-up` / `extreme close-up`(对应景别表)

---

## 反例(必避免)

- ❌ 直接翻人名:"Shen Zhi pushes the door" — 模型不知道是谁
- ❌ 缺光线描述:模型自由发挥,通常出"中午阳光直射"的烂图
- ❌ 缺景别词:模型给一个奇怪的角度
- ❌ 中文专有名词照搬:"the Yamen" / "the Tianjiu Pavilion" — 改为通用描述 "ancient government office" / "ornate pavilion"
- ❌ 抽象情绪词单独出现:"sad atmosphere" — 必须配画面 "melancholy lighting, downcast posture, autumn leaves falling"
````

- [ ] **Step 2: Commit**

```bash
git add skills/script-to-shot/references/cn-to-en-visual-translation.md
git commit -m "docs(script-to-shot): add Chinese-to-English visual translation guide"
```

---

### Task 2.4:写 scripts/validate_shotlist.sh(JSON schema 校验)

**Files:**
- Create: `skills/script-to-shot/scripts/validate_shotlist.sh`

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# validate_shotlist.sh — 校验镜头表.json 符合 schema

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <镜头表.json>" >&2
  exit 2
fi

JSON_PATH="$1"

if [[ ! -f "$JSON_PATH" ]]; then
  echo "ERROR: file not found: $JSON_PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required (install: brew install jq)" >&2
  exit 1
fi

# 必填顶层字段
EPISODE=$(jq -r '.episode // empty' "$JSON_PATH")
[[ -z "$EPISODE" ]] && { echo "ERROR: missing .episode" >&2; exit 1; }

SHOTS_LEN=$(jq -r '.shots | length' "$JSON_PATH")
[[ "$SHOTS_LEN" == "0" || "$SHOTS_LEN" == "null" ]] && { echo "ERROR: .shots is empty" >&2; exit 1; }

# 每条 shot 的必填字段
REQUIRED_FIELDS=(id scene framing camera duration description_cn description_en characters location time_of_day lighting mood)
VALID_FRAMING="ELS LS MS MCU CU ECU"
VALID_CAMERA="static pan tilt push pull track handheld orbit"
VALID_TIME_OF_DAY="晨 上午 午 下午 黄昏 夜 深夜"

ERRORS=0
TOTAL_DURATION=0

for ((i=0; i<SHOTS_LEN; i++)); do
  SHOT=$(jq -c ".shots[$i]" "$JSON_PATH")
  SHOT_ID=$(echo "$SHOT" | jq -r '.id // "?"')

  for FIELD in "${REQUIRED_FIELDS[@]}"; do
    VAL=$(echo "$SHOT" | jq -r ".\"$FIELD\" // empty")
    if [[ -z "$VAL" ]] && [[ "$FIELD" != "dialogue" ]] && [[ "$FIELD" != "os" ]]; then
      echo "ERROR: shot $SHOT_ID missing required field .$FIELD" >&2
      ERRORS=$((ERRORS + 1))
    fi
  done

  FRAMING=$(echo "$SHOT" | jq -r '.framing')
  if ! grep -qw "$FRAMING" <<< "$VALID_FRAMING"; then
    echo "ERROR: shot $SHOT_ID framing='$FRAMING' not in {$VALID_FRAMING}" >&2
    ERRORS=$((ERRORS + 1))
  fi

  CAMERA=$(echo "$SHOT" | jq -r '.camera')
  if ! grep -qw "$CAMERA" <<< "$VALID_CAMERA"; then
    echo "ERROR: shot $SHOT_ID camera='$CAMERA' not in {$VALID_CAMERA}" >&2
    ERRORS=$((ERRORS + 1))
  fi

  TIME_OF_DAY=$(echo "$SHOT" | jq -r '.time_of_day')
  if ! grep -qw "$TIME_OF_DAY" <<< "$VALID_TIME_OF_DAY"; then
    echo "ERROR: shot $SHOT_ID time_of_day='$TIME_OF_DAY' not in {$VALID_TIME_OF_DAY}" >&2
    ERRORS=$((ERRORS + 1))
  fi

  DURATION=$(echo "$SHOT" | jq -r '.duration')
  TOTAL_DURATION=$(awk "BEGIN {print $TOTAL_DURATION + $DURATION}")
done

# 镜号唯一性
UNIQUE_IDS=$(jq -r '.shots[].id' "$JSON_PATH" | sort -u | wc -l | tr -d ' ')
if [[ "$UNIQUE_IDS" != "$SHOTS_LEN" ]]; then
  echo "ERROR: duplicate shot ids" >&2
  ERRORS=$((ERRORS + 1))
fi

# 输出汇总
echo "---"
echo "Episode: $EPISODE"
echo "Shots: $SHOTS_LEN"
echo "Total duration: ${TOTAL_DURATION}s"
echo "Errors: $ERRORS"

[[ $ERRORS -gt 0 ]] && exit 1
exit 0
```

- [ ] **Step 2: 加可执行权限**

```bash
chmod +x skills/script-to-shot/scripts/validate_shotlist.sh
```

- [ ] **Step 3: 手动测试(用 valid 样例)**

```bash
cat > /tmp/test-valid.json <<'EOF'
{
  "episode": 1,
  "shots": [
    {
      "id": "S001",
      "scene": 1,
      "framing": "MS",
      "camera": "static",
      "duration": 3.0,
      "description_cn": "沈栀推门",
      "description_en": "Young Asian woman pushes door open, cinematic film still",
      "characters": ["沈栀"],
      "dialogue": null,
      "os": null,
      "location": "巫术司大厅",
      "time_of_day": "夜",
      "lighting": "moody candlelight",
      "mood": "tense"
    }
  ]
}
EOF
./skills/script-to-shot/scripts/validate_shotlist.sh /tmp/test-valid.json
```

Expected:
```
---
Episode: 1
Shots: 1
Total duration: 3.0s
Errors: 0
```

exit code = 0

- [ ] **Step 4: 手动测试(用 invalid 样例,缺 framing)**

```bash
cat > /tmp/test-invalid.json <<'EOF'
{
  "episode": 1,
  "shots": [
    {
      "id": "S001",
      "scene": 1,
      "framing": "WRONG",
      "camera": "static",
      "duration": 3.0,
      "description_cn": "x",
      "description_en": "x",
      "characters": [],
      "location": "x",
      "time_of_day": "夜",
      "lighting": "x",
      "mood": "x"
    }
  ]
}
EOF
./skills/script-to-shot/scripts/validate_shotlist.sh /tmp/test-invalid.json
echo "exit: $?"
```

Expected:
- 输出含 `ERROR: shot S001 framing='WRONG' not in {ELS LS MS MCU CU ECU}`
- exit code != 0

- [ ] **Step 5: 清理测试文件**

```bash
rm /tmp/test-valid.json /tmp/test-invalid.json
```

- [ ] **Step 6: Commit**

```bash
git add skills/script-to-shot/scripts/validate_shotlist.sh
git commit -m "feat(script-to-shot): add JSON schema validator script"
```

---

### Task 2.5:写 script-to-shot 的 SKILL.md

**Files:**
- Create: `skills/script-to-shot/SKILL.md`

- [ ] **Step 1: 写完整文件**

````markdown
---
name: script-to-shot
version: 1.0.0
description: |
  剧本转镜头。把中文短剧拍摄本拆成结构化镜头表(.md 人读 + .json 机器读),含景别/运镜/时长/英文画面描述。
  触发方式:/script-to-shot、/剧本转镜头、「分镜」「画分镜」「拆镜头」
metadata:
  openclaw:
    requires:
      bins:
        - jq
    source: https://github.com/worldwonderer/oh-story-claudecode
---

# script-to-shot:剧本转镜头

你是分镜师。把拍摄本拆成结构化镜头表,产物双写(.md + .json),让下游 shot-to-image 直接吃 .json。

---

## 核心方法

**镜头表.json 是整条流水线的核心契约。** 字段错一个,下游生图全废。每个镜头必填:景别/运镜/时长/英文画面描述。

---

## Phase 1:解析拍摄本

输入:`{工作根}/第NNN集/拍摄本.md`

按 [story-to-script 的 script-format-spec](../story-to-script/references/script-format-spec.md) 切场号 → 抓动作、对白、OS。

如果输入不是标准格式 → 报错,提示用户先跑 `/story-to-script`。

---

## Phase 2:分镜决策

按 [references/pacing-templates.md](references/pacing-templates.md) 每场计算镜头数:

- 1 个短对白 = 1 镜
- 1 个长对白(> 15 字)= 2 镜
- 1 个单一动作 = 1-2 镜
- 1 个复杂动作 = 2-3 镜
- 1 个 OS = 1 镜
- 1 个场景切换 = 1 镜(转场空镜)
- 1 个信息差揭示 = 2 镜(铺垫 + 揭示特写)

一集目标镜头数:横屏 30-50 镜、竖屏 40-60 镜。

---

## Phase 3:镜头语言注入

每镜按 [references/shot-language.md](references/shot-language.md) 补:

- **景别**(framing,枚举 ELS/LS/MS/MCU/CU/ECU)
  - 对白默认中景/中近,情绪点切特写,环境切全景
- **运镜**(camera,枚举 static/pan/tilt/push/pull/track/handheld/orbit)
  - 默认 static,关键情绪推/拉,动作戏跟/手持
- **时长**(duration,秒数,浮点)
  - 按 pacing-templates.md 经验值
- **lighting**:按场景抬头"内/外·时辰"自动推(shot-language.md "光线"段)
- **mood**:按拍摄本动作/对白情绪选(shot-language.md "氛围"段)

---

## Phase 4:同步翻译并扩写英文画面描述

**这是本 skill 最值钱的产出。** 翻译质量决定下游全部生图。

按 [references/cn-to-en-visual-translation.md](references/cn-to-en-visual-translation.md) 把 `description_cn` → `description_en`,同时:

- 把角色名替换为外观描述(从 long-write 项目 `设定/角色/*.md` 召回 description_en,如不存在则从角色名 + 拍摄本提取的视觉特征构造)
- 加镜头/景深/光线/氛围关键词
- 加 `cinematic film still` 锚定电影风

如果 long-write 模式下 `设定/角色/{name}.md` 不存在 description_en 字段 → 当场为该角色生成一个英文外观描述,写回 `设定/角色/{name}.md` 末尾(加 `## description_en` 段)。这步保证下游 `shot-to-image` 不重复造轮子。

---

## Phase 5:双写输出 + 校验

写到 `{工作根}/第NNN集/`:

### 镜头表.md(给人审、可改)

| 镜号 | 场号 | 景别 | 运镜 | 时长 | 画面描述 | 角色 | 对白/OS | 备注 |

景别用中文(远景/全景/中景/...),运镜用中文(固定/摇/推/...),让用户读得懂。

### 镜头表.json(给下游机器读)

按 spec 的 JSON schema(见 `docs/superpowers/specs/2026-05-20-novel-to-video-pipeline-design.md` 节 3.2)。景别/运镜用英文枚举(ELS/MS/static/push/...)。

### 校验

```bash
./skills/script-to-shot/scripts/validate_shotlist.sh {工作根}/第NNN集/镜头表.json
```

校验失败 → 修正后重写,直到 exit 0。

---

## Phase 6:交付提示

- 总镜数 / 总时长 / 平均每镜
- 校验通过 / 失败
- 下一步:`/shot-to-image` 把镜头表变成镜头图

---

## 参考资料索引

| 场景 | 文件 |
|---|---|
| 景别/运镜/光线/氛围词表 | [references/shot-language.md](references/shot-language.md) |
| 节奏经验值(镜头数/时长) | [references/pacing-templates.md](references/pacing-templates.md) |
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

- 跟随用户的语言回复
- 镜头表.md 中文字段(给人读),.json 英文枚举(给机器读)
````

- [ ] **Step 2: Commit**

```bash
git add skills/script-to-shot/SKILL.md
git commit -m "feat(script-to-shot): add main SKILL.md"
```

---

### Task 2.6:创建测试 fixture(期望镜头表)

**Files:**
- Create: `tests/fixtures/expected-shotlist.json`

- [ ] **Step 1: 基于 expected-script.md 写期望的镜头表 .json**

```bash
cat > tests/fixtures/expected-shotlist.json <<'EOF'
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
      "description_en": "A young Asian woman in dark high-collar robes pushes open heavy wooden doors of an ancient sorcery bureau. Rain drips from the eaves above her, backlit by warm lantern light from inside. Cinematic film still, medium shot, shot on 35mm, shallow depth of field, moody nighttime atmosphere.",
      "characters": ["沈栀"],
      "dialogue": null,
      "os": null,
      "location": "巫术司大厅",
      "time_of_day": "夜",
      "lighting": "moody candlelight, cool blue rain backlight",
      "mood": "tense, foreboding"
    },
    {
      "id": "S002",
      "scene": 1,
      "framing": "MCU",
      "camera": "static",
      "duration": 2.0,
      "description_cn": "司长抬头,看见沈栀样子愣了一下",
      "description_en": "Medium close-up of an older man in dark robes seated at a desk. He looks up from scrolls, eyes widening slightly in recognition. Candlelight catches his weathered face. Cinematic film still, warm interior lighting.",
      "characters": ["司长"],
      "dialogue": "你来晚了。",
      "os": null,
      "location": "巫术司大厅",
      "time_of_day": "夜",
      "lighting": "moody candlelight",
      "mood": "tense"
    },
    {
      "id": "S003",
      "scene": 1,
      "framing": "CU",
      "camera": "push",
      "duration": 2.5,
      "description_cn": "沈栀面部特写,平静地说话",
      "description_en": "Close-up of a young Asian woman's face. Calm but heavy expression, faint scar above left eyebrow. Camera slowly pushes in. Cinematic film still, candlelit intimate lighting, shallow depth of field.",
      "characters": ["沈栀"],
      "dialogue": "我母亲死了。",
      "os": null,
      "location": "巫术司大厅",
      "time_of_day": "夜",
      "lighting": "moody candlelight",
      "mood": "somber"
    }
  ]
}
EOF
```

- [ ] **Step 2: 用 validator 校验 fixture 自己合法**

```bash
./skills/script-to-shot/scripts/validate_shotlist.sh tests/fixtures/expected-shotlist.json
```

Expected: exit 0, no errors。

- [ ] **Step 3: Commit**

```bash
git add tests/fixtures/expected-shotlist.json
git commit -m "test: add script-to-shot fixture (expected shotlist json)"
```

---

### Task 2.7:手动端到端测试 script-to-shot

**Files:**
- 无新建

- [ ] **Step 1: 用 Plan 1 产物作输入跑 skill**

先用 Task 1.7 的方法跑出 `./短剧产物/{时间戳}-{标题}/第001集/拍摄本.md`。

然后:
```
/script-to-shot ./短剧产物/{时间戳}-{标题}/第001集/拍摄本.md
```

期望:
1. 解析拍摄本场号
2. 每场分镜
3. 注入景别/运镜/时长/光线/氛围
4. 同步翻译英文画面描述
5. 双写 `镜头表.md` + `镜头表.json`
6. 跑 validator 通过

- [ ] **Step 2: 跑 validator**

```bash
./skills/script-to-shot/scripts/validate_shotlist.sh ./短剧产物/*/第001集/镜头表.json
```

Expected: exit 0, errors=0。

如失败 → 改 SKILL.md 或 reference 让 skill 知道遵守 schema。

- [ ] **Step 3: 抽样对比英文描述质量**

```bash
jq '.shots[0].description_en' ./短剧产物/*/第001集/镜头表.json
```

跟 fixture 的 expected description_en 对比。允许差异:
- 用词可不同(只要表达同一画面)
- 必须含:角色外观描述、cinematic film still、景别词、光线描述
- 不允许:出现中文姓名 / 缺光线描述 / 缺景别词

- [ ] **Step 4: 清理 + commit(如有改动)**

```bash
rm -rf ./短剧产物
```

如 SKILL.md/refs 有改动:
```bash
git add skills/script-to-shot
git commit -m "fix(script-to-shot): refine based on fixture test"
```

---

### Task 2.8:手动端到端测试 script-to-shot(long-write 模式,验证 description_en 回写)

**Files:**
- 无新建

- [ ] **Step 1: 准备 mock long-write 项目(同 Task 1.8,但角色文件无 description_en)**

```bash
mkdir -p /tmp/mock-novel/{设定/角色,大纲,正文,追踪,短剧/第001集}
cp tests/fixtures/expected-script.md /tmp/mock-novel/短剧/第001集/拍摄本.md
cat > /tmp/mock-novel/设定/角色/沈栀.md <<'EOF'
# 沈栀

- 年龄:二十出头
- 外貌:长发及腰,左眉一道旧疤
- 性格:平静、隐忍、决绝
EOF
cat > /tmp/mock-novel/设定/角色/司长.md <<'EOF'
# 司长

- 年龄:五十岁
- 性格:谨慎、世故
EOF
```

- [ ] **Step 2: cd 到 mock 跑 skill**

```bash
cd /tmp/mock-novel
```

```
/script-to-shot 短剧/第001集/拍摄本.md
```

- [ ] **Step 3: 校验 description_en 回写到角色文件**

```bash
grep -A 3 "## description_en" /tmp/mock-novel/设定/角色/沈栀.md
```

Expected: 沈栀.md 末尾被追加了 `## description_en` 段,内容是英文外观描述。

```bash
grep -A 3 "## description_en" /tmp/mock-novel/设定/角色/司长.md
```

Expected: 同上,司长也有。

- [ ] **Step 4: 校验镜头表.json 通过 validator**

```bash
{绝对路径}/skills/script-to-shot/scripts/validate_shotlist.sh /tmp/mock-novel/短剧/第001集/镜头表.json
```

Expected: exit 0。

- [ ] **Step 5: 清理 + commit(如有改动)**

```bash
cd -
rm -rf /tmp/mock-novel
```

如有改动:
```bash
git add skills/script-to-shot
git commit -m "fix(script-to-shot): refine description_en write-back behavior"
```

---

## 收尾 Task

### Task 3.1:更新 README 引用(可选)

**Files:**
- Modify: `README.md`(在 skill 列表追加两个新 skill)
- Modify: `README_EN.md`(同上)

如果项目有 README 列出 skill 清单,把 `story-to-script` 和 `script-to-shot` 加进去。

- [ ] **Step 1: 检查 README 是否含 skill 清单**

```bash
grep -n "story-long-write\|story-cover" README.md README_EN.md | head -20
```

如果两个 README 都不含 skill 清单 → 跳过这个 task。

- [ ] **Step 2: 如有清单,追加两个新 skill**

格式参照已有条目。

- [ ] **Step 3: Commit**

```bash
git add README.md README_EN.md
git commit -m "docs: add story-to-script and script-to-shot to README"
```

---

## Plan 1 完成验收

跑通以下三条流程 → Plan 1 验收通过:

1. `/story-to-script` 把 `tests/fixtures/novel-sample-chapter.md` 转出符合格式的拍摄本
2. `/script-to-shot` 把上一步的拍摄本转出 `镜头表.md` + `镜头表.json`
3. `./skills/script-to-shot/scripts/validate_shotlist.sh` 校验镜头表.json exit 0

下一步:Plan 2(`shot-to-image`,镜头表 → 镜头图,含适配层 + 角色卡预生成)。
