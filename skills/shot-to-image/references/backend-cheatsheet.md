# 后端速查表

每个后端的提示词风格、参数范围、限制。

---

## GPT-Image-2（`gpt-image`）

- **环境变量**：`GPT_IMAGE_API_KEY`，可选 `GPT_IMAGE_BASE_URL`（默认 `https://api.openai.com/v1`）
- **提示词风格**：自然语言英文，跟 DALL-E 风格类似
- **特长**：文字渲染好（可在画面里写中文字）
- **弱点**：电影感弱，人物一致性差（仅靠 prompt）
- **参数范围**：size 支持 `1024x1024 / 1536x1024 / 1024x1536`
- **价格**（参考 2026 年）：约 $0.04/张（1024×1024）
- **角色一致性机制**：只能靠 prompt 描述，无 refer 图机制
- **API endpoint**：`POST {BASE_URL}/images/generations`

---

## Midjourney 第三方代理（`mj`）

- **环境变量**：`MJ_API_KEY`，`MJ_BASE_URL`（必填，各代理不一样）
- **提示词风格**：关键词堆叠，加 `--ar 9:16 --v 6 --style raw` 等参数
- **特长**：电影感最强，审美在线
- **弱点**：文字渲染差，API 异步（要轮询）
- **参数范围**：`--ar`，`--v`，`--style`，`--cref`（角色参考），`--sref`（风格参考）
- **价格**：取决于代理服务商，约 $0.05-0.15/张
- **角色一致性机制**：`--cref {URL}`（传角色卡 URL）+ `--cw 100`（权重）
- **API 流程**：提交任务 → 拿 task_id → 轮询 → 拿到图 URL

---

## Replicate（`replicate`）

- **环境变量**：`REPLICATE_API_TOKEN`
- **提示词风格**：看模型，FLUX 用自然语言，SDXL 用 tag 式
- **特长**：模型多（FLUX/SDXL/IP-Adapter），价格透明
- **弱点**：略慢（冷启动 10-30s）
- **价格**：FLUX-dev 约 $0.003/张，FLUX-pro 约 $0.04/张
- **角色一致性机制**：image input + IP-Adapter
- **API endpoint**：`POST https://api.replicate.com/v1/predictions`（同步等待或异步轮询）

---

## Fal.ai（`fal`）

- **环境变量**：`FAL_KEY`
- **提示词风格**：同 Replicate（主力 FLUX 系列）
- **特长**：延迟低（2-5s）
- **价格**：FLUX-schnell 约 $0.003/张，FLUX-pro 约 $0.05/张
- **角色一致性机制**：image input + IP-Adapter
- **API endpoint**：`POST https://fal.run/{model_id}`

---

## ComfyUI 本地（`comfy`）

- **环境变量**：`COMFY_HOST`（默认 `127.0.0.1:8188`）
- **提示词风格**：依赖加载的 checkpoint（FLUX/SDXL/SD1.5）
- **特长**：免费，可控性最高（workflow.json），支持 LoRA
- **弱点**：要求用户有显卡 + 已部署 ComfyUI
- **角色一致性机制**：自定义 workflow 含 IP-Adapter 或 LoRA
- **API endpoint**：`POST http://{COMFY_HOST}/prompt`

---

## prompt-only（`prompt-only`）

- **环境变量**：无
- **行为**：不调任何 API，只输出 .mj.txt（MJ 风格）和 .sd.json（SD/Comfy 风格）到 `提示词/` 目录
- **用途**：零接入门槛，用户自己拿提示词去 Discord/A1111/Comfy 跑

---

## 后端选择优先级（给 SKILL.md 抄）

1. CLI 用户显式说用某后端 → 直接路由
2. 环境变量 `IMG_BACKEND` 显式 → 路由
3. 按以下顺序扫，第一个 env 齐的就用：
   - `gpt-image`（`GPT_IMAGE_API_KEY`）
   - `mj`（`MJ_API_KEY` + `MJ_BASE_URL`）
   - `fal`（`FAL_KEY`）
   - `replicate`（`REPLICATE_API_TOKEN`）
   - `comfy`（`COMFY_HOST`，默认 `127.0.0.1:8188`，但要 curl 探测端口可达）
4. 全没齐 → 降级 `prompt-only`，提示用户配 key
