#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# End-to-end test of the db and backup images against a real S3 server.
#
# What it proves, in the order a relocation would exercise it:
#   - a first boot with nothing stored starts empty;
#   - the backup sidecar dumps, uploads under a height-stamped key, and pings
#     the heartbeat -- and refuses to do so for an empty index;
#   - a fresh volume restores the newest dump, and only the newest;
#   - every way a restore can go wrong (unreadable store, corrupt dump, a dump
#     that is lower than its key claims) ends in an EMPTY database that the
#     app re-indexes, never a crash loop and never a half-restored schema;
#   - the height guard stops a re-indexing app from replacing good dumps;
#   - the one-writer guard stores nothing unless Flux lists exactly one
#     instance of the app: not for two, not for none, not for an unreadable
#     list; and the image derives the app's name from a Flux PGHOST;
#   - pruning keeps the newest N, a dead cycle's multipart upload is aborted,
#     and a restarted sidecar waits out the cadence instead of dumping at once.
#
# SeaweedFS stands in for Storj (MinIO's images stopped pulling in 2026-11,
# found in QUI-2496). ⚠ A local store accepts requests the real Storj gateway
# rejects, such as aws-chunked uploads (MissingContentLength), so this test
# cannot catch that class of bug. The scripts set *_CHECKSUM_*=when_required
# for it, and the rehearsal against the live gateway is the gate for it.
#
# Flux's instance list is a file mounted into every sidecar run (FLUX_LOCATION_URL
# is a file:// URL), one instance by default. No run ever reads the real API.
#
# Run:  sh test/integration_test.sh
#       SKIP_BUILD=1 to reuse already-built :test images.
#
# Against a real store (the gate a local store cannot be):
#       S3_TEST_ENV=<file> S3_TEST_ROOT=<prefix> sh test/integration_test.sh
# <file> holds S3_ENDPOINT / S3_BUCKET / S3_ACCESS_KEY / S3_SECRET_KEY lines, for
# example a Storj key scoped to <prefix>. Everything the run writes lives under
# <prefix>/run-<id>/ and is deleted on exit, dead multipart uploads included.
#
# Needs: docker. Leaves nothing behind (trap removes containers, volumes, net).
# Exit: 0 = all pass, nonzero = a failure (name printed).

set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTX="${SELF_DIR}/.."

RUN="fpbrt$$"
NET="${RUN}-net"
DB_IMG="${DB_IMAGE:-flux-postgres-backup-restore:db-test}"
BK_IMG="${BACKUP_IMAGE:-flux-postgres-backup-restore:backup-test}"
S3_IMG="chrislusf/seaweedfs:4.52@sha256:57877e32bb90073b37dc109b438ba66e84fd5ed9ced5f5c04f56444ef243ce59"
HB_IMG="busybox:1.37"
FLUXDIR="$(mktemp -d)"   # the instance list the sidecars read, as /flux/location.json
chmod 755 "$FLUXDIR"

S3_HOST="${RUN}-s3"
HB_HOST="${RUN}-hb"
BUCKET="fpbrtest"
S3_USER="fpbrtest"
S3_PASS="fpbrtest-secret"
S3_URL="http://${S3_HOST}:9000"
ROOT=""
EXTERNAL=""
if [ -n "${S3_TEST_ENV:-}" ]; then
    EXTERNAL=1
    # shellcheck disable=SC1090
    . "$S3_TEST_ENV"
    : "${S3_TEST_ROOT:?S3_TEST_ROOT must name a prefix the key may write}"
    S3_URL="$S3_ENDPOINT" BUCKET="$S3_BUCKET" S3_USER="$S3_ACCESS_KEY" S3_PASS="$S3_SECRET_KEY"
    ROOT="${S3_TEST_ROOT%/}/run-${RUN}/"
fi
MAIN="${ROOT}main"     # the prefix most cases share
NONE="${ROOT}none"     # stays empty
HEIGHT_SQL="select coalesce(max(number),0) from blocks"
PGDATA_IN="/var/lib/postgresql/data/pgdata-test"

