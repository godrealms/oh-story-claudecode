# 图生视频常见坑

---

## 1. 图片不动（出来跟静态图一样）

**症状**：5s 视频里画面几乎不动

**原因**：prompt 没写 motion / 运镜是 static / 模型偏保守

**修复**：

- prompt 加 subject motion（参考 [motion-prompts.md](motion-prompts.md)）
- 即使 camera=static，也加 `subtle natural motion, breathing, gentle environment movement`
- 换后端（Runway 比可灵更“敢动”）

---

## 2. 人物畸变（脸变形、肢体扭曲）

**症状**：开始几帧还好，后面脸越来越歪

**原因**：模型在补帧时丢失锚点

**修复**：

- 输入图本身的人物姿态尽量简单（不要复杂手势 / 复杂角度）
- prompt 加 `consistent facial features, stable anatomy`
- 时长缩到 5s（10s 畸变概率翻倍）

---

## 3. 运动方向错（本该推，出来是拉）

**症状**：prompt 写 push 但视频是 pull

**原因**：模型对 camera 词理解不一致

**修复**：

- 用更直白的描述：`camera moves closer to subject` 代替 `push in`
- 用结构化 camera_control 字段（可灵 / 即梦支持）
- 重试 2-3 次（同一 prompt 不同种子）

---

## 4. 文字闪烁（画面里的字一帧一变）

**症状**：墙上的字、招牌的字每帧不一样

**原因**：模型不能稳定渲染文字

**修复**：

- 避免画面里出现关键文字
- 如必须有，在 shot-to-image 阶段就规避（描述里写 “a blank wooden sign” 而不是 “a sign saying 'Welcome'”）
- 后期 Pr 加文字遮罩盖住

---

## 5. 色调漂移（镜头里色温变了）

**症状**：开头暖色调，结尾冷色调

**原因**：模型自由发挥光线

**修复**：

- prompt 强化 lighting：`consistent warm candlelight throughout, no lighting changes`
- 缩短时长

---

## 6. 任务排队超时

**症状**：可灵 / 即梦提交后等了 10 分钟还没好

**原因**：服务高峰，任务排队

**修复**：

- 增加 timeout（默认 300s，调到 600s）
- 错峰跑（避免国内晚高峰）
- 实在不行 → 换 Runway（国外节点）

---

## 7. 角色一致性丢失（同人不同脸）

**症状**：S001 的脸 ≠ S002 的脸（即使两张图来自同一个角色卡）

**原因**：image-to-video 默认只看输入图，不知道全集还有别的镜

**修复**：

- shot-to-image 阶段保证镜头图本身已经一致（用了角色卡）
- 接受小幅差异（图生视频会有 5-10% 漂移，无法完全消除）
- 后期剪辑：把面孔差异大的镜头换景别或换角度，降低关注度

---

## 8. 整段画面崩了（像水彩晕开）

**症状**：几秒后画面糊掉

**原因**：输入图清晰度不够 / prompt 跟图差太远

**修复**：

- 输入图至少 1024×1024（再小后端会拒 / 糊）
- prompt 不要描述图里没有的元素（描述要跟图一致）
- 减少时长

---

## 调试流程

某镜视频不好，按顺序：

1. 看 `镜头视频/{shot_id}.json` 的 motion_prompt → 是不是不合理
2. 改 motion_prompt 重生：`/image-to-video --redo S017`
3. 换 duration（10 → 5）
4. 换 backend
5. 重做镜头图（回 shot-to-image）
6. 重做镜头表（回 script-to-shot，改运镜 camera 字段）

> ⚠️ **当前实现说明**：`--redo` 暂为约定，尚未在 route.sh 实现。
> 当前 agent 需要手动从 `镜头视频/{shot_id}.json` 取该镜参数，走 SKILL.md Phase 3 的单镜循环重生。
> 该约定将在 Plan 4 编排 skill 落地时统一实现。
