#!/usr/bin/env bash
#
# Publishes the built place over the live game via Open Cloud.
#
#   ./scripts/publish.sh            # build, then push to the published place
#
# Needs .deploy_key in the repo root: an Open Cloud API key with the
# universe-places WRITE scope for the experience. The key never goes on the
# command line, so it never lands in shell history or the process list.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSE=10764684362        # Mow Money, Mow Problems!
PLACE=71269136447904
KEY_FILE=.deploy_key

if [ ! -f "$KEY_FILE" ]; then
  echo "no $KEY_FILE — create an Open Cloud key (universe-places: write) and save it there" >&2
  exit 1
fi

export PATH="$HOME/.rokit/bin:$PATH"
rojo build default.project.json -o build/MowAllTheLawns.rbxl

RESPONSE=$(curl -sS -X POST \
  "https://apis.roblox.com/universes/v1/${UNIVERSE}/places/${PLACE}/versions?versionType=Published" \
  -H "x-api-key: $(cat "$KEY_FILE")" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @build/MowAllTheLawns.rbxl)

echo "$RESPONSE"
echo "$RESPONSE" | grep -q versionNumber && echo "PUBLISHED — the live game is now this build" \
  || { echo "PUBLISH FAILED" >&2; exit 1; }
