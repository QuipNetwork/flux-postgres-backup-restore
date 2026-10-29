#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds the db and backup images for Flux and prints the digests to pin in the
# app spec. Same discipline as explorer.quip.network/scripts/build-images.sh:
# Quip Flux images are built locally and pushed by hand, no CI.
#
#   --platform linux/amd64   Quip Flux images are amd64-only. Never multi-arch.
#   --provenance=false
#   --sbom=false             Together these give a SINGLE-platform manifest, so
#                            the digest printed below IS the image digest (for a
#                            manifest list, RepoDigests reports the list's).
#   BUILDX_BUILDER=default   The `multiarch` builder has broken DNS here.
#
# Usage:
#   scripts/build-images.sh            # unit tests + build
#   PUSH=1 scripts/build-images.sh     # ... and push (needs a registry login and
#                                      # a clean tree: the tag names a commit)
#
# Run test/integration_test.sh before a push; it needs ~2 min and docker.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

REGISTRY="${REGISTRY:-registry.gitlab.com/quip.network/flux-postgres-backup-restore}"
TAG_SUFFIX="${TAG_SUFFIX:-$(git rev-parse --short HEAD 2>/dev/null || echo local)}"
PUSH="${PUSH:-}"

log() { printf '[build-images] %s\n' "$*" >&2; }

if [ -n "${PUSH}" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    log "FATAL: uncommitted changes. A pushed tag must name the commit it was built from."
    exit 1
fi

sh test/dump-keys_test.sh >/dev/null || { log "FATAL: test/dump-keys_test.sh failed"; exit 1; }

build_one() {
    local role="$1" tag="${REGISTRY}:${1}-${TAG_SUFFIX}"
    log "building ${tag}"
    BUILDX_BUILDER=default docker build \
        -f "${role}/Dockerfile" \
        --platform linux/amd64 \
        --provenance=false --sbom=false \
        -t "${tag}" . >&2
    printf '%s\n' "${tag}"
}

# assert_built TAG ROLE -- the image holds what its role needs. A tag is only a
# name; check the contents before anything is pushed.
assert_built() {
    local t="$1" role="$2" check
    docker image inspect "${t}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
        | grep -q '^AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt$' \
        || { log "FATAL: ${t} does not pin AWS_CA_BUNDLE"; exit 1; }
    case "${role}" in
        db)
            check='test -x /docker-entrypoint-initdb.d/00-restore-on-empty.sh && test -r /usr/local/lib/dump-keys.sh && command -v aws pg_restore'
            ;;
        backup)
            [ "$(docker image inspect "${t}" --format '{{json .Config.Entrypoint}}')" = '["/usr/local/bin/backup-loop.sh"]' ] \
                || { log "FATAL: ${t} entrypoint is not backup-loop.sh"; exit 1; }
            check='test -x /usr/local/bin/backup-loop.sh && test -r /usr/local/lib/dump-keys.sh && command -v aws curl pg_dump date'
            ;;
    esac
    docker run --rm --entrypoint sh "${t}" -c "${check}" >/dev/null \
        || { log "FATAL: ${t} is missing a file or tool its role needs"; exit 1; }
}

TAGS=()
for role in db backup; do
    t="$(build_one "${role}")"
    assert_built "${t}" "${role}"
    if [ -n "${PUSH}" ]; then
        log "pushing ${t}"
        # >&2: docker push writes its transcript to stdout.
        docker push "${t}" >&2
    fi
    TAGS+=("${t}")
done

echo
log "built:"
for t in "${TAGS[@]}"; do
    if [ -n "${PUSH}" ]; then
        # The RepoDigest for THIS registry, not `index .RepoDigests 0`: an image
        # that also carries a local test tag lists several, in no fixed order.
        digest="$(docker image inspect "${t}" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
                  | grep "^${REGISTRY}@" | head -1)"
        printf '  %s\n    %s\n' "${t}" "${digest:-(digest unavailable -- did the push succeed?)}"
    else
        printf '  %s\n' "${t}"
    fi
done

[ -n "${PUSH}" ] || log "not pushed (set PUSH=1). Digests are only available after a push."