FAILED=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }
assert_eq() { # desc want got
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want='$2' got='$3')"; fi
}
assert_rc() { # desc want-rc got-rc
    if [ "$2" -eq "$3" ]; then pass "$1"; else fail "$1 (want rc=$2 got rc=$3)"; fi
}
assert_has() { # desc needle haystack
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in output)"; printf '%s\n' "$3" | tail -n 15 | sed 's/^/       | /' ;; esac
}

CONTAINERS=""
VOLUMES=""
# shellcheck disable=SC2317  # reached through the trap
cleanup() {
    # Before the network and the xfer volume go: s3() needs both.
    if [ -n "$EXTERNAL" ]; then
        s3 s3 rm --recursive "s3://${BUCKET}/${ROOT}" --only-show-errors >/dev/null 2>&1
        s3 s3api list-multipart-uploads --bucket "$BUCKET" --prefix "$ROOT" \
            --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null | while read -r _k _id; do
            [ -n "${_id:-}" ] || continue
            s3 s3api abort-multipart-upload --bucket "$BUCKET" --key "$_k" --upload-id "$_id" >/dev/null 2>&1
        done
    fi
    # shellcheck disable=SC2086
    [ -z "$CONTAINERS" ] || docker rm -f $CONTAINERS >/dev/null 2>&1
    # shellcheck disable=SC2086
    [ -z "$VOLUMES" ] || docker volume rm $VOLUMES >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$FLUXDIR"
}
trap cleanup EXIT INT TERM

# ── Helpers ───────────────────────────────────────────────────────────────────

s3env() { # common S3 settings, as docker -e flags
    printf '%s\n' -e "S3_ENDPOINT=${S3_URL}" -e "S3_BUCKET=${BUCKET}" \
        -e "S3_ACCESS_KEY=${S3_USER}" -e "S3_SECRET_KEY=${S3_PASS}"
}

# aws against the test S3, from the backup image (it carries aws-cli).
s3() {
    docker run --rm --network "$NET" \
        -e "AWS_ACCESS_KEY_ID=${S3_USER}" -e "AWS_SECRET_ACCESS_KEY=${S3_PASS}" \
        -e AWS_DEFAULT_REGION=us-east-1 \
        -e AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
        -e AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
        -v "${RUN}-xfer:/xfer" \
        --entrypoint aws "$BK_IMG" --endpoint-url "$S3_URL" "$@"
}

keys() { # PREFIX -- keys under it, one per line, sorted
    s3 s3api list-objects-v2 --bucket "$BUCKET" --prefix "$1/" \
        --query 'Contents[].Key' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' | LC_ALL=C sort
}

# start_db NAME PREFIX [docker-run args...] -- fresh volume every time.
start_db() {
    _name="${RUN}-$1" _prefix="$2"; shift 2
    CONTAINERS="$CONTAINERS $_name"
    VOLUMES="$VOLUMES ${_name}-vol"
    # shellcheck disable=SC2046
    docker run -d --name "$_name" --network "$NET" \
        -e POSTGRES_USER=app -e POSTGRES_PASSWORD=apppw -e POSTGRES_DB=appdb \
        -e "PGDATA=${PGDATA_IN}" -v "${_name}-vol:/var/lib/postgresql/data" \
        $(s3env) -e "S3_PREFIX=${_prefix}" -e DUMP_NAME=testapp \
        -e "HEIGHT_SQL=${HEIGHT_SQL}" \
        "$@" "$DB_IMG" >/dev/null
}

# wait_db NAME -- until postgres answers on TCP (the init-time temp server is
# socket-only, so TCP means the REAL server is up). rc 1 on timeout or exit.
wait_db() {
    _name="${RUN}-$1" _i=0
    while [ "$_i" -lt 120 ]; do
        docker exec "$_name" pg_isready -q -h 127.0.0.1 -U app -d appdb 2>/dev/null && return 0
        [ "$(docker inspect -f '{{.State.Running}}' "$_name" 2>/dev/null)" = "true" ] || return 1
        sleep 1; _i=$((_i + 1))
    done
    return 1
}

