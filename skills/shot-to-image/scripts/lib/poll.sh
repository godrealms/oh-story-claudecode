#!/usr/bin/env bash
# lib/poll.sh — 异步任务轮询的统一封装

# 用法:
#   poll_task --check-url URL --auth-header H --status-jq EXPR \
#             --done-values "v1,v2" --fail-values "v3,v4" \
#             --result-jq EXPR --interval N --timeout N
poll_task() {
  local check_url="" auth_header="" status_jq="" done_values=""
  local fail_values="" result_jq="" interval=5 timeout=300

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check-url) check_url="$2"; shift 2 ;;
      --auth-header) auth_header="$2"; shift 2 ;;
      --status-jq) status_jq="$2"; shift 2 ;;
      --done-values) done_values="$2"; shift 2 ;;
      --fail-values) fail_values="$2"; shift 2 ;;
      --result-jq) result_jq="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      *) echo "ERROR: unknown arg $1" >&2; return 2 ;;
    esac
  done

  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local response status
    response=$(curl -s -H "$auth_header" "$check_url") || {
      echo "ERROR: poll request failed" >&2
      return 1
    }
    status=$(echo "$response" | jq -r "$status_jq")

    if [[ ",$done_values," == *",$status,"* ]]; then
      echo "$response" | jq -r "$result_jq"
      return 0
    fi
    if [[ ",$fail_values," == *",$status,"* ]]; then
      echo "ERROR: task failed (status=$status)" >&2
      echo "$response" >&2
      return 1
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "ERROR: task timeout after ${timeout}s" >&2
  return 1
}
