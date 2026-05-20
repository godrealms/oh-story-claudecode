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

不支持图像 refer。只能在 prompt 里反复 reinforce 角色外观描述：

```
A young Asian woman, early twenties, waist-length black hair, dark high-collar robe, faint scar above left eyebrow, pale skin, sharp eyes — standing at the temple gate at dusk...
```

效果一般。GPT-Image-2 后端的角色一致性靠"描述精确度"，不是参考图。

### Midjourney `--cref`

```
{prompt} --cref {character_card_url} --cw 100 --ar 9:16 --v 6
```

- `--cref`：角色参考图 URL（必须公网可访问）
- `--cw 0-100`：权重，100 = 最贴近参考，0 = 只参考脸不参考服饰

工作流：
1. 角色卡生成后，上传到代理提供的图床（各代理服务商 API 不一，通常返回一个 https URL）
2. 把 URL 写入 `角色卡/{name}.json` 的 `mj_cref_url` 字段
3. 后续每镜 prompt 加 `--cref {mj_cref_url} --cw 80`

### Replicate / Fal（IP-Adapter）

通过 `image` 参数传角色卡 base64 或 URL：

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

`ip_adapter_scale` 0-1，越高越贴近参考。

### ComfyUI

需要 workflow.json 含 IP-Adapter 节点。用户自己准备 workflow 模板，skill 把角色卡作为 IP-Adapter 输入注入。

复杂度高，Plan 4 再做。

---

## 角色卡生成 prompt（标准化）

详见 [prompt-construction.md](prompt-construction.md) 的"角色卡 prompt"段。要点：

- 正面胸像
- 纯色灰背景
- 中性表情
- 85mm portrait lens（标准人像头）
- 9:16（给下游做 refer 时更稳定）
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

如果某镜生图后明显跟角色卡长得不一样（用户标记）：
1. 删掉那张图
2. 跑 `/shot-to-image --retry-failures` 重生
3. 如果重生 3 次还不像 → 提示用户考虑换后端，或者用更详细的 prompt 描述
