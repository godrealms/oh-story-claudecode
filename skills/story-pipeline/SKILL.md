---
name: story-pipeline
version: 1.0.0
description: |
  小说转视频编排器。6 个分步闸门（剧本/镜头表/角色卡/镜头图/镜头视频/交付包），每闸暂停等用户确认，支持续跑和回退。
  触发方式：/story-pipeline、/小说转视频、「拍短剧」「开拍」「跑流水线」
metadata:
  openclaw:
    requires:
      bins:
        - jq
        - curl
    source: https://github.com/worldwonderer/oh-story-claudecode
---

# story-pipeline：小说转视频编排器

你是流水线编排者。串起 5 个子 skill，在每个阶段产物完成后暂停，等用户确认才推进。

---

## 核心方法

**分步闸门 + 状态持久化。** 6 个闸门（详见 [references/gate-workflow.md](references/gate-workflow.md)），每集一份 [`.pipeline.state.json`](references/state-schema.md)，支持续跑和回退。

子 skill 调用契约：通过环境变量 `STORY_PIPELINE_EPISODE_DIR` / `STORY_PIPELINE_GATE` / `IMG_BACKEND` / `VIDEO_BACKEND` 告知子 skill「我在编排里跑」。详见 [references/gate-workflow.md](references/gate-workflow.md) 的「子 skill 调用契约」一节。

---

## Phase 1：启动决策

### 探测续跑还是新跑

```bash
# 查当前书目录的所有 in-progress episode
find {当前目录}/短剧 -name ".pipeline.state.json" 2>/dev/null
```

- 找到 1 个 → 询问用户：「发现第 NNN 集还在 gate-X，要续跑吗？」
- 找到多个 → 列出让用户选
- 找不到 → 进 gate-0 启动新跑

### 命令行参数

- `/story-pipeline` → 续跑或新跑
- `/story-pipeline --episode 3` → 指定续跑第 3 集
- `/story-pipeline --redo gate-2` → 回退当前 episode 到 gate-2 重跑
- `/story-pipeline --skip gate-5` → 跳过 gate-5（不跑视频，直接到交付）
- `/story-pipeline --new` → 强制开新集

> **实现说明**：这些 flag 由本 SKILL.md 的主线程逻辑解析，调相应的 `state.sh` 函数（如 `state_reset_from`）实现。route.sh 里没有这些参数。

---

## Phase 2：gate-0 准备

```bash
source skills/story-pipeline/scripts/state.sh
```

### 集划分

调 `story-to-script` 的 Phase 1 集划分逻辑（智能识别 long-write / 独立模式），用户决定：

- 转哪几章
- 几章 = 1 集
- 横屏 / 竖屏
- 改编强度

### 后端探测

route.sh 没有 `--dry-run`，直接照 route.sh 的探测逻辑读环境变量决定：

```bash
# 图后端优先级：GPT_IMAGE_API_KEY → MJ_API_KEY+MJ_BASE_URL → FAL_KEY → REPLICATE_API_TOKEN → ComfyUI 探活 → prompt-only
IMG_BACKEND_DETECTED="prompt-only"
if   [[ -n "${GPT_IMAGE_API_KEY:-}" ]]; then IMG_BACKEND_DETECTED="gpt-image"
elif [[ -n "${MJ_API_KEY:-}" && -n "${MJ_BASE_URL:-}" ]]; then IMG_BACKEND_DETECTED="mj"
elif [[ -n "${FAL_KEY:-}" ]]; then IMG_BACKEND_DETECTED="fal"
elif [[ -n "${REPLICATE_API_TOKEN:-}" ]]; then IMG_BACKEND_DETECTED="replicate"
elif curl -s --max-time 2 "http://${COMFY_HOST:-127.0.0.1:8188}/system_stats" >/dev/null 2>&1; then IMG_BACKEND_DETECTED="comfy"
fi

# 视频后端优先级：KLING → JIMENG → RUNWAY → SORA → VEO → prompt-only
VIDEO_BACKEND_DETECTED="prompt-only"
if   [[ -n "${KLING_API_KEY:-}" && -n "${KLING_BASE_URL:-}" ]]; then VIDEO_BACKEND_DETECTED="kling"
elif [[ -n "${JIMENG_API_KEY:-}" && -n "${JIMENG_BASE_URL:-}" ]]; then VIDEO_BACKEND_DETECTED="jimeng"
elif [[ -n "${RUNWAY_API_KEY:-}" ]]; then VIDEO_BACKEND_DETECTED="runway"
fi
```

或更省事：实际跑一次 route.sh 触发 stderr 的 `[route] dispatching to backend=...`，从中提取 backend 名。两种做法等价。

告知用户：

- 检测到的图后端、视频后端
- 全集预算估算（参考子 skill 的 cost-table）
- 询问是否继续 / 是否换后端（用户可显式 `IMG_BACKEND=mj` 或 `VIDEO_BACKEND=kling` 覆盖）

### 创建 state.json

```bash
EPISODE_DIR="{工作根}/短剧/第NNN集"
mkdir -p "$EPISODE_DIR"
state_init "$EPISODE_DIR" "$EPISODE_NUM" "$IMG_BACKEND" "$VIDEO_BACKEND" "$ASPECT"
state_set_gate "$EPISODE_DIR" gate-0 approved
```

---

## Phase 3：gate-1 → gate-5 循环

通用模式：

