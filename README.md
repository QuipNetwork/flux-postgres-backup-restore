# flux-postgres-backup-restore

Backup and restore for a Postgres database running as a component of a
single-instance Flux app, so that a Flux relocation (which hands the app an
empty volume) costs minutes instead of hours.

> ⚠ **Only for databases you can rebuild.** It is built for the block
> explorers (Subscan, Blockscout), whose database is an index of the chain. On
> any restore problem it **starts empty on purpose** and lets the app re-index.
> For a database that is the source of truth (accounts, settings, anything you
> cannot regenerate), use a restore that refuses to start empty instead, such
> as observe.quip.network's Postgres image.

| Image | Role |
| -- | -- |
| `db` | Stock `postgres:17-alpine` plus a restore that runs **only on an empty data directory** |
| `backup` | Sidecar component: dumps on a cadence to object storage, pings a heartbeat |

Published as `registry.gitlab.com/quip.network/flux-postgres-backup-restore:db-<sha>`
and `:backup-<sha>`, built and pushed by hand with `scripts/build-images.sh`
(amd64 only, single-platform manifests; pin `tag@sha256:digest` in the Flux
spec). Both images share one digest-pinned base, so the `pg_dump` that writes a
dump and the `pg_restore` that reads it are the same build.

## Why

At `instances: 1` a Flux relocation hands the app a virgin volume, and FluxOS
restores nothing. A block explorer then re-indexes from genesis. On aglais that
takes about 14 h for Subscan (at block 200k, growing about an hour per day of
chain) and 3–7 h for Blockscout. With these images it costs the Flux placement
wait, plus a download and restore, plus the blocks since the last dump.

## How it behaves

**Restore (db).** `restore-on-empty.sh` runs from `/docker-entrypoint-initdb.d`,
which the stock entrypoint runs only on an empty data directory. It restores the
newest dump against the socket-only init server, so the app cannot connect
mid-restore. It **fails open**: an unreadable store, no dump, a corrupt dump, or
a dump whose data is below the height in its key all end in an empty database
and a re-index, which is what happened before these images existed. It never
exits non-zero on such a failure, and never leaves a partial restore. (Contrast
observe's Postgres image, whose data is the source of truth and fails closed.)

**Backup (sidecar).** Each cycle reads the index height (`HEIGHT_SQL`), refuses
to dump below the newest stored dump's height, takes `pg_dump -Fc`, uploads it
to `<S3_PREFIX>/<DUMP_NAME>-<stamp>-h<height>.dump`, checks the stored size,
pings `HEARTBEAT_URL`, and prunes to `BACKUP_RETENTION`. The height guard is
what stops an app that is re-indexing after a failed restore from pushing the
good dumps out. The heartbeat fires only after a stored dump, so the monitor
goes red whenever dumps stop, for any reason.

The cadence is anchored on the newest **stored** dump, not on container start,
so routine Flux restarts neither trigger an immediate dump nor delay the next.

`backup-loop.sh --once` takes one dump now (exit 0 if stored). Use it from the
sidecar's shell before planned maintenance.

## Settings

Both components:

| Variable | Meaning |
| -- | -- |
| `S3_ENDPOINT` `S3_BUCKET` `S3_ACCESS_KEY` `S3_SECRET_KEY` | Object store. Storj works; the scripts set `*_CHECKSUM_*=when_required` for its gateway. |
| `S3_PREFIX` | ⚠ Must name the **chain** as well as the app, e.g. `subscan-postgres/aglais-542a9915`. Heights restart on a relaunch; restoring the old chain's index under a new chain would be wrong data, so a relaunch gets a new prefix. |
| `DUMP_NAME` | Key stem, `[a-z0-9-]`, e.g. `subscan` |
| `HEIGHT_SQL` | One integer: the index height. Required for backup; optional for db (it then checks only that tables exist). |

db only: `RESTORE_JOBS` (default 2), `RESTORE_DIR` (default `$PGDATA`; must be on
the volume, because the container root is capped near 10 GB on Flux). An empty
`S3_BUCKET` turns restore off.

backup only: `PGHOST` `PGUSER` `PGPASSWORD` `PGDATABASE`, `HEARTBEAT_URL`,
`BACKUP_INTERVAL` (s, default 21600), `BACKUP_RETRY` (s, default 1800),
`BACKUP_RETENTION` (default 4), `BACKUP_DIR` (default `/backup`; give the sidecar
its own volume sized for one dump, with headroom: any later `hdd` change is a
wiping redeploy of the whole app), `PGD_COMPRESS` (default `zstd:3`),
`MIN_DUMP_BYTES` (default 4096). With any S3 setting missing it idles and says
so hourly instead of crash-looping.

### Per app

| | Subscan (`quipsubscan`) | Blockscout (`quipexplorer`) |
| -- | -- | -- |
| db component | `sqdb` | `bsdb` |
| `PGHOST` (sidecar) | `fluxsqdb_quipsubscan` | `fluxbsdb_quipexplorer` |
| `DUMP_NAME` | `subscan` | `blockscout` |
| Cadence / keep | 6 h / 4 | 1 h / 6 |
| Sidecar volume | ~40 GB (12 GB database at block 192k; dump ≈ 1/5 of that) | ~2 GB (315 MB database) |

Subscan's `HEIGHT_SQL` must span its split block tables (a new
`chain_blocks_<n>` every 1,000,000 blocks, `model/substrate.go:24` in the fork).
This was checked on Postgres 17 against `chain_blocks` plus `chain_blocks_1`,
and returns 0 with no tables:

