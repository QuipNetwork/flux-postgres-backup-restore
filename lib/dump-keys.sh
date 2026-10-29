# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Dump-key rules shared by the db and backup images. POSIX sh,
# sourced, no side effects.
#
# A dump key is
#
#     <prefix>/<app>-<YYYYMMDDTHHMMSSZ>-h<height>.dump
#
# where <height> is the index height (newest block) the app had reached when the
# dump started. The stamp comes first so lexical order IS chronological order,
# with no dependence on the object store's LastModified or on clock skew between
# the node that wrote a dump and the node restoring it.
#
# The height is what lets the backup loop refuse to replace a good dump with a
# worse one: after a failed restore the app re-indexes from genesis, and without
# the guard its first few dumps would be "newest" and push the good ones out.
#
# ⚠ The prefix must identify the CHAIN as well as the app (for example
# subscan-postgres/aglais-<genesis-prefix>). Heights restart on a relaunch, and
# a restore under the old prefix would put the old chain's index under the new
# chain's blocks.

# is_uint VALUE -- rc 0 if VALUE is a non-empty string of digits.
is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# dump_key PREFIX APP HEIGHT STAMP -- print the key, rc 1 on any malformed part.
dump_key() {
    _p="${1:-}" _a="${2:-}" _h="${3:-}" _s="${4:-}"
    [ -n "$_p" ] || return 1
    printf '%s\n' "$_a" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || return 1
    is_uint "$_h" || return 1
    printf '%s\n' "$_s" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$' || return 1
    printf '%s/%s-%s-h%s.dump\n' "$_p" "$_a" "$_s" "$_h"
}

# is_own_dump_key PREFIX APP KEY -- rc 0 if KEY is a dump key of this app: directly
# under PREFIX, named for APP, and well-formed. Anything else -- another app,
# another prefix, a nested path, a script's own log line -- is never ours to
# restore, guard against or delete.
is_own_dump_key() {
    _rest="${3#"$1/$2-"}"
    [ "$_rest" != "$3" ] || return 1
    printf '%s\n' "$_rest" | grep -Eq '^[0-9]{8}T[0-9]{6}Z-h[0-9]+\.dump$'
}

# own_dump_keys PREFIX APP -- stdin: keys, whitespace- or newline-separated
# (aws --output text joins them with tabs). Prints this app's dumps, oldest
# first.
own_dump_keys() {
    # shellcheck disable=SC2020  # two characters to two newlines, on purpose
    tr '\t ' '\n\n' | while IFS= read -r _k; do
        is_own_dump_key "$1" "$2" "$_k" && printf '%s\n' "$_k"
    done | LC_ALL=C sort
}

# newest_dump_key PREFIX APP -- the dump a restore should use, or nothing.
newest_dump_key() {
    own_dump_keys "$1" "$2" | tail -n 1
}

# dump_key_height KEY -- print the height a key carries, rc 1 if it has none.
dump_key_height() {
    _h="${1##*-h}"
    _h="${_h%.dump}"
    is_uint "$_h" || return 1
    printf '%s\n' "$_h"
}

# dump_key_iso_time KEY -- the key's stamp as YYYY-MM-DDTHH:MM:SSZ, which `date -d`
# parses (the compact form is not portable). rc 1 if the key has no valid stamp.
dump_key_iso_time() {
    _s="$(printf '%s\n' "$1" | sed -n 's/.*-\([0-9]\{8\}T[0-9]\{6\}Z\)-h[0-9][0-9]*\.dump$/\1/p')"
    [ -n "$_s" ] || return 1
    printf '%s\n' "$_s" | sed 's/^\(....\)\(..\)\(..\)T\(..\)\(..\)\(..\)Z$/\1-\2-\3T\4:\5:\6Z/'
}

# may_store_dump HEIGHT NEWEST_HEIGHT -- rc 0 if a dump taken at HEIGHT may
# become the newest object. NEWEST_HEIGHT is empty when nothing is stored yet.
# An empty index (height 0) is never worth storing.
may_store_dump() {
    is_uint "${1:-}" || return 1
    [ "$1" -gt 0 ] || return 1
    [ -n "${2:-}" ] || return 0
    is_uint "$2" || return 1
    [ "$1" -ge "$2" ]
}

# dump_keys_to_prune PREFIX APP RETENTION -- dumps to delete, oldest first. Keeps
# the newest RETENTION, and always at least one: deleting the object a restore
# would pick is strictly worse than paying for storage.
dump_keys_to_prune() {
    _keep="${3:-}"
    is_uint "$_keep" || _keep=1
    [ "$_keep" -ge 1 ] || _keep=1
    _all="$(own_dump_keys "$1" "$2")"
    _n="$(printf '%s' "$_all" | grep -c . || true)"
    [ "$_n" -gt "$_keep" ] || return 0
    printf '%s\n' "$_all" | head -n "$((_n - _keep))"
}
