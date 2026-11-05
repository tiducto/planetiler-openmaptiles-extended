#!/usr/bin/env bash
#
# Uploads WORK_DIR/tiles to R2 under v/VERSION/, then points openmaptiles.json (the TileJSON clients load) at it
# and deletes all but the newest KEEP_VERSIONS versions. Tiles never change under a version, so they are cached
# for a year; the TileJSON is cached for five minutes, so clients move to a new build within minutes of its upload.
#
# Usage: scripts/tiles/publish.sh WORK_DIR
#
# Environment:
#   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET  where to upload
#   TILES_URL      public base URL of the bucket, e.g. https://tiles.tiducto.eu
#   VERSION        version folder (default: UTC time of the upload, e.g. 20261109T0323Z)
#   KEEP_VERSIONS  versions to keep, the new one included (default: 2)
#
# Needs: rclone, jq.

set -euo pipefail

WORK_DIR="${1:?usage: $0 WORK_DIR}"
: "${R2_ACCOUNT_ID:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}" "${R2_BUCKET:?}" "${TILES_URL:?}"
VERSION="${VERSION:-$(date -u +%Y%m%dT%H%MZ)}"
KEEP_VERSIONS="${KEEP_VERSIONS:-2}"
TILES_DIR="$WORK_DIR/tiles"
[ -f "$TILES_DIR/metadata.json" ] || { echo "No $TILES_DIR/metadata.json; run scripts/tiles/build.sh first." >&2; exit 1; }

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

echo "Uploading tiles to $R2_BUCKET/v/$VERSION"
rclone copy "$TILES_DIR" "r2:$R2_BUCKET/v/$VERSION" \
  --include '*.pbf' \
  --transfers 64 --checkers 64 \
  --header-upload 'Content-Type: application/x-protobuf' \
  --header-upload 'Content-Encoding: gzip' \
  --header-upload 'Cache-Control: public, max-age=31536000, immutable' \
  --stats 30s --stats-one-line --stats-log-level NOTICE

TILEJSON="$WORK_DIR/openmaptiles.json"
jq --arg tiles "${TILES_URL%/}/v/$VERSION/{z}/{x}/{y}.pbf" --arg version "$VERSION" '
  def numbers: if type == "string" then split(",") | map(tonumber) else . end;
  def layers: if type == "string" then fromjson else . end | .vector_layers;
  {
    tilejson: "3.0.0",
    name: .name,
    description: .description,
    attribution: .attribution,
    version: $version,
    scheme: "xyz",
    tiles: [$tiles],
    minzoom: (.minzoom | tonumber),
    maxzoom: (.maxzoom | tonumber),
    bounds: (.bounds | numbers),
    center: (.center | numbers),
    vector_layers: (.vector_layers // (.json | layers))
  }' "$TILES_DIR/metadata.json" > "$TILEJSON"

rclone copyto "$TILEJSON" "r2:$R2_BUCKET/v/$VERSION/openmaptiles.json" \
  --header-upload 'Content-Type: application/json' \
  --header-upload 'Cache-Control: public, max-age=31536000, immutable'
rclone copyto "$TILEJSON" "r2:$R2_BUCKET/openmaptiles.json" \
  --header-upload 'Content-Type: application/json' \
  --header-upload 'Cache-Control: public, max-age=300'
echo "Published ${TILES_URL%/}/openmaptiles.json -> version $VERSION"

rclone lsf --dirs-only "r2:$R2_BUCKET/v/" | sed 's#/$##' | sort -r | tail -n "+$((KEEP_VERSIONS + 1))" |
  while read -r old; do
    echo "Deleting old version $old"
    rclone purge "r2:$R2_BUCKET/v/$old"
  done
