#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Unit tests for lib/dump-keys.sh, the dump-key rules both images share.
#
# The rules matter more than they look. Restore picks "the newest valid key",
# backup refuses to upload below "the newest valid key's height", and prune
# deletes "everything older than the newest N valid keys". A key that slips
# through the filter can become the thing a relocation restores, and a key the
# filter wrongly rejects can be pruned or ignored. So the filter is pinned here
# against every shape of junk we have actually seen land in a listing.
#
# Run:  sh test/dump-keys_test.sh
# Exit: 0 = all pass, nonzero = a failure (name printed).

set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB="${SELF_DIR}/../lib/dump-keys.sh"

FAILED=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }
assert_eq() { # desc want got
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want='$2' got='$3')"; fi
}
assert_rc() { # desc want-rc got-rc
    if [ "$2" -eq "$3" ]; then pass "$1"; else fail "$1 (want rc=$2 got rc=$3)"; fi
}

# shellcheck source=../lib/dump-keys.sh
. "$LIB" || { echo "FATAL: cannot source $LIB"; exit 1; }

P="subscan-postgres/aglais-542a9915"
A="subscan"
K1="${P}/${A}-20261029T000000Z-h190000.dump"
K2="${P}/${A}-20261029T060000Z-h193600.dump"
K3="${P}/${A}-20261029T120000Z-h197200.dump"

echo "dump_key"
assert_eq "builds prefix/app-stamp-hheight.dump" "$K1" "$(dump_key "$P" "$A" 190000 20261029T000000Z)"
dump_key "$P" "Sub_scan" 1 20261029T000000Z >/dev/null 2>&1
assert_rc "rejects an app name outside [a-z0-9-]" 1 $?
dump_key "$P" "$A" 12x 20261029T000000Z >/dev/null 2>&1
assert_rc "rejects a non-numeric height" 1 $?
dump_key "$P" "$A" 1 2026-10-29T00:00:00Z >/dev/null 2>&1
assert_rc "rejects a stamp that is not YYYYMMDDTHHMMSSZ" 1 $?
dump_key "" "$A" 1 20261029T000000Z >/dev/null 2>&1
assert_rc "rejects an empty prefix" 1 $?

echo "own_dump_keys"
# aws --output text returns keys TAB-separated on one line. Mixed in: another
# app, another prefix, an in-flight .partial, a bad stamp, a key one directory
# deeper, and the line that bit evm-rpc -- a script's own log output landing in
# the listing.
LISTING="$(printf '%s\t%s\t%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$K3" "$K1" "$K2" \
    "${P}/explorer-20261029T130000Z-h5.dump" \
    "other-prefix/${A}-20261029T130000Z-h999999.dump" \
    "${P}/${A}-20261029T130000Z-h999999.dump.partial" \
    "${P}/${A}-2026-10-29T13:00:00Z-h999999.dump" \
    "${P}/nested/${A}-20261029T130000Z-h999999.dump" \
    "[restore-on-empty] FATAL: listing failed")"
GOT="$(printf '%s\n' "$LISTING" | own_dump_keys "$P" "$A" | tr '\n' ' ')"
assert_eq "keeps only this prefix+app, valid shape, oldest first" "$K1 $K2 $K3 " "$GOT"
GOT="$(printf 'None\n' | own_dump_keys "$P" "$A")"
assert_eq "aws 'None' (empty prefix) yields nothing" "" "$GOT"

echo "newest_dump_key"
assert_eq "newest is the latest stamp" "$K3" "$(printf '%s\n' "$LISTING" | newest_dump_key "$P" "$A")"
assert_eq "empty listing gives empty" "" "$(printf '' | newest_dump_key "$P" "$A")"

echo "dump_key_height"
assert_eq "extracts the height" "197200" "$(dump_key_height "$K3")"
dump_key_height "${P}/${A}-20261029T120000Z.dump" >/dev/null 2>&1
assert_rc "a key without a height is rejected" 1 $?

echo "may_store_dump"
may_store_dump 500 "";      assert_rc "first-ever dump (no newest) is allowed" 0 $?
may_store_dump 0 "";        assert_rc "an empty index (height 0) is never uploaded" 1 $?
may_store_dump 100 500;     assert_rc "below the newest stored height is refused" 1 $?
may_store_dump 500 500;     assert_rc "equal to the newest (chain paused) is allowed" 0 $?
may_store_dump 600 500;     assert_rc "above the newest is allowed" 0 $?
may_store_dump "" 500;      assert_rc "an unreadable height is refused" 1 $?
may_store_dump 600 abc;     assert_rc "an unreadable newest height is refused" 1 $?

echo "dump_keys_to_prune"
K4="${P}/${A}-20261029T180000Z-h200800.dump"
SIX="$(printf '%s\n' "$K1" "$K2" "$K3" "$K4" \
    "${P}/${A}-20261029T190000Z-h201400.dump" "${P}/${A}-20261029T200000Z-h202000.dump")"
GOT="$(printf '%s\n' "$SIX" | dump_keys_to_prune "$P" "$A" 4 | tr '\n' ' ')"
assert_eq "retention 4 of 6 deletes the 2 oldest" "$K1 $K2 " "$GOT"
GOT="$(printf '%s\n' "$K1" "$K2" | dump_keys_to_prune "$P" "$A" 4)"
assert_eq "fewer than retention deletes nothing" "" "$GOT"
GOT="$(printf '%s\n' "$K1" "$K2" "$K3" | dump_keys_to_prune "$P" "$A" 0 | tr '\n' ' ')"
assert_eq "retention 0 still keeps the newest" "$K1 $K2 " "$GOT"
GOT="$(printf '%s\n' "$K1" "$K2" "$K3" | dump_keys_to_prune "$P" "$A" junk | tr '\n' ' ')"
assert_eq "a non-numeric retention still keeps the newest" "$K1 $K2 " "$GOT"
GOT="$(printf '%s\n' "$K1" "other-prefix/${A}-20261029T130000Z-h1.dump" | dump_keys_to_prune "$P" "$A" 0)"
assert_eq "never deletes keys outside this prefix+app" "" "$GOT"

echo "dump_key_iso_time"
assert_eq "turns the key's stamp into ISO-8601 for date -d" "2026-10-29T12:00:00Z" "$(dump_key_iso_time "$K3")"
dump_key_iso_time "${P}/${A}-junk-h1.dump" >/dev/null 2>&1
assert_rc "a key without a valid stamp is rejected" 1 $?

echo "is_own_dump_key"
is_own_dump_key "$P" "$A" "$K1";                                    assert_rc "a dump key of this app is ours" 0 $?
is_own_dump_key "$P" "$A" "${P}/explorer-20261029T130000Z-h5.dump";  assert_rc "another app's key is not" 1 $?
is_own_dump_key "$P" "$A" "${P}/${A}-junk.dump";                     assert_rc "a malformed key is not" 1 $?

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES ABOVE"; fi
exit "$FAILED"
