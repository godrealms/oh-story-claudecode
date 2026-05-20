# 提示词构造

把 `镜头表.json` 一条 shot 记录构造成各后端能吃的提示词。

---

## 通用 prompt 公式

```
{description_en}, {lighting}, {mood},
cinematic film still, {aspect_keyword},
shot on {camera_lens_keyword},
{framing_keyword} shot,
featuring {character_refer_hint}
```

各字段：
- `description_en`：从 `shots[i].description_en` 来，**已经包含**角色外观描述、构图、电影感（由 script-to-shot 写好）
- `lighting`：`shots[i].lighting`
- `mood`：`shots[i].mood`
- `aspect_keyword`：横屏 → `16:9 aspect ratio, widescreen` / 竖屏 → `9:16 aspect ratio, vertical`
- `camera_lens_keyword`：默认 `35mm anamorphic lens`，特写镜可换 `85mm portrait lens`
- `framing_keyword`：景别 ELS/LS/MS/MCU/CU/ECU → `extreme wide / wide / medium / medium close-up / close-up / extreme close-up`
- `character_refer_hint`：见下

---

## 角色参考提示词构造

每个后端机制不一样，见 [character-consistency.md](character-consistency.md)。这里给统一的 fallback：

```
featuring the character matching reference: {character_card_dir}/{character_name}.png
```

具体怎么传参考图给后端，各 adapter 处理。

---

## negative prompt（通用）

```
blurry, low quality, watermark, text overlay, ugly, deformed,
extra fingers, mutated hands, signature, logo,
bad anatomy, disfigured, oversaturated
```

（MJ 不支持 negative prompt；Comfy/SD/FLUX 支持。）

---

## 角色卡 prompt（角色卡预生成专用）

跟镜头 prompt 不同——角色卡要"正面胸像，纯色背景，中性表情，清晰五官"。

```
{character_description_en}, centered portrait, frontal view, neutral expression, plain gray studio background, even soft lighting, clear facial features, cinematic film still, shot on 85mm portrait lens, shallow depth of field, 9:16 aspect ratio
```

注意：
- 不带场景 / 不带情绪 / 不带运镜
- 用纯色背景，避免背景元素干扰下游"指认"
- 用 85mm portrait lens，标准人像头
- 即使最终是横屏，角色卡也用 9:16 — 给下游做 refer 时更稳定