sql() { # NAME SQL
    docker exec "${RUN}-$1" psql -U app -d appdb -tAc "$2" 2>&1
}

tables() { # NAME -- tables in the public schema
    sql "$1" "select count(*) from information_schema.tables where table_schema='public'"
}

seed() { # NAME UPTO -- blocks 1..UPTO
    sql "$1" "create table if not exists blocks(number bigint primary key, payload text);
              insert into blocks select g, md5(g::text) from generate_series(1,$2) g on conflict do nothing" >/dev/null
}

logs() { # NAME
    docker logs "${RUN}-$1" 2>&1
}

bkenv() { # DB PREFIX -- the sidecar's settings, as docker -e flags
    s3env
    printf '%s\n' -e "PGHOST=${RUN}-$1" -e PGUSER=app -e PGPASSWORD=apppw -e PGDATABASE=appdb \
        -e "S3_PREFIX=$2" -e DUMP_NAME=testapp \
        -e "HEARTBEAT_URL=http://${HB_HOST}:8080/hb-$2" -e BACKUP_DIR=/tmp \
        -e FLUX_APP_NAME=testapp -e FLUX_LOCATION_URL=file:///flux/location.json \
        -v "${FLUXDIR}:/flux:ro"
}

# flux_list ENTRY_IP... -- what Flux "runs" for app testapp from now on: one
# entry per IP given, none for no arguments. Written whole, then renamed in.
flux_list() {
    _data=""
    for _ip in "$@"; do
        _data="${_data:+${_data},}{\"name\":\"testapp\",\"ip\":\"${_ip}\",\"runningSince\":\"2026-11-25T00:00:00.000Z\"}"
    done
    printf '{"status":"success","data":[%s]}' "$_data" >"${FLUXDIR}/location.json.new"
    chmod 644 "${FLUXDIR}/location.json.new"
    mv "${FLUXDIR}/location.json.new" "${FLUXDIR}/location.json"
}
# HEIGHT_SQL holds spaces, so it is never part of bkenv's word-split output;
# every caller passes it as its own quoted argument.

# backup_once DB PREFIX [docker-run args...] -- one cycle; sets BK_RC, BK_OUT.
backup_once() {
    _db="$1" _prefix="$2"; shift 2
    # shellcheck disable=SC2046
    BK_OUT="$(docker run --rm --network "$NET" $(bkenv "$_db" "$_prefix") \
        -e "HEIGHT_SQL=${HEIGHT_SQL}" "$@" "$BK_IMG" --once 2>&1)"
    BK_RC=$?
}

uploads() { # PREFIX -- keys with an unfinished multipart upload. Both
    # listings, as the loop does: some stores ignore a partial --prefix for this
    # call (MinIO did), and a prefix-scoped Storj key is refused the bucket-wide one.
    { s3 s3api list-multipart-uploads --bucket "$BUCKET" --prefix "$1/" \
          --query 'Uploads[].Key' --output text 2>/dev/null
      s3 s3api list-multipart-uploads --bucket "$BUCKET" \
          --query 'Uploads[].Key' --output text 2>/dev/null
    } | tr '\t' '\n' | grep "^$1/" | LC_ALL=C sort -u
}

heartbeats() { # PREFIX -- how many pings the sink has seen for it
    docker logs "$HB_HOST" 2>&1 | grep -c "GET /hb-$1 " || true
}

# ── Setup ─────────────────────────────────────────────────────────────────────

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    echo "building images"
    docker build -q -t "$DB_IMG" -f "$CTX/db/Dockerfile" "$CTX" >/dev/null || { echo "FATAL: db image build failed"; exit 1; }
    docker build -q -t "$BK_IMG" -f "$CTX/backup/Dockerfile" "$CTX" >/dev/null || { echo "FATAL: backup image build failed"; exit 1; }
