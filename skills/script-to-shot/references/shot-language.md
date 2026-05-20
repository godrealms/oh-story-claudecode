# 镜头语言词表

下游英文提示词全靠这一份的"中→英"对照。改这里 = 改下游全部生图/生视频效果。

---

## 景别（framing）

| 中文 | 英文缩写 | 英文全称 | 用途 |
|---|---|---|---|
| 远景 | `ELS` | extreme long shot | 环境/史诗感/小人物大场面 |
| 全景 | `LS` | long shot | 全身入镜，展示动作和环境关系 |
| 中景 | `MS` | medium shot | 半身，对白主用 |
| 中近景 | `MCU` | medium close-up | 胸像，情绪 + 对白 |
| 近景 | `CU` | close-up | 脸部，强情绪 |
| 特写 | `ECU` | extreme close-up | 眼/嘴/手/物件，极强情绪或细节 |

---

## 运镜（camera）

| 中文 | 英文 | 提示词模板 | 用途 |
|---|---|---|---|
| 固定 | `static` | `static camera, locked-off shot` | 默认，稳定 |
| 摇 | `pan` | `camera pans {left/right} slowly` | 横向扫场景 |
| 俯仰 | `tilt` | `camera tilts {up/down}` | 纵向揭示（从脚到脸） |
| 推 | `push` / `dolly in` | `camera slowly pushes in toward subject` | 情绪强化 |
| 拉 | `pull` / `dolly out` | `camera slowly pulls out` | 揭示环境/情绪释放 |
| 跟 | `track` / `follow` | `camera tracks behind subject` | 动作戏 |
| 手持 | `handheld` | `handheld shaky cam, documentary feel` | 紧张/真实感 |
| 环绕 | `orbit` | `camera orbits around subject` | 关键瞬间强调 |

---

## 光线（lighting）

按场景抬头的"内/外·时辰"自动推：

| 内/外 | 时辰 | 英文提示词 |
|---|---|---|
| 内 | 晨 | `soft morning light streaming through windows, warm golden hour interior` |
| 内 | 上午/午/下午 | `bright daylight through windows, soft natural interior lighting` |
| 内 | 黄昏 | `warm golden hour interior, long shadows, orange-amber light` |
| 内 | 夜 | `moody candlelight, low-key lighting, warm orange highlights against cool shadows` |
| 内 | 深夜 | `dim oil lamp, single light source, heavy shadows, noir lighting` |
| 外 | 晨 | `soft sunrise light, low golden sun, long shadows, misty atmosphere` |
| 外 | 上午/午/下午 | `bright sunny day, hard sunlight, clear visibility` |
| 外 | 黄昏 | `golden hour, warm sunset light, soft directional rays` |
| 外 | 夜 | `moonlight, cool blue tones, deep shadows, low ambient light` |
| 外 | 深夜 | `near-total darkness, distant lantern or moonlight only, deep noir` |

如场景明确有特殊光源（雨/雪/雷电/烛火/灯笼），叠加：
- `rain backlit by lanterns, dramatic backlight`
- `snow scene, overcast diffuse light`
- `lightning flash silhouette`
- `single candle on table, intimate close lighting`

---

## 氛围（mood）

从拍摄本的动作描述/对白情绪/场景抬头组合判断：

| 氛围词 | 英文提示词 |
|---|---|
| 紧张 | `tense, foreboding atmosphere` |
| 压抑 | `oppressive, claustrophobic mood` |
| 悲伤 | `melancholy, somber mood` |
| 浪漫 | `romantic, intimate atmosphere` |
| 激烈 | `intense, high-stakes` |
| 神秘 | `mysterious, enigmatic atmosphere` |
| 宁静 | `serene, calm` |
| 诡异 | `eerie, unsettling` |

---

## 构图（composition，可选，加分项）

提示词模板：
- `centered composition` — 中心构图，正式/对峙
- `rule of thirds` — 三分构图，自然
- `low angle` — 低角度，显威严
- `high angle` — 俯拍，显渺小
- `Dutch angle` — 倾斜，失衡感
- `over the shoulder` — 越肩，对话场用
- `wide shot with deep focus` — 大景深，展示空间纵深
- `shallow depth of field, bokeh background` — 浅景深，主体突出
