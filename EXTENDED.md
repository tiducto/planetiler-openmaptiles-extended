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
| `platform-areas`     | closed `public_transport=platform` ways become polygons unless `area=no`                                                                   |
| `footpath-over-area` | `over` on `path` lines: the kind of area polygon (platform, pier, pedestrian, ...) a piece runs across                                     |

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

1. `scripts/tiles/build.sh` merges the Geofabrik extracts of Czechia, Austria and Slovakia and builds z0–z14 tiles as
   plain `{z}/{x}/{y}.pbf` files.
2. `scripts/tiles/publish.sh` uploads them to Cloudflare R2 under `v/<version>/` (cached for a year, never changed),
   then points `openmaptiles.json` (the TileJSON clients load, cached for five minutes) at the new version and
   deletes all but the two newest versions.

Clients use `https://tiles.tiducto.eu/openmaptiles.json` as the vector source URL, in place of OpenFreeMap's.

One-time setup: `scripts/tiles/setup-cloudflare.sh` creates the bucket, its custom domain and cache rule, and sets the
workflow's variables and R2 key secrets.
