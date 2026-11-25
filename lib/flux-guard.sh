# SPDX-License-Identifier: AGPL-3.0-or-later
#
# One writer. The backup sidecar calls sole_instance before every cycle and
# stores nothing unless Flux runs exactly one instance of the app. POSIX sh,
# sourced, no side effects. Needs curl and jq.
#
# Why: Flux can run a second instance of an app whose spec asks for one. It did
# for observe.quip.network on 2026-11-23, for about 20 minutes (QUI-2518). Two
# sidecars then share one prefix. Each cycle aborts this app's unfinished
# uploads, so one sidecar can kill the other's upload mid-way, and both store
# and prune dumps of their own copy. While two run, both skip: neither needs to
# know which node it is on.
#
# Fail closed. Anything but a successful answer that lists exactly one instance
# is a skip, an empty list included. Flux answers an unknown app name with
# success and no entries, so counting zero as fine would let a wrong name turn
# the guard off without a sound. A run of skips stops the heartbeat, which is
# only sent after a stored dump, so the backup monitor goes red.
#
# The app name: FLUX_APP_NAME, or else the app part of PGHOST. Flux names a
# component's host flux<component>_<app> (fluxsqdb_quipsubscan), so one image
# serves every app without a new variable in their specs.
#
# Tests: test/flux-guard_test.sh.

# app_from_pghost HOST -- the app part of a Flux inter-component host name
# flux<component>_<app>; rc 1 for anything else.
app_from_pghost() {
    case "${1:-}" in
        flux?*_?*) ;;
        *) return 1 ;;
    esac
    _fg_rest=${1#flux}
    _fg_comp=${_fg_rest%%_*}
    _fg_app=${_fg_rest#*_}
    case "$_fg_comp" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
    case "$_fg_app" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
    printf '%s\n' "$_fg_app"
}

# flux_app_name -- FLUX_APP_NAME if set, else the app named by PGHOST.
flux_app_name() {
    if [ -n "${FLUX_APP_NAME:-}" ]; then
        printf '%s\n' "$FLUX_APP_NAME"
        return 0
    fi
    app_from_pghost "${PGHOST:-}"
}

# flux_location_url APP -- where to read the app's running instances.
# FLUX_LOCATION_URL overrides it, for tests (a file:// URL works).
flux_location_url() {
    printf '%s\n' "${FLUX_LOCATION_URL:-https://api.runonflux.io/apps/location/$1}"
}

# instances_named APP -- stdin is a Flux /apps/location answer. Prints how many
# entries belong to APP; fails on anything that is not a successful answer.
instances_named() {
    jq -e --arg app "$1" '
        if type == "object" and .status == "success" and (.data | type) == "array"
        then [.data[] | select(.name == $app)] | length
        else error("not a successful Flux answer")
        end'
}

# sole_instance -- rc 0 only if Flux runs exactly one instance of the app.
# Otherwise prints one line saying why to stderr.
sole_instance() {
    if ! _fg_app="$(flux_app_name)"; then
        echo "cannot tell which Flux app this is: set FLUX_APP_NAME, or PGHOST must be flux<component>_<app> (got '${PGHOST:-}')" >&2
        return 1
    fi
    _fg_url="$(flux_location_url "$_fg_app")"
    if ! _fg_out="$(curl --silent --show-error --fail --max-time 20 --user-agent flux-postgres-backup "$_fg_url" 2>&1)"; then
        echo "could not read the instance list from ${_fg_url}: $(printf '%s' "$_fg_out" | tr '\n' ' ' | cut -c1-200)" >&2
        return 1
    fi
    if ! _fg_count="$(printf '%s' "$_fg_out" | instances_named "$_fg_app" 2>/dev/null)"; then
        echo "the instance list from ${_fg_url} is not a usable Flux answer: $(printf '%s' "$_fg_out" | tr '\n' ' ' | cut -c1-200)" >&2
        return 1
    fi
    case "$_fg_count" in
        1) return 0 ;;
        0) echo "Flux lists no instance of ${_fg_app}, so a single writer cannot be confirmed" >&2 ;;
        *)
            _fg_ips="$(printf '%s' "$_fg_out" | jq -r --arg app "$_fg_app" '[.data[] | select(.name == $app) | .ip] | join(", ")')"
            echo "Flux runs ${_fg_count} instances of ${_fg_app} (${_fg_ips}); backups need exactly one writer" >&2
            ;;
    esac
    return 1
}
