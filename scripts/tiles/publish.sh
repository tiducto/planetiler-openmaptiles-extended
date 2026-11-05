#!/usr/bin/env bash
#
# Uploads WORK_DIR/tiles to R2 in one of two slots, v/a/ and v/b/: the one openmaptiles.json (the TileJSON clients
# load) doesn't point at. The slot still holds the build before the live one, so only tiles whose MD5 differs are
# uploaded, and tiles the new build no longer has are deleted. Then it purges the slot from Cloudflare's cache and
# points openmaptiles.json at it. Clients never see a half-updated slot, and the other slot keeps the previous build
# to roll back to. Folders from before the slots are deleted once openmaptiles.json no longer points at them.
#
# Cloudflare keeps tiles until the purge; clients recheck them after an hour, and the TileJSON after five minutes,
# so they move to a new build within minutes of its upload.
#
# Usage: scripts/tiles/publish.sh WORK_DIR
#
# Environment:
#   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET  where to upload
#   TILES_URL                                 public base URL of the bucket, e.g. https://tiles.tiducto.eu
#   CLOUDFLARE_API_TOKEN, CLOUDFLARE_ZONE_ID  to purge the slot from the cache (the token needs Cache Purge)
#   VERSION         build name in the TileJSON (default: UTC time of the upload, e.g. 20261109T0323Z)
#   R2_ENDPOINT     S3 endpoint (default: the account's R2 endpoint)
#   CLOUDFLARE_API  Cloudflare API base URL (default: https://api.cloudflare.com/client/v4)
#
# Needs: curl, jq and a current rclone (1.72 tested). Ubuntu 24.04's rclone 1.60 adds x-amz-acl to every upload,
# which R2 answers with 501 Not Implemented.

set -euo pipefail

WORK_DIR="${1:?usage: $0 WORK_DIR}"
: "${R2_ACCOUNT_ID:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}" "${R2_BUCKET:?}" "${TILES_URL:?}"
: "${CLOUDFLARE_API_TOKEN:?}" "${CLOUDFLARE_ZONE_ID:?}"
VERSION="${VERSION:-$(date -u +%Y%m%dT%H%MZ)}"
CLOUDFLARE_API="${CLOUDFLARE_API:-https://api.cloudflare.com/client/v4}"
TILES_DIR="$WORK_DIR/tiles"
TILES_HOST="${TILES_URL#*://}"
TILES_HOST="${TILES_HOST%%/*}"
[ -f "$TILES_DIR/metadata.json" ] || { echo "No $TILES_DIR/metadata.json; run scripts/tiles/build.sh first." >&2; exit 1; }

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT:-https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com}"
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

TILE_HEADERS=(
  --header-upload 'Content-Type: application/x-protobuf'
  --header-upload 'Content-Encoding: gzip'
  --header-upload 'Cache-Control: public, max-age=3600'
)
TILEJSON_HEADERS=(
  --header-upload 'Content-Type: application/json'
  --header-upload 'Cache-Control: public, max-age=300'
)

LIVE=""
if [ -n "$(rclone lsf --files-only --include /openmaptiles.json "r2:$R2_BUCKET/")" ]; then
  LIVE="$(rclone cat "r2:$R2_BUCKET/openmaptiles.json" | jq -r '.tiles[0] // ""' |
    sed -n 's#^.*/v/\([^/]*\)/{z}/{x}/{y}\.pbf$#\1#p')"
fi
case "$LIVE" in
  a) SLOT=b ;;
  *) SLOT=a ;;
esac
echo "Live: ${LIVE:-nothing}; updating slot $SLOT"

FIRST_TILE="$(cd "$TILES_DIR" && find . -name '*.pbf' -print -quit)"
FIRST_TILE="${FIRST_TILE#./}"
echo "Uploading $FIRST_TILE first"
rclone copyto "$TILES_DIR/$FIRST_TILE" "r2:$R2_BUCKET/v/$SLOT/$FIRST_TILE" "${TILE_HEADERS[@]}" --checksum --retries 1

echo "Syncing tiles to $R2_BUCKET/v/$SLOT"
rclone sync "$TILES_DIR" "r2:$R2_BUCKET/v/$SLOT" \
  --include '*.pbf' \
  --checksum --fast-list \
  --transfers 64 --checkers 64 \
  "${TILE_HEADERS[@]}" \
  --combined "$WORK_DIR/sync.txt" \
  --stats 30s --stats-one-line --stats-log-level NOTICE
same="$(grep -c '^= ' "$WORK_DIR/sync.txt" || true)"
changed="$(grep -c '^\* ' "$WORK_DIR/sync.txt" || true)"
added="$(grep -c '^+ ' "$WORK_DIR/sync.txt" || true)"
deleted="$(grep -c '^- ' "$WORK_DIR/sync.txt" || true)"
echo "Uploaded $((changed + added)) of $((same + changed + added)) tiles ($changed changed, $added new), deleted $deleted"

echo "Purging $TILES_HOST/v/$SLOT from Cloudflare's cache"
purge="$(curl -sS -X POST "$CLOUDFLARE_API/zones/$CLOUDFLARE_ZONE_ID/purge_cache" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' \
  --data "$(jq -n --arg prefix "$TILES_HOST/v/$SLOT" '{prefixes: [$prefix]}')")"
if ! jq -e '.success == true' <<<"$purge" >/dev/null 2>&1; then
  echo "ERROR: can't purge $TILES_HOST/v/$SLOT (the token needs Zone Cache Purge): $purge" >&2
  exit 1
fi

TILEJSON="$WORK_DIR/openmaptiles.json"
jq --arg tiles "${TILES_URL%/}/v/$SLOT/{z}/{x}/{y}.pbf" --arg version "$VERSION" '
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

rclone copyto "$TILEJSON" "r2:$R2_BUCKET/v/$SLOT/openmaptiles.json" "${TILEJSON_HEADERS[@]}"
rclone copyto "$TILEJSON" "r2:$R2_BUCKET/openmaptiles.json" "${TILEJSON_HEADERS[@]}"
echo "Published ${TILES_URL%/}/openmaptiles.json -> slot $SLOT, version $VERSION"

rclone lsf --dirs-only "r2:$R2_BUCKET/v/" | sed 's#/$##' | while read -r dir; do
  case "$dir" in
    "$SLOT" | "$LIVE") continue ;;
  esac
  echo "Deleting $dir"
  rclone purge "r2:$R2_BUCKET/v/$dir"
done
