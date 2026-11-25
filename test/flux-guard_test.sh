#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Unit tests for lib/flux-guard.sh, the one-writer guard the backup sidecar runs
# before every cycle. No Flux and no network: the instance lists are files,
# read through file:// URLs by the same curl call that reads the real API.
#
# Run:  sh test/flux-guard_test.sh
# Needs: curl, jq (both are in the backup image).
# Exit: 0 = all pass, nonzero = a failure (name printed).

set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB="${SELF_DIR}/../lib/flux-guard.sh"

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
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in '$3')" ;; esac
}

# shellcheck source=../lib/flux-guard.sh
. "$LIB" || { echo "FATAL: cannot source $LIB"; exit 1; }

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

entry() { # NAME IP
    printf '{"name":"%s","ip":"%s","runningSince":"2026-11-25T00:00:00.000Z","broadcastedAt":"2026-11-25T00:00:00.000Z","expireAt":"2026-11-25T02:05:00.000Z"}' "$1" "$2"
}
answer() { # FILE ENTRY...: a successful Flux answer
    _f="$1"; shift
    _data=""
    for _e in "$@"; do _data="${_data:+${_data},}${_e}"; done
    printf '{"status":"success","data":[%s]}' "$_data" >"${DIR}/${_f}"
}
A="quipsubscan"
answer one.json   "$(entry "$A" 212.139.16.103:16127)"
answer two.json   "$(entry "$A" 212.139.16.103:16127)" "$(entry "$A" 65.109.106.216:16127)"
answer none.json
answer other.json "$(entry "$A" 212.139.16.103:16127)" "$(entry quipexplorer 65.109.106.216:16127)"
printf '{"status":"error","data":{"name":"Error","message":"too many requests"}}' >"${DIR}/error.json"
printf '<html><body>502 Bad Gateway</body></html>' >"${DIR}/html.json"
printf '{"status":"success","data":{"name":"%s"}}' "$A" >"${DIR}/notalist.json"

# guard FILE -- run sole_instance for app A against that file; sets RC, WHY.
guard() {
    WHY="$(FLUX_APP_NAME="$A" FLUX_LOCATION_URL="file://${DIR}/$1" sole_instance 2>&1 >/dev/null)"
    RC=$?
}

echo "app_from_pghost"
assert_eq "Subscan's db host gives its app" "quipsubscan" "$(app_from_pghost fluxsqdb_quipsubscan)"
assert_eq "Blockscout's db host gives its app" "quipexplorer" "$(app_from_pghost fluxbsdb_quipexplorer)"
app_from_pghost localhost >/dev/null 2>&1;          assert_rc "a plain host name is not a Flux name" 1 $?
app_from_pghost "" >/dev/null 2>&1;                 assert_rc "an empty host is not a Flux name" 1 $?
app_from_pghost flux_quipsubscan >/dev/null 2>&1;   assert_rc "a missing component is rejected" 1 $?
app_from_pghost fluxsqdb_ >/dev/null 2>&1;          assert_rc "a missing app is rejected" 1 $?
app_from_pghost fluxsqdb_quip_subscan >/dev/null 2>&1; assert_rc "an app with an underscore is rejected" 1 $?
app_from_pghost fluxsqdb_quipsubscan.local >/dev/null 2>&1; assert_rc "a dotted name is rejected" 1 $?
app_from_pghost 10.0.0.5 >/dev/null 2>&1;           assert_rc "an IP address is rejected" 1 $?

echo "flux_app_name"
assert_eq "derived from PGHOST" "quipsubscan" "$(PGHOST=fluxsqdb_quipsubscan FLUX_APP_NAME= flux_app_name)"
assert_eq "FLUX_APP_NAME wins over PGHOST" "otherapp" "$(PGHOST=fluxsqdb_quipsubscan FLUX_APP_NAME=otherapp flux_app_name)"
PGHOST=db FLUX_APP_NAME= flux_app_name >/dev/null 2>&1; assert_rc "no Flux PGHOST and no override fails" 1 $?

echo "flux_location_url"
assert_eq "the public API's location route by default" \
    "https://api.runonflux.io/apps/location/quipsubscan" "$(FLUX_LOCATION_URL= flux_location_url quipsubscan)"
assert_eq "FLUX_LOCATION_URL overrides it" "file:///x.json" "$(FLUX_LOCATION_URL=file:///x.json flux_location_url quipsubscan)"

echo "instances_named"
assert_eq "one entry" "1" "$(instances_named "$A" <"${DIR}/one.json")"
assert_eq "two entries" "2" "$(instances_named "$A" <"${DIR}/two.json")"
assert_eq "no entries" "0" "$(instances_named "$A" <"${DIR}/none.json")"
assert_eq "another app's entry is not counted" "1" "$(instances_named "$A" <"${DIR}/other.json")"
instances_named "$A" <"${DIR}/error.json" >/dev/null 2>&1;    assert_rc "status error fails" 1 $(( $? != 0 ))
instances_named "$A" <"${DIR}/html.json" >/dev/null 2>&1;     assert_rc "an HTML page fails" 1 $(( $? != 0 ))
instances_named "$A" <"${DIR}/notalist.json" >/dev/null 2>&1; assert_rc "data that is not a list fails" 1 $(( $? != 0 ))
printf '' | instances_named "$A" >/dev/null 2>&1;             assert_rc "an empty body fails" 1 $(( $? != 0 ))

echo "sole_instance passes only for exactly one instance"
guard one.json;   assert_rc "one instance: back up" 0 "$RC"; assert_eq "one instance: nothing said" "" "$WHY"
guard other.json; assert_rc "one of ours beside another app: back up" 0 "$RC"
guard two.json;   assert_rc "two instances: skip" 1 $(( RC != 0 ))
assert_has "two instances: says how many and names both" "2 instances of quipsubscan (212.139.16.103:16127, 65.109.106.216:16127)" "$WHY"
guard none.json;  assert_rc "no instance listed: skip" 1 $(( RC != 0 ))
assert_has "no instance listed: says so" "no instance of quipsubscan" "$WHY"

echo "sole_instance fails closed"
guard error.json;   assert_rc "status error: skip" 1 $(( RC != 0 )); assert_has "status error: unusable" "not a usable Flux answer" "$WHY"
guard html.json;    assert_rc "HTML page: skip" 1 $(( RC != 0 ));    assert_has "HTML page: unusable" "not a usable Flux answer" "$WHY"
guard missing.json; assert_rc "unreadable list: skip" 1 $(( RC != 0 )); assert_has "unreadable list: says so" "could not read the instance list" "$WHY"
WHY="$(PGHOST=db FLUX_APP_NAME= FLUX_LOCATION_URL="file://${DIR}/one.json" sole_instance 2>&1 >/dev/null)"; RC=$?
assert_rc "unknown app: skip" 1 $(( RC != 0 ))
assert_has "unknown app: says how to name it" "FLUX_APP_NAME" "$WHY"
WHY="$(PGHOST=fluxsqdb_quipsubscan FLUX_APP_NAME= FLUX_LOCATION_URL="file://${DIR}/one.json" sole_instance 2>&1 >/dev/null)"; RC=$?
assert_rc "app derived from PGHOST: back up" 0 "$RC"

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES ABOVE"; fi
exit "$FAILED"
