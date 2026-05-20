#!/usr/bin/env bash
# adapters/sora.sh — Sora 2（占位，API 对个人开发者尚未稳定开放）

cat <<'EOF' >&2
ERROR: sora adapter is a placeholder.

Sora 2 API is currently enterprise-only as of 2026. When OpenAI opens
the API to individuals, fill in this adapter following the same pattern
as adapters/kling.sh:

1. Submit task: POST $SORA_BASE_URL/v1/videos/generations
   with image (base64) + prompt + duration
2. Poll task: GET $SORA_BASE_URL/v1/videos/generations/$TASK_ID
3. Download result + write $SHOT_ID.mp4 + $SHOT_ID.json

Env vars expected: SORA_API_KEY, SORA_BASE_URL
EOF
exit 1
