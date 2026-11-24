#!/usr/bin/env bash
# Usage: dispatch-receivers.sh REPO...  (payload from REGISTRY, TARGET, IMAGE_VERSION, REF; writes since= to GITHUB_OUTPUT)
set -euo pipefail

OWNER="${OWNER:-wirenboard}"

since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for repo in "$@"; do
  jq -n --arg registry "$REGISTRY" --arg target "$TARGET" --arg version "$IMAGE_VERSION" --arg ref "$REF" \
    '{event_type: "build-on-premise",
      client_payload: {REGISTRY: $registry, TARGET: $target, IMAGE_VERSION: $version, GROUP: "on-premise", REF: $ref}}' |
    gh api --method POST "repos/$OWNER/$repo/dispatches" --input -
  echo "Dispatched build-on-premise to $OWNER/$repo"
done
echo "since=$since" >> "${GITHUB_OUTPUT:-/dev/stdout}"
