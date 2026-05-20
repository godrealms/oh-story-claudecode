---
name: image-to-video
version: 1.0.0
description: |
  图片转视频。把镜头图 + 运动提示词转成视频片段（每镜 5s 默认），支持多生视频后端（可灵 / 即梦 / Runway / Sora / Veo / prompt-only）。
  触发方式：/image-to-video、/图片转视频、「图生视频」「出视频」
metadata:
  openclaw:
    requires:
      bins:
        - jq
        - curl
        - base64
    source: https://github.com/worldwonderer/oh-story-claudecode
---

# image-to-video：图片转视频

你是图生视频执行者。把每镜的 PNG + 运动提示词转成 5-10s 视频片段，失败不阻塞，末尾汇总。

---

## 核心方法

1. **多后端适配层** —— 见 [references/backend-cheatsheet.md](references/backend-cheatsheet.md)
2. **prompt 决定运动** —— 模型不看图猜动作，要靠 prompt 写明白。见 [references/motion-prompts.md](references/motion-prompts.md)
3. **不做合成** —— 只产逐镜 .mp4，后期工具拼接。见 [references/post-production-handoff.md](references/post-production-handoff.md)
4. **失败不阻塞** —— 单镜失败记录到 `.failures.jsonl`（一行一个 JSON 记录），末尾汇总，用户跑 `--retry-failures`

---

## Phase 1：后端选择

skill 启动时检查环境变量，按 [references/backend-cheatsheet.md](references/backend-cheatsheet.md) 的优先级自动选后端（`KLING_API_KEY` + `KLING_BASE_URL` → `JIMENG_API_KEY` + `JIMENG_BASE_URL` → `RUNWAY_API_KEY` → `SORA_API_KEY` + `SORA_BASE_URL` → `VEO_API_KEY` → 兜底 `prompt-only`）；用户可显式 `VIDEO_BACKEND=kling /image-to-video` 覆盖。

route.sh 在 dispatch 时会把选中的 backend 打到 stderr（`[route] dispatching to backend=...`），用户能看到。

> **当前后端状态**：Plan 3 实现了 `kling` 和 `prompt-only`；`jimeng` / `runway` / `sora` / `veo` 见 Plan 4。设置 `VIDEO_BACKEND` 强制使用未实现后端时会得到清晰的错误提示。自动探测时即便环境变量齐备，adapter 文件不存在也会跳过，落到下一个后端。

告知用户：
- 本次用什么后端、为什么
- 单镜成本、全集预算估算（参考 [references/backend-cheatsheet.md](references/backend-cheatsheet.md) 的价格表）
- 异步任务等待时间（可灵典型 2-5 min/镜，50 镜串行 ≈ 2-4 小时）

---

## Phase 2：运动提示词构造

每镜的 motion prompt 由 [references/motion-prompts.md](references/motion-prompts.md) 模板构造。`lib/json.sh` 提供 `build_video_prompt_json` 函数自动把镜头表 shot JSON 转成下游 adapter 期望的 prompt JSON：

```
{
  "prompt_en": "<镜头表 description_en>",
  "motion_prompt": "Camera: <运镜模板>. Atmosphere: <lighting>, <mood>.",
  "duration": <秒数>,
  "aspect": "<比例>",
  "shot_meta": { ... 整条 shot 透传 ... }
}
```

`camera_motion` 从镜头表的 `camera` 字段（`static` / `pan` / `tilt` / `push` / `pull` / `track` / `handheld` / `orbit`）映射成英文运动模板。完整模板和按后端微调说明见 [references/motion-prompts.md](references/motion-prompts.md)。

---

## Phase 3：逐镜生视频

遍历 `镜头表.json` 的 shots：

```bash
EPISODE_DIR="{工作根}/第NNN集"
mkdir -p "$EPISODE_DIR/镜头视频"

source ./scripts/lib/json.sh   # 引入 build_video_prompt_json

for SHOT_ID in $(jq -r '.shots[].id' "$EPISODE_DIR/镜头表.json"); do
  SHOT=$(jq -c ".shots[] | select(.id == \"$SHOT_ID\")" "$EPISODE_DIR/镜头表.json")
  DURATION=$(echo "$SHOT" | jq -r '.duration')
  IMAGE="$EPISODE_DIR/镜头图/${SHOT_ID}.png"

  # 镜头图必须存在(image-to-video 的输入就是图,缺图直接失败)
  if [[ ! -f "$IMAGE" ]]; then
    jq -n \
      --arg id "$SHOT_ID" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg reason "missing_image: $IMAGE" \
      '{shot_id:$id, ts:$ts, reason:$reason}' \
      >> "$EPISODE_DIR/.failures.jsonl"
    continue
  fi

  # 构造视频 prompt JSON
  PROMPT_JSON=$(build_video_prompt_json "$SHOT" "$DURATION" "{aspect}")

  # 跑 adapter（通过 route.sh dispatch）
  if echo "$PROMPT_JSON" | ./scripts/route.sh \
       --shot-id "$SHOT_ID" \
       --out-dir "$EPISODE_DIR/镜头视频" \
       --image "$IMAGE"; then
    : # 成功
  else
    # 失败记录(JSONL,一行一个记录)
    jq -n \
      --arg id "$SHOT_ID" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg reason "adapter exit non-zero" \
      '{shot_id:$id, ts:$ts, reason:$reason}' \
      >> "$EPISODE_DIR/.failures.jsonl"
  fi
done
```

注：可灵等后端是异步，单镜 2-5 分钟。50 镜串行跑 ≈ 2-4 小时。如要并行，用 `xargs -P 4` 包裹（后端通常有并发限制，慎用）。

