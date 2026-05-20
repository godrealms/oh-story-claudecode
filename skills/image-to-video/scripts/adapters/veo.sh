#!/usr/bin/env bash
# adapters/veo.sh — Google Veo（占位，按需实现）

cat <<'EOF' >&2
ERROR: veo adapter is a placeholder.

Google Veo is accessible via Google AI Studio / Vertex AI as of 2026,
but the API surface depends on which product tier you have access to.
Fill in this adapter following adapters/kling.sh pattern when ready:

1. Submit task: POST to Veo image-to-video endpoint
   (Vertex AI: aiplatform.googleapis.com/v1/projects/.../publishers/google/models/veo:predict
    AI Studio: generativelanguage.googleapis.com/v1beta/models/veo:generateVideo)
   with image (base64) + prompt + duration
2. Poll task or operation: GET .../operations/$OPERATION_ID
3. Download result + write $SHOT_ID.mp4 + $SHOT_ID.json

Env vars expected: VEO_API_KEY (and possibly VEO_PROJECT_ID, VEO_LOCATION
for Vertex AI tier).
EOF
exit 1
