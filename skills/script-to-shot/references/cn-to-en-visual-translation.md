# 中文画面描述 → 英文电影感描述

这是本 skill 最值钱的产出。**翻译质量直接决定下游所有生图的下限。**

---

## 翻译原则

1. **不直译**：中文"沈栀推门"不能翻成"Shen Zhi pushes the door"——下游生图模型不知道"Shen Zhi"是谁
2. **替换为视觉描述**："沈栀" → "young Asian woman, early twenties, long black hair, dark robes"（从角色卡的 description_en 来）
3. **加电影感关键词**：`cinematic film still`、`shot on 35mm`、`shallow depth of field`、`golden hour lighting`
4. **加构图线索**：景别 + 角度 + 焦点
5. **加纵深/光线/色温**：让画面"立体"

---

## 完整翻译范式

### 范式 1：动作镜

原文：
> 沈栀推开巫术司的大门，雨水从屋檐滴落。

英文：
> A young Asian woman in dark high-collar robes pushes open heavy wooden doors of an ancient sorcery bureau. Rain drips from the eaves above her, backlit by warm lantern light from inside. Cinematic film still, medium shot, shot on 35mm, shallow depth of field, moody nighttime atmosphere.

注意：
- 角色用外观描述替换姓名
- 加 "ancient sorcery bureau"（具体化场景）
- 加 "backlit by warm lantern light"（光线方向）
- 加 cinematic + 镜头 + 景深 + 氛围

### 范式 2：对白特写镜

原文：
> 沈栀：我母亲死了。

英文（画面描述，不是台词翻译）：
> Extreme close-up of a young Asian woman's face. Her eyes are calm but heavy. Candlelight flickers across her left cheek, casting half her face in shadow. A faint old scar above her left eyebrow catches the light. Cinematic film still, shallow depth of field, intimate lighting.

注意：对白不翻译，只翻译"说这句话时的画面"。

### 范式 3：环境镜

原文：
> （档案室，昏暗。）

英文：
> A dimly lit ancient archive room. Tall wooden shelves filled with scroll cases stretch into darkness. A single oil lamp burns on a heavy desk, casting long shadows. Empty composition, no people. Cinematic film still, deep noir lighting, atmospheric.

---

## 角色一致性的关键

每个角色第一次出现时，**必须**用完整的 description_en 替换姓名：

> "Shen Zhi" → "young Asian woman, early twenties, waist-length black hair, dark high-collar robe, faint scar above left eyebrow, pale skin"

后续镜头出现同一角色时，可缩写为：

> "the young woman" / "the woman with the scarred eyebrow" / "the same woman"

但**关键外观特征**（发型、服饰、疤痕）每镜都重复，这是给下游生图模型的"身份锚点"。

---

## 必加关键词清单

每个镜头的英文描述，必加（否则下游生图烂）：

- `cinematic film still` — 让模型走电影风，不走插画风
- `{lighting}` — 光线描述，来自 shot-language.md 的"光线"段
- `shallow depth of field` 或 `deep focus` — 景深
- `shot on 35mm` 或 `shot on anamorphic lens` — 镜头（可选，但加了更电影感）
- 景别词：`wide shot` / `medium shot` / `close-up` / `extreme close-up`（对应景别表）

---

## 反例（必避免）

- ❌ 直接翻人名："Shen Zhi pushes the door" — 模型不知道是谁
- ❌ 缺光线描述：模型自由发挥，通常出"中午阳光直射"的烂图
- ❌ 缺景别词：模型给一个奇怪的角度
- ❌ 中文专有名词照搬："the Yamen" / "the Tianjiu Pavilion" — 改为通用描述 "ancient government office" / "ornate pavilion"
- ❌ 抽象情绪词单独出现："sad atmosphere" — 必须配画面 "melancholy lighting, downcast posture, autumn leaves falling"