fi

docker network create "$NET" >/dev/null
VOLUMES="$VOLUMES ${RUN}-xfer"
docker volume create "${RUN}-xfer" >/dev/null

CONTAINERS="$CONTAINERS $HB_HOST"
if [ -z "$EXTERNAL" ]; then
    CONTAINERS="$CONTAINERS $S3_HOST"
    # One identity with the test's key; -ip must be the container's own name so
    # the master, volume and S3 servers inside it can find each other.
    # shellcheck disable=SC2016  # expanded inside the container
    docker run -d --name "$S3_HOST" --network "$NET" \
        -e "SW_IP=${S3_HOST}" -e "SW_KEY=${S3_USER}" -e "SW_SECRET=${S3_PASS}" \
        --entrypoint /bin/sh "$S3_IMG" -c '
            umask 077
            printf "{\"identities\":[{\"name\":\"test\",\"credentials\":[{\"accessKey\":\"%s\",\"secretKey\":\"%s\"}],\"actions\":[\"Admin\",\"Read\",\"Write\",\"List\",\"Tagging\"]}]}" \
                "$SW_KEY" "$SW_SECRET" > /tmp/s3.json
            exec weed server -dir=/data -ip="$SW_IP" -ip.bind=0.0.0.0 -volume.max=10 \
                -master.telemetry=false -s3 -s3.port=9000 -s3.config=/tmp/s3.json' >/dev/null
fi
flux_list 10.1.0.1:16127   # the default: Flux runs one instance
# A one-request-at-a-time HTTP sink; busybox nc prints each request line.
docker run -d --name "$HB_HOST" --network "$NET" "$HB_IMG" sh -c \
    'while :; do printf "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" | nc -l -p 8080; done' >/dev/null

if [ -n "$EXTERNAL" ]; then
    echo "external store: s3://${BUCKET}/${ROOT}"
else
    i=0
    until s3 s3api create-bucket --bucket "$BUCKET" >/dev/null 2>&1; do
        i=$((i + 1)); [ "$i" -lt 90 ] || { echo "FATAL: test S3 never came up"; exit 1; }
        sleep 1
    done
    # SeaweedFS answers listings about 30 s before it takes writes ("master is
    # warming up"), so wait for a real write before any case relies on one.
    i=0
    until s3 s3api put-object --bucket "$BUCKET" --key warmup >/dev/null 2>&1; do
        i=$((i + 1)); [ "$i" -lt 90 ] || { echo "FATAL: test S3 never took a write"; exit 1; }
        sleep 1
    done
    s3 s3api delete-object --bucket "$BUCKET" --key warmup >/dev/null 2>&1
fi

# ── Cases ─────────────────────────────────────────────────────────────────────

echo "first boot, nothing stored"
start_db a "$MAIN"
wait_db a; assert_rc "postgres comes up" 0 $?
assert_eq "database is empty" "0" "$(tables a)"
assert_has "says why it is empty" "no dumps" "$(logs a)"

echo "backup refuses an empty index"
backup_once a "$MAIN"
assert_rc "no dump taken" 1 "$BK_RC"
assert_eq "nothing uploaded" "" "$(keys "$MAIN")"
assert_eq "no heartbeat" "0" "$(heartbeats "$MAIN")"

echo "backup of an indexed database"
seed a 500
backup_once a "$MAIN"
assert_rc "dump taken" 0 "$BK_RC"
K500="$(keys "$MAIN")"
case "$K500" in
    "$MAIN"/testapp-*-h500.dump) pass "one key, carrying height 500" ;;
    *) fail "one key, carrying height 500 (got '$K500')" ;;
esac
assert_eq "heartbeat sent" "1" "$(heartbeats "$MAIN")"

echo "restore onto a fresh volume"
start_db b "$MAIN"
wait_db b; assert_rc "postgres comes up" 0 $?
assert_eq "height restored" "500" "$(sql b "$HEIGHT_SQL")"
assert_eq "row content restored" "$(sql a "select payload from blocks where number=321")" \
    "$(sql b "select payload from blocks where number=321")"
