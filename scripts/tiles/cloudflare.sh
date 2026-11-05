#!/usr/bin/env bash
#
# Makes sure the Cloudflare side of the tile hosting exists, then prints the settings publish.sh needs. Safe to
# run on every build: it only creates or updates what is missing or different.
#   - R2 bucket R2_BUCKET (EU location hint) with a read-only CORS policy, so web viewers can load tiles too
#   - custom domain TILES_HOST on that bucket, so tiles go through Cloudflare's cache (r2.dev is rate limited)
#   - cache rule for TILES_HOST: cache everything, honouring the Cache-Control headers set at upload, and keep
#     "not found" answers for a day, so a missing tile reaches R2 at most once a day
#   - firewall rule for TILES_HOST: block everything but a GET of the TileJSON or a tile without a query string, so
#     requests made up to get past the cache never reach R2 (HEAD and OPTIONS skip the cache, MapLibre sends neither)
#   - with --tiered-cache, Smart Tiered Cache on the zone
#
# Usage: settings="$(scripts/tiles/cloudflare.sh [--tiered-cache])"
#
# Needs curl, jq and CLOUDFLARE_API_TOKEN, an account API token (or a user API token) with:
#   Account: Workers R2 Storage Edit; Zone (ZONE_NAME): Zone Read, Cache Settings Edit, Zone Settings Edit, DNS Edit,
#   WAF Edit
# The same token is the R2 upload key: its id is the access key ID and the SHA-256 of its value the secret.
#
# Prints R2_ACCOUNT_ID, R2_BUCKET, TILES_URL, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY as NAME=value lines on
# stdout; everything else goes to stderr. The caller must mask R2_SECRET_ACCESS_KEY before logging it.
#
# Override with env vars: ZONE_NAME, TILES_HOST, R2_BUCKET.

set -euo pipefail

ZONE_NAME="${ZONE_NAME:-tiducto.eu}"
TILES_HOST="${TILES_HOST:-tiles.$ZONE_NAME}"
R2_BUCKET="${R2_BUCKET:-tiducto-tiles}"
CACHE_RULE_REF="tiles_cache_everything"
FIREWALL_RULE_REF="tiles_allow_only_tiles"
API="https://api.cloudflare.com/client/v4"
: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"

TIERED=0
for arg in "$@"; do
  case "$arg" in
    --tiered-cache) TIERED=1 ;;
    *) echo "ERROR: unknown argument $arg" >&2; exit 1 ;;
  esac
done

log() { echo "$*" >&2; }
fail() { echo "ERROR: $*" >&2; exit 1; }