---

## Phase 4：失败重试

```
/image-to-video --retry-failures
```

→ 读 `.failures.jsonl` → 只重生这些镜号 → 成功的从失败列表移除。

> ⚠️ **当前实现说明**：`--retry-failures` 和 `--redo` 暂为约定，尚未在 route.sh 实现。
> 当前 agent 需要手动：
> 1. `jq -r '.shot_id' {工作根}/第NNN集/.failures.jsonl` 读取失败镜号
> 2. 对每个失败镜号，从 `镜头表.json` 取对应 shot，再走 Phase 3 单镜循环
> 3. 成功后从 `.failures.jsonl` 删除对应行
> 这些约定将在 Plan 4 编排 skill 落地时统一实现。

重试 3 次仍失败 → 提示用户考虑换后端或改 motion_prompt（见 [references/image-to-video-pitfalls.md](references/image-to-video-pitfalls.md)）。

---

## Phase 5：生成 manifest + 字幕脚本

跑完后生成两份汇总。Phase 4（失败重试）跑完后再执行下面两个脚本。

### _manifest.json（在 `{EPISODE_DIR}/`）

schema：

```json
{
  "episode": NNN,
  "total_shots": 50,
  "succeeded": 47,
  "failed": 3,
  "total_duration": 195.5,
  "shots": [
    {"id": "S001", "duration": 5, "video": "镜头视频/S001.mp4", "status": "ok"},
    {"id": "S002", "duration": 5, "video": "镜头视频/S002.mp4", "status": "ok"}
  ]
}
```

从 `镜头视频/*.json` sidecar 汇总生成：

```bash
# Generate _manifest.json from 镜头视频/*.json sidecar files
EPISODE_DIR="{工作根}/第NNN集"
EPISODE_NUM=$(basename "$EPISODE_DIR" | sed 's/^第0*\([0-9]\+\)集$/\1/')

jq -n \
  --arg ep "$EPISODE_NUM" \
  --argjson shots "$(
    jq -s 'map({
      id: .shot_id,
      duration: (.duration // 5),
      video: ("镜头视频/" + .shot_id + ".mp4"),
      status: (if .status == null then "ok" else .status end),
      backend: (.backend // "unknown")
    })' "$EPISODE_DIR"/镜头视频/*.json
  )" \
  '{
    episode: ($ep | tonumber),
    total_shots: ($shots | length),
    succeeded: ($shots | map(select(.status == "ok")) | length),
    failed: ($shots | map(select(.status != "ok")) | length),
    total_duration: ($shots | map(.duration) | add),
    shots: $shots
  }' > "$EPISODE_DIR/_manifest.json"
```

### 字幕脚本.txt（在 `{EPISODE_DIR}/`）

按 [references/post-production-handoff.md](references/post-production-handoff.md) 格式累加每镜对白 / OS + 时间码，剪映可直接导入。

时间码靠累加每镜 duration 算出来；对白 / OS 从 `镜头表.json` 取：

```bash
# Generate 字幕脚本.txt from 镜头表.json (source of dialogue/OS) + sidecar durations
EPISODE_DIR="{工作根}/第NNN集"
SHOTLIST="$EPISODE_DIR/镜头表.json"

ACCUM=0
> "$EPISODE_DIR/字幕脚本.txt"

for SHOT_ID in $(jq -r '.shots[].id' "$SHOTLIST"); do
  SHOT=$(jq -c ".shots[] | select(.id == \"$SHOT_ID\")" "$SHOTLIST")
  DURATION=$(echo "$SHOT" | jq -r '.duration // 5')
  DIALOGUE=$(echo "$SHOT" | jq -r '.dialogue // empty')
  OS=$(echo "$SHOT" | jq -r '.os // empty')

  # Format timecode HH:MM:SS or MM:SS
  START_SEC=$ACCUM
  END_SEC=$(awk "BEGIN {print $ACCUM + $DURATION}")
  START_TS=$(printf '%02d:%02d' $((START_SEC / 60)) $((START_SEC % 60)))
  END_TS=$(printf '%02d:%02d' $((${END_SEC%.*} / 60)) $((${END_SEC%.*} % 60)))

  LINE=""
  [[ -n "$DIALOGUE" ]] && LINE="$DIALOGUE"
  [[ -n "$OS" ]] && LINE="${LINE:+$LINE / }OS：$OS"
  [[ -z "$LINE" ]] && LINE="（无对白）"

  printf '%s - %s  [%s]  %s\n' "$START_TS" "$END_TS" "$SHOT_ID" "$LINE" >> "$EPISODE_DIR/字幕脚本.txt"
  ACCUM=$(awk "BEGIN {print $ACCUM + $DURATION}")
done
```

---

## Phase 6：交付提示

- 成功 X 镜 / 失败 Y 镜
- 总时长 / 总成本
- 产物路径（`镜头视频/`、`提示词视频/`、`_manifest.json`、`字幕脚本.txt`）
- 下一步：打开剪映 / Pr，按 [references/post-production-handoff.md](references/post-production-handoff.md) 做后期合成、BGM、TTS、字幕

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
| 视频出完 | 后期工具（剪映 / Pr） | 见 [references/post-production-handoff.md](references/post-production-handoff.md) |
| 某镜不满意 | 单镜重生（手动） | 暂用单镜循环重跑，见 Phase 4「当前实现说明」（Plan 4 会落地 `--redo`） |
| 失败重试（手动） | 见 Phase 4「当前实现说明」 | Plan 4 落地 `--retry-failures` |

---

## 语言

- 跟随用户的语言回复，用户用什么语言就用什么语言回复
- 中文回复遵循《中文文案排版指北》