assert_has "says what it restored" "restored ${K500}" "$(logs b)"
docker exec "${RUN}-b" test -e "${PGDATA_IN}/.restore-in-progress.dump"
assert_rc "temporary dump file removed" 1 $?

echo "height guard"
start_db c "$NONE"
wait_db c; seed c 100
backup_once c "$MAIN"
assert_rc "a lower index is not uploaded" 1 "$BK_RC"
assert_has "says why" "refusing" "$BK_OUT"
assert_eq "stored keys unchanged" "$K500" "$(keys "$MAIN")"
assert_eq "no heartbeat for a refused dump" "1" "$(heartbeats "$MAIN")"

echo "one writer"
# a's index moves past the stored height, so only the one-writer guard can
# stop these cycles: the height guard would let them through.
seed a 550
# The first thing two writers break: one cycle aborting the other's upload
# mid-way. This one stands in for a real instance's upload in flight.
INFLIGHT="${MAIN}/testapp-20991231T000000Z-h550.dump"
s3 s3api create-multipart-upload --bucket "$BUCKET" --key "$INFLIGHT" >/dev/null
flux_list 10.1.0.1:16127 10.1.0.2:16127
backup_once a "$MAIN"
assert_rc "two instances: no dump taken" 1 "$BK_RC"
assert_has "two instances: names both" "2 instances of testapp (10.1.0.1:16127, 10.1.0.2:16127)" "$BK_OUT"
flux_list
backup_once a "$MAIN"
assert_rc "no instance listed: no dump taken" 1 "$BK_RC"
assert_has "no instance listed: says so" "no instance of testapp" "$BK_OUT"
rm -f "${FLUXDIR}/location.json"
backup_once a "$MAIN"
assert_rc "unreadable list: no dump taken" 1 "$BK_RC"
assert_has "unreadable list: says so" "could not read the instance list" "$BK_OUT"
assert_eq "nothing stored while skipping" "$K500" "$(keys "$MAIN")"
assert_eq "no heartbeat while skipping" "1" "$(heartbeats "$MAIN")"
assert_eq "an upload in flight survives every skip" "$INFLIGHT" "$(uploads "$MAIN" | grep '/testapp-')"
# The app's name from a Flux PGHOST, as in production (flux<component>_<app>),
# with no FLUX_APP_NAME: the host is a's address under a Flux-style name.
flux_list 10.1.0.1:16127
A_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "${RUN}-a")"
backup_once a "$MAIN" -e FLUX_APP_NAME= -e PGHOST=fluxdb_testapp --add-host "fluxdb_testapp:${A_IP}"
assert_rc "one instance, name from PGHOST: dump taken" 0 "$BK_RC"
case "$(keys "$MAIN" | tail -n 1)" in
    "$MAIN"/testapp-*-h550.dump) pass "the new dump carries height 550" ;;
    *) fail "the new dump carries height 550 (got '$(keys "$MAIN" | tail -n 1)')" ;;
esac
assert_eq "heartbeat sent again" "2" "$(heartbeats "$MAIN")"
assert_eq "with one writer again, the dead upload is aborted" "" "$(uploads "$MAIN" | grep '/testapp-')"

echo "retention and dead multipart uploads"
# A cycle killed mid-upload leaves an unfinished multipart upload: invisible as
# an object (so never restorable) but still holding storage until aborted.
s3 s3api create-multipart-upload --bucket "$BUCKET" --key "${MAIN}/testapp-20200101T000000Z-h1.dump" >/dev/null
s3 s3api create-multipart-upload --bucket "$BUCKET" --key "${MAIN}/otherapp-20200101T000000Z-h1.dump" >/dev/null
seed a 600; sleep 1
backup_once a "$MAIN" -e BACKUP_RETENTION=2
assert_rc "dump at 600 taken" 0 "$BK_RC"
seed a 700; sleep 1
backup_once a "$MAIN" -e BACKUP_RETENTION=2
assert_rc "dump at 700 taken" 0 "$BK_RC"
GOT="$(keys "$MAIN" | sed 's/.*-h//' | tr '\n' ' ')"
assert_eq "only the newest 2 remain" "600.dump 700.dump " "$GOT"
assert_eq "our dead upload aborted, another app's untouched" "${MAIN}/otherapp-20200101T000000Z-h1.dump" "$(uploads "$MAIN")"

