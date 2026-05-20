# 失败模式 & 修复

生图常见烂图模式 + 怎么 prompt 工程改善。

---

## 1. 文字渲染失败（画面里出现乱码）

**症状**：背景里出现奇怪的英文字符串或乱码方块字

**原因**：模型试图渲染描述里的中文专有名词

**修复**：
- prompt 不出现中文（全英文）
- 加 negative：`text overlay, watermark, signature, logo, gibberish text`

如果就是要画面有字（比如对联、招牌），用 GPT-Image-2（它的中文文字渲染好），其他后端避免。

---

## 2. 人物变形（六指、两个头）

**症状**：手指多/少、肢体扭曲、表情诡异

**原因**：复杂动作 + 模型理解不到位

**修复**：
- prompt 加 `clear anatomy, natural pose`
- negative 加 `extra fingers, mutated hands, deformed, bad anatomy, disfigured`
- 复杂动作拆成简单姿势（"she's pouring tea while looking at him" → "she pours tea, looking down at the cup"）
- 如果用 MJ，加 `--style raw` 抑制美化

---

## 3. 机位错乱（明明要中景出了远景）

**症状**：景别词被忽略

**原因**：prompt 里景别词放在末尾，模型权重低

**修复**：
- 景别词放在 prompt 最前面：`Medium close-up of a young woman...` 而不是 `A young woman ... medium close-up`
- 加额外强化：`tight framing` / `close framing` / `wide framing`

---

## 4. 角色长得不一样

**症状**：同一个角色每镜面孔不同

**原因**：没传 refer 图 / refer 权重低

**修复**：
- 用支持 refer 的后端（MJ / FLUX with IP-Adapter）
- 提高 `--cw` 或 `ip_adapter_scale`
- 见 [character-consistency.md](character-consistency.md)

---

## 5. 风格漂移（每镜画风不一样）

**症状**：有的镜像电影海报，有的像插画，有的像 3D 渲染

**原因**：没有锚定风格关键词

**修复**：
- 每镜 prompt 都强制加 `cinematic film still`
- 如果用 MJ，统一加 `--sref {style_reference_url}`（用第一张满意的图做风格锚）
- 如果用 Comfy/FLUX，固定 seed（同一集所有镜用同一个 seed 段）

---

## 6. 光线全是大白光

**症状**：无论是夜戏白天戏都白花花一片

**原因**：lighting 字段没传 / 模型默认偏好高 key

**修复**：
- 确保 prompt 含 lighting 描述（由 script-to-shot 注入）
- 加强化：`dramatic lighting, chiaroscuro, low-key lighting, deep shadows`
- 夜戏：`moody nighttime, candlelit, warm orange highlights against cool blue shadows`

---

## 7. 服饰错乱（本应古装却出了现代装）

**症状**：角色穿现代衣服

**原因**：描述不够具体

**修复**：
- description_en 必须明确服饰：`Tang dynasty robe with embroidered sleeves` / `dark Qing dynasty official robe with mandarin collar`
- 一旦角色服饰定了，所有镜头都重复同一描述

---

## 调试流程

某镜效果不好，按以下顺序排查：

1. 看 `镜头图/{shot_id}.json` 的 prompt 字段 → 检查 prompt 是否合理
2. 改 prompt 重生一次：`/shot-to-image --redo S017`
3. 改不好 → 换后端：`IMG_BACKEND=mj /shot-to-image --redo S017`
4. 换不好 → 改 `镜头表.json` 里的 `description_en`，然后 redo
5. 还不好 → 改 `镜头表.json` 里的 `framing` 或 `camera`（可能是镜头语言决策本身有问题）
