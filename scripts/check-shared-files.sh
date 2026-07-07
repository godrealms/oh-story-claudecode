#!/bin/bash
# check-shared-files.sh — 检查跨 skill 同名文件内容一致性
# 扫描所有 skill 的 references/ 目录，找出同名文件并比较内容
# 用法:
#   check-shared-files.sh          仅检查，发现漂移 exit 1
#   check-shared-files.sh --sync   检查并自动同步漂移副本
# 同步策略（选 canonical 版本）:
#   1. 恰好一个内容簇含未提交修改 → 该簇（"改一份推全组"工作流）
#   2. 全部已提交 → 多数版本
#   3. 多数平局 → 最新 git 提交时间
#   4. 仍无法决断 → 跳过，保留 MISMATCH 人工处理
# 兼容 bash 3+（macOS）
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "Error: not in a git repository"
  exit 1
fi

SKILLS_DIR="$REPO_ROOT/skills"
if [ ! -d "$SKILLS_DIR" ]; then
  echo "Error: skills/ not found at $SKILLS_DIR"
  exit 1
fi

SYNC_MODE=false
if [ "${1:-}" = "--sync" ]; then
  SYNC_MODE=true
fi

# Known intentional differences (basename): these files are expected to differ
# - output-templates.md / material-decomposition.md: long vs short 两套拆解方法论
# - format-and-structure.md: 短篇版含小节(beat)结构与适用范围说明
# - genre-writing-formulas.md: 「配合」引用指向各自 skill 内存在的文件
IGNORE_NAMES="output-templates.md material-decomposition.md format-and-structure.md genre-writing-formulas.md"

# Group sync: files exempted above but whose copies WITHIN a variant group must still match.
# Format: "basename:skillA=skillB" (each entry asserts skillA and skillB copies are identical)
GROUP_SYNC="genre-writing-formulas.md:story-short-analyze=story-short-write"

mismatches=0
checked=0
synced=0

file_hash() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -q "$1"
  else
    md5sum "$1" | cut -d' ' -f1
  fi
}

skill_of() {
  echo "$1" | sed "s|$SKILLS_DIR/||" | cut -d'/' -f1
}