echo "a restarted sidecar waits out the cadence"
CONTAINERS="$CONTAINERS ${RUN}-loop"
# shellcheck disable=SC2046
docker run -d --name "${RUN}-loop" --network "$NET" $(bkenv a "$MAIN") \
    -e "HEIGHT_SQL=${HEIGHT_SQL}" -e BACKUP_INTERVAL=3600 "$BK_IMG" >/dev/null
i=0
until docker logs "${RUN}-loop" 2>&1 | grep -q "next dump in"; do
    i=$((i + 1)); [ "$i" -lt 60 ] || break
    sleep 1
done
assert_has "schedules from the newest stored dump" "next dump in" "$(docker logs "${RUN}-loop" 2>&1)"
assert_eq "no extra dump on start" "600.dump 700.dump " "$(keys "$MAIN" | sed 's/.*-h//' | tr '\n' ' ')"
docker rm -f "${RUN}-loop" >/dev/null

echo "restore picks the newest"
start_db d "$MAIN"
wait_db d; assert_rc "postgres comes up" 0 $?
assert_eq "height is the newest dump's" "700" "$(sql d "$HEIGHT_SQL")"

echo "corrupt newest dump falls back to empty"
docker run --rm -v "${RUN}-xfer:/xfer" "$HB_IMG" sh -c 'head -c 4096 /dev/urandom > /xfer/garbage' >/dev/null
s3 s3 cp /xfer/garbage "s3://${BUCKET}/${MAIN}/testapp-29991231T235959Z-h999999.dump" --only-show-errors
start_db e "$MAIN"
wait_db e; assert_rc "postgres still comes up" 0 $?
assert_eq "database is empty, not half-restored" "0" "$(tables e)"
assert_has "says the restore failed" "RESTORE FAILED" "$(logs e)"
s3 s3 rm "s3://${BUCKET}/${MAIN}/testapp-29991231T235959Z-h999999.dump" --only-show-errors

echo "a dump lower than its key claims is rejected"
NEWEST="$(keys "$MAIN" | tail -n 1)"
s3 s3 cp "s3://${BUCKET}/${NEWEST}" "s3://${BUCKET}/${MAIN}/testapp-29991231T235959Z-h900.dump" --only-show-errors
start_db f "$MAIN"
wait_db f; assert_rc "postgres still comes up" 0 $?
assert_eq "database is empty" "0" "$(tables f)"
assert_has "says the height did not match" "below the key's height" "$(logs f)"
s3 s3 rm "s3://${BUCKET}/${MAIN}/testapp-29991231T235959Z-h900.dump" --only-show-errors

echo "unreadable store falls back to empty"
start_db g "$MAIN" -e S3_SECRET_KEY=wrong
wait_db g; assert_rc "postgres still comes up" 0 $?
assert_eq "database is empty" "0" "$(tables g)"
assert_has "says the listing failed" "could not list" "$(logs g)"

echo "backups not configured"
start_db h "$MAIN" -e S3_BUCKET=
wait_db h; assert_rc "postgres comes up" 0 $?
assert_has "db says restore is off" "S3_BUCKET unset" "$(logs h)"
backup_once a "$MAIN" -e S3_BUCKET=
assert_rc "sidecar takes no dump" 1 "$BK_RC"
assert_has "sidecar says so loudly" "BACKUPS ARE NOT RUNNING" "$BK_OUT"

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES ABOVE"; fi
exit "$FAILED"
