#!/usr/bin/env bash
# lib/poll.sh — 异步任务轮询的统一封装
# Source me, don't exec me. Designed to work under set -euo pipefail in caller.

# 用法:
#   poll_task --check-url URL --status-jq EXPR \
#             --done-values "v1,v2" --fail-values "v3,v4" \
#             --result-jq EXPR \
#             [--auth-header H] [--interval N] [--timeout N]
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
      *) echo "ERROR: poll_task: unknown arg $1" >&2; return 2 ;;
    esac
  done

  # Validate required args
  [[ -z "$check_url" ]] && { echo "ERROR: poll_task: --check-url required" >&2; return 2; }
  [[ -z "$status_jq" ]] && { echo "ERROR: poll_task: --status-jq required" >&2; return 2; }
  [[ -z "$done_values" ]] && { echo "ERROR: poll_task: --done-values required" >&2; return 2; }
  [[ -z "$result_jq" ]] && { echo "ERROR: poll_task: --result-jq required" >&2; return 2; }

  # Validate interval/timeout are integers
  [[ "$interval" =~ ^[0-9]+$ ]] || { echo "ERROR: poll_task: --interval must be integer seconds" >&2; return 2; }
  [[ "$timeout" =~ ^[0-9]+$ ]] || { echo "ERROR: poll_task: --timeout must be integer seconds" >&2; return 2; }

  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local body_file http_code curl_args
    body_file=$(mktemp)

    # Build curl args: only add -H when auth_header is non-empty
    curl_args=(-sS --max-time 30 -o "$body_file" -w '%{http_code}')
    [[ -n "$auth_header" ]] && curl_args+=(-H "$auth_header")

    if ! http_code=$(curl "${curl_args[@]}" "$check_url" 2>&1); then
      echo "ERROR: poll_task: curl failed: $http_code" >&2
      rm -f "$body_file"
      return 1
    fi

    # Surface non-2xx as failure (don't keep polling on permanent errors)
    if [[ "$http_code" != 2* ]]; then
      echo "ERROR: poll_task: HTTP $http_code from $check_url" >&2
      cat "$body_file" >&2
      rm -f "$body_file"
      return 1
    fi

    local response status
    response=$(cat "$body_file")
    rm -f "$body_file"

    status=$(echo "$response" | jq -r "$status_jq" 2>/dev/null)

    if [[ ",$done_values," == *",$status,"* ]]; then
      echo "$response" | jq -r "$result_jq"
      return 0
    fi
    if [[ -n "$fail_values" ]] && [[ ",$fail_values," == *",$status,"* ]]; then
      echo "ERROR: poll_task: task failed (status=$status)" >&2
      echo "$response" >&2
      return 1
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "ERROR: poll_task: timeout after ${timeout}s" >&2
  return 1
}