```sql
select coalesce(max((xpath('/row/m/text()', query_to_xml(format('select max(block_num) as m from %I', tablename), false, true, '')))[1]::text::bigint), 0) from pg_tables where schemaname = 'public' and tablename ~ '^chain_blocks(_[0-9]+)?$'
```

Blockscout's: `select coalesce(max(number),0) from blocks where consensus`.

### After a Subscan restore

Subscan's extrinsic counters (`count_extrinsic`, `count_signed_extrinsic`, and
the balance/evm plugin totals) live only in Redis, which a relocation empties.
Blocks and projections recover by themselves: sqsub republishes from 0, and the
worker skips blocks already in the database. Once the index has caught up, run
this once in the `sqwork` shell. Running it mid-catch-up double-counts.

```sh
/subscan/cmd/subscan refreshMetadata
```

Blockscout needs nothing: its catchup fetcher fills missing ranges by itself.

### Measured (2026-10-29, real Storj, real Subscan data)

A 5.0 GB Subscan database (69,783 blocks, 3.3M events) gave a 0.98 GB dump.
Dump plus upload took 58 s. Restore onto an empty volume took 56 s, download
included, and Postgres was accepting connections at 61 s. Table counts and
digests over every block hash and extrinsic hash matched the source.

Blockscout, the same day: production's API image (`explorer.quip.network:api-6685278`,
Blockscout 9.0.2) indexed 3,052 recent aglais blocks into the db image, then
went through dump, Storj and restore. Everything matched: 62 tables, 205
indexes, 354 functions, 6 enum types, the btree_gin, btree_gist, citext and
pg_trgm extensions, all 316 migrations, and block and transaction hash
digests. The same API then started on the restored database with no error or
duplicate-key lines and carried on from the restored height. Blockscout's
catch-up fetcher filled the one new block its realtime fetcher had skipped
("Index had to catch up", 1 block).

Storj notes, from the scoped production keys: a key scoped to `<folder>/` may
list unfinished multipart uploads only under that folder (the bucket-wide
listing is AccessDenied), and it is refused in other folders and other buckets.

## Tests

```sh
sh test/dump-keys_test.sh       # key rules, no docker, seconds
sh test/integration_test.sh     # both images vs a local MinIO, ~2 min

# the same 39 checks against a real store (~90 s on Storj); everything is
# written under <prefix>/run-<id>/ and deleted on exit
S3_TEST_ENV=<file of S3_* lines> S3_TEST_ROOT=<prefix> sh test/integration_test.sh
```

⚠ MinIO accepts the aws-chunked uploads the real Storj gateway rejects, and it
ignores a partial `--prefix` on `list-multipart-uploads`. So the run against the
real store, with a key scoped like the production ones, is the gate before
deploying.
