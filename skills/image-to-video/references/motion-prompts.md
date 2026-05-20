# 运动提示词模板

视频后端不是看图片本身决定怎么动，而是看 prompt 决定。prompt 不写动作 → 出来是个静态图飘几秒。

---

## 运动提示词三层

1. **Camera motion**：相机怎么动
2. **Subject motion**：被摄主体怎么动
3. **Atmosphere**：氛围（光线 + 情绪），保持画面连贯

完整 prompt：

```
Camera: {camera_motion}, {speed}.
Subject motion: {character_action}.
Atmosphere: {lighting}, {mood}.
Duration: {N}s.
```

---

## Camera motion 模板

| 镜头表 camera 值 | 英文运动提示词 |
|---|---|
| `static` | `static camera, locked-off shot, subtle natural motion only` |
| `pan` | `camera pans slowly left to right` 或 `slow right pan` |
| `tilt` | `camera tilts up slowly from feet to face` 或 `slow tilt down` |
| `push` | `camera slowly pushes in toward subject, dolly-in` |
| `pull` | `camera slowly pulls out from subject, dolly-out` |
| `track` | `camera tracks behind subject, following motion` |
| `handheld` | `handheld shaky camera, documentary feel, slight wobble` |
| `orbit` | `camera orbits around subject 180 degrees` |

速度修饰：

- `very slow` — 几乎察觉不到
- `slow` — 默认
- `moderate` — 中速
- `fast` — 快速（慎用，容易乱）

---

## Subject motion 模板

从镜头表的 `description_cn` / `description_en` 抽动作动词，转为视频语言：

| 描述里有 | Subject motion |
|---|---|
| “推开门” | `subject pushes door open slowly` |
| “走进来” | `subject walks into frame` |
| “抬头” | `subject looks up slowly` |
| “回头” | `subject turns head and looks back` |
| “笑了一下” | `subject smiles briefly` |
| “手停了一下” | `subject's hand pauses mid-motion` |
| “雨水滴落” | `rain drops slowly from above` |
| “烛火摇晃” | `candle flame flickers gently` |
| （静态对白，无明显动作） | `subject speaks calmly, subtle facial expression` |

如果实在没有可拍动作 → `subtle ambient motion, slight breathing, gentle environment movement`（微动）。

---

## Atmosphere 模板

直接复用镜头表的 `lighting` + `mood` 字段：

```
Atmosphere: {lighting}, {mood} mood, cinematic quality, film grain
```

---

## 完整 prompt 示例

> **关于本节示例：** 这是手工拼出的"理想形态"prompt（含 Subject motion / Duration / cinematic 后缀）。`lib/json.sh` 的 `build_video_prompt_json` 只产出最小骨架（`Camera:... Atmosphere:...`，无 Subject motion，无 Duration 行），Subject motion / cinematic quality / Duration 由 adapter 或 agent 在调后端前手动追加。镜头表的 `duration` 字段允许小数（如 3.0），adapter 会按各后端能接受的档位映射（如 kling 走 5/10 两档）。

镜头表里的 S001（沈栀推门）：

```json
{
  "id": "S001",
  "camera": "static",
  "duration": 5.0,
  "description_en": "A young Asian woman in dark robes pushes open heavy wooden doors of an ancient sorcery bureau. Rain drips from the eaves...",
  "lighting": "moody candlelight, cool blue rain backlight",
  "mood": "tense, foreboding"
}
```

构造的视频 prompt（理想形态）：

```
A young Asian woman in dark robes pushes open heavy wooden doors of an ancient sorcery bureau. Rain drips from the eaves above her.

Camera: static camera, locked-off shot, subtle natural motion only.
Subject motion: subject pushes door open slowly, walks into frame.
Atmosphere: moody candlelight, cool blue rain backlight, tense and foreboding mood.
Duration: 5 seconds.
```

`build_video_prompt_json` 默认产出（最小骨架）：

```
A young Asian woman in dark robes pushes open heavy wooden doors of an ancient sorcery bureau. Rain drips from the eaves...

Camera: static camera, locked-off shot. Atmosphere: moody candlelight, cool blue rain backlight, tense, foreboding.
```

---

## 按后端微调

不同后端对 prompt 长度和风格偏好不一样：

### 可灵（kling）

- 偏好简洁，300 字以内
- 支持中英文混合
- camera 控制有专门字段（`camera_control`），可以不放 prompt 而走结构化参数

### 即梦（jimeng）

- 偏好中文 prompt（它的训练数据中文权重高）
- 镜头控制可用「镜头语言」字段

### Runway Gen-3

- 偏好英文，长 prompt 可以（500+ 字）
- 用 `Camera: ...` 起首加强相机控制
- 推荐每 prompt 加 `cinematic quality, professional cinematography`

### Sora 2

- 偏好详细英文叙述
- 时长可以更长（10s+），但每秒成本更高

### prompt-only

- 完整保留所有信息，用户自己挑后端