cf() {
  local args=(-sS -X "$1" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")
  [ $# -ge 3 ] && args+=(--data "$3")
  local body
  body="$(curl "${args[@]}" "$API$2")"
  printf '%s' "$body"
  [ "$(printf '%s' "$body" | jq -r '.success // false')" = "true" ]
}

errors() { jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")'; }

upsert_rule() {
  local phase="$1" ref="$2" rule="$3" what="$4" permission="$5" entrypoint ruleset_id rule_id out
  entrypoint="$(cf GET "/zones/$ZONE_ID/rulesets/phases/$phase/entrypoint" || true)"
  ruleset_id="$(jq -r '.result.id // empty' <<<"$entrypoint")"
  rule_id="$(jq -r --arg ref "$ref" '.result.rules[]? | select(.ref == $ref) | .id' <<<"$entrypoint")"
  if [ -z "$ruleset_id" ]; then
    out="$(cf PUT "/zones/$ZONE_ID/rulesets/phases/$phase/entrypoint" \
      "$(jq -n --argjson rule "$rule" '{rules: [$rule]}')")" || fail "can't create the $what (needs $permission): $(errors <<<"$out")"
    log "$what: created"
  elif [ -n "$rule_id" ]; then
    out="$(cf PATCH "/zones/$ZONE_ID/rulesets/$ruleset_id/rules/$rule_id" "$rule")" ||
      fail "can't update the $what (needs $permission): $(errors <<<"$out")"
    log "$what: up to date"
  else
    out="$(cf POST "/zones/$ZONE_ID/rulesets/$ruleset_id/rules" "$rule")" ||
      fail "can't add the $what (needs $permission): $(errors <<<"$out")"
    log "$what: added"
  fi
}

ZONE="$(cf GET "/zones?name=$ZONE_NAME")" || fail "can't read zone $ZONE_NAME (needs Zone Read): $(errors <<<"$ZONE")"
ZONE_ID="$(jq -r '.result[0].id // empty' <<<"$ZONE")"
ACCOUNT_ID="$(jq -r '.result[0].account.id // empty' <<<"$ZONE")"
[ -n "$ZONE_ID" ] || fail "zone $ZONE_NAME not found for this token (needs Zone Read on it)"

if ! TOKEN="$(cf GET /user/tokens/verify)"; then
  TOKEN="$(cf GET "/accounts/$ACCOUNT_ID/tokens/verify")" || fail "the token doesn't verify: $(errors <<<"$TOKEN")"
fi
TOKEN_ID="$(jq -r '.result.id' <<<"$TOKEN")"

BUCKETS="$(cf GET "/accounts/$ACCOUNT_ID/r2/buckets?name_contains=$R2_BUCKET&per_page=1000")" ||
  fail "can't list R2 buckets (needs Workers R2 Storage Edit): $(errors <<<"$BUCKETS")"
if jq -e --arg bucket "$R2_BUCKET" '.result.buckets[]? | select(.name == $bucket)' <<<"$BUCKETS" >/dev/null; then
  log "bucket $R2_BUCKET: exists"
else
  out="$(cf POST "/accounts/$ACCOUNT_ID/r2/buckets" "$(jq -n --arg name "$R2_BUCKET" '{name: $name, locationHint: "eeur"}')")" ||
    fail "can't create bucket $R2_BUCKET: $(errors <<<"$out")"
  log "bucket $R2_BUCKET: created"
fi

out="$(cf PUT "/accounts/$ACCOUNT_ID/r2/buckets/$R2_BUCKET/cors" \
  '{"rules":[{"allowed":{"methods":["GET","HEAD"],"origins":["*"]},"maxAgeSeconds":86400}]}')" ||
  fail "can't set the CORS policy: $(errors <<<"$out")"

DOMAINS="$(cf GET "/accounts/$ACCOUNT_ID/r2/buckets/$R2_BUCKET/domains/custom")" ||
  fail "can't read the bucket's custom domains: $(errors <<<"$DOMAINS")"
if jq -e --arg host "$TILES_HOST" '.result.domains[]? | select(.domain == $host)' <<<"$DOMAINS" >/dev/null; then
  log "custom domain $TILES_HOST: $(jq -c --arg host "$TILES_HOST" '.result.domains[] | select(.domain == $host) | .status' <<<"$DOMAINS")"
else
  out="$(cf POST "/accounts/$ACCOUNT_ID/r2/buckets/$R2_BUCKET/domains/custom" \
    "$(jq -n --arg domain "$TILES_HOST" --arg zone "$ZONE_ID" '{domain: $domain, zoneId: $zone, enabled: true, minTLS: "1.2"}')")" ||
    fail "can't attach $TILES_HOST (needs DNS Edit): $(errors <<<"$out")"
  log "custom domain $TILES_HOST: attached"
fi

CACHE_RULE="$(jq -n --arg host "$TILES_HOST" --arg ref "$CACHE_RULE_REF" '{
  ref: $ref,
  description: "Cache map tiles and TileJSON, honouring their Cache-Control headers; keep misses for a day",
  expression: "(http.host eq \"\($host)\")",
  action: "set_cache_settings",
  action_parameters: {
    cache: true,
    edge_ttl: {mode: "respect_origin", status_code_ttl: [{status_code: 404, value: 86400}]},
    browser_ttl: {mode: "respect_origin"}
  },
  enabled: true
}')"
upsert_rule http_request_cache_settings "$CACHE_RULE_REF" "$CACHE_RULE" "cache rule" "Cache Settings Edit"

FIREWALL_RULE="$(jq -n --arg host "$TILES_HOST" --arg ref "$FIREWALL_RULE_REF" '{
  ref: $ref,
  description: "Only the TileJSON and tiles, so made-up requests never reach R2",
  expression: ("(http.host eq \"\($host)\" and (http.request.method ne \"GET\""
    + " or http.request.uri.query ne \"\""
    + " or not (http.request.uri.path eq \"/openmaptiles.json\""
    + " or http.request.uri.path wildcard \"/v/*/openmaptiles.json\""
    + " or http.request.uri.path wildcard \"/v/*/*/*/*.pbf\")))"),
  action: "block",
  enabled: true
}')"
upsert_rule http_request_firewall_custom "$FIREWALL_RULE_REF" "$FIREWALL_RULE" "firewall rule" "WAF Edit"

if [ "$TIERED" = 1 ]; then
  out="$(cf PATCH "/zones/$ZONE_ID/cache/tiered_cache_smart_topology_enable" '{"value":"on"}')" ||
    fail "can't turn on Smart Tiered Cache (needs Zone Settings Edit): $(errors <<<"$out")"
  log "Smart Tiered Cache: on"
fi

if command -v sha256sum >/dev/null; then
  SECRET="$(printf '%s' "$CLOUDFLARE_API_TOKEN" | sha256sum | cut -d' ' -f1)"
else
  SECRET="$(printf '%s' "$CLOUDFLARE_API_TOKEN" | shasum -a 256 | cut -d' ' -f1)"
fi
echo "R2_ACCOUNT_ID=$ACCOUNT_ID"
echo "R2_BUCKET=$R2_BUCKET"
echo "TILES_URL=https://$TILES_HOST"
echo "R2_ACCESS_KEY_ID=$TOKEN_ID"
echo "R2_SECRET_ACCESS_KEY=$SECRET"
