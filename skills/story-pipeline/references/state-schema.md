# state.json schema

每集根目录 `.pipeline.state.json`，由 `scripts/state.sh` 管理：

```json
{
  "episode": 1,
  "current_gate": "gate-4",
  "gates": {
    "gate-0": {"status": "approved", "updated_at": "2026-05-20T10:00:00Z"},
    "gate-1": {"status": "approved", "updated_at": "2026-05-20T10:05:00Z", "artifacts": ["拍摄本.md"]},
    "gate-2": {"status": "approved", "updated_at": "2026-05-20T10:20:00Z", "artifacts": ["镜头表.md", "镜头表.json"]},
    "gate-3": {"status": "approved", "updated_at": "2026-05-20T10:35:00Z", "artifacts": ["角色卡/沈栀.png", "角色卡/司长.png"]},
    "gate-4": {"status": "waiting_approval", "updated_at": "2026-05-20T11:50:00Z", "shots_total": 42, "shots_done": 40, "shots_failed": 2, "failed_shot_ids": ["S017", "S023"]},
    "gate-5": {"status": "pending"},
    "gate-6": {"status": "pending"}
  },
  "config": {
    "img_backend": "mj",
    "video_backend": "kling",
    "aspect": "9:16",
    "duration_default": 5
  },
  "created_at": "2026-05-20T10:00:00Z"
}
```

---

## 字段说明

- `episode`：集号（int）
- `current_gate`：当前 in_progress 或 waiting_approval 的闸门，由 `state_set_gate` 自动维护
- `gates.<gate>`：每个闸门的状态对象
  - `status`：`pending` / `running` / `waiting_approval` / `approved` / `stale`
  - `updated_at`：ISO 8601 UTC，由 `state_set_gate` 写入
  - `artifacts`（可选）：该闸门产出的文件相对路径列表，用 `state_add_artifact` 追加
  - 闸门可加额外字段（如 gate-4 的 `shots_total` / `shots_done` / `shots_failed`），由编排 skill 用 `jq` 直接写
- `config`：本集全局配置
  - `img_backend` / `video_backend`：用哪个后端（用户在 gate-0 决定）
  - `aspect`：`9:16` 或 `16:9`
  - `duration_default`：每镜默认时长（秒）
- `created_at`：state 创建时间，由 `state_init` 写入

---

## 闸门特有字段

### gate-0（准备）

无额外字段。

### gate-1（拍摄本）

`artifacts`：`["拍摄本.md"]` 或 `["拍摄本.md", "分镜本.md"]`

### gate-2（镜头表）

`artifacts`：`["镜头表.md", "镜头表.json"]`
`total_shots`：镜头总数（int）
`total_duration`：总时长秒数（float）

### gate-3（角色卡）

`artifacts`：每个角色一项，如 `["角色卡/沈栀.png", "角色卡/司长.png"]`（共享目录，路径相对于书目录而非集目录）
`characters_total`：int
`characters_done`：int

### gate-4（镜头图）

`shots_total`：int
`shots_done`：int
`shots_failed`：int
`failed_shot_ids`：`["S017", "S023"]`

失败镜号同步落到 `$EPISODE_DIR/.failures.jsonl`（一行一个 JSON 记录），由 shot-to-image 写入；编排 skill 收尾时读这份文件回填 `failed_shot_ids`。

### gate-5（镜头视频）

同 gate-4 结构，但单位是视频片段：
`shots_total` / `shots_done` / `shots_failed` / `failed_shot_ids`
`total_video_duration`：float（实际产出视频总时长）

### gate-6（交付包）

`artifacts`：`["README.md", "字幕脚本.txt", "_manifest.json"]`

---

## 回退与 previous_artifacts

`state_reset_from <dir> <from_gate>` 会把指定闸门及其后续闸门置 `pending`，已有 `artifacts` 字段挪到 `previous_artifacts` 保留，方便事后比对。盘上的实际文件不会被删除，编排 skill 自己决定要不要覆盖目录或留旧版做对照。

---

## 并发与文件锁

本流水线假定单 episode 单进程跑。如果用户同时跑两集（两个 terminal）：

- 两集是独立目录，各自 `.pipeline.state.json`，互不干扰
- 但生图 / 生视频 API 限速可能冲突 → 用户自己控并发

如果同一 episode 被两个进程同时跑 → 行为未定义，后写者赢。`state.sh` 的写操作走 `tmp + mv` 保证单条 jq 命令的原子性，但跨命令的 race 不防。implementation 阶段如果有真需求可以加 `flock`，默认不做。
