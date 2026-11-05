#!/usr/bin/env bash
#
# One-time setup for hosting the tiles on Cloudflare R2, and for the Tiles workflow that publishes them.
#
# It lists what is missing, asks before changing anything, and is safe to run again:
#   - R2 bucket R2_BUCKET (EU location hint) with a read-only CORS policy, so web viewers can load tiles too
#   - custom domain TILES_HOST on that bucket, so tiles go through Cloudflare's cache (r2.dev is rate limited)
#   - cache rule for TILES_HOST: cache everything, honouring the Cache-Control headers set at upload
#   - Smart Tiered Cache on the zone (asked separately: it applies to the whole zone)
#   - GitHub Actions enabled on REPO, upstream's publishing workflows disabled there, and the variables
#     R2_ACCOUNT_ID, R2_BUCKET, TILES_URL and the secrets R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY set on REPO
#
# The R2 access key for the workflow is created by hand (the script tells you where) and read from a hidden
# prompt; it is never written to disk.
#
# Usage: setup-cloudflare.sh [--yes] [--tiered-cache]
#   --yes           apply without asking, so it also runs without a terminal (e.g. Claude Code's ! commands);
#                   the R2 key is then not prompted for, and the script says where to add it on GitHub instead
#   --tiered-cache  with --yes, also turn on Smart Tiered Cache for the zone
#
# Needs curl, jq and gh (logged in with admin rights on REPO), and a Cloudflare API token with:
#   Account: Workers R2 Storage Edit; Zone: Zone Read, Cache Rules Edit, Zone Settings Edit, DNS Edit
# taken from CLOUDFLARE_API_TOKEN or, when unset, from the Secret Manager secret CLOUDFLARE_TOKEN_SECRET
# (default `cloudflare-api-token`) in GCP_PROJECT_ID via gcloud.
#
# Override with env vars: ZONE_NAME, TILES_HOST, R2_BUCKET, REPO, GCP_PROJECT_ID, CLOUDFLARE_TOKEN_SECRET.

set -euo pipefail

ZONE_NAME="${ZONE_NAME:-tiducto.eu}"
TILES_HOST="${TILES_HOST:-tiles.$ZONE_NAME}"
R2_BUCKET="${R2_BUCKET:-tiducto-tiles}"
REPO="${REPO:-tiducto/planetiler-openmaptiles-extended}"
PROJECT="${GCP_PROJECT_ID:-tiducto-spider}"
TOKEN_SECRET="${CLOUDFLARE_TOKEN_SECRET:-cloudflare-api-token}"
RULE_REF="tiles_cache_everything"
API="https://api.cloudflare.com/client/v4"

YES=0
TIERED=0
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    --tiered-cache) TIERED=1 ;;
    *) echo "ERROR: unknown argument $arg (use --yes, --tiered-cache)" >&2; exit 1 ;;
  esac
done
INTERACTIVE=0
[ -t 0 ] && INTERACTIVE=1
if [ "$INTERACTIVE" = 0 ] && [ "$YES" = 0 ]; then
  echo "ERROR: no terminal to ask in. Run it in a terminal, or pass --yes (plus --tiered-cache to turn that on too)." >&2
  exit 1
fi

for tool in curl jq gh; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not found on PATH." >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not logged in (gh auth login)." >&2; exit 1; }
gh repo view "$REPO" >/dev/null 2>&1 || { echo "ERROR: can't see $REPO with gh. Create the fork first." >&2; exit 1; }

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  command -v gcloud >/dev/null || { echo "ERROR: set CLOUDFLARE_API_TOKEN (gcloud not found to read it)." >&2; exit 1; }
  CLOUDFLARE_API_TOKEN="$(gcloud secrets versions access latest --secret="$TOKEN_SECRET" --project "$PROJECT")"
fi

