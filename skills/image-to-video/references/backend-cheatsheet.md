# 视频后端速查表

---

## 可灵（`kling`）— **状态：Plan 3 实现**

- **环境变量**：`KLING_API_KEY`，`KLING_BASE_URL`（默认 `https://api.klingai.com`）
- **特长**：图生视频质量高，中文 prompt 友好，人物运动自然
- **弱点**：任务排队时间长（2-5 分钟），API 异步
- **时长**：5s / 10s 两档（10s 成本翻倍）
- **价格**：5s 约 ¥3.5 / $0.5，10s 约 ¥7 / $1
- **API endpoint**：`POST {BASE_URL}/v1/videos/image2video`（提交）/ `GET {BASE_URL}/v1/videos/image2video/{task_id}`（查询）
- **参数**：`image`（base64 或 URL）、`prompt`、`duration`（5/10）、`aspect_ratio`
- **角色一致性机制**：有“主体参考”功能，可上传角色卡作 subject_id（本 plan 暂不接，Plan 4 补）

---

## 即梦 / 火山方舟（`jimeng`）— **状态：占位，Plan 4 落地**

- **环境变量**：`JIMENG_API_KEY`，`JIMENG_BASE_URL`（默认 `https://ark.cn-beijing.volces.com`）
- **特长**：中文 prompt 一流，有“角色”功能可锁人物
- **弱点**：API 文档以中文为主，字段命名跟英文圈不一样
- **时长**：5s 起，可到 10s
- **价格**：5s 约 ¥3
- **API endpoint**：`POST {BASE_URL}/api/v3/contents/generations/tasks`（提交）/ `GET {BASE_URL}/api/v3/contents/generations/tasks/{task_id}`（查询）
- **角色一致性机制**：`character_id` 字段（本 plan 暂不接）

---

## Runway Gen-3（`runway`）— **状态：占位，Plan 4 落地**

- **环境变量**：`RUNWAY_API_KEY`
- **特长**：运动幅度大，西式审美强，镜头语言响应好
- **弱点**：成本高
- **时长**：5s / 10s
- **价格**：5s 约 $0.5，10s 约 $1
- **API endpoint**：`POST https://api.dev.runwayml.com/v1/image_to_video`
- **角色一致性机制**：仅靠输入图（image_url），不支持独立 character refer

---

## Sora 2（`sora`）— **状态：占位，Plan 4 落地**

- **环境变量**：`SORA_API_KEY`，`SORA_BASE_URL`
- **状态说明**：2026 年 API 对企业开放，个人未必能接。adapter 仅占位，Plan 4 补
- **特长**：运动最真实，可生超长（20s+）
- **价格**：高

---

## Veo / Google（`veo`）— **状态：占位，Plan 4 落地**

- **环境变量**：`VEO_API_KEY`
- **状态说明**：Google AI Studio 部分支持。adapter 仅占位

---

## prompt-only（`prompt-only`）— **状态：Plan 3 实现**

- **环境变量**：无
- **行为**：导出 `.kling.txt`、`.jimeng.txt`、`.runway.txt` 等多家后端的提示词文件到 `提示词视频/`
- **用途**：零接入，用户自己挑后端复制粘贴

---

## 后端选择优先级

1. CLI 显式 → 用
2. 环境变量 `VIDEO_BACKEND` 显式 → 用
3. 按顺序扫：
   - `kling`（`KLING_API_KEY` + `KLING_BASE_URL`）
   - `jimeng`（`JIMENG_API_KEY` + `JIMENG_BASE_URL`）
   - `runway`（`RUNWAY_API_KEY`）
   - `sora`（`SORA_API_KEY` + `SORA_BASE_URL`，且 adapter 已实现）
   - `veo`（`VEO_API_KEY`，且 adapter 已实现）
4. 全没齐 → 降级 `prompt-only`

注：Sora/Veo adapter 默认占位 `exit 1` 报“暂未实现”，自动路由跳过它们落到 prompt-only。

---

## 每集预算估算

按 50 镜 × 5s/镜：

| 后端 | 单镜成本 | 50 镜总成本 |
|---|---|---|
| 可灵 | $0.5 | $25 |
| 即梦 | ¥3（~$0.4） | $20 |
| Runway | $0.5 | $25 |
| prompt-only | 0 | 0 |

每集成本数十美元 — 比 shot-to-image 贵得多。用户跑前必须确认。
