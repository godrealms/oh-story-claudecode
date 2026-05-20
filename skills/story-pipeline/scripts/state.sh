#!/usr/bin/env bash
# state.sh — .pipeline.state.json 读写工具
#
# 用法（source 进来用，而不是直接执行）：
#   source state.sh
#   state_init <episode_dir> <episode_num> [img_backend] [video_backend] [aspect]
#   state_set_gate <episode_dir> <gate> <status>
#   state_add_artifact <episode_dir> <gate> <artifact>
#   state_get_current_gate <episode_dir>
#   state_get_gate_status <episode_dir> <gate>
#   state_reset_from <episode_dir> <from_gate>
#   state_get_config <episode_dir> <key>
#
# 全部函数遵循 set -euo pipefail 兼容（不预设错误处理，让调用方控制）。

STATE_FILE_NAME=".pipeline.state.json"

# 初始化 state.json（若已存在则保留，不覆盖）
state_init() {
  local dir="$1" episode="$2"
  local img_backend="${3:-prompt-only}"
  local video_backend="${4:-prompt-only}"
  local aspect="${5:-9:16}"
  local file="$dir/$STATE_FILE_NAME"

  [[ -z "$dir" ]] && { echo "ERROR: state_init: dir required" >&2; return 2; }
  [[ -z "$episode" ]] && { echo "ERROR: state_init: episode required" >&2; return 2; }

  if [[ -f "$file" ]]; then
    return 0
  fi

  mkdir -p "$dir"

  # 用 jq -n --argjson/--arg 安全构造，避免 here-doc 把变量值当 JSON 字面量插入
  jq -n \
    --argjson episode "$episode" \
    --arg img_backend "$img_backend" \
    --arg video_backend "$video_backend" \
    --arg aspect "$aspect" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      episode: $episode,
      current_gate: "gate-0",
      gates: {
        "gate-0": {status: "pending"},
        "gate-1": {status: "pending"},
        "gate-2": {status: "pending"},
        "gate-3": {status: "pending"},
        "gate-4": {status: "pending"},
        "gate-5": {status: "pending"},
        "gate-6": {status: "pending"}
      },
      config: {
        img_backend: $img_backend,
        video_backend: $video_backend,
        aspect: $aspect
      },
      created_at: $created_at
    }' > "$file"
}

# 设置某 gate 状态，并把 current_gate 指向它
state_set_gate() {
  # 注意：参数名避开 `status`（在 zsh 中是只读变量），用 gate_status 替代
  local dir="$1" gate="$2" gate_status="$3"
  local file="$dir/$STATE_FILE_NAME"

  [[ -z "$dir" || -z "$gate" || -z "$gate_status" ]] && {
    echo "ERROR: state_set_gate: dir/gate/status required" >&2; return 2;
  }
  [[ ! -f "$file" ]] && { echo "ERROR: state_set_gate: state file not found: $file" >&2; return 1; }

  local tmp
  tmp=$(mktemp)
  # trap RETURN 仅 bash 支持；zsh 用别的语法且会对裸 RETURN 报警告
  if [[ -n "${BASH_VERSION:-}" ]]; then
    trap 'rm -f "$tmp"' RETURN
  fi

  jq --arg g "$gate" \
     --arg s "$gate_status" \
     --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.gates[$g].status = $s
      | .gates[$g].updated_at = $t
      | .current_gate = $g' \
    "$file" > "$tmp" && mv "$tmp" "$file"
}

# 给某 gate 追加一条 artifact 路径
state_add_artifact() {
  local dir="$1" gate="$2" artifact="$3"
  local file="$dir/$STATE_FILE_NAME"

  [[ -z "$dir" || -z "$gate" || -z "$artifact" ]] && {
    echo "ERROR: state_add_artifact: dir/gate/artifact required" >&2; return 2;
  }
  [[ ! -f "$file" ]] && { echo "ERROR: state_add_artifact: state file not found: $file" >&2; return 1; }

  local tmp
  tmp=$(mktemp)
  # trap RETURN 仅 bash 支持；zsh 用别的语法且会对裸 RETURN 报警告
  if [[ -n "${BASH_VERSION:-}" ]]; then
    trap 'rm -f "$tmp"' RETURN
  fi

  jq --arg g "$gate" --arg a "$artifact" \
    '.gates[$g].artifacts = ((.gates[$g].artifacts // []) + [$a])' \
    "$file" > "$tmp" && mv "$tmp" "$file"
}

# 读 current_gate
state_get_current_gate() {
  local dir="$1"
  local file="$dir/$STATE_FILE_NAME"
  [[ ! -f "$file" ]] && { echo "ERROR: state_get_current_gate: state file not found: $file" >&2; return 1; }
  jq -r '.current_gate // empty' "$file"
}

# 读某 gate 状态
state_get_gate_status() {
  local dir="$1" gate="$2"
  local file="$dir/$STATE_FILE_NAME"
  [[ ! -f "$file" ]] && { echo "ERROR: state_get_gate_status: state file not found: $file" >&2; return 1; }
  jq -r --arg g "$gate" '.gates[$g].status // empty' "$file"
}

# 从某 gate 起重置：把它和后续闸门置 pending，已有产物移到 previous_artifacts 保留
state_reset_from() {
  local dir="$1" from_gate="$2"
  local file="$dir/$STATE_FILE_NAME"

  [[ -z "$dir" || -z "$from_gate" ]] && {
    echo "ERROR: state_reset_from: dir/from_gate required" >&2; return 2;
  }
  [[ ! -f "$file" ]] && { echo "ERROR: state_reset_from: state file not found: $file" >&2; return 1; }

  # 从 "gate-N" 解析出整数 N，校验非空且全数字
  local gate_num="${from_gate#gate-}"
  [[ "$gate_num" =~ ^[0-9]+$ ]] || {
    echo "ERROR: state_reset_from: from_gate must be gate-N form, got: $from_gate" >&2; return 2;
  }

  local tmp
  tmp=$(mktemp)
  # trap RETURN 仅 bash 支持；zsh 用别的语法且会对裸 RETURN 报警告
  if [[ -n "${BASH_VERSION:-}" ]]; then
    trap 'rm -f "$tmp"' RETURN
  fi

  jq --argjson n "$gate_num" --arg g "$from_gate" '
    .gates = (
      .gates
      | to_entries
      | map(
          if (.key | sub("gate-"; "") | tonumber) >= $n then
            .value = (
              {status: "pending"}
              + (if (.value.artifacts // null) != null
                 then {previous_artifacts: .value.artifacts}
                 else {} end)
            )
          else . end
        )
      | from_entries
    )
    | .current_gate = $g
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# 读 config.<key>
state_get_config() {
  local dir="$1" key="$2"
  local file="$dir/$STATE_FILE_NAME"
  [[ ! -f "$file" ]] && { echo "ERROR: state_get_config: state file not found: $file" >&2; return 1; }
  jq -r --arg k "$key" '.config[$k] // empty' "$file"
}