# cf METHOD PATH [JSON]: prints the response body, returns non-zero unless Cloudflare reports success.
cf() {
  local args=(-sS -X "$1" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")
  [ $# -ge 3 ] && args+=(--data "$3")
  local body
  body="$(curl "${args[@]}" "$API$2")"
  printf '%s' "$body"
  [ "$(printf '%s' "$body" | jq -r '.success // false')" = "true" ]
}

errors() { jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")'; }

confirm() {
  local answer
  [ "$YES" = 1 ] && { echo "$1 yes (--yes)"; return 0; }
  read -r -p "$1 [y/N] " answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

echo "==> Zone $ZONE_NAME"
ZONE="$(cf GET "/zones?name=$ZONE_NAME")" || { echo "ERROR: can't read the zone: $(errors <<<"$ZONE")" >&2; exit 1; }
ZONE_ID="$(jq -r '.result[0].id // empty' <<<"$ZONE")"
ACCOUNT_ID="$(jq -r '.result[0].account.id // empty' <<<"$ZONE")"
[ -n "$ZONE_ID" ] || { echo "ERROR: zone $ZONE_NAME not found for this token." >&2; exit 1; }

echo "==> Checking what exists"
todo=()

BUCKETS="$(cf GET "/accounts/$ACCOUNT_ID/r2/buckets?name_contains=$R2_BUCKET&per_page=1000")" ||
  { echo "ERROR: can't list R2 buckets (needs Workers R2 Storage Edit): $(errors <<<"$BUCKETS")" >&2; exit 1; }
if jq -e --arg bucket "$R2_BUCKET" '.result.buckets[]? | select(.name == $bucket)' <<<"$BUCKETS" >/dev/null; then
  echo "    bucket $R2_BUCKET: exists"
else
  echo "    bucket $R2_BUCKET: missing"
  todo+=(bucket)
fi
todo+=(cors)

DOMAINS="$(cf GET "/accounts/$ACCOUNT_ID/r2/buckets/$R2_BUCKET/domains/custom" || true)"
if jq -e --arg host "$TILES_HOST" '.result.domains[]? | select(.domain == $host)' <<<"$DOMAINS" >/dev/null; then
  echo "    custom domain $TILES_HOST: attached ($(jq -r --arg host "$TILES_HOST" '.result.domains[] | select(.domain == $host) | .status.ssl // .status' <<<"$DOMAINS"))"
else
  echo "    custom domain $TILES_HOST: missing"
  todo+=(domain)
fi

ENTRYPOINT="$(cf GET "/zones/$ZONE_ID/rulesets/phases/http_request_cache_settings/entrypoint" || true)"
RULESET_ID="$(jq -r '.result.id // empty' <<<"$ENTRYPOINT")"
RULE_ID="$(jq -r --arg ref "$RULE_REF" '.result.rules[]? | select(.ref == $ref) | .id' <<<"$ENTRYPOINT")"
if [ -n "$RULE_ID" ]; then
  echo "    cache rule for $TILES_HOST: exists, will be updated"
else
  echo "    cache rule for $TILES_HOST: missing"
fi
todo+=(cache_rule)

TIERED="$(cf GET "/zones/$ZONE_ID/cache/tiered_cache_smart_topology_enable" || true)"
if [ "$(jq -r '.result.value // empty' <<<"$TIERED")" = "on" ]; then
  echo "    Smart Tiered Cache: on"
else
  echo "    Smart Tiered Cache: off (zone-wide setting, asked separately)"
  todo+=(tiered)
fi

echo
echo "Planned: ${todo[*]}, then GitHub Actions setup on $REPO."
confirm "Apply these changes?" || { echo "Nothing changed."; exit 0; }

if [[ " ${todo[*]} " == *" bucket "* ]]; then
  echo "==> Creating bucket $R2_BUCKET"
  out="$(cf POST "/accounts/$ACCOUNT_ID/r2/buckets" "$(jq -n --arg name "$R2_BUCKET" '{name: $name, locationHint: "eeur"}')")" ||
    { echo "ERROR: $(errors <<<"$out")" >&2; exit 1; }
fi

echo "==> Setting the read-only CORS policy"
out="$(cf PUT "/accounts/$ACCOUNT_ID/r2/buckets/$R2_BUCKET/cors" \
  '{"rules":[{"allowed":{"methods":["GET","HEAD"],"origins":["*"]},"maxAgeSeconds":86400}]}')" ||
  { echo "ERROR: $(errors <<<"$out")" >&2; exit 1; }

if [[ " ${todo[*]} " == *" domain "* ]]; then
  echo "==> Attaching $TILES_HOST to the bucket"
  out="$(cf POST "/accounts/$ACCOUNT_ID/r2/buckets/$R2_BUCKET/domains/custom" \
    "$(jq -n --arg domain "$TILES_HOST" --arg zone "$ZONE_ID" '{domain: $domain, zoneId: $zone, enabled: true, minTLS: "1.2"}')")" ||
    { echo "ERROR: $(errors <<<"$out")" >&2; exit 1; }
fi

echo "==> Cache rule for $TILES_HOST"
RULE="$(jq -n --arg host "$TILES_HOST" --arg ref "$RULE_REF" '{
  ref: $ref,
  description: "Cache map tiles and TileJSON, honouring their Cache-Control headers",
  expression: "(http.host eq \"\($host)\")",
  action: "set_cache_settings",
  action_parameters: {cache: true, edge_ttl: {mode: "respect_origin"}, browser_ttl: {mode: "respect_origin"}},
  enabled: true
}')"
if [ -z "$RULESET_ID" ]; then
  out="$(cf PUT "/zones/$ZONE_ID/rulesets/phases/http_request_cache_settings/entrypoint" \
    "$(jq -n --argjson rule "$RULE" '{rules: [$rule]}')")" || { echo "ERROR: $(errors <<<"$out")" >&2; exit 1; }
elif [ -n "$RULE_ID" ]; then
  out="$(cf PATCH "/zones/$ZONE_ID/rulesets/$RULESET_ID/rules/$RULE_ID" "$RULE")" ||
    { echo "ERROR: $(errors <<<"$out")" >&2; exit 1; }
else
  out="$(cf POST "/zones/$ZONE_ID/rulesets/$RULESET_ID/rules" "$RULE")" ||
    { echo "ERROR: $(errors <<<"$out")" >&2; exit 1; }
fi

if [[ " ${todo[*]} " == *" tiered "* ]]; then
  echo
  echo "Smart Tiered Cache sends cache misses from every Cloudflare location through one upper tier near the"
  echo "bucket, so a new tile is read from R2 about once instead of once per location. It applies to the whole"
  echo "$ZONE_NAME zone, but only changes anything for responses Cloudflare caches."
  if { [ "$YES" = 1 ] && [ "$TIERED" = 1 ]; } || { [ "$YES" = 0 ] && confirm "Turn on Smart Tiered Cache for $ZONE_NAME?"; }; then
    out="$(cf PATCH "/zones/$ZONE_ID/cache/tiered_cache_smart_topology_enable" '{"value":"on"}')" ||
      echo "WARNING: couldn't turn it on (needs Zone Settings Edit): $(errors <<<"$out")" >&2
  fi
fi

echo "==> GitHub Actions on $REPO"
gh api -X PUT "repos/$REPO/actions/permissions" -F enabled=true -f allowed_actions=all >/dev/null
for workflow in snapshot.yml release.yml; do
  gh workflow disable "$workflow" -R "$REPO" >/dev/null 2>&1 && echo "    disabled upstream $workflow" || true
done
gh workflow enable tiles.yml -R "$REPO" >/dev/null 2>&1 && echo "    enabled tiles.yml (forks start with schedules off)" ||
  echo "    WARNING: couldn't enable tiles.yml; push the branch with it to $REPO's default branch first" >&2
gh variable set R2_ACCOUNT_ID -R "$REPO" --body "$ACCOUNT_ID"
gh variable set R2_BUCKET -R "$REPO" --body "$R2_BUCKET"
gh variable set TILES_URL -R "$REPO" --body "https://$TILES_HOST"

existing_secrets="$(gh secret list -R "$REPO" --json name --jq '.[].name')"
has_secrets=0
grep -qx R2_ACCESS_KEY_ID <<<"$existing_secrets" && grep -qx R2_SECRET_ACCESS_KEY <<<"$existing_secrets" && has_secrets=1
if [ "$INTERACTIVE" = 0 ]; then
  if [ "$has_secrets" = 1 ]; then
    echo "    R2 key secrets already set"
  else
    echo
    echo "Last step, by hand: create the workflow's R2 key in the Cloudflare dashboard -> R2 -> Manage API tokens ->"
    echo "Create Account API token, permission 'Object Read & Write', applied to the bucket $R2_BUCKET only."
    echo "Add its Access Key ID and Secret Access Key as the secrets R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY at"
    echo "https://github.com/$REPO/settings/secrets/actions"
  fi
elif [ "$has_secrets" = 1 ] && ! confirm "R2 key secrets already exist on $REPO. Replace them?"; then
  echo "    kept the existing R2 key secrets"
else
  echo
  echo "Create the workflow's R2 key: Cloudflare dashboard -> R2 -> Manage API tokens -> Create Account API token,"
  echo "permission 'Object Read & Write', applied to the bucket $R2_BUCKET only. Then paste its S3 credentials."
  read -r -s -p "Access Key ID: " key_id; echo
  read -r -s -p "Secret Access Key: " key_secret; echo
  [ -n "$key_id" ] && [ -n "$key_secret" ] || { echo "ERROR: both values are needed." >&2; exit 1; }
  printf '%s' "$key_id" | gh secret set R2_ACCESS_KEY_ID -R "$REPO"
  printf '%s' "$key_secret" | gh secret set R2_SECRET_ACCESS_KEY -R "$REPO"
  unset key_id key_secret
fi

echo
echo "Done. The custom domain can take a few minutes to become active."
echo "Start a build with: gh workflow run tiles.yml -R $REPO"
echo "Clients load: https://$TILES_HOST/openmaptiles.json"
