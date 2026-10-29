#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Dump a derived Postgres to object storage on a cadence, so the db image can
# restore it after a Flux relocation instead of re-indexing from genesis.
#
# One cycle:
#   1. Read the index height (HEIGHT_SQL) and the newest stored dump's height.
#   2. HEIGHT GUARD: dump only if the height is above 0 and not below the
#      newest stored. After a failed restore the app re-indexes from genesis;
#      without the guard its first dumps would become "newest" and prune the
#      good ones.
#   3. Abort this app's unfinished multipart uploads. A cycle killed mid-upload
#      leaves one: never restorable, but it holds storage.
#   4. pg_dump -Fc into BACKUP_DIR, then check its size and that pg_restore can
#      read its table of contents.
#   5. Upload straight to the final key and check the stored size. There is no
#      .partial-then-rename step: an S3 object only appears once its upload
#      completes, and renaming a >5 GB object server-side needs UploadPartCopy,
#      which is unverified on Storj.
#   6. Ping HEARTBEAT_URL, ONLY after a stored dump, so the monitor goes red
#      whenever dumps stop, for any reason, the height guard included.
#   7. Prune to BACKUP_RETENTION, never the newest.
#
# The cadence is anchored on the newest STORED dump, not on container start.
# Flux restarts components every few days; a restart must neither trigger an
# immediate multi-GB dump nor push the next one out by a full interval.
#
# --once  run one cycle now; exit 0 if a dump was stored, 1 if not. Also the
#         operator's way to take a dump before planned maintenance.
#
# Settings (environment):
#   PGHOST PGUSER PGPASSWORD PGDATABASE   the db component (Flux: flux<component>_<app>)
#   S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY S3_PREFIX DUMP_NAME
#                     must match the db component's
#   S3_REGION         default us-east-1
#   HEIGHT_SQL        query returning the index height as one integer
#   HEARTBEAT_URL     optional; GET after each stored dump
#   BACKUP_INTERVAL   seconds between dumps, default 21600 (6 h)
#   BACKUP_RETRY      seconds before retrying a cycle that stored nothing,
#                     default 1800, capped at BACKUP_INTERVAL
#   BACKUP_RETENTION  dumps to keep, default 4, minimum 1
#   BACKUP_DIR        scratch for the dump file, default /backup. Give it its
#                     own volume sized for one dump: the container root is
#                     capped near 10 GB on Flux.
#   DUMP_COMPRESS      pg_dump --compress, default zstd:3
#   MIN_DUMP_BYTES    a smaller dump counts as failed, default 4096

set -uo pipefail

ONCE=0
[ "${1:-}" = "--once" ] && ONCE=1

log() { echo "[backup] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# shellcheck source=../lib/dump-keys.sh
. /usr/local/lib/dump-keys.sh

for v in PGHOST PGUSER PGDATABASE; do
    [ -n "${!v:-}" ] || { log "FATAL: $v is required"; exit 1; }
done

MISSING=""
for v in S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY S3_PREFIX DUMP_NAME HEIGHT_SQL; do
    [ -n "${!v:-}" ] || MISSING="$MISSING $v"
done
if [ -n "$MISSING" ]; then
    # Idle rather than crash-loop (a component that is always red teaches people
    # to ignore red), but say so every hour: a backup that quietly does nothing
    # is only discovered when a restore is needed.
    while :; do
        log "##########################################################"
        log "## BACKUPS ARE NOT RUNNING. Missing:${MISSING}"
        log "## A Flux relocation will re-index this app from genesis."
        log "##########################################################"
        [ "$ONCE" -eq 1 ] && exit 1
        sleep 3600
    done
fi

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}"
# Storj's gateway requires Content-Length, which aws-cli v2.23+ omits by
# default (aws-chunked encoding) -- it fails as MissingContentLength and reads
# like a permissions error. Overridable for a gateway that wants checksums.
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

INTERVAL="${BACKUP_INTERVAL:-21600}"
RETRY="${BACKUP_RETRY:-1800}"
RETENTION="${BACKUP_RETENTION:-4}"
DIR="${BACKUP_DIR:-/backup}"
MIN_BYTES="${MIN_DUMP_BYTES:-4096}"
for v in INTERVAL RETRY MIN_BYTES; do
    if ! is_uint "${!v}" || [ "${!v}" -eq 0 ]; then
        log "FATAL: $v must be a positive integer (got '${!v}')"
        exit 1
    fi
