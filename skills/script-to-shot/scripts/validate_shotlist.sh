#!/usr/bin/env bash
# validate_shotlist.sh — 校验镜头表.json 符合 schema

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <镜头表.json>" >&2
  exit 2
fi

JSON_PATH="$1"

if [[ ! -f "$JSON_PATH" ]]; then
  echo "ERROR: file not found: $JSON_PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required (install: brew install jq)" >&2
  exit 1
fi

# 必填顶层字段
EPISODE=$(jq -r '.episode // empty' "$JSON_PATH")
[[ -z "$EPISODE" ]] && { echo "ERROR: missing .episode" >&2; exit 1; }

SHOTS_LEN=$(jq -r '.shots | length' "$JSON_PATH")
[[ "$SHOTS_LEN" == "0" || "$SHOTS_LEN" == "null" ]] && { echo "ERROR: .shots is empty" >&2; exit 1; }

# 每条 shot 的必填字段
REQUIRED_FIELDS=(id scene framing camera duration description_cn description_en characters location time_of_day lighting mood)
VALID_FRAMING="ELS LS MS MCU CU ECU"
VALID_CAMERA="static pan tilt push pull track handheld orbit"
VALID_TIME_OF_DAY="晨 上午 午 下午 黄昏 夜 深夜"

ERRORS=0
TOTAL_DURATION=0

for ((i=0; i<SHOTS_LEN; i++)); do
  SHOT=$(jq -c ".shots[$i]" "$JSON_PATH")
  SHOT_ID=$(echo "$SHOT" | jq -r '.id // "?"')

  for FIELD in "${REQUIRED_FIELDS[@]}"; do
    VAL=$(echo "$SHOT" | jq -r ".\"$FIELD\" // empty")
    if [[ -z "$VAL" ]] && [[ "$FIELD" != "dialogue" ]] && [[ "$FIELD" != "os" ]]; then
      echo "ERROR: shot $SHOT_ID missing required field .$FIELD" >&2
      ERRORS=$((ERRORS + 1))
    fi
  done

  FRAMING=$(echo "$SHOT" | jq -r '.framing')
  if ! grep -qw "$FRAMING" <<< "$VALID_FRAMING"; then
    echo "ERROR: shot $SHOT_ID framing='$FRAMING' not in {$VALID_FRAMING}" >&2
    ERRORS=$((ERRORS + 1))
  fi

  CAMERA=$(echo "$SHOT" | jq -r '.camera')
  if ! grep -qw "$CAMERA" <<< "$VALID_CAMERA"; then
    echo "ERROR: shot $SHOT_ID camera='$CAMERA' not in {$VALID_CAMERA}" >&2
    ERRORS=$((ERRORS + 1))
  fi

  TIME_OF_DAY=$(echo "$SHOT" | jq -r '.time_of_day')
  if ! grep -qw "$TIME_OF_DAY" <<< "$VALID_TIME_OF_DAY"; then
    echo "ERROR: shot $SHOT_ID time_of_day='$TIME_OF_DAY' not in {$VALID_TIME_OF_DAY}" >&2
    ERRORS=$((ERRORS + 1))
  fi

  DURATION=$(echo "$SHOT" | jq -r '.duration')
  TOTAL_DURATION=$(awk "BEGIN {print $TOTAL_DURATION + $DURATION}")
done

# 镜号唯一性
UNIQUE_IDS=$(jq -r '.shots[].id' "$JSON_PATH" | sort -u | wc -l | tr -d ' ')
if [[ "$UNIQUE_IDS" != "$SHOTS_LEN" ]]; then
  echo "ERROR: duplicate shot ids" >&2
  ERRORS=$((ERRORS + 1))
fi

# 输出汇总
echo "---"
echo "Episode: $EPISODE"
echo "Shots: $SHOTS_LEN"
echo "Total duration: ${TOTAL_DURATION}s"
echo "Errors: $ERRORS"

[[ $ERRORS -gt 0 ]] && exit 1
exit 0
