# 闸门工作流

6 个闸门，每个闸门由一个子 skill 执行，完成后暂停等用户确认。

---

## 闸门表

| Gate | 名 | 执行 skill | 产物 |
|---|---|---|---|
| gate-0 | 准备 | （主线程） | 集划分确认 + 后端探测 + 预算估算 |
| gate-1 | 拍摄本 | story-to-script | `拍摄本.md` |
| gate-2 | 镜头表 | script-to-shot | `镜头表.md` + `镜头表.json` |
| gate-3 | 角色卡 | shot-to-image（Phase 2 only） | `角色卡/*.png` + `*.card.json` |
| gate-4 | 镜头图 | shot-to-image（Phase 3+） | `镜头图/*.png` + `*.json` |
| gate-5 | 镜头视频 | image-to-video | `镜头视频/*.mp4` + `*.json` |
| gate-6 | 交付包 | （主线程） | `README.md` + `字幕脚本.txt` + `_manifest.json` |

---

## 闸门状态枚举

- `pending`：未开始
- `running`：正在执行
- `waiting_approval`：执行完成，等用户确认
- `approved`：用户批准，可进下一闸
- `stale`：已被回退，产物保留但下游闸门重置

实际枚举值定义在 `scripts/state.sh`，通过 `state_set_gate <episode_dir> <gate> <status>` 写入 `.pipeline.state.json`。

---

## 子 skill 调用契约

编排 skill 调子 skill 时，设以下环境变量：

```bash
export STORY_PIPELINE_EPISODE=1
export STORY_PIPELINE_EPISODE_DIR="/path/to/{书名}/短剧/第001集"
export STORY_PIPELINE_GATE=gate-2
export IMG_BACKEND=...     # 从 state.json config.img_backend 读
export VIDEO_BACKEND=...   # 从 state.json config.video_backend 读
```

子 skill 通过这些环境变量知道：

- 自己在编排里跑（vs 独立跑）
- 产物落到指定 episode_dir
- 不重新询问后端（用 config 里定的）

子 skill 失败时把失败镜号写进 `$STORY_PIPELINE_EPISODE_DIR/.failures.jsonl`（一行一个 JSON 记录），编排 skill 在闸门收尾时读这份文件汇总产出，决定是否阻塞推进。

---

## 暂停与续跑

闸门完成 → 编排 skill 把这一闸状态置 `waiting_approval`（`state_set_gate <dir> <gate> waiting_approval`）→ 输出产物路径 + 评估 + 等待用户响应。

用户响应「继续」→ 编排 skill 把这一闸置 `approved`，推进到下一闸。

用户响应「重做」→ 编排 skill 跑 `state_reset_from <dir> <gate>`，重新执行这一闸。

用户响应「退出」→ 编排 skill 不动 state，直接退出。下次启动续跑。

---

## 续跑逻辑

`/story-pipeline` 启动时：

1. 探测当前目录下所有 `{书名}/短剧/{第NNN集}/.pipeline.state.json`
   - 找到多集 in_progress，询问用户跑哪集
   - 没有 → 跳到 gate-0 准备阶段
2. 用 `state_get_current_gate <dir>` 读当前闸门
3. 用 `state_get_gate_status <dir> <gate>` 看状态：
   - `waiting_approval` → 提示用户「上次跑到这一闸停在等批准，要继续吗？」
   - `running` → 异常中断，建议 `state_reset_from <dir> <gate>` 重新跑这一闸
   - `approved` → 推进到下一闸
4. 从当前闸门续跑

---

## 回退

`/story-pipeline --redo gate-2` → 在指定 episode 上跑 `state_reset_from <dir> gate-2` → 进入 gate-2。

`state_reset_from` 会把指定闸门及其后续闸门状态置 `pending`，同时把这些闸门已有的 `artifacts` 字段挪到 `previous_artifacts` 保留（不删盘上文件，agent 自己决定要不要清空目录重写）。

> **注意**：`--redo` / `--skip` 这两个 CLI 参数是约定，由 SKILL.md 的 Phase 1 主线程逻辑解析后调相应的 `state.sh` 函数实现。route.sh 里没有这两个 flag。

---

## 跳过

`/story-pipeline --skip gate-5` → 在当前 episode 把 gate-5 置 `approved`（无产物），推进到 gate-6。

典型用途：用户想直接做剪辑试拼，跳过视频生成步骤。
