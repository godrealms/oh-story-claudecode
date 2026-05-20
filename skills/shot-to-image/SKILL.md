---
name: shot-to-image
version: 1.0.0
description: |
  镜头转图片。把镜头表.json 转成镜头图，含角色卡预生成 + 复用，支持多生图后端（GPT-Image-2 / MJ / Replicate / Fal / ComfyUI / prompt-only）。
  触发方式：/shot-to-image、/镜头转图片、「生镜头图」「出图」
metadata:
  openclaw:
    requires:
      bins:
        - jq
        - curl
        - base64
    source: https://github.com/worldwonderer/oh-story-claudecode
---

# shot-to-image：镜头转图片

你是分镜出图执行者。把 `镜头表.json` 一条条 shot 转成 PNG，确保角色一致性。

---

## 核心方法

1. **角色卡预生成 + 复用** —— 见 [references/character-consistency.md](references/character-consistency.md)
2. **多后端适配层** —— 见 [references/backend-cheatsheet.md](references/backend-cheatsheet.md)
3. **失败不阻塞** —— 单镜失败记录到 `.failures.jsonl`（一行一个 JSON 记录），末尾汇总，用户跑 `--retry-failures`

---

## Phase 1：后端选择

skill 启动时检查环境变量，按 [references/backend-cheatsheet.md](references/backend-cheatsheet.md) 的优先级自动选后端（`GPT_IMAGE_API_KEY` → `MJ_API_KEY` + `MJ_BASE_URL` → `FAL_KEY` → `REPLICATE_API_TOKEN` → ComfyUI 探活 → 兜底 `prompt-only`）；用户可显式 `IMG_BACKEND=mj /shot-to-image` 覆盖。

route.sh 在 dispatch 时会把选中的 backend 打到 stderr（`[route] dispatching to backend=...`），用户能看到。

> **当前后端状态**：全部 6 个生图后端均已实现（gpt-image / mj / replicate / fal / comfy / prompt-only）。设置 `IMG_BACKEND` 强制使用某后端时若环境变量缺失会得到清晰的错误提示。

告知用户：
- 本次用什么后端、为什么
- 预算估算（参考 [references/cost-table.md](references/cost-table.md)）

---

## Phase 2：角色卡预生成

### 扫角色

```bash
jq -r '[.shots[].characters[]] | unique | .[]' {工作根}/第NNN集/镜头表.json
```

得本集角色清单。

### 召回 description_en

按以下优先级：
1. `{工作根}/短剧/角色卡/{name}.png` 和 `{name}.card.json` 都存在 → 跳过生成（character_card.sh 自动 short-circuit）。注意：prompt-only 后端不生成 PNG，重跑会再次写入 prompt 文件，这是预期行为。
2. long-write 模式下 `设定/角色/{name}.md` 含 `## description_en` 段（由 script-to-shot 写）→ 用它
3. 都没有 → 询问用户角色外观描述（或者从拍摄本/镜头表抽取构造）

### 跑预生成

对每个未生成的角色：

```bash
./scripts/character_card.sh \
  "{角色名}" \
  "{description_en}" \
  "{工作根}/短剧/角色卡" \
  "{aspect}"
```

产物：
- `{NAME}.png` —— 角色卡参考图（prompt-only 后端下不生成）
- `{NAME}.card.json` —— **canonical 角色卡 schema**（name / description_en / reference_png / *_id 字段 / generated_at / generated_by_backend）
- `{NAME}.json` —— adapter 写的 sidecar（审计信息：实际 prompt、backend、provider 返回 id 等），不要跟 .card.json 混淆

---

## Phase 3：逐镜生图

遍历 `镜头表.json` 的 shots：

```bash
mkdir -p {工作根}/第NNN集/镜头图

source ./scripts/lib/json.sh   # 引入 build_prompt_json

for SHOT_ID in $(jq -r '.shots[].id' 镜头表.json); do
  SHOT=$(jq -c ".shots[] | select(.id == \"$SHOT_ID\")" 镜头表.json)

  # 构造 prompt JSON（lib/json.sh 提供的 build_prompt_json 函数）
  PROMPT_JSON=$(build_prompt_json "$SHOT" "{工作根}/短剧/角色卡" "{aspect}")

  # 决定 refer（主角第一个角色的角色卡 PNG）
  FIRST_CHAR=$(echo "$SHOT" | jq -r '.characters[0] // empty')
  REFER=""
  [[ -n "$FIRST_CHAR" && -f "{工作根}/短剧/角色卡/${FIRST_CHAR}.png" ]] \
    && REFER="{工作根}/短剧/角色卡/${FIRST_CHAR}.png"

  # 跑 adapter（通过 route.sh dispatch）
  if echo "$PROMPT_JSON" | ./scripts/route.sh \
       --shot-id "$SHOT_ID" \
       --out-dir "{工作根}/第NNN集/镜头图" \
       ${REFER:+--refer "$REFER"}; then
    : # 成功
  else
    # 失败记录(JSONL,一行一个记录)
    jq -n \
      --arg id "$SHOT_ID" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg reason "adapter exit non-zero" \
      '{shot_id:$id, ts:$ts, reason:$reason}' \
      >> "{工作根}/第NNN集/.failures.jsonl"
  fi
done
```

---

## Phase 4：一致性自检（可选）

只在用户加 `--check-consistency` 时跑。基础版：对每个角色随机抽 3 张生成图，跟角色卡放一起，让用户人眼判断；不一致 → 标记重生。

advanced 版（face embedding）留给未来扩展。

---

## Phase 5：失败重试

```
/shot-to-image --retry-failures
```

→ 读 `.failures.jsonl` → 只重生这些镜号 → 成功的从失败列表移除。

> ⚠️ **当前实现说明**：`--retry-failures` 和 `--redo` 暂为约定,尚未在 route.sh 实现。
> 当前 agent 需要手动:
> 1. `jq -r '.shot_id' {工作根}/第NNN集/.failures.jsonl` 读取失败镜号
> 2. 对每个失败镜号,从 `镜头表.json` 取对应 shot,再走 Phase 3 单镜循环
> 3. 成功后从 `.failures.jsonl` 删除对应行
> 这些约定将在 Plan 4 编排 skill 落地时统一实现。

重试 3 次仍失败 → 提示用户考虑换后端或改 `description_en`（见 [references/failure-modes.md](references/failure-modes.md)）。

---

## Phase 6：交付提示

- 成功 X 镜 / 失败 Y 镜
- 总成本（按 [references/cost-table.md](references/cost-table.md) 估算）
- 下一步：`/image-to-video` 把镜头图转成视频片段

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
| 某镜不满意 | 单镜重生（手动） | 暂用单镜循环重跑，见 Phase 5「当前实现说明」（Plan 4 会落地 `--redo`） |
| 失败重试（手动） | 见 Phase 5「当前实现说明」 | Plan 4 落地 `--retry-failures` |

---

## 语言

- 跟随用户的语言回复，用户用什么语言就用什么语言回复
- 中文回复遵循《中文文案排版指北》