# Sync a group of same-named files to a canonical version (see strategy above).
# Args: all paths in the group. Returns 1 when no canonical can be determined.
sync_group() {
  local paths=("$@")
  local hashes=()
  local p i k
  for p in "${paths[@]}"; do
    hashes+=("$(file_hash "$p")")
  done

  # Cluster by content: track count, max commit time, dirty flag per cluster
  local sums=() counts=() times=() dirtys=()
  for ((i = 0; i < ${#paths[@]}; i++)); do
    local mt dirty
    mt="$(git -C "$REPO_ROOT" log -1 --format=%ct -- "${paths[$i]}" 2>/dev/null)" || mt=""
    [ -z "$mt" ] && mt=0
    dirty=false
    git -C "$REPO_ROOT" diff --quiet HEAD -- "${paths[$i]}" 2>/dev/null || dirty=true
    local found=false
    for ((k = 0; k < ${#sums[@]}; k++)); do
      if [ "${sums[$k]}" = "${hashes[$i]}" ]; then
        counts[$k]=$((counts[$k] + 1))
        [ "$mt" -gt "${times[$k]}" ] && times[$k]="$mt"
        [ "$dirty" = true ] && dirtys[$k]=true
        found=true
        break
      fi
    done
    if [ "$found" = false ]; then
      sums+=("${hashes[$i]}")
      counts+=(1)
      times+=("$mt")
      dirtys+=("$dirty")
    fi
  done

  # Rule 1: exactly one cluster contains uncommitted changes → it is canonical
  local best=-1 dirty_clusters=0
  for ((k = 0; k < ${#sums[@]}; k++)); do
    if [ "${dirtys[$k]}" = true ]; then
      dirty_clusters=$((dirty_clusters + 1))
      best=$k
    fi
  done
  if [ "$dirty_clusters" -ne 1 ]; then
    # Rule 2+3: majority, tie broken by latest commit time
    best=0
    for ((k = 1; k < ${#sums[@]}; k++)); do
      if [ "${counts[$k]}" -gt "${counts[$best]}" ]; then
        best=$k
      elif [ "${counts[$k]}" -eq "${counts[$best]}" ] && [ "${times[$k]}" -gt "${times[$best]}" ]; then
        best=$k
      fi
    done
    # Rule 4: unresolved tie → give up
    for ((k = 0; k < ${#sums[@]}; k++)); do
      [ "$k" -eq "$best" ] && continue
      if [ "${counts[$k]}" -eq "${counts[$best]}" ] && [ "${times[$k]}" -eq "${times[$best]}" ]; then
        echo "  SYNC SKIPPED: cannot determine canonical version (tie), resolve manually"
        return 1
      fi
    done
  fi

  # Copy canonical version over the rest
  local src=""
  for ((i = 0; i < ${#paths[@]}; i++)); do
    if [ "${hashes[$i]}" = "${sums[$best]}" ]; then
      src="${paths[$i]}"
      break
    fi
  done
  local src_skill
  src_skill="$(skill_of "$src")"
  for ((i = 0; i < ${#paths[@]}; i++)); do
    if [ "${hashes[$i]}" != "${sums[$best]}" ]; then
      cp "$src" "${paths[$i]}"
      echo "  SYNCED: $src_skill -> $(skill_of "${paths[$i]}")"
    fi
  done
  return 0
}

echo "Shared File Consistency Check"
echo "=============================="

# Find all basenames that appear in 2+ skills
dup_names="$(find "$SKILLS_DIR" -type f -path '*/references/*' ! -name '.gitkeep' -exec basename {} \; 2>/dev/null | sort | uniq -d)"

for base in $dup_names; do
  # Skip known intentional differences
  skip=false
  for ignore in $IGNORE_NAMES; do
    if [ "$base" = "$ignore" ]; then
      skip=true
      break
    fi
  done
  if [ "$skip" = true ]; then
    continue
  fi
  # Collect all paths for this basename
  paths=()
  while IFS= read -r fpath; do
    [ -z "$fpath" ] && continue
    paths+=("$fpath")
  done < <(find "$SKILLS_DIR" -type f -path '*/references/*' -name "$base" 2>/dev/null)

  if [ ${#paths[@]} -lt 2 ]; then
    continue
  fi

  checked=$((checked + 1))
  ref_path="${paths[0]}"
  ref_skill="$(skill_of "$ref_path")"
  group_diffs=0

  for ((i = 1; i < ${#paths[@]}; i++)); do
    if ! diff -q "$ref_path" "${paths[$i]}" >/dev/null 2>&1; then
      if [ "$group_diffs" -eq 0 ]; then
        echo ""
        echo "MISMATCH: $base"
        echo "  Reference: $ref_skill"
      fi
      echo "  Differs in: $(skill_of "${paths[$i]}")"
      group_diffs=$((group_diffs + 1))
    fi
  done

  if [ "$group_diffs" -gt 0 ]; then
    if [ "$SYNC_MODE" = true ] && sync_group "${paths[@]}"; then
      synced=$((synced + group_diffs))
    else
      mismatches=$((mismatches + group_diffs))
    fi
  fi
done

# Group sync checks: exempted basenames whose in-group copies must match
for entry in $GROUP_SYNC; do
  base="${entry%%:*}"
  pair="${entry#*:}"
  skill_a="${pair%%=*}"
  skill_b="${pair#*=}"
  path_a="$SKILLS_DIR/$skill_a/references/$base"
  path_b="$SKILLS_DIR/$skill_b/references/$base"
  if [ ! -f "$path_a" ] || [ ! -f "$path_b" ]; then
    echo ""
    echo "MISMATCH: $base (group sync: missing file)"
    [ -f "$path_a" ] || echo "  Missing: $skill_a"
    [ -f "$path_b" ] || echo "  Missing: $skill_b"
    mismatches=$((mismatches + 1))
    continue
  fi
  checked=$((checked + 1))
  if ! diff -q "$path_a" "$path_b" >/dev/null 2>&1; then
    echo ""
    echo "MISMATCH: $base (group sync: $skill_a vs $skill_b must match)"
    echo "  Reference: $skill_a"
    echo "  Differs in: $skill_b"
    if [ "$SYNC_MODE" = true ] && sync_group "$path_a" "$path_b"; then
      synced=$((synced + 1))
    else
      mismatches=$((mismatches + 1))
    fi
  fi
done

echo ""
echo "=============================="
summary="Files checked (shared): $checked | Mismatches: $mismatches"
if [ "$SYNC_MODE" = true ]; then
  summary="$summary | Synced: $synced"
fi
echo "$summary"

if [ "$mismatches" -gt 0 ]; then
  echo ""
  echo "NOTE: Some mismatches may be intentional (skill-specific customizations)."
  if [ "$SYNC_MODE" = true ]; then
    echo "      Unresolved groups above need manual review."
  else
    echo "      Review each case before syncing, or run with --sync to auto-sync."
  fi
  exit 1
fi

echo "All shared files are consistent."
