# planetiler-openmaptiles-extended

This fork builds OpenMapTiles-compatible vector tiles with a few additions that upstream doesn't have yet, and
publishes them weekly for the Jízdní řády JMK app. Styles written for OpenMapTiles keep working unchanged.

## Additions

Each addition lives on its own branch, based on upstream `main`, with its tests, so it can be offered upstream on
its own. The schema side of each lives in [tiducto/openmaptiles-extended](https://github.com/tiducto/openmaptiles-extended)
on a branch of the same name, also based on upstream.

|        Branch        |                                                                   Change                                                                   |
|----------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| `motorroad`          | `motorroad=1` on non-motorway roads tagged `motorroad=yes` ([openmaptiles#1818](https://github.com/openmaptiles/openmaptiles/pull/1818))   |
| `elevator`           | `highway=elevator` nodes and areas as POIs, class `elevator` ([openmaptiles#1820](https://github.com/openmaptiles/openmaptiles/pull/1820)) |
| `footpath-over-area` | `over` on `path` lines: the kind of area polygon (platform, pier, pedestrian, ...) a piece runs across                                     |
| `building-roof`      | `roof=1` on buildings tagged `building=roof` (platform canopies, shelters, fuel station roofs)                                             |

`main` merges these branches. To add a new one: branch from upstream `main`, regenerate the schema code from the
matching `openmaptiles-extended` branch, add the Java change and tests, then merge it into `main`. When two branches
touch the generated code, resolve by regenerating from all their schema changes together.

The generated code comes from Planetiler's current OpenMapTiles base plus the `openmaptiles-extended` changes, so
upstream schema changes not yet ported to Planetiler stay out:

```bash
./scripts/regenerate-openmaptiles.sh <branch-or-tag> https://raw.githubusercontent.com/tiducto/openmaptiles-extended/
```

## Tiles

The `Tiles` workflow (`.github/workflows/tiles.yml`) runs every Monday and on demand:

1. `scripts/tiles/cloudflare.sh` makes sure the R2 bucket `tiducto-tiles`, its custom domain `tiles.tiducto.eu`,
   the cache and firewall rules for that host and Smart Tiered Cache exist, creating or fixing whatever is missing.
2. `scripts/tiles/build.sh` merges the Geofabrik extracts of Czechia, Austria and Slovakia and builds z0–z14 tiles as
   plain `{z}/{x}/{y}.pbf` files.
3. `scripts/tiles/publish.sh` uploads them to R2 under `v/<version>/` (cached for a year, never changed), then points
   `openmaptiles.json` (the TileJSON clients load, cached for five minutes) at the new version and deletes all but the
   two newest versions.

Clients use `https://tiles.tiducto.eu/openmaptiles.json` as the vector source URL, in place of OpenFreeMap's.

The tiles are public, with no key: a key would ship inside every app, so it would keep nobody out. What costs money is
a request that misses Cloudflare's cache and reads from R2 (bandwidth is free, and so are cache hits), so the host is
set up to keep those few. The firewall rule blocks anything but `GET`, `HEAD` or `OPTIONS` of `/openmaptiles.json`,
`/v/<version>/openmaptiles.json` and `/v/<version>/<z>/<x>/<y>.pbf` without a query string, at the edge and for free,
and the cache rule keeps "not found" answers for a day. Run the workflow with `setup_only` to apply a change to them
without building tiles.

The only setting is the repository secret `CLOUDFLARE_API_TOKEN`, a Cloudflare account API token (Manage account →
Account API tokens; a user API token works too) with Account → Workers R2 Storage → Edit, and Zone → Zone → Read,
Cache Settings → Edit, Zone Settings → Edit, DNS → Edit and WAF → Edit on `tiducto.eu`. The same token is the R2 upload key: its id
is the access key ID and the SHA-256 of its value the secret access key.
