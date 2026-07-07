#!/bin/bash
# check-shared-files.sh — 检查跨 skill 同名文件内容一致性
# 扫描所有 skill 的 references/ 目录，找出同名文件并比较内容
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
  ref_skill="$(echo "$ref_path" | sed "s|$SKILLS_DIR/||" | cut -d'/' -f1)"
  all_match=true

  for ((i = 1; i < ${#paths[@]}; i++)); do
    if ! diff -q "$ref_path" "${paths[$i]}" >/dev/null 2>&1; then
      skill_name="$(echo "${paths[$i]}" | sed "s|$SKILLS_DIR/||" | cut -d'/' -f1)"
      if [ "$all_match" = true ]; then
        echo ""
        echo "MISMATCH: $base"
        echo "  Reference: $ref_skill"
      fi
      echo "  Differs in: $skill_name"
      all_match=false
      mismatches=$((mismatches + 1))
    fi
  done
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
    mismatches=$((mismatches + 1))
  fi
done

echo ""
echo "=============================="
echo "Files checked (shared): $checked | Mismatches: $mismatches"

if [ "$mismatches" -gt 0 ]; then
  echo ""
  echo "NOTE: Some mismatches may be intentional (skill-specific customizations)."
  echo "      Review each case before syncing."
  exit 1
fi

echo "All shared files are consistent."