done
[ "$RETRY" -le "$INTERVAL" ] || RETRY="$INTERVAL"

s3api() { aws --endpoint-url "$S3_ENDPOINT" s3api "$@"; }
s3() { aws --endpoint-url "$S3_ENDPOINT" s3 "$@"; }

# list_keys -- every key under the prefix; rc 1 (logged) if the store cannot be
# read. list-objects-v2, not `s3 ls`, which exits 1 on an empty prefix.
list_keys() {
    local out
    if ! out="$(s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "${S3_PREFIX}/" \
            --query 'Contents[].Key' --output text 2>&1)"; then
        log "ERROR: could not list s3://${S3_BUCKET}/${S3_PREFIX}/ -- aws said: ${out}"
        return 1
    fi
    printf '%s\n' "$out"
}

# Housekeeping only: failure here never stops a dump.
abort_dead_uploads() {
    local scoped bucketwide key id
    # Two listings, because stores disagree on prefix filtering. MinIO lists
    # unfinished uploads only for an exact key or with no prefix at all, so a
    # partial prefix returns nothing (measured, RELEASE.2025-04-22). A
    # prefix-scoped Storj grant may instead refuse the bucket-wide listing.
    # Whatever either returns is filtered to this app's keys below.
    scoped="$(s3api list-multipart-uploads --bucket "$S3_BUCKET" --prefix "${S3_PREFIX}/" \
        --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null)"
    bucketwide="$(s3api list-multipart-uploads --bucket "$S3_BUCKET" \
        --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null)"
    printf '%s\n%s\n' "$scoped" "$bucketwide" | LC_ALL=C sort -u | while read -r key id; do
        [ -n "${id:-}" ] || continue        # blank, or "None"
        is_own_dump_key "$S3_PREFIX" "$DUMP_NAME" "$key" || continue
        if s3api abort-multipart-upload --bucket "$S3_BUCKET" --key "$key" --upload-id "$id" >/dev/null 2>&1; then
            log "aborted a dead upload of ${key}"
        else
            log "WARN: could not abort the dead upload of ${key}"
        fi
    done
}

prune() {
    local listing k
    listing="$(list_keys)" || { log "WARN: prune skipped"; return 0; }
    printf '%s\n' "$listing" | dump_keys_to_prune "$S3_PREFIX" "$DUMP_NAME" "$RETENTION" | while IFS= read -r k; do
        [ -n "$k" ] || continue
        if s3 rm "s3://${S3_BUCKET}/${k}" --only-show-errors; then
            log "pruned ${k}"
        else
            log "WARN: could not prune ${k}"
        fi
    done
}

