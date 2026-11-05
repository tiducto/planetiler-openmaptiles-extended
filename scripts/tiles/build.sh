#!/usr/bin/env bash
#
# Builds the tile set as plain {z}/{x}/{y}.pbf files into WORK_DIR/tiles.
#
# Usage: scripts/tiles/build.sh WORK_DIR
#
# Environment:
#   AREAS     Geofabrik extracts to merge (default: Czechia, Austria, Slovakia)
#   BOUNDS    tile bounds as min lon,min lat,max lon,max lat (default: the box around those three)
#   JAVA_XMX  Planetiler heap (default: 8g)
#   SKIP_OSM_DOWNLOAD=1 reuses WORK_DIR/osm/*.osm.pbf instead of downloading them again
#
# Water polygons come from osmdata.openstreetmap.de, or from the FAU mirror's newest copy when that is down.
#
# Needs: java, curl, osmium (only when merging several extracts), and the jar from ./mvnw -DskipTests package.

set -euo pipefail

WORK_DIR="${1:?usage: $0 WORK_DIR}"
AREAS="${AREAS:-europe/czech-republic europe/austria europe/slovakia}"
BOUNDS="${BOUNDS:-9.4,46.3,22.6,51.1}"
JAVA_XMX="${JAVA_XMX:-8g}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JAR="$(ls "$ROOT"/target/planetiler-openmaptiles-*-with-deps.jar 2>/dev/null | head -1 || true)"
[ -n "$JAR" ] || { echo "No Planetiler jar in $ROOT/target; run ./mvnw -DskipTests package first." >&2; exit 1; }

mkdir -p "$WORK_DIR/osm" "$WORK_DIR/sources"

WATER="$WORK_DIR/sources/water-polygons-split-3857.zip"
WATER_URL="https://osmdata.openstreetmap.de/download/water-polygons-split-3857.zip"
WATER_MIRROR="https://ftp.fau.de/mirrors/openstreetmapdata.com-archive"
fetch_water() {
  if curl -fsSL --connect-timeout 20 --retry 2 -o "$WATER.part" "$WATER_URL"; then
    mv "$WATER.part" "$WATER"
    echo "Water polygons from osmdata.openstreetmap.de"
    return
  fi
  echo "osmdata.openstreetmap.de is unreachable, trying the FAU mirror"
  local days
  days="$(curl -fsSL --retry 3 "$WATER_MIRROR/" | grep -oE 'href="[0-9]{4}-[0-9]{2}-[0-9]{2}/"' | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -r | sed -n '1,10p')"
  for day in $days; do
    if curl -fsSL --retry 3 -o "$WATER.part" "$WATER_MIRROR/$day/water-polygons-split-3857.zip"; then
      mv "$WATER.part" "$WATER"
      echo "Water polygons from the FAU mirror, $day"
      return
    fi
  done
  echo "No water polygons from osmdata.openstreetmap.de or the FAU mirror" >&2
  exit 1
}
[ -s "$WATER" ] || fetch_water

if [ "${SKIP_OSM_DOWNLOAD:-0}" != "1" ]; then
  rm -f "$WORK_DIR"/osm/*.osm.pbf
  for area in $AREAS; do
    echo "Downloading $area"
    curl -fsSL --retry 3 -o "$WORK_DIR/osm/${area##*/}.osm.pbf" "https://download.geofabrik.de/$area-latest.osm.pbf"
  done
fi

extracts=("$WORK_DIR"/osm/*.osm.pbf)
if [ "${#extracts[@]}" -gt 1 ]; then
  echo "Merging ${#extracts[@]} extracts"
  osmium merge --overwrite --output "$WORK_DIR/region.osm.pbf" "${extracts[@]}"
else
  cp "${extracts[0]}" "$WORK_DIR/region.osm.pbf"
fi

rm -rf "$WORK_DIR/tiles"
java "-Xmx$JAVA_XMX" -jar "$JAR" \
  --osm_path="$WORK_DIR/region.osm.pbf" \
  --bounds="$BOUNDS" \
  --download \
  --download_dir="$WORK_DIR/sources" \
  --tmpdir="$WORK_DIR/tmp" \
  --output="$WORK_DIR/tiles" \
  --force

echo "Built $(find "$WORK_DIR/tiles" -name '*.pbf' | wc -l | tr -d ' ') tiles, $(du -sh "$WORK_DIR/tiles" | cut -f1)"
