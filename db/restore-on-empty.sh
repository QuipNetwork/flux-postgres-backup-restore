#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Restore the newest dump onto an empty data directory, or start
# empty. Runs from /docker-entrypoint-initdb.d (see db/Dockerfile), as the
# postgres user, against the socket-only temporary server.
#
# FAILS OPEN. The database is derived state, so every failure -- store
# unreachable, no dump, corrupt dump, a dump lower than its key claims -- ends
# in an empty database that the app re-indexes from genesis. That was the
# behaviour before this image existed, so a broken backup path costs time but
# never correctness. Two things it must never do:
#
#   - Exit non-zero on a recoverable failure. The stock entrypoint writes
#     PG_VERSION before init scripts run, so after one failed exit FluxOS's
#     restart skips init entirely and serves whatever is on disk.
#   - Leave a partial restore behind. On any failure the database is dropped
#     and recreated empty before exiting 0.
#
# A failed restore is still noticed: the re-indexing app sits below the newest
# dump's height, so the backup sidecar's height guard refuses to upload and its
# heartbeat monitor goes red.
#
# Settings (environment):
#   S3_BUCKET        empty or unset => restore is off (first deploy, or none configured)
#   S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_PREFIX DUMP_NAME
#                    required when S3_BUCKET is set; must match the sidecar's
#   S3_REGION        default us-east-1
#   HEIGHT_SQL       optional; when set, the restored database must reach the
#                    height in the dump's key (otherwise: at least one table)
#   RESTORE_JOBS     pg_restore parallelism, default 2
#   RESTORE_DIR      download directory, default $PGDATA. It must be on the
#                    volume: the container root is capped near 10 GB on Flux.

set -uo pipefail

log() { echo "[restore-on-empty] $*"; }

# shellcheck source=../lib/dump-keys.sh
. /usr/local/lib/dump-keys.sh

DUMP_FILE="${RESTORE_DIR:-$PGDATA}/.restore-in-progress.dump"

psql_db() { # DB [psql args...] -- as the superuser, over the init socket
    local db="$1"; shift
    psql -v ON_ERROR_STOP=1 -X -q --username "$POSTGRES_USER" --dbname "$db" "$@"
}

# Drop whatever a failed restore left and recreate the database empty, as the
# stock entrypoint made it.
reset_db() {
    if [ "$POSTGRES_DB" = "postgres" ]; then
        psql_db postgres <<'SQL'
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
SQL
    else
        psql_db postgres -v db="$POSTGRES_DB" -v owner="$POSTGRES_USER" <<'SQL'
DROP DATABASE IF EXISTS :"db" WITH (FORCE);
CREATE DATABASE :"db" OWNER :"owner";
SQL
    fi
}

# start_empty REASON -- the one failure exit.
start_empty() {
    rm -f "$DUMP_FILE"
    log "RESTORE FAILED: $1"
    if ! reset_db; then
        # Nothing safe is left. A non-zero exit at least shows up as a restart.
        log "FATAL: could not reset ${POSTGRES_DB} after a failed restore; it may be partial"
        exit 1
    fi
    log "starting with an EMPTY database -- the app will re-index from genesis"
    exit 0
}

if [ -z "${S3_BUCKET:-}" ]; then
    log "S3_BUCKET unset -- restore is off, starting empty"
    exit 0
fi
for v in S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_PREFIX DUMP_NAME; do
    [ -n "${!v:-}" ] || start_empty "S3_BUCKET is set but $v is not"
done

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}"
# Storj's gateway requires Content-Length, which aws-cli v2.23+ omits by
# default (aws-chunked encoding) -- it fails as MissingContentLength and reads
# like a permissions error. Overridable for a gateway that wants checksums.
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

WHERE="s3://${S3_BUCKET}/${S3_PREFIX}/"

# list-objects-v2, not `s3 ls`: on an empty prefix `s3 ls` exits 1 and prints
# nothing, which is indistinguishable from a failure. This exits 0 with "None".
if ! LISTING="$(aws --endpoint-url "$S3_ENDPOINT" s3api list-objects-v2 \
        --bucket "$S3_BUCKET" --prefix "${S3_PREFIX}/" \
        --query 'Contents[].Key' --output text 2>&1)"; then
    log "could not list ${WHERE} -- aws said:"
    printf '%s\n' "$LISTING" | sed 's/^/[restore-on-empty]   /'
    start_empty "could not list ${WHERE}"
fi

KEY="$(printf '%s\n' "$LISTING" | newest_dump_key "$S3_PREFIX" "$DUMP_NAME")"
if [ -z "$KEY" ]; then
    log "no dumps for ${DUMP_NAME} under ${WHERE} -- starting empty"
    exit 0
fi
WANT="$(dump_key_height "$KEY")"

log "restoring ${KEY}"
STARTED="$(date +%s)"

aws --endpoint-url "$S3_ENDPOINT" s3 cp "s3://${S3_BUCKET}/${KEY}" "$DUMP_FILE" --only-show-errors \
    || start_empty "download of ${KEY} failed"

# --exit-on-error turns a partial restore into a failure we can clean up,
# rather than a database silently missing tables.
pg_restore --exit-on-error --no-owner --no-privileges --jobs "${RESTORE_JOBS:-2}" \
        --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" "$DUMP_FILE" \
    || start_empty "pg_restore of ${KEY} failed"
rm -f "$DUMP_FILE"

# Assert the positive: a restore that "succeeded" into the wrong data is the
# failure this script exists to prevent.
if [ -n "${HEIGHT_SQL:-}" ]; then
    GOT="$(psql_db "$POSTGRES_DB" -tA -c "$HEIGHT_SQL" 2>&1)"
    is_uint "$GOT" || start_empty "height query after restore did not return a number: ${GOT}"
    [ "$GOT" -ge "$WANT" ] || start_empty "restored height ${GOT} is below the key's height ${WANT}"
else
    TABLES="$(psql_db "$POSTGRES_DB" -tA -c \
        "select count(*) from information_schema.tables where table_schema='public'" 2>&1)"
    [ "${TABLES:-0}" -ge 1 ] 2>/dev/null || start_empty "restore produced no tables"
    GOT="unchecked"
fi

log "restored ${KEY} (height ${GOT}) in $(( $(date +%s) - STARTED ))s"