# cycle -- rc 0 only if a dump was stored.
cycle() {
    local height listing newest newest_h stamp key file size remote started

    if ! height="$(psql -X -q -tA -c "$HEIGHT_SQL" 2>&1)"; then
        log "ERROR: height query failed: ${height}"
        return 1
    fi
    height="${height//[[:space:]]/}"
    is_uint "$height" || { log "ERROR: height query returned '${height}', not a number"; return 1; }

    listing="$(list_keys)" || return 1
    newest="$(printf '%s\n' "$listing" | newest_dump_key "$S3_PREFIX" "$DUMP_NAME")"
    newest_h=""
    [ -z "$newest" ] || newest_h="$(dump_key_height "$newest")"
    if ! may_store_dump "$height" "$newest_h"; then
        if [ "$height" -eq 0 ]; then
            log "index is empty (height 0) -- nothing to back up yet"
        else
            log "refusing: index height ${height} is below the newest stored dump ${newest}." \
                "Re-indexing after a failed restore? Dumps resume once the index passes it."
        fi
        return 1
    fi

    abort_dead_uploads

    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    if ! key="$(dump_key "$S3_PREFIX" "$DUMP_NAME" "$height" "$stamp")"; then
        log "ERROR: cannot build a key from S3_PREFIX='${S3_PREFIX}' DUMP_NAME='${DUMP_NAME}'"
        return 1
    fi
    mkdir -p "$DIR" || { log "ERROR: cannot create ${DIR}"; return 1; }
    rm -f "${DIR}/${DUMP_NAME}-"*.dump              # a killed cycle's leftover
    file="${DIR}/${DUMP_NAME}-${stamp}.dump"
    started="$(date +%s)"

    if ! pg_dump -Fc --compress="${DUMP_COMPRESS:-zstd:3}" -f "$file"; then
        rm -f "$file"
        log "ERROR: pg_dump failed; the previous dumps stay newest"
        return 1
    fi
    size="$(stat -c %s "$file")"
    if [ "$size" -lt "$MIN_BYTES" ]; then
        rm -f "$file"
        log "ERROR: dump is only ${size} bytes (< ${MIN_BYTES}); not storing a stub"
        return 1
    fi
    if ! pg_restore --list "$file" >/dev/null 2>&1; then
        rm -f "$file"
        log "ERROR: pg_restore cannot read the dump's table of contents; not storing it"
        return 1
    fi

    if ! s3 cp "$file" "s3://${S3_BUCKET}/${key}" --only-show-errors; then
        rm -f "$file"
        log "ERROR: upload of ${key} failed"
        return 1
    fi
    rm -f "$file"

    # Assert the positive: the object is there, whole.
    remote="$(s3api head-object --bucket "$S3_BUCKET" --key "$key" --query ContentLength --output text 2>&1)"
    if [ "$remote" != "$size" ]; then
        log "ERROR: ${key} is '${remote}' bytes in the store, expected ${size}; deleting it"
        s3 rm "s3://${S3_BUCKET}/${key}" --only-show-errors || log "WARN: could not delete ${key}"
        return 1
    fi
    log "stored ${key} (${size} bytes) in $(( $(date +%s) - started ))s"

    if [ -n "${HEARTBEAT_URL:-}" ]; then
        curl -fsS -m 30 -o /dev/null "$HEARTBEAT_URL" || log "WARN: heartbeat failed; the dump itself is stored"
    fi

    prune
    return 0
}

# seconds_until_due -- 0 when a dump is due now. Any doubt means "now": a
# spare dump is cheap next to a missed one.
seconds_until_due() {
    local listing newest iso stamped due
    listing="$(list_keys)" || { echo 0; return; }
    newest="$(printf '%s\n' "$listing" | newest_dump_key "$S3_PREFIX" "$DUMP_NAME")"
    [ -n "$newest" ] || { echo 0; return; }
    iso="$(dump_key_iso_time "$newest")" || { echo 0; return; }
    stamped="$(date -u -d "$iso" +%s 2>/dev/null)" || { echo 0; return; }
    due=$(( stamped + INTERVAL - $(date -u +%s) ))
    [ "$due" -gt 0 ] || due=0
    echo "$due"
}

# No timeout outside --once: after a relocation the db component restores
# before it accepts TCP connections, and that can legitimately take a while.
wait_for_postgres() {
    local waited=0
    until pg_isready -q; do
        sleep 5
        waited=$((waited + 5))
        [ $((waited % 60)) -ne 0 ] || log "still waiting for postgres at ${PGHOST} (${waited}s)"
        if [ "$ONCE" -eq 1 ] && [ "$waited" -ge 120 ]; then
            log "ERROR: postgres at ${PGHOST} not ready after ${waited}s"
            return 1
        fi
    done
}

log "starting: db=${PGHOST}/${PGDATABASE} store=s3://${S3_BUCKET}/${S3_PREFIX}/ name=${DUMP_NAME}" \
    "interval=${INTERVAL}s retry=${RETRY}s retention=${RETENTION}"
wait_for_postgres || exit 1

if [ "$ONCE" -eq 1 ]; then
    cycle
    exit $?
fi

while :; do
    due="$(seconds_until_due)"
    if [ "$due" -gt 0 ]; then
        log "newest stored dump is recent; next dump in ${due}s"
        sleep "$due"
    fi
    if ! cycle; then
        log "no dump stored this cycle; retrying in ${RETRY}s"
        sleep "$RETRY"
    fi
done