```bash
for GATE in gate-1 gate-2 gate-3 gate-4 gate-5; do
  STATUS="$(state_get_gate_status "$EPISODE_DIR" "$GATE")"

  case "$STATUS" in
    approved)
      # 续跑：已通过的闸门直接跳过
      continue
      ;;
    waiting_approval)
      # 上次跑到这一闸停在等批准；不重跑，直接等确认
      echo "$GATE 上次已交付，等待确认。"
      ;;
    running)
      # 异常中断，建议重做
      echo "$GATE 上次异常中断（status=running）。要重做（state_reset_from \"$EPISODE_DIR\" $GATE）还是退出（手动诊断）？(重做/退出)"
      read RESPONSE
      case "$RESPONSE" in
        重做) state_reset_from "$EPISODE_DIR" "$GATE" ;;
        *) exit 0 ;;
      esac
      STATUS="pending"
      ;;
  esac

  # 如 status 在上面变成了 pending 或本来就 pending/stale，执行 sub-skill
  if [[ "$STATUS" == "pending" || "$STATUS" == "stale" ]]; then
    state_set_gate "$EPISODE_DIR" "$GATE" running

    # 调对应子 skill（带环境变量）
    STORY_PIPELINE_EPISODE_DIR="$EPISODE_DIR" \
    STORY_PIPELINE_GATE="$GATE" \
    IMG_BACKEND="$(state_get_config "$EPISODE_DIR" img_backend)" \
    VIDEO_BACKEND="$(state_get_config "$EPISODE_DIR" video_backend)" \
      {对应子 skill 调用}

    state_set_gate "$EPISODE_DIR" "$GATE" waiting_approval
  fi

  # 读失败镜号（如果子 skill 写了 .failures.jsonl）
  if [[ -f "$EPISODE_DIR/.failures.jsonl" ]]; then
    FAILED=$(jq -r '.shot_id' "$EPISODE_DIR/.failures.jsonl" | tr '\n' ' ')
    [[ -n "$FAILED" ]] && echo "失败镜号：$FAILED"
  fi

  # 输出产物 + 评估 + 等用户响应
  echo "$GATE 完成，产物已落到 $EPISODE_DIR"
  echo "请确认（继续 / 重做 / 退出）："
  read RESPONSE

  case "$RESPONSE" in
    继续) state_set_gate "$EPISODE_DIR" "$GATE" approved ;;
    重做) state_reset_from "$EPISODE_DIR" "$GATE" ;;
    退出) exit 0 ;;
  esac
done
```

### gate-1：拍摄本（story-to-script）

调：`/story-to-script` 的 Phase 2-5（skip Phase 1 集划分，因为 gate-0 已做）
产物：`$EPISODE_DIR/拍摄本.md`（可选 `分镜本.md`）

### gate-2：镜头表（script-to-shot）

调：`/script-to-shot` 全 Phase
产物：`$EPISODE_DIR/镜头表.md` + `镜头表.json`（校验通过）

### gate-3：角色卡（shot-to-image Phase 2）

调：`/shot-to-image` 只跑 Phase 1（后端选）+ Phase 2（角色卡预生成）
产物：`{书名}/短剧/角色卡/*.png` + `*.card.json`

### gate-4：镜头图（shot-to-image Phase 3+）

调：`/shot-to-image` 跳过 Phase 2（角色卡已就绪），跑 Phase 3-5
产物：`$EPISODE_DIR/镜头图/*.png` + `*.json`
内部依赖：`scripts/lib/json.sh` 的 `build_prompt_json` 函数

### gate-5：镜头视频（image-to-video）

调：`/image-to-video` 全 Phase
产物：`$EPISODE_DIR/镜头视频/*.mp4` + `*.json` + `_manifest.json` + `字幕脚本.txt`
内部依赖：`scripts/lib/json.sh` 的 `build_video_prompt_json` 函数

---

## Phase 4：gate-6 交付包

汇总生成 `$EPISODE_DIR/README.md`：

```markdown
# 第 NNN 集 交付包

## 镜头清单
{从 _manifest.json 抽出来的镜号 + 时长 + 文件路径表}

## 字幕脚本
见 字幕脚本.txt

## 后期工作流
1. 打开剪映 / Pr，新建 9:16（或 16:9）项目
2. 按文件名顺序导入 镜头视频/
3. 加 BGM，挑 {根据 mood 推荐的 BGM 类型}
4. 用 字幕脚本.txt 加字幕轨
5. OS 段用剪映 TTS（古风男 / 女声），其他对白可不加配音（让画面 + 字幕承担）
6. 输出参数：见 `skills/image-to-video/references/post-production-handoff.md`

## 统计
- 总镜数：{N}
- 视频总时长：{X.Y}s
- 估算成片时长（加转场 + 字幕）：{X.Y}s × 1.1
```

完成 → `state_set_gate "$EPISODE_DIR" gate-6 approved`。同时把交付物登记到 state：

```bash
state_add_artifact "$EPISODE_DIR" gate-6 README.md
state_add_artifact "$EPISODE_DIR" gate-6 字幕脚本.txt
state_add_artifact "$EPISODE_DIR" gate-6 _manifest.json
```

---

## Phase 5：收尾

- 打印总成本（从各 `*.json` 里 backend 字段累加，参考子 skill 的 cost-table）
- 询问用户是否继续下一集：`/story-pipeline --episode {NEXT}`
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
| 单步出错 | 直接调对应单 skill 修 | `/shot-to-image`（agent 手动重跑失败镜，见 shot-to-image SKILL.md Phase 5） |
| 单独跑某 skill 不走编排 | 直接调 | `/script-to-shot` |
| 想退出再回来 | 不动 state，下次启动续跑 | `/story-pipeline` |
| 回退某闸 | CLI flag | `/story-pipeline --redo gate-2` |
| 跳过某闸 | CLI flag | `/story-pipeline --skip gate-5` |
| 流水线完了想继续下一集 | 重新跑 | `/story-pipeline --new` |

---

## 语言

- 跟随用户的语言回复，用户用什么语言就用什么语言回复
- 中文回复遵循《中文文案排版指北》
